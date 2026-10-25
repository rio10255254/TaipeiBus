// Who answers a turn: Claude with the reply schema enforced, or Groq in JSON mode when Claude cannot.
import { Anthropic, claudeClient, claudeModel, describe } from '../_shared/claude.ts';
import { readReply, REPLY_SCHEMA, type Reply, SYSTEM_PROMPT, WEB_PROMPT } from './reply.ts';
import { SayReader } from './say.ts';

/// The phone waits about eight seconds for a turn; Claude gets most of it, leaving time for Groq.
const CLAUDE_TIMEOUT_MS = 4500;
const GROQ_TIMEOUT_MS = 3000;
const GROQ_MODEL = 'openai/gpt-oss-120b';

/// The phone speaks the first sentence as soon as it arrives; if Claude has said nothing by then, Groq
/// still has time to answer.
const FIRST_WORDS_MS = 4500;
const STREAM_TIMEOUT_MS = 8000;

export type Answer = { reply: Reply; model: string } | { failure: string };

function request(message: string) {
  return {
    model: claudeModel(),
    max_tokens: 600,
    // The same system prompt every turn, so it can be cached; the turn itself goes last.
    system: [{ type: 'text' as const, text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' as const } }],
    messages: [{ role: 'user' as const, content: message }],
    // A short spoken answer inside the phone's wait: no extended thinking, low effort, and the
    // reply schema enforced so nothing but the reply comes back.
    thinking: { type: 'disabled' as const },
    output_config: { effort: 'low' as const, format: { type: 'json_schema' as const, schema: REPLY_SCHEMA } },
  };
}

function answer(response: Anthropic.Message): Answer {
  if (stopped(response.stop_reason)) return { failure: `stopped ${response.stop_reason}` };
  const text = response.content.flatMap((block) => block.type === 'text' ? [block.text] : []).join('');
  const reply = readReply(parse(text));
  return reply ? { reply, model: response.model } : { failure: 'unusable reply' };
}

export async function askClaude(apiKey: string, message: string): Promise<Answer> {
  try {
    return answer(await claudeClient(apiKey, CLAUDE_TIMEOUT_MS).messages.create(request(message)));
  } catch (error) {
    const failure = describe(error);
    console.error('claude failed', failure);
    return { failure };
  }
}

/// The same turn, streamed: `onSay` gets the words of `say` as Claude writes them, and `complete` once
/// they are all there, before the actions are written. `spoke` tells the caller whether any words went
/// out before a failure, when a second brain can no longer take over.
export async function streamClaude(apiKey: string, message: string, onSay: (words: string, complete: boolean) => void): Promise<Answer & { spoke: boolean }> {
  const controller = new AbortController();
  let spoke = false;
  const quiet = setTimeout(() => { if (!spoke) controller.abort(); }, FIRST_WORDS_MS);
  try {
    const stream = claudeClient(apiKey, STREAM_TIMEOUT_MS).messages.stream(request(message), { signal: controller.signal });
    const say = new SayReader();
    let complete = false;
    for await (const event of stream) {
      if (event.type !== 'content_block_delta' || event.delta.type !== 'text_delta' || complete) continue;
      const words = say.push(event.delta.text);
      complete = say.complete;
      if (words || complete) {
        spoke ||= words.length > 0;
        onSay(words, complete);
      }
    }
    return { ...answer(await stream.finalMessage()), spoke };
  } catch (error) {
    const failure = controller.signal.aborted && !spoke ? 'no words in time' : describe(error);
    console.error('claude stream failed', failure);
    return { failure, spoke };
  } finally {
    clearTimeout(quiet);
  }
}

/// What a web lookup found: the spoken answer, the pages it came from, and the passages it quoted
/// (the phone checks the answer's times against them).
export type WebAnswer = { say: string; sources: { title: string; url: string }[]; quoted: string[]; model: string } | { failure: string };

const WEB_TIMEOUT_MS = 15000;

/// Answers one question with Claude's web search, at most two searches. `onWords` gets the answer as it
/// is written; anything Claude writes before the results arrive is not part of the answer.
export async function searchWeb(apiKey: string, question: string, onWords: (words: string) => void): Promise<WebAnswer> {
  try {
    const stream = claudeClient(apiKey, WEB_TIMEOUT_MS).messages.stream({
      model: claudeModel(),
      max_tokens: 800,
      system: [{ type: 'text', text: WEB_PROMPT, cache_control: { type: 'ephemeral' } }],
      messages: [{ role: 'user', content: question }],
      thinking: { type: 'disabled' },
      output_config: { effort: 'low' },
      tools: [{
        type: 'web_search_20250305', name: 'web_search', max_uses: 2,
        user_location: { type: 'approximate', city: 'Taipei', region: 'Taipei', country: 'TW', timezone: 'Asia/Taipei' },
      }],
    });
    let searched = false;
    for await (const event of stream) {
      if (event.type === 'content_block_start' && event.content_block.type === 'web_search_tool_result') searched = true;
      if (searched && event.type === 'content_block_delta' && event.delta.type === 'text_delta') onWords(event.delta.text);
    }
    const message = await stream.finalMessage();
    if (stopped(message.stop_reason)) return { failure: `stopped ${message.stop_reason}` };
    const sources = new Map<string, string>();
    const quoted: string[] = [];
    let say = '';
    let after = false;
    // Pages the search returned, in order: the sources when the answer cites none itself.
    const results: { title: string; url: string }[] = [];
    for (const block of message.content) {
      if (block.type === 'web_search_tool_result') {
        after = true;
        if (Array.isArray(block.content)) for (const result of block.content) results.push({ title: result.title, url: result.url });
      }
      if (block.type !== 'text' || !after) continue;
      say += block.text;
      for (const citation of block.citations ?? []) {
        if (citation.type !== 'web_search_result_location') continue;
        sources.set(citation.url, citation.title ?? citation.url);
        if (citation.cited_text) quoted.push(citation.cited_text.slice(0, 500));
      }
    }
    say = say.trim();
    if (!after || !say) return { failure: 'no answer from the web' };
    return {
      say, model: message.model, quoted: quoted.slice(0, 8),
      sources: (sources.size ? [...sources].map(([url, title]) => ({ title, url })) : results)
        .slice(0, 3).map((source) => ({ title: (source.title || source.url).slice(0, 80), url: source.url })),
    };
  } catch (error) {
    const failure = describe(error);
    console.error('web search failed', failure);
    return { failure };
  }
}

export async function askGroq(apiKey: string, message: string): Promise<Answer> {
  try {
    const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: { Authorization: `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(GROQ_TIMEOUT_MS),
      body: JSON.stringify({
        model: GROQ_MODEL, temperature: 0, max_completion_tokens: 900, reasoning_effort: 'low', include_reasoning: false,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: `${SYSTEM_PROMPT}\n\n只輸出符合這個 JSON Schema 的物件：${JSON.stringify(REPLY_SCHEMA)}` },
          { role: 'user', content: message },
        ],
      }),
    });
    if (!response.ok) return { failure: `groq ${response.status}` };
    const body = await response.json();
    const reply = readReply(parse(body?.choices?.[0]?.message?.content ?? ''));
    return reply ? { reply, model: String(body?.model ?? GROQ_MODEL) } : { failure: 'groq unusable reply' };
  } catch (error) {
    return { failure: `groq ${error instanceof Error ? error.name : String(error)}` };
  }
}

function stopped(reason: string | null): boolean {
  return reason === 'refusal' || reason === 'max_tokens';
}

/// The JSON object in a reply, even if a model wraps it in text.
function parse(text: string): unknown {
  const open = text.indexOf('{'), close = text.lastIndexOf('}');
  if (open < 0 || close <= open) return null;
  try {
    return JSON.parse(text.slice(open, close + 1));
  } catch {
    return null;
  }
}
