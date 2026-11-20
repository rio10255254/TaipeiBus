import React from 'react';
import { AbsoluteFill, Audio, Easing, Img, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from 'remotion';
import script from './episodes.json';
import cut from './preview.json';
import timings from './timing.json';
import { FONT, LATIN } from './fonts';
import { clamp, pop, ramp } from './kit';
import { C } from './theme';

/**
 * The App Store's app preview. Apple allows only screen recordings of the app itself, with captions
 * and touch marks over them, so there is no phone frame or page here: the recording fills the frame
 * (886 × 1920, 30 fps) and everything else sits on top of it.
 */
export const PREVIEW = { w: 886, h: 1920, fps: 30 };

type Clip = {
  /** The line this footage plays under, and how many seconds into that line it cuts in. */
  line: number; at?: number;
  /** A file in public/preview, and the second of it that is on screen at the cut. */
  file: string; from: number; rate?: number;
  /** Touch marks, in seconds after the cut and in picture pixels. */
  taps?: { at: number; x: number; y: number }[];
};
type Line = { text: string };
type Timing = { total: number; end: number; slots: { start: number; length: number; voiceLength: number }[] };

const EP = (script as unknown as { episodes: { id: string; endLine: string; lines: Line[] }[] }).episodes.find((e) => e.id === 'store')!;
const TM = (timings as unknown as Record<string, Timing>).store;
const CUT = cut as unknown as { captions: ('top' | 'bottom')[]; clips: Clip[] };
export const previewFrames = Math.round(TM.total * PREVIEW.fps);

const FADE = 0.3;
const inOut = Easing.bezier(0.45, 0, 0.2, 1);

const Footage: React.FC<{ clip: Clip; start: number; end: number; t: number }> = ({ clip, start, end, t }) => {
  // On screen from just before its cut (fading in over the last clip) until the next has covered it.
  const rate = clip.rate ?? 1;
  const lead = start <= 0 ? 0 : Math.min(FADE, clip.from / rate);
  const first = Math.round((start - lead) * PREVIEW.fps);
  return (
    <Sequence from={first} durationInFrames={Math.max(1, Math.round((end + 0.05) * PREVIEW.fps) - first)} layout="none">
      <AbsoluteFill style={{ opacity: lead ? ramp(t, start - lead, start, inOut) : 1 }}>
        <OffthreadVideo src={staticFile(`preview/${clip.file}`)} muted startFrom={Math.round((clip.from - lead * rate) * PREVIEW.fps)} playbackRate={rate}
          style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
      </AbsoluteFill>
    </Sequence>
  );
};

const Touch: React.FC<{ x: number; y: number; t: number; at: number }> = ({ x, y, t, at }) => {
  if (t < at - 0.3 || t > at + 0.75) return null;
  const down = ramp(t, at - 0.28, at) * (1 - ramp(t, at + 0.12, at + 0.5));
  const ring = ramp(t, at, at + 0.6, Easing.out(Easing.cubic));
  const size = 150;
  return (
    <div style={{ position: 'absolute', left: x, top: y, width: 0, height: 0 }}>
      <div style={{ position: 'absolute', left: -size / 2, top: -size / 2, width: size, height: size, borderRadius: '50%',
        border: `5px solid rgba(255,185,64,${0.95 * (1 - ring)})`, transform: `scale(${0.45 + ring * 1.2})` }} />
      <div style={{ position: 'absolute', left: -38, top: -38, width: 76, height: 76, borderRadius: '50%', background: 'rgba(255,255,255,.9)',
        boxShadow: '0 8px 22px rgba(10,20,40,.5), inset 0 0 0 4px rgba(255,185,64,.9)', opacity: down, transform: `scale(${1.3 - 0.3 * down})` }} />
    </div>
  );
};

const runs = (text: string) => text.split(/(\*\*[^*]+\*\*)/).filter(Boolean).map((part) =>
  part.startsWith('**') ? { text: part.slice(2, -2), mark: true } : { text: part, mark: false });

/** The line being spoken. The preview plays muted by default, so this carries the film on its own. */
const Caption: React.FC<{ text: string; where: 'top' | 'bottom'; t: number; start: number; speak: number; end: number }> = ({ text, where, t, start, speak, end }) => {
  const show = ramp(t, start, start + 0.24) * (1 - ramp(t, end - 0.18, end, Easing.in(Easing.cubic)));
  if (show <= 0.002) return null;
  const parts = runs(text);
  const total = parts.reduce((n, p) => n + [...p.text.replace(/\n/g, '')].length, 0);
  const shown = clamp((t - start - 0.05) / Math.max(0.3, speak * 0.8)) * total;
  let seen = 0;
  const away = where === 'top' ? -1 : 1;
  return (
    <div style={{ position: 'absolute', left: 44, right: 44, ...(where === 'top' ? { top: 150 } : { bottom: 170 }), display: 'flex', justifyContent: 'center',
      opacity: show, transform: `translateY(${(1 - show) * 24 * away}px)` }}>
      <div style={{ background: 'rgba(14,20,31,.93)', borderRadius: 36, padding: '26px 40px 30px', boxShadow: '0 22px 54px rgba(4,8,18,.45), inset 0 0 0 2px rgba(255,255,255,.08)',
        fontFamily: FONT, fontWeight: 900, fontSize: 56, lineHeight: 1.3, letterSpacing: 1, color: '#F6F8FC', textAlign: 'center', whiteSpace: 'pre-wrap' }}>
        {parts.map((p, i) => (
          <span key={i} style={{ color: p.mark ? C.amber : undefined }}>
            {[...p.text].map((ch, j) => {
              if (ch === '\n') return <br key={j} />;
              const k = clamp(shown - seen++);
              return <span key={j} style={{ opacity: 0.18 + 0.82 * k, display: 'inline-block', transform: `translateY(${(1 - k) * 7}px)` }}>{ch}</span>;
            })}
          </span>
        ))}
      </div>
    </div>
  );
};

/** The close: the app keeps running underneath, dimmed, with its name over it. */
const Close: React.FC<{ t: number; at: number; line: string }> = ({ t, at, line }) => {
  if (t < at - 0.1) return null;
  const dim = ramp(t, at - 0.1, at + 0.5, inOut);
  const icon = pop(t, at + 0.15, 10, 0.7);
  const name = ramp(t, at + 0.45, at + 0.95, Easing.out(Easing.cubic));
  const sub = ramp(t, at + 0.9, at + 1.4, Easing.out(Easing.cubic));
  return (
    <AbsoluteFill style={{ background: `rgba(14,20,31,${0.86 * dim})`, alignItems: 'center', justifyContent: 'center', fontFamily: FONT, color: '#F6F8FC' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', marginTop: -60 }}>
        <Img src={staticFile('icon.png')} style={{ width: 232, height: 232, borderRadius: 52, boxShadow: '0 30px 70px rgba(0,0,0,.5)', opacity: clamp(icon * 1.4), transform: `scale(${0.6 + 0.4 * icon})` }} />
        <div style={{ marginTop: 46, fontWeight: 900, fontSize: 148, letterSpacing: 10, lineHeight: 1, opacity: name, transform: `translateY(${(1 - name) * 24}px)` }}>一路</div>
        <div style={{ marginTop: 14, fontFamily: LATIN, fontWeight: 600, fontSize: 42, letterSpacing: 6, opacity: 0.82 * name }}>OneRoad</div>
        <div style={{ marginTop: 54, fontWeight: 700, fontSize: 40, letterSpacing: 2, color: C.amber, opacity: sub, transform: `translateY(${(1 - sub) * 16}px)` }}>{line}</div>
      </div>
    </AbsoluteFill>
  );
};

export const StorePreview: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / PREVIEW.fps;
  const starts = CUT.clips.map((c) => TM.slots[c.line].start + (c.at ?? 0));
  return (
    <AbsoluteFill style={{ background: C.night }}>
      {CUT.clips.map((clip, i) => (
        <Footage key={i} clip={clip} t={t} start={starts[i]} end={i + 1 < starts.length ? starts[i + 1] : TM.total} />
      ))}
      {CUT.clips.map((clip, i) => (clip.taps ?? []).map((tap, j) => <Touch key={`${i}-${j}`} x={tap.x} y={tap.y} t={t} at={starts[i] + tap.at} />))}
      {EP.lines.map((line, j) => {
        const slot = TM.slots[j];
        return <Caption key={j} text={line.text} where={CUT.captions[j] ?? 'top'} t={t} start={slot.start + 0.08} speak={slot.voiceLength || slot.length * 0.6}
          end={Math.min(slot.start + slot.length, TM.end) - 0.04} />;
      })}
      <Close t={t} at={TM.end} line={EP.endLine} />
      <Audio src={staticFile('audio/store.mp3')} />
    </AbsoluteFill>
  );
};
