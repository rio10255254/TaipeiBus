import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { BusCollector } from './collector.mjs';

for (const name of ['.env', '.env.local']) { try { process.loadEnvFile(name); } catch {} }
const port = Number(process.env.PORT || 4173);
const production = process.argv.includes('--production');
const collector = new BusCollector({ interval: Number(process.env.BUS_POLL_INTERVAL_MS || 15000) });
const clients = new Set();
const json = (res, data, status = 200) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(data)); };
let vite;
if (!production) {
  const { createServer } = await import('vite');
  vite = await createServer({ server: { middlewareMode: true, host: '0.0.0.0' }, appType: 'spa' });
}
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/config') return json(res, { engine: process.env.MAPBOX_PUBLIC_TOKEN ? 'mapbox' : 'maplibre', mapboxToken: process.env.MAPBOX_PUBLIC_TOKEN || null, pollInterval: collector.interval });
    if (url.pathname === '/api/snapshot') return json(res, collector.snapshot);
    if (url.pathname === '/api/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
      res.write(`data: ${JSON.stringify(collector.snapshot)}\n\n`); clients.add(res);
      req.on('close', () => clients.delete(res)); return;
    }
    if (url.pathname.startsWith('/api/stops/')) return json(res, collector.routeStops(decodeURIComponent(url.pathname.slice('/api/stops/'.length)), url.searchParams.get('direction') || '0'));
    if (url.pathname === '/api/nearby-stops') {
      const position = [Number(url.searchParams.get('lon')), Number(url.searchParams.get('lat'))];
      if (position.some(n => !Number.isFinite(n)) || Math.abs(position[0]) > 180 || Math.abs(position[1]) > 90) return json(res, { error: '位置格式錯誤' }, 400);
      return json(res, { stops: collector.nearbyStops(position, url.searchParams.get('q') || '') });
    }
    if (url.pathname.startsWith('/api/stations/')) {
      const arrivals = collector.stationArrivals(decodeURIComponent(url.pathname.slice('/api/stations/'.length)));
      return json(res, arrivals || { error: '站牌不存在' }, arrivals ? 200 : 404);
    }
    if (url.pathname.startsWith('/api/routes/')) {
      const route = collector.routeFeature(decodeURIComponent(url.pathname.slice('/api/routes/'.length)));
      return json(res, route || { error: '此路線尚無可用軌跡' }, route ? 200 : 404);
    }
    if (url.pathname === '/api/health') return json(res, { ok: true, vehicles: collector.snapshot.vehicles.length, polls: collector.snapshot.polls, clients: clients.size, error: collector.snapshot.error });
    if (vite) return vite.middlewares(req, res);
    const relative = decodeURIComponent(url.pathname).replace(/^\/+/, '') || 'index.html';
    const absolute = path.resolve('dist', relative);
    if (!absolute.startsWith(path.resolve('dist') + path.sep) && absolute !== path.resolve('dist')) return json(res, { error: 'Invalid path' }, 400);
    let file; try { file = await readFile(absolute); } catch { if (path.extname(relative)) return json(res, { error: 'Not found' }, 404); file = await readFile('dist/index.html'); }
    const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2' }[path.extname(relative)] || 'text/html';
    res.writeHead(200, { 'Content-Type': mime }); res.end(file);
  } catch { json(res, { error: '伺服器暫時無法處理請求' }, 500); }
});
collector.on('snapshot', snapshot => {
  const event = `data: ${JSON.stringify(snapshot)}\n\n`;
  for (const client of clients) { if (client.writableLength > 2000000) { client.end(); clients.delete(client); } else client.write(event); }
});
const heartbeat = setInterval(() => { for (const client of clients) client.write(': heartbeat\n\n'); }, 15000);
server.listen(port, '0.0.0.0', () => {
  console.log(`Bus preview: http://localhost:${port}`);
  for (const addresses of Object.values(os.networkInterfaces())) for (const address of addresses || []) if (address.family === 'IPv4' && !address.internal) console.log(`Phone preview: http://${address.address}:${port}`);
  void collector.start().then(() => console.log(`Live collector: ${collector.snapshot.vehicles.length} vehicles, ${collector.shapes.size} route shapes`));
});
async function stop() { clearInterval(heartbeat); collector.stop(); for (const client of clients) client.end(); await vite?.close(); server.close(() => process.exit(0)); }
process.on('SIGINT', stop); process.on('SIGTERM', stop);
