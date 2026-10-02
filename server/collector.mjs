import { gunzipSync } from 'node:zlib';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { EventEmitter } from 'node:events';
import { parseTaipeiTime, parseLineString, prepareLine, snapToLine, lineSlice, normalizeBus, distanceMeters } from './geo.mjs';

const BASE = 'https://tcgbusfs.blob.core.windows.net/blobbus/';
export const SOURCE = '臺北市公共運輸處';

export async function readFeed(name) {
  const response = await fetch(`${BASE}${name}.gz`, { signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw new Error(`公開資料回應 ${response.status}`);
  let bytes = Buffer.from(await response.arrayBuffer());
  // Some HTTP intermediaries decompress the blob automatically.
  if (bytes[0] === 0x1f && bytes[1] === 0x8b) bytes = gunzipSync(bytes);
  const data = JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, ''));
  return { rows: Array.isArray(data) ? data : data.BusInfo, updateTime: Array.isArray(data) ? null : parseTaipeiTime(data.EssentialInfo?.UpdateTime) };
}

export class BusCollector extends EventEmitter {
  constructor({ interval = 15000, fetchFeed = readFeed, cachePath = 'work/latest-buses.json' } = {}) {
    super(); this.interval = Math.max(10000, interval); this.fetchFeed = fetchFeed; this.cachePath = cachePath;
    this.routes = new Map(); this.parentRoutes = new Map(); this.providers = new Map(); this.shapes = new Map(); this.previous = new Map();
    this.stops = new Map(); this.stationLocations = new Map(); this.paths = new Map(); this.estimates = new Map(); this.estimateUpdatedAt = null; this.estimateError = null;
    this.snapshot = { source: SOURCE, vehicles: [], receivedAt: null, sourceUpdatedAt: null, error: null, polls: 0 };
  }
  async start() {
    try { this.snapshot = { ...this.snapshot, ...JSON.parse(await readFile(this.cachePath, 'utf8')), error: '正在重新連線資料來源' }; } catch {}
    await Promise.allSettled([this.refreshRoutes(), this.refreshShapes(), this.refreshStops(), this.refreshPaths(), this.refreshProviders()]);
    await this.poll();
    this.timer = setInterval(() => void this.poll(), this.interval);
    this.metadataTimer = setInterval(() => void Promise.allSettled([this.refreshRoutes(), this.refreshShapes(), this.refreshStops(), this.refreshPaths(), this.refreshProviders()]), 24 * 60 * 60 * 1000);
  }
  stop() { clearInterval(this.timer); clearInterval(this.metadataTimer); }
  async refreshRoutes() {
    const { rows } = await this.fetchFeed('GetRoute');
    if (!Array.isArray(rows) || !rows.length) throw new Error('路線資料格式錯誤');
    for (const row of rows) { this.routes.set(String(row.pathAttributeId), row); this.parentRoutes.set(String(row.Id), row); }
  }
  async refreshProviders() {
    const { rows } = await this.fetchFeed('GetProvider');
    if (!Array.isArray(rows)) throw new Error('業者資料格式錯誤');
    this.providers = new Map(rows.filter(row => row.id && row.nameZn).map(row => [String(row.id), row.nameZn]));
  }
  async refreshShapes() {
    const { rows } = await this.fetchFeed('GetBusShape');
    if (!Array.isArray(rows) || !rows.length) throw new Error('路線軌跡格式錯誤');
    for (const row of rows) {
      const coordinates = parseLineString(row.wkt);
      if (!coordinates) continue;
      const key = Number(row.SubRouteID) > 0 ? `sub:${row.SubRouteID}` : `route:${row.RouteID}`;
      this.shapes.set(key, { ...prepareLine(coordinates), key });
    }
  }
  getLine(routeId) {
    const route = this.routes.get(String(routeId)) || this.parentRoutes.get(String(routeId));
    return this.shapes.get(`sub:${routeId}`) || this.shapes.get(`route:${route?.Id || routeId}`);
  }
  async refreshStops() {
    const { rows } = await this.fetchFeed('GetStop');
    if (!Array.isArray(rows)) throw new Error('站點資料格式錯誤');
    const stops = new Map();
    const stations = new Map();
    for (const row of rows) {
      const position = [Number(row.longitude), Number(row.latitude)];
      if (!row.Id || position.some(n => !Number.isFinite(n))) continue;
      const stop = { id: String(row.Id), routeId: String(row.routeId), name: row.nameZh, sequence: Number(row.seqNo), direction: String(row.goBack), position };
      stops.set(stop.id, stop);
      const locationId = String(row.stopLocationId || row.Id);
      if (!stations.has(locationId)) stations.set(locationId, { id: locationId, name: row.nameZh, position, address: row.address || '', bearing: row.bearing || '', stopIds: [] });
      stations.get(locationId).stopIds.push(stop.id);
    }
    this.stops = stops;
    this.stationLocations = stations;
  }
  async refreshPaths() {
    const { rows } = await this.fetchFeed('GetPathDetail');
    if (!Array.isArray(rows)) throw new Error('附屬路線站點格式錯誤');
    const paths = new Map();
    for (const row of rows) {
      const type = row.type ?? row.Type;
      if (type && String(type) !== '0') continue;
      const id = String(row.pathAttributeId ?? row.PathAttributeId);
      if (!paths.has(id)) paths.set(id, []);
      paths.get(id).push({ stopId: String(row.stopId ?? row.StopId), sequence: Number(row.sequenceNo ?? row.SequenceNo) });
    }
    this.paths = paths;
  }
  async refreshEstimates() {
    try {
      const { rows, updateTime } = await this.fetchFeed('GetEstimateTime');
      if (!Array.isArray(rows) || !rows.length || !updateTime) throw new Error('到站預估資料尚未提供');
      const estimates = new Map();
      for (const row of rows) {
        const seconds = row.EstimateTime == null || !String(row.EstimateTime).trim() ? NaN : Number(row.EstimateTime);
        if (Number.isFinite(seconds)) estimates.set(`${row.RouteID}:${row.StopID}`, seconds);
      }
      this.estimates = estimates; this.estimateUpdatedAt = updateTime; this.estimateError = null;
    } catch (error) { this.estimateError = error.message; }
  }
  routeStops(routeId, direction) {
    const route = this.routes.get(String(routeId)) || this.parentRoutes.get(String(routeId));
    const parentId = String(route?.Id || routeId);
    const path = this.paths.get(String(routeId));
    const ordered = path?.length ? path.map(item => ({ ...this.stops.get(item.stopId), sequence: item.sequence })).filter(stop => stop.id) : [...this.stops.values()].filter(stop => stop.routeId === parentId);
    const stops = ordered.filter(stop => stop.direction === String(direction)).sort((a, b) => a.sequence - b.sequence).map(stop => ({ ...stop, estimateSeconds: this.estimates.get(`${parentId}:${stop.id}`) ?? null }));
    return { routeId, direction, serviceMatched: !!path?.length, updatedAt: this.estimateUpdatedAt, error: this.estimateError, stops };
  }
  nearbyStops(position, query = '') {
    const search = String(query).toLowerCase().trim();
    return [...this.stationLocations.values()].filter(stop => !search || stop.name.toLowerCase().includes(search) || stop.address.toLowerCase().includes(search)).map(stop => ({ id: stop.id, name: stop.name, position: stop.position, address: stop.address, bearing: stop.bearing, distance: Math.round(distanceMeters(position, stop.position)) })).sort((a, b) => a.distance - b.distance).slice(0, 35);
  }
  stationArrivals(id) {
    const station = this.stationLocations.get(String(id));
    if (!station) return null;
    const seen = new Set(), arrivals = [];
    for (const stopId of station.stopIds) {
      const stop = this.stops.get(stopId), route = this.parentRoutes.get(stop.routeId);
      const key = `${stop.routeId}:${stop.direction}`;
      if (seen.has(key)) continue; seen.add(key);
      const nearbyVehicles = this.snapshot.vehicles.filter(bus => {
        const path = this.paths.get(bus.routeId);
        return bus.parentRouteId === stop.routeId && bus.direction === stop.direction && Date.now() - bus.observedAt < 120000 && (!path?.length || path.some(item => item.stopId === stopId));
      }).map(bus => ({ id: bus.id, plate: bus.plate, routeId: bus.routeId, distance: Math.round(distanceMeters(bus.rawPosition, station.position)), observedAt: bus.observedAt })).sort((a, b) => a.distance - b.distance).slice(0, 2);
      arrivals.push({ routeId: String(route?.pathAttributeId || stop.routeId), parentRouteId: stop.routeId, routeName: route?.nameZh || stop.routeId, direction: stop.direction, destination: stop.direction === '0' ? route?.destinationZh || '去程' : route?.departureZh || '回程', estimateSeconds: this.estimates.get(`${stop.routeId}:${stopId}`) ?? null, nearbyVehicles });
    }
    arrivals.sort((a, b) => (a.estimateSeconds == null || a.estimateSeconds < 0 ? Infinity : a.estimateSeconds) - (b.estimateSeconds == null || b.estimateSeconds < 0 ? Infinity : b.estimateSeconds));
    return { station: { id: station.id, name: station.name, position: station.position, address: station.address, bearing: station.bearing }, updatedAt: this.estimateUpdatedAt, error: this.estimateError, arrivals };
  }
  routeFeature(routeId) {
    const line = this.getLine(routeId);
    return line ? { type: 'Feature', properties: { routeId }, geometry: { type: 'LineString', coordinates: line.coordinates } } : null;
  }
  async poll() {
    if (this.busy) return;
    this.busy = true;
    try {
      const [vehicleResult] = await Promise.allSettled([this.fetchFeed('GetBusData'), this.refreshEstimates()]);
      if (vehicleResult.status === 'rejected') throw vehicleResult.reason;
      const { rows, updateTime } = vehicleResult.value;
      if (!Array.isArray(rows) || !rows.length) throw new Error('車輛資料格式錯誤');
      const now = Date.now(), unique = new Map();
      for (const row of rows) {
        const route = this.routes.get(String(row.RouteID)) || this.parentRoutes.get(String(row.RouteID));
        const bus = normalizeBus(row, route, now);
        if (!bus) continue;
        bus.provider = this.providers.get(String(row.ProviderID)) || null;
        const old = this.previous.get(bus.id), line = this.getLine(bus.routeId);
        const snap = line ? snapToLine(bus.position, line, bus.speed > 2 ? bus.heading : null) : null;
        if (snap) { bus.position = snap.position; bus.aligned = true; }
        bus.path = [bus.position];
        if (old && old.bus.routeId === bus.routeId && old.bus.direction === bus.direction && bus.observedAt > old.bus.observedAt && bus.observedAt - old.bus.observedAt <= 60000) {
          const distance = distanceMeters(old.bus.position, bus.position);
          if (snap && old.snap && old.lineKey === line.key && Math.abs(snap.along - old.snap.along) < Math.max(100, distance * 2.5) && distance < 1000) bus.path = lineSlice(line, old.snap, snap);
          // Avoid a straight interpolation across a block when no matched route is available.
        }
        const existing = unique.get(bus.id);
        if (!existing || bus.observedAt > existing.bus.observedAt) unique.set(bus.id, { bus, snap, lineKey: line?.key });
      }
      if (!unique.size) throw new Error('資料中沒有有效的近期營運車輛');
      this.previous = unique;
      this.snapshot = { source: SOURCE, vehicles: [...unique.values()].map(x => x.bus), receivedAt: now, sourceUpdatedAt: updateTime, error: null, polls: this.snapshot.polls + 1 };
      await mkdir('work', { recursive: true });
      await writeFile(this.cachePath, JSON.stringify(this.snapshot));
    } catch (error) {
      this.snapshot = { ...this.snapshot, error: error.message };
    } finally {
      this.busy = false; this.emit('snapshot', this.snapshot);
    }
  }
}
