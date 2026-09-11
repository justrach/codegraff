// Test-only policy. Production windows must not import or inherit this policy.
const assert = require('node:assert/strict');
function createTestWindowPolicy({ app, BrowserWindow }, env = process.env, platform = process.platform) {
  const foreground = env.GRAFF_TEST_FOREGROUND === '1';
  const violations = [], observed = new Set();
  if (!foreground && platform === 'darwin') app.setActivationPolicy('prohibited');
  const guard = win => {
    if (observed.has(win)) return;
    observed.add(win);
    if (foreground) return;
    for (const event of ['show', 'focus']) win.on(event, () => violations.push(`Unexpected window ${event}`));
    // Fail before a test or cleanup path can expose or activate its window.
    for (const method of ['show', 'showInactive', 'focus', 'restore', 'maximize', 'setFullScreen']) {
      win[method] = () => { throw Error(`${method} requires GRAFF_TEST_FOREGROUND=1`); };
    }
  };
  app.on('browser-window-created', (_event, win) => guard(win));
  if (!foreground) app.focus = () => { throw Error('app.focus requires GRAFF_TEST_FOREGROUND=1'); };
  const options = value => ({ ...value, show: false, focusable: foreground,
    webPreferences: { ...value.webPreferences, ...(!foreground ? { backgroundThrottling: false } : {}) } });
  return {
    foreground,
    createWindow(value) {
      const win = new BrowserWindow(options(value)); guard(win); return win;
    },
    present(win) {
      if (foreground) { win.show(); win.focus(); }
    },
    assertSafe() {
      if (!foreground) {
        assert.deepEqual(violations, [], 'Background tests must never show or activate native windows');
        for (const win of BrowserWindow.getAllWindows()) {
          assert.equal(win.isVisible(), false, 'A background test window became visible');
          assert.equal(win.isFocused(), false, 'A background test window took native focus');
        }
      }
      return { mode: foreground ? 'foreground' : 'background', windows: observed.size, violations: [...violations] };
    },
    cleanup() {
      // Every window, including windows created by nested suites or failed steps.
      for (const win of BrowserWindow.getAllWindows()) win.destroy();
      assert.equal(BrowserWindow.getAllWindows().length, 0, 'Test windows remain after cleanup');
    },
  };
}
module.exports = { createTestWindowPolicy };
