// After a deploy: one voice turn with time to spare, so Claude has a changed reply shape ready before
// the first rider asks (otherwise that first turn waits too long and Groq answers it).
// deno run --allow-env --allow-net --no-lock --config supabase/functions/converse/deno.json supabase/functions/converse/warm.ts
import { warmClaude } from './brain.ts';
import { userMessage } from './reply.ts';

const key = Deno.env.get('ANTHROPIC_API_KEY')?.trim();
if (!key) {
  console.log('No ANTHROPIC_API_KEY: nothing to warm.');
  Deno.exit(0);
}
const started = performance.now();
const ready = await warmClaude(key, userMessage({ utterance: '你好', state: '畫面：地圖', history: [] }));
console.log(`Claude reply shape ${ready ? 'ready' : 'not ready'} in ${Math.round(performance.now() - started)} ms`);
