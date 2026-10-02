const METERS_PER_DEGREE = 111320;

export function parseTaipeiTime(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  const normalized = value.trim().replaceAll('/', '-').replace(' ', 'T');
  const zoned = /(?:Z|[+-]\d{2}:?\d{2})$/.test(normalized) ? normalized : `${normalized}+08:00`;
  const millis = Date.parse(zoned);
  return Number.isFinite(millis) ? millis : null;
}

export function distanceMeters(a, b) {
  const cosine = Math.cos((a[1] + b[1]) * Math.PI / 360);
  return Math.hypot((a[0] - b[0]) * cosine, a[1] - b[1]) * METERS_PER_DEGREE;
}

export function bearing(a, b) {
  return (Math.atan2((b[0] - a[0]) * Math.cos(a[1] * Math.PI / 180), b[1] - a[1]) * 180 / Math.PI + 360) % 360;
}

export function parseLineString(wkt) {
  if (typeof wkt !== 'string' || !/^LINESTRING\s*\(/i.test(wkt)) return null;
  const coordinates = wkt.slice(wkt.indexOf('(') + 1, wkt.lastIndexOf(')')).split(',').map(pair => pair.trim().split(/\s+/).slice(0, 2).map(Number));
  if (coordinates.length < 2 || coordinates.some(p => p.length !== 2 || p.some(n => !Number.isFinite(n)))) return null;
  return coordinates;
}

export function prepareLine(coordinates) {
  const cumulative = [0];
  for (let i = 1; i < coordinates.length; i++) cumulative.push(cumulative[i - 1] + distanceMeters(coordinates[i - 1], coordinates[i]));
  return { coordinates, cumulative, length: cumulative.at(-1) };
}

export function snapToLine(point, line, heading = null) {
  const cosine = Math.cos(point[1] * Math.PI / 180);
  let best = null;
  for (let i = 0; i < line.coordinates.length - 1; i++) {
    const a = line.coordinates[i], b = line.coordinates[i + 1];
    if (point[0] < Math.min(a[0], b[0]) - .00065 || point[0] > Math.max(a[0], b[0]) + .00065 || point[1] < Math.min(a[1], b[1]) - .00065 || point[1] > Math.max(a[1], b[1]) + .00065) continue;
    const dx = (b[0] - a[0]) * cosine, dy = b[1] - a[1];
    const lengthSq = dx * dx + dy * dy;
    if (!lengthSq) continue;
    const t = Math.max(0, Math.min(1, ((point[0] - a[0]) * cosine * dx + (point[1] - a[1]) * dy) / lengthSq));
    const position = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
    const distance = distanceMeters(point, position);
    // Shape data may include both directions. Use the smaller of either travel bearing.
    const segmentHeading = bearing(a, b);
    const forwardAngle = heading == null ? 0 : Math.abs(((segmentHeading - heading + 540) % 360) - 180);
    const angle = Math.min(forwardAngle, 180 - forwardAngle);
    const score = distance + angle * .18;
    if (!best || score < best.score) best = { position, distance, score, segment: i, along: line.cumulative[i] + (line.cumulative[i + 1] - line.cumulative[i]) * t };
  }
  return best && best.distance <= 40 ? best : null;
}

export function lineSlice(line, from, to) {
  const reverse = from.along > to.along;
  const start = reverse ? to : from, end = reverse ? from : to;
  const coordinates = [start.position];
  for (let i = start.segment + 1; i <= end.segment; i++) coordinates.push(line.coordinates[i]);
  coordinates.push(end.position);
  return reverse ? coordinates.reverse() : coordinates;
}

export function normalizeBus(row, route, now = Date.now()) {
  const position = [Number(row.Longitude), Number(row.Latitude)];
  const observedAt = parseTaipeiTime(row.DataTime);
  if (!row.BusID || position.some(n => !Number.isFinite(n)) || position[0] < 121.4 || position[0] > 121.72 || position[1] < 24.94 || position[1] > 25.23 || !observedAt || observedAt > now + 60000 || now - observedAt > 15 * 60000 || String(row.BusStatus) === '99' || String(row.DutyStatus) === '2') return null;
  const heading = Number(row.Azimuth), speed = Number(row.Speed);
  const direction = String(row.GoBack);
  return {
    id: String(row.CarID || row.BusID), plate: String(row.BusID), routeId: String(row.RouteID),
    parentRouteId: String(route?.Id || row.RouteID), routeName: route?.pathAttributeName || route?.nameZh || String(row.RouteID), mainRouteName: route?.nameZh || route?.pathAttributeName || String(row.RouteID),
    direction, destination: direction === '0' ? route?.destinationZh || '去程' : direction === '1' ? route?.departureZh || '回程' : '方向未提供',
    position, rawPosition: position, heading: Number.isFinite(heading) ? ((heading % 360) + 360) % 360 : 0,
    speed: Number.isFinite(speed) && speed >= 0 && speed < 180 ? speed : 0, observedAt,
    status: String(row.BusStatus), carType: String(row.CarType ?? ''), provider: route?.providerName || null, aligned: false, demo: false
  };
}
