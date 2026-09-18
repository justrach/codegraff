const { test, expect } = require('bun:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { notchStore, createNotch } = require('./notch.cjs');

function fixture() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'graff-notch-'));
}

test('missing preference defaults on without creating files', () => {
  const directory = path.join(fixture(), 'nested');
  expect(notchStore(directory).load()).toBe(true);
  expect(fs.existsSync(directory)).toBe(false);
});

test('corrupt preference defaults on, and save roundtrips', () => {
  const directory = fixture();
  fs.writeFileSync(path.join(directory, 'observer-notch.json'), '{');
  const store = notchStore(directory);
  expect(store.load()).toBe(true);
  store.save(false);
  expect(JSON.parse(fs.readFileSync(path.join(directory, 'observer-notch.json'), 'utf8'))).toEqual({ enabled: false });
  expect(store.load()).toBe(false);
});

test('packaged checks never show the notch on the host desktop', () => {
  const calls = [];
  const notch = createNotch({
    native: { updateNotch: json => calls.push(json), hideNotch: () => calls.push('hide') },
    store: { load: () => true, save: () => {} },
    allow: false,
  });
  expect(notch.enabled()).toBe(false);
  expect(notch.setEnabled(true)).toBe(false);
  notch.update({ sessions: [] });
  expect(calls).toEqual(['hide']);
});

test('updates are dropped while hidden and clicks still activate', () => {
  const calls = [];
  const native = {
    updateNotch: json => calls.push(['update', json]),
    hideNotch: () => calls.push(['hide']),
    inspectNotch: () => '{"visible":false,"key":false}',
  };
  const selected = [];
  const notch = createNotch({
    native,
    store: { load: () => true, save: () => {} },
    activate: id => selected.push(id),
  });
  notch.update({ sessions: [{ id: 2, title: 'Live', state: 'working', label: 'Working', detail: '' }] });
  expect(calls[0][0]).toBe('update');
  notch.setEnabled(false);
  expect(calls.at(-1)).toEqual(['hide']);
  const before = calls.length;
  notch.update({ sessions: [{ id: 2, title: 'Live', state: 'waiting', label: 'Waiting', detail: '' }] });
  expect(calls.length).toBe(before + 1);
  expect(calls.at(-1)).toEqual(['hide']);
  notch.clicked(2);
  expect(selected).toEqual([2]);
  expect(notch.inspect()).toMatchObject({ visible: false, key: false });
});
