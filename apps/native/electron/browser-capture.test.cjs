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
