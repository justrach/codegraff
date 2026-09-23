/** Codegraff extension, not an ACP v1 standard usage field. Counts cover this connection, including after loading historical messages. */
export type AcpUsage = {
  usageComplete: boolean; costComplete: boolean; costUsd: number | null; knownCostUsd: number;
  input: number; cached: number; written: number; output: number; calls: number;
  missing: number; failed: number; subscription: number; unpriced: number;
};
export function parseAcpUsage(value: Record<string, unknown>): AcpUsage | undefined {
  const names = ['input_tokens', 'cache_read_tokens', 'cache_write_tokens', 'output_tokens', 'api_calls', 'missing_usage_calls',
    'unreported_failed_attempts', 'subscription_calls', 'unpriced_calls'] as const;
  if (value.scope !== 'connection' || typeof value.usage_complete !== 'boolean' || typeof value.cost_complete !== 'boolean') return;
  if (names.some(k => !Number.isSafeInteger(value[k]) || (value[k] as number) < 0)) return;
  if (typeof value.known_cost_usd !== 'number' || !Number.isFinite(value.known_cost_usd) || value.known_cost_usd < 0) return;
  const [input, cached, written, output, calls, missing, failed, subscription, unpriced] = names.map(k => value[k] as number);
  if (cached + written > input) return;
  const usageComplete = value.usage_complete && missing === 0 && failed === 0;
  const costComplete = value.cost_complete && usageComplete && subscription === 0 && unpriced === 0;
  const cost = value.cost_usd;
  if (costComplete && (typeof cost !== 'number' || !Number.isFinite(cost) || cost < 0)) return;
  return { usageComplete, costComplete, costUsd: costComplete ? cost as number : null,
    knownCostUsd: value.known_cost_usd, input, cached, written, output, calls, missing, failed, subscription, unpriced };
}
export function usageCaption(usage: AcpUsage): string {
  const amount = usage.costComplete ? `$${usage.costUsd!.toFixed(4)}` : 'Total cost unknown';
  const known = `${usage.input.toLocaleString('en-US')} input · ${usage.output.toLocaleString('en-US')} output tokens · ${usage.cached.toLocaleString('en-US')} cached read · ${usage.written.toLocaleString('en-US')} cache write tokens`;
  const notes = [usage.failed ? `${usage.failed} failed attempt(s) without usage` : '',
    usage.missing ? `${usage.missing} completed call(s) missing usage` : '',
    usage.subscription ? 'subscription billing' : '', usage.unpriced ? 'unpriced calls' : ''].filter(Boolean);
  const subtotal = !usage.costComplete && usage.knownCostUsd > 0 ? ` · known metered subtotal $${usage.knownCostUsd.toFixed(4)}` : '';
  return `Usage since connection: ${amount}${subtotal} · ${usage.usageComplete ? known : `known subtotal ${known}; total tokens unknown`}${notes.length ? ` · ${notes.join(' · ')}` : ''}`;
}

/** Normalize our negotiated wire extension into a client-only reducer event. */
export function usageUpdate(line: unknown, sessionId: string): ({ sessionUpdate: 'gui_usage' } & Record<string, unknown>) | undefined {
  if (!line || typeof line !== 'object') return;
  const message = line as { method?: unknown; params?: { sessionId?: unknown; usage?: unknown } };
  if (message.method !== '_codegraff/usage' || message.params?.sessionId !== sessionId) return;
  const usage = message.params.usage;
  if (!usage || typeof usage !== 'object' || Array.isArray(usage)) return;
  return { ...usage, sessionUpdate: 'gui_usage' };
}
