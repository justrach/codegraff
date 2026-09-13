const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { testInput } = require('./test-desktop.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function runStreamingCodeVisuals({ win, origin, output }) {
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async source => {
    for (let attempt = 0; attempt < 200; attempt++) { if (await js(source)) return; await sleep(50); }
    fs.writeFileSync(path.join(output, 'code-failure.png'), (await win.webContents.capturePage()).toPNG());
    console.error(await js(`JSON.stringify({button:document.querySelector('[data-code-expand]')?.outerHTML,lastClick:window.lastFixtureClick,scroll:document.querySelector('main')?.scrollTop})`));
    throw Error(`Streaming code check timed out: ${source}`);
  };
  await win.loadURL(`${origin}/visual-tests/code`);
  await wait(`document.querySelector('[data-code-fixture]')?.dataset.codeFixtureReady==='true'`);
  await js('document.fonts.ready.then(()=>true)');
  await js(`Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{window.fixtureCopiedCode=value}}})`);
  const set = (text, status = 'streaming', stopReason) => js(`window.dispatchEvent(new CustomEvent('fixture-code',{detail:${JSON.stringify({ text, status, stopReason })}}))`);
  await js(`document.addEventListener('click',e=>{window.lastFixtureClick={tag:e.target.tagName,trusted:e.isTrusted}},{capture:true})`);
  const click = async selector => {
    // Wait for layout and hit testing, not just React's element insertion.
    let point;
    for (let attempt = 0; attempt < 30; attempt++) {
      await js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'center',behavior:'instant'})`);
      await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
      point = await js(`(()=>{const el=document.querySelector(${JSON.stringify(selector)}),r=el.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return el.contains(document.elementFromPoint(x,y))?{x,y}:null})()`);
      if (point) break;
      await sleep(30);
    }
    assert.ok(point, `Control is not pointer-reachable: ${selector}`);
    for (const type of ['mouseDown', 'mouseUp']) await testInput(win.webContents, {type,...point,button:'left',clickCount:1});
  };
  const body = `document.querySelector('[data-streamdown="code-block-body"] code')`;
  const code = Array.from({ length: 300 }, (_, index) => `const item${index} = { message: "Readable 😀 code", enabled: true };`).join('\n');
  let source = '```javascript\n' + code;
  await set(source);
  await wait(`!!document.querySelector('[data-code-streaming]') && ${body}?.textContent===${JSON.stringify(code)}`);
  assert.equal(await js(`${body}.childElementCount`), 0, 'live code should stay one text node');
  await sleep(200);
  assert.equal(await js(`!!document.querySelector('[data-code-streaming]')`), true, 'a pause between deliveries must not start highlighting');
  const appended = code + '\nconsole.log(item299);';
  source = '```javascript\n' + appended;
  await set(source);
  await wait(`${body}?.textContent===${JSON.stringify(appended)}`);
  assert.equal(await js(`${body}.childElementCount`), 0);
  await set(source + '\n```');
  await wait(`!document.querySelector('[data-code-streaming]') && !!${body}?.querySelector('span[style*="--sdm-c"]')`);
  await set(source + '\n```', 'done');
  await wait(`!document.querySelector('[data-streamdown="code-block-copy-button"]')?.disabled`);
  assert.equal(await js(`document.querySelectorAll('[data-streamdown="code-block-download-button"]').length`), 0, 'configured download control stays disabled');
  await click('[data-streamdown="code-block-copy-button"]');
  await wait(`typeof window.fixtureCopiedCode==='string'`);
  assert.equal((await js('window.fixtureCopiedCode')).trimEnd(), appended, 'copy preserves the full completed code');
  const fullText = () => js(`${body}.textContent`);
  const assertExpanded = async expected => {
    await wait(`document.querySelector('[data-code-expand]')?.getAttribute('aria-expanded')==='false'`);
    assert.equal((await fullText()).includes('item299'), false, 'collapsed code omits later highlighted lines');
    await click('[data-code-expand]');
    await wait(`document.querySelector('[data-code-expand]')?.getAttribute('aria-expanded')==='true'`);
    await wait(`${body}?.textContent.replace(/\\n/g,'')===${JSON.stringify(expected.replace(/\n/g, ''))}`);
  };
  assert.equal(await js(`document.querySelector('[data-code-expand]').textContent.trim()`), 'Show 241 more lines');
  await assertExpanded(appended);
  await click('[data-code-expand]');
  await wait(`document.querySelector('[data-code-preview]')?.dataset.codePreview==='collapsed'`);
  await wait(`${body}?.textContent.replace(/\\n/g,'')===${JSON.stringify(code.split('\n').slice(0,60).join(''))}`);
  await js(`document.querySelector('[data-code-expand]').scrollIntoView({block:'end',behavior:'instant'})`);
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  fs.writeFileSync(path.join(output, 'completed-code-preview.png'), (await win.webContents.capturePage()).toPNG());
  // Keyboard activation uses Chromium's trusted key events as well.
  await testInput(win.webContents, {type:'keyDown',keyCode:'Return'});
  await testInput(win.webContents, {type:'keyUp',keyCode:'Return'});
  await wait(`document.querySelector('[data-code-expand]')?.getAttribute('aria-expanded')==='true'`);
  // An unfinished fence must also highlight after cancellation/completion.
  for (const [status, reason] of [['done', 'cancelled'], ['done', 'end_turn'], ['error', undefined]]) {
    console.log('Checking unfinished fence',status,reason);
    await set(source); await wait(`!!document.querySelector('[data-code-streaming]')`);
    await set(source, status, reason);
    await wait(`!document.querySelector('[data-code-streaming]') && !!${body}?.querySelector('span[style*="--sdm-c"]')`);
    await assertExpanded(appended);
  }
  const large = code.repeat(5) + '\n// END LARGE SAMPLE';
  assert.ok(large.length > 65536);
  await set('```javascript\n' + large);
  await wait(`${body}?.textContent===${JSON.stringify(large)}`);
  assert.equal(await js(`${body}.childElementCount`), 0);
  await set('```javascript\n' + large, 'done');
  await wait(`!document.querySelector('[data-code-streaming]')`);
  await assertExpanded(large);
  assert.equal(await js(`!!${body}.querySelector('span[style*="--sdm-c"]')`), false, 'expanded oversized code uses the plain-text fallback');
  // Documents retain their entire source without an extra disclosure step.
  await js(`window.dispatchEvent(new CustomEvent('fixture-code',{detail:${JSON.stringify({text:source+'\n```',status:'done',asDocument:true})}}))`);
  await wait(`!document.querySelector('[data-code-expand]') && ${body}?.textContent.replace(/\\n/g,'')===${JSON.stringify(appended.replace(/\n/g,''))}`);
  await js(`document.documentElement.classList.remove('dark')`);
  await sleep(50);
  const light = await js(`getComputedStyle(${body}.querySelector('span[style*="--sdm-c"]')).color`);
  await js(`document.documentElement.classList.add('dark')`);
  await wait(`getComputedStyle(${body}.querySelector('span[style*="--sdm-c"]')).color!==${JSON.stringify(light)}`);
  await js(`document.documentElement.classList.remove('dark')`);
  await wait(`getComputedStyle(${body}.querySelector('span[style*="--sdm-c"]')).color===${JSON.stringify(light)}`);
  await set('```mermaid\nflowchart LR\n    Start --> Done');
  await wait(`!!document.querySelector('[data-code-streaming]')`);
  assert.equal(await js(`!!document.querySelector('[data-streamdown="mermaid-block"]')`), false, 'an open mermaid fence stays a code block');
  await set('```mermaid\nflowchart LR\n    Start --> Done\n```', 'done');
  await wait(`!!document.querySelector('[data-streamdown="mermaid-block"] svg')`);
  assert.ok(await js(`document.querySelector('[data-streamdown="mermaid-block"] svg').getBoundingClientRect().height > 0`));
  await js(`document.documentElement.classList.add('dark')`);
  await wait(`document.querySelector('[data-streamdown="mermaid-block"] svg')?.id.endsWith('-d')`);
  await js(`document.documentElement.classList.remove('dark')`);
  await wait(`document.querySelector('[data-streamdown="mermaid-block"] svg')?.id.endsWith('-l')`);
  fs.writeFileSync(path.join(output, 'streaming-code-results.json'), JSON.stringify({ passed: ['single text node while live', 'delivery pauses', 'append fidelity', 'closed fence highlight', 'copy and controls', 'unfinished stop/end/error highlight', 'large code fidelity', 'mermaid diagram', 'collapsed full-source copy', 'trusted mouse and keyboard expansion', 'document opt-out', 'theme switching'], smallCharacters: code.length, largeCharacters: large.length }, null, 2));
  console.log('Streaming code checks passed: live fidelity, completed highlighting, controls, cancellation, large fences and mermaid diagrams.');
}
module.exports = { runStreamingCodeVisuals };
