// The voice conversation for 台北公車 Pro. Each request is one turn: what the rider just said, the
// app's current state in words and the last eight turns. The reply says what to speak (numbers left as
// slots the app fills) and which app actions to run. A question that needs current information is
// answered from a web search, a few a day. Turns come from Pro's own daily allowance; nothing is stored.
import { caller, headerText, reply, taipeiDay } from '../_shared/caller.ts';
import { tierOf } from '../_shared/pro.ts';
import type { SupabaseClient } from '@supabase/supabase-js';
import { askClaude, askGroq, searchWeb, streamClaude } from './brain.ts';
import { type Audio, heardTurn, readAudio, transcribe } from './hear.ts';
import { NO_WEB, NO_WEB_CHOSEN, type Reply, readInput, type TurnInput, userMessage, webQuestion } from './reply.ts';

const DAILY_TURNS = 40;
/// Web lookups a day; past them the model answers from what it knows.
const DAILY_WEB = 3;
/// The voice consent this server's data use matches; the app sends the version the rider agreed to.
const VOICE_CONSENT = 1;
/// The consent that also covers sending the turn's audio for server recognition.
const AUDIO_CONSENT = 2;

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
  if (body.feedback && typeof body.feedback === 'object') return await saveFeedback(admin, userId, body.feedback as Record<string, unknown>);
  if (body.transcribe === true) return await transcribeOnly(admin, userId, body, groqKey);
  const input = readInput(body);
  if (!input) return reply({ error: 'invalid' }, 400);

  const tier = await tierOf(admin, userId, typeof body.proof === 'string' ? body.proof : undefined,
    typeof body.renewal === 'string' ? body.renewal : undefined);
  if (tier !== 'pro') return reply({ error: 'pro_required' }, 403);
  const { data: used, error: allowanceError } = await admin.rpc('take_voice_allowance', {
    p_user: userId, p_day: taipeiDay(), p_limit: DAILY_TURNS,
  });
  if (allowanceError) return reply({ error: 'allowance' }, 500);
  if (used === null) return reply({ error: 'daily_limit', limit: DAILY_TURNS }, 429);

  const headers: Record<string, string> = { 'X-Assistant-Used': String(used), 'X-Assistant-Limit': String(DAILY_TURNS) };
  if (body.stream === true) {
    // The rider can turn web lookups off in Settings.
    const webLeft = body.web === false ? 0 : await webAllowanceLeft(admin, userId);
    return streamed({
      input, webLeft, noWeb: body.web === false ? NO_WEB_CHOSEN : NO_WEB, used, anthropicKey, groqKey, headers,
      audio: Number(body.consent) >= AUDIO_CONSENT ? readAudio(body) : null, takeWeb: () => takeWebAllowance(admin, userId),
    });
  }
  // Only the streamed turn can follow up with a web lookup.
  const message = userMessage(input, NO_WEB);
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

/// The phone's 「只用雲端」 setting: the turn's audio is written down on its own, with nothing heard on the
/// phone, and the phone then goes on with the words as usual (its next request takes the turn).
async function transcribeOnly(admin: SupabaseClient, userId: string, body: Record<string, unknown>, groqKey?: string): Promise<Response> {
  if (!(Number(body.consent) >= AUDIO_CONSENT)) return reply({ error: 'consent_required' }, 400);
  const audio = readAudio(body);
  if (!audio) return reply({ error: 'invalid' }, 400);
  const tier = await tierOf(admin, userId, typeof body.proof === 'string' ? body.proof : undefined,
    typeof body.renewal === 'string' ? body.renewal : undefined);
  if (tier !== 'pro') return reply({ error: 'pro_required' }, 403);
  if (!groqKey) return reply({ error: 'not_configured' }, 503);
  const heard = await transcribe(groqKey, audio);
  if ('text' in heard) return reply({ heard: heard.text }, 200);
  console.error('server recognition failed', heard.failure);
  return reply({ error: 'unheard', reason: heard.failure }, 502);
}

/// Reports a phone may send a day.
const DAILY_REPORTS = 20;

/// A voice answer the rider reported: what was heard, what was said and the state it answered from,
/// kept 30 days (pruned with the allowances) to improve the conversation.
async function saveFeedback(admin: SupabaseClient, userId: string, feedback: Record<string, unknown>): Promise<Response> {
  const text = (key: string, limit: number) =>
    typeof feedback[key] === 'string' ? (feedback[key] as string).replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '').trim().slice(0, limit) : '';
  const report = { user_id: userId, heard: text('heard', 300), said: text('said', 600), state: text('state', 4000),
    model: text('model', 80), note: text('note', 300) };
  if (!report.heard && !report.said) return reply({ error: 'invalid' }, 400);
  const since = new Date(Date.now() - 86_400_000).toISOString();
  const { count } = await admin.from('assistant_feedback').select('id', { count: 'exact', head: true })
    .eq('user_id', userId).gt('created_at', since);
  if ((count ?? 0) >= DAILY_REPORTS) return reply({ error: 'daily_limit' }, 429);
  const { error } = await admin.from('assistant_feedback').insert(report);
  if (error) return reply({ error: 'feedback' }, 500);
  return reply({ saved: true }, 200);
}

async function webAllowanceLeft(admin: SupabaseClient, userId: string): Promise<number> {
  const { data } = await admin.from('assistant_web_usage').select('count').eq('user_id', userId).eq('day', taipeiDay()).maybeSingle();
  return Math.max(0, DAILY_WEB - Number(data?.count ?? 0));
}

