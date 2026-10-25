// Online understanding for 台北公車. The app sends one chat request; this function checks who is
// asking, takes one sentence from that phone's daily allowance (20, or 100 with Pro), and asks
// Anthropic's Claude, or Groq when Claude cannot answer. Keys never leave the server and sentences
// are not stored.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { Environment, SignedDataVerifier } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';
import { askClaude } from './claude.ts';

const BUNDLE_ID = 'com.rio10255254.TaipeiBus';
const PRO_PRODUCTS = new Set(['com.rio10255254.TaipeiBus.pro.monthly', 'com.rio10255254.TaipeiBus.pro.yearly']);
const MODELS = { pro: ['openai/gpt-oss-120b', 'openai/gpt-oss-20b'], free: ['openai/gpt-oss-20b'] };
const LIMITS = { pro: 100, free: 20 };
const MAX_INPUT = 6000;
const MAX_OUTPUT = 800;
/// Builds whose consent names Claude send this version; older builds agreed to Groq only and stay there.
const CLAUDE_CONSENT = 2;

type Tier = 'pro' | 'free';

Deno.serve(async (request) => {
  if (request.method !== 'POST') return reply({ error: 'method' }, 405);
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const groqKey = Deno.env.get('GROQ_API_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceKey || (!groqKey && !anthropicKey)) return reply({ error: 'not_configured' }, 503);
  if (!authorization?.startsWith('Bearer ')) return reply({ error: 'unauthorized' }, 401);

  // The gateway already verified the token (verify_jwt); this reads whose it is.
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data: identity, error: identityError } = await userClient.auth.getUser();
  if (identityError || !identity.user) return reply({ error: 'unauthorized' }, 401);
  const userId = identity.user.id;

  let body: { request?: Record<string, unknown>; proof?: string; consent?: number };
  try {
    body = await request.json();
  } catch {
    return reply({ error: 'invalid' }, 400);
  }
  const chat = sanitize(body.request);
  if (!chat) return reply({ error: 'invalid' }, 400);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  const tier = await tierOf(admin, userId, body.proof);

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
    fallback = { 'X-Assistant-Fallback': (failure ?? 'unknown').replace(/[^\x20-\x7e]/g, '?').slice(0, 200) };
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

/// Pro when the phone sent a signed App Store transaction for an active Pro subscription. A check is
/// remembered until that subscription period ends, so most requests skip it.
/// A failed check never fails the request: the phone is simply served as free this time.
async function tierOf(admin: SupabaseClient, userId: string, proof?: string): Promise<Tier> {
  try {
    return await checkTier(admin, userId, proof);
  } catch (error) {
    console.error('pro check failed', error instanceof Error ? error.message : String(error));
    return 'free';
  }
}

async function checkTier(admin: SupabaseClient, userId: string, proof?: string): Promise<Tier> {
  const { data: cached } = await admin.from('assistant_pro').select('expires_at').eq('user_id', userId).maybeSingle();
  if (cached && new Date(cached.expires_at).getTime() > Date.now()) return 'pro';
  if (!proof || proof.length > 20000) return 'free';
  const transaction = await verifyTransaction(proof);
  if (!transaction) return 'free';
  await admin.from('assistant_pro').upsert({
    user_id: userId,
    original_transaction_id: transaction.originalTransactionId,
    expires_at: new Date(transaction.expiresDate).toISOString(),
    updated_at: new Date().toISOString(),
  });
  return 'pro';
}

let verifiers: SignedDataVerifier[] | null = null;

async function verifyTransaction(jws: string): Promise<{ originalTransactionId: string; expiresDate: number } | null> {
  if (!verifiers) {
    try {
      verifiers = await makeVerifiers();
    } catch (error) {
      console.error('apple roots unavailable', error instanceof Error ? error.message : String(error));
      return null;
    }
  }
  for (const verifier of verifiers) {
    try {
      const payload = await verifier.verifyAndDecodeTransaction(jws);
      if (!payload.productId || !PRO_PRODUCTS.has(payload.productId)) return null;
      if (payload.revocationDate || !payload.expiresDate || payload.expiresDate <= Date.now()) return null;
      return { originalTransactionId: String(payload.originalTransactionId ?? ''), expiresDate: payload.expiresDate };
    } catch (error) {
      // Signed for the other environment (TestFlight is Sandbox), or not Apple's: try the next.
      console.warn('transaction not verified', error instanceof Error ? error.message : String(error));
    }
  }
  return null;
}

async function makeVerifiers(): Promise<SignedDataVerifier[]> {
  const names = ['AppleRootCA-G3.cer', 'AppleRootCA-G2.cer', 'AppleIncRootCertificate.cer'];
  const roots = await Promise.all(names.map(async (name) => {
    const response = await fetch(`https://www.apple.com/certificateauthority/${name}`);
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    return Buffer.from(new Uint8Array(await response.arrayBuffer()));
  }));
  const appId = Number(Deno.env.get('APP_APPLE_ID')) || undefined;
  const list = [new SignedDataVerifier(roots, false, Environment.SANDBOX, BUNDLE_ID)];
  // Production transactions need the app's numeric App Store ID.
  if (appId) list.unshift(new SignedDataVerifier(roots, false, Environment.PRODUCTION, BUNDLE_ID, appId));
  return list;
}

function taipeiDay(): string {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

function reply(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status });
}
