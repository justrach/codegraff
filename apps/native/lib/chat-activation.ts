/** Activation order is independent of tab and split-pane display order. */

export function rememberActivation(history: number[], activeId: number, live: Iterable<number>): number[] {
  const keep = new Set(live);
  return [...history.filter(id => id !== activeId && keep.has(id)), activeId];
}

/** Newest surviving activation, then the existing positional fallback. */
export function focusAfterClose(
  history: number[],
  live: Iterable<number>,
  visible: number[],
  remaining: { id: number }[],
): number | undefined {
  const keep = new Set(live);
  return [...history].reverse().find(id => keep.has(id)) ?? visible[0] ?? remaining.at(-1)?.id;
}
