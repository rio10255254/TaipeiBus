// Pro access, shared by the assistant functions: verified from the signed App Store transaction the
// app sends and remembered until that subscription period ends.
import type { SupabaseClient } from '@supabase/supabase-js';
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';
import { X509Certificate } from 'node:crypto';
import { APPLE_ROOTS } from './apple_roots.ts';

const BUNDLE_ID = 'com.rio10255254.TaipeiBus';
const APP_APPLE_ID = 6818475740;
const PRO_PRODUCTS = new Set(['com.rio10255254.TaipeiBus.pro.monthly', 'com.rio10255254.TaipeiBus.pro.yearly']);

export type Tier = 'pro' | 'free';

/// Pro when the phone sent a signed App Store transaction for an active Pro subscription. A check is
/// remembered until that subscription period ends, so most requests skip it.
/// A failed check never fails the request: the phone is simply served as free this time.
export async function tierOf(admin: SupabaseClient, userId: string, proof?: string): Promise<Tier> {
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

/// The active Pro subscription a signed transaction proves, or null.
export async function verifyTransaction(jws: string, list = verifiers ??= makeVerifiers()): Promise<{ originalTransactionId: string; expiresDate: number } | null> {
  for (const verifier of list) {
    try {
      const payload = await verifier.verifyAndDecodeTransaction(jws);
      if (!payload.productId || !PRO_PRODUCTS.has(payload.productId)) return null;
      if (payload.revocationDate || !payload.expiresDate || payload.expiresDate <= Date.now()) return null;
      return { originalTransactionId: String(payload.originalTransactionId ?? ''), expiresDate: payload.expiresDate };
    } catch (error) {
      // Signed for the other environment (TestFlight is Sandbox), or not Apple's: try the next.
      console.warn('transaction not verified', failure(error), chainProbe(jws));
    }
  }
  return null;
}

/// App Store purchases are Production; TestFlight purchases are Sandbox.
export function makeVerifiers(roots: string[] = APPLE_ROOTS): SignedDataVerifier[] {
  const certificates = roots.map((root) => Buffer.from(root, 'base64'));
  // Production transactions need the app's numeric App Store ID (public: apps.apple.com/tw/app/id6818475740).
  const appId = Number(Deno.env.get('APP_APPLE_ID')) || APP_APPLE_ID;
  return [
    new SignedDataVerifier(certificates, false, Environment.PRODUCTION, BUNDLE_ID, appId),
    new SignedDataVerifier(certificates, false, Environment.SANDBOX, BUNDLE_ID),
  ];
}

/// Why Apple's library refused a transaction: its status name and the underlying error, if any.
function failure(error: unknown): string {
  if (error instanceof VerificationException) {
    const cause = error.cause instanceof Error ? `${error.cause.constructor.name}: ${error.cause.message}` : '';
    return [VerificationStatus[error.status] ?? String(error.status), cause].filter(Boolean).join(' ');
  }
  return error instanceof Error ? `${error.constructor.name}: ${error.message}` : String(error);
}

/// Each check the library makes on the transaction's certificate chain, from Apple's public
/// certificates only: which one fails on this runtime.
function chainProbe(jws: string): string {
  try {
    const header = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(jws.split('.')[0].replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0))));
    const chain: string[] = header.x5c ?? [];
    const [leaf, intermediate] = chain.slice(0, 2).map((cert) => new X509Certificate(Buffer.from(cert, 'base64')));
    const roots = APPLE_ROOTS.map((root) => new X509Certificate(Buffer.from(root, 'base64')));
    const parts = [
      `alg=${header.alg} chain=${chain.length}`,
      `intermediate=${intermediate.subject.replace(/\n/g, ',')} issuer=${intermediate.issuer.replace(/\n/g, ',')}`,
      ...roots.map((root, index) => {
        let verified: string;
        try { verified = String(intermediate.verify(root.publicKey)); } catch (error) { verified = `throws ${error instanceof Error ? error.message : error}`; }
        return `root${index} subject=${root.subject.replace(/\n/g, ',')} issuerMatch=${intermediate.issuer === root.subject} verify=${verified}`;
      }),
      (() => { try { return `leafVerify=${leaf.verify(intermediate.publicKey)}`; } catch (error) { return `leafVerify throws ${error instanceof Error ? error.message : error}`; } })(),
      `leafIssuerMatch=${leaf.issuer === intermediate.subject} intermediateCa=${intermediate.ca}`,
      `leafValid=${leaf.validFrom}..${leaf.validTo}`,
    ];
    return parts.join(' | ');
  } catch (error) {
    return `probe failed ${error instanceof Error ? error.message : String(error)}`;
  }
}
