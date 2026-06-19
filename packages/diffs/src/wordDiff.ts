import type { DiffSegment } from "./types";

/** Split a line into word-ish tokens (runs of word chars, whitespace, or single symbols). */
function splitTokens(text: string): string[] {
  return text.match(/[A-Za-z0-9_]+|\s+|[^A-Za-z0-9_\s]/g) ?? [];
}

/**
 * Compute intra-line word segments for a paired deletion/addition.
 * Uses a standard LCS so unchanged runs are shared and only the true edits
 * are marked. Returns segments for the "before" (removed) and "after" (added) sides.
 */
export function diffWords(before: string, after: string): {
  before: DiffSegment[];
  after: DiffSegment[];
} {
  const a = splitTokens(before);
  const b = splitTokens(after);
  const n = a.length;
  const m = b.length;

  // The LCS table is O(n·m) in time and memory. A single long minified/bundled
  // line pair (tens of thousands of symbols each) would allocate billions of
  // cells and hang/OOM the tab — and this runs synchronously during render.
  // Bail out to a single removed/added segment when the pairing is too large;
  // the line still renders, just without intra-line word highlighting.
  const LCS_CELL_BUDGET = 200_000;
  if (n * m > LCS_CELL_BUDGET) {
    return {
      before: [{ kind: "removed", value: before }],
      after: [{ kind: "added", value: after }],
    };
  }

  // LCS table.
  const lcs: number[][] = Array.from({ length: n + 1 }, () => new Array<number>(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      lcs[i]![j] = a[i] === b[j]
        ? lcs[i + 1]![j + 1]! + 1
        : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!);
    }
  }

  const beforeSegs: DiffSegment[] = [];
  const afterSegs: DiffSegment[] = [];
  const pushSeg = (segs: DiffSegment[], kind: DiffSegment["kind"], value: string) => {
    const last = segs[segs.length - 1];
    if (last != null && last.kind === kind) {
      last.value += value;
    } else {
      segs.push({ kind, value });
    }
  };

  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      pushSeg(beforeSegs, "same", a[i]!);
      pushSeg(afterSegs, "same", b[j]!);
      i += 1;
      j += 1;
    } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!) {
      pushSeg(beforeSegs, "removed", a[i]!);
      i += 1;
    } else {
      pushSeg(afterSegs, "added", b[j]!);
      j += 1;
    }
  }
  while (i < n) {
    pushSeg(beforeSegs, "removed", a[i]!);
    i += 1;
  }
  while (j < m) {
    pushSeg(afterSegs, "added", b[j]!);
    j += 1;
  }

  return { before: beforeSegs, after: afterSegs };
}
