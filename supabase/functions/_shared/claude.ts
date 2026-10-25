// The Anthropic client for the assistant functions.
import Anthropic from '@anthropic-ai/sdk';

export { Anthropic };

/// No retries: each function has a Groq fallback and the app is waiting.
export function claudeClient(apiKey: string, timeout: number): Anthropic {
  // A key made outside a workspace must name one on every request.
  const workspace = Deno.env.get('ANTHROPIC_WORKSPACE_ID');
  return new Anthropic({
    apiKey, maxRetries: 0, timeout,
    defaultHeaders: workspace ? { 'anthropic-workspace-id': workspace } : undefined,
  });
}

export function claudeModel(): string {
  return Deno.env.get('ANTHROPIC_MODEL') || 'claude-haiku-5-5';
}

/// Status, error type and the start of Anthropic's message (for example a used-up credit balance or an
/// unknown model). Never the key or the request.
export function describe(error: unknown): string {
  if (error instanceof Anthropic.APIError) {
    const body = error.error as { error?: { type?: string; message?: string } } | undefined;
    const detail = [body?.error?.type, body?.error?.message?.slice(0, 100)].filter(Boolean).join(': ');
    return [String(error.status ?? ''), error.constructor.name, detail].filter(Boolean).join(' ');
  }
  return error instanceof Error ? `${error.constructor.name}: ${error.message.slice(0, 100)}` : String(error);
}
