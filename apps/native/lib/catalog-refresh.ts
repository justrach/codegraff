/** An in-flight focus fetch may have sampled settings before this turn changed
 * them. Wait for it to settle, then request one post-turn snapshot. */
export async function refreshAfterPendingCatalog(
  pending: Promise<unknown> | undefined,
  current: () => boolean,
  refresh: () => Promise<void>,
): Promise<void> {
  if (pending) await pending.catch(() => undefined);
  if (current()) await refresh();
}
