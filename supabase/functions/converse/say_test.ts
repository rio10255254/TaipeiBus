import { assert, assertEquals } from 'jsr:@std/assert@1';
import { streamClaude } from './brain.ts';
import { SayReader } from './say.ts';

function readAll(chunks: string[]): string[] {
  const reader = new SayReader();
  return chunks.map((chunk) => reader.push(chunk));
}

Deno.test('the spoken words come out as they arrive', () => {
  assertEquals(readAll(['{"sa', 'y": "307 往', '板橋，{r1}。', '", "actions": []}']), ['', '307 往', '板橋，{r1}。', '']);
});

Deno.test('escapes split across chunks are decoded once complete', () => {
  assertEquals(readAll(['{"say":"他說\\', '"好\\"，\\u59', '7d。"}']).join(''), '他說"好"，好。');
});

Deno.test('nothing after the closing quote, and the reader says it is complete', () => {
  const reader = new SayReader();
  reader.push('{"say":"好');
  assert(!reader.complete);
  reader.push('。","actions"');
  assert(reader.complete);
  assertEquals(readAll(['{"say":"好。","choices":["say"]', '}']), ['好。', '']);
});

Deno.test('a reply without say yields nothing', () => {
  assertEquals(readAll(['{"actions":[]}']), ['']);
});

Deno.test('a streamed Claude turn hands over the words before the reply', async () => {
  const none = { type: 'none', stop: '', route: '', destination: '', origin: '', time: '', mode: 'any', preference: 'balanced', option: 0 };
  const json = JSON.stringify({ say: '307 往板橋，{r1}。', actions: [], confirm: none, choices: [], followUp: true });
  const pieces = [json.slice(0, 12), json.slice(12, 20), json.slice(20)];
  const events = [
    { type: 'message_start', message: { id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', content: [], stop_reason: null, usage: { input_tokens: 900, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    ...pieces.map((text) => ({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } })),
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 40 } },
    { type: 'message_stop' },
  ];
  let streamed = false;
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    streamed = (await request.json()).stream === true;
    const body = events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
    return new Response(body, { headers: { 'Content-Type': 'text/event-stream' } });
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    const words: string[] = [];
    let said = 0;
    const result = await streamClaude('test-key', '乘客剛剛說：307 還要多久', (say, complete) => {
      words.push(say);
      if (complete) said += 1;
    });
    assertEquals(said, 1);
    assert(streamed);
    assert('reply' in result && result.spoke);
    assertEquals(words.join(''), '307 往板橋，{r1}。');
    assertEquals(result.reply.say, words.join(''));
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
});
