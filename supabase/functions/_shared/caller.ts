// Who is asking, shared by the assistant functions.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

export type Caller = { userId: string; admin: SupabaseClient };

/// The anonymous phone behind the request and a service client for the allowance tables, or the
/// response to send instead.
export async function caller(request: Request): Promise<Caller | Response> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: 'not_configured' }, 503);
  if (!authorization?.startsWith('Bearer ')) return reply({ error: 'unauthorized' }, 401);
  // The gateway already verified the token (verify_jwt); this reads whose it is.
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data: identity, error } = await userClient.auth.getUser();
  if (error || !identity.user) return reply({ error: 'unauthorized' }, 401);
  return { userId: identity.user.id, admin: createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } }) };
}

export function taipeiDay(): string {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}

export function reply(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, { status });
}

/// Header values must be ASCII.
export function headerText(text: string): string {
  return text.replace(/[^\x20-\x7e]/g, '?').slice(0, 200);
}
