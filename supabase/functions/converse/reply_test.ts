// deno test --allow-env --allow-net
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { askClaude } from './brain.ts';
import { readInput, readReply, userMessage } from './reply.ts';

const action = (type: string, extra: Record<string, unknown> = {}) => ({
  type, stop: '', route: '', destination: '', origin: '', time: '', mode: 'any', preference: 'balanced', option: 0, ...extra,
});
const none = action('none');

Deno.test('a plain answer passes with its slots untouched', () => {
  const reply = readReply({ say: '307 {r1}，在新埔站下車。', actions: [action('show_route', { route: '307' })], confirm: none, choices: [], followUp: false });
  assertEquals(reply?.say, '307 {r1}，在新埔站下車。');
  assertEquals(reply?.actions.map((a) => a.type), ['show_route']);
  assertEquals(reply?.confirm.type, 'none');
});

Deno.test('changing the trip is only ever asked, never run', () => {
  const reply = readReply({ say: '要開始導航嗎？', actions: [action('start_navigation'), action('show_stop', { stop: '台北車站' })], confirm: none, choices: [], followUp: false });
  assertEquals(reply?.actions.map((a) => a.type), ['show_stop']);
  assertEquals(reply?.confirm.type, 'start_navigation');
  assertEquals(reply?.followUp, true, 'a question always waits for the answer');
});

Deno.test('a confirm that does not change the trip is dropped', () => {
  assertEquals(readReply({ say: '好', actions: [], confirm: action('show_stop', { stop: 'A' }), choices: [], followUp: false })?.confirm.type, 'none');
});

Deno.test('unknown, empty and excess actions are dropped', () => {
  const reply = readReply({
    say: '好的', confirm: none, choices: [], followUp: false,
    actions: [action('delete_everything'), action('show_stop'), action('plan_trip'), action('choose_option', { option: 7 }),
      action('show_route', { route: '1' }), action('show_route', { route: '2' }), action('show_route', { route: '3' }), action('show_route', { route: '4' })],
  });
  assertEquals(reply?.actions.map((a) => a.route), ['1', '2', '3']);
});

Deno.test('choices are trimmed, unique and at most three', () => {
  const reply = readReply({ say: '哪一站？', actions: [], confirm: none, choices: [' 台北車站 ', '台北車站', '西門', '公館', '古亭', 5], followUp: true });
  assertEquals(reply?.choices, ['台北車站', '西門', '公館']);
});

Deno.test('nothing to say or too much to say is unusable', () => {
  assertEquals(readReply({ say: '  ', actions: [], confirm: none, choices: [], followUp: false }), null);
  assertEquals(readReply({ say: '很'.repeat(161), actions: [], confirm: none, choices: [], followUp: false }), null);
  assertEquals(readReply('not an object'), null);
});

Deno.test('the request is bounded and keeps only the last two turns', () => {
  const input = readInput({ utterance: ' 307 還要多久\u0007 ', state: 'x'.repeat(5000), history: [{ user: 'a', say: 'b' }, { user: 'c', say: 'd' }, { user: 'e', say: 'f' }] });
  assertEquals(input?.utterance, '307 還要多久');
  assertEquals(input?.state.length, 4000);
  assertEquals(input?.history, [{ user: 'c', say: 'd' }, { user: 'e', say: 'f' }]);
  assertEquals(readInput({ utterance: '' }), null);
  const message = userMessage(input!);
  assert(message.startsWith('目前狀態：'));
  assert(message.endsWith('乘客剛剛說：307 還要多久'));
});

Deno.test('Claude is asked with a fixed, cacheable system prompt and the reply schema', async () => {
  const received: Record<string, unknown>[] = [];
  const answer = { say: '307 {r1}。', actions: [], confirm: none, choices: [], followUp: false };
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    received.push(await request.json());
    return Response.json({ id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', stop_reason: 'end_turn',
      content: [{ type: 'text', text: JSON.stringify(answer) }], usage: { input_tokens: 900, output_tokens: 40 } });
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    const result = await askClaude('test-key', '乘客剛剛說：307 還要多久');
    assert('reply' in result);
    assertEquals(result.reply.say, '307 {r1}。');
    const body = received[0] as { system: Array<{ cache_control?: unknown }>; output_config: { format?: { type?: string }; effort?: string }; thinking: unknown };
    assertEquals(body.system[0].cache_control, { type: 'ephemeral' });
    assertEquals(body.output_config.format?.type, 'json_schema');
    assertEquals(body.output_config.effort, 'low');
    assertEquals(body.thinking, { type: 'disabled' });
    assert(!('temperature' in body));
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
});
