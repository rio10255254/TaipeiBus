import * as maplibre from 'maplibre-gl';
import workerURL from 'maplibre-gl/dist/maplibre-gl-worker.mjs?worker&url';
import './styles.css';
import { BusLayer } from './bus-layer.js';
import { VehicleMotion, meters, pointAtDistance } from './motion.js';

const $ = id => document.getElementById(id);
const emptyRoute = { type: 'FeatureCollection', features: [] };
const motion = new VehicleMotion();
let map, layer, engine, liveSnapshot, demoVehicles = [], mode = 'live', selectedId = null;
let lastSelected, following = false, loaded = false, connected = false, firstLive = true, routeRequest = 0;
let query = '', toastTimer, cameraTick = 0;
let pollSeconds = 15;
let clarityEnabled = true, buildingOpacity = null;
let view = 'stops', activeRoute = null, station = null, stationData = null, nearbyStations = [];
let userPosition = null, stationRequest = 0, stationSearchTimer, routeStopsData = null, arrivalStopId = null, detailRequest = 0, locating = false;
const savedId = (() => { try { return localStorage.getItem('taipei-bus:last-id'); } catch { return null; } })();
const normal = value => String(value).toLowerCase().replace(/[\s-]/g, '');
const routeMatches = bus => !activeRoute || bus.parentRouteId === activeRoute.id || bus.routeId === activeRoute.id;
const matches = bus => routeMatches(bus) && (view === 'stops' || !query || normal(bus.routeName).includes(query) || normal(bus.plate).includes(query));
const currentVehicles = () => mode === 'demo' ? demoVehicles : liveSnapshot?.vehicles || [];
const isStale = bus => !bus.demo && Date.now() - bus.observedAt > 120000;
const ageText = bus => bus.demo ? '模擬定位' : Date.now() - bus.observedAt < 60000 ? `${Math.max(0, Math.floor((Date.now() - bus.observedAt) / 1000))} 秒前` : `${Math.floor((Date.now() - bus.observedAt) / 60000)} 分鐘前`;
const states = { '0': '正常', '1': '事故', '2': '故障', '3': '壅塞', '4': '緊急事件', '5': '加油中' };
const bearingText = value => ({ N: '北向', NE: '東北向', E: '東向', SE: '東南向', S: '南向', SW: '西南向', W: '西向', NW: '西北向' })[value] || '';
const clock = time => time ? new Date(time).toLocaleTimeString('zh-TW', { timeZone: 'Asia/Taipei', hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '—';
const estimateText = (seconds, time, error) => {
  if (error || !time || Date.now() - time > 120000 || seconds == null) return '暫無資料';
  if (seconds < 0) return ({ '-1': '尚未發車', '-2': '交管不停靠', '-3': '末班已過', '-4': '今日未營運' })[seconds] || '暫無資料';
  return seconds <= 60 ? '1 分鐘內' : `${Math.ceil(seconds / 60)} 分鐘`;
};
const distanceText = distance => distance >= 1000 ? `${(distance / 1000).toFixed(1)} km` : `${Math.round(distance)} m`;

function closeMobileSheets() {
  $('app').classList.remove('show-search', 'show-detail'); $('mobile-scrim').hidden = true;
  $('mobile-close-search').hidden = true; $('search').blur();
}
function openMobileSearch(next) {
  if (next) { if (next === 'stops') { station = null; stationData = null; } setView(next); }
  $('app').classList.remove('show-detail'); $('app').classList.add('show-search');
  $('mobile-scrim').hidden = false; $('mobile-close-search').hidden = false;
  $('search').focus();
}
function updateNearbyMap() {
  map?.getSource('nearby-stations')?.setData({ type: 'FeatureCollection', features: nearbyStations.filter(s => s.distance < 1500).slice(0, 18).map(s => ({ type: 'Feature', properties: { id: s.id, name: `${s.name} ${bearingText(s.bearing)}` }, geometry: { type: 'Point', coordinates: s.position } })) });
}
function renderMapInfo() {
  const bus = selectedId && motion.at(selectedId);
  const visible = !!(bus || station || activeRoute);
  $('world-info').hidden = !visible; $('mobile-clear').hidden = !visible; $('mobile-follow').hidden = !bus; $('mobile-routes').hidden = !!bus;
  $('mobile-follow').classList.toggle('active', following);
  $('world-arrivals').replaceChildren();
  $('world-info').classList.toggle('route-context', !bus && !station && !!activeRoute);
  $('world-caption').textContent = '';
  if (bus) {
    $('world-title').textContent = bus.routeName; $('world-subtitle').textContent = `往 ${bus.destination}`;
    $('world-meta').textContent = `${bus.plate} · ${isStale(bus) ? '定位延遲' : `GPS ${Math.round(bus.speed)} km/h · ${ageText(bus)}`}`;
  } else if (station) {
    $('world-title').textContent = station.name; $('world-subtitle').textContent = bearingText(station.bearing); $('world-meta').textContent = '';
    for (const arrival of (stationData?.arrivals || []).slice(0, 2)) {
      const button = document.createElement('button'); button.className = 'eta-tag';
      const name = document.createElement('small'); name.textContent = arrival.routeName;
      const time = document.createElement('strong'); time.textContent = estimateText(arrival.estimateSeconds, stationData.updatedAt, stationData.error);
      button.append(name, time); button.onclick = () => void selectRoute(arrival.parentRouteId, arrival.routeName); $('world-arrivals').append(button);
    }
    $('world-caption').textContent = stationData ? '官方路線預估' : '取得預估中…';
  } else if (activeRoute) {
    $('world-title').textContent = activeRoute.name; $('world-subtitle').textContent = '路線動態';
    $('world-meta').textContent = `${currentVehicles().filter(b => routeMatches(b) && !isStale(b)).length} 輛近期回報 · 點車牌查看`;
  }
  positionMapInfo();
}
function positionMapInfo() {
  if (!loaded || $('world-info').hidden) { $('world-connector').style.display = 'none'; return; }
  const bus = selectedId && motion.at(selectedId);
  const anchor = bus?.position || station?.position;
  if (!anchor) { $('world-info').style.transform = 'translate(24px, 112px)'; $('world-connector').style.display = 'none'; return; }
  const p = map.project(anchor), width = map.getContainer().clientWidth, height = map.getContainer().clientHeight;
  const labelWidth = Math.min(286, width - 40), labelHeight = $('world-info').offsetHeight;
  const x = Math.max(20, Math.min(width - labelWidth - 20, p.x - labelWidth / 2));
  const y = Math.max(155, Math.min(height - 190 - labelHeight, p.y - labelHeight - 32));
  const inView = p.x >= -20 && p.x <= width + 20 && p.y >= -20 && p.y <= height + 20;
  $('world-info').style.visibility = inView ? 'visible' : 'hidden'; $('world-connector').style.display = inView ? 'block' : 'none';
  $('world-info').style.transform = `translate(${x}px, ${y}px)`;
  $('world-connector').querySelector('path').setAttribute('d', `M ${p.x} ${p.y} L ${p.x} ${p.y - 15} L ${x + labelWidth / 2} ${y + labelHeight + 8}`);
}

function toast(message) {
  $('toast').textContent = message; $('toast').hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').hidden = true, 4000);
}

function padding() {
  return { top: 155, bottom: 145, left: 35, right: 35 };
}

function focusBus(bus, immediate = false) {
  if (!loaded || !bus) return;
  map.easeTo({ center: bus.position, zoom: Math.max(map.getZoom(), 18.1), pitch: 52, padding: padding(), duration: immediate ? 0 : 900 });
}

function renderList() {
  if (view === 'stops' && mode === 'live') { renderStations(); return; }
  const center = map?.getCenter() || { lng: 121.5605, lat: 25.0377 };
  const rows = currentVehicles().filter(matches).sort((a, b) => meters(a.position, [center.lng, center.lat]) - meters(b.position, [center.lng, center.lat]));
  if (view === 'routes' && mode === 'live') { renderRoutes(rows); return; }
  $('list-title').textContent = activeRoute ? '此路線車輛' : query ? '搜尋結果' : mode === 'demo' ? '模擬車輛' : '地圖附近車輛';
  $('result-count').textContent = query ? `${rows.length} 輛` : `${Math.min(rows.length, 12)} / ${rows.length} 輛`;
  const list = $('bus-list');
  const scroll = list.scrollTop; list.replaceChildren();
  if (!rows.length) {
    const text = document.createElement('p'); text.className = 'empty-state';
    text.textContent = query ? '找不到這個路線或車牌，試試其他關鍵字。' : liveSnapshot ? '目前沒有可顯示的車輛定位。' : '正在取得車輛定位…'; list.append(text);
  }
  for (const bus of rows.slice(0, query || activeRoute ? 40 : 12)) {
    const row = document.createElement('button'); row.className = `bus-row${bus.id === selectedId ? ' selected' : ''}`; row.dataset.busId = bus.id;
    const route = document.createElement('span'); route.className = 'row-route'; route.textContent = bus.routeName;
    const copy = document.createElement('span'); copy.className = 'row-copy';
    const plate = document.createElement('strong'); plate.textContent = bus.plate;
    const direction = document.createElement('small'); direction.textContent = `往 ${bus.destination}${bus.demo ? ' · 模擬' : ''}`;
    copy.append(plate, direction);
    const speed = document.createElement('span'); speed.className = `row-speed${isStale(bus) ? ' stale' : ''}`;
    speed.textContent = isStale(bus) ? '已延遲' : `${Math.round(bus.speed)} km/h`;
    const age = document.createElement('small'); age.textContent = ageText(bus); speed.append(age);
    row.append(route, copy, speed); row.onclick = () => selectBus(bus.id); list.append(row);
  }
  list.scrollTop = scroll;
}

function listRow(routeName, primary, secondary, value, subtitle = '') {
  const row = document.createElement('button'); row.className = 'bus-row';
  const route = document.createElement('span'); route.className = 'row-route'; route.textContent = routeName;
  const copy = document.createElement('span'); copy.className = 'row-copy';
  const name = document.createElement('strong'); name.textContent = primary;
  const detail = document.createElement('small'); detail.textContent = secondary; copy.append(name, detail);
  const right = document.createElement('span'); right.className = 'row-speed'; right.textContent = value;
  if (subtitle) { const small = document.createElement('small'); small.textContent = subtitle; right.append(small); }
  row.append(route, copy, right); return row;
}

function renderRoutes(vehicles) {
  const groups = new Map();
  for (const bus of vehicles) {
    const id = bus.parentRouteId || bus.routeId;
    if (!groups.has(id)) groups.set(id, { id, name: bus.mainRouteName || bus.routeName, buses: [], nearest: bus });
    groups.get(id).buses.push(bus);
  }
  $('bus-list').replaceChildren(); $('list-title').textContent = query ? '路線搜尋結果' : '地圖附近路線'; $('result-count').textContent = `${groups.size} 條`;
  for (const route of [...groups.values()].slice(0, 35)) {
    const fresh = route.buses.filter(bus => !isStale(bus)).length;
    const row = listRow(route.name, `往 ${route.nearest.destination}`, `${route.buses.length} 輛回報 · ${fresh} 輛定位於 2 分鐘內`, '查看', '路線動態');
    row.dataset.routeId = route.id; row.onclick = () => void selectRoute(route.id, route.name); $('bus-list').append(row);
  }
  if (!groups.size) $('bus-list').textContent = liveSnapshot ? '找不到此路線的營運車輛。' : '正在載入路線…';
}

async function selectRoute(id, name) {
  closeMobileSheets();
  deselect(); activeRoute = { id: String(id), name: name || currentVehicles().find(bus => bus.parentRouteId === String(id))?.mainRouteName || String(id) };
  station = null; stationData = null; query = ''; $('search').value = ''; setView('vehicles'); updateFilters();
  const buses = currentVehicles().filter(routeMatches); renderList();
  try {
    const response = await fetch(`/api/routes/${encodeURIComponent(id)}`); const feature = response.ok ? await response.json() : null;
    if (activeRoute?.id !== String(id)) return;
    const coordinates = feature?.geometry?.coordinates || buses.map(bus => bus.position);
    if (feature) map.getSource('selected-route')?.setData(feature);
    if (coordinates.length > 1) { const bounds = new engine.LngLatBounds(); for (const point of coordinates) bounds.extend(point); map.fitBounds(bounds, { padding: padding(), maxZoom: 16, pitch: 30, duration: 1000 }); }
    else if (buses[0]) focusBus(buses[0]);
  } catch { if (buses[0]) focusBus(buses[0]); }
  map.triggerRepaint();
  renderMapInfo();
}

function updateFilters() {
  $('route-filter').hidden = !activeRoute; $('route-filter-name').textContent = activeRoute ? `${activeRoute.name} · 路線動態` : '';
  $('station-filter').hidden = !station || view !== 'stops'; $('station-filter-name').textContent = station ? `${station.name}${bearingText(station.bearing) ? ` · ${bearingText(station.bearing)}` : ''}` : '';
  $('arrival-scope').hidden = !station || view !== 'stops' || mode === 'demo';
  const features = [];
  if (userPosition) features.push({ type: 'Feature', properties: { kind: 'user' }, geometry: { type: 'Point', coordinates: userPosition } });
  if (station) features.push({ type: 'Feature', properties: { kind: 'stop' }, geometry: { type: 'Point', coordinates: station.position } });
  map?.getSource('user-and-stop')?.setData({ type: 'FeatureCollection', features });
}

function setView(next) {
  view = next; query = ''; $('search').value = '';
  $('app').classList.toggle('view-stops', view === 'stops');
  for (const item of ['routes', 'stops', 'vehicles']) { $(`view-${item}`).classList.toggle('active', item === view); $(`view-${item}`).setAttribute('aria-pressed', String(item === view)); }
  $('search').placeholder = view === 'stops' ? '搜尋站牌名稱或地址' : view === 'routes' ? '搜尋公車路線' : '搜尋車牌或路線';
  if (next === 'stops') { activeRoute = null; deselect(); if (!station) void searchStations(); else void refreshStation(); }
  updateFilters(); renderList(); map?.triggerRepaint();
}

async function searchStations() {
  const request = ++stationRequest; const center = map.getCenter(); const position = userPosition || [center.lng, center.lat];
  try {
    const result = await fetch(`/api/nearby-stops?lon=${position[0]}&lat=${position[1]}&q=${encodeURIComponent($('search').value)}`).then(r => r.json());
    if (request === stationRequest) { nearbyStations = result.stops || []; if (view === 'stops') renderStations(); updateNearbyMap(); }
  } catch { toast('站牌資料暫時無法取得。'); }
}

function renderStations() {
  const list = $('bus-list'); list.replaceChildren();
  if (station) {
    $('list-title').textContent = `往此站的公車 · ${clock(stationData?.updatedAt)} 更新`; $('result-count').textContent = `${stationData?.arrivals.length || 0} 條`;
    for (const arrival of stationData?.arrivals || []) {
      const vehicle = arrival.nearbyVehicles[0];
      const secondary = vehicle ? `附近 ${vehicle.plate} · 距站 ${distanceText(vehicle.distance)}` : '尚無近期車輛定位';
      const row = listRow(arrival.routeName, `往 ${arrival.destination}`, secondary, estimateText(arrival.estimateSeconds, stationData.updatedAt, stationData.error), '官方預估');
      row.classList.add('arrival-row');
      row.onclick = () => void selectRoute(arrival.parentRouteId, arrival.routeName); row.dataset.arrivalRoute = arrival.parentRouteId; list.append(row);
    }
    if (!stationData) list.textContent = '正在取得到站預估…';
    else if (!stationData.arrivals.length) list.textContent = '此站暫無可用路線資料。';
  } else {
    $('list-title').textContent = query ? '站牌搜尋結果' : userPosition ? '附近站牌 · 直線距離' : '地圖附近站牌 · 直線距離'; $('result-count').textContent = `${nearbyStations.length} 站`;
    for (const stop of nearbyStations) {
      const row = listRow(bearingText(stop.bearing) || '站', stop.name, stop.address || bearingText(stop.bearing), distanceText(stop.distance), userPosition ? '距你' : '距地圖中心');
      row.dataset.stationId = stop.id; row.onclick = () => selectStation(stop); list.append(row);
    }
    if (!nearbyStations.length) list.textContent = '找不到此站牌，請試試其他名稱。';
  }
}

function selectStation(stop) {
  deselect(); activeRoute = null; closeMobileSheets();
  station = stop; stationData = null; query = ''; $('search').value = ''; updateFilters(); renderStations();
  map.easeTo({ center: stop.position, zoom: 17.4, pitch: 48, padding: padding(), duration: 900 }); void refreshStation(); renderMapInfo();
}

async function refreshStation() {
  if (!station || mode !== 'live') return;
  const id = station.id;
  try { const result = await fetch(`/api/stations/${encodeURIComponent(id)}`).then(r => r.json()); if (station?.id === id && result.arrivals) { stationData = result; if (view === 'stops') renderStations(); renderMapInfo(); } }
  catch { if (station?.id === id) { stationData = { arrivals: [], error: '連線中斷' }; renderStations(); } }
}

function locationReady(position) {
  locating = false; $('locate-user').disabled = false; $('locate-user').classList.remove('loading');
  const coords = position.coords || position; userPosition = [coords.longitude, coords.latitude];
  station = null; stationData = null; setView('stops'); map.easeTo({ center: userPosition, zoom: 16, pitch: 35, padding: padding(), duration: 1000 });
  updateFilters(); void searchStations();
}

function locationFailed() {
  locating = false; $('locate-user').disabled = false; $('locate-user').classList.remove('loading');
  setView('stops'); toast('未取得位置，可搜尋站牌名稱，或選擇地圖附近的站牌。');
}

function locateUser() {
  if (locating) return; locating = true; $('locate-user').disabled = true; $('locate-user').classList.add('loading');
  if (window.webkit?.messageHandlers?.requestLocation) { window.webkit.messageHandlers.requestLocation.postMessage({}); return; }
  if (!navigator.geolocation) { locationFailed(); return; }
  navigator.geolocation.getCurrentPosition(locationReady, locationFailed, { enableHighAccuracy: false, timeout: 12000, maximumAge: 60000 });
}

async function refreshDetailStops() {
  const bus = motion.at(selectedId); const request = ++detailRequest;
  if (!bus || bus.demo) { routeStopsData = null; $('arrival-panel').hidden = true; return; }
  try {
    const result = await fetch(`/api/stops/${encodeURIComponent(bus.routeId)}?direction=${encodeURIComponent(bus.direction)}`).then(r => r.json());
    if (request !== detailRequest || selectedId !== bus.id) return;
    routeStopsData = result;
    if (!result.stops?.some(stop => stop.id === arrivalStopId)) arrivalStopId = [...(result.stops || [])].sort((a, b) => meters(a.position, bus.rawPosition) - meters(b.position, bus.rawPosition))[0]?.id;
    const select = $('arrival-stop'); select.replaceChildren();
    for (const stop of result.stops || []) { const option = document.createElement('option'); option.value = stop.id; option.textContent = stop.name; select.append(option); }
    if (arrivalStopId) select.value = arrivalStopId;
    renderArrivalDetail(bus);
  } catch { if (selectedId === bus.id) { routeStopsData = null; $('arrival-panel').hidden = true; } }
}

function renderArrivalDetail(bus) {
  const stop = routeStopsData?.stops?.find(item => item.id === arrivalStopId);
  $('arrival-panel').hidden = !stop || bus.demo;
  if (!stop) return;
  $('arrival-title').textContent = routeStopsData.serviceMatched ? '此路線 · 站點到站預估' : '主路線 · 站點到站預估';
  $('arrival-time').textContent = estimateText(stop.estimateSeconds, routeStopsData.updatedAt, routeStopsData.error);
  $('arrival-distance').textContent = `距此車約 ${distanceText(meters(bus.rawPosition, stop.position))}（直線）`;
  $('arrival-note').textContent = `${clock(routeStopsData.updatedAt)} 更新 · 路線預估未綁定車牌`;
}

function renderDetail() {
  $('vehicle-detail').hidden = !selectedId; $('app').classList.toggle('has-selection', !!selectedId);
  updateClarity();
  if (!selectedId) return;
  const bus = motion.at(selectedId);
  if (bus) lastSelected = bus;
  const shown = bus || lastSelected;
  if (!shown) return;
  $('detail-route').textContent = shown.routeName;
  $('detail-provider').textContent = `${shown.provider || '車牌'}${shown.carType === '1' ? ' · 低底盤' : ''}`;
  $('detail-plate').textContent = shown.plate;
  $('detail-direction').textContent = `往 ${shown.destination}${shown.demo ? ' · 模擬車輛' : ''}`;
  $('detail-speed').textContent = !bus || isStale(shown) ? '—' : `${Math.round(shown.speed)} km/h`;
  $('detail-age').textContent = ageText(shown);
  $('detail-state').textContent = !bus ? '未再回報' : shown.demo ? '移動示範' : isStale(shown) ? '定位延遲' : states[shown.status] || '狀態未提供';
  $('detail-time').textContent = shown.demo ? '模擬資料' : clock(shown.observedAt);
  if (bus) renderArrivalDetail(bus);
  $('follow').disabled = !bus || isStale(shown);
  if ($('follow').disabled) following = false;
  $('follow').setAttribute('aria-pressed', String(following));
  $('follow-label').textContent = following ? '正在跟車 · 拖曳可暫停' : '跟著這輛公車';
  let warning = '';
  if (!bus) warning = '這輛車目前未回報營運定位，保留最後位置；不會自動換成另一輛車。';
  else if (isStale(shown)) warning = '定位已超過 2 分鐘，車身停在最後回報位置。';
  else if (!shown.demo && !shown.aligned) warning = '目前顯示 GPS 回報位置，尚未匹配到路線軌跡。';
  $('detail-warning').textContent = warning; $('detail-warning').hidden = !warning;
  $('app').style.setProperty('--detail-height', `${Math.ceil($('vehicle-detail').getBoundingClientRect().height)}px`);
}

function updateClarity() {
  if (!loaded) return;
  const opacity = selectedId && clarityEnabled ? .26 : 1;
  if (buildingOpacity === opacity) return;
  buildingOpacity = opacity;
  for (const item of map.getStyle().layers) if (item.type === 'fill-extrusion') map.setPaintProperty(item.id, 'fill-extrusion-opacity', opacity);
  $('vehicle-clarity').setAttribute('aria-pressed', String(clarityEnabled));
  map.triggerRepaint();
}

async function showRoute(bus) {
  if (!loaded) return;
  const request = ++routeRequest;
  map.getSource('selected-route')?.setData(emptyRoute);
  if (!bus) return;
  try {
    let feature;
    if (bus.demo) feature = { type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: bus.demoTrack } };
    else { const result = await fetch(`/api/routes/${encodeURIComponent(bus.routeId)}`); if (!result.ok) return; feature = await result.json(); }
    if (request === routeRequest && selectedId === bus.id) map.getSource('selected-route')?.setData(feature);
  } catch { /* Vehicle tracking remains available if route geometry is temporarily unavailable. */ }
}

function selectBus(id, { focus = true, immediate = false } = {}) {
  station = null; stationData = null; updateFilters(); closeMobileSheets();
  selectedId = id; following = false; lastSelected = motion.at(id);
  if (!lastSelected) { selectedId = null; return; }
  if (mode === 'live') { try { localStorage.setItem('taipei-bus:last-id', id); } catch {} }
  routeStopsData = null; arrivalStopId = null;
  renderDetail(); renderList(); void showRoute(lastSelected); void refreshDetailStops();
  if (focus) focusBus(lastSelected, immediate);
  following = true; renderMapInfo();
  map?.triggerRepaint();
}

function deselect() {
  selectedId = null; following = false; lastSelected = null; routeStopsData = null; arrivalStopId = null; detailRequest++; renderDetail(); renderList(); void showRoute(null);
  try { localStorage.removeItem('taipei-bus:last-id'); } catch {}
  map?.triggerRepaint();
  renderMapInfo();
}

function renderStatus() {
  const error = liveSnapshot?.error;
  const age = liveSnapshot?.receivedAt ? Date.now() - liveSnapshot.receivedAt : Infinity;
  const sourceAge = liveSnapshot?.sourceUpdatedAt ? Date.now() - liveSnapshot.sourceUpdatedAt : age;
  const healthy = connected && !error && age < 45000 && sourceAge < 120000;
  $('connection-status').textContent = mode === 'demo' ? '移動示範' : healthy ? '即時資料' : error ? '來源暫時中斷' : connected && sourceAge >= 120000 ? '來源更新延遲' : '正在重新連線';
  document.querySelector('.live-dot').style.background = mode === 'demo' ? '#b7985d' : healthy ? '#4ca779' : '#b7985d';
  document.querySelector('.status-dot').style.background = healthy ? '#4ca779' : '#b7985d';
  $('feed-detail').textContent = error ? '來源連線中斷，顯示最後定位。' : `資料：臺北市公共運輸處 · 每 ${pollSeconds} 秒查詢`;
  $('fleet-count').textContent = mode === 'demo' ? String(demoVehicles.length) : liveSnapshot?.vehicles.length.toLocaleString() || '—';
  $('fleet-updated').textContent = mode === 'demo' ? '模擬車輛 · 不代表即時交通' : liveSnapshot?.sourceUpdatedAt ? `GPS 來源 ${clock(liveSnapshot.sourceUpdatedAt)} 更新${sourceAge >= 120000 ? ' · 已延遲' : ''}` : '正在取得 GPS 資料';
  $('mobile-updated').textContent = mode === 'demo' ? '模擬定位' : liveSnapshot?.sourceUpdatedAt ? `${clock(liveSnapshot.sourceUpdatedAt)} 更新${healthy ? '' : ' · 延遲'}` : '正在取得資料';
}

function acceptSnapshot(snapshot) {
  if (!Array.isArray(snapshot.vehicles)) return;
  liveSnapshot = snapshot;
  if (mode === 'live' && loaded) {
    motion.ingest(snapshot.vehicles);
    if (firstLive && snapshot.vehicles.length) {
      firstLive = false;
      void searchStations();
    }
    renderList(); renderDetail(); renderMapInfo(); map.triggerRepaint();
    if (selectedId) void refreshDetailStops();
    if (station) void refreshStation();
  }
  renderStatus();
}

async function setMode(next) {
  if (next === mode) return;
  if (next === 'demo' && !demoVehicles.length) {
    try {
      const response = await fetch('/demo-tracks.json'); if (!response.ok) throw new Error();
      const { tracks } = await response.json(); const demoStart = performance.now();
      for (let i = 0; i < 8; i++) {
        const track = tracks[i % tracks.length]; const reverse = i % 4 >= 2; const path = reverse ? [...track].reverse() : track;
        const length = path.slice(1).reduce((sum, p, j) => sum + meters(path[j], p), 0);
        const startDistance = length * ((i * .217 + .14) % 1);
        const initial = pointAtDistance(path, startDistance);
        demoVehicles.push({ id: `demo-${i}`, plate: `DEMO-0${i + 1}`, routeId: `demo-route-${i % 2}`, routeName: i % 2 ? '藍線' : '仁愛', direction: reverse ? '1' : '0', destination: i % 2 ? reverse ? '基隆路一段南向' : '基隆路一段北向' : reverse ? '仁愛路四段西向' : '仁愛路四段東向', position: initial.position, heading: initial.heading, speed: 20 + i % 3 * 3, observedAt: Date.now(), status: '0', aligned: true, demo: true, demoTrack: path, demoLength: length, demoStart, startDistance });
      }
    } catch { toast('示範路徑未載入，請稍後再試。'); return; }
  }
  mode = next; selectedId = null; lastSelected = null; following = false; query = ''; $('search').value = ''; activeRoute = null; station = null; stationData = null; routeStopsData = null;
  for (const item of ['live', 'demo']) { $(`${item}-mode`).classList.toggle('active', item === mode); $(`${item}-mode`).setAttribute('aria-pressed', String(item === mode)); }
  $('demo-notice').hidden = mode !== 'demo';
  for (const item of ['routes', 'stops']) $(`view-${item}`).disabled = mode === 'demo';
  $('locate-user').disabled = mode === 'demo';
  setView(mode === 'demo' ? 'vehicles' : 'routes');
  motion.ingest(currentVehicles()); renderDetail(); renderStatus(); renderList();
  if (mode === 'demo') { selectBus('demo-0'); following = true; renderDetail(); }
  else { void showRoute(null); map.easeTo({ center: [121.5605, 25.0377], zoom: 17.8, pitch: 58, padding: padding(), duration: 1000 }); }
  map.triggerRepaint();
}

function connectFeed() {
  const source = new EventSource('/api/events');
  source.onopen = () => { connected = true; renderStatus(); };
  source.onmessage = event => { try { acceptSnapshot(JSON.parse(event.data)); } catch (error) { console.warn('Bus snapshot could not be displayed', error); } };
  source.onerror = () => { connected = false; renderStatus(); };
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) { void fetch('/api/snapshot').then(r => r.json()).then(acceptSnapshot).catch(() => {}); map?.triggerRepaint(); }
  });
}

