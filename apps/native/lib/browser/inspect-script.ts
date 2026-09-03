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
