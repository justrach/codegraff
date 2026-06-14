export type AttachmentKind = "text" | "pdf" | "image";

export interface Attachment {
  id: string;
  path: string;
  name: string;
  ext: string;
  kind: AttachmentKind;
}

const TEXT_EXTS = [
  "md",
  "markdown",
  "txt",
  "text",
  "json",
  "jsonc",
  "csv",
  "tsv",
  "yaml",
  "yml",
  "toml",
  "xml",
  "html",
  "htm",
  "css",
  "scss",
  "less",
  "js",
  "jsx",
  "mjs",
  "cjs",
  "ts",
  "tsx",
  "py",
  "rs",
  "go",
  "java",
  "kt",
  "c",
  "h",
  "cpp",
  "hpp",
  "cc",
  "rb",
  "php",
  "swift",
  "sh",
  "bash",
  "zsh",
  "sql",
  "log",
  "ini",
  "env",
  "cfg",
  "conf",
  "lua",
  "r",
  "dart",
  "scala",
  "vue",
  "svelte",
];
const PDF_EXTS = ["pdf"];
const IMAGE_EXTS = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "avif"];

const ACCEPTED_EXTS: Record<string, AttachmentKind> = {
  ...Object.fromEntries(TEXT_EXTS.map((ext) => [ext, "text" as const])),
  ...Object.fromEntries(PDF_EXTS.map((ext) => [ext, "pdf" as const])),
  ...Object.fromEntries(IMAGE_EXTS.map((ext) => [ext, "image" as const])),
};

export function basename(path: string): string {
  const normalized = path.replace(/[\\/]+$/, "");
  const segments = normalized.split(/[\\/]/);
  return segments[segments.length - 1] ?? normalized;
}

function extensionOf(name: string): string {
  const dotIndex = name.lastIndexOf(".");
  if (dotIndex <= 0 || dotIndex === name.length - 1) {
    return "";
  }
  return name.slice(dotIndex + 1).toLowerCase();
}

/** Returns attachment metadata for an accepted file path, or null if rejected. */
export function classifyPath(path: string): Attachment | null {
  const name = basename(path);
  const ext = extensionOf(name);
  const kind = ACCEPTED_EXTS[ext];
  if (kind == null) {
    return null;
  }

  return {
    // Paths are unique within a tray (the store dedupes by path), so using the
    // path as the id keeps cards stable across re-renders.
    id: path,
    path,
    name,
    ext,
    kind,
  };
}

const ATTACHMENT_BLOCK_HEADER = "Attached files:";
// Matches the trailing block we generate: a header followed by `@[<path>]` tokens.
// The harness attachment parser scans the prompt for `@[...]` tokens and routes
// each file through its pipeline (images inline, binaries/PDFs become a
// <file_reference> the agent opens with the read tool, text inlines as content).
const ATTACHMENT_BLOCK_PATTERN = /\n*Attached files:\n((?:[ \t]*@\[.+\]\n?)+)$/;

/** Appends an agent-readable, machine-parseable list of attached paths to a prompt. */
export function appendAttachmentsToPrompt(
  prompt: string,
  attachments: Attachment[],
): string {
  if (attachments.length === 0) {
    return prompt;
  }

  const lines = attachments.map((attachment) => `@[${attachment.path}]`);
  return `${prompt}\n\n${ATTACHMENT_BLOCK_HEADER}\n${lines.join("\n")}`;
}

/** Splits a stored user message into its body and the trailing attached-file paths. */
export function parseAttachmentBlock(text: string): {
  body: string;
  paths: string[];
} {
  const match = text.match(ATTACHMENT_BLOCK_PATTERN);
  if (match == null) {
    return { body: text, paths: [] };
  }

  const paths = match[1]
    .split("\n")
    .map((line) => line.trim().replace(/^@\[/, "").replace(/\]$/, "").trim())
    .filter((line) => line.length > 0);

  const body = text.slice(0, match.index).trimEnd();
  return { body, paths };
}
