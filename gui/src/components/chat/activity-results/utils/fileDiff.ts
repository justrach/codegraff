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

function parseOptionalLineNumber(value: string): number | null {
  const trimmedValue = value.trim();
  if (trimmedValue.length === 0) {
    return null;
  }

  const lineNumber = Number.parseInt(trimmedValue, 10);
  return Number.isFinite(lineNumber) ? lineNumber : null;
}

function parseExcerptDiffLine(line: string): ParsedExcerptDiffLine | null {
  const separatorIndex = line.indexOf("|");
  if (separatorIndex < 0) {
    return null;
  }

  const gutter = line.slice(0, separatorIndex);
  const contentWithMarker = line.slice(separatorIndex + 1);
  const gutterMatch = gutter.match(/^\s*(\d*)\s*(\d*)\s*$/);
  if (gutterMatch == null) {
    return null;
  }

  const beforeLineNumber = parseOptionalLineNumber(gutterMatch[1] ?? "");
  const afterLineNumber = parseOptionalLineNumber(gutterMatch[2] ?? "");
  const marker = contentWithMarker[0];
  const kind =
    marker === "+"
      ? "addition"
      : marker === "-"
        ? "deletion"
        : "context";
  const text = kind === "context" ? contentWithMarker : contentWithMarker.slice(1);

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
  const parsedLines = patch
    .split("\n")
    .map((line) => parseExcerptDiffLine(line));

  if (parsedLines.length === 0 || parsedLines.some((line) => line == null)) {
    return null;
  }

  return parsedLines.filter(
    (line): line is ParsedExcerptDiffLine => line != null,
  );
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
  const beforeLines = lines.filter((line) => line.kind !== "addition");
  const afterLines = lines.filter((line) => line.kind !== "deletion");
  const beforeCount = beforeLines.length;
  const afterCount = afterLines.length;
  const beforeStart = findHunkStart(lines, "beforeLineNumber", beforeCount);
  const afterStart = findHunkStart(lines, "afterLineNumber", afterCount);
  const patchLines = lines.map((line) => {
    switch (line.kind) {
      case "context":
        return ` ${line.text}`;
      case "addition":
        return `+${line.text}`;
      case "deletion":
        return `-${line.text}`;
    }
  });

  const headerLines = [
    `diff --git a/${normalizedPath} b/${normalizedPath}`,
    ...(beforeCount === 0
      ? ["new file mode 100644"]
      : afterCount === 0
        ? ["deleted file mode 100644"]
        : []),
    `--- ${beforeCount === 0 ? "/dev/null" : `a/${normalizedPath}`}`,
    `+++ ${afterCount === 0 ? "/dev/null" : `b/${normalizedPath}`}`,
    `@@ -${beforeStart},${beforeCount} +${afterStart},${afterCount} @@`,
  ];

  return [...headerLines, ...patchLines].join("\n");
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
