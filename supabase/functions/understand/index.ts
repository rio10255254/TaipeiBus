// Online understanding for 台北公車. The app sends one chat request; this function checks who is
// asking, takes one sentence from that phone's daily allowance (20, or 100 with Pro), and asks
// Anthropic's Claude, or Groq when Claude cannot answer. Keys never leave the server and sentences
// are not stored.
import { caller, headerText, reply, taipeiDay } from '../_shared/caller.ts';
import { tierOf } from '../_shared/pro.ts';
import { askClaude } from './claude.ts';
import { DAILY_AI } from '../_shared/allowance.ts';

const MODELS = { pro: ['openai/gpt-oss-120b', 'openai/gpt-oss-20b'], free: ['openai/gpt-oss-20b'] };
const LIMITS = DAILY_AI;
const MAX_INPUT = 6000;
const MAX_OUTPUT = 800;
/// Builds whose consent names Claude send this version; older builds agreed to Groq only and stay there.
const CLAUDE_CONSENT = 2;

Deno.serve(async (request) => {
  if (request.method !== 'POST') return reply({ error: 'method' }, 405);
  const groqKey = Deno.env.get('GROQ_API_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!groqKey && !anthropicKey) return reply({ error: 'not_configured' }, 503);
  const who = await caller(request);
  if (who instanceof Response) return who;
  const { userId, admin } = who;

  let body: { request?: Record<string, unknown>; proof?: string; renewal?: string; consent?: number };
  try {
    body = await request.json();
  } catch {
    return reply({ error: 'invalid' }, 400);
  }
  const chat = sanitize(body.request);
  if (!chat) return reply({ error: 'invalid' }, 400);

  const tier = await tierOf(admin, userId, body.proof, body.renewal);

  // Each tier may use only its own models; a free phone asking for the larger one gets the smaller.
  const allowed = MODELS[tier];
  const model = allowed.includes(String(chat.model)) ? String(chat.model) : allowed[0];

  const { data: used, error: allowanceError } = await admin.rpc('take_assistant_allowance', {
    p_user: userId, p_day: taipeiDay(), p_limit: LIMITS[tier],
  });
  if (allowanceError) return reply({ error: 'allowance' }, 500);
  if (used === null) return reply({ error: 'daily_limit', tier, limit: LIMITS[tier] }, 429);
  const headers = { 'Content-Type': 'application/json', 'X-Assistant-Tier': tier, 'X-Assistant-Used': String(used) };

  let fallback: Record<string, string> = {};
  if (anthropicKey && Number(body.consent) >= CLAUDE_CONSENT) {
    const { answer, failure } = await askClaude(anthropicKey, chat);
    if (answer) return new Response(JSON.stringify(answer), { headers: { ...headers, 'X-Assistant-Provider': 'anthropic' } });
    // Why Claude did not answer, for the deploy check and troubleshooting; header values must be ASCII.
    fallback = { 'X-Assistant-Fallback': headerText(failure ?? 'unknown') };
  }
  if (!groqKey) return reply({ error: 'unavailable' }, 503);

  const upstream = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: { Authorization: `Bearer ${groqKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...chat, model }),
  });
  const text = await upstream.text();
  return new Response(text, { status: upstream.status, headers: { ...headers, ...fallback, 'X-Assistant-Provider': 'groq' } });
});

/// Only the fields the app uses, with bounded sizes; nothing else reaches Claude or Groq.
function sanitize(input: Record<string, unknown> | undefined): Record<string, unknown> | null {
  if (!input || !Array.isArray(input.messages) || input.messages.length === 0 || input.messages.length > 3) return null;
  let total = 0;
  const messages = [];
  for (const message of input.messages as Array<Record<string, unknown>>) {
    const role = message?.role, content = message?.content;
    if ((role !== 'system' && role !== 'user') || typeof content !== 'string') return null;
    total += content.length;
    messages.push({ role, content });
  }
  if (total > MAX_INPUT) return null;
  const limit = Math.min(Number(input.max_completion_tokens) || 500, MAX_OUTPUT);
  return {
    model: typeof input.model === 'string' ? input.model : '',
    messages,
    temperature: 0,
    max_completion_tokens: limit,
    reasoning_effort: 'low',
    include_reasoning: false,
    response_format: { type: 'json_object' },
  };
}
