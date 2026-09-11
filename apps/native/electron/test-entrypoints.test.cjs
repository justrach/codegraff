const { test, expect } = require('bun:test');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');

// Catch the original #832 failure mode: a new test bypasses the shared helper.
// Parse code so strings containing renderer .focus() are not mistaken for OS focus.
test('every test BrowserWindow constructor uses the enforced options', () => {
  let checked = 0;
  for (const name of fs.readdirSync(__dirname).filter(n => n.endsWith('.cjs') && !n.endsWith('.test.cjs') && n !== 'main.cjs' && n !== 'test-window-policy.cjs')) {
    const source = ts.createSourceFile(name, fs.readFileSync(path.join(__dirname, name), 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const visit = node => {
      if (ts.isNewExpression(node) && node.expression.getText(source) === 'BrowserWindow') {
        checked++;
        expect(node.arguments?.[0]?.getText(source), name).toMatch(/testWindowOptions\(/);
      }
      if (ts.isCallExpression(node) && /(?:^|\.)createWindow$/.test(node.expression.getText(source))) checked++;
      ts.forEachChild(node, visit);
    };
    visit(source);
  }
  expect(checked).toBeGreaterThanOrEqual(9);
});

test('standalone Electron test entry points install policy before waiting for readiness', () => {
  for (const name of ['visual-tests.cjs', 'performance-benchmark.cjs', 'gui-coding-smoke.cjs', 'test-window-probe.cjs', 'native-gui.cjs']) {
    const source = fs.readFileSync(path.join(__dirname, name), 'utf8');
    const install = source.search(/installTestWindowPolicy\(app\)|require\('\.\/test-desktop\.cjs'\)/);
    expect(install, name).toBeGreaterThanOrEqual(0);
    expect(install, name).toBeLessThan(source.indexOf('app.whenReady()'));
  }
});
