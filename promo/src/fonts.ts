import '@fontsource/noto-sans-tc/500.css';
import '@fontsource/noto-sans-tc/700.css';
import '@fontsource/noto-sans-tc/900.css';
import '@fontsource/inter/600.css';
import '@fontsource/inter/800.css';
import { continueRender, delayRender } from 'remotion';
import episodes from './episodes.json';

/** Chinese and interface text. */
export const FONT = '"Noto Sans TC", "PingFang TC", sans-serif';
/** Numbers and Latin set beside it. */
export const LATIN = 'Inter, "Noto Sans TC", sans-serif';

// Every glyph the films show, so the matching unicode-range subsets are fetched before the first frame.
const TEXT = JSON.stringify(episodes) + '一路OneRoad公車捷運YouBike步行AppStore免費下載接到底，、。？！#0123456789 abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

const handle = delayRender('Loading fonts');
Promise.all([
  ...['500', '700', '900'].map((weight) => document.fonts.load(`${weight} 64px "Noto Sans TC"`, TEXT)),
  ...['600', '800'].map((weight) => document.fonts.load(`${weight} 64px Inter`, TEXT)),
]).then(() => continueRender(handle), () => continueRender(handle));
