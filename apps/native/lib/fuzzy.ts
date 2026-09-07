/** Same ranking the line-REPL `/model` picker uses (`src/pickers.zig`):
 * prefix beats substring beats subsequence; separators fold so "5.6 sol"
 * hits `gpt-5.6-sol`. Higher is better; `null` is no match. */

const SEPS = new Set(["-", "_", " ", ".", "/"]);

function foldSeps(s: string): string {
  let out = "";
  for (const ch of s) {
    if (SEPS.has(ch)) continue;
    out += ch.toLowerCase();
  }
  return out;
}

function indexOfIgnoreCase(hay: string, needle: string): number {
  if (needle.length === 0) return 0;
  if (needle.length > hay.length) return -1;
  const h = hay.toLowerCase();
  const n = needle.toLowerCase();
  return h.indexOf(n);
}

function startsWithIgnoreCase(hay: string, needle: string): boolean {
  return hay.length >= needle.length && hay.slice(0, needle.length).toLowerCase() === needle.toLowerCase();
}

/** fzf-style: every char of `needle` appears in `hay` in order, gaps allowed. */
export function fuzzySubseq(hay: string, needle: string): boolean {
  if (needle.length === 0) return true;
  const h = hay.toLowerCase();
  const n = needle.toLowerCase();
  let ni = 0;
  for (let i = 0; i < h.length; i += 1) {
    if (h[i] === n[ni]) {
      ni += 1;
      if (ni === n.length) return true;
    }
  }
  return false;
}

function scoreFolded(hay: string, needle: string): number | null {
  if (needle.length === 0) return 0;
  if (needle.length > hay.length) return null;
  const lenPen = Math.min(hay.length, 200);
  const slash = hay.lastIndexOf("/");
  const base = slash >= 0 ? slash + 1 : 0;
  if (startsWithIgnoreCase(hay.slice(base), needle) || startsWithIgnoreCase(hay, needle)) {
    return 300_000 - lenPen;
  }
  const pos = indexOfIgnoreCase(hay, needle);
  if (pos >= 0) return 200_000 - Math.min(pos, 1000) * 10 - lenPen;
  if (fuzzySubseq(hay, needle)) return 100_000 - lenPen;
  return null;
}

/** Rank a fuzzy match. Prefix > substring > subsequence. Empty needle is 0. */
export function fuzzyScore(hay: string, needle: string): number | null {
  if (needle.length === 0) return 0;
  const direct = scoreFolded(hay, needle);
  if (direct != null) return direct;
  return scoreFolded(foldSeps(hay), foldSeps(needle));
}
