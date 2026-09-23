import {test} from 'node:test';
import assert from 'node:assert/strict';
import {prompt} from './acp-client';
import {createPromptRunner} from '../components/site/harness-prompt-runner';
import {createQueueSteerer} from './prompt-queue-steer';
const chunk = {method:'session/update',params:{sessionId:'test',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'Visible partial reply'}}}};
async function withWire(lines:unknown[], body:(received:unknown[])=>Promise<void>) {
  const original=globalThis.fetch, received:unknown[]=[];
  globalThis.fetch=async()=>new Response(lines.map(line=>JSON.stringify(line)).join('\n')+'\n');
  try {await body(received);} finally {globalThis.fetch=original;}
}
test('a disconnected stream preserves partial output and reports interruption',async()=>{
  await withWire([chunk],async received=>{
    await assert.rejects(async()=>{for await(const update of prompt('test','test','hello'))received.push(update);},/ended before/);
    assert.deepEqual(received,[chunk.params.update]);
  });
});
test('a cancelled turn produces a terminal event instead of a hanging spinner',async()=>{
  await withWire([chunk,{id:1,result:{stopReason:'cancelled'}}],async received=>{
    for await(const update of prompt('test','test','hello'))received.push(update);
    assert.deepEqual(received.at(-1),{sessionUpdate:'gui_turn_end',stopReason:'cancelled'});
  });
});
test('a bridge error is surfaced after any already delivered text',async()=>{
  await withWire([chunk,{id:1,error:{message:'Agent exited'}}],async received=>{
    await assert.rejects(async()=>{for await(const update of prompt('test','test','hello'))received.push(update);},/Agent exited/);
    assert.equal(received.length,1);
  });
});
test('an actual connection loss names the interrupted response and preserves delivered text', async () => {
  const original = globalThis.fetch;
  let reads = 0;
  globalThis.fetch = async () => new Response(new ReadableStream({
    pull(controller) {
      if (reads++ === 0) controller.enqueue(new TextEncoder().encode(JSON.stringify(chunk) + '\n'));
      else controller.error(new TypeError('network error'));
    },
  }));
  const received: unknown[] = [];
  try {
    await assert.rejects(async () => {
      for await (const update of prompt('test', 'test', 'hello')) received.push(update);
    }, /connection to Graff ended before the turn finished/);
    assert.deepEqual(received, [chunk.params.update]);
  } finally { globalThis.fetch = original; }
});
test('a terminal reply is authoritative even if the connection fails immediately afterward', async () => {
  const original = globalThis.fetch;
  let reads = 0;
  globalThis.fetch = async () => new Response(new ReadableStream({
    pull(controller) {
      if (reads++ === 0) controller.enqueue(new TextEncoder().encode(JSON.stringify({id:1,result:{stopReason:'end_turn'}}) + '\n'));
      else controller.error(new TypeError('network error'));
    },
  }));
  try {
    const received: unknown[] = [];
    for await (const update of prompt('test', 'test', 'hello')) received.push(update);
    assert.deepEqual(received, [{sessionUpdate:'gui_turn_end',stopReason:'end_turn'}]);
  } finally { globalThis.fetch = original; }
});

test('prompt catalog refresh follows configuration updates once after this chat turn', async () => {
  const savedFetch = globalThis.fetch;
  const savedWindow = globalThis.window;
  const savedFrame = globalThis.requestAnimationFrame;
  const savedCancelFrame = globalThis.cancelAnimationFrame;
  globalThis.window = { localStorage: { setItem() {} } } as unknown as Window & typeof globalThis;
  globalThis.requestAnimationFrame = callback => setTimeout(callback, 0) as unknown as number;
  globalThis.cancelAnimationFrame = id => clearTimeout(id);
  const update = { method: 'session/update', params: { sessionId: 's1', update: { sessionUpdate: 'config_option_update', configOptions: [] } } };
  const terminal = { id: 1, result: { stopReason: 'end_turn' } };
  let lines: unknown[] = [];
  globalThis.fetch = async () => new Response(lines.map(line => JSON.stringify(line)).join('\n') + '\n');
  try {
    const run = async (text: string, reply: unknown[], current = true) => {
      lines = reply;
      const chatsRef = { current: [{ id: 1, title: 'Existing chat', messages: [] }] };
      const runningRef = { current: new Set<number>() };
      const msgIdRef = { current: 0 };
      let refreshes = 0;
      const steerer = createQueueSteerer({ getQueue: () => [], setQueue: () => {}, status: () => {} });
      const runner = createPromptRunner({
        onStarted() {}, onCompleted() {}, runningRef, steerer, setFollowing() {}, chatsRef,
        model: null, msgIdRef, setChats: action => { chatsRef.current = typeof action === 'function' ? action(chatsRef.current) : action; },
        setCancelError() {}, setBusyFor() {}, setHistory() {}, pinsRef: { current: {} },
        handleOf: id => `test:${id}`, setPins() {}, requireSession: async () => 's1',
        sessionIsCurrent: (id, sessionId) => current && id === 1 && sessionId === 's1',
        prepareModel: async () => {}, adoptCatalog: async () => {
          assert.equal(runningRef.current.has(1), false, 'refresh starts after turn cleanup');
          refreshes++;
        }, refreshStored: async () => {}, takeQueuedPrompt: () => undefined,
      });
      await runner(1, text);
      return refreshes;
    };
    assert.equal(await run('ordinary prompt', [update, update, terminal]), 1, 'repeated updates coalesce');
    assert.equal(await run('ordinary prompt', [terminal]), 0, 'unrelated turns do not refresh');
    assert.equal(await run('/effort high', [terminal]), 1, 'existing slash refresh remains');
    assert.equal(await run('/effort high', [update, terminal]), 1, 'slash and update still refresh once');
    assert.equal(await run('/effort high', [{ id: 1, error: { code: -32603, message: 'rejected' } }]), 0, 'rejected slash change does not refresh');
    assert.equal(await run('ordinary prompt', [update, { id: 1, result: { stopReason: 'cancelled' } }]), 1, 'cancelled turn still reconciles a reported change');
    assert.equal(await run('ordinary prompt', [update, { id: 1, error: { code: -32603, message: 'stopped' } }]), 1, 'later failure still reconciles a reported change');
    assert.equal(await run('ordinary prompt', [update, terminal], false), 0, 'replaced session cannot refresh another worker');
  } finally {
    globalThis.fetch = savedFetch;
    globalThis.window = savedWindow;
    globalThis.requestAnimationFrame = savedFrame;
    globalThis.cancelAnimationFrame = savedCancelFrame;
  }
});
