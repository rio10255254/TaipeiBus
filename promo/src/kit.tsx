import React from 'react';
import { AbsoluteFill, Easing, Img, interpolate, staticFile } from 'remotion';
import { C, THEMES, ThemeName } from './theme';
import { FONT } from './fonts';

export const W = 1080;
export const H = 1920;
export const FPS = 60;
export const BEAT = 0.5; // seconds, 120 bpm
/** The app's screenshots are 1206 × 2622 pixels (402 × 874 points at 3×). */
export const SHOT_W = 1206;
export const SHOT_H = 2622;

export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
/** 0 → 1 between two times (seconds), eased. */
export const ramp = (t: number, from: number, to: number, ease: (n: number) => number = Easing.bezier(0.22, 1, 0.36, 1)) =>
  ease(clamp((t - from) / Math.max(1e-6, to - from)));
/** A damped spring from 0 to 1 that starts at `at`: quick out, a small overshoot, settled in about half a second. */
export const pop = (t: number, at: number, stiffness = 14, damping = 0.62) => {
  const x = t - at;
  if (x <= 0) return 0;
  return 1 - Math.exp(-damping * stiffness * x) * Math.cos(stiffness * Math.sqrt(1 - damping * damping) * x);
};
export const lerp = (a: number, b: number, k: number) => a + (b - a) * k;

/** Text with **marked** phrases split into runs. */
export const runs = (text: string) =>
  text.split(/(\*\*[^*]+\*\*)/g).filter(Boolean).map((part) =>
    part.startsWith('**') ? { text: part.slice(2, -2), mark: true } : { text: part, mark: false });

/** The page behind everything: the theme's colour, soft light from the top left, and route lines drifting by. */
export const Stage: React.FC<{ theme: ThemeName; t: number; children?: React.ReactNode; dim?: number }> = ({ theme, t, children, dim = 0 }) => {
  const th = THEMES[theme];
  const lines = [
    { d: 'M -80 420 C 240 380, 420 620, 760 560 S 1100 700, 1200 640', w: 26, o: 1, speed: 18 },
    { d: 'M -60 1180 C 200 1240, 380 1010, 640 1090 S 980 1320, 1180 1230', w: 20, o: 0.8, speed: -14 },
    { d: 'M 220 -60 C 180 320, 420 520, 360 900 S 520 1500, 420 2000', w: 16, o: 0.7, speed: 11 },
    { d: 'M 900 -40 C 960 400, 760 700, 860 1100 S 700 1640, 820 1980', w: 14, o: 0.6, speed: -9 },
  ];
  return (
    <AbsoluteFill style={{ background: `linear-gradient(168deg, ${th.bg} 0%, ${th.bg2} 100%)`, overflow: 'hidden' }}>
      <AbsoluteFill style={{ background: 'radial-gradient(90% 55% at 16% 4%, rgba(255,255,255,.20), rgba(255,255,255,0) 60%)' }} />
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
        {lines.map((l, i) => (
          <g key={i} opacity={l.o}>
            <path d={l.d} fill="none" stroke={th.line} strokeWidth={l.w} strokeLinecap="round" />
            <path d={l.d} fill="none" stroke={th.line} strokeWidth={l.w * 0.34} strokeLinecap="round"
              strokeDasharray="2 60" strokeDashoffset={-t * l.speed} />
          </g>
        ))}
      </svg>
      <AbsoluteFill style={{ background: 'radial-gradient(95% 60% at 84% 100%, rgba(0,0,0,.28), rgba(0,0,0,0) 70%)' }} />
      {children}
      {dim > 0 ? <AbsoluteFill style={{ background: `rgba(8,12,20,${dim})` }} /> : null}
    </AbsoluteFill>
  );
};

export type Pose = { x: number; y: number; s: number; rx?: number; ry?: number; rz?: number };
/** A region of the screenshot, in its pixels: [x0, y0, x1, y1]. */
export type Rect = [number, number, number, number];
export type LiftSpec = { rect: Rect; z: number; k: number; glow?: boolean };

