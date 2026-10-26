// deno test --allow-env --allow-net
import { assert, assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { check, problems } from './checks.ts';
import { readReply } from './reply.ts';
import { columnsReady, expectation, isVerdict, judge, logLine, printable, readJudgment, readReports, selectQuery, updateQuery, verdictOf } from './replay.ts';

const none = { type: 'none', stop: '', route: '', destination: '', origin: '', time: '', then: '', query: '', mode: 'any', preference: 'balanced', option: 0 };
const replyOf = (say: string) => readReply({ say, actions: [], confirm: none, choices: [], followUp: false })!;
const fine = { pass: true, category: 'fine', reported: 'misheard' } as const;

Deno.test('rows become reports; ids must be positive integers and something must have been heard', () => {
  const reports = readReports([
    { id: 7, heard: '三零七還要多酒', said: '307 {r1}。', state: '畫面：地圖' },
    { id: '12', heard: '去淡水', said: null, state: null },
    { id: '12; drop table x', heard: 'a' }, { id: -1, heard: 'a' }, { id: 1.5, heard: 'a' }, { id: 3, heard: '  ' }, null, 'row',
  ]);
  assertEquals(reports, [
    { id: 7, heard: '三零七還要多酒', said: '307 {r1}。', state: '畫面：地圖' },
    { id: 12, heard: '去淡水', said: '', state: '' },
  ]);
  assertThrows(() => readReports({ message: 'error' }));
});

Deno.test('the select query carries only an integer limit', () => {
  assert(selectQuery(20).endsWith('limit 20'));
  assert(selectQuery(1e9).endsWith('limit 100'));
  assert(selectQuery(0).endsWith('limit 1'));
  assert(selectQuery(5.7).endsWith('limit 5'));
  assert(selectQuery(NaN).endsWith('limit 20'));
  assert(selectQuery(20).includes("interval '30 days'"));
});

Deno.test('the update query takes an integer id and fixed labels only', () => {
  assertEquals(updateQuery(42, 'fail:misheard', 'fine', 'claude-haiku-5-5'),
    "update public.assistant_feedback set verdict = 'fail:misheard', reported_issue = 'fine', checked_model = 'claude-haiku-5-5', checked_at = now() where id = 42");
  assertThrows(() => updateQuery(Number('1; drop table x'), 'pass', 'fine', 'm'));
  assertThrows(() => updateQuery(0, 'pass', 'fine', 'm'));
  assertThrows(() => updateQuery(1.5, 'pass', 'fine', 'm'));
  // deno-lint-ignore no-explicit-any
  assertThrows(() => updateQuery(1, "fail:x' or '1'='1" as any, 'fine', 'm'));
  // deno-lint-ignore no-explicit-any
  assertThrows(() => updateQuery(1, 'pass', 'nope' as any, 'm'));
  assertThrows(() => updateQuery(1, 'pass', 'fine', "m', verdict = 'pass"));
});

Deno.test('verdicts: the checks decide first, then the judge', () => {
  assertEquals(verdictOf([], fine), 'pass');
  assertEquals(verdictOf([{ category: 'too_long', text: '太長' }], fine), 'fail:too_long');
  assertEquals(verdictOf([], { pass: false, category: 'misheard', reported: 'fine' }), 'fail:misheard');
  assertEquals(verdictOf([], { pass: false, category: 'fine', reported: 'fine' }), 'fail:unhelpful');
  assert(isVerdict('pass') && isVerdict('fail:invented_fact'));
  assert(!isVerdict('fail:fine') && !isVerdict('fail:') && !isVerdict('ok'));
});

Deno.test('a replayed turn is checked like the eval, with no web lookup left', () => {
  const report = { id: 1, heard: '三零七還要多酒', said: '', state: '畫面：站牌\n可用資料（念的時候寫成 {代號}）：\n[r1] 307 的到站' };
  assertEquals(verdictOf(problems(expectation(report), replyOf('307 {r1}。')), fine), 'pass');
  assertEquals(verdictOf(problems(expectation(report), replyOf('307 再 5 分鐘到。')), fine), 'fail:invented_fact');
  assertEquals(verdictOf(problems(expectation(report), replyOf('307 {r2}。')), fine), 'fail:invented_fact');
  assertEquals(verdictOf(problems(expectation(report), replyOf('我上網查一下。')), fine), 'fail:wrong_action');
  assertEquals(verdictOf(problems(expectation(report), replyOf('您好，307 {r1}。')), fine), 'fail:tone');
  assertEquals(expectation({ ...report, heard: 'When is the 307?' }).english, true);
  assertEquals(expectation(report).english, false);
});

Deno.test('check keeps the eval’s own wording', () => {
  assertEquals(check({ state: '', utterance: '307 多久' }, replyOf('307 再 5 分鐘到，您別急。')), ['自己寫了數字「5」', '用「您」而不是「你」']);
});

Deno.test('the judge answers with fixed labels or not at all', () => {
  assertEquals(readJudgment('{"pass":false,"category":"misheard","reported":"wrong_action"}'), { pass: false, category: 'misheard', reported: 'wrong_action' });
  assertEquals(readJudgment('{"pass":true,"category":"其他","reported":"fine"}'), null);
  assertEquals(readJudgment('not json'), null);
});

Deno.test('only plain labels reach the log', () => {
  assertEquals(printable('429 RateLimitError rate_limit_error'), '429 RateLimitError rate_limit_error');
  assertEquals(printable('no words in time'), 'no words in time');
  assertEquals(printable('我要去淡水老街'), '[redacted]');
  assertEquals(printable('heard "take me home"'), '[redacted]');
  assertEquals(printable('x'.repeat(200)), '[redacted]');
  assertEquals(logLine(42, 'fail:misheard', 'fine'), '#42 fail:misheard（回報的回答：fine）');
  // deno-lint-ignore no-explicit-any
  assertEquals(logLine(42, '我要回家' as any, '淡水' as any), '#42 ?（回報的回答：?）');
});

Deno.test('the judge is a short request with its labels enforced', async () => {
  const received: Record<string, unknown>[] = [];
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    received.push(await request.json());
    return Response.json({ id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', stop_reason: 'end_turn',
      content: [{ type: 'text', text: '{"pass":true,"category":"fine","reported":"misheard"}' }], usage: { input_tokens: 500, output_tokens: 20 } });
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    const judged = await judge('test-key', { id: 1, heard: '三零七還要多酒', said: '我聽不懂。', state: '畫面：地圖' }, replyOf('307 {r1}。'));
    assertEquals(judged, { pass: true, category: 'fine', reported: 'misheard' });
    const body = received[0] as {
      output_config: { format?: { type?: string; schema?: { required?: string[] } }; effort?: string }; thinking: unknown; messages: { content: string }[];
    };
    assertEquals(body.output_config.format?.type, 'json_schema');
    assertEquals(body.output_config.format?.schema?.required, ['pass', 'category', 'reported']);
    assertEquals(body.output_config.effort, 'low');
    assertEquals(body.thinking, { type: 'disabled' });
    assert(body.messages[0].content.includes('現在的回答：\n說：307 {r1}。'));
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
});

Deno.test('the replay waits for the verdict columns to be deployed', () => {
  assertEquals(columnsReady([{ ready: 1 }]), true);
  assertEquals(columnsReady([{ ready: '1' }]), true);
  assertEquals(columnsReady([{ ready: 0 }]), false);
  assertEquals(columnsReady([]), false);
  assertEquals(columnsReady({ message: 'error' }), false);
});
