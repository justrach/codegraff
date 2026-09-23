const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture({ accessibility = false, screenRecording = false, enabled = true, platform = 'darwin', choose = 'Cancel' } = {}) {
  const calls = [], dialogs = [], opened = [];
  const electron = {
    dialog: { showMessageBox: async (_, options) => {
      dialogs.push(options);
      return { response: options.buttons.indexOf(choose) };
    } },
    shell: { openExternal: async url => { opened.push(url); } },
  };
  const module = { exports: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'computer.cjs'), 'utf8'), {
    module, process: { platform }, require: name => name === 'electron' ? electron : require(name),
  });
  const computer = new module.exports.ComputerUse('', {});
  computer.enabled = enabled;
  computer.native = method => {
    calls.push(method);
    return method === 'permissions' ? { accessibility, screenRecording } : { ok: true };
  };
  return { computer, calls, dialogs, opened };
}

test('computer status separates actions by their actual permission requirements', () => {
  for (const accessibility of [false, true]) for (const screenRecording of [false, true]) {
    const { computer, calls } = fixture({ accessibility, screenRecording });
    const status = computer.status();
    assert.equal(status.accessibility, accessibility);
    assert.equal(status.screenRecording, screenRecording);
    assert.ok(status.readyActions.includes('status'));
    assert.ok(status.readyActions.includes('apps'));
    assert.equal(status.readyActions.includes('screenshot'), screenRecording);
    for (const action of ['snapshot', 'activate', 'press', 'setValue', 'click', 'type', 'key', 'scroll']) {
      assert.equal(status.readyActions.includes(action), accessibility, action);
      if (!accessibility) assert.match(status.blockedActions[action], /Accessibility.*then retry/);
    }
    if (!screenRecording) assert.match(status.blockedActions.screenshot, /Screen Recording.*then relaunch/);
    assert.deepEqual(calls, ['permissions'], 'status must never request a grant');
  }
});

test('disabled and unsupported computer status never advertises usable actions', () => {
  for (const platform of ['darwin', 'linux']) {
    const { computer, calls } = fixture({ enabled: false, platform, accessibility: true, screenRecording: true });
    const status = computer.status();
    assert.equal(status.readyActions.join(','), 'status');
    assert.equal(Object.keys(status.blockedActions).length, 10);
    assert.match(status.blockedActions.apps, platform === 'darwin' ? /Enable Computer use/ : /macOS only/);
    assert.deepEqual(calls, platform === 'darwin' ? ['permissions'] : []);
  }
});

test('blocked commands return exactly the remedy reported by status', async () => {
  for (const action of ['snapshot', 'click', 'screenshot']) {
    const { computer, calls } = fixture();
    const status = await computer.command('status');
    await assert.rejects(computer.command(action), error => error.message === status.blockedActions[action]);
    assert.ok(calls.every(method => method === 'permissions'), 'blocked commands must not execute native input or capture');
  }
});

test('app listing and Accessibility snapshots still work without screen recording', async () => {
  const { computer, calls } = fixture({ accessibility: true });
  assert.equal((await computer.command('apps')).ok, true);
  assert.equal((await computer.command('snapshot', { pid: 123 })).ok, true);
  assert.ok(calls.includes('apps'));
  assert.ok(calls.includes('snapshot'));
  await assert.rejects(computer.command('requestPermissions'), /Unsupported computer action/);
  assert.ok(!calls.includes('requestPermissions'));
});

test('permissions dialog offers only missing settings panes and opens the matching one', async () => {
  for (const accessibility of [false, true]) for (const screenRecording of [false, true]) {
    const options = [
      ['Open Accessibility Settings', !accessibility, 'Privacy_Accessibility'],
      ['Open Screen Recording Settings', !screenRecording, 'Privacy_ScreenCapture'],
    ];
    for (const [choose, missing, pane] of options) {
      const { computer, dialogs, opened, calls } = fixture({ accessibility, screenRecording, enabled: false, choose: missing ? choose : 'Cancel' });
      await computer.configure();
      assert.equal(dialogs[0].buttons.includes(choose), missing);
      assert.equal(dialogs[0].buttons[dialogs[0].cancelId], 'Cancel');
      assert.deepEqual(opened, missing ? [`x-apple.systempreferences:com.apple.preference.security?${pane}`] : []);
      assert.equal(computer.enabled, false, 'opening Settings must not enable agent access');
      assert.ok(!calls.includes('requestPermissions'));
      if (!accessibility) assert.match(dialogs[0].detail, /Accessibility.*then retry/);
      if (!screenRecording) assert.match(dialogs[0].detail, /Screen Recording.*then relaunch/);
    }
  }
});

test('only confirming Enable requests permissions; cancel and disable preserve consent boundaries', async () => {
  for (const [enabled, choose, expected] of [[false, 'Enable computer use', true], [true, 'Disable computer use', false], [false, 'Cancel', false]]) {
    const { computer, calls, opened } = fixture({ enabled, choose });
    await computer.configure();
    assert.equal(computer.enabled, expected);
    assert.equal(calls.filter(method => method === 'requestPermissions').length, expected ? 1 : 0);
    assert.deepEqual(opened, []);
  }
});