function wireUI() {
  $('mobile-search').onclick = () => openMobileSearch('stops');
  $('mobile-routes').onclick = () => openMobileSearch('routes');
  $('mobile-close-search').onclick = closeMobileSheets; $('mobile-scrim').onclick = closeMobileSheets;
  $('mobile-locate').onclick = locateUser;
  $('mobile-clear').onclick = () => { closeMobileSheets(); station = null; stationData = null; activeRoute = null; deselect(); updateFilters(); void searchStations(); };
  $('mobile-follow').onclick = () => { $('follow').click(); renderMapInfo(); };
  $('world-more').onclick = () => {
    if (selectedId) { $('app').classList.add('show-detail'); $('mobile-scrim').hidden = false; }
    else if (station) openMobileSearch();
    else if (activeRoute) openMobileSearch('vehicles');
  };
  $('mobile-info').onclick = () => {
    const dialog = document.createElement('dialog'); dialog.className = 'phone-settings';
    const title = document.createElement('h2'); title.textContent = '資料與設定';
    const copy = document.createElement('p'); copy.textContent = '臺北市公共運輸處 · 每 15 秒取得更新。官方到站預估未綁定車牌。';
    const controls = document.createElement('div'); controls.className = 'settings-actions';
    for (const [label, action] of [['即時公車', () => setMode('live')], ['移動示範', () => setMode('demo')], ['淡化建築', () => $('vehicle-clarity').click()]]) {
      const button = document.createElement('button'); button.textContent = label; button.onclick = () => { void action(); dialog.close(); }; controls.append(button);
    }
    const link = document.createElement('a'); link.href = '/map-credits.html'; link.textContent = '地圖來源與授權'; link.target = '_blank';
    const close = document.createElement('button'); close.textContent = '完成'; close.onclick = () => dialog.close();
    dialog.append(title, copy, controls, link, close); dialog.onclose = () => dialog.remove(); $('app').append(dialog); dialog.showModal();
  };
  $('search').addEventListener('input', () => { query = normal($('search').value); if (view === 'stops') { station = null; stationData = null; updateFilters(); clearTimeout(stationSearchTimer); stationSearchTimer = setTimeout(() => void searchStations(), 250); } else renderList(); map?.triggerRepaint(); });
  for (const item of ['routes', 'stops', 'vehicles']) $(`view-${item}`).onclick = () => setView(item);
  $('locate-user').onclick = locateUser;
  window.addEventListener('native-location', event => event.detail?.error ? locationFailed() : locationReady(event.detail));
  $('clear-route').onclick = () => { activeRoute = null; updateFilters(); setView('routes'); void showRoute(null); };
  $('clear-station').onclick = () => { station = null; stationData = null; updateFilters(); void searchStations(); };
  $('arrival-stop').onchange = () => { arrivalStopId = $('arrival-stop').value; const bus = motion.at(selectedId); if (bus) renderArrivalDetail(bus); };
  $('live-mode').onclick = () => void setMode('live'); $('demo-mode').onclick = () => void setMode('demo');
  $('close-detail').onclick = closeMobileSheets;
  $('vehicle-clarity').onclick = () => { clarityEnabled = !clarityEnabled; updateClarity(); };
  $('follow').onclick = () => { following = !following; renderDetail(); if (following) focusBus(motion.at(selectedId)); };
  $('perspective').onclick = () => { following = false; const is3D = map.getPitch() > 10; map.easeTo({ pitch: is3D ? 0 : 58, duration: 850 }); renderDetail(); };
  $('overview').onclick = () => { following = false; map.easeTo({ center: [121.539, 25.054], zoom: 12.5, pitch: 35, padding: padding(), duration: 1300 }); renderDetail(); };
  $('zoom-in').onclick = () => map.zoomIn({ duration: 400 }); $('zoom-out').onclick = () => map.zoomOut({ duration: 400 });
  $('north').onclick = () => map.easeTo({ bearing: 0, duration: 700 });
  document.addEventListener('keydown', event => { if (event.key === '/' && event.target.tagName !== 'INPUT') { event.preventDefault(); $('search').focus(); } if (event.key === 'Escape') deselect(); });
  map.on('click', event => { const id = layer.pick(event.point); if (id) selectBus(id); else { const r = 16, p = event.point; const feature = map.queryRenderedFeatures([[p.x-r,p.y-r],[p.x+r,p.y+r]], { layers: ['nearby-stop-dots', 'nearby-stop-labels'] })[0]; const stop = nearbyStations.find(s => s.id === feature?.properties.id); if (stop) { setView('stops'); selectStation(stop); } } });
  map.on('mousemove', event => { map.getCanvas().style.cursor = layer.pick(event.point) ? 'pointer' : ''; });
  map.on('movestart', event => { if (event.originalEvent && following) { following = false; renderDetail(); } });
  map.on('moveend', () => { renderList(); if (view === 'stops' && !station && !userPosition) void searchStations(); });
  map.on('pitch', () => { const is3D = map.getPitch() > 10; $('perspective').textContent = is3D ? '3D' : '2D'; $('perspective').setAttribute('aria-pressed', String(is3D)); });
  map.on('rotate', () => document.querySelector('#north span').style.transform = `rotate(${-map.getBearing()}deg)`);
  map.on('render', () => {
    positionMapInfo();
    const now = performance.now();
    if (following && now - cameraTick > 200 && !map.isMoving()) {
      const bus = motion.at(selectedId, now); cameraTick = now;
      if (bus && !isStale(bus)) map.jumpTo({ center: bus.position });
    }
  });
  setInterval(() => { renderDetail(); renderStatus(); renderMapInfo(); }, 1000);
  setInterval(() => { if (!document.hidden) renderList(); }, 5000);
  new ResizeObserver(() => { map.resize(); if (following) focusBus(motion.at(selectedId), true); }).observe($('map'));
}

