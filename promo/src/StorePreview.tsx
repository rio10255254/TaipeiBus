import React from 'react';
import { AbsoluteFill, Audio, Easing, Img, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import script from './episodes.json';
import cut from './preview.json';
import timings from './timing.json';
import { FONT, LATIN } from './fonts';
import { clamp, lerp, pop, ramp } from './kit';
import { C } from './theme';

/**
 * The App Store's app preview. Apple allows only screen recordings of the app itself, with captions
 * and touch marks over them, so there is no phone frame or page here: the recording fills the frame
 * (886 × 1920, 30 fps) and everything else sits on top of it.
 *
 * The recordings play at the speed they were made. What keeps the film moving between the app's own
 * animations is the edit: every shot has a camera that drifts or pushes in on what the line is about,
 * and shots arrive by sliding or pushing through rather than dissolving.
 */
export const PREVIEW = { w: 886, h: 1920, fps: 30 };
const { w: W, h: H } = PREVIEW;

/** Where the camera looks (a point in the recording, in frame pixels) and how close, at a second of the shot. */
type Key = { at: number; x?: number; y?: number; s?: number };
type Enter = 'cut' | 'left' | 'right' | 'up' | 'through';
type Clip = {
  /** The line this footage plays under, and how many seconds into that line it cuts in (or `t`, a second of the film). */
  line: number; at?: number; t?: number;
  /** A file in public/preview, the second of it on screen at the cut, and how fast it plays. */
  file: string; from: number; rate?: number;
  /** How the shot arrives over the one before. */
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
/** `captions`: how far down the frame each line's caption sits, chosen so it never covers what the line is about. */
const CUT = cut as unknown as { captions: number[]; clips: Clip[] };
export const previewFrames = Math.round(TM.total * PREVIEW.fps);

/** A shot starts arriving this long before its cut and has landed this long after. */
const LEAD = 0.14;
const LAND = 0.34;
const glide = Easing.bezier(0.45, 0, 0.2, 1);
const arrive = Easing.bezier(0.16, 0.84, 0.24, 1);

function cameraAt(clip: Clip, local: number, length: number) {
  const keys = clip.camera?.length ? clip.camera : [{ at: 0, s: 1 }, { at: length, s: 1.04 }];
  let a = keys[0], b = keys[keys.length - 1];
  for (let i = 0; i + 1 < keys.length; i++) if (local >= keys[i].at) { a = keys[i]; b = keys[i + 1]; }
  const k = b.at > a.at ? glide(clamp((local - a.at) / (b.at - a.at))) : 0;
  const s = lerp(a.s ?? 1, b.s ?? 1, k);
  const x = lerp(a.x ?? W / 2, b.x ?? W / 2, k), y = lerp(a.y ?? H / 2, b.y ?? H / 2, k);
  // The point looked at goes to the middle of the frame, as far as the picture's edges allow.
  return { s, tx: Math.min(0, Math.max(W - W * s, W / 2 - x * s)), ty: Math.min(0, Math.max(H - H * s, H / 2 - y * s)) };
}

const Touch: React.FC<{ x: number; y: number; t: number; at: number }> = ({ x, y, t, at }) => {
  if (t < at - 0.3 || t > at + 0.9) return null;
  const down = ramp(t, at - 0.26, at, Easing.out(Easing.cubic)) * (1 - ramp(t, at + 0.1, at + 0.45));
  const ring = ramp(t, at, at + 0.6, Easing.out(Easing.cubic)), ring2 = ramp(t, at + 0.12, at + 0.85, Easing.out(Easing.cubic));
  const circle = (size: number, k: number, width: number) => (
    <div style={{ position: 'absolute', left: -size / 2, top: -size / 2, width: size, height: size, borderRadius: '50%',
      border: `${width}px solid rgba(255,185,64,${0.95 * (1 - k)})`, transform: `scale(${0.4 + k * 1.25})` }} />
  );
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: 0, height: 0 }}>
      {circle(150, ring, 5)}
      {t > at + 0.12 ? circle(210, ring2, 3) : null}
      <div style={{ position: 'absolute', left: -38, top: -38, width: 76, height: 76, borderRadius: '50%', background: 'rgba(255,255,255,.92)',
        boxShadow: '0 8px 22px rgba(10,20,40,.5), inset 0 0 0 4px rgba(255,185,64,.95)', opacity: down, transform: `scale(${1.35 - 0.35 * down})` }} />
    </div>
  );
};

