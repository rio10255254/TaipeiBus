// Runs against a local stand-in for the Messages API: deno test --allow-env --allow-net
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { askClaude } from './claude.ts';

type Received = { body: Record<string, unknown>; key: string | null };

async function withServer(answer: (body: Record<string, unknown>) => Response, run: (received: Received[]) => Promise<void>) {
  const received: Received[] = [];
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    const body = await request.json();
    const key = request.headers.get('x-api-key') ?? request.headers.get('authorization')?.replace(/^Bearer /, '') ?? null;
    received.push({ body, key });
    return answer(body);
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    await run(received);
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
}

function message(stopReason: string, text: string): Response {
  return Response.json({
    id: 'msg_test', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', stop_reason: stopReason,
    content: [{ type: 'text', text }], usage: { input_tokens: 120, output_tokens: 18 },
  });
}

const chat = {
  model: 'openai/gpt-oss-120b', max_completion_tokens: 500, temperature: 0,
  messages: [{ role: 'system', content: '只輸出 JSON {"destination":""}' }, { role: 'user', content: '去台北車站' }],
};

Deno.test('asks Claude without sampling settings and answers in the chat completions shape', async () => {
  await withServer(() => message('end_turn', '{"destination":"台北車站"}'), async (received) => {
    const { answer } = await askClaude('test-key', chat);
    assertEquals(received.length, 1);
    const { body, key } = received[0];
    assertEquals(key, 'test-key');
    assertEquals(body.model, 'claude-haiku-5-5');
    assertEquals(body.max_tokens, 500);
    assertEquals(body.thinking, { type: 'disabled' });
    assertEquals(body.output_config, { effort: 'low' });
    assert(!('temperature' in body));
    assert(String(body.system).startsWith('只輸出 JSON'));
    assertEquals(body.messages, [{ role: 'user', content: '去台北車站' }]);
    const choices = answer?.choices as Array<{ message: { content: string } }>;
    assertEquals(choices[0].message.content, '{"destination":"台北車站"}');
    assertEquals(answer?.model, 'claude-haiku-5-5');
  });
});

Deno.test('leaves a declined, cut-off or non-JSON answer to Groq', async () => {
  for (const [stop, text] of [['refusal', ''], ['max_tokens', '{"destination":'], ['end_turn', '台北車站']]) {
    await withServer(() => message(stop, text), async () => {
      const { answer, failure } = await askClaude('test-key', chat);
      assertEquals(answer, null);
      assert(failure);
    });
  }
});

Deno.test('fails over at once when Claude errors, without retrying', async () => {
  await withServer(() => Response.json({ type: 'error', error: { type: 'overloaded_error', message: 'busy' } }, { status: 529 }),
    async (received) => {
      const { answer, failure } = await askClaude('test-key', chat);
      assertEquals(answer, null);
      assertEquals(failure, '529 InternalServerError overloaded_error: busy');
      assertEquals(received.length, 1);
    });
});

Deno.test('sends nothing without a user message', async () => {
  await withServer(() => message('end_turn', '{}'), async (received) => {
    assertEquals((await askClaude('test-key', { ...chat, messages: [{ role: 'system', content: 'x' }] })).answer, null);
    assertEquals(received.length, 0);
  });
});
