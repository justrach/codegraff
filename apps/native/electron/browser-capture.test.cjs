const { test, expect } = require('bun:test');
const { captureBrowser } = require('./browser-capture.cjs');
const { bounds } = require('./policy.cjs');
test('embedded view bounds follow application zoom and clamp to the window', () => {
  expect(bounds({ x: 100, y: 80, width: 300, height: 400 }, { width: 600, height: 700 }, 1.5))
    .toEqual({ x: 150, y: 120, width: 450, height: 580 });
});
test('capture reports image and CSS viewport geometry without revealing hidden pages', async () => {
  const wc = { isDestroyed: () => false,
    executeJavaScript: async () => ({ width: 400, height: 300, scrollX: 0, scrollY: 120 }),
    capturePage: async (rect, options) => {
      expect(rect).toBeUndefined(); expect(options).toEqual({ stayHidden: true, stayAwake: true });
      return { isEmpty: () => false, toPNG: () => Buffer.from('pixels'), getSize: () => ({ width: 800, height: 600 }) };
    } };
  const result = await captureBrowser(wc);
  expect(result.viewport.scrollY).toBe(120); expect(result.imageSize.width).toBe(800);
  expect(result.data).toBe(Buffer.from('pixels').toString('base64'));
});
test('empty browser images are errors, not successful image responses', async () => {
  await expect(captureBrowser({ isDestroyed: () => false,
    executeJavaScript: async () => ({ width: 400, height: 300 }),
    capturePage: async () => ({ isEmpty: () => true }) })).rejects.toThrow('empty screenshot');
});
test('native compositor failures retry without revealing the page and refresh viewport geometry', async () => {
  let captures = 0, reads = 0;
  const result = await captureBrowser({ isDestroyed: () => false,
    executeJavaScript: async () => ({ width: 400 + ++reads, height: 300, scrollX: 0, scrollY: reads }),
    capturePage: async (rect, options) => {
      expect(rect).toBeUndefined(); expect(options).toEqual({ stayHidden: true, stayAwake: true });
      if (++captures < 3) throw new Error('UnknownVizError');
      return { isEmpty: () => false, toPNG: () => Buffer.from('recovered pixels'), getSize: () => ({ width: 806, height: 600 }) };
    } });
  expect(captures).toBe(3); expect(reads).toBe(3);
  expect(result.viewport).toEqual({ width: 403, height: 300, scrollX: 0, scrollY: 3 });
  expect(result.data).toBe(Buffer.from('recovered pixels').toString('base64'));
});
test('a persistent native compositor failure stops after three capture attempts', async () => {
  let captures = 0;
  const failure = new Error('UnknownVizError');
  await expect(captureBrowser({ isDestroyed: () => false,
    executeJavaScript: async () => ({ width: 400, height: 300 }),
    capturePage: async () => { captures++; throw failure; } })).rejects.toBe(failure);
  expect(captures).toBe(3);
});
test('closed pages, ordinary errors and script failures are not retried', async () => {
  let captures = 0;
  await expect(captureBrowser({ isDestroyed: () => captures > 0,
    executeJavaScript: async () => ({ width: 400, height: 300 }),
    capturePage: async () => { captures++; throw new Error('UnknownVizError'); } })).rejects.toThrow('page closed');
  expect(captures).toBe(1);
  for (const message of ['Frame Gone', 'Timeout', 'Permission denied', 'Wrapped UnknownVizError']) {
    captures = 0;
    await expect(captureBrowser({ isDestroyed: () => false,
      executeJavaScript: async () => ({ width: 400, height: 300 }),
      capturePage: async () => { captures++; throw new Error(message); } })).rejects.toThrow(message);
    expect(captures).toBe(1);
  }
  let reads = 0;
  captures = 0;
  await expect(captureBrowser({ isDestroyed: () => false,
    executeJavaScript: async () => { reads++; throw new Error('UnknownVizError'); },
    capturePage: async () => { captures++; } })).rejects.toThrow('UnknownVizError');
  expect(reads).toBe(1); expect(captures).toBe(0);
});
