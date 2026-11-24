import React from 'react';
import { Easing } from 'remotion';
import { LATIN } from '../fonts';
import { clamp, lerp, pop, ramp } from '../kit';
import { ACCENT, INK, MapControls, SOFT, StatusBar, Touch, text } from './chrome';
import { along, box, disc, from, path, turn } from './geo';
import paths from './paths.json';
import { Flat, LngLat, SimMap, Solid } from './SimMap';

/**
 * Following a bus in 3D, then its card. The bus runs along route 939's published shape: east on
 * Ren'ai Road and left into Shifu Road, slowing for the corner as a bus does. The camera is the
 * app's follow camera in spirit: it looks a little ahead of the bus and turns after it, late and
 * gently, so the corner reads as the bus turning rather than the map spinning.
 */
const FPS = 30, FRAMES = 9 * FPS;
const ROUTE = path(paths.bus as LngLat[]);
const CORNER = ROUTE.at[1 + 7]; // the middle of the first rounded corner
const glide = Easing.bezier(0.45, 0, 0.2, 1);

/** Metres a second at a place on the route: down to a walk's pace through the corner, then away. */
const speed = (s: number) => 5.2 + 7.6 * Easing.inOut(Easing.quad)(clamp(Math.abs(s - CORNER) / 46));

type Step = { s: number; at: LngLat; heading: number; kmh: number; centre: LngLat; bearing: number };
const STEPS: Step[] = (() => {
  const out: Step[] = [];
  let s = CORNER - 44, centre: LngLat | null = null, bearing = 0;
  for (let f = 0; f < FRAMES; f++) {
    const here = along(ROUTE, s);
    // Heading averaged over the bus's own length, so it swings through the corner instead of snapping.
    const tail = along(ROUTE, s - 7).heading, nose = along(ROUTE, s + 7).heading;
    const heading = tail + turn(nose, tail) / 2;
    const ahead = along(ROUTE, s + 16).at;
    if (!centre) { centre = ahead; bearing = heading - 34; }
    centre = [lerp(centre[0], ahead[0], 0.1), lerp(centre[1], ahead[1], 0.1)];
    // The view drifts round the bus for the first seconds, then settles a little off its tail.
    const off = lerp(-34, 12, glide(clamp(f / (4.2 * FPS))));
    bearing += turn(heading + off, bearing) * 0.045;
    out.push({ s, at: here.at, heading, kmh: speed(s) * 3.6, centre, bearing });
    s += speed(s) / FPS;
  }
  return out;
})();

/** The bus, about twice life size as the app draws it: skirt, body, glass and roof as stacked blocks. */
const bus = (at: LngLat, heading: number): { solids: Solid[]; flats: Flat[] } => {
  const L = 26, W = 6.4;
  const part = (base: number, height: number, color: string, length = L, width = W, forward = 0): Solid => ({ ring: box(at, heading, length, width, forward), base, height, color });
  return {
    solids: [
      part(0.6, 1.9, '#2B3442'), part(1.9, 4.6, '#51668A'), part(4.6, 7.1, '#18202B', L - 0.6, W - 0.2), part(7.1, 7.9, '#DDE3EC'),
      part(7.9, 8.5, '#B4BECC', 7.5, 3.2, -3), part(2.0, 3.1, '#FFD27A', 0.6, W - 1.5, L / 2 - 0.1),
    ],
    flats: [
      { ring: disc(at, 24), color: '#2F6FE4', opacity: 0.1 }, { ring: disc(at, 17), color: '#2F6FE4', opacity: 0.12 },
      { ring: box(from(at, heading, -1, 1.8), heading, L + 3, W + 2.8), color: '#101820', opacity: 0.2 },
    ],
  };
};

const Row: React.FC<{ y: number; children: React.ReactNode }> = ({ y, children }) => <div style={{ position: 'absolute', left: 56, right: 56, top: y, display: 'flex', alignItems: 'center' }}>{children}</div>;

