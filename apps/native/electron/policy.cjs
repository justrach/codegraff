const { timingSafeEqual } = require('node:crypto');

function looksLikeWebAddress(text) {
  if (!text || /\s/.test(text)) return false;
  if (/^(file|javascript|data|blob):/i.test(text) || /^[a-z][\w+.-]*:\/\//i.test(text)) return true;
  if (/^(about|data|blob|file|javascript):/i.test(text)) return true;
  if (/^(localhost|127\.0\.0\.1|\[::1\]|\d+\.\d+\.\d+\.\d+)(:|\/|$)/.test(text)) return true;
  if (/^[\w-]+(\.[\w-]+)+(:\d+)?([/?#]|$)/i.test(text)) return true;
  if (/^[\w.-]+:\d+([/?#]|$)/.test(text)) return true;
  return false;
}

function pageURL(raw) {
  const text = String(raw || '').trim();
  if (!text || text === 'about:blank') return 'about:blank';
  if (/^(file|javascript|data|blob):/i.test(text)) throw new Error('Only HTTP and HTTPS pages are supported');
  const local = /^(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/.test(text);
  const candidate = looksLikeWebAddress(text)
    ? (/^[a-z][\w+.-]*:/i.test(text) && !local ? text : `${local ? 'http' : 'https'}://${text}`)
    : `https://www.google.com/search?q=${encodeURIComponent(text)}`;
  let url;
  try { url = new URL(candidate); }
  catch { throw new Error('Enter a web address or a search.'); }
  if (!['https:', 'http:'].includes(url.protocol)) throw new Error('Only HTTP and HTTPS pages are supported');
  if (url.username || url.password) throw new Error('Use the page sign-in form');
  return url.href;
}

function authorized(req, token) {
  if (req.headers.origin) return false;
  const actual = Buffer.from(req.headers.authorization || '');
  const expected = Buffer.from(`Bearer ${token}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function bounds(rect, size, zoom = 1) {
  if (!rect || !['x', 'y', 'width', 'height'].every(k => Number.isFinite(rect[k]))) return null;
  if (!Number.isFinite(zoom) || zoom <= 0) return null;
  rect = Object.fromEntries(['x', 'y', 'width', 'height'].map(key => [key, rect[key] * zoom]));
  const x = Math.max(0, Math.min(size.width, Math.round(rect.x)));
  const y = Math.max(0, Math.min(size.height, Math.round(rect.y)));
  return { x, y, width: Math.max(0, Math.min(size.width - x, Math.round(rect.width))),
    height: Math.max(0, Math.min(size.height - y, Math.round(rect.height))) };
}
module.exports = { pageURL, authorized, bounds };
