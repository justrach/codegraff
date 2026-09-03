/** The JavaScript the route evaluates in the sidecar's page to identify
 * the element under a viewport point. Nothing is injected or persisted:
 * every hover or click is one `Runtime.evaluate`, so it works on any page
 * regardless of its content security policy. */

const SOURCE = String.raw`(function (x, y) {
  var el = document.elementFromPoint(x, y);
  if (!el) return null;
  var r = el.getBoundingClientRect();
  var attr = function (n) { return el.getAttribute(n) || ""; };
  var squash = function (s) { return (s || "").replace(/\s+/g, " ").trim(); };
  var ROLES = { A: "link", BUTTON: "button", INPUT: "textbox", TEXTAREA: "textbox", SELECT: "combobox", IMG: "img",
    H1: "heading", H2: "heading", H3: "heading", H4: "heading", NAV: "navigation", MAIN: "main", FORM: "form",
    LI: "listitem", UL: "list", OL: "list", TABLE: "table", LABEL: "label", SUMMARY: "button" };
  var tag = el.tagName;
  var role = attr("role") || ROLES[tag] || "";
  if (tag === "INPUT") {
    var t = (el.getAttribute("type") || "text").toLowerCase();
    role = t === "checkbox" ? "checkbox" : t === "radio" ? "radio" : t === "submit" || t === "button" ? "button" : "textbox";
  }
  var labelled = "";
  if (el.labels && el.labels.length) labelled = squash(el.labels[0].textContent);
  var name = attr("aria-label") || labelled || attr("alt") || attr("title") || attr("placeholder") || attr("value") || squash(el.innerText || el.textContent).slice(0, 80);
  var seg = function (e) {
    if (e.id) return "#" + CSS.escape(e.id);
    var tid = e.getAttribute("data-testid");
    if (tid) return e.tagName.toLowerCase() + "[data-testid=\"" + tid + "\"]";
    var s = e.tagName.toLowerCase();
    var cls = Array.prototype.filter.call(e.classList, function (c) { return !/[:\[\]\/!@]/.test(c); }).slice(0, 2);
    if (cls.length) s += "." + cls.map(function (c) { return CSS.escape(c); }).join(".");
    var p = e.parentElement;
    if (p) {
      var same = Array.prototype.filter.call(p.children, function (c) { return c.tagName === e.tagName; });
      if (same.length > 1) s += ":nth-of-type(" + (same.indexOf(e) + 1) + ")";
    }
    return s;
  };
  var parts = [];
  var cur = el;
  while (cur && cur !== document.body && cur !== document.documentElement && parts.length < 4) {
    parts.unshift(seg(cur));
    if (cur.id) break;
    cur = cur.parentElement;
  }
  return {
    tag: tag.toLowerCase(),
    role: role,
    name: squash(name).slice(0, 80),
    text: squash(el.innerText || el.textContent).slice(0, 160),
    selector: parts.join(" > "),
    href: el.href ? String(el.href) : null,
    rect: { x: r.left, y: r.top, w: r.width, h: r.height },
    url: location.href,
    title: document.title
  };
})(__X__, __Y__)`;

/** Kuri reads a request head into an 8 KB buffer, and the expression rides
 * in the query string, so the source is collapsed to one line first. No
 * string literal above spans lines or holds runs of spaces. */
function compact(source: string): string {
  return source.replace(/\s*\n\s*/g, " ").replace(/ {2,}/g, " ").trim();
}

export function inspectExpression(x: number, y: number): string {
  return compact(SOURCE).replace("__X__", String(Math.round(x))).replace("__Y__", String(Math.round(y)));
}

/** Every element worth pinning that is on screen right now, in one call:
 * interactive things and anything with its own text, with the box, a
 * stable selector and an accessible name for each. The pane hit-tests this
 * locally, so hover and click cost nothing, and refreshes it after a
 * scroll or a navigation. `textContent` rather than `innerText`: the
 * latter forces layout per element and the page can have thousands. */
