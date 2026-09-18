/** Graff Sidecar — content script (isolated world).
 *
 * Page probes and actions behind the harness's browser methods. Runs in the
 * extension's isolated world: page scripts cannot see or touch this code,
 * and page content is treated as untrusted data on the way back (same rule
 * as the sidecar's annotationsBlock). Nothing here exfiltrates on its own —
 * every value goes back to the background worker, which only talks to the
 * paired loopback harness.
 */

const ROLES = { A: "link", BUTTON: "button", INPUT: "textbox", TEXTAREA: "textbox", SELECT: "combobox",
  IMG: "img", H1: "heading", H2: "heading", H3: "heading", H4: "heading", NAV: "navigation",
  MAIN: "main", FORM: "form", LI: "listitem", UL: "list", OL: "list", TABLE: "table", LABEL: "label", SUMMARY: "button" };
const SKIP = /^(SCRIPT|STYLE|NOSCRIPT|SVG|PATH|BR|HTML|HEAD|META|LINK|TEMPLATE|IFRAME)$/;
const INTERACTIVE = /^(A|BUTTON|INPUT|SELECT|TEXTAREA|SUMMARY|LABEL|IMG|VIDEO)$/;

function squash(s) { return (s || "").replace(/\s+/g, " ").trim(); }

/* Marker colors follow the user's GUI theme (extension storage mirrors
 * themeStore's keys). Read once at load plus on each pick-mode entry, so
 * a theme change applies next time without a page reload. content_scripts
 * cannot load theme.css (it would leak extension URLs into page CSSOM
 * lookups), so only the two hexes cross the boundary. */
const FALLBACK_ACCENT = "#e8a33d"; // warm-graphite dark --accent
const FALLBACK_DEEP = "#16140f"; // warm-graphite dark --background
let markerAccent = FALLBACK_ACCENT, markerDeep = FALLBACK_DEEP;
if (chrome.storage?.local) {
  chrome.storage.local.get(["themePreset"]).then(({ themePreset }) => {
    fetch(chrome.runtime.getURL("theme-presets.json")).then((r) => r.json()).then(({ swatches }) => {
      const s = swatches[themePreset];
      if (s) { markerAccent = s.accent; markerDeep = s.bg; }
    }).catch(() => undefined);
  }).catch(() => undefined);
}

function roleOf(el) {
  const role = el.getAttribute("role") || ROLES[el.tagName] || "";
  if (el.tagName === "INPUT") {
    const t = (el.getAttribute("type") || "text").toLowerCase();
    return t === "checkbox" ? "checkbox" : t === "radio" ? "radio" : t === "submit" || t === "button" ? "button" : "textbox";
  }
  return role;
}

function nameOf(el) {
  const labelled = el.labels?.length ? squash(el.labels[0].textContent) : "";
  return squash(el.getAttribute("aria-label") || labelled || el.getAttribute("alt") ||
    el.getAttribute("title") || el.getAttribute("placeholder") || el.getAttribute("value") || el.textContent).slice(0, 80);
}

function selectorOf(el) {
  const seg = (e) => {
    if (e.id) return `#${CSS.escape(e.id)}`;
    const tid = e.getAttribute("data-testid");
    if (tid) return `${e.tagName.toLowerCase()}[data-testid="${tid}"]`;
    let s = e.tagName.toLowerCase();
    const cls = [...e.classList].filter((c) => !/[:[\]/!@]/.test(c)).slice(0, 2);
    if (cls.length) s += "." + cls.map((c) => CSS.escape(c)).join(".");
    const p = e.parentElement;
    if (p) {
      const same = [...p.children].filter((c) => c.tagName === e.tagName);
      if (same.length > 1) s += `:nth-of-type(${same.indexOf(e) + 1})`;
    }
    return s;
  };
  const parts = [];
  for (let cur = el; cur && cur !== document.body && cur !== document.documentElement && parts.length < 4; cur = cur.parentElement) {
    parts.unshift(seg(cur));
    if (cur.id) break;
  }
  return parts.join(" > ");
}

function box(el) {
  const r = el.getBoundingClientRect();
  return { x: r.left, y: r.top, w: r.width, h: r.height };
}

function describe(el) {
  return { tag: el.tagName.toLowerCase(), role: roleOf(el), name: nameOf(el),
    text: squash(el.innerText || el.textContent).slice(0, 160),
    selector: selectorOf(el), href: el.href ? String(el.href) : (el.closest("a")?.href || null), rect: box(el) };
}

/** Every pinnable on-screen element: interactive or text-bearing, like the
 * sidecar's mapExpression. Capped so a huge page cannot stall the tab. */
