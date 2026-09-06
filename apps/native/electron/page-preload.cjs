// Isolated-world picker: no privileged API is exposed to the visited page.
const { ipcRenderer } = require('electron');
let picking = false;
let outline;
ipcRenderer.on('pick-mode', (_event, enabled) => {
  picking = enabled;
  if (!picking) outline?.remove();
});
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
  picking = false; outline?.remove();
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
