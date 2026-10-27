import { assert, assertEquals } from 'jsr:@std/assert@1';
import { searchWeb, streamClaude } from './brain.ts';
import { PlacePeek, SayReader } from './say.ts';

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

function peekAll(chunks: string[]): string[][] {
  const peek = new PlacePeek();
  return chunks.map((chunk) => peek.push(chunk));
}

const empty = '"stop":"","route":"",';

Deno.test('a trip\'s places come out once both names are whole', () => {
  assertEquals(peekAll(['{"say":"好，去南京復興。","actions":[{"type":"plan_trip",', empty + '"destination":"南京', '復興","origin":"', '台北車站","time":""', '}]}']),
    [[], [], [], ['南京復興', '台北車站'], []]);
  assertEquals(peekAll(['{"say":"好","actions":[{"type":"plan_trip",' + empty + '"destination":"Apple 信義A13","origin":"","time":"明天 14:00 出發"}]}']),
    [['Apple 信義A13']]);
});

Deno.test('find_place names come out of its query; other actions and confirm give none', () => {
  assertEquals(peekAll(['{"say":"我查一下","actions":[{"type":"find_place","stop":"","route":"","destination":"","origin":"","time":"","then":"","query":"永康牛肉麵、老王牛肉麵"}]}']),
    [['永康牛肉麵', '老王牛肉麵']]);
  assertEquals(peekAll(['{"say":"好","actions":[{"type":"show_route","stop":"","route":"307","destination":"板橋"}]}']), [[]]);
  assertEquals(peekAll(['{"say":"要出發嗎？","actions":[],"confirm":{"type":"plan_trip",' + empty + '"destination":"板橋","origin":""}}']), [[]]);
});

Deno.test('a reply without say yields nothing', () => {
  assertEquals(readAll(['{"actions":[]}']), ['']);
});

Deno.test('a streamed Claude turn hands over the words before the reply', async () => {
  const none = { type: 'none', stop: '', route: '', destination: '', origin: '', time: '', mode: 'any', preference: 'balanced', avoid: { bus: false, metro: false, bike: false, routes: [] }, option: 0 };
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

Deno.test('a web lookup speaks only the answer after the results, with its sources', async () => {
  const citation = { type: 'web_search_result_location', url: 'https://www.npm.gov.tw/visit', title: '國立故宮博物院｜參觀資訊', cited_text: '開放時間：週二至週日 09:00–17:00', encrypted_index: 'x' };
  const events = [
    { type: 'message_start', message: { id: 'msg_web', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', content: [], stop_reason: null, usage: { input_tokens: 900, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '讓我搜尋。' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'content_block_start', index: 1, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"query":"故宮 開放時間"}' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'content_block_start', index: 2, content_block: { type: 'web_search_tool_result', tool_use_id: 'srvtoolu_1', content: [{ type: 'web_search_result', url: citation.url, title: citation.title, encrypted_content: 'x', page_age: null }] } },
    { type: 'content_block_stop', index: 2 },
    { type: 'content_block_start', index: 3, content_block: { type: 'text', text: '', citations: [] } },
    { type: 'content_block_delta', index: 3, delta: { type: 'citations_delta', citation } },
    { type: 'content_block_delta', index: 3, delta: { type: 'text_delta', text: '故宮週二到週日開放，' } },
    { type: 'content_block_delta', index: 3, delta: { type: 'text_delta', text: '到 17:00。' } },
    { type: 'content_block_stop', index: 3 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 60 } },
    { type: 'message_stop' },
  ];
  let tools: unknown;
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    tools = (await request.json()).tools;
    const body = events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
    return new Response(body, { headers: { 'Content-Type': 'text/event-stream' } });
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    const words: string[] = [];
    const found = await searchWeb('test-key', '乘客問：故宮今天開到幾點', (text) => words.push(text));
    assert('say' in found);
    assertEquals(words.join(''), '故宮週二到週日開放，到 17:00。', 'nothing said before the results');
    assertEquals(found.say, '故宮週二到週日開放，到 17:00。');
    assertEquals(found.sources, [{ title: citation.title, url: citation.url }]);
    assertEquals(found.quoted, [citation.cited_text]);
    assertEquals((tools as { type: string; max_uses: number }[])[0].type, 'web_search_20250305');
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
});

Deno.test('a web answer without citations names the pages the search found', async () => {
  const citation = { type: 'web_search_result_location', url: 'https://www.npm.gov.tw/visit', title: '國立故宮博物院｜參觀資訊', cited_text: '開放時間：週二至週日 09:00–17:00', encrypted_index: 'x' };
  const events = [
    { type: 'message_start', message: { id: 'msg_web', type: 'message', role: 'assistant', model: 'claude-haiku-5-5', content: [], stop_reason: null, usage: { input_tokens: 900, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } },
    { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: '讓我搜尋。' } },
    { type: 'content_block_stop', index: 0 },
    { type: 'content_block_start', index: 1, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } },
    { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"query":"故宮 開放時間"}' } },
    { type: 'content_block_stop', index: 1 },
    { type: 'content_block_start', index: 2, content_block: { type: 'web_search_tool_result', tool_use_id: 'srvtoolu_1', content: [{ type: 'web_search_result', url: citation.url, title: citation.title, encrypted_content: 'x', page_age: null }] } },
    { type: 'content_block_stop', index: 2 },
    { type: 'content_block_start', index: 3, content_block: { type: 'text', text: '', citations: [] } },
    { type: 'content_block_delta', index: 3, delta: { type: 'text_delta', text: '故宮週二到週日開放，' } },
    { type: 'content_block_delta', index: 3, delta: { type: 'text_delta', text: '到 17:00。' } },
    { type: 'content_block_stop', index: 3 },
    { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage: { output_tokens: 60 } },
    { type: 'message_stop' },
  ];
  let tools: unknown;
  const server = Deno.serve({ port: 0, onListen() {} }, async (request) => {
    tools = (await request.json()).tools;
    const body = events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('');
    return new Response(body, { headers: { 'Content-Type': 'text/event-stream' } });
  });
  Deno.env.set('ANTHROPIC_BASE_URL', `http://localhost:${server.addr.port}`);
  try {
    const words: string[] = [];
    const found = await searchWeb('test-key', '乘客問：故宮今天開到幾點', (text) => words.push(text));
    assert('say' in found);
    assertEquals(words.join(''), '故宮週二到週日開放，到 17:00。', 'nothing said before the results');
    assertEquals(found.say, '故宮週二到週日開放，到 17:00。');
    assertEquals(found.sources, [{ title: citation.title, url: citation.url }]);
    assertEquals(found.quoted, []);
    assertEquals((tools as { type: string; max_uses: number }[])[0].type, 'web_search_20250305');
  } finally {
    Deno.env.delete('ANTHROPIC_BASE_URL');
    await server.shutdown();
  }
});
