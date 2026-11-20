import React from 'react';
import { AbsoluteFill, Audio, Easing, staticFile, useCurrentFrame } from 'remotion';
import script from './episodes.json';
import timings from './timing.json';
import './fonts';
import { BEAT, Caption, EndCard, FPS, Headline, Phone, Pose, Rect, Stage, Sticker, Tag, Tap, clamp, lerp, pop, ramp } from './kit';
import { ThemeName } from './theme';

/** `on`: the screen (of this shot's swaps) the region belongs to; the shot's first screen when left out. */
type Lift = { rect: Rect; z?: number; at: number; out?: number; glow?: boolean; on?: string };
type Shot = {
  /** The line this shot belongs to (its own position when left out) and the beat of that line it starts on. */
  line?: number;
  from?: number;
  screen: string;
  pose: Pose;
  /** How the phone gets here: rise from below (first shot), turn like a card and show the new screen, or glide (default). */
  enter?: 'rise' | 'flip' | 'glide';
  /** A slow push in over the shot, as a fraction of the scale. */
  drift?: number;
  lifts?: Lift[];
  taps?: { x: number; y: number; at: number }[];
  stickers?: { text: string; sub?: string; x: number; y: number; at: number; out?: number; tone?: 'amber' | 'paper' | 'night' | 'go'; tilt?: number; size?: number }[];
  /** Screens that follow within the shot: pushed in from the right or cross-faded, at a beat. */
  swaps?: { at: number; screen: string; how?: 'slide' | 'fade' }[];
  dim?: number;
};
type Episode = {
  id: string; label: string; theme: ThemeName; title: string; endLine: string; outro: string; note?: string;
  lines: { text: string; say?: string; beats?: number }[];
  shots: Shot[];
};
type Timing = { total: number; end: number; slots: { start: number; length: number; voiceStart: number; voiceLength: number }[] };

export const EPISODES = (script as unknown as { episodes: Episode[] }).episodes;
const TIMING = timings as unknown as Record<string, Timing>;
export const reelFrames = (id: string) => Math.max(60, Math.round((TIMING[id]?.total ?? 10) * FPS));

const inOut = Easing.bezier(0.45, 0, 0.2, 1);
const mix = (a: Pose, b: Pose, k: number): Pose => ({
  x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k), s: lerp(a.s, b.s, k),
  rx: lerp(a.rx ?? 0, b.rx ?? 0, k), ry: lerp(a.ry ?? 0, b.ry ?? 0, k), rz: lerp(a.rz ?? 0, b.rz ?? 0, k),
});

