const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const desktop = require('./test-desktop.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
exports.run = async ({win, backend}) => {
  const output = process.env.GRAFF_SHUTDOWN_OUTPUT;
  const js = source => win.webContents.executeJavaScript(source);
  const until = async (condition, label) => {
    // Outer Electron budget is 120s; 30s here lost to CI scheduling on the
    // scripted ACP turn (listener + HTTP check + completion text).
    const budget = Number(process.env.GRAFF_TEST_TIMEOUT_MS);
    const ms = Number.isFinite(budget) && budget >= 10000 ? Math.min(budget, 120000) : 90000;
    const end = Date.now() + ms;
    while (Date.now() < end) { if (await condition()) return; await sleep(50); }
    throw Error(`Shutdown fixture timed out: ${label}`);
  };
  await until(() => js(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`), 'composer');
  async function submit(text) {
    const box = await js(`(() => { const e=document.querySelector('textarea[aria-label="Prompt"]');e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    await desktop.testInput(win.webContents, {type:'mouseDown',button:'left',clickCount:1,...box});
    await desktop.testInput(win.webContents, {type:'mouseUp',button:'left',clickCount:1,...box});
    for (const keyCode of text) await desktop.testInput(win.webContents, {type:'char',keyCode});
    await desktop.testInput(win.webContents, {type:'keyDown',keyCode:'Return'});
    await desktop.testInput(win.webContents, {type:'keyUp',keyCode:'Return'});
  }
  await submit('Start the isolated listener, check its socket, and report readiness.');
  await until(() => js(`document.body.innerText.includes('Listener ready for shutdown.')`), 'agent completion');
  if (process.env.GRAFF_SHUTDOWN_PIN === '1') {
    await submit('/jobs keep 1');
    await until(() => js(`document.body.innerText.includes('job 1 pinned')`), 'explicit user pin');
  }
  const workspace = process.env.GRAFF_CWD;
  const listener = JSON.parse(fs.readFileSync(path.join(workspace,'listener.json'),'utf8'));
  const records = fs.readdirSync(path.join(process.env.HOME,'.codegraff/jobs')).map(name => JSON.parse(fs.readFileSync(path.join(process.env.HOME,'.codegraff/jobs',name),'utf8')));
  assert.equal(records.length, 1);
  assert.equal(records[0].pinned, process.env.GRAFF_SHUTDOWN_PIN === '1');
  fs.writeFileSync(path.join(output,'before-quit.json'),JSON.stringify({app:process.pid,backend:backend.child.pid,listener,record:records[0]},null,2));
  fs.writeFileSync(path.join(output,'gui-text.txt'),await js('document.body.innerText'));
  fs.writeFileSync(path.join(output,'before-quit.png'),(await win.webContents.capturePage()).toPNG());
  desktop.assertSafe();
  // Observe shutdown before the external watchdog can reap Electron's group.
  const alive = pid => {
    try { return !require('node:child_process').execFileSync('ps',['-p',String(pid),'-o','stat='],{encoding:'utf8'}).trim().startsWith('Z'); }
    catch { return false; }
  };
  let observingQuit = false;
  require('electron').app.on('before-quit', event => {
    event.preventDefault();
    if (observingQuit) return;
    observingQuit = true;
    until(() => !alive(backend.child.pid) && !alive(records[0].owner_pid), 'production backend and worker shutdown')
      .then(() => {
        fs.writeFileSync(path.join(output,'quit-observed.json'),JSON.stringify({backendGone:true,workerGone:true}));
        require('electron').app.exit(0);
      }).catch(error => { console.error(error); require('electron').app.exit(1); });
  });
};
