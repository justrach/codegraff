import type { DiffHunk, DiffLine, DiffStats, FileDiff, ParsedPatch } from "./types";

const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

function stripPrefix(rawPath: string): string {
  // Drop the leading a/ or b/ that git adds; keep /dev/null as-is.
  if (rawPath === "/dev/null") {
    return rawPath;
  }
  if (rawPath.startsWith("a/") || rawPath.startsWith("b/")) {
    return rawPath.slice(2);
  }
  return rawPath;
}

function emptyFile(): FileDiff {
  return {
    oldPath: null,
    newPath: null,
    path: "",
    isNew: false,
    isDeleted: false,
    isRename: false,
    isBinary: false,
    hunks: [],
    stats: { additions: 0, deletions: 0 },
  };
}

function finalizeFile(file: FileDiff): FileDiff {
  const display = file.newPath && file.newPath !== "/dev/null"
    ? file.newPath
    : (file.oldPath && file.oldPath !== "/dev/null" ? file.oldPath : "");
  return { ...file, path: display };
}

/**
 * Parse a git-style unified diff (one or more files) into a structured model.
 * Tolerant of partial/synthetic patches: unknown lines are ignored rather than thrown.
 */
export function parsePatch(patch: string): ParsedPatch {
  const files: FileDiff[] = [];
  const lines = patch.split("\n");

  let current: FileDiff | null = null;
  let currentHunk: DiffHunk | null = null;
  let beforeLine = 0;
  let afterLine = 0;

  const pushFile = () => {
    if (current != null) {
      files.push(finalizeFile(current));
    }
  };

  for (const line of lines) {
    if (line.startsWith("diff --git ")) {
      pushFile();
      current = emptyFile();
      currentHunk = null;
      const match = line.match(/^diff --git (\S+) (\S+)/);
      if (match) {
        current.oldPath = stripPrefix(match[1]!);
        current.newPath = stripPrefix(match[2]!);
      }
      continue;
    }

    if (current == null) {
      // Allow a bare hunk with no `diff --git` header.
      if (line.startsWith("@@")) {
        current = emptyFile();
      } else {
        continue;
      }
    }

    if (line.startsWith("new file mode")) {
      current.isNew = true;
      continue;
    }
    if (line.startsWith("deleted file mode")) {
      current.isDeleted = true;
      continue;
    }
    if (line.startsWith("rename from ") || line.startsWith("rename to ")) {
      current.isRename = true;
      continue;
    }
    if (line.startsWith("Binary files") || line.startsWith("GIT binary patch")) {
      current.isBinary = true;
      continue;
    }
    if (line.startsWith("--- ")) {
      current.oldPath = stripPrefix(line.slice(4).trim());
      continue;
    }
    if (line.startsWith("+++ ")) {
      current.newPath = stripPrefix(line.slice(4).trim());
      continue;
    }
    if (line.startsWith("index ") || line.startsWith("old mode") || line.startsWith("new mode") || line.startsWith("similarity index")) {
      continue;
    }

    const hunkMatch = line.match(HUNK_HEADER);
    if (hunkMatch) {
      const beforeStart = Number.parseInt(hunkMatch[1]!, 10);
      const beforeCount = hunkMatch[2] != null ? Number.parseInt(hunkMatch[2], 10) : 1;
      const afterStart = Number.parseInt(hunkMatch[3]!, 10);
      const afterCount = hunkMatch[4] != null ? Number.parseInt(hunkMatch[4], 10) : 1;
      currentHunk = {
        header: line,
        beforeStart,
        beforeCount,
        afterStart,
        afterCount,
        lines: [],
      };
      current.hunks.push(currentHunk);
      beforeLine = beforeStart;
      afterLine = afterStart;
      continue;
    }

    if (currentHunk == null) {
      continue;
    }

    // "\ No newline at end of file" — metadata, skip.
    if (line.startsWith("\\")) {
      continue;
    }

    const marker = line[0];
    const text = line.slice(1);
    let diffLine: DiffLine | null = null;
    if (marker === "+") {
      diffLine = { kind: "addition", beforeLineNumber: null, afterLineNumber: afterLine, text };
      afterLine += 1;
      current.stats.additions += 1;
    } else if (marker === "-") {
      diffLine = { kind: "deletion", beforeLineNumber: beforeLine, afterLineNumber: null, text };
      beforeLine += 1;
      current.stats.deletions += 1;
    } else if (marker === " ") {
      diffLine = { kind: "context", beforeLineNumber: beforeLine, afterLineNumber: afterLine, text };
      beforeLine += 1;
      afterLine += 1;
    }
    // A zero-length line is the trailing-newline split artifact, not content — skip it.

    if (diffLine != null) {
      currentHunk.lines.push(diffLine);
    }
  }

  pushFile();

  const stats: DiffStats = files.reduce(
    (acc, file) => ({
      additions: acc.additions + file.stats.additions,
      deletions: acc.deletions + file.stats.deletions,
    }),
    { additions: 0, deletions: 0 },
  );

  return { files, stats };
}

/** Total +/- counts for a git patch. Returns null for non-git input. */
export function getPatchStats(patch: string): DiffStats | null {
  if (!patch.startsWith("diff --git ")) {
    return null;
  }
  return parsePatch(patch).stats;
}