const Shot: React.FC<{ clip: Clip; start: number; end: number; next?: Enter; t: number }> = ({ clip, start, end, next, t }) => {
  const rate = clip.rate ?? 1;
  const enter = start <= 0 ? 'cut' : clip.enter ?? 'left';
  const lead = enter === 'cut' ? 0 : Math.min(LEAD, clip.from / rate);
  const first = Math.round((start - lead) * PREVIEW.fps);
  const last = Math.round((end + LAND + 0.05) * PREVIEW.fps);
  const local = t - start, length = end - start;
  const cam = cameraAt(clip, Math.max(0, local), length);
  // Arriving over the last shot, and later giving way to the next.
  const inK = enter === 'cut' ? 1 : arrive(clamp((t - (start - lead)) / (lead + LAND)));
  const outK = next && next !== 'cut' ? arrive(clamp((t - (end - LEAD)) / (LEAD + LAND))) : 0;
  let x = 0, y = 0, scale = 1, opacity = 1;
  if (enter === 'left') x += (1 - inK) * W;
  if (enter === 'right') x -= (1 - inK) * W;
  if (enter === 'up') { y += (1 - inK) * H * 0.55; opacity *= clamp(inK * 2.2); }
  if (enter === 'through') { scale *= 0.82 + 0.18 * inK; opacity *= clamp(inK * 1.6); }
  if (next === 'left') { x -= outK * W * 0.28; }
  if (next === 'right') { x += outK * W * 0.28; }
  if (next === 'up') { scale *= 1 - 0.06 * outK; }
  if (next === 'through') { scale *= 1 + 0.34 * outK; opacity *= 1 - outK; }
  const shade = next && next !== 'through' ? 0.42 * outK : 0;
  const moving = inK < 1 && enter !== 'cut';
  return (
    <Sequence from={first} durationInFrames={Math.max(1, last - first)} layout="none">
      <AbsoluteFill style={{ transform: `translate(${x}px, ${y}px) scale(${scale})`, opacity, overflow: 'hidden',
        borderRadius: moving ? 44 * (1 - inK) : 0, boxShadow: moving ? `0 0 ${90 * (1 - inK) + 30}px rgba(4,8,18,${0.55 * (1 - inK * 0.6)})` : undefined }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, transformOrigin: '0 0', transform: `translate(${cam.tx}px, ${cam.ty}px) scale(${cam.s})` }}>
          <OffthreadVideo src={staticFile(`preview/${clip.file}`)} muted startFrom={Math.max(0, Math.round((clip.from - lead * rate) * PREVIEW.fps))} playbackRate={rate}
            style={{ position: 'absolute', left: 0, top: 0, width: W, height: H, objectFit: 'cover' }} />
          {(clip.spots ?? []).map((spot, j) => {
            const k = ramp(local, spot.at, spot.at + 0.35, glide) * (1 - ramp(local, spot.until, spot.until + 0.3, glide));
            if (k <= 0.002) return null;
            const [x0, y0, x1, y1] = spot.rect;
            return <div key={j} style={{ position: 'absolute', left: x0, top: y0, width: x1 - x0, height: y1 - y0, borderRadius: spot.radius ?? 36,
              boxShadow: `0 0 0 3000px rgba(10,16,28,${0.46 * k}), inset 0 0 0 ${4 * k}px rgba(255,185,64,${0.95 * k})` }} />;
          })}
          {(clip.taps ?? []).map((tap, j) => <Touch key={j} x={tap.x} y={tap.y} t={local} at={tap.at} />)}
        </div>
        {shade ? <AbsoluteFill style={{ background: `rgba(8,12,22,${shade})` }} /> : null}
      </AbsoluteFill>
    </Sequence>
  );
};

const runs = (text: string) => text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((part) =>
  part.startsWith('**') ? { text: part.slice(2, -2), mark: true } : { text: part, mark: false });

