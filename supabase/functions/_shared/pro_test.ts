import { assert, assertEquals } from 'jsr:@std/assert@1';
import { crypto } from 'jsr:@std/crypto@1';
import { encodeHex } from 'jsr:@std/encoding@1/hex';
import { APPLE_ROOT_CA, APPLE_ROOT_CA_G2, APPLE_ROOT_CA_G3 } from './apple_roots.ts';
import { X509Certificate } from 'node:crypto';
import * as x509 from '@peculiar/x509';
import { verifyTransaction } from './pro.ts';

// Sandbox transactions for Pro monthly, valid until 2099, signed by test chains shaped like Apple's (the
// intermediate and leaf carry Apple's marker extensions). Only the test roots and the signed transactions
// are here; the keys that made them were thrown away. The second chain matches Apple's algorithms: a
// P-384 root and intermediate signing with SHA-384, and a P-256 leaf.
const TEST_ROOT =
  'MIIBpDCCAUmgAwIBAgIUSs+NQQv7AfcIIFNzJQ4mLI7/QMcwCgYIKoZIzj0EAwIwHjEcMBoGA1UEAwwTVGFpcGVpQnVzIFRlc3Qg' +
  'Um9vdDAgFw0yNjEwMjUxMzU5NDVaGA8yMTI2MTAwMTEzNTk0NVowHjEcMBoGA1UEAwwTVGFpcGVpQnVzIFRlc3QgUm9vdDBZMBMG' +
  'ByqGSM49AgEGCCqGSM49AwEHA0IABKpIXL8E4RLnXQBGKum0ugAF99kVivkwniVZIM1CvVRNv2GUmFtxp5hDVdkMsLrsledMcOTT' +
  'lnofbB1gHc4BjWCjYzBhMB0GA1UdDgQWBBRZKkOqRhWQ23kRDR0VptYhXlEqXTAfBgNVHSMEGDAWgBRZKkOqRhWQ23kRDR0VptYh' +
  'XlEqXTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAKBggqhkjOPQQDAgNJADBGAiEA4JjEINN02bwu2OBfu0bOkhVu' +
  'dXEFu+8D7iirNkAWXzkCIQCMjh2pp7scm+1OU+pEq1pUCGV2BO9CUddUJIGMB0EjPQ==';
