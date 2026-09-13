import type { QueuedPrompt } from "./prompt-queue";

/** Settings use the same worker as ordinary prompts. Keep the queued entry
 * until settings finish, then recheck navigation, active turns and edit holds. */
export async function resumeQueuedPrompt(chat: number, options: {
  pending: Set<number>;
  canStart(chat: number): boolean;
  wait(chat: number): Promise<unknown> | undefined;
  take(chat: number): QueuedPrompt | undefined;
  run(chat: number, text: string): void | Promise<void>;
}): Promise<void> {
  if (options.pending.has(chat) || !options.canStart(chat)) return;
  options.pending.add(chat);
  try {
    await options.wait(chat);
    if (!options.canStart(chat)) return;
    const next = options.take(chat);
    if (next) void options.run(chat, next.text);
  } finally {
    options.pending.delete(chat);
  }
}