/** The line being spoken. The preview plays muted by default, so this carries the film on its own. */
const Caption: React.FC<{ text: string; top: number; t: number; start: number; speak: number; end: number }> = ({ text, top, t, start, speak, end }) => {
  const out = ramp(t, end - 0.2, end, Easing.in(Easing.cubic));
  if (t < start - 0.02 || out >= 1) return null;
  const spring = pop(t, start, 11, 0.62);
  const parts = runs(text);
  const total = parts.reduce((n, p) => n + [...p.text.replace(/\n/g, '')].length, 0);
  const shown = clamp((t - start - 0.08) / Math.max(0.3, speak * 0.8)) * total;
  let seen = 0;
  const away = top < H / 2 ? -1 : 1;
  return (
    <div style={{ position: 'absolute', left: 44, right: 44, top, display: 'flex', justifyContent: 'center', opacity: clamp(spring * 1.6) * (1 - out),
      transform: `translateY(${((1 - spring) * 46 + out * 30) * away}px) scale(${0.9 + 0.1 * spring})` }}>
      <div style={{ background: 'rgba(14,20,31,.93)', borderRadius: 36, padding: '26px 40px 30px', boxShadow: '0 22px 54px rgba(4,8,18,.45), inset 0 0 0 2px rgba(255,255,255,.08)',
        fontFamily: FONT, fontWeight: 900, fontSize: 56, lineHeight: 1.3, letterSpacing: 1, color: '#F6F8FC', textAlign: 'center', whiteSpace: 'pre-wrap' }}>
        {parts.map((p, i) => (
          <span key={i} style={{ color: p.mark ? C.amber : undefined }}>
            {[...p.text].map((ch, j) => {
              if (ch === '\n') return <br key={j} />;
              const k = clamp(shown - seen++);
              return <span key={j} style={{ opacity: 0.18 + 0.82 * k, display: 'inline-block', transform: `translateY(${(1 - k) * 9}px) scale(${0.94 + 0.06 * k})` }}>{ch}</span>;
            })}
          </span>
        ))}
      </div>
    </div>
  );
};

/** The close: the app keeps running underneath, softened, with its name over it. */
const Close: React.FC<{ t: number; at: number; line: string }> = ({ t, at, line }) => {
  if (t < at - 0.1) return null;
  const dim = ramp(t, at - 0.1, at + 0.5, glide);
  const icon = pop(t, at + 0.12, 10, 0.68);
  const name = ramp(t, at + 0.4, at + 0.9, Easing.out(Easing.cubic));
  const rule = ramp(t, at + 0.75, at + 1.5, glide);
  const sub = ramp(t, at + 0.95, at + 1.45, Easing.out(Easing.cubic));
  return (
    <AbsoluteFill style={{ background: `rgba(14,20,31,${0.8 * dim})`, alignItems: 'center', justifyContent: 'center', fontFamily: FONT, color: '#F6F8FC' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginTop: -60 }}>
        <Img src={staticFile('icon.png')} style={{ width: 232, height: 232, borderRadius: 52, boxShadow: '0 30px 70px rgba(0,0,0,.5)', opacity: clamp(icon * 1.4), transform: `scale(${0.6 + 0.4 * icon})` }} />
        <div style={{ marginTop: 46, fontWeight: 900, fontSize: 148, letterSpacing: 10, lineHeight: 1, opacity: name, transform: `translateY(${(1 - name) * 28}px)` }}>一路</div>
        <div style={{ marginTop: 14, fontFamily: LATIN, fontWeight: 600, fontSize: 42, letterSpacing: 6, opacity: 0.82 * name }}>OneRoad</div>
        <div style={{ marginTop: 40, width: 420 * rule, height: 6, borderRadius: 3, background: C.amber }} />
        <div style={{ marginTop: 34, fontWeight: 700, fontSize: 40, letterSpacing: 2, color: C.amber, opacity: sub, transform: `translateY(${(1 - sub) * 18}px)` }}>{line}</div>
      </div>
    </AbsoluteFill>
  );
};

export const StorePreview: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / PREVIEW.fps;
  const starts = CUT.clips.map((c) => c.t ?? TM.slots[c.line].start + (c.at ?? 0));
  return (
    <AbsoluteFill style={{ background: C.night }}>
      {/* Under the close the app goes soft, so its own text does not sit behind the name. */}
      <AbsoluteFill style={{ filter: t > TM.end - 0.1 ? `blur(${14 * ramp(t, TM.end - 0.1, TM.end + 0.6, glide)}px)` : undefined }}>
        {CUT.clips.map((clip, i) => (
          <Shot key={i} clip={clip} t={t} start={starts[i]} end={i + 1 < starts.length ? starts[i + 1] : TM.total}
            next={i + 1 < starts.length ? CUT.clips[i + 1].enter ?? 'left' : undefined} />
        ))}
      </AbsoluteFill>
      {EP.lines.map((line, j) => {
        const slot = TM.slots[j];
        return <Caption key={j} text={line.text} top={CUT.captions[j] ?? 150} t={t} start={slot.start + 0.1} speak={slot.voiceLength || slot.length * 0.6}
          end={Math.min(slot.start + slot.length, TM.end) - 0.04} />;
      })}
      <Close t={t} at={TM.end} line={EP.endLine} />
      <Audio src={staticFile('audio/store.mp3')} />
    </AbsoluteFill>
  );
};
