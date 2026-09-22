// Production UI regression with synthetic ACP responses; no model/network calls.
// Start the built app, then: node scripts/test-model-catalog.mjs http://127.0.0.1:PORT
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
import net from 'node:net';
const { installGalleryFixture } = createRequire(import.meta.url)('../electron/gallery-fixture.cjs');
let origin = process.argv[2], server;
if (!origin) {
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  origin = `http://127.0.0.1:${port}`;
  server = spawn(process.execPath, ['node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', String(port)], { stdio: 'ignore', env: { ...process.env, GRAFF_DESKTOP_TOKEN: '' } });
}
const browser = await chromium.launch({ headless: true });
try {
  for (let attempt = 0; attempt < 100; attempt++) {
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(1000) })).ok) break; } catch {}
    if (attempt === 99) throw Error('Model catalog test server did not start');
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  await context.addInitScript({ content: `(${installGalleryFixture.toString()})();(${installCatalogFixture.toString()})();` });
  await context.route('**/*', route => {
    const url = new URL(route.request().url());
    return url.origin === origin && !url.pathname.startsWith('/api/') ? route.continue() : route.abort();
  });
  const page = await context.newPage();
  await page.goto(origin);
  const retry = page.getByRole('button', { name: 'Retry', exact: true });
  await retry.waitFor();
  await retry.click();
  const effort = page.getByRole('button', { name: 'Select effort', exact: true });
  await effort.waitFor();
  assert.match(await effort.innerText(), /Medium/);
  const beforeOpen = await page.evaluate(() => window.catalogReads);
  await page.getByRole('button', { name: 'Choose model', exact: true }).click();
  await page.waitForFunction(before => window.catalogReads > before, beforeOpen);
  await page.getByRole('option').filter({ hasText: 'gpt-sol' }).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Choose model"]')?.getAttribute('data-model') === 'gpt-sol');
  await effort.waitFor();
  const setEffort = async key => {
    await effort.click();
    const range = page.getByRole('slider', { name: 'Reasoning effort level' });
    await range.focus();
    await range.press(key);
    await page.waitForFunction(expected => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes(expected), key === 'End' ? 'High' : 'Light').catch(async error => {
      console.error(await page.evaluate(() => ({ body: document.body.innerText, calls: window.catalogCalls.filter(call => call.method !== 'session/idle') })));
      throw error;
    });
    await page.waitForFunction(() => !document.querySelector('[role="status"]')?.textContent?.includes('Saving'));
    await page.keyboard.press('Escape');
  };
  await setEffort('End');
  await checkEffortTransitions(page);
  await page.waitForFunction(() => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes('High'));
  const first = await page.locator('[data-tab-id]').first().getAttribute('data-tab-id');
  await page.getByRole('button', { name: 'New chat', exact: true }).click();
  await setEffort('Home');
  await page.waitForFunction(() => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes('Light'));
  const second = await page.locator('[data-tab-id]').last().getAttribute('data-tab-id');
  assert.notEqual(first, second);
  await page.locator(`[data-tab-id="${first}"]`).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes('High'));
  await page.locator(`[data-tab-id="${second}"]`).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes('Light'));
  await page.evaluate(() => { window.holdEffort = true; });
  await effort.click(); await page.getByRole('slider', { name: 'Reasoning effort level' }).press('ArrowRight');
  await page.waitForFunction(() => window.effortReplies.length === 1);
  await page.keyboard.press('Escape'); await page.locator(`[data-tab-id="${first}"]`).click();
  assert.match(await effort.innerText(), /High/);
  await page.evaluate(() => window.effortReplies.shift()(false));
  await page.locator(`[data-tab-id="${second}"]`).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Select effort"]')?.textContent?.includes('Medium'));
  await page.locator(`[data-tab-id="${first}"]`).click(); assert.match(await effort.innerText(), /High/);
  await page.locator(`[data-tab-id="${second}"]`).click();
  await page.evaluate(() => { window.holdEffort = false; }); await setEffort('Home');
  const composer = page.getByRole('textbox', { name: 'Prompt', exact: true });
  await composer.fill('hold fixture'); await composer.press('Enter');
  await page.waitForFunction(() => typeof window.finishCatalogTurn === 'function');
  const before = await page.evaluate(() => window.catalogCalls.filter(call => call.method === 'bootstrap' || call.method === 'session/cancel').length);
  const beforeRunningOpen = await page.evaluate(() => window.catalogReads);
  await page.getByRole('button', { name: 'Choose model', exact: true }).click();
  await page.waitForFunction(before => window.catalogReads > before, beforeRunningOpen);
  await page.getByRole('option').filter({ hasText: 'gpt-astra' }).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Choose model"]')?.textContent?.includes('Next'));
  assert.equal(await page.evaluate(() => window.catalogCalls.filter(call => call.method === 'bootstrap' || call.method === 'session/cancel').length), before, 'Selection interrupted the running worker');
  await composer.fill('queued next model'); await composer.press('Enter');
  await page.evaluate(() => window.finishCatalogTurn());
  await page.waitForFunction(() => window.catalogCalls.some(call => call.method === 'session/prompt' && call.params.prompt[0]?.text === 'queued next model'));
  const calls = await page.evaluate(() => window.catalogCalls.filter(call => ['bootstrap', 'session/cancel', 'session/prompt'].includes(call.method)));
  const queued = calls.findIndex(call => call.method === 'session/prompt' && call.params.prompt[0]?.text === 'queued next model');
  assert.equal(calls.slice(0, queued).findLast(call => call.method === 'bootstrap')?.params.model, 'gpt-astra');
  assert.equal(calls.filter(call => call.method === 'session/cancel').length, 0);
  await page.waitForFunction(() => !document.querySelector('[aria-label="Choose model"]')?.textContent?.includes('Next'));
  console.log('Model catalog UI: retry, capability refresh, per-chat effort, and queued next-model selection passed');
} finally { await browser.close(); server?.kill('SIGTERM'); }