async function takeWebAllowance(admin: SupabaseClient, userId: string): Promise<number | null> {
  const { data, error } = await admin.rpc('take_web_allowance', { p_user: userId, p_day: taipeiDay(), p_limit: DAILY_WEB });
  return error ? null : data;
}

type Turn = {
  input: TurnInput; webLeft: number; noWeb: string; used: number; anthropicKey?: string; groqKey?: string;
  headers: Record<string, string>; audio: Audio | null; takeWeb: () => Promise<number | null>;
};

/// Server-sent events, one JSON object each: first `{"heard": words}` when the turn's audio was written
/// down again on the server, so the phone shows and keeps that; `{"say": words}` as the spoken sentence is written, so the
/// phone can start speaking at the first full stop; `{"said": true}` once it is whole, so a last sentence
/// without a full stop need not wait for the actions; then `{"reply": ..., "model", "provider", "used",
/// "limit"}` with the checked reply, or `{"error": ...}`. Groq answers in one piece, and only while
/// nothing has been said. Event streams pass through proxies as they are written rather than buffered.
///
/// A reply asking for web_search goes on in the same stream: its 「我上網查一下」 is said first, then the
/// answer from the search, and the last event adds `sources` and the passages they quoted (`quoted`).
/// Comments keep the connection alive from the first byte, through the search. Past the day's lookups, Claude is asked
/// again to answer from what it knows.
function streamed(turn: Turn): Response {
  const { webLeft, used, anthropicKey, groqKey, headers } = turn;
  const encoder = new TextEncoder();
  // The rider cut in and the phone hung up: the rest of the turn is written to no one.
  let gone = false;
  let keepAlive: ReturnType<typeof setInterval> | undefined;
  const body = new ReadableStream<Uint8Array>({
    async start(controller) {
      const write = (text: string) => {
        if (gone) return;
        try {
          controller.enqueue(encoder.encode(text));
        } catch {
          gone = true;
        }
      };
      const send = (line: unknown) => write(`data: ${JSON.stringify(line)}\n\n`);
      // Bytes from the start and every few seconds, so the phone's idle timeout never fires while
      // Claude, then Groq, or a web search is still working.
      write(': ok\n\n');
      keepAlive = setInterval(() => write(': working\n\n'), 3000);
      const speak = (say: string, said: boolean) => {
        if (say) send({ say });
        if (said) send({ said: true });
      };
      if (turn.audio && groqKey) {
        const heard = await transcribe(groqKey, turn.audio);
        if ('text' in heard) {
          turn.input = heardTurn(turn.input, heard.text);
          send({ heard: heard.text });
        } else {
          console.error('server recognition failed', heard.failure);
        }
      }
      const input = turn.input;
      const message = userMessage(input, webLeft > 0 ? `今天還能用 ${webLeft} 次` : turn.noWeb);
      const claude = anthropicKey ? await streamClaude(anthropicKey, message, speak) : { failure: 'not configured', spoke: false };
      if ('reply' in claude) {
        const search = claude.reply.actions.find((action) => action.type === 'web_search');
        if (!search) {
          send({ reply: claude.reply, model: claude.model, provider: 'anthropic', used, limit: DAILY_TURNS });
        } else {
          send({ ...await followUp(turn, claude.reply, claude.model, search.query, speak, () => gone), used, limit: DAILY_TURNS });
        }
      } else if (claude.spoke) {
        send({ error: 'interrupted' });
      } else {
        const groq = groqKey ? await askGroq(groqKey, message) : { failure: 'groq not configured' };
        if ('reply' in groq) {
          speak(groq.reply.say, true);
          send({ reply: groq.reply, model: groq.model, provider: 'groq', used, limit: DAILY_TURNS });
        } else {
          console.error('no answer', claude.failure, groq.failure);
          send({ error: 'unavailable' });
        }
      }
      clearInterval(keepAlive);
      if (!gone) controller.close();
    },
    cancel() {
      gone = true;
      clearInterval(keepAlive);
    },
  });
  return new Response(body, { headers: { ...headers, 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store' } });
}

/// The rest of a turn that asked for the web: the answer from a search while lookups remain, otherwise
/// Claude's own knowledge. Returns the last event, with the reply's words and actions joined up.
async function followUp(turn: Turn, first: Reply, model: string, query: string, speak: (say: string, said: boolean) => void,
  hungUp: () => boolean): Promise<Record<string, unknown>> {
  const actions = first.actions.filter((action) => action.type !== 'web_search');
  const key = turn.anthropicKey!;
  // The rider cut in during 「我上網查一下」: no lookup is spent on an answer no one will hear.
  if (hungUp()) return { reply: { ...first, actions }, model, provider: 'anthropic' };
  if (turn.webLeft > 0 && await turn.takeWeb() !== null) {
    const found = await searchWeb(key, webQuestion(turn.input, query), (words) => speak(words, false));
    if ('say' in found) {
      speak('', true);
      return {
        reply: { ...first, actions, say: `${first.say}${found.say}` }, model: found.model, provider: 'anthropic',
        sources: found.sources, quoted: found.quoted,
      };
    }
    console.error('web lookup failed', found.failure);
  }
  // No lookup left, or it failed: answer from what Claude knows.
  const known = await streamClaude(key, userMessage(turn.input, turn.noWeb), speak);
  if ('reply' in known) {
    const more = known.reply.actions.filter((action) => action.type !== 'web_search');
    return { reply: { ...known.reply, actions: [...actions, ...more].slice(0, 3), say: `${first.say}${known.reply.say}` }, model: known.model, provider: 'anthropic' };
  }
  return { reply: { ...first, actions }, model, provider: 'anthropic' };
}
