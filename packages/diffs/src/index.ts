export type {
  DiffLine,
  DiffLineKind,
  DiffHunk,
  DiffSegment,
  DiffStats,
  FileDiff,
  ParsedPatch,
} from "./types";
export { parsePatch, getPatchStats } from "./parse";
export { diffWords } from "./wordDiff";
export {
  tokenizeLine,
  languageFromPath,
  type Language,
  type Token,
  type TokenType,
} from "./highlight";
