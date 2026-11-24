import maplibregl, { GeoJSONSource, Map as MapLibre } from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import React, { useEffect, useRef, useState } from 'react';
import { continueRender, delayRender, useCurrentFrame } from 'remotion';
import style from './style.json';

/**
 * The app's map, drawn here frame by frame with the app's own style and the same tiles. Nothing is
 * played back: every frame sets the camera and everything on the map, waits until the map has
 * finished drawing, and only then lets the frame be taken. That is why it cannot stutter.
 *
 * Sizes are in the phone's points (443 × 960 at 2×), as in the app, so labels and line widths match.
 */
export type LngLat = [number, number];
export type Camera = { center: LngLat; zoom: number; bearing?: number; pitch?: number; /** Points kept clear at the bottom (a sheet), which lifts the centre. */ lift?: number;
  /** How solid the buildings are; the app thins them around a bus it is following. */ buildings?: number };
export type Line = { coords: LngLat[]; color: string; width: number; casing?: string; dotted?: boolean; opacity?: number };
export type Solid = { ring: LngLat[]; base: number; height: number; color: string };
export type Flat = { ring: LngLat[]; color: string; opacity: number };
export type Dot = { at: LngLat; color: string; radius: number; stroke?: string; strokeWidth?: number };
export type Projected = Record<string, { x: number; y: number }>;

const POINTS = { w: 443, h: 960 };
const collection = (features: object[]) => ({ type: 'FeatureCollection', features }) as never;

export const SimMap: React.FC<{
  camera: Camera; lines?: Line[]; solids?: Solid[]; flats?: Flat[]; dots?: Dot[];
  /** Places whose position on screen the overlays need (returned in the recording's 886 × 1920 pixels). */
  anchors?: Record<string, LngLat>;
  children?: (at: Projected) => React.ReactNode;
}> = ({ camera, lines = [], solids = [], flats = [], dots = [], anchors = {}, children }) => {
  const frame = useCurrentFrame();
  const holder = useRef<HTMLDivElement>(null);
  const map = useRef<MapLibre | null>(null);
  const [ready, setReady] = useState(false);
  const [at, setAt] = useState<Projected>({});
  const [opening] = useState(() => delayRender('The map is loading', { timeoutInMilliseconds: 280000 }));

  useEffect(() => {
    const made = new maplibregl.Map({
      container: holder.current!, style: style as never, interactive: false, attributionControl: false, fadeDuration: 0,
      pixelRatio: 2, preserveDrawingBuffer: true, center: camera.center, zoom: camera.zoom, bearing: camera.bearing ?? 0, pitch: camera.pitch ?? 0,
      maxPitch: 75,
    } as never);
    made.on('load', () => {
      const empty = collection([]);
      for (const id of ['sim-lines', 'sim-flats', 'sim-dots', 'sim-solids']) made.addSource(id, { type: 'geojson', data: empty });
      const under = made.getLayer('building-3d') ? 'building-3d' : undefined;
      made.addLayer({ id: 'sim-flats', type: 'fill', source: 'sim-flats', paint: { 'fill-color': ['get', 'color'], 'fill-opacity': ['get', 'opacity'] } }, under);
      made.addLayer({ id: 'sim-casing', type: 'line', source: 'sim-lines', filter: ['all', ['has', 'casing'], ['!', ['get', 'dotted']]],
        layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'casing'], 'line-width': ['+', ['get', 'width'], 3], 'line-opacity': ['get', 'opacity'] } }, under);
      made.addLayer({ id: 'sim-lines', type: 'line', source: 'sim-lines', filter: ['!', ['get', 'dotted']],
        layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': ['get', 'width'], 'line-opacity': ['get', 'opacity'] } }, under);
      made.addLayer({ id: 'sim-dotted', type: 'line', source: 'sim-lines', filter: ['get', 'dotted'],
        layout: { 'line-cap': 'round', 'line-join': 'round' }, paint: { 'line-color': ['get', 'color'], 'line-width': ['get', 'width'], 'line-dasharray': [0.01, 2], 'line-opacity': ['get', 'opacity'] } });
      made.addLayer({ id: 'sim-dots', type: 'circle', source: 'sim-dots', paint: { 'circle-color': ['get', 'color'], 'circle-radius': ['get', 'radius'],
        'circle-stroke-color': ['get', 'stroke'], 'circle-stroke-width': ['get', 'strokeWidth'], 'circle-pitch-alignment': 'map' } });
      made.addLayer({ id: 'sim-solids', type: 'fill-extrusion', source: 'sim-solids', paint: { 'fill-extrusion-color': ['get', 'color'],
        'fill-extrusion-base': ['get', 'base'], 'fill-extrusion-height': ['get', 'height'], 'fill-extrusion-vertical-gradient': true } });
      // City and district names belong to a wider view than any shot here.
      for (const layer of made.getStyle().layers) if (/^label_/.test(layer.id)) made.setLayoutProperty(layer.id, 'visibility', 'none');
      map.current = made;
      setReady(true);
      continueRender(opening);
    });
    return () => made.remove();
    // The map is made once; every later change goes through the effect below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const state = JSON.stringify([camera, lines, solids, flats, dots, anchors]);
  useEffect(() => {
    const made = map.current;
    if (!made || !ready) return;
    const waiting = delayRender(`The map is drawing frame ${frame}`, { timeoutInMilliseconds: 280000 });
    let released = false;
    const release = () => { if (!released) { released = true; continueRender(waiting); } };
    made.jumpTo({ center: camera.center, zoom: camera.zoom, bearing: camera.bearing ?? 0, pitch: camera.pitch ?? 0, padding: { top: 0, left: 0, right: 0, bottom: camera.lift ?? 0 } });
    if (made.getLayer('building-3d')) made.setPaintProperty('building-3d', 'fill-extrusion-opacity', camera.buildings ?? 0.9);
    const set = (id: string, features: object[]) => (made.getSource(id) as GeoJSONSource).setData(collection(features));
    set('sim-lines', lines.filter((l) => l.coords.length > 1).map((l) => ({ type: 'Feature', geometry: { type: 'LineString', coordinates: l.coords },
      properties: { color: l.color, width: l.width, dotted: !!l.dotted, opacity: l.opacity ?? 1, ...(l.casing ? { casing: l.casing } : {}) } })));
    set('sim-flats', flats.map((f) => ({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [f.ring] }, properties: { color: f.color, opacity: f.opacity } })));
    set('sim-dots', dots.map((d) => ({ type: 'Feature', geometry: { type: 'Point', coordinates: d.at },
      properties: { color: d.color, radius: d.radius, stroke: d.stroke ?? '#FFFFFF', strokeWidth: d.strokeWidth ?? 0 } })));
    set('sim-solids', solids.map((s) => ({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [s.ring] }, properties: { color: s.color, base: s.base, height: s.height } })));
    const next: Projected = {};
    for (const [name, place] of Object.entries(anchors)) {
      const p = made.project(place);
      next[name] = { x: p.x * 2, y: p.y * 2 };
    }
    setAt(next);
    made.once('idle', release);
    made.triggerRepaint();
    return () => { made.off('idle', release); release(); };
    // `state` stands for everything drawn.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [frame, ready, state]);

  return (
    <div style={{ position: 'absolute', left: 0, top: 0, width: 886, height: 1920, overflow: 'hidden', background: '#EEF0EA' }}>
      <div ref={holder} style={{ position: 'absolute', left: 0, top: 0, width: POINTS.w, height: POINTS.h, transformOrigin: '0 0', transform: 'scale(2)' }} />
      {children ? children(at) : null}
    </div>
  );
};
