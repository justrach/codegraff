const { test, expect } = require('bun:test');
const { EventEmitter } = require('node:events');
const { createTestWindowPolicy } = require('./test-window-policy.cjs');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
function fixture(env = {}) {
  const app = new EventEmitter(), calls = [], windows = new Set();
  app.setActivationPolicy = value => calls.push(value);
  app.focus = () => calls.push('app.focus');
  class Window extends EventEmitter {
    constructor(options) { super(); this.options = options; windows.add(this); app.emit('browser-window-created', {}, this); }
    static getAllWindows() { return [...windows]; }
    show() { this.visible = true; this.emit('show'); }
    focus() { this.focused = true; this.emit('focus'); }
    isVisible() { return !!this.visible; }
    isFocused() { return !!this.focused; }
    destroy() { windows.delete(this); }
  }
  return { policy: createTestWindowPolicy({ app, BrowserWindow: Window }, env, 'darwin'), app, calls, Window };
}
test('#832: every background test window rejects native activation, including cleanup paths', () => {
  const { policy, app, calls } = fixture();
  const a = policy.createWindow({ show: true, focusable: true, webPreferences: { sandbox: true, backgroundThrottling: true } });
  const b = policy.createWindow({});
  expect(calls).toEqual(['prohibited']);
  expect(a.options).toMatchObject({ show: false, focusable: false, webPreferences: { sandbox: true, backgroundThrottling: false } });
  policy.present(a); policy.present(b);
  for (const action of ['show', 'showInactive', 'focus', 'restore', 'maximize', 'setFullScreen']) {
    expect(() => b[action](true)).toThrow('GRAFF_TEST_FOREGROUND=1');
  }
  expect(() => app.focus()).toThrow('GRAFF_TEST_FOREGROUND=1');
  expect(policy.assertSafe()).toEqual({ mode: 'background', windows: 2, violations: [] });
  policy.cleanup();
  expect(policy.assertSafe().violations).toEqual([]);
});
test('#832: one exact opt-in enables foreground checks; unrelated flags never enable them', () => {
  for (const env of [{ GRAFF_TEST_FOREGROUND: '0' }, { GRAFF_TEST_FOREGROUND: 'true' }, { GRAFF_PERFORMANCE_TESTS: '1' }, { GRAFF_ELECTRON_SMOKE: '/tmp/report' }]) {
    const { policy } = fixture(env);
    expect(policy.foreground).toBe(false); policy.cleanup();
  }
  const { policy, calls } = fixture({ GRAFF_TEST_FOREGROUND: '1' });
  const win = policy.createWindow({}); policy.present(win);
  expect(calls).toEqual([]); expect(win.isVisible()).toBe(true); expect(win.isFocused()).toBe(true);
  expect(policy.assertSafe().mode).toBe('foreground'); policy.cleanup();
});
test('#832: unsolicited show/focus events fail verification and all failed-suite windows are cleaned up', () => {
  const { policy, Window } = fixture();
  const win = policy.createWindow({});
  win.emit('focus');
  expect(() => policy.assertSafe()).toThrow('must never show or activate');
  policy.createWindow({});
  policy.cleanup();
  expect(Window.getAllWindows()).toEqual([]);
});

test('#832: all GUI test modules use the shared window and input policy', () => {
  // Parse actual calls, not renderer JS embedded in fixture strings: focusing a
  // DOM control is expected, activating a native test window is not.
  const files = fs.readdirSync(__dirname).filter(name => /visual|smoke|performance-(benchmark|scenarios)/.test(name) && name.endsWith('.cjs') && !name.endsWith('.test.cjs'));
  const bypasses = [];
  for (const name of files) {
    const source = ts.createSourceFile(name, fs.readFileSync(path.join(__dirname, name), 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const visit = node => {
      if (ts.isNewExpression(node) && /BrowserWindow$/.test(node.expression.getText(source))) bypasses.push(`${name}: direct BrowserWindow`);
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
        const owner = node.expression.expression.getText(source), method = node.expression.name.text;
        if (method === 'sendInputEvent' || (['show', 'showInactive', 'focus', 'restore', 'maximize'].includes(method) && /^(win|fixtureWindow|app)$/.test(owner))) {
          bypasses.push(`${name}: ${owner}.${method}`);
        }
        if (method === 'setFullScreen' || (owner === 'computer' && method === 'command' && node.arguments[0]?.text === 'type')) {
          let parent = node.parent, guarded = false;
          while (parent) {
            if (ts.isIfStatement(parent) && /testDesktop.foreground|checkedFullscreen/.test(parent.expression.getText(source))) guarded = true;
            parent = parent.parent;
          }
          if (!guarded) bypasses.push(`${name}: unguarded native ${method}`);
        }
      }
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  expect(bypasses).toEqual([]);
});
