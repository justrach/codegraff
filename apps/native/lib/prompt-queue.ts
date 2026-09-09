export type QueuedPrompt = { id: number; text: string };

export function enqueuePrompt(list: QueuedPrompt[], text: string, id: number): QueuedPrompt[] {
  const trimmed = text.trim();
  if (!trimmed) return list;
  return [...list, { id, text: trimmed }];
}

export function dropQueuedPrompt(list: QueuedPrompt[], id: number): QueuedPrompt[] {
  return list.filter((item) => item.id !== id);
}

/** Move only the selected entry; preserve every other entry's relative order. */
export function prioritizeQueuedPrompt(list: QueuedPrompt[], id: number): QueuedPrompt[] {
  const selected = list.find(item => item.id === id);
  if (!selected || list[0] === selected) return list;
  return [selected, ...list.filter(item => item.id !== id)];
}

export function shiftQueuedPrompt(list: QueuedPrompt[]): {
  next: QueuedPrompt | undefined;
  rest: QueuedPrompt[];
} {
  if (list.length === 0) return { next: undefined, rest: list };
  const [next, ...rest] = list;
  return { next, rest };
}
