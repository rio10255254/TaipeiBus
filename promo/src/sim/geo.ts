import { LngLat } from './SimMap';

/** Metres per degree at Taipei's latitude: enough for shapes a few hundred metres across. */
const EAST = 100_900, NORTH = 110_800;
export const metres = (a: LngLat, b: LngLat) => Math.hypot((a[0] - b[0]) * EAST, (a[1] - b[1]) * NORTH);

export type Path = { points: LngLat[]; at: number[]; length: number };
export const path = (points: LngLat[]): Path => {
  const at = [0];
  for (let i = 1; i < points.length; i++) at.push(at[i - 1] + metres(points[i - 1], points[i]));
  return { points, at, length: at[at.length - 1] };
};

/** The place `distance` metres along a path, and the compass heading of travel there. */
export const along = (p: Path, distance: number): { at: LngLat; heading: number } => {
  const d = Math.min(Math.max(distance, 0), p.length - 0.001);
  let i = 1;
  while (i < p.at.length - 1 && p.at[i] < d) i++;
  const a = p.points[i - 1], b = p.points[i];
  const k = (d - p.at[i - 1]) / Math.max(1e-6, p.at[i] - p.at[i - 1]);
  return { at: [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k], heading: (Math.atan2((b[0] - a[0]) * EAST, (b[1] - a[1]) * NORTH) * 180) / Math.PI };
};

/** The part of a path travelled so far. */
export const upTo = (p: Path, distance: number): LngLat[] => {
  const out: LngLat[] = [];
  for (let i = 0; i < p.points.length && p.at[i] < distance; i++) out.push(p.points[i]);
  if (distance > 0) out.push(along(p, distance).at);
  return out;
};

/** A point `forward` and `right` metres from a place facing `heading`. */
export const from = (at: LngLat, heading: number, forward: number, right: number): LngLat => {
  const h = (heading * Math.PI) / 180;
  return [at[0] + (Math.sin(h) * forward + Math.cos(h) * right) / EAST, at[1] + (Math.cos(h) * forward - Math.sin(h) * right) / NORTH];
};

/** A rectangle on the ground, centred on a place and turned to a heading. */
export const box = (at: LngLat, heading: number, length: number, width: number, forward = 0): LngLat[] => {
  const c = [[length / 2, -width / 2], [length / 2, width / 2], [-length / 2, width / 2], [-length / 2, -width / 2], [length / 2, -width / 2]];
  return c.map(([f, r]) => from(at, heading, f + forward, r));
};

export const disc = (at: LngLat, radius: number, sides = 40): LngLat[] =>
  Array.from({ length: sides + 1 }, (_, i) => from(at, (i / sides) * 360, radius, 0));

/** The shorter way round from one heading to another. */
export const turn = (to: number, fromHeading: number) => ((to - fromHeading + 540) % 360) - 180;
