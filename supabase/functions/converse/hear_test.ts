import { assert, assertEquals } from 'jsr:@std/assert@1';
import { chinesePunctuation, hallucinated, heardTurn, readAudio, traditional, transcribe, whisperPrompt } from './hear.ts';

const sound = btoa(String.fromCharCode(...new Uint8Array(2000).fill(7)));

Deno.test('the turn audio is read only when it is there and of a sensible size', () => {
  const audio = readAudio({ audio: sound, audioLanguage: 'en', vocabulary: ['World Gym', 5, 'x'.repeat(50), '台北101'] });
  assertEquals(audio?.bytes.length, 2000);
  assertEquals(audio?.language, 'en');
  assertEquals(audio?.vocabulary, ['World Gym', '台北101']);
  assertEquals(readAudio({ audio: sound })?.language, 'zh');
  assertEquals(readAudio({}), null);
  assertEquals(readAudio({ audio: btoa('short') }), null);
  assertEquals(readAudio({ audio: 'not base64 !!' }), null);
  assertEquals(readAudio({ audio: 'A'.repeat(500_000) }), null);
});

Deno.test('Whisper is told the language, the script and the names to expect', () => {
  const prompt = whisperPrompt({ bytes: new Uint8Array(), language: 'zh', vocabulary: ['World Gym', '圓山', '忠孝復興'] });
  assert(prompt.startsWith('乘客用繁體中文'));
  assert(prompt.endsWith('World Gym、圓山、忠孝復興'));
  const long = whisperPrompt({ bytes: new Uint8Array(), language: 'zh', vocabulary: Array(80).fill('忠孝復興站') });
  assert(long.length < 200);
});

Deno.test("Whisper's reading becomes what was said, in Taiwan's characters", async () => {
  let sent: FormData | undefined;
  const fake = (async (_url: string, init: RequestInit) => {
    sent = init.body as FormData;
    return Response.json({ text: '我想去圆山的酒吧，有什么推荐的吗' });
  }) as typeof fetch;
  const heard = await transcribe('key', { bytes: new Uint8Array(2000), language: 'zh', vocabulary: [] }, fake);
  assertEquals(heard, { text: '我想去圓山的酒吧，有什麼推薦的嗎' });
  assertEquals(chinesePunctuation('我要去 World Gym,怎麼搭比較快?'), '我要去 World Gym，怎麼搭比較快？');
  assertEquals(chinesePunctuation('307還要多久?'), '307還要多久？');
  assertEquals(chinesePunctuation('到站了.'), '到站了。');
  assertEquals(chinesePunctuation('3.5 公里，12:30 出發'), '3.5 公里，12:30 出發');
  assertEquals(sent?.get('model'), 'whisper-large-v3');
  assertEquals(sent?.get('language'), 'zh');
});

Deno.test("Whisper's failures and its words for silence fall back to the phone's reading", async () => {
  const failing = (async () => new Response('busy', { status: 503 })) as typeof fetch;
  assertEquals(await transcribe('key', { bytes: new Uint8Array(2000), language: 'zh', vocabulary: [] }, failing), { failure: 'whisper 503' });
  const silence = (async () => Response.json({ text: '謝謝觀看' })) as typeof fetch;
  assertEquals(await transcribe('key', { bytes: new Uint8Array(2000), language: 'zh', vocabulary: [] }, silence), { failure: 'whisper unusable' });
  assert(hallucinated('請不吝點贊訂閱'));
  assert(!hallucinated('我要去 World Gym'));
  assertEquals(traditional('World Gym'), 'World Gym');
});

Deno.test("the phone's own readings stay as alternatives", () => {
  const input = { utterance: '我要去word jim', alternatives: ['我要去 World Gym', '我要去沃德金'], state: '', history: [] };
  const turn = heardTurn(input, '我要去 World Gym');
  assertEquals(turn.utterance, '我要去 World Gym');
  assertEquals(turn.alternatives, ['我要去word jim', '我要去沃德金']);
});