export const Reel: React.FC<{ id: string }> = ({ id }) => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const ep = EPISODES.find((e) => e.id === id)!;
  const tm = TIMING[id];
  // Shots in order of time: each runs from its start to the next one's (the last to the end card).
  const starts = ep.shots.map((s, j) => tm.slots[s.line ?? j].start + (s.from ?? 0) * BEAT);
  let i = 0;
  for (let j = 0; j < starts.length; j++) if (t >= starts[j]) i = j;
  const shot = ep.shots[i];
  const prev = i > 0 ? ep.shots[i - 1] : null;
  const slot = { start: starts[i], length: (i + 1 < starts.length ? starts[i + 1] : tm.end) - starts[i] };
  const local = t - slot.start;
  const beat = (b: number) => slot.start + b * BEAT;

  // The camera: from where the last shot left the phone to this shot's pose, then a slow push in.
  const drifted = (s: Shot, k: number): Pose => ({ ...s.pose, s: s.pose.s * (1 + (s.drift ?? 0.03) * k) });
  const arrive = Math.min(shot.enter === 'flip' ? 0.7 : 0.75, slot.length * 0.8);
  const k = ramp(t, slot.start - 0.02, slot.start + arrive, inOut);
  const from = prev ? drifted(prev, 1) : { ...shot.pose, y: shot.pose.y + 1500, s: shot.pose.s * 0.92, rx: 18 };
  let pose = mix(from, drifted(shot, clamp(local / slot.length)), k);
  if (!prev) {
    const rise = pop(t, 0.1, 9, 0.72);
    pose = mix(from, drifted(shot, clamp(local / slot.length)), rise);
  }
  // A card flip: edge-on at the half-way point, where the screen changes.
  let showPrev = false;
  if (shot.enter === 'flip' && prev) {
    const f = ramp(t, slot.start, slot.start + arrive, inOut);
    if (f < 0.5) { pose.ry = (pose.ry ?? 0) + f * 2 * 90; showPrev = true; }
    else pose.ry = (pose.ry ?? 0) - (1 - f) * 2 * 90;
  } else if (prev && prev.screen !== shot.screen && k < 0.5) {
    showPrev = false; // cross-faded below
  }
  // A gentle sway so the phone is never frozen.
  pose.ry = (pose.ry ?? 0) + Math.sin(t * 1.1) * 0.9;
  pose.rx = (pose.rx ?? 0) + Math.cos(t * 0.8) * 0.5;

  // What the glass shows.
  const lastOf = (s: Shot) => (s.swaps?.length ? s.swaps[s.swaps.length - 1].screen : s.screen);
  const screens: { name: string; opacity?: number; shift?: number }[] = [];
  if (shot.enter === 'flip' && prev && showPrev) screens.push({ name: lastOf(prev) });
  else {
    if (prev && lastOf(prev) !== shot.screen && shot.enter !== 'flip') {
      const fade = ramp(t, slot.start + 0.1, slot.start + 0.55, inOut);
      if (fade < 1) screens.push({ name: lastOf(prev) });
      screens.push({ name: shot.screen, opacity: fade });
    } else screens.push({ name: shot.screen });
    for (const swap of shot.swaps ?? []) {
      const s = ramp(t, beat(swap.at), beat(swap.at) + 0.45, inOut);
      if (s <= 0) continue;
      if (swap.how === 'fade') screens.push({ name: swap.screen, opacity: s });
      else screens.push({ name: swap.screen, shift: 1 - s });
    }
  }
  const topScreen = screens[screens.length - 1].name;
  const settled = lastVisible(shot, t, beat);
  const lifts = (shot.lifts ?? []).filter((l) => topScreen === settled && (l.on ?? shot.screen) === settled).map((l) => ({
    rect: l.rect, z: l.z ?? 120, glow: l.glow,
    k: pop(t, beat(l.at), 13, 0.6) * (1 - ramp(t, l.out != null ? beat(l.out) : slot.start + slot.length - 0.28, (l.out != null ? beat(l.out) : slot.start + slot.length - 0.28) + 0.26, Easing.in(Easing.cubic))),
  }));

  const end = tm.end;
  return (
    <AbsoluteFill>
      <Stage theme={ep.theme} t={t} dim={shot.dim ? shot.dim * ramp(t, slot.start, slot.start + 0.5) : 0}>
        <Tag label={ep.label} t={t} ink={ep.theme === 'mist' || ep.theme === 'sand' ? '#152030' : '#F7FAFF'} />
        <Phone pose={pose} screens={screens} lifts={lifts} shine={Math.sin(t * 0.7) * 0.5 + (pose.ry ?? 0) / 60}>
          {(shot.taps ?? []).map((tap, j) => <Tap key={j} x={tap.x} y={tap.y} t={t} at={beat(tap.at)} />)}
        </Phone>
        <Headline text={ep.title} t={t} theme={ep.theme} out={tm.slots[0].start + tm.slots[0].length - 0.3} />
        {(shot.stickers ?? []).map((s, j) => (
          <Sticker key={`${i}-${j}`} text={s.text} sub={s.sub} x={s.x} y={s.y} t={t} at={beat(s.at)} out={s.out != null ? beat(s.out) : slot.start + slot.length - 0.2}
            tone={s.tone} tilt={s.tilt} size={s.size} />
        ))}
        {ep.lines.map((line, j) => {
          const sl = tm.slots[j];
          if (j === 0) return null; // the cover's headline is its caption
          return <Caption key={j} text={line.text} t={t} start={sl.start + 0.04} speak={sl.voiceLength || sl.length * 0.6} end={Math.min(sl.start + sl.length, end) - 0.02} />;
        })}
      </Stage>
      <EndCard t={t} at={end} line={ep.endLine} cta={ep.outro} note={ep.note} />
      <Audio src={staticFile(`audio/${id}.mp3`)} />
    </AbsoluteFill>
  );
};

/** The screen that is fully on the glass at `t` within a shot (lifts only rise from a settled screen). */
function lastVisible(shot: Shot, t: number, beat: (b: number) => number) {
  let name = shot.screen;
  for (const swap of shot.swaps ?? []) if (t >= beat(swap.at) + 0.4) name = swap.screen;
  return name;
}