const TEST_TRANSACTION =
  'eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCc2pDQ0FWaWdBd0lCQWdJVU1vQWk2c2xmN0lTclk3Qk1sb2dSRHd1b0VDTXdDZ1lJ' +
  'S29aSXpqMEVBd0l3SGpFY01Cb0dBMVVFQXd3VFZHRnBjR1ZwUW5WeklGUmxjM1FnVjFkRVVqQWdGdzB5TmpFd01qVXhNelU1TkRW' +
  'YUdBOHlNVEl5TURneU16RXpOVGswTlZvd0hqRWNNQm9HQTFVRUF3d1RWR0ZwY0dWcFFuVnpJRlJsYzNRZ1RHVmhaakJaTUJNR0J5' +
  'cUdTTTQ5QWdFR0NDcUdTTTQ5QXdFSEEwSUFCTGQ3VkVReVU4SVNraWdVVGtkMTRzNFhybXNQTUFTRWNOSFlwN1hkaURpbDlaUHk4' +
  'anRrbG0wTk1WZS9Cc2k4OHNoNzN3cENnemNQQkxXeHNZUmdCUDZqY2pCd01Bd0dBMVVkRXdFQi93UUNNQUF3RGdZRFZSMFBBUUgv' +
  'QkFRREFnZUFNQkFHQ2lxR1NJYjNZMlFHQ3dFRUFnVUFNQjBHQTFVZERnUVdCQlNqVWNtSVVJNkVCMGMzcGt5c1VnQ2l4M3hDMnpB' +
  'ZkJnTlZIU01FR0RBV2dCVFp2MXRDekcvenMvS3hWdVh0YzZhb1hsUkdEVEFLQmdncWhrak9QUVFEQWdOSUFEQkZBaUVBb2NCajVT' +
  'YjQzT2xtTGNZY2Y4bmR5bDRiZTE2QUhLaTRuV0EvRXdUQWk1Z0NJQTFGeVdyb2piV0cxNVU5WnZaRVVqS1Z5Tnc5TzhGM205NUQy' +
  'dUFBcDM3aSIsIk1JSUJ0VENDQVZ1Z0F3SUJBZ0lVTEh6c0hmcjdFWHZjc2RBWnArTUVPcXNJOHQ4d0NnWUlLb1pJemowRUF3SXdI' +
  'akVjTUJvR0ExVUVBd3dUVkdGcGNHVnBRblZ6SUZSbGMzUWdVbTl2ZERBZ0Z3MHlOakV3TWpVeE16VTVORFZhR0E4eU1USTFNRFV4' +
  'T1RFek5UazBOVm93SGpFY01Cb0dBMVVFQXd3VFZHRnBjR1ZwUW5WeklGUmxjM1FnVjFkRVVqQlpNQk1HQnlxR1NNNDlBZ0VHQ0Nx' +
  'R1NNNDlBd0VIQTBJQUJKbFVGRU5xUk1PUkVNajZ5OXJSTnZabU9PQW02amhZa3dlOU1NWlJOY3p6bmhMeWNxdlRhNldqUW5Xbm1J' +
  'cTVsZUMxSlNjaThlczRkUFgzek1LTTZGdWpkVEJ6TUE4R0ExVWRFd0VCL3dRRk1BTUJBZjh3RGdZRFZSMFBBUUgvQkFRREFnRUdN' +
  'QkFHQ2lxR1NJYjNZMlFHQWdFRUFnVUFNQjBHQTFVZERnUVdCQlRadjF0Q3pHL3pzL0t4VnVYdGM2YW9YbFJHRFRBZkJnTlZIU01F' +
  'R0RBV2dCUlpLa09xUmhXUTIza1JEUjBWcHRZaFhsRXFYVEFLQmdncWhrak9QUVFEQWdOSUFEQkZBaUJJcExGWExyamU1Q1BPVlRI' +
  'dkZBZzlGeEZlTWh6N1ZUc241UFgvNzJxaTlRSWhBSkxmSENuNU1QUFBxNjJ6WlJPTWdaOEU5bjNHL1JuRXd6M3I5bzJub2FCSyIs' +
  'Ik1JSUJwRENDQVVtZ0F3SUJBZ0lVU3MrTlFRdjdBZmNJSUZOekpRNG1MSTcvUU1jd0NnWUlLb1pJemowRUF3SXdIakVjTUJvR0Ex' +
  'VUVBd3dUVkdGcGNHVnBRblZ6SUZSbGMzUWdVbTl2ZERBZ0Z3MHlOakV3TWpVeE16VTVORFZhR0E4eU1USTJNVEF3TVRFek5UazBO' +
  'Vm93SGpFY01Cb0dBMVVFQXd3VFZHRnBjR1ZwUW5WeklGUmxjM1FnVW05dmREQlpNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VI' +
  'QTBJQUJLcElYTDhFNFJMblhRQkdLdW0wdWdBRjk5a1Zpdmt3bmlWWklNMUN2VlJOdjJHVW1GdHhwNWhEVmRrTXNMcnNsZWRNY09U' +
  'VGxub2ZiQjFnSGM0QmpXQ2pZekJoTUIwR0ExVWREZ1FXQkJSWktrT3FSaFdRMjNrUkRSMFZwdFloWGxFcVhUQWZCZ05WSFNNRUdE' +
  'QVdnQlJaS2tPcVJoV1EyM2tSRFIwVnB0WWhYbEVxWFRBUEJnTlZIUk1CQWY4RUJUQURBUUgvTUE0R0ExVWREd0VCL3dRRUF3SUJC' +
  'akFLQmdncWhrak9QUVFEQWdOSkFEQkdBaUVBNEpqRUlOTjAyYnd1Mk9CZnUwYk9raFZ1ZFhFRnUrOEQ3aWlyTmtBV1h6a0NJUUNN' +
  'amgycHA3c2NtKzFPVStwRXExcFVDR1YyQk85Q1VkZFVKSUdNQjBFalBRPT0iXX0.eyJ0cmFuc2FjdGlvbklkIjoiMjAwMDAwMDAw' +
  'MDAwMDAwMSIsIm9yaWdpbmFsVHJhbnNhY3Rpb25JZCI6IjIwMDAwMDAwMDAwMDAwMDEiLCJidW5kbGVJZCI6ImNvbS5yaW8xMDI1' +
  'NTI1NC5UYWlwZWlCdXMiLCJwcm9kdWN0SWQiOiJjb20ucmlvMTAyNTUyNTQuVGFpcGVpQnVzLnByby5tb250aGx5IiwicHVyY2hh' +
  'c2VEYXRlIjoxNzkyOTM2ODAwMDAwLCJvcmlnaW5hbFB1cmNoYXNlRGF0ZSI6MTc5MjkzNjgwMDAwMCwiZXhwaXJlc0RhdGUiOjQw' +
  'NzA5MDg4MDAwMDAsInF1YW50aXR5IjoxLCJ0eXBlIjoiQXV0by1SZW5ld2FibGUgU3Vic2NyaXB0aW9uIiwiaW5BcHBPd25lcnNo' +
  'aXBUeXBlIjoiUFVSQ0hBU0VEIiwic2lnbmVkRGF0ZSI6MTc5MjkzNjgwMDAwMCwiZW52aXJvbm1lbnQiOiJTYW5kYm94IiwidHJh' +
  'bnNhY3Rpb25SZWFzb24iOiJQVVJDSEFTRSIsInN0b3JlZnJvbnQiOiJUV04iLCJzdG9yZWZyb250SWQiOiIxNDM0NzAifQ.OA7R_' +
  'soR1rLt_EpGF5gM19Ldg5GXuwAJbQdz_UUop72jRNq4NfjOX1q7VK4xG3_zR2wc_Ffa-TXH6AAFQcaDZA';

