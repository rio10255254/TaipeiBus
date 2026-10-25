// Claude for online understanding, the first choice before Groq.
import Anthropic from '@anthropic-ai/sdk';

/// The app gives up after about five seconds, so Claude gets less, leaving time for Groq.
const CLAUDE_TIMEOUT_MS = 3000;

/// The same request answered by Claude, shaped like Groq's reply so the app reads both alike. nil when
/// Claude fails, declines, runs out of room or answers without JSON; the caller then asks Groq.
export async function askClaude(apiKey: string, chat: Record<string, unknown>): Promise<Record<string, unknown> | null> {
  const messages = chat.messages as Array<{ role: string; content: string }>;
  const system = messages.filter((message) => message.role === 'system').map((message) => message.content);
  const user = messages.filter((message) => message.role === 'user')
    .map((message): Anthropic.MessageParam => ({ role: 'user', content: message.content }));
  if (user.length === 0) return null;
  try {
    const client = new Anthropic({ apiKey, maxRetries: 0, timeout: CLAUDE_TIMEOUT_MS });
    const message = await client.messages.create({
      model: Deno.env.get('ANTHROPIC_MODEL') || 'claude-haiku-5-5',
      max_tokens: Number(chat.max_completion_tokens),
      system: [...system, 'Reply with exactly one JSON object and nothing else.'].join('\n\n'),
      messages: user,
      // Short JSON within the app's five seconds: no extended thinking, low effort.
      thinking: { type: 'disabled' },
      output_config: { effort: 'low' },
    });
    if (message.stop_reason === 'refusal' || message.stop_reason === 'max_tokens') {
      console.warn('claude stopped', message.stop_reason);
      return null;
    }
    const text = message.content.flatMap((block) => block.type === 'text' ? [block.text] : []).join('');
    if (!text.includes('{')) return null;
    return {
      id: message.id,
      model: message.model,
      choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
      usage: { prompt_tokens: message.usage.input_tokens, completion_tokens: message.usage.output_tokens },
    };
  } catch (error) {
    const status = error instanceof Anthropic.APIError ? ` ${error.status}` : '';
    console.error(`claude failed${status}`, error instanceof Error ? error.constructor.name : String(error));
    return null;
  }
}
