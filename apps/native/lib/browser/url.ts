/** Address-bar handling: navigate URLs and hostnames, search ordinary words.
 * Blocked schemes stay errors — they are never turned into a search (#823). */

const SEARCH = "https://www.google.com/search?q=";

const BLOCKED = /^(file|javascript|data|blob):/i;
const EXPLICIT = /^[a-z][a-z0-9+.-]*:\/\//i;
const SPECIAL = /^(about|data|blob|file|javascript):/i;
const LOCAL = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\d+\.\d+\.\d+\.\d+)(:\d+)?(\/|$)/i;
const HOST = /^[\w-]+(\.[\w-]+)+(:\d+)?([/?#]|$)/i;
const HOST_PORT = /^[\w.-]+:\d+([/?#]|$)/;

export function looksLikeWebAddress(raw: string): boolean {
  const t = raw.trim();
  if (!t || /\s/.test(t)) return false;
  if (BLOCKED.test(t) || EXPLICIT.test(t) || SPECIAL.test(t)) return true;
  if (LOCAL.test(t) || HOST.test(t) || HOST_PORT.test(t)) return true;
  return false;
}

export function searchUrl(query: string): string {
  return `${SEARCH}${encodeURIComponent(query.trim())}`;
}

/** What the address bar accepts: a URL, a bare host, or a search query. */
export function normalizeUrl(raw: string): string {
  const t = raw.trim();
  if (!t) return "about:blank";
  if (BLOCKED.test(t) || EXPLICIT.test(t) || SPECIAL.test(t)) return t;
  if (looksLikeWebAddress(t)) {
    return `${LOCAL.test(t) ? "http" : "https"}://${t}`;
  }
  return searchUrl(t);
}