const APPLE_SHAPED_ROOT =
  'MIICBTCCAYqgAwIBAgIUYNKEFT0ebUJ2kkhisqK+5fFhiHIwCgYIKoZIzj0EAwMwMDEfMB0GA1UEAwwWVGFpcGVpQnVzIFRlc3Qg' +
  'Um9vdCBHMzENMAsGA1UECgwEVGVzdDAgFw0yNjEwMjUxNTI5MjVaGA8yMTI2MTAwMTE1MjkyNVowMDEfMB0GA1UEAwwWVGFpcGVp' +
  'QnVzIFRlc3QgUm9vdCBHMzENMAsGA1UECgwEVGVzdDB2MBAGByqGSM49AgEGBSuBBAAiA2IABAgntvnViNZQ/n/GxRVl9nw4tZyc' +
  '+ihqhiPQY2FIyuIavpYEdMVc9mSejr57fO/sZSOIUpvRaUXzkPjzqbxtagdmZND5QOcmErZsQmYpENC7dx0HaZx+jjwUPDglKb5V' +
  'YKNjMGEwHQYDVR0OBBYEFJi6SZC+kmUSd4EbqU00g6ROxWSKMB8GA1UdIwQYMBaAFJi6SZC+kmUSd4EbqU00g6ROxWSKMA8GA1Ud' +
  'EwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2kAMGYCMQCMP53gizHmIi7J2Po8h0vnlZpde/UKXi+Ul1aX' +
  'aUkd1/4QbzbxzRoW5aKePV9+6DECMQChsozVdrNJUGNxM35jzNe8M1XmXOpWdC+8STKVNZkj6UggMG3hVc4Ii+k3FcTIdQ0=';
