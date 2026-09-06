// Isolated-world picker: no privileged API is exposed to the visited page.
const { ipcRenderer } = require('electron');
let picking = false;
let outline, hint, markers, pins = [];
function pickMode(enabled) {
  picking = enabled;
  outline?.remove(); hint?.remove();
  if (!enabled) return;
  hint = document.createElement('div');
  hint.textContent = 'Click an element to pin · Esc to cancel';
  hint.style.cssText = 'position:fixed;top:12px;left:50%;transform:translateX(-50%);pointer-events:none;z-index:2147483647;background:#064e3b;color:white;border-radius:20px;padding:8px 14px;font:13px system-ui;white-space:nowrap;box-shadow:0 2px 12px #0003';
  document.documentElement.append(hint);
}
ipcRenderer.on('pick-mode', (_event, enabled) => pickMode(enabled));
ipcRenderer.on('pins-sync', (_event, next) => { pins = next; renderPins(); });
function renderPins() {
  markers?.remove();
  markers = document.createElement('div');
  markers.dataset.graffPins = '';
  markers.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483646';
  pins.forEach((pin, i) => {
    if (pin.url !== location.href) return;
    let el; try { el = document.querySelector(pin.element.selector); } catch { return; }
    if (!el) return;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height || r.bottom < 0 || r.top > innerHeight) return;
    const mark = document.createElement('div');
    mark.style.cssText = `position:absolute;left:${r.x}px;top:${r.y}px;width:${r.width}px;height:${r.height}px;border:2px solid #059669;border-radius:4px;box-sizing:border-box;background:#0596690a`;
    const badge = document.createElement('span'); badge.textContent = String(i + 1);
    badge.style.cssText = 'position:absolute;left:0;top:0;background:#064e3b;color:white;border-radius:12px;min-width:20px;height:20px;text-align:center;font:bold 12px/20px system-ui';
    mark.append(badge); markers.append(mark);
  });
  document.documentElement.append(markers);
}
let scheduled = false;
function schedulePins() {
  if (!pins.length || scheduled) return;
  scheduled = true; requestAnimationFrame(() => { scheduled = false; renderPins(); });
}
window.addEventListener('scroll', schedulePins, true);
window.addEventListener('resize', schedulePins);
document.addEventListener('keydown', event => {
  if (!picking || event.key !== 'Escape') return;
  event.preventDefault(); event.stopImmediatePropagation(); pickMode(false);
  ipcRenderer.send('browser-pick-cancelled');
}, true);
function selector(el) {
  const parts = [];
  for (let cur = el; cur && cur !== document.documentElement && parts.length < 8; cur = cur.parentElement) {
    if (cur.id) { parts.unshift(`#${CSS.escape(cur.id)}`); break; }
    const siblings = [...(cur.parentElement?.children || [])].filter(e => e.tagName === cur.tagName);
    parts.unshift(`${cur.tagName.toLowerCase()}:nth-of-type(${siblings.indexOf(cur) + 1})`);
  }
  return parts.join(' > ');
}
document.addEventListener('pointermove', event => {
  if (!picking || !(event.target instanceof Element)) return;
  const rect = event.target.getBoundingClientRect();
  if (!outline) {
    outline = document.createElement('div');
    outline.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #059669;border-radius:4px;box-sizing:border-box';
  }
  if (!outline.isConnected) document.documentElement.append(outline);
  Object.assign(outline.style, { left: `${rect.x}px`, top: `${rect.y}px`, width: `${rect.width}px`, height: `${rect.height}px` });
}, true);
for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) document.addEventListener(type, event => {
  if (picking) { event.preventDefault(); event.stopImmediatePropagation(); }
}, true);
document.addEventListener('click', event => {
  if (!picking || !(event.target instanceof Element)) return;
  event.preventDefault(); event.stopImmediatePropagation();
  const el = event.target, r = el.getBoundingClientRect();
  const text = (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  const rect = { x: r.x, y: r.y, w: r.width, h: r.height };
  ipcRenderer.send('browser-pin', {
    id: Date.now(), comment: '', url: location.href, title: document.title, ref: null,
    element: { tag: el.tagName.toLowerCase(), role: el.getAttribute('role') || '',
      name: el.getAttribute('aria-label') || el.getAttribute('alt') || text.slice(0, 80), text,
      selector: selector(el), href: el.closest('a')?.href || null, rect },
    point: { x: event.clientX, y: event.clientY },
    doc: { ...rect, x: r.x + scrollX, y: r.y + scrollY },
  });
  pickMode(false);
}, true);

let longTasks;
ipcRenderer.on('profile-enabled', (_event, enabled) => {
  longTasks?.disconnect();
  if (!enabled) return;
  longTasks = new PerformanceObserver(list => {
    for (const entry of list.getEntries()) ipcRenderer.send('profile-longtask', entry.duration);
  });
  longTasks.observe({ type: 'longtask', buffered: false });
});
