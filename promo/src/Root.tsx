import { Composition } from 'remotion';
import { EPISODES, Reel, reelFrames } from './Reel';
import { FPS, H, W } from './kit';

export const Root = () => (
  <>
    {EPISODES.map((e) => (
      <Composition key={e.id} id={`Reel-${e.id}`} component={Reel} defaultProps={{ id: e.id }} durationInFrames={reelFrames(e.id)} fps={FPS} width={W} height={H} />
    ))}
  </>
);