const APPLE_SHAPED_TRANSACTION =
  'eyJhbGciOiJFUzI1NiIsIng1YyI6WyJNSUlCOHpDQ0FYbWdBd0lCQWdJVVZhT0drUWRPSWpmSmZYMWpIdEgrYjN1QllRTXdDZ1lJ' +
  'S29aSXpqMEVBd013TURFZk1CMEdBMVVFQXd3V1ZHRnBjR1ZwUW5WeklGUmxjM1FnVjFkRVVpQkhOakVOTUFzR0ExVUVDZ3dFVkdW' +
  'emREQWdGdzB5TmpFd01qVXhOVEk1TWpWYUdBOHlNVEl5TURneU16RTFNamt5TlZvd0xURWNNQm9HQTFVRUF3d1RWR0ZwY0dWcFFu' +
  'VnpJRlJsYzNRZ1RHVmhaakVOTUFzR0ExVUVDZ3dFVkdWemREQlpNQk1HQnlxR1NNNDlBZ0VHQ0NxR1NNNDlBd0VIQTBJQUJIMmFP' +
  'OWdBYis5cmk4cUVTZS9DbnJWR0lNWHAvQzBuMXZ0bS8vb28vRWVvMlpRaTMxaVpXUjgwazVMQXhzcXJDSHdvM3RYQ2lWRTBQby9x' +
  'Q0Q5dS81T2pjakJ3TUF3R0ExVWRFd0VCL3dRQ01BQXdEZ1lEVlIwUEFRSC9CQVFEQWdlQU1CQUdDaXFHU0liM1kyUUdDd0VFQWdV' +
  'QU1CMEdBMVVkRGdRV0JCUjRkN0NIa2I1RkZBVEVSOTR4bnpjeFJkWis3ekFmQmdOVkhTTUVHREFXZ0JTZi9URU4wblRSZ1k4NmRh' +
  'azRSUm5Sb0x4bURqQUtCZ2dxaGtqT1BRUURBd05vQURCbEFqRUEvNFVXUzJ3YWduT3VERk12eENyaitHekFGYnJyZUtzbUx1NXpo' +
  'MWRrS1NkR2NtUjJZRXhMamR6MHVMMVpWMEVxQWpCSUErbFlaN2lMRksycFdlVjQyRUF6dmt4VTRvVE5BcnNPa0dLVzIxZGlDL0Z2' +
  'U2llUGdlUVJvcXZIeEthUE13QT0iLCJNSUlDRnpDQ0FaeWdBd0lCQWdJVVNVcXloRFFSQ0lMeU1TY2h1N1N5M1RRMGd5Z3dDZ1lJ' +
  'S29aSXpqMEVBd013TURFZk1CMEdBMVVFQXd3V1ZHRnBjR1ZwUW5WeklGUmxjM1FnVW05dmRDQkhNekVOTUFzR0ExVUVDZ3dFVkdW' +
  'emREQWdGdzB5TmpFd01qVXhOVEk1TWpWYUdBOHlNVEkxTURVeE9URTFNamt5TlZvd01ERWZNQjBHQTFVRUF3d1dWR0ZwY0dWcFFu' +
  'VnpJRlJsYzNRZ1YxZEVVaUJITmpFTk1Bc0dBMVVFQ2d3RVZHVnpkREIyTUJBR0J5cUdTTTQ5QWdFR0JTdUJCQUFpQTJJQUJQdmZ0' +
  'L2VMTWxWVEoyajJXczhQdW0wUGR4Nk1IZnhnZHJzMjlvWlBPQkxFNXlLWnlaZEFYcEFXSlB5bGR3R3h5S3haSnpyNkZqYm1IcS92' +
  'SzlONG9GTDdsWXh2a2JmOXV0M3BNQXQxSmRUY2s0TG9ZbFRpeEZ1QTMvZCtJcCtLanFOMU1ITXdEd1lEVlIwVEFRSC9CQVV3QXdF' +
  'Qi96QU9CZ05WSFE4QkFmOEVCQU1DQVFZd0VBWUtLb1pJaHZkalpBWUNBUVFDQlFBd0hRWURWUjBPQkJZRUZKLzlNUTNTZE5HQmp6' +
  'cDFxVGhGR2RHZ3ZHWU9NQjhHQTFVZEl3UVlNQmFBRkppNlNaQytrbVVTZDRFYnFVMDBnNlJPeFdTS01Bb0dDQ3FHU000OUJBTURB' +
  'MmtBTUdZQ01RQ2Y0MFBubGh2Skt0azZNNTBBbnUvOGhWcE1qVTcrL3M4N3RackZERm9uSVB2eEhXL0hFQkZJdkVVaXlnTFJUR2ND' +
  'TVFETjBjUCtKNVE5ZEkxYi8wK3plQzJjS0pkMHkrOVM1eWhheWtaNXlKYmZOeUJHQWJtWFFSaFo1dnBGQXlFQm5XRT0iLCJNSUlD' +
  'QlRDQ0FZcWdBd0lCQWdJVVlOS0VGVDBlYlVKMmtraGlzcUsrNWZGaGlISXdDZ1lJS29aSXpqMEVBd013TURFZk1CMEdBMVVFQXd3' +
  'V1ZHRnBjR1ZwUW5WeklGUmxjM1FnVW05dmRDQkhNekVOTUFzR0ExVUVDZ3dFVkdWemREQWdGdzB5TmpFd01qVXhOVEk1TWpWYUdB' +
  'OHlNVEkyTVRBd01URTFNamt5TlZvd01ERWZNQjBHQTFVRUF3d1dWR0ZwY0dWcFFuVnpJRlJsYzNRZ1VtOXZkQ0JITXpFTk1Bc0dB' +
  'MVVFQ2d3RVZHVnpkREIyTUJBR0J5cUdTTTQ5QWdFR0JTdUJCQUFpQTJJQUJBZ250dm5WaU5aUS9uL0d4UlZsOW53NHRaeWMraWhx' +
  'aGlQUVkyRkl5dUlhdnBZRWRNVmM5bVNlanI1N2ZPL3NaU09JVXB2UmFVWHprUGp6cWJ4dGFnZG1aTkQ1UU9jbUVyWnNRbVlwRU5D' +
  'N2R4MEhhWngramp3VVBEZ2xLYjVWWUtOak1HRXdIUVlEVlIwT0JCWUVGSmk2U1pDK2ttVVNkNEVicVUwMGc2Uk94V1NLTUI4R0Ex' +
  'VWRJd1FZTUJhQUZKaTZTWkMra21VU2Q0RWJxVTAwZzZST3hXU0tNQThHQTFVZEV3RUIvd1FGTUFNQkFmOHdEZ1lEVlIwUEFRSC9C' +
  'QVFEQWdFR01Bb0dDQ3FHU000OUJBTURBMmtBTUdZQ01RQ01QNTNnaXpIbUlpN0oyUG84aDB2bmxacGRlL1VLWGkrVWwxYVhhVWtk' +
  'MS80UWJ6Ynh6Um9XNWFLZVBWOSs2REVDTVFDaHNvelZkck5KVUdOeE0zNWp6TmU4TTFYbVhPcFdkQys4U1RLVk5aa2o2VWdnTUcz' +
  'aFZjNElpK2szRmNUSWRRMD0iXX0.eyJ0cmFuc2FjdGlvbklkIjoiMjAwMDAwMDAwMDAwMDAwMSIsIm9yaWdpbmFsVHJhbnNhY3Rp' +
  'b25JZCI6IjIwMDAwMDAwMDAwMDAwMDEiLCJidW5kbGVJZCI6ImNvbS5yaW8xMDI1NTI1NC5UYWlwZWlCdXMiLCJwcm9kdWN0SWQi' +
  'OiJjb20ucmlvMTAyNTUyNTQuVGFpcGVpQnVzLnByby5tb250aGx5IiwicHVyY2hhc2VEYXRlIjoxNzkyOTQ0MDAwMDAwLCJvcmln' +
  'aW5hbFB1cmNoYXNlRGF0ZSI6MTc5Mjk0NDAwMDAwMCwiZXhwaXJlc0RhdGUiOjQwNzA5MDg4MDAwMDAsInF1YW50aXR5IjoxLCJ0' +
  'eXBlIjoiQXV0by1SZW5ld2FibGUgU3Vic2NyaXB0aW9uIiwiaW5BcHBPd25lcnNoaXBUeXBlIjoiUFVSQ0hBU0VEIiwic2lnbmVk' +
  'RGF0ZSI6MTc5Mjk0NDAwMDAwMCwiZW52aXJvbm1lbnQiOiJTYW5kYm94IiwidHJhbnNhY3Rpb25SZWFzb24iOiJQVVJDSEFTRSIs' +
  'InN0b3JlZnJvbnQiOiJUV04iLCJzdG9yZWZyb250SWQiOiIxNDM0NzAifQ.lHLf5K5jGpS2YTrXoYKbS3oobWCr6qtSlddoouvOz' +
  'uVna2p-fEuDS-fLlEY3I1hSxIDLk4-0q8DRc3U8sZ-UFQ';

