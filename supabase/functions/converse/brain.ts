// Who answers a turn: Claude with the reply schema enforced, or Groq in JSON mode when Claude cannot.
import { claudeClient, claudeModel, describe } from '../_shared/claude.ts';
import { readReply, REPLY_SCHEMA, type Reply, SYSTEM_PROMPT } from './reply.ts';

/// The phone waits about eight seconds for a turn; Claude gets most of it, leaving time for Groq.
const CLAUDE_TIMEOUT_MS = 4500;
const GROQ_TIMEOUT_MS = 3000;
const GROQ_MODEL = 'openai/gpt-oss-120b';

export type Answer = { reply: Reply; model: string } | { failure: string };

export async function askClaude(apiKey: string, message: string): Promise<Answer> {
  try {
    const response = await claudeClient(apiKey, CLAUDE_TIMEOUT_MS).messages.create({
      model: claudeModel(),
      max_tokens: 600,
      // The same system prompt every turn, so it can be cached; the turn itself goes last.
      system: [{ type: 'text', text: SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } }],
      messages: [{ role: 'user', content: message }],
      // A short spoken answer inside the phone's wait: no extended thinking, low effort, and the
      // reply schema enforced so nothing but the reply comes back.
      thinking: { type: 'disabled' },
      output_config: { effort: 'low', format: { type: 'json_schema', schema: REPLY_SCHEMA } },
    });
    if (stopped(response.stop_reason)) return { failure: `stopped ${response.stop_reason}` };
    const text = response.content.flatMap((block) => block.type === 'text' ? [block.text] : []).join('');
    const reply = readReply(parse(text));
    return reply ? { reply, model: response.model } : { failure: 'unusable reply' };
  } catch (error) {
    const failure = describe(error);
    console.error('claude failed', failure);
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
