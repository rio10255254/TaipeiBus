import React from 'react';
import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { BusScene } from './BusScene';

export const Probe: React.FC = () => {
  const frame = useCurrentFrame();
  return <AbsoluteFill><BusScene t={frame / 30} tap={5.07} /></AbsoluteFill>;
};
