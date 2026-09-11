const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const desktop = require('./test-desktop.cjs');
async function run({ win, backend, token }) {
  const temp = process.env.HOME, output = process.env.GRAFF_PACKAGED_OUTPUT;
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const until = async (condition, label, timeout = 15000) => {
    const end = Date.now() + timeout;
    while (Date.now() < end) { if (await condition()) return; await new Promise(resolve => setTimeout(resolve, 50)); }
    throw Error(`Packaged HTML test timed out: ${label}`);
  };
  const active = () => js(`window.graffDesktop.projects('load').then(data=>data?.active)`);
  await until(async () => await active() === fs.realpathSync(process.env.GRAFF_CWD), 'initial terminal project');
  // Invoke the actual launcher again against this same running application.
  const workspace = fs.realpathSync(path.join(temp, 'second project'));
  await new Promise((resolve, reject) => {
    const child = spawn('/bin/sh', ['-c', 'launcher=$1; shift; . "$launcher"; wait "$!"', 'codegraff-test', path.join(temp, 'codegraff'), workspace], { stdio: 'ignore' });
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(Error('Second launch exceeded 10 seconds')); }, 10000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(Error('Second launch failed')); });
  });
  await until(async () => await active() === workspace, 'running app accepts second project');
  const catalog = await js(`fetch('/api/models').then(r=>r.json())`);
  assert.match(JSON.stringify(catalog.result.current), /lmstudio/i, 'Only the isolated offline model may be used');
  const click = async selector => {
    const point = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
    for (const type of ['mouseDown', 'mouseUp']) await desktop.testInput(wc, { type, ...point, button: 'left', clickCount: 1 });
  };
  const send = async text => {
    await click('textarea[aria-label="Prompt"]');
    for (const keyCode of text) await desktop.testInput(wc, { type: 'char', keyCode });
    await until(() => js(`!document.querySelector('[aria-label="Send"]').disabled`), 'send enabled');
    await click('[aria-label="Send"]');
  };
  const report = { passed: ['packaged cold launcher path', 'packaged running-app launcher path'] };
  await require('./html-tool-frontend.cjs').runHtmlTool({ win, origin: backend.origin, output, temp, workspace,
    requests: path.join(temp, 'requests.json'), send, click, until, report,
    fetchApi: (url, options = {}) => fetch(url, { ...options, headers: { ...options.headers, 'x-graff-desktop': token } }),
  });
  fs.writeFileSync(path.join(output, 'html-results.json'), JSON.stringify(report, null, 2));
}
module.exports = { run };
