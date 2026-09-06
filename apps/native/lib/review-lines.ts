export type ReviewLine = { kind: "hunk" | "add" | "remove" | "context"; text: string; old?: number; next?: number };
export function reviewLines(diff: string): ReviewLine[] {
  let old = 0, next = 0, inHunk = false;
  const rows: ReviewLine[] = [];
  for (const line of diff.split("\n")) {
    const hunk = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)/.exec(line);
    if (hunk) {
      old = Number(hunk[1]); next = Number(hunk[2]); inHunk = true;
      rows.push({ kind: "hunk", text: hunk[3].trim(), old, next }); continue;
    }
    if (line.startsWith("diff --git")) inHunk = false;
    if (!inHunk || !/^[ +\-]/.test(line)) continue;
    if (line[0] === "+") rows.push({ kind: "add", text: line.slice(1), next: next++ });
    else if (line[0] === "-") rows.push({ kind: "remove", text: line.slice(1), old: old++ });
    else rows.push({ kind: "context", text: line.slice(1), old: old++, next: next++ });
  }
  return rows;
}
