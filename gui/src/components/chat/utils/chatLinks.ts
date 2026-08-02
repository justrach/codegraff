const URL_PATTERN = /https?:\/\/[^\s"'`<>]+/giu;
const FILE_PATH_PATTERN =
  /(?:file:\/\/[^\s"'`<>]+|~\/[^\s"'`<>]+|\.{1,2}\/[^\s"'`<>]+|\/[^\s"'`<>]+|[A-Za-z]:[\\/][^\s"'`<>]+|\\\\[^\s"'`<>]+|[A-Za-z0-9._@-]+(?:\/[A-Za-z0-9._@-]+)+(?::\d+){0,2}|[A-Za-z0-9._@-]+\.[A-Za-z0-9_-]+(?::\d+){0,2})/gu;
const PATH_BOUNDARY_PATTERN = /[\s([{"'`]/u;
const TRAILING_PUNCTUATION_PATTERN = /[.,;!?]+$/u;
const TRAILING_CLOSERS = new Set([")", "]", "}", ">", "'", '"', "`"]);
// Paired Markdown emphasis delimiters. Dropped from a link target only when the
// preceding text actually opened the pair (#197); they are legal URL characters
// otherwise (`#object.__init__`, `/glob/**`).
const EMPHASIS_PAIRS = ["**", "__", "~~"] as const;
const FILE_BASENAME_EXTENSION_PATTERN = /\.[A-Za-z0-9_-]+$/u;
const WINDOWS_DRIVE_PATH_PATTERN = /^[A-Za-z]:[\\/]/u;
const WINDOWS_UNC_PATH_PATTERN = /^\\\\/u;
const EXTERNAL_SCHEME_PATTERN = /^([A-Za-z][A-Za-z0-9+.-]*):(.*)$/u;
const RELATIVE_PATH_PREFIX_PATTERN = /^(~\/|\.{1,2}\/)/u;
const RELATIVE_FILE_PATH_PATTERN = /^[A-Za-z0-9._@-]+(?:\/[A-Za-z0-9._@-]+)+(?::\d+){0,2}$/u;
const RELATIVE_FILE_NAME_PATTERN = /^[A-Za-z0-9._@-]+\.[A-Za-z0-9_-]+(?::\d+){0,2}$/u;
const POSITION_SUFFIX_PATTERN = /:\d+(?::\d+)?$/u;
const POSITION_ONLY_PATTERN = /^\d+(?::\d+)?$/u;
const POSIX_FILE_ROOT_PREFIXES = [
  "/Users/",
  "/home/",
  "/tmp/",
  "/var/",
  "/etc/",
  "/opt/",
  "/mnt/",
  "/Volumes/",
  "/private/",
  "/root/",
] as const;

export interface ChatLinkParseOptions {
  workspacePath?: string | null;
}

export interface ChatLinkMatch {
  kind: "url" | "file";
  start: number;
  end: number;
  value: string;
  path?: string;
}

interface FileUrlTarget {
  path: string;
  hash: string;
}

interface PathPositionParts {
  path: string;
  line?: string;
  column?: string;
}

export function isExternalHttpUrl(href: string): boolean {
  return /^https?:\/\//iu.test(href);
}

export function isMailtoUrl(href: string): boolean {
  return /^mailto:/iu.test(href);
}

function trimLinkCandidate(candidate: string): string {
  let value = candidate;

  let trimmed = true;
  while (trimmed && value.length > 0) {
    trimmed = false;

    const withoutPunctuation = value.replace(TRAILING_PUNCTUATION_PATTERN, "");
    if (withoutPunctuation.length !== value.length) {
      value = withoutPunctuation;
      trimmed = true;
      continue;
    }

    const lastChar = value.at(-1);
    if (lastChar == null) {
      break;
    }

    if (TRAILING_CLOSERS.has(lastChar)) {
      const opener =
        lastChar === ")" ? "(" : lastChar === "]" ? "[" : lastChar === "}" ? "{" : null;
      if (opener != null) {
        const openerCount = value.split(opener).length - 1;
        const closerCount = value.split(lastChar).length - 1;
        if (closerCount <= openerCount) {
          break;
        }
      }

      value = value.slice(0, -1);
      trimmed = true;
    }
  }

  return value;
}

function markdownClosingDelimiterBefore(text: string, start: number): string | null {
  const opening = text.slice(0, start).match(/[~*_]+$/u)?.[0];
  if (opening == null) {
    return null;
  }

  for (let index = 0; index < opening.length; index += 1) {
    if (opening[index] === "*" || opening[index] === "_") {
      continue;
    }
    if (opening[index] !== "~" || opening[index + 1] !== "~") {
      return null;
    }
    index += 1;
  }

  return [...opening].reverse().join("");
}

/**
 * Does the text in front of the URL contain a run that could have *opened* this
 * emphasis pair? A delimiter run only opens when a non-space follows it, so
 * `**Note: see ` opens but `2 ** 3 ` does not.
 */
function hasEmphasisOpenerBefore(before: string, pair: string): boolean {
  let index = before.indexOf(pair);
  while (index >= 0) {
    const next = before[index + pair.length];
    if (next != null && !/\s/u.test(next)) {
      return true;
    }
    index = before.indexOf(pair, index + 1);
  }

  return false;
}

/**
 * Defense in depth for #197: a paired Markdown emphasis delimiter (`**`, `__`,
 * `~~`) is not part of the link target when the surrounding text actually
 * opened that pair earlier — `**Note: see http://x.test**` reaches this matcher
 * with the opener too far from the URL for the mirrored pass above to see it.
 *
 * The strip stays *conditional* on that opener. `**`, `__` and `~~` are all
 * legal URL characters, and an unconditional strip truncates real targets
 * (`…/datamodel.html#object.__init__`, `…/glob/**`, `…/a~~`) — a regression of
 * bb623af, which is why a lone trailing `*`/`~` was already left alone.
 */
function stripEmphasisBoundaries(before: string, value: string): string {
  let result = value;
  let stripped = true;

  while (stripped && result.length > 0) {
    stripped = false;
    for (const pair of EMPHASIS_PAIRS) {
      if (!hasEmphasisOpenerBefore(before, pair)) {
        continue;
      }
      if (result.endsWith(pair)) {
        result = trimLinkCandidate(result.slice(0, -pair.length));
        stripped = true;
        break;
      }
    }
  }

  return result;
}

function trimMarkdownWrappedLinkCandidate(text: string, start: number, candidate: string): string {
  const value = trimLinkCandidate(candidate);
  const closingDelimiter = markdownClosingDelimiterBefore(text, start);
  const mirrored =
    closingDelimiter != null && value.endsWith(closingDelimiter)
      ? trimLinkCandidate(value.slice(0, -closingDelimiter.length))
      : value;

  return stripEmphasisBoundaries(text.slice(0, start), mirrored);
}

function safeDecode(value: string): string {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function stripSearchAndHash(value: string): FileUrlTarget {
  const hashIndex = value.indexOf("#");
  const pathWithSearch = hashIndex >= 0 ? value.slice(0, hashIndex) : value;
  const hash = hashIndex >= 0 ? value.slice(hashIndex) : "";
  const queryIndex = pathWithSearch.indexOf("?");
  const path = queryIndex >= 0 ? pathWithSearch.slice(0, queryIndex) : pathWithSearch;
  return { path, hash };
}

function parseFileUrlHref(
  href: string,
  options: { decodePath?: boolean } = {},
): FileUrlTarget | null {
  try {
    const parsed = new URL(href);
    if (parsed.protocol.toLowerCase() !== "file:") {
      return null;
    }

    let rawPath = parsed.pathname;
    if (parsed.hostname.length > 0 && parsed.hostname !== "localhost") {
      rawPath = /^[A-Za-z]:$/u.test(parsed.hostname)
        ? `${parsed.hostname}${rawPath}`
        : `//${parsed.hostname}${rawPath}`;
    }

    if (rawPath.length === 0) {
      return null;
    }

    const normalizedPath = /^\/[A-Za-z]:[\\/]/u.test(rawPath)
      ? rawPath.slice(1)
      : rawPath;

    return {
      path: options.decodePath === false ? normalizedPath : safeDecode(normalizedPath),
      hash: parsed.hash,
    };
  } catch {
    return null;
  }
}

export function rewriteChatFileUriHref(href: string | undefined): string | null {
  if (href == null) {
    return null;
  }

  const target = parseFileUrlHref(href.trim(), { decodePath: false });
  if (target == null) {
    return null;
  }

  return `${target.path}${target.hash}`;
}

export function sanitizeChatMarkdownHref(
  href: string | undefined,
  workspacePath?: string | null,
): string | null {
  if (href == null) {
    return null;
  }

  const trimmed = href.trim();
  if (trimmed.length === 0) {
    return null;
  }

  const rewrittenFileHref = rewriteChatFileUriHref(trimmed);
  const candidate = rewrittenFileHref ?? trimmed;
  if (isExternalHttpUrl(candidate) || isMailtoUrl(candidate)) {
    return candidate;
  }

  if (resolveChatFilePathTarget(candidate, workspacePath) != null) {
    return candidate;
  }

  return null;
}

function looksLikePosixFilesystemPath(path: string): boolean {
  if (!path.startsWith("/")) {
    return false;
  }

  if (POSIX_FILE_ROOT_PREFIXES.some((prefix) => path.startsWith(prefix))) {
    return true;
  }

  if (POSITION_SUFFIX_PATTERN.test(path)) {
    return true;
  }

  const basename = path.slice(path.lastIndexOf("/") + 1);
  return FILE_BASENAME_EXTENSION_PATTERN.test(basename);
}

function appendLineColumnFromHash(path: string, hash: string): string {
  if (hash.length === 0 || POSITION_SUFFIX_PATTERN.test(path)) {
    return path;
  }

  const match = hash.match(/^#L(\d+)(?:C(\d+))?$/iu);
  if (match?.[1] == null) {
    return path;
  }

  return `${path}:${match[1]}${match[2] == null ? "" : `:${match[2]}`}`;
}

function isLikelyPathCandidate(path: string): boolean {
  if (WINDOWS_DRIVE_PATH_PATTERN.test(path) || WINDOWS_UNC_PATH_PATTERN.test(path)) {
    return true;
  }

  if (RELATIVE_PATH_PREFIX_PATTERN.test(path)) {
    return true;
  }

  if (path.startsWith("/")) {
    return looksLikePosixFilesystemPath(path);
  }

  return RELATIVE_FILE_PATH_PATTERN.test(path) || RELATIVE_FILE_NAME_PATTERN.test(path);
}

function hasExternalScheme(path: string): boolean {
  const match = path.match(EXTERNAL_SCHEME_PATTERN);
  if (match == null) {
    return false;
  }

  if (WINDOWS_DRIVE_PATH_PATTERN.test(path) || WINDOWS_UNC_PATH_PATTERN.test(path)) {
    return false;
  }

  const rest = match[2] ?? "";
  if (rest.startsWith("//")) {
    return true;
  }

  return !POSITION_ONLY_PATTERN.test(rest);
}

function isWindowsAbsolutePath(value: string): boolean {
  return WINDOWS_DRIVE_PATH_PATTERN.test(value) || WINDOWS_UNC_PATH_PATTERN.test(value);
}

function isAbsolutePath(value: string): boolean {
  return value.startsWith("/") || isWindowsAbsolutePath(value);
}

function isWindowsPathStyle(value: string): boolean {
  return isWindowsAbsolutePath(value) || /[A-Za-z]:\\/u.test(value);
}

function joinPath(base: string, next: string, separator: "/" | "\\"): string {
  const cleanBase = base.replace(/[\\/]+$/u, "");
  if (separator === "\\") {
    return `${cleanBase}\\${next.replaceAll("/", "\\")}`;
  }

  return `${cleanBase}/${next.replace(/^\/+/, "")}`;
}

function inferHomeFromWorkspace(workspacePath: string): string | null {
  const posixUser = workspacePath.match(/^\/Users\/([^/]+)/u);
  if (posixUser?.[1] != null) {
    return `/Users/${posixUser[1]}`;
  }

  const posixHome = workspacePath.match(/^\/home\/([^/]+)/u);
  if (posixHome?.[1] != null) {
    return `/home/${posixHome[1]}`;
  }

  const windowsUser = workspacePath.match(/^([A-Za-z]:\\Users\\[^\\]+)/u);
  if (windowsUser?.[1] != null) {
    return windowsUser[1];
  }

  return null;
}

function splitPathAndPosition(value: string): PathPositionParts {
  let path = value;
  let column: string | undefined;
  let line: string | undefined;

  const columnMatch = path.match(/:(\d+)$/u);
  if (
    columnMatch?.[1] == null ||
    (WINDOWS_DRIVE_PATH_PATTERN.test(path) && columnMatch.index === 1)
  ) {
    return { path };
  }

  column = columnMatch[1];
  path = path.slice(0, -columnMatch[0].length);

  const lineMatch = path.match(/:(\d+)$/u);
  if (
    lineMatch?.[1] != null &&
    !(WINDOWS_DRIVE_PATH_PATTERN.test(path) && lineMatch.index === 1)
  ) {
    line = lineMatch[1];
    path = path.slice(0, -lineMatch[0].length);
  } else {
    line = column;
    column = undefined;
  }

  return { path, line, column };
}

function resolvePathAgainstWorkspace(rawPath: string, workspacePath: string): string {
  const { path, line, column } = splitPathAndPosition(rawPath);
  let resolvedPath = path;

  if (path.startsWith("~/")) {
    const home = inferHomeFromWorkspace(workspacePath);
    if (home != null) {
      const separator: "/" | "\\" = isWindowsPathStyle(home) ? "\\" : "/";
      resolvedPath = joinPath(home, path.slice(2), separator);
    }
  } else if (!isAbsolutePath(path)) {
    const separator: "/" | "\\" = isWindowsPathStyle(workspacePath) ? "\\" : "/";
    resolvedPath = joinPath(workspacePath, path, separator);
  }

  if (line == null) {
    return resolvedPath;
  }

  return `${resolvedPath}:${line}${column == null ? "" : `:${column}`}`;
}

export function resolveChatFilePathTarget(
  value: string | undefined,
  workspacePath?: string | null,
): string | null {
  if (value == null) {
    return null;
  }

  const rawValue = trimLinkCandidate(value.trim());
  if (rawValue.length === 0 || rawValue.startsWith("#")) {
    return null;
  }

  const fileUrlTarget = rawValue.toLowerCase().startsWith("file:")
    ? parseFileUrlHref(rawValue)
    : null;
  const source = fileUrlTarget ?? stripSearchAndHash(rawValue);
  const decodedPath = fileUrlTarget == null ? safeDecode(source.path.trim()) : source.path.trim();
  const decodedHash = safeDecode(source.hash.trim());

  if (decodedPath.length === 0 || hasExternalScheme(decodedPath)) {
    return null;
  }

  if (!isLikelyPathCandidate(decodedPath)) {
    return null;
  }

  const pathWithPosition = appendLineColumnFromHash(decodedPath, decodedHash);
  if (isAbsolutePath(pathWithPosition)) {
    return pathWithPosition;
  }

  if (workspacePath == null || workspacePath.trim().length === 0) {
    return null;
  }

  return resolvePathAgainstWorkspace(pathWithPosition, workspacePath.trim());
}

function readPathCandidate(text: string, startIndex: number): string {
  let index = startIndex;
  while (index < text.length) {
    const char = text[index];
    if (char == null || /\s/u.test(char) || char === "<") {
      break;
    }

    index += 1;
  }

  return trimLinkCandidate(text.slice(startIndex, index));
}

function shouldConsiderPathStart(text: string, index: number): boolean {
  return index === 0 || PATH_BOUNDARY_PATTERN.test(text[index - 1] ?? "");
}

function rangesOverlap(
  left: { start: number; end: number },
  right: { start: number; end: number },
): boolean {
  return left.start < right.end && right.start < left.end;
}

export function getChatLinkMatches(
  text: string,
  options: ChatLinkParseOptions = {},
): ChatLinkMatch[] {
  const matches: ChatLinkMatch[] = [];

  URL_PATTERN.lastIndex = 0;
  let urlMatch: RegExpExecArray | null;
  while ((urlMatch = URL_PATTERN.exec(text)) !== null) {
    const value = trimMarkdownWrappedLinkCandidate(text, urlMatch.index, urlMatch[0]);
    if (value.length === 0) {
      continue;
    }

    matches.push({
      kind: "url",
      start: urlMatch.index,
      end: urlMatch.index + value.length,
      value,
    });
  }

  FILE_PATH_PATTERN.lastIndex = 0;
  let pathMatch: RegExpExecArray | null;
  while ((pathMatch = FILE_PATH_PATTERN.exec(text)) !== null) {
    const start = pathMatch.index;
    if (!shouldConsiderPathStart(text, start)) {
      continue;
    }

    const value = readPathCandidate(text, start);
    const candidate = { start, end: start + value.length };
    if (matches.some((match) => rangesOverlap(candidate, match))) {
      continue;
    }

    const path = resolveChatFilePathTarget(value, options.workspacePath);
    if (path == null) {
      continue;
    }

    matches.push({
      kind: "file",
      start,
      end: candidate.end,
      value,
      path,
    });
  }

  return matches.sort((left, right) => left.start - right.start || right.end - left.end);
}