async function fingerprint(base64: string): Promise<string> {
  const der = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  return encodeHex(await crypto.subtle.digest('SHA-256', der));
}

Deno.test('the bundled roots are Apple\'s published certificates', async () => {
  assertEquals(await fingerprint(APPLE_ROOT_CA_G3), '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179');
  assertEquals(await fingerprint(APPLE_ROOT_CA_G2), 'c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050');
  assertEquals(await fingerprint(APPLE_ROOT_CA), 'b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024');
});

// Supabase's runtime does not implement these; the check must not need them.
const unimplemented = () => {
  throw new Error('Not implemented: crypto.X509Certificate.prototype.verify');
};

Deno.test('a TestFlight purchase is verified offline, without node:crypto certificates', async () => {
  const realFetch = globalThis.fetch;
  const realVerify = X509Certificate.prototype.verify;
  globalThis.fetch = () => Promise.reject(new Error('no network in this test'));
  X509Certificate.prototype.verify = unimplemented;
  try {
    for (const [root, transaction] of [[TEST_ROOT, TEST_TRANSACTION], [APPLE_SHAPED_ROOT, APPLE_SHAPED_TRANSACTION]]) {
      const pro = await verifyTransaction(transaction, [root]);
      assert(pro);
      assertEquals(pro.originalTransactionId, '2000000000000001');
      assertEquals(pro.expiresDate, Date.UTC(2099, 0, 1));
    }
  } finally {
    globalThis.fetch = realFetch;
    X509Certificate.prototype.verify = realVerify;
  }
});

