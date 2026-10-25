// The voice conversation for 台北公車 Pro. Each request is one turn: what the rider just said, the
// app's current state in words and the last two turns. The reply says what to speak (numbers left as
// slots the app fills) and which app actions to run. Turns come from Pro's own daily allowance;
// nothing is stored.
import { caller, headerText, reply, taipeiDay } from '../_shared/caller.ts';
import { tierOf } from '../_shared/pro.ts';
import { askClaude, askGroq } from './brain.ts';
import { readInput, userMessage } from './reply.ts';

const DAILY_TURNS = 40;
/// The voice consent this server's data use matches; the app sends the version the rider agreed to.
const VOICE_CONSENT = 1;

Deno.serve(async (request) => {
  if (request.method !== 'POST') return reply({ error: 'method' }, 405);
  const groqKey = Deno.env.get('GROQ_API_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!groqKey && !anthropicKey) return reply({ error: 'not_configured' }, 503);
  const who = await caller(request);
  if (who instanceof Response) return who;
  const { userId, admin } = who;

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return reply({ error: 'invalid' }, 400);
  }
  if (!(Number(body.consent) >= VOICE_CONSENT)) return reply({ error: 'consent_required' }, 400);
  const input = readInput(body);
  if (!input) return reply({ error: 'invalid' }, 400);

  const tier = await tierOf(admin, userId, typeof body.proof === 'string' ? body.proof : undefined);
  if (tier !== 'pro') return reply({ error: 'pro_required' }, 403);
  const { data: used, error: allowanceError } = await admin.rpc('take_voice_allowance', {
    p_user: userId, p_day: taipeiDay(), p_limit: DAILY_TURNS,
  });
  if (allowanceError) return reply({ error: 'allowance' }, 500);
  if (used === null) return reply({ error: 'daily_limit', limit: DAILY_TURNS }, 429);

  const message = userMessage(input);
  const headers: Record<string, string> = { 'X-Assistant-Used': String(used), 'X-Assistant-Limit': String(DAILY_TURNS) };
  const claude = anthropicKey ? await askClaude(anthropicKey, message) : { failure: 'not configured' };
  if ('reply' in claude) {
    return Response.json({ ...claude, provider: 'anthropic', used, limit: DAILY_TURNS }, { headers: { ...headers, 'X-Assistant-Provider': 'anthropic' } });
  }
  headers['X-Assistant-Fallback'] = headerText(claude.failure);
  const groq = groqKey ? await askGroq(groqKey, message) : { failure: 'groq not configured' };
  if ('reply' in groq) {
    return Response.json({ ...groq, provider: 'groq', used, limit: DAILY_TURNS }, { headers: { ...headers, 'X-Assistant-Provider': 'groq' } });
  }
  console.error('no answer', claude.failure, groq.failure);
  return Response.json({ error: 'unavailable' }, { status: 502, headers: { ...headers, 'X-Assistant-Fallback': headerText(`${claude.failure}; ${groq.failure}`) } });
});
