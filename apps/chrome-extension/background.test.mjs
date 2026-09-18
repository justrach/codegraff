import test from 'node:test';
import assert from 'node:assert/strict';
const listeners = {};
const event = name => ({addListener: fn => listeners[name] = fn});
const calls = [];
const host = {onMessage: event('message'), onDisconnect: event('hostDisconnect'), postMessage() {}};
globalThis.chrome = {
  runtime: {connectNative: () => host},
  action: {onClicked: event('click'), setBadgeText: async () => {}, setBadgeBackgroundColor: async () => {}, setTitle: async () => {}},
  debugger: {attach: async () => {}, detach: async () => {}, onDetach: event('detach'), sendCommand: async (...args) => {calls.push(args); return {}; }},
  tabs: {get: async id => ({id, url: 'https://example.test', title: 'Test'}), onRemoved: event('removed'), onUpdated: event('updated')},
};
const {execute} = await import('./background.js');
test('only user-connected tabs are actionable; navigation and detach revoke access', async () => {
  await assert.rejects(execute({name: 'chrome_click', arguments: {tabId: 7, x: 1, y: 2}}), /not connected/);
  await listeners.click({id: 7, url: 'https://example.test'});
  assert.equal((await execute({name: 'chrome_tabs'})).length, 1);
  await execute({name: 'chrome_click', arguments: {tabId: 7, x: 1, y: 2}});
  assert.deepEqual(calls.map(c => c[2].type), ['mousePressed', 'mouseReleased']);
  await assert.rejects(execute({name: 'chrome_type', arguments: {tabId: 7, text: 123}}), /Text/);
  await assert.rejects(execute({name: 'arbitrary_cdp', arguments: {tabId: 7}}), /Unknown/);
  listeners.updated(7, {status: 'loading'});
  await assert.rejects(execute({name: 'chrome_snapshot', arguments: {tabId: 7}}), /not connected/);
  await listeners.click({id: 7, url: 'https://example.test'});
  listeners.detach({tabId: 7});
  assert.deepEqual(await execute({name: 'chrome_tabs'}), []);
});