const PHONE_W = 620; // page pixels at scale 1
const EDGE = Math.round(PHONE_W * 0.012);
const BEZEL = Math.round(PHONE_W * 0.016);
const SCREEN_W = PHONE_W - 2 * (EDGE + BEZEL);
const SCREEN_H = (SCREEN_W * SHOT_H) / SHOT_W;
const PHONE_H = SCREEN_H + 2 * (EDGE + BEZEL);
const RADIUS = Math.round(PHONE_W * 0.135);
export const PHONE = { w: PHONE_W, h: PHONE_H, screenW: SCREEN_W, screenH: SCREEN_H, px: SCREEN_W / SHOT_W };

/** Where a screenshot pixel sits inside the phone, from the phone's centre (page pixels at scale 1). */
export const onScreen = (x: number, y: number) => ({
  x: (x - SHOT_W / 2) * PHONE.px,
  y: (y - SHOT_H / 2) * PHONE.px,
});

export const shotUrl = (name: string) => staticFile(`shots/${name}.jpg`);

/**
 * An iPhone seen by a camera: the pose moves, turns and scales it in real perspective. `screens` are
 * drawn in order with their opacities (a cross-fade is two of them); `slide` pushes the second one in
 * from the right like a navigation push. Regions listed in `lifts` rise off the glass towards the
 * camera with a soft shadow; `children` are drawn on the glass in screenshot pixels (taps, pens).
 */
export const Phone: React.FC<{
  pose: Pose;
  screens: { name: string; opacity?: number; shift?: number }[];
  lifts?: LiftSpec[];
  children?: React.ReactNode;
  shine?: number;
  dimScreen?: number;
}> = ({ pose, screens, lifts = [], children, shine = 0, dimScreen = 0 }) => {
  const top = screens[screens.length - 1];
  const inner = RADIUS - EDGE - BEZEL;
  return (
    <div style={{ position: 'absolute', left: W / 2, top: H / 2, width: 0, height: 0, perspective: 2600, perspectiveOrigin: '0px 0px' }}>
      <div style={{
        position: 'absolute', left: -PHONE_W / 2, top: -PHONE_H / 2, width: PHONE_W, height: PHONE_H, transformStyle: 'preserve-3d',
        transform: `translate3d(${pose.x}px, ${pose.y}px, 0) scale(${pose.s}) rotateX(${pose.rx ?? 0}deg) rotateY(${pose.ry ?? 0}deg) rotateZ(${pose.rz ?? 0}deg)`,
      }}>
        {/* The shadow the phone casts on the page behind it. */}
        <div style={{ position: 'absolute', inset: 0, borderRadius: RADIUS, transform: 'translate3d(0, 46px, -90px)',
          boxShadow: '0 70px 120px rgba(4,10,22,.50), 0 20px 44px rgba(4,10,22,.34)' }} />
        <div style={{ position: 'absolute', inset: 0, borderRadius: RADIUS,
          background: 'linear-gradient(145deg, #646a73 0%, #272a2f 18%, #121417 50%, #2a2d32 82%, #6a7079 100%)',
          boxShadow: 'inset 0 0 0 2px rgba(255,255,255,.12)' }} />
        <div style={{ position: 'absolute', inset: EDGE, borderRadius: RADIUS - EDGE, background: '#050506' }} />
        <div style={{ position: 'absolute', left: EDGE + BEZEL, top: EDGE + BEZEL, width: SCREEN_W, height: SCREEN_H, borderRadius: inner, overflow: 'hidden', background: '#000' }}>
          {screens.map((s, i) => (
            <Img key={s.name + i} src={shotUrl(s.name)} style={{ position: 'absolute', left: 0, top: 0, width: SCREEN_W, height: SCREEN_H,
              opacity: s.opacity ?? 1, transform: s.shift ? `translateX(${s.shift * SCREEN_W}px)` : undefined }} />
          ))}
          {dimScreen > 0 ? <div style={{ position: 'absolute', inset: 0, background: `rgba(6,10,18,${dimScreen})` }} /> : null}
          <div style={{ position: 'absolute', left: '50%', top: 11 * 3 * PHONE.px, width: 126 * 3 * PHONE.px, height: 37 * 3 * PHONE.px,
            marginLeft: -(126 * 3 * PHONE.px) / 2, borderRadius: 999, background: '#000' }} />
          {/* Light sliding over the glass as the phone turns. */}
          <div style={{ position: 'absolute', inset: 0, opacity: 0.5,
            background: `linear-gradient(${112 + shine * 30}deg, rgba(255,255,255,0) ${30 + shine * 40}%, rgba(255,255,255,.22) ${44 + shine * 40}%, rgba(255,255,255,0) ${58 + shine * 40}%)` }} />
        </div>
        {lifts.map((l, i) => {
          const [x0, y0, x1, y1] = l.rect;
          const w = (x1 - x0) * PHONE.px, h = (y1 - y0) * PHONE.px;
          const k = clamp(l.k, 0, 1.2);
          if (k <= 0.001) return null;
          // A row as wide as the screen rises less, so it stays inside the frame when the phone fills the page.
          const wide = x1 - x0 > 900;
          const rise = wide ? Math.min(l.z, 80) : l.z;
          return (
            <div key={i} style={{ position: 'absolute', left: EDGE + BEZEL + x0 * PHONE.px, top: EDGE + BEZEL + y0 * PHONE.px, width: w, height: h,
              transform: `translate3d(0, 0, ${rise * k}px) scale(${1 + (wide ? 0.012 : 0.05) * k})`, borderRadius: 26 * PHONE.px * 3, overflow: 'hidden',
              boxShadow: `0 ${18 * k}px ${46 * k}px rgba(6,12,26,${0.42 * Math.min(1, k)}), 0 ${4 * k}px ${10 * k}px rgba(6,12,26,${0.3 * Math.min(1, k)})${l.glow ? `, 0 0 0 ${4 * k}px rgba(255,185,64,${0.9 * Math.min(1, k)})` : ''}`,
              opacity: Math.min(1, k * 4) }}>
              <Img src={shotUrl(top.name)} style={{ position: 'absolute', left: -x0 * PHONE.px, top: -y0 * PHONE.px, width: SCREEN_W, height: SCREEN_H }} />
            </div>
          );
        })}
        <div style={{ position: 'absolute', left: EDGE + BEZEL, top: EDGE + BEZEL, width: SCREEN_W, height: SCREEN_H, transform: 'translateZ(2px)', transformStyle: 'preserve-3d' }}>
          {children}
        </div>
        {/* Side keys. */}
        {[[118, 30, 'left'], [176, 62, 'left'], [252, 62, 'left'], [196, 98, 'right']].map(([y, h, side], i) => (
          <div key={i} style={{ position: 'absolute', [side as string]: -5, top: (y as number) * 3 * PHONE.px, width: 6, height: (h as number) * 3 * PHONE.px,
            borderRadius: 4, background: 'linear-gradient(90deg, #2a2d32, #5c6168)' }} />
        ))}
      </div>
    </div>
  );
};