/** The bus's card, laid out as the app's: where it is going, how fast, when it last reported. */
const Card: React.FC<{ up: number; kmh: number; ago: number }> = ({ up, kmh, ago }) => {
  if (up <= 0.001) return null;
  const H = 760;
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, top: 1920 - H * up, height: H + 80, borderRadius: '56px 56px 0 0', background: 'rgba(250,250,247,.97)',
      boxShadow: '0 -18px 60px rgba(20,30,40,.2), inset 0 2px 0 rgba(255,255,255,.9)' }}>
      <div style={{ position: 'absolute', left: 406, top: 14, width: 74, height: 10, borderRadius: 5, background: 'rgba(60,60,67,.3)' }} />
      <svg style={{ position: 'absolute', left: 44, top: 78 }} width="30" height="44" viewBox="0 0 30 44"><path d="M22 6L8 22l14 16" fill="none" stroke={ACCENT} strokeWidth="5" strokeLinecap="round" strokeLinejoin="round" /></svg>
      <div style={{ position: 'absolute', left: 100, top: 52, ...text(56, 900), fontFamily: LATIN }}>939</div>
      <div style={{ position: 'absolute', left: 102, top: 124, ...text(28, 600, SOFT), fontFamily: LATIN, letterSpacing: 1 }}>KKA-9852</div>
      <div style={{ position: 'absolute', right: 44, top: 60, width: 68, height: 68, borderRadius: 34, background: 'rgba(118,118,128,.14)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <svg width="26" height="26" viewBox="0 0 26 26"><path d="M4 4l18 18M22 4L4 22" stroke="#6B6B70" strokeWidth="4" strokeLinecap="round" /></svg>
      </div>
      <div style={{ position: 'absolute', left: 56, top: 196, ...text(38, 700) }}>往 臺北市政府</div>
      <Row y={276}>
        <svg width="40" height="40" viewBox="0 0 40 40"><circle cx="20" cy="20" r="15" fill="none" stroke={INK} strokeWidth="3.4" /><path d="M20 20l7-7" stroke={INK} strokeWidth="3.4" strokeLinecap="round" /></svg>
        <div style={{ marginLeft: 16, width: 78, ...text(44, 800), fontFamily: LATIN, fontVariantNumeric: 'tabular-nums' }}>{Math.round(kmh)}</div>
        <div style={{ marginRight: 54, ...text(26, 500, SOFT) }}>時速 km/h</div>
        <svg width="44" height="34" viewBox="0 0 44 34"><circle cx="22" cy="17" r="5" fill="#2FB45A" /><path d="M11 6a16 16 0 0 0 0 22M33 6a16 16 0 0 1 0 22M5 1a24 24 0 0 0 0 32M39 1a24 24 0 0 1 0 32" fill="none" stroke="#2FB45A" strokeWidth="3.2" strokeLinecap="round" /></svg>
        <div style={{ marginLeft: 14 }}><div style={text(32, 700)}>營運中</div><div style={{ ...text(24, 500, SOFT), fontVariantNumeric: 'tabular-nums' }}>{ago} 秒前回報</div></div>
      </Row>
      <Row y={376}>
        <svg width="36" height="36" viewBox="0 0 36 36"><rect x="7" y="4" width="22" height="28" rx="3" fill="none" stroke={SOFT} strokeWidth="3" /><path d="M13 11h10M13 17h10M13 23h10" stroke={SOFT} strokeWidth="3" /></svg>
        <div style={{ marginLeft: 16, ...text(30, 500, '#55555A') }}>臺北客運</div>
      </Row>
      <div style={{ position: 'absolute', left: 56, right: 56, top: 440, height: 2, background: 'rgba(60,60,67,.12)' }} />
      <Row y={468}>
        <div style={text(32, 600)}>淡化建築・凸顯這輛車</div>
        <div style={{ marginLeft: 'auto', width: 104, height: 62, borderRadius: 31, background: ACCENT }}><div style={{ margin: '5px 0 0 47px', width: 52, height: 52, borderRadius: 26, background: '#fff', boxShadow: '0 3px 8px rgba(0,0,0,.2)' }} /></div>
      </Row>
      {[['追蹤中', 56, true], ['查看路線', 456, false]].map(([label, left, on]) => (
        <div key={String(label)} style={{ position: 'absolute', left: Number(left), top: 572, width: 374, height: 96, borderRadius: 48, background: on ? 'rgba(245,148,10,.2)' : 'rgba(245,148,10,.12)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', ...text(34, 700, '#D47F00') }}>{label}</div>
      ))}
      <div style={{ position: 'absolute', left: 56, top: 694, ...text(24, 500, SOFT) }}>官方即時位置・每幾秒更新一次</div>
    </div>
  );
};

/** `t`: seconds since the shot began. `tap`: when the tag is touched and the card comes up. */
export const BusScene: React.FC<{ t: number; tap: number }> = ({ t, tap }) => {
  const step = STEPS[Math.min(STEPS.length - 1, Math.max(0, Math.round(t * FPS)))];
  const up = pop(t, tap + 0.12, 9, 0.82);
  const settle = glide(clamp(t / 3.6));
  const drawn = bus(step.at, step.heading);
  const pressed = ramp(t, tap - 0.12, tap, Easing.out(Easing.cubic)) * (1 - ramp(t, tap + 0.05, tap + 0.3));
  return (
    <SimMap camera={{ center: step.centre, zoom: lerp(18.15, 17.65, settle) + 0.1 * clamp(up), bearing: step.bearing, pitch: lerp(58, 53, settle), lift: 270 * clamp(up), buildings: 0.58 }}
      solids={drawn.solids} flats={drawn.flats} anchors={{ bus: step.at }}>
      {(at) => {
        const p = at.bus ?? { x: 443, y: 900 };
        const x = Math.min(p.x + 76, 886 - 430), y = p.y - 132;
        return (
          <>
            <div style={{ position: 'absolute', left: x, top: y, height: 76, padding: '0 22px 0 14px', borderRadius: 38, display: 'flex', alignItems: 'center', gap: 14,
              background: 'rgba(252,252,250,.96)', boxShadow: '0 10px 26px rgba(20,30,45,.22), inset 0 0 0 1.5px rgba(255,255,255,.8)', transform: `scale(${1 - 0.06 * pressed})`, opacity: 1 - 0.85 * clamp(up * 1.6) }}>
              <div style={{ padding: '4px 16px 6px', borderRadius: 16, background: '#2F6FE4', ...text(32, 800, '#fff'), fontFamily: LATIN }}>939</div>
              <div style={{ ...text(30, 700), fontFamily: LATIN, letterSpacing: 0.5 }}>KKA-9852</div>
              <div style={{ display: 'flex', gap: 6, marginLeft: 4 }}>{[0, 1, 2].map((i) => <div key={i} style={{ width: 7, height: 7, borderRadius: 4, background: '#6B6B70' }} />)}</div>
            </div>
            <MapControls bearing={step.bearing} following lift={clamp(up)} />
            <StatusBar time="2:35" />
            <Touch x={x + 206} y={y + 38} t={t} at={tap} />
            <Card up={up} kmh={STEPS[Math.max(0, Math.round(t * FPS) - (Math.round(t * FPS) % 15))].kmh} ago={3 + Math.floor(Math.max(0, t - tap) * 1) % 4} />
          </>
        );
      }}
    </SimMap>
  );
};
