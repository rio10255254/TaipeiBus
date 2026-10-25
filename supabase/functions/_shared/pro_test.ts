import { assert, assertEquals } from 'jsr:@std/assert@1';
import { crypto } from 'jsr:@std/crypto@1';
import { encodeHex } from 'jsr:@std/encoding@1/hex';
import { APPLE_ROOT_CA, APPLE_ROOT_CA_G2, APPLE_ROOT_CA_G3 } from './apple_roots.ts';
import { makeVerifiers, verifyTransaction } from './pro.ts';

// A Sandbox transaction for Pro monthly, valid until 2099, signed by a test chain shaped like Apple's (the
// intermediate and leaf carry Apple's marker extensions). Only the test root and the signed transaction are
// here; the keys that made them were thrown away.
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

async function fingerprint(base64: string): Promise<string> {
  const der = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
  return encodeHex(await crypto.subtle.digest('SHA-256', der));
}

Deno.test('the bundled roots are Apple\'s published certificates', async () => {
  assertEquals(await fingerprint(APPLE_ROOT_CA_G3), '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179');
  assertEquals(await fingerprint(APPLE_ROOT_CA_G2), 'c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050');
  assertEquals(await fingerprint(APPLE_ROOT_CA), 'b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024');
});

Deno.test('a TestFlight purchase is verified without downloading anything', async () => {
  const realFetch = globalThis.fetch;
  globalThis.fetch = () => Promise.reject(new Error('no network in this test'));
  try {
    const pro = await verifyTransaction(TEST_TRANSACTION, makeVerifiers([TEST_ROOT]));
    assert(pro);
    assertEquals(pro.originalTransactionId, '2000000000000001');
    assertEquals(pro.expiresDate, Date.UTC(2099, 0, 1));
  } finally {
    globalThis.fetch = realFetch;
  }
});

Deno.test('a transaction not signed by Apple is not Pro', async () => {
  assertEquals(await verifyTransaction(TEST_TRANSACTION, makeVerifiers()), null);
});
