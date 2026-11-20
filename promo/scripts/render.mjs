#!/usr/bin/env node
// Render films to out/<id>.mp4:  node scripts/render.mjs ep1 ep2 [--preview]
// --preview renders half size at 30 fps (quick, to check design and timing).
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';

const args = process.argv.slice(2);
const preview = args.includes('--preview');
const ids = args.filter((a) => !a.startsWith('--'));
const extra = args.filter((a) => a.startsWith('--') && a !== '--preview');
if (!ids.length) { console.error('usage: node scripts/render.mjs <episode id> [...] [--preview]'); process.exit(1); }
mkdirSync(preview ? 'out/preview' : 'out', { recursive: true });
for (const id of ids) {
  const started = Date.now();
  const file = preview ? `out/preview/${id}.mp4` : `out/oneroad-${id}.mp4`;
  const flags = ['--browser-executable=/opt/pw-browsers/chromium', '--timeout=300000', '--concurrency=4', '--log=error',
    ...(preview ? ['--scale=0.5', '--every-nth-frame=2'] : ['--crf=17']), ...extra];
  const r = spawnSync('npx', ['remotion', 'render', 'src/index.ts', `Reel-${id}`, file, ...flags], { stdio: 'inherit' });
  if (r.status !== 0) process.exit(r.status ?? 1);
  console.log(`${id}: ${Math.round((Date.now() - started) / 1000)} s -> ${file}`);
}
