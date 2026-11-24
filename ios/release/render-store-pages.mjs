// Draws the App Store gallery (6.9" iPhone, 1320 × 2868 PNG): a coloured page, a small label,
// one bold headline with a highlighted phrase, a line under it and a large, real screen from the
// app in a phone. The screens are captured by AppStoreScreenshotTests (ios.yml, usability scope
// `app-store-features`) and kept unmodified in `screenshot-sources`; nothing inside a screen is
// drawn or changed here. The words are in PAGES below.
//
//   node ios/release/render-store-pages.mjs [sources] [output]
// Needs Playwright with Chromium and network access to Google Fonts.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = path.dirname(fileURLToPath(import.meta.url));
const SOURCES = process.argv[2] ?? path.join(here, 'screenshot-sources');
const OUT = process.argv[3] ?? path.join(here, 'screenshots');
const ICON = path.join(here, '../TaipeiBus/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
const W = 1320, H = 2868;

/**
 * `theme` is the page colour (slate is the brand's blue, night for the 3D map, mist and sand are
 * light pages, moss for cycling); `screen` names a file in the sources; `pair` puts two screens
 * side by side; `crop` shows only part of a source that is not a bare screenshot ([x, y, w, h] in
 * its pixels); `chips` are small tags; `note` is a small line for what needs the subscription.
 */
export const PAGES = [
  { file: '01-live-bus', theme: 'slate', brand: true, screen: 'store-1.9.0-live-bus', phoneTop: 1090,
    title: '公車到哪了<br><mark>打開就知道</mark>', text: '公車、捷運、YouBike 與步行，一路接到底。',
    chips: ['台北', '新北', '免登入'] },
  { file: '02-next-bus', theme: 'night', screen: 'store-1.9.0-bus-card', icon: 'clock', kicker: '即時到站',
    title: '下一班<br><mark>還要多久</mark>', text: '官方到站時間、車速與回報時間，<br>點一輛車就能跟著它走。' },
  { file: '03-compare', theme: 'mist', screen: 'store-1.9.0-compare', icon: 'route', kicker: '路線比較',
    title: '怎麼去最快<br><mark>一次比完</mark>', text: '公車、捷運、YouBike 放在一起比，<br>走路、等車的時間都算進去。' },
  { file: '04-youbike', theme: 'moss', screen: 'store-1.9.0-steps-youbike', icon: 'bike', kicker: 'YouBike 接駁',
    title: '最後一段路<br><mark>騎車接上</mark>', text: '借車站有幾輛、還車站有幾格，<br>出發前每一步都先看清楚。' },
  { file: '05-walking', theme: 'sand', screen: 'store-1.9.0-walking', icon: 'walk', kicker: 'App 內步行',
    title: '走到站牌<br><mark>不用切 App</mark>', text: '步行路線、剩下幾分鐘和到站時間，<br>都在同一張地圖上。' },
  { file: '06-station', theme: 'slate', screen: 'store-1.9.0-station', icon: 'pin', kicker: '附近站牌',
    title: '這一站<br><mark>有哪些車</mark>', text: '點站牌看下一班多久到，<br>常用的站牌加星號收藏。' },
  { file: '07-routes', theme: 'sand', screen: 'store-1.9.0-keypad', icon: 'pin', kicker: '路線查詢',
    title: '找路線<br><mark>按幾下就到</mark>', text: '紅、藍、棕、綠、幹線一鍵帶入，<br>雙北公車與捷運都查得到。' },
  { file: '08-start', theme: 'night', finale: true, kicker: '出門前，看一眼',
    title: '一路<br>接到底', text: '路線規劃、導航、到站資訊與 3D 公車地圖，<br>不用登入、免費使用。',
    chips: ['公車', '捷運', 'YouBike', '步行'],
    collage: ['store-1.9.0-compare', 'store-1.9.0-live-bus', 'store-1.9.0-steps-youbike'] },
];

const T = {
  slate: { bg: '#4F6F96', glow: 'rgba(214,230,250,.22)', shade: 'rgba(12,26,48,.28)', ink: '#F7FAFF', soft: 'rgba(240,246,255,.86)',
    mark: '#FFD27A', markBack: 'rgba(8,20,40,.22)', pill: '#F7FAFF', pillInk: '#3F5F86', chip: 'rgba(247,250,255,.14)', chipLine: 'rgba(247,250,255,.55)' },
  night: { bg: '#172233', glow: 'rgba(120,160,220,.20)', shade: 'rgba(0,0,0,.34)', ink: '#F4F7FC', soft: 'rgba(226,234,246,.84)',
    mark: '#FFC25C', markBack: 'rgba(255,255,255,.08)', pill: '#FFB340', pillInk: '#1B2638', chip: 'rgba(244,247,252,.10)', chipLine: 'rgba(244,247,252,.50)' },
  mist: { bg: '#EEF2F7', glow: 'rgba(255,255,255,.80)', shade: 'rgba(70,100,140,.12)', ink: '#18222F', soft: '#51606F',
    mark: 'inherit', markBack: 'rgba(255,170,40,.50)', pill: '#4F6F96', pillInk: '#F7FAFF', chip: 'rgba(79,111,150,.10)', chipLine: 'rgba(79,111,150,.45)' },
  sand: { bg: '#F4EDE1', glow: 'rgba(255,255,255,.70)', shade: 'rgba(150,110,50,.12)', ink: '#241C12', soft: '#665744',
    mark: 'inherit', markBack: 'rgba(255,160,30,.48)', pill: '#D9822B', pillInk: '#FFF8EC', chip: 'rgba(217,130,43,.10)', chipLine: 'rgba(217,130,43,.45)' },
  moss: { bg: '#3F6B55', glow: 'rgba(225,245,225,.18)', shade: 'rgba(8,30,20,.28)', ink: '#F5FAF4', soft: 'rgba(236,246,236,.86)',
    mark: '#FFE08A', markBack: 'rgba(0,0,0,.18)', pill: '#F5FAF4', pillInk: '#335A47', chip: 'rgba(245,250,244,.14)', chipLine: 'rgba(245,250,244,.55)' },
};

const svg = (d) => `<svg viewBox="0 0 24 24" width="32" height="32" aria-hidden="true"><path fill="currentColor" d="${d}"/></svg>`;
const ICONS = {
  bus: svg('M6 3h12a3 3 0 0 1 3 3v10a2 2 0 0 1-1 1.7V19a1.5 1.5 0 0 1-3 0v-1H7v1a1.5 1.5 0 0 1-3 0v-1.3A2 2 0 0 1 3 16V6a3 3 0 0 1 3-3Zm-1 4v4h14V7H5Zm2.5 8a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5Zm9 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5Z'),
  route: svg('M6 3a3 3 0 0 1 1 5.83V14a2 2 0 0 0 2 2h4.17a3 3 0 1 1 0 2H9a4 4 0 0 1-4-4V8.83A3 3 0 0 1 6 3Zm12-1 4 4-4 4V7h-5V5h5V2Z'),
  clock: svg('M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20Zm1 5h-2v6l4.6 2.7 1-1.7L13 11.8V7Z'),
  walk: svg('M13.5 5.5a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM9.8 8.9 7 23h2.1l1.8-8 2.1 2v6h2v-7.5l-2.1-2 .6-3A7.3 7.3 0 0 0 19 13v-2a5.2 5.2 0 0 1-4.3-2.4l-1-1.6a2 2 0 0 0-2.5-.8L6 8.3V13h2V9.6l1.8-.7Z'),
  bike: svg('M15.5 5.5a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM5 12a5 5 0 1 0 0 10 5 5 0 0 0 0-10Zm0 8.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Zm5.8-10 2.4-2.4.8.8A7 7 0 0 0 19 11v-2a5 5 0 0 1-3.6-1.5l-1.9-1.9a2 2 0 0 0-2.8 0L7.9 8.4a2 2 0 0 0 0 2.8L11 14v5h2v-6.2l-2.2-2.3ZM19 12a5 5 0 1 0 0 10 5 5 0 0 0 0-10Zm0 8.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7Z'),
  pin: svg('M12 2a7 7 0 0 1 7 7c0 5.2-7 13-7 13S5 14.200 5 9a7 7 0 0 1 7-7Zm0 4.500a2.500 2.500 0 1 0 0 5 2.500 2.500 0 0 0 0-5Z'),
};

const png = (file) => `data:image/png;base64,${fs.readFileSync(file).toString('base64')}`;
const shot = (name) => png(path.join(SOURCES, `${name}.png`));

const css = (t) => `
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@500;600;700;800;900&family=Noto+Sans+TC:wght@500;700;900&display=block');
  * { box-sizing: border-box; margin: 0; }
  html, body { width: ${W}px; height: ${H}px; overflow: hidden; }
  body { position: relative; font-family: Inter, 'Noto Sans TC', sans-serif; color: ${t.ink}; -webkit-font-smoothing: antialiased;
    background-color: ${t.bg};
    background-image: radial-gradient(115% 70% at 18% 6%, ${t.glow}, rgba(255,255,255,0) 60%),
      radial-gradient(95% 60% at 82% 100%, ${t.shade}, rgba(0,0,0,0) 70%); }
  .copy { position: absolute; left: 100px; right: 100px; top: 150px; height: 790px; display: flex; flex-direction: column; justify-content: center; }
  .brand { display: flex; align-items: center; gap: 24px; margin-bottom: 60px; font-weight: 800; font-size: 46px; letter-spacing: 1px; }
  .brand img { width: 96px; height: 96px; border-radius: 23px; box-shadow: 0 10px 26px rgba(10,24,46,.32), 0 1px 3px rgba(10,24,46,.2); }
  .brand small { font-weight: 600; font-size: 34px; opacity: .78; letter-spacing: 0; }
  .kicker { align-self: flex-start; display: inline-flex; align-items: center; gap: 12px; margin-bottom: 34px; padding: 12px 30px 12px 22px;
    border-radius: 999px; background: ${t.pill}; color: ${t.pillInk}; font-weight: 800; font-size: 34px; letter-spacing: 2px;
    box-shadow: 0 8px 20px rgba(10,24,46,.20); }
  h1 { font-weight: 900; font-size: 128px; line-height: 1.16; letter-spacing: 1px; text-wrap: balance; }
  h1 mark { color: ${t.mark}; background: none; position: relative; z-index: 0; white-space: nowrap; }
  h1 mark::before { content: ''; position: absolute; z-index: -1; left: -0.08em; right: -0.1em; bottom: 0.06em; height: 0.36em;
    background: ${t.markBack}; border-radius: 0.12em 0.2em 0.16em 0.1em; transform: rotate(-1.2deg) skewX(-8deg); }
  .text { margin-top: 42px; font-weight: 500; font-size: 46px; line-height: 1.45; color: ${t.soft}; text-wrap: pretty; }
  .note { margin-top: 24px; font-weight: 700; font-size: 34px; color: ${t.mark === 'inherit' ? t.pill : t.mark}; }
  .chips { margin-top: 40px; display: flex; gap: 18px; flex-wrap: wrap; }
  .chips span { padding: 12px 28px; border-radius: 999px; background: ${t.chip}; border: 2px solid ${t.chipLine}; font-weight: 800; font-size: 36px; }
  .chips span::before { content: '✓ '; }
  .phone { position: absolute; border-radius: var(--r);
    background: linear-gradient(145deg, #5b6068 0%, #24272c 18%, #121417 50%, #282b30 82%, #60656d 100%);
    box-shadow: 0 60px 120px rgba(8,18,36,.34), 0 18px 40px rgba(8,18,36,.24), 0 2px 4px rgba(0,0,0,.25), inset 0 0 0 2px rgba(255,255,255,.10); }
  .phone .bezel { position: absolute; inset: var(--edge); border-radius: calc(var(--r) - var(--edge)); background: #050506; overflow: hidden; }
  .phone .screen { position: absolute; inset: var(--bezel); border-radius: calc(var(--r) - var(--edge) - var(--bezel)); overflow: hidden; background: #000; }
  .phone .screen img { display: block; width: 100%; }
  .phone .island { position: absolute; left: 50%; transform: translateX(-50%); background: #000; border-radius: 999px; }
  .phone .key { position: absolute; width: 7px; border-radius: 4px; background: linear-gradient(90deg, #2a2d32, #5c6168); }
`;

const device = (w) => {
  const edge = Math.round(w * 0.012), bezel = Math.round(w * 0.015);
  const screen = w - 2 * (edge + bezel);
  return { w, edge, bezel, screen, pt: screen / 402, r: Math.round(w * 0.135) };
};

/** A phone whose top edge is at y; it runs off the bottom of the page. `crop` picks part of the source. */
function phone(source, y, { w = 920, left = (W - w) / 2, turn = 0, crop = null } = {}) {
  const d = device(w);
  const h = Math.round(2 * (d.edge + d.bezel) + d.screen * 2622 / 1206);
  const key = (side, top, height) => `<span class="key" style="${side}:-6px;top:${Math.round(top * d.pt)}px;height:${Math.round(height * d.pt)}px"></span>`;
  const image = crop
    ? `<img src="${source}" style="width:${(d.screen * crop.full) / crop.w}px;margin-left:-${(d.screen * crop.x) / crop.w}px;margin-top:-${(d.screen * crop.y) / crop.w}px">`
    : `<img src="${source}">`;
  return `<div class="phone" style="left:${left}px;top:${y}px;width:${w}px;height:${h}px;--r:${d.r}px;--edge:${d.edge}px;--bezel:${d.bezel}px;${turn ? `transform:rotate(${turn}deg);` : ''}">
    ${key('left', 118, 30)}${key('left', 176, 62)}${key('left', 252, 62)}${key('right', 196, 98)}
    <div class="bezel"><div class="screen">${image}</div>
      <span class="island" style="top:${Math.round(d.bezel + 11 * d.pt)}px;width:${Math.round(126 * d.pt)}px;height:${Math.round(37 * d.pt)}px"></span>
    </div></div>`;
}

const page = (body, theme) => `<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><style>${css(T[theme])}</style></head><body>${body}</body></html>`;

function feature(p, icon) {
  const top = p.phoneTop ?? 1000;
  const phones = p.pair
    ? phone(shot(p.pair[0]), top + 20, { w: 640, left: 70, turn: -3 }) + phone(shot(p.pair[1]), top + 180, { w: 640, left: W - 640 - 70, turn: 3 })
    : phone(shot(p.screen), top, { crop: p.crop ? { x: p.crop[0], y: p.crop[1], w: p.crop[2], full: p.crop[4] } : null });
  return page(`
    <div class="copy">
      ${p.brand ? `<div class="brand"><img src="${icon}">一路 <small>OneRoad</small></div>` : ''}
      ${p.kicker ? `<p class="kicker">${ICONS[p.icon ?? 'bus']}${p.kicker}</p>` : ''}
      <h1>${p.title}</h1><p class="text">${p.text}</p>${p.note ? `<p class="note">${p.note}</p>` : ''}
      ${p.chips ? `<div class="chips">${p.chips.map((c) => `<span>${c}</span>`).join('')}</div>` : ''}
    </div>${phones}`, p.theme);
}

function finale(p, icon) {
  const fan = (p.collage ?? []).map((name, i) => {
    const w = 400, x = [70, 460, 850][i], y = [1800, 1710, 1820][i], turn = [-7, 1.5, 8][i];
    return `<div style="position:absolute;left:${x}px;top:${y}px;width:${w}px;transform:rotate(${turn}deg);padding:10px;border-radius:44px;
      background:#0b0d10;box-shadow:0 40px 80px rgba(0,0,0,.45), 0 8px 20px rgba(0,0,0,.3)">
      <img src="${shot(name)}" style="display:block;width:100%;border-radius:36px"></div>`;
  }).join('');
  const t = T[p.theme];
  return page(`${fan}
    <div style="position:absolute;left:100px;right:100px;top:290px">
      <div class="brand" style="margin:0"><img src="${icon}" style="width:150px;height:150px;border-radius:36px">
        <span style="font-size:64px">一路 <small style="font-size:44px">OneRoad</small></span></div>
      <p style="margin-top:96px;font-weight:700;font-size:60px;letter-spacing:2px;color:${t.mark}">${p.kicker}</p>
      <p style="margin-top:20px;font-weight:900;font-size:236px;line-height:1.06;letter-spacing:4px">${p.title}</p>
      <div class="chips" style="margin-top:70px">${p.chips.map((c) => `<span style="font-size:40px;padding:16px 34px">${c}</span>`).join('')}</div>
      <p class="text" style="margin-top:52px">${p.text}</p>
    </div>`, p.theme);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const require = createRequire(import.meta.url);
  const { chromium } = require('playwright');
  const icon = png(ICON);
  const only = process.env.ONLY?.split(',');
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {});
  try {
    const tab = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
    for (const p of PAGES) {
      if (only && !only.includes(p.file)) continue;
      await tab.setContent(p.finale ? finale(p, icon) : feature(p, icon), { waitUntil: 'networkidle' });
      await tab.evaluate(() => document.fonts.ready);
      const target = path.join(OUT, `${p.file}.png`);
      await tab.screenshot({ path: target, type: 'png' });
      console.log(`Wrote ${target}`);
    }
  } finally { await browser.close(); }
}
