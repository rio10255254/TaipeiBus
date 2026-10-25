// The voice conversation for 台北公車 Pro. Each request is one turn: what the rider just said, the
// app's current state in words and the last two turns. The reply says what to speak (numbers left as
// slots the app fills) and which app actions to run. Turns come from Pro's own daily allowance;
// nothing is stored.
import { caller, headerText, reply, taipeiDay } from '../_shared/caller.ts';
import { tierOf } from '../_shared/pro.ts';
import { askClaude, askGroq, streamClaude } from './brain.ts';
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
  if (body.stream === true) return streamed(message, used, anthropicKey, groqKey, headers);
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

/// Server-sent events, one JSON object each: `{"say": words}` as the spoken sentence is written, so the
/// phone can start speaking at the first full stop; `{"said": true}` once it is whole, so a last sentence
/// without a full stop need not wait for the actions; then `{"reply": ..., "model", "provider", "used",
/// "limit"}` with the checked reply, or `{"error": ...}`. Groq answers in one piece, and only while
/// nothing has been said. Event streams pass through proxies as they are written rather than buffered.
function streamed(message: string, used: number, anthropicKey: string | undefined, groqKey: string | undefined, headers: Record<string, string>): Response {
  const encoder = new TextEncoder();
  // The rider cut in and the phone hung up: the rest of the turn is written to no one.
  let gone = false;
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const send = (line: unknown) => {
        if (gone) return;
        try {
          controller.enqueue(encoder.encode(`data: ${JSON.stringify(line)}\n\n`));
        } catch {
          gone = true;
        }
      };
      const claude = anthropicKey ? await streamClaude(anthropicKey, message, (say, said) => {
          if (say) send({ say });
          if (said) send({ said: true });
        }) : { failure: 'not configured', spoke: false };
      if ('reply' in claude) {
        send({ reply: claude.reply, model: claude.model, provider: 'anthropic', used, limit: DAILY_TURNS });
      } else if (claude.spoke) {
        send({ error: 'interrupted' });
      } else {
        const groq = groqKey ? await askGroq(groqKey, message) : { failure: 'groq not configured' };
        if ('reply' in groq) {
          send({ say: groq.reply.say });
          send({ said: true });
          send({ reply: groq.reply, model: groq.model, provider: 'groq', used, limit: DAILY_TURNS });
        } else {
          console.error('no answer', claude.failure, groq.failure);
          send({ error: 'unavailable' });
        }
      }
      if (!gone) controller.close();
    },
    cancel() {
      gone = true;
    },
  });
  return new Response(body, { headers: { ...headers, 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store' } });
}
