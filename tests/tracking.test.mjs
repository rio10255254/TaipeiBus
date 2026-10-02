import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseTaipeiTime, normalizeBus, prepareLine, snapToLine, lineSlice } from '../server/geo.mjs';
import { BusCollector } from '../server/collector.mjs';
import { VehicleMotion, pointAtDistance, meters } from '../src/motion.js';

function row(overrides = {}) {
  return { BusID: 'ABC-123', CarID: 'physical-1', RouteID: 'sub-1', Longitude: '121.55', Latitude: '25.04', Speed: '30', Azimuth: '90', GoBack: '0', BusStatus: '0', DutyStatus: '0', DataTime: new Date().toISOString(), ...overrides };
}

test('Taipei source timestamps use UTC+8; invalid or unavailable data never becomes a current vehicle', () => {
  assert.equal(parseTaipeiTime('2026/10/02 10:15:00'), Date.parse('2026-10-02T02:15:00Z'));
  assert.equal(parseTaipeiTime('not a date'), null);
  assert.equal(normalizeBus(row({ DataTime: 'broken' })), null);
  assert.equal(normalizeBus(row({ DataTime: new Date(Date.now() + 120000).toISOString() })), null);
  assert.equal(normalizeBus(row({ DataTime: new Date(Date.now() - 16 * 60000).toISOString() })), null);
  assert.equal(normalizeBus(row({ BusStatus: '99' })), null);
  assert.equal(normalizeBus(row({ DutyStatus: '2' })), null);
  assert.equal(normalizeBus(row({ Longitude: '0' })), null);
  const bus = normalizeBus(row(), { Id: 'parent-1', pathAttributeName: '235', destinationZh: '國父紀念館' });
  assert.equal(bus.id, 'physical-1'); assert.equal(bus.routeName, '235'); assert.equal(bus.destination, '國父紀念館');
});

test('road matching and interpolation preserve a corner instead of cutting through its block', () => {
  const road = [[121.55, 25.04], [121.551, 25.04], [121.551, 25.041]];
  const line = prepareLine(road);
  const from = snapToLine([121.5501, 25.04001], line, 90), to = snapToLine([121.55101, 25.0409], line, 0);
  assert.ok(from && to);
  const route = lineSlice(line, from, to);
  assert.deepEqual(route[1], road[1]);
  const length = route.slice(1).reduce((sum, p, i) => sum + meters(route[i], p), 0);
  const midpoint = pointAtDistance(route, length / 2).position;
  assert.ok(Math.abs(midpoint[0] - 121.551) < 0.00001 || Math.abs(midpoint[1] - 25.04) < 0.00001);
  assert.equal(snapToLine([121.553, 25.045], line), null, 'far GPS must not be silently moved to a road');
  assert.deepEqual(lineSlice(line, to, from), [...route].reverse());
});

test('a physical vehicle changes route without interpolating across town; stale GPS freezes', () => {
  const motion = new VehicleMotion();
  const now = Date.now();
  const bus = { id: 'one', routeId: '235', direction: '0', observedAt: now - 15000, position: [121.55, 25.04], heading: 90, speed: 30 };
  motion.ingest([bus], 0);
  const changed = { ...bus, routeId: '212', observedAt: now, position: [121.56, 25.05], path: [bus.position, [121.56, 25.05]] };
  motion.ingest([changed], 1000);
  assert.deepEqual(motion.at('one', 1001).position, changed.position);
  const old = { ...changed, observedAt: now - 130000, position: [121.5601, 25.05], path: [changed.position, [121.5601, 25.05]] };
  motion.ingest([old], 2000);
  assert.deepEqual(motion.at('one', 2001).position, old.position);
  motion.ingest([], 3000); assert.equal(motion.at('one'), null);
});

test('repeated snapshots cannot restart the same movement', () => {
  const motion = new VehicleMotion(); const now = Date.now();
  const start = { id: 'one', routeId: '235', direction: '0', observedAt: now - 10000, position: [121.55, 25.04], speed: 20, heading: 90 };
  const end = { ...start, observedAt: now, position: [121.551, 25.04], path: [start.position, [121.551, 25.04]] };
  motion.ingest([start], 0); motion.ingest([end], 1000);
  const middle = motion.at('one', 4000);
  motion.ingest([end], 4500);
  assert.equal(motion.states.get('one').start, 1000);
  assert.ok(motion.at('one', 5000).position[0] > middle.position[0]);
});

