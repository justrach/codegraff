import type {
  ActivityResultFormat,
  ActivityResultPresentation,
  ActivityResultTone,
} from "../activity-results/types/activityResult";

/**
 * Coarse category for a tool, used to pick an icon/label and a sensible body
 * format. The backend collapses many real tools (webfetch, gh, MCP servers)
 * into `ToolCallDetail.kind: "unknown"`, so for those we fall back to matching
 * the tool's name.
 */
export type ToolCategory = "web" | "github" | "generic";

const WEB_NAME = /fetch|web|http|url|browse|crawl|scrape/i;
const GITHUB_NAME = /github|(^|[_-])gh($|[_-])|gitlab|\bpr\b|pull[_-]?request/i;

/** Classify an `unknown`-kind tool by its name. */
export function classifyUnknownToolName(name: string): ToolCategory {
  if (WEB_NAME.test(name)) {
    return "web";
  }
  if (GITHUB_NAME.test(name)) {
    return "github";
  }
  return "generic";
}

function looksLikeJson(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length < 2) {
    return false;
  }
  const first = trimmed[0];
  const last = trimmed[trimmed.length - 1];
  const bracketed =
    (first === "{" && last === "}") || (first === "[" && last === "]");
  if (!bracketed) {
    return false;
  }
  try {
    JSON.parse(trimmed);
    return true;
  } catch {
    return false;
  }
}

// Cheap structural signal: code tends to use these tokens densely, prose does
// not. Kept conservative so ordinary tool text falls through to prose (which
// wraps and reads fine) rather than being mis-highlighted as code.
const CODE_SIGNAL = /[;{}]|=>|\bfunction\b|\bconst\b|\blet\b|\bimport\b|\bdef\b|\bclass\b|<\/?[a-z][\w-]*>/;

function looksLikeCode(text: string): boolean {
  const lines = text.split("\n");
  if (lines.length < 2) {
    return false;
  }
  const signalLines = lines.filter((line) => CODE_SIGNAL.test(line)).length;
  return signalLines / lines.length >= 0.4;
}

interface DetectFormatInput {
  /** ToolCallDetail.kind of the originating call. */
  detailKind: string;
  /** The originating tool name (used for `unknown` tools). */
  name: string;
  /** Whether the structured result is shell output. */
  isShellOutput: boolean;
  text: string;
}

/** Pick how to render a result body, plus an optional display language. */
export function detectContentFormat({
  detailKind,
  name,
  isShellOutput,
  text,
}: DetectFormatInput): { format: ActivityResultFormat; language?: string } {
  if (isShellOutput || detailKind === "shell") {
    return { format: "terminal" };
  }

  const isWeb =
    detailKind === "fetch" ||
    (detailKind === "unknown" && classifyUnknownToolName(name) === "web");
  if (isWeb) {
    return { format: "prose" };
  }

  if (looksLikeJson(text)) {
    return { format: "code", language: "json" };
  }
  if (looksLikeCode(text)) {
    return { format: "code" };
  }
  return { format: "prose" };
}

const INLINE_MAX_LINES = 3;
const INLINE_MAX_CHARS = 240;

/**
 * Short, non-error prose renders inline (no card chrome). Errors, terminals,
 * code, and longer output keep the full card so they stay scannable.
 */
export function resolvePresentation({
  text,
  tone,
  format,
}: {
  text: string;
  tone: ActivityResultTone;
  format: ActivityResultFormat;
}): ActivityResultPresentation {
  if (tone === "error" || format !== "prose") {
    return "card";
  }
  const lineCount = text.split("\n").length;
  if (lineCount <= INLINE_MAX_LINES && text.length < INLINE_MAX_CHARS) {
    return "inline";
  }
  return "card";
}
