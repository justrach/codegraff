export type BrowserLinkSegment =
  | { kind: "text"; value: string }
  | { kind: "link"; label: string; href: string };

const EXPLICIT_HTTP = /^https?:\/\//i;
const LOCAL_HOST = /^(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\d{1,3}(?:\.\d{1,3}){3})(?::\d{1,5})?(?:[/?#]|$)/i;
const FILELIKE_SUFFIXES = new Set([
  "7z", "avif", "avi", "bak", "bmp", "bz2", "c", "cc", "cfg", "conf", "cpp", "css",
  "csv", "dmg", "doc", "docx", "eot", "exe", "flac", "gif", "go", "gz", "h", "hpp",
  "html", "ico", "ini", "java", "jpeg", "jpg", "js", "json", "jsx", "lock", "log", "m4a",
  "map", "md", "mjs", "mkv", "mov", "mp3", "mp4", "msi", "ogg", "otf", "pdf", "pkg",
  "png", "ppt", "pptx", "py", "rar", "rb", "rs", "sh", "sql", "svg", "swp", "tar",
  "tgz", "toml", "ts", "tsx", "ttf", "txt", "wasm", "wav", "webm", "webmanifest", "webp",
  "woff", "woff2", "xls", "xlsx", "xml", "xz", "yaml", "yml", "zig", "zip",
]);
const CANDIDATE = /https?:\/\/[^\s<>"'`]+|www\.(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}(?::\d{1,5})?(?:[/?#][^\s<>"'`]*)?|(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\d{1,3}(?:\.\d{1,3}){3})(?::\d{1,5})?(?:[/?#][^\s<>"'`]*)?|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})(?::\d{1,5})?(?:[/?#][^\s<>"'`]*)?/giu;
const TRAILING_PUNCTUATION = /[.,;:!?]+$/u;
const CLOSERS: Record<string, string> = { ")": "(", "]": "[", "}": "{" };

function trimCandidate(raw: string): string {
  let value = raw;
  let changed = true;
  while (changed && value.length > 0) {
    changed = false;
    const withoutPunctuation = value.replace(TRAILING_PUNCTUATION, "");
    if (withoutPunctuation !== value) {
      value = withoutPunctuation;
      changed = true;
      continue;
    }
    const last = value.at(-1);
    const opener = last == null ? undefined : CLOSERS[last];
    if (last != null && opener != null) {
      const opens = value.split(opener).length - 1;
      const closes = value.split(last).length - 1;
      if (closes > opens) {
        value = value.slice(0, -1);
        changed = true;
      }
    }
  }
  return value;
}

function hasSafeBoundary(text: string, start: number): boolean {
  if (start === 0) return true;
  const before = text.slice(0, start);
  if (/[A-Za-z][A-Za-z0-9+.-]*:$/u.test(before)) return false;
  return !/[A-Za-z0-9_@./\\-]/u.test(text[start - 1] ?? "");
}

function hasValidIpv4(hostname: string): boolean {
  if (!/^\d{1,3}(?:\.\d{1,3}){3}$/u.test(hostname)) return true;
  return hostname.split(".").every(part => Number(part) <= 255);
}

function looksFilelikeHostname(hostname: string, raw: string, explicit: boolean): boolean {
  if (explicit || raw.toLowerCase().startsWith("www.")) return false;
  const labels = hostname.toLowerCase().split(".");
  return FILELIKE_SUFFIXES.has(labels.at(-1) ?? "");
}

/** Turn text that clearly names a browser destination into a safe HTTP(S) href.
 * Bare public hosts use HTTPS; localhost and numeric addresses use HTTP. */
export function normalizeBrowserTarget(raw: string): string | null {
  const value = trimCandidate(raw.trim());
  if (!value || /\s/u.test(value)) return null;
  const explicit = EXPLICIT_HTTP.test(value);
  const local = LOCAL_HOST.test(value);
  if (!explicit && !local && !/^www\./i.test(value) && !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]{2,59})(?::\d{1,5})?(?:[/?#]|$)/i.test(value)) return null;

  try {
    const url = new URL(explicit ? value : `${local ? "http" : "https"}://${value}`);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || !url.hostname) return null;
    if (!hasValidIpv4(url.hostname) || looksFilelikeHostname(url.hostname, value, explicit)) return null;
    return url.href;
  } catch {
    return null;
  }
}

export function browserLinkSegments(text: string): BrowserLinkSegment[] {
  const links: Array<{ start: number; end: number; label: string; href: string }> = [];
  CANDIDATE.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = CANDIDATE.exec(text)) !== null) {
    const start = match.index;
    if (!hasSafeBoundary(text, start)) continue;
    const label = trimCandidate(match[0]);
    const href = normalizeBrowserTarget(label);
    if (href == null) continue;
    links.push({ start, end: start + label.length, label, href });
  }
  if (links.length === 0) return [{ kind: "text", value: text }];

  const segments: BrowserLinkSegment[] = [];
  let cursor = 0;
  for (const link of links) {
    if (link.start > cursor) segments.push({ kind: "text", value: text.slice(cursor, link.start) });
    segments.push({ kind: "link", label: link.label, href: link.href });
    cursor = link.end;
  }
  if (cursor < text.length) segments.push({ kind: "text", value: text.slice(cursor) });
  return segments;
}
