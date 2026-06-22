export type DiffLineKind = "context" | "addition" | "deletion";

export interface DiffStats {
  additions: number;
  deletions: number;
}

/** A word-level segment within a single line (used for intra-line "word" diffs). */
export interface DiffSegment {
  kind: "same" | "added" | "removed";
  value: string;
}

export interface DiffLine {
  kind: DiffLineKind;
  beforeLineNumber: number | null;
  afterLineNumber: number | null;
  text: string;
  /** Present when intra-line word diffing has been applied to this line. */
  segments?: DiffSegment[];
}

export interface DiffHunk {
  /** The raw `@@ ... @@` header line. */
  header: string;
  beforeStart: number;
  beforeCount: number;
  afterStart: number;
  afterCount: number;
  lines: DiffLine[];
}

export interface FileDiff {
  oldPath: string | null;
  newPath: string | null;
  /** Display path: newPath ?? oldPath. */
  path: string;
  isNew: boolean;
  isDeleted: boolean;
  isRename: boolean;
  isBinary: boolean;
  hunks: DiffHunk[];
  stats: DiffStats;
}

export interface ParsedPatch {
  files: FileDiff[];
  stats: DiffStats;
}
