// Pro access, shared by the assistant functions: verified from the signed App Store transaction the
// app sends and remembered until that subscription period ends.
import type { SupabaseClient } from '@supabase/supabase-js';
import * as x509 from '@peculiar/x509';
import { APPLE_ROOTS } from './apple_roots.ts';

// Supabase's runtime does not implement node:crypto's X509Certificate.verify, which Apple's own
// library depends on, so the chain is checked here with Web Crypto, making the same checks.
x509.cryptoProvider.set(crypto);

const BUNDLE_ID = 'com.rio10255254.TaipeiBus';
const PRO_PRODUCTS = new Set(['com.rio10255254.TaipeiBus.pro.monthly', 'com.rio10255254.TaipeiBus.pro.yearly']);
/// App Store purchases are Production; TestFlight purchases are Sandbox.
const ENVIRONMENTS = new Set(['Production', 'Sandbox']);
/// Apple's marker extensions: on the certificate that signs App Store data, and on its intermediate.
const APP_STORE_LEAF = '1.2.840.113635.100.6.11.1';
const APPLE_WWDR_INTERMEDIATE = '1.2.840.113635.100.6.2.1';

export type Tier = 'pro' | 'free';

/// Pro when the phone sent a signed App Store transaction for an active Pro subscription, or one in
/// billing grace with its signed renewal info. A check is remembered until that subscription period
/// (or grace) ends, so most requests skip it.
/// A failed check never fails the request: the phone is simply served as free this time.
export async function tierOf(admin: SupabaseClient, userId: string, proof?: string, renewal?: string): Promise<Tier> {
  try {
    return await checkTier(admin, userId, proof, renewal);
  } catch (error) {
    console.error('pro check failed', error instanceof Error ? error.message : String(error));
    return 'free';
  }
}

async function checkTier(admin: SupabaseClient, userId: string, proof?: string, renewal?: string): Promise<Tier> {
  const { data: cached } = await admin.from('assistant_pro').select('expires_at').eq('user_id', userId).maybeSingle();
  if (cached && new Date(cached.expires_at).getTime() > Date.now()) return 'pro';
  if (!proof || proof.length > 20000) return 'free';
  const transaction = await verifyTransaction(proof, APPLE_ROOTS, renewal && renewal.length <= 20000 ? renewal : undefined);
  if (!transaction) return 'free';
  await admin.from('assistant_pro').upsert({
    user_id: userId,
    original_transaction_id: transaction.originalTransactionId,
    expires_at: new Date(transaction.expiresDate).toISOString(),
    updated_at: new Date().toISOString(),
  });
  return 'pro';
}

export type Pro = { originalTransactionId: string; expiresDate: number };

/// The active Pro subscription a signed App Store transaction proves, or null. The checks follow
/// Apple's App Store Server Library: a three-certificate chain from one of `roots` to an intermediate
/// and leaf carrying Apple's markers, every certificate valid when Apple signed the transaction, and
/// the leaf's ES256 signature over it. A subscription past its period still counts during billing grace,
/// until the `gracePeriodExpiresDate` of its renewal info, signed the same way.
export async function verifyTransaction(jws: string, roots: string[] = APPLE_ROOTS, renewal?: string): Promise<Pro | null> {
  try {
    const [header, payload] = await verifiedJWS(jws, roots);
    if (header.alg !== 'ES256') throw new Error(`alg ${header.alg}`);
    if (payload.bundleId !== BUNDLE_ID || !ENVIRONMENTS.has(payload.environment)) throw new Error(`app ${payload.bundleId} ${payload.environment}`);
    if (!PRO_PRODUCTS.has(payload.productId)) return null;
    if (payload.revocationDate || !payload.expiresDate) return null;
    const originalTransactionId = String(payload.originalTransactionId ?? '');
    if (payload.expiresDate > Date.now()) return { originalTransactionId, expiresDate: payload.expiresDate };
    if (!renewal) return null;
    const [renewalHeader, info] = await verifiedJWS(renewal, roots);
    if (renewalHeader.alg !== 'ES256' || String(info.originalTransactionId ?? '') !== originalTransactionId ||
      info.environment !== payload.environment) throw new Error('renewal info of another subscription');
    const grace = Number(info.gracePeriodExpiresDate) || 0;
    return grace > Date.now() ? { originalTransactionId, expiresDate: grace } : null;
  } catch (error) {
    console.warn('transaction not verified', error instanceof Error ? error.message : String(error));
    return null;
  }
}

// deno-lint-ignore no-explicit-any
type Json = Record<string, any>;

async function verifiedJWS(jws: string, roots: string[]): Promise<[Json, Json]> {
  const parts = jws.split('.');
  if (parts.length !== 3) throw new Error('not a JWS');
  const header: Json = JSON.parse(new TextDecoder().decode(base64url(parts[0])));
  const payload: Json = JSON.parse(new TextDecoder().decode(base64url(parts[1])));
  const chain: string[] = Array.isArray(header.x5c) ? header.x5c : [];
  if (chain.length !== 3) throw new Error(`chain of ${chain.length}`);
  const [leaf, intermediate] = chain.slice(0, 2).map((der) => new x509.X509Certificate(base64(der)));
  const trusted = roots.map((der) => new x509.X509Certificate(base64(der)));

  let root: x509.X509Certificate | undefined;
  for (const candidate of trusted) {
    if (intermediate.issuer === candidate.subject && await intermediate.verify({ publicKey: candidate, signatureOnly: true })) root = candidate;
  }
  if (!root) throw new Error('intermediate not issued by a trusted root');
  if (leaf.issuer !== intermediate.subject || !await leaf.verify({ publicKey: intermediate, signatureOnly: true })) throw new Error('leaf not issued by the intermediate');
  if (!intermediate.getExtension(x509.BasicConstraintsExtension)?.ca) throw new Error('intermediate is not a CA');
  if (!leaf.getExtension(APP_STORE_LEAF) || !intermediate.getExtension(APPLE_WWDR_INTERMEDIATE)) throw new Error('missing Apple markers');
  // As Apple's library does without online checks: valid when Apple signed it.
  const signed = new Date(Number(payload.signedDate) || Date.now());
  for (const certificate of [leaf, intermediate, root]) {
    if (signed < certificate.notBefore || signed > certificate.notAfter) throw new Error('certificate not valid when signed');
  }

  const key = await leaf.publicKey.export({ name: 'ECDSA', namedCurve: 'P-256' }, ['verify']);
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, base64url(parts[2]),
    new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!valid) throw new Error('signature');
  return [header, payload];
}

function base64(text: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(text), (character) => character.charCodeAt(0));
}

function base64url(text: string): Uint8Array<ArrayBuffer> {
  const plain = text.replace(/-/g, '+').replace(/_/g, '/');
  return base64(plain + '='.repeat((4 - plain.length % 4) % 4));
}
