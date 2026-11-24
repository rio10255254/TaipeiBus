import React from 'react';
import { AbsoluteFill, Audio, Easing, Img, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import script from './episodes.json';
import cut from './preview.json';
import timings from './timing.json';
import { FONT, LATIN } from './fonts';
import { clamp, lerp, pop, ramp } from './kit';
import { C } from './theme';
import { BusScene } from './sim/BusScene';
import { Touch } from './sim/chrome';
import { TripScene } from './sim/TripScene';
import { WalkScene } from './sim/WalkScene';

/**
 * The App Store's app preview (886 × 1920, 30 fps). Apple allows only screen recordings of the app
 * itself, with text and touch marks added, so the picture is always the real recording: it sits as
 * a rounded screen on the brand's night page, with the line's headline above it, set the same way
 * as the store screenshots. There is no phone, hand or mock-up.
 *
 * What keeps it moving between the app's own animations is the edit: each shot has a camera that
 * drifts or closes in inside the screen, screens arrive by sliding over or pushing through the last,
 * and the page behind them shifts with every line.
 */
export const PREVIEW = { w: 886, h: 1920, fps: 30 };
const { w: W, h: H } = PREVIEW;
/** The screen on the page. Everything inside it is laid out in the recording's own 886 × 1920. */
const SCREEN = { w: 694, x: 96, y: 398, r: 64 };
const K = SCREEN.w / W;
const SCREEN_H = Math.round(H * K);

/** Where the camera looks (a point in the recording, in frame pixels) and how close, at a second of the shot. */
type Key = { at: number; x?: number; y?: number; s?: number };
type Enter = 'cut' | 'blend' | 'left' | 'right' | 'through';
type Clip = {
  /** The line this footage plays under, and how many seconds into that line it cuts in (or `t`, a second of the film). */
  line: number; at?: number; t?: number;
  /** A recording: a file in public/preview, the second of it on screen at the cut, and how fast it plays. */
  file?: string; from?: number; rate?: number;
  /** Or a shot drawn here: the app's map rendered frame by frame, with the times (seconds into the shot) of its touches. */
  sim?: 'bus' | 'trip' | 'walk'; at1?: number; at2?: number;
  /** How the screen arrives over the one before; `blend` is for two takes of the same still screen. */
  enter?: Enter;
  camera?: Key[];
  /** Touch marks: seconds after the cut, at a point of the recording. */
  taps?: { at: number; x: number; y: number }[];
  /** A part of the screen to hold the eye on: everything else dims a little. Seconds after the cut. */
  spots?: { at: number; until: number; rect: [number, number, number, number]; radius?: number }[];
};
type Line = { text: string };
type Timing = { total: number; end: number; slots: { start: number; length: number; voiceLength: number }[] };

const EP = (script as unknown as { episodes: { id: string; endLine: string; lines: Line[] }[] }).episodes.find((e) => e.id === 'store')!;
const TM = (timings as unknown as Record<string, Timing>).store;
/** `kickers`: the small label over each line's headline. */
const CUT = cut as unknown as { kickers: string[]; clips: Clip[] };
export const previewFrames = Math.round(TM.total * PREVIEW.fps);

/** A screen starts arriving this long before its cut and has landed this long after. */
const LEAD = 0.14;
const LAND = 0.42;
const glide = Easing.bezier(0.45, 0, 0.2, 1);
const arrive = Easing.bezier(0.16, 0.84, 0.24, 1);

function cameraAt(clip: Clip, local: number, length: number) {
  const keys = clip.camera?.length ? clip.camera : [{ at: 0, s: 1 }, { at: length, s: 1.04 }];
  let a = keys[0], b = keys[keys.length - 1];
  for (let i = 0; i + 1 < keys.length; i++) if (local >= keys[i].at) { a = keys[i]; b = keys[i + 1]; }
  const k = b.at > a.at ? glide(clamp((local - a.at) / (b.at - a.at))) : 0;
  const s = lerp(a.s ?? 1, b.s ?? 1, k);
  const x = lerp(a.x ?? W / 2, b.x ?? W / 2, k), y = lerp(a.y ?? H / 2, b.y ?? H / 2, k);
  // The point looked at goes to the middle of the screen, as far as the picture's edges allow.
  return { s, tx: Math.min(0, Math.max(W - W * s, W / 2 - x * s)), ty: Math.min(0, Math.max(H - H * s, H / 2 - y * s)) };
}

/** One take of the recording, as a screen on the page. */
const Screen: React.FC<{ clip: Clip; start: number; end: number; next?: Enter; t: number; leave: number }> = ({ clip, start, end, next, t, leave }) => {
  const rate = clip.rate ?? 1;
  const enter = start <= 0 ? 'cut' : clip.enter ?? 'left';
  const lead = enter === 'cut' ? 0 : clip.sim ? LEAD : Math.min(LEAD, (clip.from ?? 0) / rate);
  const first = Math.round((start - lead) * PREVIEW.fps);
  const leaving = next !== undefined && next !== 'cut' && next !== 'blend';
  // A screen stays under the next one only while that one is still arriving.
  const last = Math.round((end + (leaving ? LAND + 0.05 : next === 'blend' ? 0.16 : 0)) * PREVIEW.fps);
  const local = t - start, length = end - start;
  const cam = cameraAt(clip, Math.max(0, local), length);
  // Arriving over the last screen, and later giving way to the next.
  const inK = enter === 'cut' ? 1 : enter === 'blend' ? ramp(t, start - lead, start + 0.12, glide) : arrive(clamp((t - (start - lead)) / (lead + LAND)));
  const outK = leaving ? arrive(clamp((t - (end - LEAD)) / (LEAD + LAND))) : 0;
  let x = 0, scale = 1, opacity = 1, turn = 0;
  if (enter === 'left') { x += (1 - inK) * (W - SCREEN.x + 40); turn += (1 - inK) * 2.4; }
  if (enter === 'right') { x -= (1 - inK) * (SCREEN.x + SCREEN.w + 40); turn -= (1 - inK) * 2.4; }
  if (enter === 'through') { scale *= 0.8 + 0.2 * inK; opacity *= clamp(inK * 1.7); }
  if (enter === 'blend') opacity *= inK;
  if (next === 'left') { x -= outK * (SCREEN.x + SCREEN.w * 0.72); scale *= 1 - 0.07 * outK; opacity *= 1 - clamp(outK * 1.15); }
  if (next === 'right') { x += outK * (SCREEN.x + SCREEN.w * 0.72); scale *= 1 - 0.07 * outK; opacity *= 1 - clamp(outK * 1.15); }
  if (next === 'through') { scale *= 1 + 0.16 * outK; opacity *= 1 - clamp(outK * 1.3); }
  // The close takes the screen down and away.
  scale *= 1 - 0.1 * leave; opacity *= 1 - leave;
  const float = Math.sin(t * 0.9) * 4;
  return (
    <Sequence from={first} durationInFrames={Math.max(1, last - first)} layout="none">
      <div style={{ position: 'absolute', left: SCREEN.x, top: SCREEN.y, width: SCREEN.w, height: SCREEN_H, borderRadius: SCREEN.r, overflow: 'hidden', opacity,
        transform: `translate(${x}px, ${float + 70 * leave}px) rotate(${turn}deg) scale(${scale})`,
        boxShadow: '0 46px 110px rgba(2,6,16,.6), 0 10px 30px rgba(2,6,16,.38)' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, transformOrigin: '0 0', transform: `scale(${K})` }}>
          <div style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, transformOrigin: '0 0', transform: `translate(${cam.tx}px, ${cam.ty}px) scale(${cam.s})` }}>
            {clip.sim === 'bus' ? <BusScene t={Math.max(0, local)} tap={clip.at1 ?? 5} /> : clip.sim === 'trip' ? <TripScene t={Math.max(0, local)} />
              : clip.sim === 'walk' ? <WalkScene t={Math.max(0, local)} open={clip.at1 ?? 0.3} go={clip.at2 ?? 1.5} /> : (
                <OffthreadVideo src={staticFile(`preview/${clip.file}`)} muted startFrom={Math.max(0, Math.round(((clip.from ?? 0) - lead * rate) * PREVIEW.fps))} playbackRate={rate}
                  style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, objectFit: 'cover' }} />
              )}
            {(clip.spots ?? []).map((spot, j) => {
              const k = ramp(local, spot.at, spot.at + 0.35, glide) * (1 - ramp(local, spot.until, spot.until + 0.3, glide));
              if (k <= 0.002) return null;
              const [x0, y0, x1, y1] = spot.rect;
              return <div key={j} style={{ position: 'absolute', left: x0, top: y0, width: x1 - x0, height: y1 - y0, borderRadius: spot.radius ?? 36,
                boxShadow: `0 0 0 3000px rgba(10,16,28,${0.5 * k}), inset 0 0 0 ${5 * k}px rgba(255,185,64,${0.95 * k})` }} />;
            })}
            {(clip.taps ?? []).map((tap, j) => <Touch key={j} x={tap.x} y={tap.y} t={local} at={tap.at} />)}
          </div>
        </div>
        <div style={{ position: 'absolute', inset: 0, borderRadius: SCREEN.r, boxShadow: 'inset 0 0 0 2px rgba(255,255,255,.17)' }} />
      </div>
    </Sequence>
  );
};

