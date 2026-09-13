import type { Msg } from '@/components/site/harness-types';

const MESSAGE_LIMIT = 80;
const CHARACTER_LIMIT = 48 * 1024;
/** Bound initial DOM work by content as well as message count. History stays intact. */
export function transcriptPageStart(messages: readonly Msg[], end = messages.length): number {
  let start = end, characters = 0;
  while (start > 0 && end - start < MESSAGE_LIMIT) {
    const message = messages[start - 1];
    const size = message.role === 'user' ? message.text.length : message.turn.text.length +
      (message.turn.reasoning?.length ?? 0) + message.turn.tools.reduce((sum, tool) => sum + (tool.detail?.length ?? 0), 0);
    if (start < end && characters + size > CHARACTER_LIMIT) break;
    characters += size; start--;
  }
  // Keep the newest request beside its reply even when one reply alone is large.
  if (start > 0 && messages[start]?.role === 'assistant' && messages[start - 1]?.role === 'user') start--;
  return start;
}
