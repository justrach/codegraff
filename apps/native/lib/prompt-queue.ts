export type QueuedPrompt = { id: number; text: string; editing?: true; draft?: string };

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

/** Rewrite one entry in place. The id is the identity the steerer selects by
 *  and the drain shifts by, so an edit never reorders or re-ids the queue. An
 *  edit that leaves nothing drops the entry — the same result as its ✕ — and
 *  an id that is not queued is left alone. */
export function editQueuedPrompt(list: QueuedPrompt[], id: number, text: string): QueuedPrompt[] {
  if (!list.some(item => item.id === id)) return list;
  const trimmed = text.trim();
  if (!trimmed) return dropQueuedPrompt(list, id);
  return list.map(item => {
    if (item.id !== id) return item;
    const { editing: _editing, draft: _draft, ...saved } = item;
    return { ...saved, text: trimmed };
  });
}

/** Hold the entry while its editor is open; cancelling keeps its saved text. */
export function setQueuedPromptEditing(list: QueuedPrompt[], id: number, editing: boolean): QueuedPrompt[] {
  return list.map(item => {
    if (item.id !== id) return item;
    if (editing) return { ...item, editing: true, draft: item.draft ?? item.text };
    const { editing: _editing, draft: _draft, ...saved } = item;
    return saved;
  });
}

export function shiftQueuedPrompt(list: QueuedPrompt[]): {
  next: QueuedPrompt | undefined;
  rest: QueuedPrompt[];
} {
  if (list.length === 0 || list.some(item => item.editing)) return { next: undefined, rest: list };
  const [next, ...rest] = list;
  return { next, rest };
}