/** A fingertip on the glass (screenshot pixels): it presses, a ring spreads, it lifts. */
export const Tap: React.FC<{ x: number; y: number; t: number; at: number }> = ({ x, y, t, at }) => {
  const k = t - at;
  if (k < -0.25 || k > 0.7) return null;
  const down = ramp(t, at - 0.25, at) * (1 - ramp(t, at + 0.12, at + 0.5));
  const ring = ramp(t, at, at + 0.55, Easing.out(Easing.cubic));
  const size = 150 * PHONE.px * 3;
  return (
    <div style={{ position: 'absolute', left: x * PHONE.px, top: y * PHONE.px, width: 0, height: 0 }}>
      <div style={{ position: 'absolute', left: -size / 2, top: -size / 2, width: size, height: size, borderRadius: '50%',
        border: `${3}px solid rgba(255,255,255,${0.9 * (1 - ring)})`, transform: `scale(${0.4 + ring * 1.3})`, boxShadow: `0 0 0 2px rgba(20,40,80,${0.25 * (1 - ring)})` }} />
      <div style={{ position: 'absolute', left: -size * 0.24, top: -size * 0.24, width: size * 0.48, height: size * 0.48, borderRadius: '50%',
        background: 'rgba(255,255,255,.92)', boxShadow: '0 6px 18px rgba(10,20,40,.45), inset 0 -3px 8px rgba(40,70,120,.25)',
        opacity: down, transform: `scale(${1.25 - 0.3 * down})` }} />
    </div>
  );
};