const MAP_SOURCE = String.raw`(function () {
  var vw = innerWidth, vh = innerHeight;
  var squash = function (s) { return (s || "").replace(/\s+/g, " ").trim(); };
  var ROLES = { A: "link", BUTTON: "button", INPUT: "textbox", TEXTAREA: "textbox", SELECT: "combobox", IMG: "img",
    H1: "heading", H2: "heading", H3: "heading", H4: "heading", NAV: "navigation", MAIN: "main", FORM: "form",
    LI: "listitem", UL: "list", OL: "list", TABLE: "table", LABEL: "label", SUMMARY: "button" };
  var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|SVG|PATH|BR|HTML|HEAD|META|LINK|TEMPLATE|IFRAME)$/;
  var INTERACTIVE = /^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|LABEL|IMG|VIDEO)$/;
  var roleOf = function (el) {
    var tag = el.tagName;
    var role = el.getAttribute("role") || ROLES[tag] || "";
    if (tag === "INPUT") {
      var t = (el.getAttribute("type") || "text").toLowerCase();
      role = t === "checkbox" ? "checkbox" : t === "radio" ? "radio" : t === "submit" || t === "button" ? "button" : "textbox";
    }
    return role;
  };
  var nameOf = function (el) {
    var attr = function (n) { return el.getAttribute(n) || ""; };
    var labelled = el.labels && el.labels.length ? squash(el.labels[0].textContent) : "";
    return squash(attr("aria-label") || labelled || attr("alt") || attr("title") || attr("placeholder") || attr("value") || el.textContent).slice(0, 80);
  };
  var seg = function (e) {
    if (e.id) return "#" + CSS.escape(e.id);
    var tid = e.getAttribute("data-testid");
    if (tid) return e.tagName.toLowerCase() + "[data-testid=\"" + tid + "\"]";
    var s = e.tagName.toLowerCase();
    var cls = Array.prototype.filter.call(e.classList, function (c) { return !/[:\[\]\/!@]/.test(c); }).slice(0, 2);
    if (cls.length) s += "." + cls.map(function (c) { return CSS.escape(c); }).join(".");
    var p = e.parentElement;
    if (p) {
      var same = Array.prototype.filter.call(p.children, function (c) { return c.tagName === e.tagName; });
      if (same.length > 1) s += ":nth-of-type(" + (same.indexOf(e) + 1) + ")";
    }
    return s;
  };
  var selectorOf = function (el) {
    var parts = [];
    var cur = el;
    while (cur && cur !== document.body && cur !== document.documentElement && parts.length < 4) {
      parts.unshift(seg(cur));
      if (cur.id) break;
      cur = cur.parentElement;
    }
    return parts.join(" > ");
  };
  var out = [];
  var all = document.body ? document.body.getElementsByTagName("*") : [];
  for (var i = 0; i < all.length && out.length < 600; i++) {
    var el = all[i];
    var tag = el.tagName;
    if (SKIP.test(tag)) continue;
    var r = el.getBoundingClientRect();
    if (r.width < 6 || r.height < 6) continue;
    if (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) continue;
    var interactive = INTERACTIVE.test(tag) || el.hasAttribute("role") || el.hasAttribute("onclick") || el.hasAttribute("tabindex") || el.hasAttribute("contenteditable");
    var hasText = false;
    for (var c = el.firstChild; c; c = c.nextSibling) { if (c.nodeType === 3 && c.nodeValue.trim()) { hasText = true; break; } }
    if (!interactive && !hasText) continue;
    out.push({ i: out.length, tag: tag.toLowerCase(), role: roleOf(el), name: nameOf(el), text: squash(el.textContent).slice(0, 120),
      selector: selectorOf(el), href: el.href ? String(el.href) : null, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
  }
  return { url: location.href, title: document.title, vw: vw, vh: vh, scrollX: scrollX, scrollY: scrollY, els: out };
})()`;

export function mapExpression(): string {
  return compact(MAP_SOURCE);
}

/** Scroll the innermost scrollable box under a point, else the page.
 * Kuri's `/mouse/wheel` (CDP `Input.dispatchMouseEvent` mouseWheel) fails
 * on some pages, and a wheel that does nothing is the fastest way to make
 * the pane feel broken; scrolling by script never fails. */
const SCROLL_SOURCE = String.raw`(function (x, y, dx, dy) {
  var el = document.elementFromPoint(x, y);
  while (el && el !== document.body && el !== document.documentElement) {
    var s = getComputedStyle(el);
    if (/(auto|scroll)/.test(s.overflowY + s.overflowX) && (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1)) {
      var before = el.scrollTop + el.scrollLeft;
      el.scrollBy(dx, dy);
      if (el.scrollTop + el.scrollLeft !== before) return "box";
    }
    el = el.parentElement;
  }
  window.scrollBy(dx, dy);
  return "page";
})(__X__, __Y__, __DX__, __DY__)`;

export function scrollExpression(x: number, y: number, dx: number, dy: number): string {
  return compact(SCROLL_SOURCE)
    .replace("__X__", String(Math.round(x)))
    .replace("__Y__", String(Math.round(y)))
    .replace("__DX__", String(Math.round(dx)))
    .replace("__DY__", String(Math.round(dy)));
}

/** The same lookup, rect only: what hover needs at ten calls a second. */
export const HOVER_SOURCE = String.raw`(function (x, y) {
  var el = document.elementFromPoint(x, y);
  if (!el) return null;
  var r = el.getBoundingClientRect();
  return { rect: { x: r.left, y: r.top, w: r.width, h: r.height }, tag: el.tagName.toLowerCase() };
})(__X__, __Y__)`;

export function hoverExpression(x: number, y: number): string {
  return compact(HOVER_SOURCE).replace("__X__", String(Math.round(x))).replace("__Y__", String(Math.round(y)));
}
