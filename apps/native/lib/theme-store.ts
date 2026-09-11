/** One observer per mounted application, shared by Markdown and diagram views. */
export function createThemeStore(source: { read(): boolean; observe(changed: () => void): () => void }) {
  const listeners = new Set<() => void>();
  let stop: (() => void) | undefined, previous = false;
  return {
    getSnapshot: source.read,
    subscribe(listener: () => void) {
      listeners.add(listener);
      if (!stop) {
        previous = source.read();
        stop = source.observe(() => {
          const next = source.read();
          if (next === previous) return;
          previous = next; listeners.forEach(notify => notify());
        });
      }
      return () => { listeners.delete(listener); if (!listeners.size) { stop?.(); stop = undefined; } };
    },
  };
}

export const themeStore = createThemeStore({
  read: () => typeof document !== 'undefined' && document.documentElement.classList.contains('dark'),
  observe(changed) {
    const observer = new MutationObserver(changed);
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    return () => observer.disconnect();
  },
});
