// Headless production motion checks. Never opens or focuses a native window.
// Usage: node scripts/test-motion.mjs /absolute/app/root /absolute/output
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const { chromium } = require('@playwright/test');
const { installGalleryFixture } = require('../electron/gallery-fixture.cjs');
const { installMotionFixture } = require('../electron/motion-fixture.cjs');
const root = path.resolve(process.argv[2] || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const output = path.resolve(process.argv[3] || path.join(root, '../../zig-out/motion/current'));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let server, browser, context, page, video, complete = false, finishing = false;
assert.ok(fs.existsSync(chromium.executablePath()), 'Install the Playwright Chromium runtime before running headless checks');
const deadline = setTimeout(() => { console.error('Headless motion checks exceeded 120 seconds'); void finish(1); }, 120000);

try {
  fs.mkdirSync(output, { recursive: true });
  assert.ok(fs.existsSync(path.join(root, '.next/BUILD_ID')), 'Build the selected app first');
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(output, 'motion-headless-server.log'), 'w');
  server = spawn(process.env.GRAFF_TEST_BUN || 'bun', ['node_modules/next/dist/bin/next', 'start', '--port', String(port), '--hostname', '127.0.0.1'], {
    cwd: root, env: { ...process.env, GRAFF_VISUAL_TESTS: '1', GRAFF_DESKTOP_TOKEN: '', NEXT_TELEMETRY_DISABLED: '1' }, detached: true, stdio: ['ignore', log, log],
  });
  fs.closeSync(log);
  for (let i = 0; i < 200; i++) {
    try { if ((await fetch(origin, { signal: AbortSignal.timeout(1000) })).ok) break; } catch {}
    if (i === 199) throw Error('Motion server did not start');
    await sleep(100);
  }
  browser = await chromium.launch({ headless: true });
  const ffmpegRoot = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  const videoAvailable = fs.existsSync(ffmpegRoot) && fs.readdirSync(ffmpegRoot).some(name => name.startsWith('ffmpeg-'));
  context = await browser.newContext({ viewport: { width: 1440, height: 920 }, reducedMotion: 'no-preference',
    ...(videoAvailable ? { recordVideo: { dir: output, size: { width: 1440, height: 920 } } } : {}) });
  await context.addInitScript({ content: `(${installGalleryFixture.toString()})();(${installMotionFixture.toString()})();
    window.graffDesktop={projects:async()=>null,updates:async()=>({status:'unavailable',currentVersion:'1.0.0'}),browser:async()=>null,activity:async()=>null,terminal:async()=>null,windowControl:async()=>null,updateSubscribe:()=>()=>{},subscribe:()=>()=>{},terminalSubscribe:()=>()=>{}};` });
  const unexpected = [];
  await context.route('**/*', route => {
    const url = new URL(route.request().url());
    const allowed = url.origin === origin && !url.pathname.startsWith('/api/') || url.protocol === 'data:';
    if (!allowed) unexpected.push(url.origin === origin ? url.pathname : 'external request');
    return allowed ? route.continue() : route.abort();
  });
  page = await context.newPage();
  video = page.video();
  const cdp = await context.newCDPSession(page);
  await cdp.send('Performance.enable');
  const js = code => page.evaluate(code);
  const wait = expression => page.waitForFunction(expression, null, { timeout: 10000 });
  const metrics = async () => Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map(({ name, value }) => [name, value]));
  const move = selector => page.locator(selector).hover();
  const click = selector => page.locator(selector).click();
  const key = name => page.keyboard.press(name);
  const draft = value => page.locator('textarea[aria-label="Prompt"]').fill(value);
  const running = () => js(`document.getAnimations().filter(a=>a.playState==='running'||a.pending).map(a=>({name:a.animationName??a.transitionProperty??'web-animation',target:a.effect?.target?.tagName}))`);
  const capture = async name => {
    await js('document.activeElement?.blur()');
    await sleep(300);
    await page.screenshot({ path: path.join(output, name) });
  };
  const visibility = hidden => page.evaluate(value => {
    Object.defineProperty(document, 'hidden', { configurable: true, value });
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: value ? 'hidden' : 'visible' });
    document.dispatchEvent(new Event('visibilitychange'));
  }, hidden);
  const report = { build: fs.readFileSync(path.join(root, '.next/BUILD_ID'), 'utf8').trim(),
    runtime: { chromium: browser.version(), headless: true }, checks: [],
    note: 'Headless Chromium, production build, fresh context, synthetic API responses and blocked API/network escape. Visibility checks dispatch synthetic document events; they do not verify native window throttling. Layout counters are observations, not a tight timing threshold.' };
  const passed = name => { report.checks.push(name); console.log('Motion:', name); };
  await page.goto(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]') && document.querySelector('[aria-label="Choose model"]')?.textContent.includes('Graff')`);
  await js(`window.motionEvents=[];for(const type of ['keydown','mouseover','focusin'])document.addEventListener(type,event=>{window.motionEvents.push({type,key:event.key,row:event.target.closest?.('[data-motion-row]')?.dataset.motionRow,label:event.target.getAttribute?.('aria-label')});if(window.motionEvents.length>30)window.motionEvents.shift()},true)`);
  await js('document.fonts.ready.then(()=>true)');
  await sleep(1100);
  assert.deepEqual(await running(), [], 'The settled home screen must not animate indefinitely');
  assert.ok(await js(`document.querySelectorAll('.home-reveal').length>=3`), 'The fixture must show the home entrance content');
  assert.equal(await js(`document.querySelectorAll('[data-promptbar] canvas').length`), 0, 'The composer must not retain a canvas');
  assert.ok(await js(`[...document.querySelectorAll('.home-reveal')].every(e=>{const s=getComputedStyle(e);return s.opacity==='1'&&s.filter==='none'&&s.willChange==='auto'})`), 'Home reveal must settle without a blur or permanent will-change');
  passed('home settles with no running animations, blur or composer canvas');
  await capture('motion-home.png');

  const sidebar = '[aria-label="Workspace navigation"]';
  const rowSelector = `${sidebar} button[data-row]`;
  const rows = await js(`document.querySelectorAll(${JSON.stringify(rowSelector)}).length`);
  assert.ok(rows >= 4, 'The fixture must expose multiple real sidebar rows');
  // Tag existing controls for stable input targets without changing their styling.
  await js(`[...document.querySelectorAll(${JSON.stringify(rowSelector)})].forEach((e,i)=>e.dataset.motionRow=String(i))`);
  const target = index => `[data-motion-row="${index}"]`;
  const aligned = index => js(`(()=>{const row=document.querySelector(${JSON.stringify(target(index))});const group=row.closest('[class~="group/glide-menu"]');const h=group.querySelector(':scope > span[aria-hidden]');const a=h.getBoundingClientRect(),b=row.getBoundingClientRect();return Math.abs(a.top-b.top)<1&&Math.abs(a.height-b.height)<1&&getComputedStyle(h).opacity==='1'})()`);
  await move(target(0)); await sleep(280);
  const before = await metrics();
  for (let index = 0; index < 24; index++) { await move(target(index % 4)); await sleep(24); }
  await sleep(300);
  const after = await metrics();
  report.hover = { moves: 24, layoutCount: after.LayoutCount - before.LayoutCount,
    layoutMs: 1000 * (after.LayoutDuration - before.LayoutDuration), styleMs: 1000 * (after.RecalcStyleDuration - before.RecalcStyleDuration) };
  assert.ok(await aligned(3), 'Pointer highlight must finish on the last hovered row');
  await move('h1'); await sleep(160);
  await js(`document.querySelector(${JSON.stringify(target(1))}).focus()`);
  await key('Tab'); await sleep(280);
  assert.equal(await js('document.activeElement.dataset.motionRow'), '2', 'Tab must advance to the next sidebar row');
  assert.ok(await aligned(2), 'Keyboard focus must move the shared highlight');
  await move(`${target(0)} svg`); await sleep(280);
  await js(`document.querySelector(${JSON.stringify(target(2))}).focus()`); await sleep(280);
  await move(`${target(0)} .sidebar-copy`); await sleep(280);
  assert.ok(await aligned(0), 'Returning to another child of the hovered row must reclaim the highlight after keyboard focus');
  passed('rapid browser pointer input and keyboard focus settle on the correct sidebar row');

  const modelDialog = '[aria-label="Choose a model"]';
  const modelOptions = '[aria-label="Available models"] [role="option"]';
  for (let repeat = 0; repeat < 2; repeat++) {
    await click('[aria-label="Choose model"]');
    await wait(`document.activeElement?.getAttribute('aria-label')==='Filter models'`);
    await sleep(200);
    await move(`${modelOptions}:nth-child(2)`);
    await wait(`document.querySelector('[aria-label="Filter models"]').getAttribute('aria-activedescendant')===document.querySelector(${JSON.stringify(`${modelOptions}:nth-child(2)`)}).id`);
    await key('ArrowDown');
    await wait(`document.querySelector('[aria-label="Filter models"]').getAttribute('aria-activedescendant')===document.querySelector(${JSON.stringify(`${modelOptions}:nth-child(3)`)}).id`);
    if (repeat === 0) await capture('motion-model-menu.png');
    // capture blurs the field; restore focus so Escape follows the dialog path.
    await js(`document.querySelector('[aria-label="Filter models"]').focus()`);
    await key('Escape');
    await wait(`!document.querySelector(${JSON.stringify(modelDialog)})`);
    assert.equal(await js('document.activeElement.getAttribute("aria-label")'), 'Choose model');
  }
  passed('model menu pointer and keyboard selection, focus restoration, Escape and reopening');

  for (let repeat = 0; repeat < 2; repeat++) {
    await draft('/');
    await wait(`document.querySelectorAll('[data-composer-menu] [role="option"]').length>1`);
    await key('ArrowDown');
    await wait(`document.querySelector('[data-composer-menu] [role="option"]:nth-child(2)').getAttribute('aria-selected')==='true'`);
    await move('[data-composer-menu] [role="option"]:first-child');
    await wait(`document.querySelector('[data-composer-menu] [role="option"]').getAttribute('aria-selected')==='true'`);
    await key('Escape');
    await wait(`!document.querySelector('[data-composer-menu]')`);
    assert.equal(await js('document.activeElement.getAttribute("aria-label")'), 'Prompt');
    await draft('');
  }
  passed('composer menu pointer and keyboard selection, retained focus, Escape and reopening');
  for (let repeat = 0; repeat < 2; repeat++) {
    await click('[aria-label="Select effort"]');
    await wait(`!!document.querySelector('[aria-label="Reasoning effort"]')`);
    await key('Escape');
    await wait(`!document.querySelector('[aria-label="Reasoning effort"]')`);
    assert.equal(await js('document.activeElement.getAttribute("aria-label")'), 'Choose model');
  }
  passed('effort menu Escape, focus restoration and reopening');

  // Extend a production entrance to test the visibility listener and CSS gate.
  // Headless documents cannot reproduce native minimize/occlusion behavior.
  await click('[aria-label="Choose model"]');
  await wait(`!!document.querySelector(${JSON.stringify(modelDialog)})`);
  await js(`document.querySelector(${JSON.stringify(modelDialog)}).style.animationDuration='10s'`);
  assert.notEqual(await js(`getComputedStyle(document.querySelector(${JSON.stringify(modelDialog)})).animationName`), 'none');
  await sleep(250);
  await visibility(true);
  await wait(`document.hidden && document.documentElement.dataset.motionHidden==='true'`);
  assert.equal(await js(`getComputedStyle(document.querySelector(${JSON.stringify(modelDialog)})).animationPlayState`), 'paused');
  await wait(`document.querySelector(${JSON.stringify(modelDialog)}).getAnimations().every(a=>!a.pending)`);
  assert.deepEqual(await running(), [], 'Hidden windows must pause CSS motion');
  await visibility(false);
  await wait(`!document.hidden && document.documentElement.dataset.motionHidden!=='true'`);
  assert.equal(await js(`getComputedStyle(document.querySelector(${JSON.stringify(modelDialog)})).animationPlayState`), 'running');
  await js(`document.querySelector('[aria-label="Filter models"]').focus()`); await key('Escape');
  await wait(`!document.querySelector(${JSON.stringify(modelDialog)})`);
  passed('synthetic visibility events pause CSS motion and resume it');

  const celebrate = async () => {
    await click('[aria-label="Choose model"]');
    await wait(`!!document.querySelector(${JSON.stringify(modelDialog)})`);
    const started = await js(`(()=>{[...document.querySelectorAll(${JSON.stringify(modelOptions)})].find(e=>e.textContent.includes('sprinkles-5')).click();return document.querySelector('[data-composer-sweep]').getAnimations().length>0})()`);
    await wait(`!document.querySelector(${JSON.stringify(modelDialog)})`);
    return started;
  };
  assert.ok(await celebrate(), 'Selecting the special fixture model must start its feedback animation');
  await sleep(700);
  assert.equal(await js(`document.querySelector('[data-composer-sweep]').getAnimations().length`), 0, 'Finished feedback must release its animation');
  assert.equal(await js(`getComputedStyle(document.querySelector('[data-composer-sweep]')).opacity`), '0');
  passed('composer feedback finishes and releases its animation');

  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await page.goto(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]') && document.querySelector('[aria-label="Choose model"]')?.textContent.includes('Graff')`);
  assert.ok(await js(`document.querySelectorAll('.home-reveal').length>=3`));
  assert.ok(await js(`[...document.querySelectorAll('.home-reveal')].every(e=>{const s=getComputedStyle(e);return s.opacity==='1'&&s.animationName==='none'&&s.animationDelay==='0s'})`), 'Reduced motion must reveal home without an entrance delay');
  await click('[aria-label="Choose model"]');
  await wait(`document.activeElement?.getAttribute('aria-label')==='Filter models'`);
  assert.ok(await js(`(()=>{const s=getComputedStyle(document.querySelector(${JSON.stringify(modelDialog)}));return s.opacity==='1'&&s.animationName==='none'})()`));
  await key('Escape'); await wait(`!document.querySelector(${JSON.stringify(modelDialog)})`);
  assert.equal(await celebrate(), false, 'Reduced motion must skip the feedback at invocation');
  assert.equal(await js(`document.querySelector('[data-composer-sweep]').getAnimations().length`), 0);
  assert.deepEqual(await running(), [], 'Reduced motion must disable decorative animation');
  passed('reduced motion reveals content immediately and skips menu and composer feedback animations');
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
  await page.goto(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]') && document.querySelector('[aria-label="Choose model"]')?.textContent.includes('Graff')`);
  await sleep(1100);
  await capture('motion-preview.png');

  await js('window.motionControlledStream=true');
  await draft('Show how the workspace stays responsive while a reply arrives.');
  await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
  await click('[aria-label="Send"]');
  await wait(`typeof window.motionStreamChunk==='function'`);
  await js(`window.motionStreamChunk('Checking the motion lifecycle',true)`);
  await wait(`document.querySelector('article')?.textContent.includes('Checking the motion lifecycle')`);
  await js(`window.motionReasoningRow=[...document.querySelectorAll('article span')].find(e=>e.textContent==='Checking the motion lifecycle').parentElement;window.motionStreamChunk(' as the reply grows.',true)`);
  await wait(`document.querySelector('article')?.textContent.includes('as the reply grows.')`);
  assert.ok(await js(`window.motionReasoningRow.isConnected && window.motionReasoningRow.textContent.includes('as the reply grows.')`), 'A live reasoning update must reuse its row');
  await click('article button[aria-expanded="true"]');
  await sleep(450);
  assert.equal(await js(`document.querySelector('article button[aria-expanded]').nextElementSibling.getAnimations({subtree:true}).filter(a=>a.playState==='running').length`), 0, 'Collapsed reasoning rows must not animate');
  await js(`window.motionStreamChunk('The workspace is ready. ')`);
  await wait(`document.querySelector('article')?.textContent.includes('The workspace is ready.')`);
  await js(`window.motionStreamChunk('A calm interface keeps the conversation readable. '.repeat(100)+'REDUCED-FLUSH-MARKER')`);
  await sleep(100);
  assert.ok(await js(`!document.querySelector('article').textContent.includes('REDUCED-FLUSH-MARKER')`), 'The fixture must exercise an in-flight reveal');
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  // Let the media event and React commit cross a rendering boundary; do not
  // mistake an eventually completed typewriter for an immediate flush.
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true)))))`);
  assert.ok(await js(`document.querySelector('article').textContent.includes('REDUCED-FLUSH-MARKER')`), 'Reduced motion must flush at the next rendering boundary');
  await cdp.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'no-preference' }] });
  await js(`window.motionStreamChunk(' New updates remain readable. '.repeat(100)+'HIDDEN-FLUSH-MARKER')`);
  await sleep(100);
  assert.ok(await js(`!document.querySelector('article').textContent.includes('HIDDEN-FLUSH-MARKER')`));
  await visibility(true);
  await wait(`document.hidden && document.querySelector('article').textContent.includes('HIDDEN-FLUSH-MARKER')`);
  await visibility(false);
  await wait('!document.hidden');
  await js('window.motionStreamFinish()');
  await wait(`document.querySelector('article')?.getAttribute('aria-busy')==='false'`);
  await sleep(700);
  assert.deepEqual(await running(), [], 'A completed reply and collapsed reasoning must not retain running animations');
  passed('streaming reasoning reuses rows; collapsed rows stop; reduced motion and hide flush pending text; completed reply settles');
  await js("window.dispatchEvent(new CustomEvent('graff-desktop-action',{detail:'close'}))");
  await wait(`!document.querySelector('article') && !!document.querySelector('textarea[aria-label="Prompt"]')`);
  await sleep(700);
  assert.deepEqual(unexpected, [], 'Motion checks must not call real APIs or external services');
  report.unexpectedRequests = unexpected;
  fs.writeFileSync(path.join(output, 'motion-headless-report.json'), JSON.stringify(report, null, 2));
  complete = true;
  console.log('Headless motion checks complete:', output);

} catch (error) {
  console.error(error);
  if (page && !page.isClosed()) {
    try { console.error('Page focus:', await page.evaluate(() => ({ label: document.activeElement?.getAttribute('aria-label'), tag: document.activeElement?.tagName }))); await page.screenshot({ path: path.join(output, 'motion-headless-failure.png') }); } catch {}
  }
} finally { await finish(complete ? 0 : 1); }

async function finish(code) {
  if (finishing) return;
  finishing = true;
  clearTimeout(deadline);
  if (context) await context.close().catch(() => {});
  if (video) {
    try { await video.saveAs(path.join(output, complete ? 'motion-preview.webm' : 'motion-headless-failure.webm')); await video.delete(); } catch {}
  }
  if (browser) await browser.close().catch(() => {});
  if (server?.pid) try { process.kill(-server.pid, 'SIGTERM'); } catch {}
  process.exitCode = code;
}