/** Rings spreading from a point on the glass (screenshot pixels): this is live, look here. */
export const Pulse: React.FC<{ x: number; y: number; t: number; at: number; until: number; color?: string }> = ({ x, y, t, at, until, color = '255,185,64' }) => {
  if (t < at || t > until + 0.4) return null;
  const fade = ramp(t, at, at + 0.2) * (1 - ramp(t, until, until + 0.4));
  const size = 260 * PHONE.px * 3;
  return (
    <div style={{ position: 'absolute', left: x * PHONE.px, top: y * PHONE.px, width: 0, height: 0, opacity: fade }}>
      {[0, 0.5].map((phase) => {
        const k = ((t - at) / 1.0 + phase) % 1;
        return <div key={phase} style={{ position: 'absolute', left: -size / 2, top: -size / 2, width: size, height: size, borderRadius: '50%',
          border: `4px solid rgba(${color},${0.95 * (1 - k)})`, background: `rgba(${color},${0.16 * (1 - k)})`, transform: `scale(${0.25 + k * 0.85})` }} />;
      })}
    </div>
  );
};

/** A small label that lands with a bounce: what the lifted piece of screen is. */
export const Sticker: React.FC<{ text: string; x: number; y: number; t: number; at: number; out?: number; tilt?: number; tone?: 'amber' | 'paper' | 'night' | 'go'; size?: number; sub?: string }> =
  ({ text, x, y, t, at, out, tilt = -3, tone = 'amber', size = 50, sub }) => {
    const k = pop(t, at, 16, 0.55) * (out == null ? 1 : 1 - ramp(t, out, out + 0.22, Easing.in(Easing.cubic)));
    if (k <= 0.002) return null;
    const tones = { amber: [C.amber, '#1B2638'], paper: ['#FBFCFE', C.ink], night: ['#182334', '#F4F7FC'], go: [C.go, '#07301A'] } as const;
    const [bg, ink] = tones[tone];
    return (
      <div style={{ position: 'absolute', left: x, top: y, transform: `translate(-50%, -50%) rotate(${tilt}deg) scale(${k})`, opacity: Math.min(1, k * 3),
        background: bg, color: ink, fontFamily: FONT, fontWeight: 900, fontSize: size, letterSpacing: 1, padding: `${size * 0.34}px ${size * 0.64}px`, borderRadius: size * 0.5,
        whiteSpace: 'nowrap', boxShadow: '0 22px 46px rgba(6,12,26,.38), 0 5px 12px rgba(6,12,26,.26)', textAlign: 'center', lineHeight: 1.15 }}>
        {text}
        {sub ? <div style={{ fontSize: size * 0.56, fontWeight: 700, opacity: 0.78, marginTop: 4 }}>{sub}</div> : null}
      </div>
    );
  };

/**
 * The caption band, low on the page but clear of the platform's own controls: a dark pill, the line
 * appearing a few characters at a time as it is spoken, the marked phrase in amber.
 */
export const Caption: React.FC<{ text: string; t: number; start: number; speak: number; end: number }> = ({ text, t, start, speak, end }) => {
  const show = ramp(t, start, start + 0.22) * (1 - ramp(t, end - 0.16, end, Easing.in(Easing.cubic)));
  if (show <= 0.002) return null;
  const parts = runs(text.replace(/\n/g, '\n'));
  const total = parts.reduce((n, p) => n + [...p.text.replace(/\n/g, '')].length, 0);
  const shown = clamp((t - start - 0.05) / Math.max(0.3, speak * 0.82)) * total;
  let seen = 0;
  return (
    <div style={{ position: 'absolute', left: 70, right: 70, top: 1318, display: 'flex', justifyContent: 'center', opacity: show,
      transform: `translateY(${(1 - show) * 26}px)` }}>
      <div style={{ background: 'rgba(14,20,31,.94)', borderRadius: 40, padding: '30px 46px 34px', boxShadow: '0 26px 60px rgba(4,8,18,.5), inset 0 0 0 2px rgba(255,255,255,.07)',
        fontFamily: FONT, fontWeight: 900, fontSize: 64, lineHeight: 1.3, letterSpacing: 1, color: '#F6F8FC', textAlign: 'center', whiteSpace: 'pre-wrap' }}>
        {parts.map((p, i) => (
          <span key={i} style={{ color: p.mark ? C.amber : undefined }}>
            {[...p.text].map((ch, j) => {
              if (ch === '\n') return <br key={j} />;
              const k = clamp(shown - seen++);
              return <span key={j} style={{ opacity: 0.16 + 0.84 * k, display: 'inline-block', transform: `translateY(${(1 - k) * 8}px)` }}>{ch}</span>;
            })}
          </span>
        ))}
      </div>
    </div>
  );
};

