import { Composition } from 'remotion';
import { EPISODES, Reel, reelFrames } from './Reel';
import { PREVIEW, StorePreview, previewFrames } from './StorePreview';
import { FPS, H, W } from './kit';

export const Root = () => (
  <>
    {EPISODES.filter((e) => e.kind !== 'preview').map((e) => (
      <Composition key={e.id} id={`Reel-${e.id}`} component={Reel} defaultProps={{ id: e.id }} durationInFrames={reelFrames(e.id)} fps={FPS} width={W} height={H} />
    ))}
    <Composition id="StorePreview" component={StorePreview} durationInFrames={previewFrames} fps={PREVIEW.fps} width={PREVIEW.w} height={PREVIEW.h} />
  </>
);
