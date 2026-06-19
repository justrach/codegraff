import type { ParsedExcerptDiffLine } from "../types/fileDiff";

export function getFileDiffDisplayName(path: string): string {
  const normalizedPath = path.replace(/\\/g, "/");
  const segments = normalizedPath.split("/");
  return segments.at(-1) || path || "Diff";
}

export function getFileDiffDisplayPath(
  path: string,
  workspacePath: string | null,
): string {
  const normalizedPath = path.replace(/\\/g, "/");
  const normalizedWorkspacePath = workspacePath?.replace(/\\/g, "/");

  if (
    normalizedWorkspacePath != null &&
    normalizedPath.startsWith(normalizedWorkspacePath)
  ) {
    const trimmed = normalizedPath
      .slice(normalizedWorkspacePath.length)
      .replace(/^\/+/, "");
    return trimmed.length > 0 ? trimmed : ".";
  }

  return normalizedPath;
}

function parseExcerptDiffLine(line: string): ParsedExcerptDiffLine | null {
  const separatorIndex = line.indexOf("|");
  if (separatorIndex < 0) {
    return null;
  }

  const gutter = line.slice(0, separatorIndex);
  // The gutter holds only the before/after line-number columns. Anything else
  // (ellipsis gap markers, stray prose) is not an excerpt line.
  if (!/^[\d\s]*$/.test(gutter)) {
    return null;
  }

  const numbers = (gutter.match(/\d+/g) ?? []).map((value) =>
    Number.parseInt(value, 10),
  );
  const contentWithMarker = line.slice(separatorIndex + 1);
  const marker = contentWithMarker[0];
  const kind =
    marker === "+"
      ? "addition"
      : marker === "-"
        ? "deletion"
        : "context";
  const text = kind === "context" ? contentWithMarker : contentWithMarker.slice(1);

  // Assign the gutter number(s) by kind — a single column is ambiguous after
  // whitespace collapses, but an addition only carries an "after" number, a
  // deletion only a "before", and context carries both.
  let beforeLineNumber: number | null = null;
  let afterLineNumber: number | null = null;
  if (kind === "addition") {
    afterLineNumber = numbers.at(-1) ?? null;
  } else if (kind === "deletion") {
    beforeLineNumber = numbers[0] ?? null;
  } else {
    beforeLineNumber = numbers[0] ?? null;
    afterLineNumber = numbers[1] ?? numbers[0] ?? null;
  }

  if (
    beforeLineNumber == null &&
    afterLineNumber == null &&
    kind === "context"
  ) {
    return null;
  }

  return {
    beforeLineNumber,
    afterLineNumber,
    kind,
    text,
  };
}

function parseExcerptDiffLines(patch: string): ParsedExcerptDiffLine[] | null {
  // Drop lines we don't recognize (gap/ellipsis markers, blank separators between
  // non-contiguous edit regions) instead of discarding the whole excerpt — a single
  // unparseable line must not hide every real edit. Require at least one recognizable
  // line so a pure byte-summary ("wrote N bytes …") still routes to the disk/placeholder
  // path rather than being mistaken for a diff.
  const parsedLines = patch
    .split("\n")
    .map((line) => parseExcerptDiffLine(line))
    .filter((line): line is ParsedExcerptDiffLine => line != null);

  return parsedLines.length === 0 ? null : parsedLines;
}

/**
 * Split parsed excerpt lines into contiguous hunks. The harness can report several
 * disjoint edit regions in one excerpt; emitting them as a single hunk would renumber
 * the gutters wrong across the gaps, so we start a new hunk whenever the next line's
 * explicit before/after line number breaks the running sequence.
 */
function groupExcerptHunks(
  lines: ParsedExcerptDiffLine[],
): ParsedExcerptDiffLine[][] {
  const hunks: ParsedExcerptDiffLine[][] = [];
  let current: ParsedExcerptDiffLine[] | null = null;
  let expectedBefore: number | null = null;
  let expectedAfter: number | null = null;

  for (const line of lines) {
    const breaks =
      current != null &&
      ((line.beforeLineNumber != null &&
        expectedBefore != null &&
        line.beforeLineNumber !== expectedBefore) ||
        (line.afterLineNumber != null &&
          expectedAfter != null &&
          line.afterLineNumber !== expectedAfter));

    if (current == null || breaks) {
      current = [];
      hunks.push(current);
      expectedBefore = null;
      expectedAfter = null;
    }

    current.push(line);

    // A line consumes a "before" slot unless it's an addition, and an "after" slot
    // unless it's a deletion; advance the side(s) it occupies.
    if (line.kind !== "addition") {
      expectedBefore = (line.beforeLineNumber ?? expectedBefore ?? 0) + 1;
    }
    if (line.kind !== "deletion") {
      expectedAfter = (line.afterLineNumber ?? expectedAfter ?? 0) + 1;
    }
  }

  return hunks;
}

