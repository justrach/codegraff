const selector = '[data-chat], [data-tab-id]';
const key = (element: HTMLElement) => element.hasAttribute('data-chat') ? `pane:${element.dataset.chat}` : `tab:${element.dataset.tabId}`;
export function captureTabLayout() {
  return new Map(Array.from(document.querySelectorAll<HTMLElement>(selector), element => [key(element), element.getBoundingClientRect()]));
}
/** Animate the committed layout, never intermediate React state or a cloned chat. */
export function settleTabLayout(before: ReturnType<typeof captureTabLayout>) {
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return [];
  const animations: Animation[] = [];
  for (const element of document.querySelectorAll<HTMLElement>(selector)) {
    const previous = before.get(key(element)), next = element.getBoundingClientRect();
    if (!next.width || !next.height) continue;
    if (previous?.width && previous.height) {
      const dx = previous.left-next.left, dy = previous.top-next.top;
      const sx = previous.width/next.width, sy = previous.height/next.height;
      if (Math.abs(dx)+Math.abs(dy)+Math.abs(sx-1)+Math.abs(sy-1) < 0.01) continue;
      animations.push(element.animate([
        { transformOrigin: 'top left', transform: `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})` },
        { transformOrigin: 'top left', transform: 'none' },
      ], { duration: 320, easing: 'cubic-bezier(.22, 1, .36, 1)' }));
    } else if (element.hasAttribute('data-chat')) {
      animations.push(element.animate([
        { opacity: 0, transform: 'translateY(14px) scale(.985)' },
        { opacity: 1, transform: 'none' },
      ], { duration: 280, easing: 'cubic-bezier(.22, 1, .36, 1)' }));
    }
  }
  return animations;
}