function snapshot() {
  const vw = innerWidth, vh = innerHeight, out = [];
  const all = document.body ? document.body.getElementsByTagName("*") : [];
  for (let i = 0; i < all.length && out.length < 600; i++) {
    const el = all[i];
    if (SKIP.test(el.tagName)) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 6 || r.height < 6 || r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) continue;
    const interactive = INTERACTIVE.test(el.tagName) || el.hasAttribute("role") ||
      el.hasAttribute("onclick") || el.hasAttribute("tabindex") || el.hasAttribute("contenteditable");
    let hasText = false;
    for (let c = el.firstChild; c; c = c.nextSibling) {
      if (c.nodeType === 3 && c.nodeValue.trim()) { hasText = true; break; }
    }
    if (!interactive && !hasText) continue;
    out.push({ ...describe(el), i: out.length });
  }
  return { url: location.href, title: document.title, vw, vh, scrollX, scrollY, els: out };
}

/** Compact text snapshot with stable `eN` refs into the element list. */
function compactSnapshot() {
  const map = snapshot();
  const lines = map.els.map((el) => `${el.role || el.tag} "${el.name.replace(/"/g, '\\"')}" @e${el.i}`);
  return { ...map, snapshot: lines.join("\n") };
}

function findTarget(params = {}) {
  if (params.selector) {
    const el = document.querySelector(String(params.selector));
    if (!el) throw new Error("Element not found");
    return el;
  }
  if (params.ref !== undefined) {
    const els = snapshot().els;
    const el = els[Number(String(params.ref).replace(/^e/, ""))];
    if (!el) throw new Error("Ref not on screen — take a fresh snapshot");
    const node = document.querySelector(el.selector);
    if (!node) throw new Error("Element is gone — take a fresh snapshot");
    return node;
  }
  if (params.x !== undefined) {
    const el = document.elementFromPoint(Number(params.x), Number(params.y));
    if (!el) throw new Error("No element at that point");
    return el;
  }
  throw new Error("click/fill/select need selector, ref, or x/y");
}

let highlightLayer = null;
function highlight(params = {}) {
  highlightLayer?.remove();
  const el = findTarget(params);
  el.scrollIntoView({ block: "center" });
  const r = el.getBoundingClientRect();
  highlightLayer = document.createElement("div");
  highlightLayer.style.cssText = `position:fixed;left:${r.x}px;top:${r.y}px;width:${r.width}px;height:${r.height}px;` +
    `border:2px solid ${markerAccent};border-radius:4px;box-sizing:border-box;background:${markerAccent}22;` +
    "pointer-events:none;z-index:2147483647;transition:opacity .4s";
  document.documentElement.append(highlightLayer);
  setTimeout(() => highlightLayer && (highlightLayer.style.opacity = "0"), 1600);
  setTimeout(() => { highlightLayer?.remove(); highlightLayer = null; }, 2200);
  return { ok: true };
}

function setValue(el, text) {
  if (!(el instanceof HTMLInputElement) && !(el instanceof HTMLTextAreaElement)) throw new Error("Element is not a text input");
  if (el.type === "password") throw new Error("Secure fields require user input");
  el.focus();
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, "value")?.set?.call(el, String(text));
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
}

/* --- Pin mode: the pick-an-element flow from the Electron preload,
 * re-implemented for a real user tab. Esc cancels; a click reports a pin. */
let picking = false, outline = null, hint = null, pins = [];

function pickMode(enabled) {
  picking = !!enabled;
  outline?.remove(); outline = null;
  hint?.remove(); hint = null;
  if (!picking) return;
  hint = document.createElement("div");
  hint.textContent = "Graff: click an element to pin · Esc to cancel";
  hint.style.cssText = "position:fixed;top:12px;left:50%;transform:translateX(-50%);pointer-events:none;z-index:2147483647;" +
    `background:${markerDeep};color:${markerAccent};border:1px solid ${markerAccent};border-radius:20px;padding:8px 14px;font:13px system-ui;white-space:nowrap`;
  document.documentElement.append(hint);
}

document.addEventListener("pointermove", (e) => {
  if (!picking || !(e.target instanceof Element)) return;
  const r = e.target.getBoundingClientRect();
  if (!outline) {
    outline = document.createElement("div");
    outline.style.cssText = `position:fixed;pointer-events:none;z-index:2147483647;border:2px solid ${markerAccent};border-radius:4px;box-sizing:border-box`;
  }
  if (!outline.isConnected) document.documentElement.append(outline);
  Object.assign(outline.style, { left: `${r.x}px`, top: `${r.y}px`, width: `${r.width}px`, height: `${r.height}px` });
}, true);

for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
  document.addEventListener(type, (e) => {
    if (picking) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, true);
}

