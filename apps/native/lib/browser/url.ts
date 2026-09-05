/** What the address bar accepts: a full URL, a bare host, or a local
 * address. A bare host becomes https; localhost and raw addresses stay
 * http, since dev servers rarely speak TLS. Empty means a blank page. */
export function normalizeUrl(raw: string): string {
  const t = raw.trim();
  if (!t) return "about:blank";
  // `localhost:3000` is a host and port, not a scheme: a scheme needs `//`
  // after it, except the few that never carry one.
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(t) || /^(about|data|blob|file|javascript):/i.test(t)) return t;
  const local = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|\d+\.\d+\.\d+\.\d+)(:\d+)?(\/|$)/i.test(t);
  return `${local ? "http" : "https"}://${t}`;
}