function buildExcerptHunk(lines: ParsedExcerptDiffLine[]): string {
  const beforeCount = lines.filter((line) => line.kind !== "addition").length;
  const afterCount = lines.filter((line) => line.kind !== "deletion").length;
  const beforeStart = findHunkStart(lines, "beforeLineNumber", beforeCount);
  const afterStart = findHunkStart(lines, "afterLineNumber", afterCount);
  const body = lines.map((line) => {
    switch (line.kind) {
      case "context":
        return ` ${line.text}`;
      case "addition":
        return `+${line.text}`;
      case "deletion":
        return `-${line.text}`;
    }
  });

  return [
    `@@ -${beforeStart},${beforeCount} +${afterStart},${afterCount} @@`,
    ...body,
  ].join("\n");
}

function findHunkStart(
  lines: ParsedExcerptDiffLine[],
  side: "beforeLineNumber" | "afterLineNumber",
  lineCount: number,
): number {
  if (lineCount === 0) {
    return 0;
  }

  for (const line of lines) {
    const lineNumber = line[side];
    if (lineNumber != null) {
      return lineNumber;
    }
  }

  return 1;
}

function buildSyntheticGitPatch(
  path: string,
  lines: ParsedExcerptDiffLine[],
): string {
  const normalizedPath = path.replace(/\\/g, "/");
  // new/deleted-file markers depend on the whole excerpt, not a single hunk.
  const totalBefore = lines.filter((line) => line.kind !== "addition").length;
  const totalAfter = lines.filter((line) => line.kind !== "deletion").length;

  const headerLines = [
    `diff --git a/${normalizedPath} b/${normalizedPath}`,
    ...(totalBefore === 0
      ? ["new file mode 100644"]
      : totalAfter === 0
        ? ["deleted file mode 100644"]
        : []),
    `--- ${totalBefore === 0 ? "/dev/null" : `a/${normalizedPath}`}`,
    `+++ ${totalAfter === 0 ? "/dev/null" : `b/${normalizedPath}`}`,
  ];

  const hunks = groupExcerptHunks(lines).map(buildExcerptHunk);

  return [...headerLines, ...hunks].join("\n");
}

export function buildRenderableFileDiffPatch(path: string, patch: string): string {
  const normalizedPatch = patch.trim();
  if (normalizedPatch.length === 0 || normalizedPatch.startsWith("diff --git ")) {
    return normalizedPatch;
  }

  const parsedExcerptDiffLines = parseExcerptDiffLines(normalizedPatch);
  if (parsedExcerptDiffLines == null) {
    return normalizedPatch;
  }

  return buildSyntheticGitPatch(path, parsedExcerptDiffLines);
}

/**
 * Builds an all-additions git patch from a file's full contents. Used to render
 * a real diff for create/overwrite operations, which the harness only reports as
 * a "wrote N bytes" summary (no line-level diff). The whole file shows as added.
 */
export function buildAdditionPatchFromContent(path: string, content: string): string {
  const normalizedPath = path.replace(/\\/g, "/");
  const rawLines = content.split("\n");
  // A trailing newline yields a final empty element; drop it so we don't render
  // a phantom blank addition.
  if (rawLines.length > 0 && rawLines[rawLines.length - 1] === "") {
    rawLines.pop();
  }
  const count = rawLines.length;
  const headerLines = [
    `diff --git a/${normalizedPath} b/${normalizedPath}`,
    "new file mode 100644",
    "--- /dev/null",
    `+++ b/${normalizedPath}`,
    `@@ -0,0 +1,${count} @@`,
  ];
  const body = rawLines.map((line) => `+${line}`);
  return [...headerLines, ...body].join("\n");
}

export function getFileDiffPatchStats(
  patch: string,
): { additions: number; deletions: number } | null {
  if (!patch.startsWith("diff --git ")) {
    return null;
  }

  let additions = 0;
  let deletions = 0;

  for (const line of patch.split("\n")) {
    if (
      line.startsWith("diff --git ") ||
      line.startsWith("@@") ||
      line.startsWith("+++") ||
      line.startsWith("---") ||
      line.startsWith("index ") ||
      line.startsWith("new file mode ") ||
      line.startsWith("deleted file mode ")
    ) {
      continue;
    }

    if (line.startsWith("+")) {
      additions += 1;
      continue;
    }

    if (line.startsWith("-")) {
      deletions += 1;
    }
  }

  return { additions, deletions };
}