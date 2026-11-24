import React from 'react';
import { Easing } from 'remotion';
import { FONT, LATIN } from '../fonts';
import { ramp } from '../kit';

/** The parts of the screen that are the same in every simulated shot, drawn in the recording's 886 × 1920 pixels. */
export const INK = '#1C1C1E', SOFT = '#8A8A8E', ACCENT = '#F5940A', GLASS = 'rgba(250,250,247,.9)';

export const StatusBar: React.FC<{ time?: string }> = ({ time = '9:41' }) => (
  <>
    <div style={{ position: 'absolute', left: 70, top: 44, fontFamily: LATIN, fontWeight: 600, fontSize: 34, letterSpacing: 0.5, color: INK }}>{time}</div>
    <div style={{ position: 'absolute', left: 316, top: 28, width: 254, height: 74, borderRadius: 37, background: '#000' }} />
    <svg style={{ position: 'absolute', right: 58, top: 46 }} width="150" height="34" viewBox="0 0 150 34">
      {[0, 1, 2, 3].map((i) => <rect key={i} x={i * 10} y={22 - i * 5} width="6" height={8 + i * 5} rx="2" fill={INK} />)}
      <path d="M52 15a17 17 0 0 1 28 0M57 20a11 11 0 0 1 18 0" fill="none" stroke={INK} strokeWidth="4" strokeLinecap="round" />
      <circle cx="66" cy="26" r="3.4" fill={INK} />
      <rect x="94" y="7" width="46" height="23" rx="7" fill="none" stroke={INK} strokeOpacity=".4" strokeWidth="2" />
      <rect x="97" y="10" width="40" height="17" rx="4.5" fill="#34C759" />
      <rect x="143" y="14" width="4" height="9" rx="2" fill={INK} fillOpacity=".45" />
    </svg>
  </>
);

const round = (size: number): React.CSSProperties => ({ width: size, height: size, borderRadius: size / 2, background: GLASS,
  boxShadow: '0 6px 18px rgba(30,40,50,.16), inset 0 0 0 1.5px rgba(255,255,255,.7)', display: 'flex', alignItems: 'center', justifyContent: 'center' });

const glyph = {
  map: <path d="M4 8l9-4 10 4 9-4v20l-9 4-10-4-9 4zM13 4v20M23 8v20" fill="none" strokeWidth="2.6" strokeLinejoin="round" />,
  city: <><circle cx="18" cy="18" r="12" fill="none" strokeWidth="2.6" /><path d="M9 20l6-9 5 6 4-3 4 6" fill="none" strokeWidth="2.6" strokeLinejoin="round" /></>,
  locate: <path d="M30 6L6 16l11 3 3 11z" fill="none" strokeWidth="2.6" strokeLinejoin="round" />,
  search: <><circle cx="16" cy="16" r="9" fill="none" strokeWidth="2.8" /><path d="M23 23l8 8" strokeWidth="2.8" strokeLinecap="round" /></>,
  routes: <path d="M9 8a3 3 0 1 0 0 .1M27 28a3 3 0 1 0 0 .1M12 8h9a6 6 0 0 1 0 12h-6a4 4 0 0 0 0 8h9" fill="none" strokeWidth="2.6" strokeLinecap="round" />,
  follow: <><circle cx="18" cy="18" r="9" fill="none" strokeWidth="2.8" /><circle cx="18" cy="18" r="3" /><path d="M18 3v6M18 27v6M3 18h6M27 18h6" strokeWidth="2.8" strokeLinecap="round" /></>,
  close: <path d="M9 9l18 18M27 9L9 27" strokeWidth="3" strokeLinecap="round" />,
};
export const Button: React.FC<{ x: number; y: number; icon: keyof typeof glyph; color?: string; size?: number; opacity?: number }> = ({ x, y, icon, color = '#3A3F45', size = 92, opacity = 1 }) => (
  <div style={{ position: 'absolute', left: x - size / 2, top: y - size / 2, opacity, ...round(size) }}>
    <svg width="36" height="36" viewBox="0 0 36 36" stroke={color} fill={icon === 'follow' ? color : 'none'}>{glyph[icon]}</svg>
  </div>
);

/** The map's own controls: three on the right, the compass under them turning with the map. */
export const MapControls: React.FC<{ bearing: number; following?: boolean; lift?: number }> = ({ bearing, following, lift = 0 }) => (
  <>
    <Button x={806} y={206} icon="map" />
    <Button x={806} y={312} icon="city" />
    <Button x={806} y={418} icon="locate" />
    <div style={{ position: 'absolute', left: 806 - 40, top: 540 - 40, width: 80, height: 80, borderRadius: 40, background: '#17181A', boxShadow: '0 6px 16px rgba(20,25,30,.3)' }}>
      <svg width="80" height="80" viewBox="-40 -40 80 80" style={{ transform: `rotate(${-bearing}deg)` }}>
        {Array.from({ length: 24 }, (_, i) => <path key={i} d={`M0 ${-31}V${i % 6 ? -27 : -24}`} stroke="rgba(255,255,255,.75)" strokeWidth="1.6" transform={`rotate(${i * 15})`} />)}
        <path d="M0 -20l6 20h-12z" fill="#FF453A" /><path d="M0 20l6 -20h-12z" fill="#F2F2F2" />
      </svg>
    </div>
    <div style={{ opacity: 1 - lift }}>
      <Button x={96} y={1790} icon="search" />
      <Button x={568} y={1790} icon="routes" />
      <Button x={680} y={1790} icon="follow" color={following ? ACCENT : undefined} />
      <Button x={792} y={1790} icon="close" />
    </div>
  </>
);

export const text = (size: number, weight = 500, color = INK): React.CSSProperties => ({ fontFamily: FONT, fontSize: size, fontWeight: weight, color, lineHeight: 1.25, whiteSpace: 'nowrap' });

/** A touch: a soft white dot pressing down and two amber rings leaving it. */
export const Touch: React.FC<{ x: number; y: number; t: number; at: number }> = ({ x, y, t, at }) => {
  if (t < at - 0.3 || t > at + 0.95) return null;
  const down = ramp(t, at - 0.26, at, Easing.out(Easing.cubic)) * (1 - ramp(t, at + 0.1, at + 0.45));
  const ring = ramp(t, at, at + 0.6, Easing.out(Easing.cubic)), ring2 = ramp(t, at + 0.12, at + 0.9, Easing.out(Easing.cubic));
  const circle = (size: number, k: number, width: number) => (
    <div style={{ position: 'absolute', left: -size / 2, top: -size / 2, width: size, height: size, borderRadius: '50%',
      border: `${width}px solid rgba(255,185,64,${0.95 * (1 - k)})`, transform: `scale(${0.4 + k * 1.25})` }} />
  );
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: 0, height: 0 }}>
      {circle(170, ring, 6)}
      {t > at + 0.12 ? circle(240, ring2, 4) : null}
      <div style={{ position: 'absolute', left: -44, top: -44, width: 88, height: 88, borderRadius: '50%', background: 'rgba(255,255,255,.94)',
        boxShadow: '0 10px 26px rgba(10,20,40,.5), inset 0 0 0 5px rgba(255,185,64,.95)', opacity: down, transform: `scale(${1.35 - 0.35 * down})` }} />
    </div>
  );
};
