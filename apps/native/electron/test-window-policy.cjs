// Test-only policy. Production windows must not import or inherit this policy.
const assert = require('node:assert/strict');
function createTestWindowPolicy({ app, BrowserWindow }, env = process.env, platform = process.platform) {
  const { testWindowMode, testWindowOptions, presentWindow, installTestWindowPolicy } = require('./test-window.cjs');
  const mode = testWindowMode(env), foreground = mode === 'foreground';
  const violations = [], observed = new Set();
  installTestWindowPolicy(app, env, platform);
  const guard = win => {
    if (observed.has(win)) return;
    observed.add(win);
    if (foreground) return;
    for (const event of mode === 'hidden' ? ['show', 'focus'] : ['focus']) {
      win.on(event, () => violations.push(`Unexpected window ${event}`));
    }
  };
  app.on('browser-window-created', (_event, win) => guard(win));
  const options = value => testWindowOptions(value, env);
  return {
    foreground,
    createWindow(value) {
      const win = new BrowserWindow(options(value)); guard(win); return win;
    },
    present(win) {
      presentWindow(win, app, undefined, env);
    },
    assertSafe() {
      if (!foreground) {
        assert.deepEqual(violations, [], 'Background tests must never show or activate native windows');
        for (const win of BrowserWindow.getAllWindows()) {
          if (mode === 'hidden') assert.equal(win.isVisible(), false, 'A background test window became visible');
          assert.equal(win.isFocused(), false, 'A background test window took native focus');
        }
      }
      return { mode: mode === 'hidden' ? 'background' : mode, windows: observed.size, violations: [...violations] };
    },
    cleanup() {
      // Every window, including windows created by nested suites or failed steps.
      for (const win of BrowserWindow.getAllWindows()) win.destroy();
      assert.equal(BrowserWindow.getAllWindows().length, 0, 'Test windows remain after cleanup');
    },
  };
}
module.exports = { createTestWindowPolicy };
