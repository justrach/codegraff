const { timingSafeEqual } = require('node:crypto');

function pageURL(raw) {
  const text = String(raw || '').trim();
  if (!text || text === 'about:blank') return 'about:blank';
  const local = /^(localhost|127\.0\.0\.1|\[::1\])(:|\/|$)/.test(text);
  const url = new URL(/^[a-z][\w+.-]*:/i.test(text) && !local ? text : `${local ? 'http' : 'https'}://${text}`);
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

function bounds(rect, size) {
  if (!rect || !['x', 'y', 'width', 'height'].every(k => Number.isFinite(rect[k]))) return null;
  const x = Math.max(0, Math.min(size.width, Math.round(rect.x)));
  const y = Math.max(0, Math.min(size.height, Math.round(rect.y)));
  return { x, y, width: Math.max(0, Math.min(size.width - x, Math.round(rect.width))),
    height: Math.max(0, Math.min(size.height - y, Math.round(rect.height))) };
}
module.exports = { pageURL, authorized, bounds };