async function start() {
  try {
    const config = await fetch('/api/config').then(r => r.json());
    pollSeconds = Math.round(config.pollInterval / 1000);
    engine = maplibre;
    maplibre.setWorkerUrl(workerURL);
    if (config.engine === 'mapbox') { engine = (await import('mapbox-gl')).default; await import('mapbox-gl/dist/mapbox-gl.css'); engine.accessToken = config.mapboxToken; }
    const qa = new URLSearchParams(location.search).has('qa');
    map = new engine.Map({ container: 'map', style: config.engine === 'mapbox' ? 'mapbox://styles/mapbox/light-v11' : '/styles/taipei.json', center: [121.5605, 25.0377], zoom: 18, pitch: 58, bearing: -28, maxPitch: 75, minZoom: 11, maxZoom: 21, attributionControl: false, canvasContextAttributes: { antialias: true, preserveDrawingBuffer: qa }, ...(config.engine === 'mapbox' ? { antialias: true, projection: 'mercator' } : {}) });
    map.addControl(new engine.AttributionControl({ compact: true, customAttribution: config.engine === 'maplibre' ? '<a href="/map-credits.html">樣式來源</a>' : undefined }), 'bottom-right');
    map.addControl(new engine.ScaleControl({ maxWidth: 80, unit: 'metric' }), 'bottom-left');
    map.on('error', event => console.warn('Map resource', event.error?.message || event.error));
    map.getCanvas().addEventListener('webglcontextlost', () => toast('地圖繪圖暫停，正在等待恢復。'));
    connectFeed();
    map.on('load', () => {
      const labels = map.getStyle().layers.find(item => item.type === 'symbol')?.id;
      if (config.engine === 'mapbox' && !map.getLayer('building-3d')) map.addLayer({ id: 'building-3d', source: 'composite', 'source-layer': 'building', type: 'fill-extrusion', minzoom: 15, filter: ['==', 'extrude', 'true'], paint: { 'fill-extrusion-color': '#d7ddd8', 'fill-extrusion-height': ['get', 'height'], 'fill-extrusion-base': ['get', 'min_height'], 'fill-extrusion-opacity': 1 } }, labels);
      map.addSource('selected-route', { type: 'geojson', data: emptyRoute });
      map.addSource('user-and-stop', { type: 'geojson', data: emptyRoute });
      map.addSource('nearby-stations', { type: 'geojson', data: emptyRoute });
      const buildings = map.getLayer('building-3d') ? 'building-3d' : labels;
      map.addLayer({ id: 'selected-route-line', type: 'line', source: 'selected-route', layout: { 'line-join': 'round', 'line-cap': 'round' }, paint: { 'line-color': '#7ba5ad', 'line-width': 2.5, 'line-opacity': .3 } }, buildings);
      layer = new BusLayer(engine, motion, { selected: () => selectedId, filter: bus => matches(bus) || bus.id === selectedId, clarity: () => clarityEnabled && !!selectedId });
      map.addLayer(layer, labels); loaded = true;
      map.addLayer({ id: 'user-and-stop-point', type: 'circle', source: 'user-and-stop', paint: { 'circle-radius': 6, 'circle-color': ['match', ['get', 'kind'], 'user', '#2380cf', '#b79252'], 'circle-stroke-width': 2, 'circle-stroke-color': '#fff' } });
      map.addLayer({ id: 'nearby-stop-dots', type: 'circle', source: 'nearby-stations', minzoom: 15.7, paint: { 'circle-radius': 3, 'circle-color': '#2879e8', 'circle-stroke-width': 1.5, 'circle-stroke-color': '#fff' } });
      map.addLayer({ id: 'nearby-stop-labels', type: 'symbol', source: 'nearby-stations', minzoom: 15.7, layout: { 'text-field': ['get','name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0,1.4] }, paint: { 'text-color': '#46525e', 'text-halo-color': '#fff', 'text-halo-width': 2 } });
      if (qa) window.__busApp = { map, layer, motion, selectBus, setMode, deselect, selectRoute, selectStation, get snapshot() { return liveSnapshot; }, get selectedId() { return selectedId; }, get mode() { return mode; }, get view() { return view; } };
      wireUI(); setView('stops'); if (liveSnapshot) acceptSnapshot(liveSnapshot); void searchStations();
    });
    setTimeout(() => { if (!loaded) toast('底圖載入時間較長，請確認網路能連線至地圖服務。'); }, 15000);
  } catch (error) {
    $('fatal-error').hidden = false; $('fatal-error').querySelector('p').textContent = `請確認預覽伺服器與網路連線。${error.message}`;
  }
}

void start();
