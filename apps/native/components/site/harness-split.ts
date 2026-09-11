/** Columns the split view will show at once, the active chat included.
 * Past four, panes are too narrow to read. */
export const MAX_COLUMNS = 4;

export const SPLIT_LIMIT_MESSAGE = "Four panes is the limit so each chat stays readable.";

export function splitLimitReached(visible: number): boolean {
  return visible >= MAX_COLUMNS;
}
