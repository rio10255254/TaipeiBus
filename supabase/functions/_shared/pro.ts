// Pro access, shared by the assistant functions: verified from the signed App Store transaction the
// app sends and remembered until that subscription period ends.
import type { SupabaseClient } from '@supabase/supabase-js';
import { Environment, SignedDataVerifier } from '@apple/app-store-server-library';
import { Buffer } from 'node:buffer';

const BUNDLE_ID = 'com.rio10255254.TaipeiBus';
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