document.addEventListener("click", (e) => {
  if (!picking || !(e.target instanceof Element)) return;
  e.preventDefault(); e.stopImmediatePropagation();
  const el = e.target, desc = describe(el);
  pickMode(false);
  chrome.runtime.sendMessage({ cmd: "pin-event", pin: {
    id: Date.now(), comment: "", url: location.href, title: document.title, ref: null,
    element: desc, point: { x: e.clientX, y: e.clientY },
    doc: { ...desc.rect, x: desc.rect.x + scrollX, y: desc.rect.y + scrollY },
  } });
}, true);

document.addEventListener("keydown", (e) => {
  if (picking && e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); pickMode(false); }
}, true);

let markers = null;
function renderPins() {
  markers?.remove();
  markers = document.createElement("div");
  markers.style.cssText = "position:fixed;inset:0;pointer-events:none;z-index:2147483646";
  pins.forEach((pin, i) => {
    if (pin.url !== location.href) return;
    let el;
    try { el = document.querySelector(pin.element.selector); } catch { return; }
    if (!el) return;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height || r.bottom < 0 || r.top > innerHeight) return;
    const mark = document.createElement("div");
    mark.style.cssText = `position:absolute;left:${r.x}px;top:${r.y}px;width:${r.width}px;height:${r.height}px;` +
      `border:2px solid ${markerAccent};border-radius:4px;box-sizing:border-box;background:${markerAccent}14`;
    const badge = document.createElement("span");
    badge.textContent = String(i + 1);
    badge.style.cssText = `position:absolute;left:0;top:0;background:${markerDeep};color:${markerAccent};border:1px solid ${markerAccent};border-radius:12px;min-width:20px;height:20px;text-align:center;font:bold 12px/20px system-ui`;
    mark.append(badge); markers.append(mark);
  });
  document.documentElement.append(markers);
}

/** `evaluate` runs the harness's expression in the page's own world via a
 * script tag, so `window`/`document` behave exactly like devtools. The tag
 * is removed immediately; the page still cannot see this isolated world. */
function evaluateInPage(expression) {
  return new Promise((resolve, reject) => {
    const id = `__graff_eval_${Math.random().toString(36).slice(2)}`;
    const done = (e) => {
      if (e.data?.id !== id) return;
      window.removeEventListener("message", done);
      script.remove();
      if (e.data.ok) resolve(e.data.value ?? null);
      else reject(new Error(String(e.data.error || "evaluate failed")));
    };
    window.addEventListener("message", done);
    const script = document.createElement("script");
    script.textContent = `(function(){var id=${JSON.stringify(id)};try{var v=(0,eval)(${JSON.stringify(String(expression))});Promise.resolve(v).then(function(value){postMessage({id:id,ok:true,value:value??null},"*")},function(e){postMessage({id:id,ok:false,error:String(e&&e.message||e)},"*")})}catch(e){postMessage({id:id,ok:false,error:String(e&&e.message||e)},"*")}})();`;
    (document.documentElement || document.head).append(script);
    setTimeout(() => { window.removeEventListener("message", done); script.remove(); reject(new Error("evaluate timed out")); }, 15000);
  });
}

const handlers = {
  snapshot: () => compactSnapshot(),
  map: () => snapshot(),
  inspect: (p) => ({ ...describe(findTarget({ x: p.x, y: p.y })), url: location.href, title: document.title }),
  evaluate: (p) => evaluateInPage(p.expression).then((value) => ({ value })),
  click: (p) => { findTarget(p).click(); return { ok: true }; },
  fill: (p) => { setValue(findTarget(p), p.text ?? ""); return { ok: true }; },
  select: (p) => {
    const el = findTarget(p);
    if (!(el instanceof HTMLSelectElement)) throw new Error("Element is not a select");
    el.value = String(p.value ?? "");
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { ok: true };
  },
  scroll: (p) => { window.scrollBy(Number(p.dx) || 0, Number(p.dy) || 0); return { x: scrollX, y: scrollY }; },
  highlight: (p) => highlight(p),
  pick: (p) => { pickMode(p.enabled); return { ok: true }; },
  pins: (p) => { pins = Array.isArray(p.pins) ? p.pins.slice(0, 100) : []; renderPins(); return { ok: true }; },
  history: (p) => { history.go(Number(p.go)); return { ok: true }; },
};

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  (async () => {
    const fn = handlers[msg?.cmd];
    if (!fn) throw new Error(`Unknown page command: ${msg?.cmd}`);
    reply({ ok: true, result: await fn(msg.params) });
  })().catch((err) => reply({ ok: false, error: err instanceof Error ? err.message : String(err) }));
  return true;
});
