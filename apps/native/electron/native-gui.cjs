const testDesktop = require('./test-desktop.cjs');
const { app, screen } = require('electron');
const { ComputerUse } = require('./computer.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const resources = process.argv[2];
const output = process.env.GRAFF_NATIVE_OUTPUT || path.resolve(__dirname, '../../../zig-out/native-tests');
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-native-test-'));
app.setPath('userData', profile);
const report = { status: 'running', passed: [], skipped: [] };
let win, finished = false;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const wait = async (condition, message) => {
  for (let n = 0; n < 150; n++) { if (await condition()) return; await sleep(100); }
  throw Error(message);
};
const deadline = setTimeout(() => finish(Error('Native GUI checks timed out')), 60000);
function finish(error) {
  if (finished) return;
  finished = true; clearTimeout(deadline);
  report.status = error ? 'failed' : report.skipped.length ? 'passed-with-skips' : 'passed';
  if (error) { report.error = error.message; console.error(error); }
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'native-results.json'), JSON.stringify(report, null, 2));
  testDesktop.cleanup(); fs.rmSync(profile, { recursive: true, force: true });
  app.exit(error ? 1 : 0);
}
app.whenReady().then(async () => {
  assert.ok(testDesktop.foreground, 'Native checks need an isolated foreground desktop');
  assert.ok(screen.getAllDisplays().some(display => display.bounds.width > 0 && display.bounds.height > 0), 'CI has no usable display');
  const native = require(path.join(resources, 'native/activity.node'));
  const probe = require(path.join(resources, 'native/test-window-probe.node'));
  win = testDesktop.createWindow({ width: 900, height: 720, webPreferences: { sandbox: true } });
  const wc = win.webContents, handle = win.getNativeWindowHandle();
  const inspect = () => JSON.parse(probe.inspect(handle));
  await wc.loadURL('data:text/html,<title>Native test</title><input aria-label="Native input" id="input"><p>Isolated native GUI fixture</p>');
  testDesktop.present(win);
  await wait(() => { const state = inspect(); return state.active && state.visible && state.key && state.screens > 0; }, 'CI cannot activate a native window; a graphical login session is required');
  report.passed.push('graphical session and native window focus');
  for (let n = 0; n < 2; n++) {
    native.show(handle, JSON.stringify({ rssMiB: 64, cpuPercent: 0, processes: 1, browsers: 0 }));
    await wait(() => { const state = inspect(); return state.sheetAttached && state.sheetVisible && state.sheetKey; }, 'The production Activity sheet did not become visible and key');
    const state = inspect();
    assert.equal(state.sheetTitle, 'Activity');
    assert.ok(state.sheetWidth >= 400 && state.sheetHeight > 200, 'The SwiftUI sheet has no usable content area');
    probe.pressReturn(handle);
    await wait(() => !inspect().sheetAttached, 'Return did not activate the Activity sheet Done button');
  }
  report.passed.push('production SwiftUI sheet presentation, Done key, dismissal and reopening');
  const computer = new ComputerUse(resources, win);
  const permissions = computer.status();
  report.permissions = { accessibility: permissions.accessibility, screenRecording: permissions.screenRecording };
  computer.enabled = true;
  try {
    if (permissions.accessibility) {
      testDesktop.present(win);
      await wc.executeJavaScript('document.querySelector("input").focus()');
      const tree = await computer.command('snapshot', { pid: process.pid });
      assert.ok(tree.elements.length > 0);
      await computer.command('type', { pid: process.pid, text: 'native-input' });
      await wait(() => wc.executeJavaScript('document.querySelector("input").value === "native-input"'), 'Native OS typing did not reach the test window');
      report.passed.push('native Accessibility snapshot and OS typing');
    } else report.skipped.push('native Accessibility snapshot and OS typing: Accessibility permission unavailable');
    if (permissions.screenRecording) {
      const capture = await computer.command('screenshot');
      assert.ok(capture.data.length > 100);
      report.passed.push('native display capture');
    } else report.skipped.push('native display capture: Screen Recording permission unavailable');
  } finally { computer.enabled = false; }
  for (const reason of report.skipped) console.log(`SKIP: ${reason}`);
  if (process.env.GRAFF_NATIVE_REQUIRE_OS_INPUT === '1') assert.deepEqual(report.skipped, [], 'This runner must have preconfigured OS permissions');
  console.log('Native GUI checks:', JSON.stringify(report));
}).then(() => finish()).catch(finish);
process.on('SIGTERM', () => finish(Error('Native tests interrupted')));
process.on('SIGINT', () => finish(Error('Native tests interrupted')));
