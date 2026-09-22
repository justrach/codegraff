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

function installCatalogFixture() {
  const fallback = window.fetch;
  let fail = true;
  const chats = new Map();
  window.catalogCalls = [];
  window.catalogReads = 0;
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
        if (text.startsWith('/effort ')) chats.get(body.chat).effort = text.split(' ')[1];
        return new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } }) + '\n');
      }
    }
    return fallback(input, options);
  };
}