Deno.test('a transaction not signed by a trusted root is not Pro', async () => {
  assertEquals(await verifyTransaction(TEST_TRANSACTION), null, 'Apple roots do not trust the test chain');
  assertEquals(await verifyTransaction(APPLE_SHAPED_TRANSACTION, [TEST_ROOT]), null, 'another root');
});

Deno.test('a changed transaction is not Pro', async () => {
  const [header, payload, signature] = APPLE_SHAPED_TRANSACTION.split('.');
  const claims = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  const forged = btoa(JSON.stringify({ ...claims, productId: 'com.rio10255254.TaipeiBus.pro.yearly' }))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  assertEquals(await verifyTransaction(`${header}.${forged}.${signature}`, [APPLE_SHAPED_ROOT]), null);
});

// Billing grace: a chain made here, its transaction already past its period and its renewal info
// saying when grace ends.
const ES256 = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' };
const encode = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes));
const encodeUrl = (bytes: Uint8Array) => encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function graceChain() {
  const notBefore = new Date(Date.now() - 86_400_000), notAfter = new Date(Date.now() + 86_400_000);
  const marker = (oid: string) => new x509.Extension(oid, false, new Uint8Array([5, 0]));
  const rootKeys = await crypto.subtle.generateKey(ES256, true, ['sign', 'verify']) as CryptoKeyPair;
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: '01', name: 'CN=TaipeiBus Grace Root', notBefore, notAfter, keys: rootKeys, signingAlgorithm: ES256,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const middleKeys = await crypto.subtle.generateKey(ES256, true, ['sign', 'verify']) as CryptoKeyPair;
  const middle = await x509.X509CertificateGenerator.create({
    serialNumber: '02', subject: 'CN=TaipeiBus Grace WWDR', issuer: root.subject, notBefore, notAfter,
    publicKey: middleKeys.publicKey, signingKey: rootKeys.privateKey, signingAlgorithm: ES256,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true), marker('1.2.840.113635.100.6.2.1')],
  });
  const leafKeys = await crypto.subtle.generateKey(ES256, true, ['sign', 'verify']) as CryptoKeyPair;
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: '03', subject: 'CN=TaipeiBus Grace Leaf', issuer: middle.subject, notBefore, notAfter,
    publicKey: leafKeys.publicKey, signingKey: middleKeys.privateKey, signingAlgorithm: ES256,
    extensions: [new x509.BasicConstraintsExtension(false, undefined, true), marker('1.2.840.113635.100.6.11.1')],
  });
  const x5c = [leaf, middle, root].map((certificate) => encode(new Uint8Array(certificate.rawData)));
  const sign = async (claims: Record<string, unknown>) => {
    const text = (value: unknown) => encodeUrl(new TextEncoder().encode(JSON.stringify(value)));
    const signed = `${text({ alg: 'ES256', x5c })}.${text({ signedDate: Date.now(), ...claims })}`;
    const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, leafKeys.privateKey, new TextEncoder().encode(signed));
    return `${signed}.${encodeUrl(new Uint8Array(signature))}`;
  };
  return { root: x5c[2], sign };
}

Deno.test('a subscription in billing grace stays Pro until grace ends', async () => {
  const { root, sign } = await graceChain();
  const lapsed = await sign({
    originalTransactionId: '2000000000000009', bundleId: 'com.rio10255254.TaipeiBus', environment: 'Sandbox',
    productId: 'com.rio10255254.TaipeiBus.pro.monthly', expiresDate: Date.now() - 3_600_000,
  });
  const graceEnds = Date.now() + 6 * 86_400_000;
  const renewal = await sign({ originalTransactionId: '2000000000000009', environment: 'Sandbox', gracePeriodExpiresDate: graceEnds });
  assertEquals(await verifyTransaction(lapsed, [root]), null, 'past its period without renewal info');
  assertEquals(await verifyTransaction(lapsed, [root], renewal), { originalTransactionId: '2000000000000009', expiresDate: graceEnds });
  const ended = await sign({ originalTransactionId: '2000000000000009', environment: 'Sandbox', gracePeriodExpiresDate: Date.now() - 1 });
  assertEquals(await verifyTransaction(lapsed, [root], ended), null, 'grace over');
  const another = await sign({ originalTransactionId: '2000000000000010', environment: 'Sandbox', gracePeriodExpiresDate: graceEnds });
  assertEquals(await verifyTransaction(lapsed, [root], another), null, 'another subscription\'s renewal');
});
