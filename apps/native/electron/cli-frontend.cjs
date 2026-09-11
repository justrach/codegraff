const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
async function runCliFrontend({app, win, temp, workspace, output, until, report, projects}) {
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  assert.equal((await projects.load()).active, fs.realpathSync(workspace), 'launch folder overrides remembered project');
  assert.equal(fs.readFileSync(path.join(workspace, 'proof.txt'), 'utf8'), 'kept', 'actual Graff worker used the launch folder');
  const next = path.join(temp, "Project with spaces ' literal"), file = path.join(next, 'read me.txt');
  fs.mkdirSync(next); fs.writeFileSync(file, 'The terminal opened this file in the correct project.');
  const launch = target => new Promise((resolve, reject) => {
    const second = spawn(process.execPath, [path.join(__dirname, 'cli-second-instance.cjs'), app.getPath('userData'), target], { stdio: 'ignore', env: process.env });
    const timer = setTimeout(() => { second.kill('SIGKILL'); reject(Error('Second-instance handoff exceeded 10 seconds')); }, 10000);
    second.once('error', error => { clearTimeout(timer); reject(error); });
    second.once('exit', code => { clearTimeout(timer); code === 0 ? resolve() : reject(Error(`Secondary instance exited ${code}`)); });
  });
  await launch(file);
  await until(async () => (await projects.load()).active === fs.realpathSync(next), 'second process switches project');
  await until(() => js(`document.body.textContent.includes('The terminal opened this file in the correct project.')`), 'file renders in Files pane');
  assert.equal(await js(`document.querySelectorAll('[data-tab-id] button[aria-pressed]').length`), 2, 'existing conversation stays open');
  await js(`Promise.all(document.getAnimations().filter(a=>a.effect?.getTiming().iterations!==Infinity).map(a=>a.finished.catch(()=>{}))).then(()=>true)`);
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))`);
  fs.writeFileSync(path.join(output, 'codegraff-path.png'), (await wc.capturePage()).toPNG());
  await launch(next);
  await new Promise(resolve => setTimeout(resolve, 200));
  assert.equal(await js(`document.querySelectorAll('[data-tab-id] button[aria-pressed]').length`), 2, 'reopening same folder does not duplicate tabs');
  // Return to the first chat using trusted Chromium input, then verify its text.
  const selector = '[data-tab-id] button[aria-pressed]';
  const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  for (const type of ['mouseDown', 'mouseUp']) await require('./test-desktop.cjs').testInput(wc, { type, ...point, button: 'left', clickCount: 1 });
  await until(() => js(`document.body.textContent.includes('The earlier result is still present.')`), 'first chat survives project handoff');
  report.passed.push('launch folder overrides saved project and actual worker writes there', 'real second-process path handoff', 'file opens in correct folder', 'same-folder launch reuses tab', 'first conversation survives');
}
module.exports = { runCliFrontend };