test('collector updates without any viewer; outages preserve source time and last real position', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'taipei-bus-test-'));
  let failure = false, next = row(), routeFetches = 0;
  const fetchFeed = async name => {
    if (name === 'GetRoute') { routeFetches++; return { rows: [{ Id: 'parent-1', pathAttributeId: 'sub-1', pathAttributeName: '235', destinationZh: '國父紀念館' }] }; }
    if (name === 'GetBusShape') return { rows: [{ RouteID: 'parent-1', SubRouteID: -1, wkt: 'LINESTRING (121.55 25.04,121.551 25.04,121.551 25.041)' }] };
    if (failure) throw new Error('source offline');
    return { rows: [next, { ...next, DataTime: new Date(Date.parse(next.DataTime) - 1000).toISOString() }], updateTime: Date.parse(next.DataTime) };
  };
  const collector = new BusCollector({ fetchFeed, cachePath: path.join(directory, 'snapshot.json') });
  try {
    await collector.start(); assert.equal(collector.listenerCount('snapshot'), 0);
    assert.equal(collector.snapshot.vehicles.length, 1); assert.equal(collector.snapshot.polls, 1);
    assert.equal(collector.snapshot.vehicles[0].routeName, '235'); assert.equal(routeFetches, 1);
    next = row({ Longitude: '121.551', Latitude: '25.0408', DataTime: new Date(Date.parse(next.DataTime) + 10000).toISOString(), Azimuth: '0' });
    await collector.poll(); assert.equal(collector.snapshot.polls, 2);
    assert.equal(collector.snapshot.vehicles[0].path.length, 3);
    const snapshot = collector.snapshot;
    failure = true; await collector.poll();
    assert.equal(collector.snapshot.error, 'source offline');
    assert.equal(collector.snapshot.sourceUpdatedAt, snapshot.sourceUpdatedAt);
    assert.equal(collector.snapshot.receivedAt, snapshot.receivedAt);
    assert.deepEqual(collector.snapshot.vehicles, snapshot.vehicles);
  } finally { collector.stop(); await rm(directory, { recursive: true, force: true }); }
});

test('station estimates stay at route level and branch stop lists follow the official path ids', async () => {
  const collector = new BusCollector({ fetchFeed: async name => ({
    rows: name === 'GetRoute' ? [{ Id: 200, pathAttributeId: 201, nameZh: '235', pathAttributeName: '235 區間', destinationZh: '新莊', departureZh: '台北' }] :
      name === 'GetStop' ? [
        { Id: 1, routeId: 200, nameZh: '國父紀念館', seqNo: 10, goBack: '0', longitude: '121.56', latitude: '25.04', stopLocationId: 77, address: '仁愛路東向' },
        { Id: 2, routeId: 200, nameZh: '光復路口', seqNo: 11, goBack: '0', longitude: '121.558', latitude: '25.04', stopLocationId: 78 },
        { Id: 3, routeId: 200, nameZh: '區間不停靠站', seqNo: 12, goBack: '0', longitude: '121.559', latitude: '25.04', stopLocationId: 79 }
      ] : name === 'GetPathDetail' ? [
        { pathAttributeId: 201, stopId: 2, sequenceNo: 1, type: '0' },
        { pathAttributeId: 201, stopId: 1, sequenceNo: 2, type: '0' }
      ] : [{ RouteID: 200, StopID: 1, EstimateTime: '194' }, { RouteID: 200, StopID: 2, EstimateTime: '' }],
    updateTime: Date.now()
  }) });
  await Promise.all([collector.refreshRoutes(), collector.refreshStops(), collector.refreshPaths(), collector.refreshEstimates()]);
  const route = collector.routeStops('201', '0');
  assert.equal(route.serviceMatched, true); assert.deepEqual(route.stops.map(stop => stop.id), ['2', '1']);
  assert.equal(route.stops[0].estimateSeconds, null); assert.equal(route.stops[1].estimateSeconds, 194);
  collector.snapshot.vehicles = [normalizeBus(row({ RouteID: '201', Longitude: '121.5601', Latitude: '25.04' }), collector.routes.get('201'))];
  const station = collector.stationArrivals('77');
  assert.equal(station.arrivals[0].estimateSeconds, 194);
  assert.equal(station.arrivals[0].nearbyVehicles[0].plate, 'ABC-123');
  assert.equal(station.arrivals[0].nearbyVehicles[0].estimateSeconds, undefined, 'a route ETA must not be assigned to a physical bus');
  assert.equal(collector.nearbyStops([121.56, 25.04], '國父')[0].id, '77');
});