/** The series tag in the top left: the app's icon, its name and which film this is. */
export const Tag: React.FC<{ label: string; t: number; ink: string }> = ({ label, t, ink }) => {
  const k = ramp(t, 0.05, 0.5);
  return (
    <div style={{ position: 'absolute', left: 70, top: 250, display: 'flex', alignItems: 'center', gap: 20, opacity: k, transform: `translateX(${(1 - k) * -30}px)`,
      fontFamily: FONT, color: ink }}>
      <Img src={staticFile('icon.png')} style={{ width: 84, height: 84, borderRadius: 20, boxShadow: '0 10px 24px rgba(6,12,26,.35)' }} />
      <div>
        <div style={{ fontWeight: 900, fontSize: 40, letterSpacing: 2, lineHeight: 1.1 }}>一路 <span style={{ fontWeight: 600, fontSize: 30, opacity: 0.8, letterSpacing: 0 }}>OneRoad</span></div>
        <div style={{ fontWeight: 700, fontSize: 28, opacity: 0.82, letterSpacing: 2, marginTop: 4 }}>{label}</div>
      </div>
    </div>
  );
};

/** The cover's headline: two lines set large, the marked phrase underlined with a highlighter stroke that draws itself. */
export const Headline: React.FC<{ text: string; t: number; theme: ThemeName; out: number; top?: number; size?: number }> = ({ text, t, theme, out, top = 400, size = 132 }) => {
  const th = THEMES[theme];
  const leave = ramp(t, out, out + 0.4, Easing.in(Easing.cubic));
  if (leave >= 1) return null;
  const lines = text.split('\n');
  return (
    <div style={{ position: 'absolute', left: 70, right: 60, top, fontFamily: FONT, fontWeight: 900, fontSize: size, lineHeight: 1.16, letterSpacing: 2, color: th.ink,
      opacity: 1 - leave, transform: `translateY(${-leave * 90}px) scale(${1 - leave * 0.06})`, transformOrigin: 'left top' }}>
      {lines.map((line, i) => {
        const k = ramp(t, 0.02 + i * 0.12, 0.5 + i * 0.12);
        return (
          <div key={i} style={{ opacity: k, transform: `translateY(${(1 - k) * 44}px)`, whiteSpace: 'nowrap' }}>
            {runs(line).map((p, j) => p.mark ? (
              <span key={j} style={{ position: 'relative', color: th.mark, display: 'inline-block' }}>
                <span style={{ position: 'absolute', left: '-0.06em', right: '-0.08em', bottom: '0.07em', height: '0.34em', borderRadius: '0.12em 0.2em 0.16em 0.1em',
                  background: theme === 'mist' || theme === 'sand' ? 'rgba(255,170,40,.34)' : 'rgba(6,14,30,.26)', transform: `rotate(-1.2deg) skewX(-8deg) scaleX(${ramp(t, 0.5 + i * 0.12, 0.95 + i * 0.12)})`, transformOrigin: 'left center' }} />
                <span style={{ position: 'relative' }}>{p.text}</span>
              </span>
            ) : <span key={j}>{p.text}</span>)}
          </div>
        );
      })}
    </div>
  );
};

