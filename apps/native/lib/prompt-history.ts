/** Composer prompt history: ArrowUp / ArrowDown in the prompt bar recall
 * earlier prompts the way a shell does. Persisted per browser so a fresh tab
 * (or a reload) still has yesterday's prompts under the cursor. Pure helpers
 * live here so the key rules are testable without a DOM. */

export const HISTORY_KEY = "graff.native.prompt-history";
export const HISTORY_MAX = 200;

/** Append `text` as the newest entry. A prompt already in the list moves to
 * the newest position instead of repeating — stepping through five copies of
 * "continue" is noise — and the list is capped from the oldest end. */
export function pushHistory(list: readonly string[], text: string, max = HISTORY_MAX): string[] {
  const t = text.trim();
  if (!t) return [...list];
  const next = [...list.filter((entry) => entry !== t), t];
  return next.length > max ? next.slice(next.length - max) : next;
}

/** Persisted history plus the open chat's own prompts (a resumed session's
 * transcript is not in this browser's storage), newest last, each prompt once
 * at its most recent position. */
export function mergeHistory(persisted: readonly string[], chatPrompts: readonly string[]): string[] {
  const all = [...persisted, ...chatPrompts];
  const seen = new Set<string>();
  const out: string[] = [];
  for (let i = all.length - 1; i >= 0; i -= 1) {
    const t = all[i].trim();
    if (!t || seen.has(t)) continue;
    seen.add(t);
    out.push(t);
  }
  return out.reverse();
}

/** History cursor: -1 is the live draft, 0 the newest prompt, and so on. */
export function stepHistory(length: number, index: number, dir: "up" | "down"): number {
  if (dir === "up") return Math.min(length - 1, index + 1);
  return Math.max(-1, index - 1);
}

export function entryAt(list: readonly string[], index: number): string | null {
  if (index < 0 || index >= list.length) return null;
  return list[list.length - 1 - index];
}

/** ArrowUp recalls history only from the first line of the draft (or an
 * empty one); ArrowDown steps forward only from the last line. Anywhere else
 * the keys move the caret like they do in any textarea. */
export function historyKeyIntent(draft: string, caret: number, key: string): "up" | "down" | null {
  if (key === "ArrowUp") return draft.slice(0, caret).includes("\n") ? null : "up";
  if (key === "ArrowDown") return draft.slice(caret).includes("\n") ? null : "down";
  return null;
}

type ReadStore = Pick<Storage, "getItem">;
type WriteStore = Pick<Storage, "setItem">;

export function loadHistory(storage: ReadStore | null | undefined): string[] {
  try {
    const raw = storage?.getItem(HISTORY_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((entry): entry is string => typeof entry === "string") : [];
  } catch {
    return [];
  }
}

export function saveHistory(storage: WriteStore | null | undefined, list: readonly string[]): void {
  try {
    storage?.setItem(HISTORY_KEY, JSON.stringify(list.slice(-HISTORY_MAX)));
  } catch {
    // Private mode or a full quota: history is a convenience, never a failure.
  }
}
