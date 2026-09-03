export type QueuedPrompt = { id: number; text: string };

export function enqueuePrompt(list: QueuedPrompt[], text: string, id: number): QueuedPrompt[] {
  const trimmed = text.trim();
  if (!trimmed) return list;
  return [...list, { id, text: trimmed }];
}

export function dropQueuedPrompt(list: QueuedPrompt[], id: number): QueuedPrompt[] {
  return list.filter((item) => item.id !== id);
}

export function shiftQueuedPrompt(list: QueuedPrompt[]): {
  next: QueuedPrompt | undefined;
  rest: QueuedPrompt[];
} {
  if (list.length === 0) return { next: undefined, rest: list };
  const [next, ...rest] = list;
  return { next, rest };
}
