// Claude for online understanding, the first choice before Groq.
import Anthropic from '@anthropic-ai/sdk';

/// The app gives up after about five seconds, so Claude gets less, leaving time for Groq.
const CLAUDE_TIMEOUT_MS = 3000;

/// The same request answered by Claude, shaped like Groq's reply so the app reads both alike. Without an
/// answer (Claude failed, declined, ran out of room or answered without JSON) `failure` says why, in a few
/// words safe to show, and the caller asks Groq.
export async function askClaude(apiKey: string, chat: Record<string, unknown>):
  Promise<{ answer: Record<string, unknown> | null; failure?: string }> {
  const messages = chat.messages as Array<{ role: string; content: string }>;
  const system = messages.filter((message) => message.role === 'system').map((message) => message.content);
  const user = messages.filter((message) => message.role === 'user')
    .map((message): Anthropic.MessageParam => ({ role: 'user', content: message.content }));
  if (user.length === 0) return { answer: null, failure: 'no user message' };
  try {
    // A key made outside a workspace must name one on every request.
    const workspace = Deno.env.get('ANTHROPIC_WORKSPACE_ID');
    const client = new Anthropic({
      apiKey, maxRetries: 0, timeout: CLAUDE_TIMEOUT_MS,
      defaultHeaders: workspace ? { 'anthropic-workspace-id': workspace } : undefined,
    });
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
      return { answer: null, failure: `stopped ${message.stop_reason}` };
    }
    const text = message.content.flatMap((block) => block.type === 'text' ? [block.text] : []).join('');
    if (!text.includes('{')) return { answer: null, failure: 'no JSON' };
    return { answer: {
      id: message.id,
      model: message.model,
      choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }],
      usage: { prompt_tokens: message.usage.input_tokens, completion_tokens: message.usage.output_tokens },
    } };
  } catch (error) {
    const failure = describe(error);
    console.error('claude failed', failure);
    return { answer: null, failure };
  }
}

/// Status, error type and the start of Anthropic's message (for example a used-up credit balance or an
/// unknown model). Never the key or the request.
function describe(error: unknown): string {
  if (error instanceof Anthropic.APIError) {
    const body = error.error as { error?: { type?: string; message?: string } } | undefined;
    const detail = [body?.error?.type, body?.error?.message?.slice(0, 100)].filter(Boolean).join(': ');
    return [String(error.status ?? ''), error.constructor.name, detail].filter(Boolean).join(' ');
  }
  return error instanceof Error ? `${error.constructor.name}: ${error.message.slice(0, 100)}` : String(error);
}