async function checkEffortTransitions(page) {
  const effort = page.getByRole('button', { name: 'Select effort', exact: true });
  const range = page.getByRole('slider', { name: 'Reasoning effort level' });
  const resets = () => page.evaluate(() => window.catalogCalls.filter(call => ['bootstrap', 'session/cancel'].includes(call.method)).length);
  const before = await resets();
  await page.evaluate(() => { window.holdEffort = true; });
  await effort.click(); await range.press('Home');
  await page.waitForFunction(() => window.effortReplies.length === 1);
  const stable = async (name, value) => {
    const frames = await page.evaluate(async () => {
      const samples = [];
      for (let i = 0; i < 8; i++) {
        await new Promise(requestAnimationFrame);
        const input = document.querySelector('[aria-label="Reasoning effort level"]');
        samples.push({ label: document.querySelector('[aria-label="Select effort"]')?.textContent, value: input?.value, disabled: input?.disabled, opacity: input ? getComputedStyle(input.parentElement).opacity : null });
      }
      return samples;
    });
    for (const frame of frames) {
      assert.ok(frame.label.includes(name), JSON.stringify(frame));
      assert.equal(frame.value, value); assert.equal(frame.disabled, false); assert.equal(frame.opacity, '1');
    }
  };
  await stable('Light', '0');
  await page.keyboard.press('Escape'); await effort.click();
  await stable('Light', '0');
  await range.press('End');
  await stable('High', '2');
  await page.evaluate(() => window.effortReplies.shift()(false));
  await page.waitForFunction(() => window.effortReplies.length === 1);
  await stable('High', '2');
  await page.evaluate(() => window.effortReplies.shift()(true));
  await page.getByRole('alert').filter({ hasText: 'fixture rejected' }).waitFor();
  await stable('Light', '0');
  await range.press('End');
  await page.waitForFunction(() => window.effortReplies.length === 1);
  await stable('High', '2');
  await page.evaluate(() => window.effortReplies.shift()(false));
  await page.waitForFunction(() => !document.querySelector('[role="status"]')?.textContent?.includes('Saving'));
  await page.keyboard.press('Escape'); await effort.click(); await stable('High', '2');
  await page.keyboard.press('Escape');
  await page.evaluate(() => { window.holdEffort = false; });
  assert.equal(await resets(), before, 'Effort changes must not restart or cancel the chat');
  assert.equal(await page.evaluate(() => window.catalogCalls.findLast(call => call.method === 'graff/models')?.params?.refresh), false, 'Confirmation must skip provider discovery');
}

function installCatalogFixture() {
  const fallback = window.fetch;
  let fail = true;
  const chats = new Map();
  window.catalogCalls = [];
  window.catalogReads = 0;
  window.effortReplies = [];
  const json = body => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
  const catalog = state => ({ result: {
    models: ['gpt-astra', 'gpt-sol'].map(name => ({ name, provider: 'codex', authenticated: true, context: 1000, cost: 'plan', current: name === state.model, effortLevels: ['low', 'medium', 'high'] })),
    current: { model: state.model, provider: 'codex', effort: state.effort, fast: false, effortLevels: ['low', 'medium', 'high'] },
  } });
  window.graffDesktop = { projects: async () => null, updates: async () => ({ status: 'unavailable' }), browser: async () => null, activity: async () => null, terminal: async () => null, windowControl: async () => null, updateSubscribe: () => () => {}, subscribe: () => () => {}, terminalSubscribe: () => () => {} };
  window.fetch = async (input, options) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.origin);
    const body = options?.body ? JSON.parse(options.body) : null;
    if (body) window.catalogCalls.push(body);
    if (url.pathname === '/api/models') {
      window.catalogReads++;
      if (fail) { fail = false; return json({ error: 'fixture unavailable' }); }
      return json(catalog({ model: 'gpt-astra', effort: 'medium' }));
    }
    if (url.pathname === '/api/acp' && body) {
      if (body.method === 'bootstrap') {
        if (!chats.has(body.chat) || body.params?.reset) chats.set(body.chat, { model: body.params?.model || 'gpt-sol', effort: 'medium' });
        return json({ sessionId: body.chat, commands: [] });
      }
      if (body.method === 'graff/models') { window.catalogReads++; return json(catalog(chats.get(body.chat))); }
      if (body.method === 'session/prompt') {
        const text = body.params.prompt.map(block => block.text || '').join('');
        if (text === 'hold fixture') return new Response(new ReadableStream({ start(controller) {
          const encode = value => new TextEncoder().encode(JSON.stringify(value) + '\n');
          controller.enqueue(encode({ jsonrpc: '2.0', method: 'session/update', params: { update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Still working' } } } }));
          window.finishCatalogTurn = () => { controller.enqueue(encode({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } })); controller.close(); delete window.finishCatalogTurn; };
        } }));
        if (text.startsWith('/effort ') && window.holdEffort) {
          const rejected = await new Promise(resolve => window.effortReplies.push(resolve));
          if (rejected) return new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, error: { code: -32000, message: 'fixture rejected' } }) + '\n');
        }
        if (text.startsWith('/effort ')) chats.get(body.chat).effort = text.split(' ')[1];
        return new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } }) + '\n');
      }
    }
    return fallback(input, options);
  };
}
