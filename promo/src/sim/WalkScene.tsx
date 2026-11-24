import React from 'react';
import { Easing, Img, staticFile } from 'remotion';
import { LATIN } from '../fonts';
import { clamp, lerp, pop, ramp } from '../kit';
import { Button, INK, SOFT, StatusBar, Touch, text } from './chrome';
import { along, path, upTo } from './geo';
import paths from './paths.json';
import { LngLat, SimMap } from './SimMap';

/**
 * A stop's arrivals, then the walk to it. The stop is Ren'ai Guangfu, the walk the 259 metres along
 * Ren'ai Road that the app's own guidance drew; the banner and the card that arrive with it are the
 * app's, from its store capture of this same walk.
 */
const WALK = path(paths.walk as LngLat[]);
const STOP = WALK.points[WALK.points.length - 1];
const START = WALK.points[0];
const glide = Easing.bezier(0.45, 0, 0.2, 1);
const glass: React.CSSProperties = { background: 'rgba(252,252,250,.96)', boxShadow: '0 10px 28px rgba(20,30,45,.2), inset 0 0 0 1.5px rgba(255,255,255,.8)' };

/** `open`: when the stop's tag is touched. `go`: when 步行 is. Seconds since the shot began. */
export const WalkScene: React.FC<{ t: number; open: number; go: number }> = ({ t, open, go }) => {
  const walking = glide(clamp((t - go - 0.1) / 1.5));
  const turn = glide(clamp((t - go - 0.1) / 3.2));
  const drawn = WALK.length * glide(clamp((t - go - 0.25) / 1.3));
  const middle = along(WALK, WALK.length / 2).at;
  const tag = 1 - ramp(t, go + 0.05, go + 0.35);
  const rows = [0, 1].map((i) => pop(t, open + 0.12 + i * 0.08, 12, 0.72));
  const actions = pop(t, open + 0.3, 12, 0.7);
  const banner = pop(t, go + 0.35, 10, 0.8), card = pop(t, go + 0.5, 10, 0.82);
  return (
    <SimMap camera={{ center: [lerp(STOP[0], middle[0], walking), lerp(STOP[1] + 0.00036, middle[1] + 0.0001, walking)], zoom: lerp(17.85, 16.72, walking) + 0.1 * turn,
      bearing: lerp(0, -28, turn) }}
      lines={[{ coords: upTo(WALK, drawn), color: '#2F6FE4', width: 6.5, dotted: true }]}
      dots={[{ at: START, color: '#2F6FE4', radius: 9 * clamp(walking * 2), stroke: '#FFFFFF', strokeWidth: 3.5 }, { at: STOP, color: '#FFFFFF', radius: 7, stroke: '#2F6FE4', strokeWidth: 4 }]}
      anchors={{ stop: STOP }}>
      {(at) => {
        const p = at.stop ?? { x: 443, y: 1000 };
        const left = p.x - 250, top = p.y - 232;
        return (
          <>
            <div style={{ opacity: tag }}>
              <div style={{ position: 'absolute', left, top, height: 108, padding: '0 28px 0 22px', borderRadius: 34, display: 'flex', alignItems: 'center', gap: 18, ...glass }}>
                <div style={{ width: 44, height: 44, borderRadius: 22, background: '#F5940A', ...text(30, 900, '#fff'), textAlign: 'center', lineHeight: '44px' }}>!</div>
                <div><div style={text(40, 800)}>仁愛光復路口</div><div style={text(24, 500, SOFT)}>西向</div></div>
                <svg width="28" height="18" viewBox="0 0 28 18" style={{ marginLeft: 6, transform: `rotate(${180 * clamp(rows[0])}deg)` }}><path d="M4 4l10 10L24 4" fill="none" stroke="#6B6B70" strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" /></svg>
              </div>
              <div style={{ position: 'absolute', left: left + 30, top: top + 124, height: 62, display: 'flex', alignItems: 'center', gap: 14 }}>
                <div style={{ padding: '6px 16px 8px', borderRadius: 14, background: '#6A3FA0', ...text(30, 800, '#fff') }}>仁愛幹線</div>
                <div style={{ padding: '6px 16px 8px', borderRadius: 14, ...glass, ...text(28, 700) }}>1 分鐘 ›</div>
              </div>
              {['EAL-5112', 'EAL-5135'].map((plate, i) => (
                <div key={plate} style={{ position: 'absolute', left: left - 70, top: top + 206 + i * 84, width: 520, height: 70, borderRadius: 35, padding: '0 28px', display: 'flex', alignItems: 'center', ...glass,
                  opacity: clamp(rows[i] * 1.5), transform: `translateY(${(1 - rows[i]) * -26}px) scale(${0.92 + 0.08 * rows[i]})` }}>
                  <div style={{ ...text(28, 700), fontFamily: LATIN, letterSpacing: 0.5 }}>{plate}</div>
                  <div style={{ marginLeft: 'auto', ...text(26, 600, '#55555A') }}>時間待確認</div>
                </div>
              ))}
              {[['到站車輛', 0, 232], ['步行', 250, 172]].map(([label, dx, width], i) => (
                <div key={String(label)} style={{ position: 'absolute', left: left - 20 + Number(dx), top: top + 384, width: Number(width), height: 72, borderRadius: 36, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12, ...glass,
                  opacity: clamp(actions * 1.5), transform: `scale(${0.8 + 0.2 * actions})`, ...text(28, 700, INK) }}>
                  <svg width="30" height="30" viewBox="0 0 30 30" fill="none" stroke={INK} strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round">
                    {i ? <><circle cx="16" cy="5" r="2.6" fill={INK} /><path d="M10 28l4-9-2-7 5-2 3 5 4 2M12 12l-3 5M17 19l3 9" /></> : <><rect x="5" y="4" width="20" height="19" rx="4" /><path d="M5 15h20M9 27v-4M21 27v-4" /></>}
                  </svg>
                  {label}
                </div>
              ))}
            </div>
            <Touch x={left + 190} y={top + 54} t={t} at={open} />
            <Touch x={left + 316} y={top + 420} t={t} at={go} />
            {t > go ? (
              <svg style={{ position: 'absolute', left: p.x - 30, top: p.y - 74, transformOrigin: '30px 74px', transform: `scale(${pop(t, go + 0.2, 12, 0.6)})` }} width="60" height="76" viewBox="0 0 60 76">
                <path d="M30 74C30 74 6 46 6 28a24 24 0 0 1 48 0c0 18-24 46-24 46z" fill="#F0453A" stroke="#fff" strokeWidth="4" />
                <path d="M23 18v22M23 19h15l-4 6 4 6H23" fill="#fff" stroke="#fff" strokeWidth="3" strokeLinejoin="round" />
              </svg>
            ) : null}
            <Button x={806} y={418 + 50 * walking} icon="map" />
            <Button x={806} y={524 + 50 * walking} icon="locate" />
            <StatusBar time="2:41" />
            <Img src={staticFile('sim/walk-banner.png')} style={{ position: 'absolute', left: 34, top: 139 - (1 - banner) * 420, width: 818, height: 213, borderRadius: 48, boxShadow: '0 14px 40px rgba(10,15,25,.3)' }} />
            <Img src={staticFile('sim/walk-card.png')} style={{ position: 'absolute', left: 34, top: 1456 + (1 - card) * 560, width: 818, height: 379, borderRadius: 58, boxShadow: '0 -8px 40px rgba(20,30,40,.16)' }} />
          </>
        );
      }}
    </SimMap>
  );
};
