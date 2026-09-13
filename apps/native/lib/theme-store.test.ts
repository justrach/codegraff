import { expect, test } from 'bun:test';
import { createThemeStore } from './theme-store';

test('many views share one observer, notify only for theme changes, and release it', () => {
  let dark = false, observers = 0, stops = 0, notifications = 0;
  let changed = () => {};
  const store = createThemeStore({ read: () => dark, observe(callback) {
    observers++; changed = callback; return () => { stops++; };
  } });
  expect(observers).toBe(0);
  const releases = Array.from({ length: 100 }, () => store.subscribe(() => { notifications++; }));
  expect(observers).toBe(1);
  changed(); expect(notifications).toBe(0);
  dark = true; changed();
  expect(store.getSnapshot()).toBe(true);
  expect(notifications).toBe(100);
  releases.slice(0, 99).forEach(release => release());
  expect(stops).toBe(0);
  dark = false; changed(); expect(notifications).toBe(101);
  releases[99](); expect(stops).toBe(1);
  dark = true;
  const release = store.subscribe(() => { notifications++; });
  expect(observers).toBe(2);
  changed(); expect(notifications).toBe(101);
  release(); expect(stops).toBe(2);
});
