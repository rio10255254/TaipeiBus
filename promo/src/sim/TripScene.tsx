import React from 'react';
import { Easing, Img, staticFile } from 'remotion';
import { clamp, lerp, pop, ramp } from '../kit';
import { Button, StatusBar } from './chrome';
import { path, upTo } from './geo';
import paths from './paths.json';
import { Dot, Line, LngLat, SimMap } from './SimMap';

/**
 * The trip the recorded itinerary shows, drawn onto the map as it is offered: bus 967 from the
 * Memorial Hall to Zhongxiao Dunhua, then bus 630 to Neihu Station, along their published shapes.
 * The sheet under it is the app's own, taken from the recording of that same search.
 */
const LEGS = (paths.trip as LngLat[][]).map(path);
const STOPS = paths.tripStops as LngLat[];
const TOTAL = LEGS[0].length + LEGS[1].length;
const glide = Easing.bezier(0.45, 0, 0.2, 1);
const BLUE = '#2F6FE4';

export const TripScene: React.FC<{ t: number }> = ({ t }) => {
  const drawn = TOTAL * glide(clamp((t - 0.25) / 1.9));
  const view = glide(clamp(t / 2.3));
  const sheet = pop(t, 0.05, 10, 0.86);
  const lines: Line[] = LEGS.map((leg, i) => ({ coords: upTo(leg, drawn - (i ? LEGS[0].length : 0)), color: BLUE, width: 5, casing: '#FFFFFF' }));
  const reached = (i: number) => pop(t, 0.25 + 1.9 * [0, 0.34, 1][i] - (i ? 0.05 : 0.2), 12, 0.6);
  const dots: Dot[] = [
    { at: STOPS[0], color: BLUE, radius: 9 * clamp(reached(0)), stroke: '#FFFFFF', strokeWidth: 3.5 },
    { at: STOPS[1], color: '#FFFFFF', radius: 6.5 * clamp(reached(1)), stroke: BLUE, strokeWidth: 3.5 },
  ];
  return (
    <SimMap camera={{ center: [lerp(STOPS[0][0], 121.5722, view), lerp(STOPS[0][1], 25.0602, view)], zoom: lerp(13.3, 11.92, view), lift: 266 * view }} lines={lines} dots={dots}
      anchors={{ end: STOPS[2] }}>
      {(at) => (
        <>
          {at.end ? (
            <svg style={{ position: 'absolute', left: at.end.x - 30, top: at.end.y - 72, transformOrigin: '30px 72px', transform: `scale(${reached(2)})` }} width="60" height="76" viewBox="0 0 60 76">
              <path d="M30 74C30 74 6 46 6 28a24 24 0 0 1 48 0c0 18-24 46-24 46z" fill="#F0453A" stroke="#fff" strokeWidth="4" />
              <circle cx="30" cy="28" r="9" fill="#fff" />
            </svg>
          ) : null}
          <Button x={806} y={206} icon="map" />
          <Button x={806} y={640} icon="locate" />
          <StatusBar time="2:38" />
          <Img src={staticFile('sim/choices-sheet.png')} style={{ position: 'absolute', left: 14, top: 850 + (1 - sheet) * 1100, width: 858, height: 1058, borderRadius: 60,
            boxShadow: '0 -10px 50px rgba(20,30,40,.18)' }} />
        </>
      )}
    </SimMap>
  );
};