/** The end card every film lands on: the icon, the name, one line, and where to get it. */
export const EndCard: React.FC<{ t: number; at: number; line: string; cta: string; note?: string }> = ({ t, at, line, cta, note }) => {
  const k = t - at;
  if (k < -0.6) return null;
  const open = ramp(t, at - 0.5, at + 0.25, Easing.inOut(Easing.cubic));
  const icon = pop(t, at + 0.05, 13, 0.5);
  const name = ramp(t, at + 0.3, at + 0.85);
  const tag = ramp(t, at + 0.62, at + 1.1);
  const button = pop(t, at + 0.95, 15, 0.55);
  const dots = ['公車', '捷運', 'YouBike', '步行'];
  return (
    <AbsoluteFill style={{ clipPath: `circle(${open * 150}% at 50% 44%)` }}>
      <AbsoluteFill style={{ background: `linear-gradient(170deg, ${C.nightSoft} 0%, ${C.night} 100%)` }} />
      <AbsoluteFill style={{ background: 'radial-gradient(70% 40% at 50% 30%, rgba(120,165,235,.26), rgba(120,165,235,0) 70%)' }} />
      <svg width={W} height={H} style={{ position: 'absolute', inset: 0 }}>
        <path d="M 140 1210 C 320 1150, 420 1290, 540 1230 S 800 1150, 940 1220" fill="none" stroke="rgba(255,185,64,.9)" strokeWidth={10} strokeLinecap="round"
          strokeDasharray={900} strokeDashoffset={900 * (1 - ramp(t, at + 0.55, at + 1.5, Easing.inOut(Easing.cubic)))} />
        {[140, 407, 673, 940].map((x, i) => {
          const y = [1210, 1262, 1178, 1220][i];
          const d = pop(t, at + 0.7 + i * 0.2, 16, 0.5);
          return <circle key={i} cx={x} cy={y} r={17 * d} fill={C.night} stroke={C.amber} strokeWidth={8} />;
        })}
      </svg>
      {dots.map((d, i) => {
        const x = [140, 407, 673, 940][i], y = [1210, 1262, 1178, 1220][i];
        const a = ramp(t, at + 0.8 + i * 0.2, at + 1.2 + i * 0.2);
        return <div key={d} style={{ position: 'absolute', left: x, top: y + 44, transform: 'translateX(-50%)', opacity: a, fontFamily: FONT, fontWeight: 700, fontSize: 34,
          color: 'rgba(232,240,252,.86)', letterSpacing: 1, whiteSpace: 'nowrap' }}>{d}</div>;
      })}
      <div style={{ position: 'absolute', left: 0, right: 0, top: 470, display: 'flex', flexDirection: 'column', alignItems: 'center', fontFamily: FONT, color: '#F5F8FD' }}>
        <Img src={staticFile('icon.png')} style={{ width: 250, height: 250, borderRadius: 58, transform: `scale(${icon}) rotate(${(1 - Math.min(1, icon)) * -14}deg)`,
          boxShadow: '0 40px 80px rgba(0,0,0,.5), 0 10px 24px rgba(0,0,0,.35)' }} />
        <div style={{ marginTop: 56, fontWeight: 900, fontSize: 150, letterSpacing: 10, lineHeight: 1, opacity: name, clipPath: `inset(0 ${(1 - name) * 100}% 0 0)` }}>一路</div>
        <div style={{ marginTop: 14, fontWeight: 600, fontSize: 44, letterSpacing: 6, opacity: name * 0.8 }}>OneRoad</div>
        <div style={{ marginTop: 44, fontWeight: 700, fontSize: 48, letterSpacing: 2, opacity: tag, transform: `translateY(${(1 - tag) * 20}px)`, color: 'rgba(232,240,252,.92)' }}>{line}</div>
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: 1390, display: 'flex', flexDirection: 'column', alignItems: 'center', fontFamily: FONT }}>
        <div style={{ transform: `scale(${button})`, background: C.amber, color: '#1B2638', fontWeight: 900, fontSize: 54, letterSpacing: 2, padding: '26px 60px', borderRadius: 999,
          boxShadow: '0 22px 50px rgba(255,160,30,.34), 0 6px 14px rgba(0,0,0,.3)' }}>{cta}</div>
        {note ? <div style={{ marginTop: 26, fontWeight: 600, fontSize: 32, color: 'rgba(226,234,246,.7)', opacity: ramp(t, at + 1.3, at + 1.7) }}>{note}</div> : null}
      </div>
    </AbsoluteFill>
  );
};
