const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function runStreamingCodeVisuals({ win, origin, output }) {
  const js = source => win.webContents.executeJavaScript(source);
  const wait = async source => {
    for (let attempt = 0; attempt < 200; attempt++) { if (await js(source)) return; await sleep(50); }
    throw Error(`Streaming code check timed out: ${source}`);
  };
  await win.loadURL(`${origin}/visual-tests/code`);
  await wait(`document.querySelector('[data-code-fixture]')?.dataset.codeFixtureReady==='true'`);
  await js('document.fonts.ready.then(()=>true)');
  await js(`Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async value=>{window.fixtureCopiedCode=value}}})`);
  const set = (text, status = 'streaming', stopReason) => js(`window.dispatchEvent(new CustomEvent('fixture-code',{detail:${JSON.stringify({ text, status, stopReason })}}))`);
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
  await js(`document.querySelector('[data-streamdown="code-block-copy-button"]').click()`);
  await wait(`typeof window.fixtureCopiedCode==='string'`);
  assert.equal((await js('window.fixtureCopiedCode')).trimEnd(), appended, 'copy preserves the full completed code');
  // An unfinished fence must also highlight after cancellation/completion.
  for (const [status, reason] of [['done', 'cancelled'], ['done', 'end_turn'], ['error', undefined]]) {
    await set(source); await wait(`!!document.querySelector('[data-code-streaming]')`);
    await set(source, status, reason);
    await wait(`!document.querySelector('[data-code-streaming]') && !!${body}?.querySelector('span[style*="--sdm-c"]')`);
    assert.equal((await js(`${body}.textContent`)).replace(/\n/g, ''), appended.replace(/\n/g, ''));
  }
  const large = code.repeat(5) + '\n// END LARGE SAMPLE';
  assert.ok(large.length > 65536);
  await set('```javascript\n' + large);
  await wait(`${body}?.textContent===${JSON.stringify(large)}`);
  assert.equal(await js(`${body}.childElementCount`), 0);
  await set('```javascript\n' + large, 'done');
  await wait(`!document.querySelector('[data-code-streaming]')`);
  assert.equal((await js(`${body}.textContent`)).replace(/\n/g, ''), large.replace(/\n/g, ''), 'large code keeps all content after the highlighter limit');
  fs.writeFileSync(path.join(output, 'streaming-code-results.json'), JSON.stringify({ passed: ['single text node while live', 'delivery pauses', 'append fidelity', 'closed fence highlight', 'copy and controls', 'unfinished stop/end/error highlight', 'large code fidelity'], smallCharacters: code.length, largeCharacters: large.length }, null, 2));
  console.log('Streaming code checks passed: live fidelity, completed highlighting, controls, cancellation and large fences.');
}
module.exports = { runStreamingCodeVisuals };