const runs = (text: string) => text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((part) =>
  part.startsWith('**') ? { text: part.slice(2, -2), mark: true } : { text: part, mark: false });

/** The line's headline, set like the store screenshots: a small label, then two lines, the second in amber. */
const Headline: React.FC<{ index: number; text: string; kicker: string; t: number; start: number; end: number; speak: number }> = ({ index, text, kicker, t, start, end, speak }) => {
  const out = ramp(t, end - 0.24, end, Easing.in(Easing.cubic));
  if (t < start - 0.05 || out >= 1) return null;
  const rows = text.split('\n').map((row) => row.replace(/[，。]$/, ''));
  const label = ramp(t, start, start + 0.4, arrive);
  return (
    <div style={{ position: 'absolute', left: 62, top: 84, right: 40, fontFamily: FONT, opacity: 1 - out, transform: `translateY(${-18 * out}px)` }}>
      <div style={{ display: 'inline-flex', alignItems: 'center', gap: 14, padding: '9px 22px 10px 10px', borderRadius: 40, background: 'rgba(255,185,64,.13)',
        boxShadow: 'inset 0 0 0 2px rgba(255,185,64,.32)', opacity: label, transform: `translateX(${(1 - label) * -26}px)` }}>
        <Img src={staticFile('icon.png')} style={{ width: 40, height: 40, borderRadius: 10 }} />
        <span style={{ fontWeight: 700, fontSize: 30, letterSpacing: 3, color: C.amber }}>{kicker}</span>
        <span style={{ fontFamily: LATIN, fontWeight: 600, fontSize: 24, color: 'rgba(255,214,140,.7)', letterSpacing: 1 }}>{index + 1}/{EP.lines.length}</span>
      </div>
      <div style={{ marginTop: 22 }}>
        {rows.map((row, r) => {
          const k = arrive(clamp((t - start - 0.08 - r * 0.1) / 0.55));
          const marked = row.includes('**');
          const sweep = ramp(t, start + 0.3 + speak * 0.45, start + 0.75 + speak * 0.45, glide);
          return (
            <div key={r} style={{ overflow: 'hidden', height: 92, marginTop: r ? -4 : 0 }}>
              <div style={{ display: 'inline-block', position: 'relative', fontWeight: 900, fontSize: 70, lineHeight: '92px', letterSpacing: 1.5, whiteSpace: 'nowrap',
                transform: `translateY(${(1 - k) * 96}px)`, opacity: clamp(k * 1.5) }}>
                {marked ? <span style={{ position: 'absolute', left: -8, right: -8, bottom: 12, height: 30, borderRadius: 10, background: 'rgba(255,185,64,.24)',
                  transformOrigin: '0 50%', transform: `scaleX(${sweep})` }} /> : null}
                {runs(row).map((p, i) => <span key={i} style={{ position: 'relative', color: p.mark ? C.amber : '#F6F8FC' }}>{p.text}</span>)}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};

/** The page: night blue, with two soft lights that drift and step along with the lines. */
const Page: React.FC<{ t: number; line: number }> = ({ t, line }) => (
  <AbsoluteFill style={{ background: 'linear-gradient(168deg, #1D2D49 0%, #121C30 52%, #0A111E 100%)', overflow: 'hidden' }}>
    <div style={{ position: 'absolute', width: 1100, height: 1100, borderRadius: '50%', left: -420 + 130 * Math.sin(t * 0.23) + line * 70, top: 760 + 90 * Math.cos(t * 0.19),
      background: 'radial-gradient(circle, rgba(255,185,64,.2) 0%, rgba(255,185,64,.06) 42%, rgba(255,185,64,0) 68%)' }} />
    <div style={{ position: 'absolute', width: 1200, height: 1200, borderRadius: '50%', left: 260 - 110 * Math.sin(t * 0.17) - line * 60, top: -520 + 70 * Math.cos(t * 0.21),
      background: 'radial-gradient(circle, rgba(96,150,232,.34) 0%, rgba(96,150,232,.1) 44%, rgba(96,150,232,0) 70%)' }} />
    <div style={{ position: 'absolute', width: 900, height: 900, borderRadius: '50%', left: 380 + 80 * Math.cos(t * 0.15), top: 1380 + 60 * Math.sin(t * 0.2),
      background: 'radial-gradient(circle, rgba(52,199,123,.12) 0%, rgba(52,199,123,0) 66%)' }} />
  </AbsoluteFill>
);

/** The close: the name, the line it stands for, and the four ways it joins up. */
const Close: React.FC<{ t: number; at: number; line: string }> = ({ t, at, line }) => {
  if (t < at) return null;
  const icon = pop(t, at + 0.18, 10, 0.68);
  const name = ramp(t, at + 0.45, at + 0.95, Easing.out(Easing.cubic));
  const rule = ramp(t, at + 0.8, at + 1.5, glide);
  const sub = ramp(t, at + 1.0, at + 1.5, Easing.out(Easing.cubic));
  return (
    <AbsoluteFill style={{ alignItems: 'center', justifyContent: 'center', fontFamily: FONT, color: '#F6F8FC' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginTop: -40 }}>
        <Img src={staticFile('icon.png')} style={{ width: 240, height: 240, borderRadius: 54, boxShadow: '0 34px 80px rgba(0,0,0,.55)', opacity: clamp(icon * 1.4), transform: `scale(${0.6 + 0.4 * icon})` }} />
        <div style={{ marginTop: 50, fontWeight: 900, fontSize: 150, letterSpacing: 10, lineHeight: 1, opacity: name, transform: `translateY(${(1 - name) * 30}px)` }}>一路</div>
        <div style={{ marginTop: 16, fontFamily: LATIN, fontWeight: 600, fontSize: 42, letterSpacing: 6, opacity: 0.82 * name }}>OneRoad</div>
        <div style={{ marginTop: 44, width: 440 * rule, height: 6, borderRadius: 3, background: C.amber }} />
        <div style={{ marginTop: 36, fontWeight: 700, fontSize: 40, letterSpacing: 2, color: C.amber, opacity: sub, transform: `translateY(${(1 - sub) * 18}px)` }}>{line}</div>
        <div style={{ marginTop: 46, display: 'flex', gap: 16 }}>
          {['公車', '捷運', 'YouBike', '步行'].map((mode, i) => {
            const k = pop(t, at + 1.35 + i * 0.12, 12, 0.7);
            return <div key={mode} style={{ padding: '12px 26px 14px', borderRadius: 40, boxShadow: 'inset 0 0 0 2px rgba(246,248,252,.5)', fontWeight: 700, fontSize: 32,
              letterSpacing: 1, opacity: clamp(k * 1.5), transform: `scale(${0.7 + 0.3 * k})` }}>{mode}</div>;
          })}
        </div>
      </div>
    </AbsoluteFill>
  );
};

export const StorePreview: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / PREVIEW.fps;
  const starts = CUT.clips.map((c) => c.t ?? TM.slots[c.line].start + (c.at ?? 0));
  const leave = ramp(t, TM.end - 0.12, TM.end + 0.4, glide);
  // The lights step sideways as each line begins.
  const line = TM.slots.reduce((sum, slot) => sum + ramp(t, slot.start - 0.1, slot.start + 0.7, glide), 0) - 1;
  return (
    <AbsoluteFill style={{ background: C.night }}>
      <Page t={t} line={line} />
      {CUT.clips.map((clip, i) => (
        <Screen key={i} clip={clip} t={t} leave={leave} start={starts[i]} end={i + 1 < starts.length ? starts[i + 1] : TM.end + 0.5}
          next={i + 1 < starts.length ? CUT.clips[i + 1].enter ?? 'left' : undefined} />
      ))}
      {EP.lines.map((item, j) => {
        const slot = TM.slots[j];
        return <Headline key={j} index={j} text={item.text} kicker={CUT.kickers[j] ?? ''} t={t} start={slot.start + 0.06} speak={slot.voiceLength || slot.length * 0.6}
          end={Math.min(slot.start + slot.length, TM.end) - 0.02} />;
      })}
      <Close t={t} at={TM.end} line={EP.endLine} />
      <Audio src={staticFile('audio/store.mp3')} />
    </AbsoluteFill>
  );
};
