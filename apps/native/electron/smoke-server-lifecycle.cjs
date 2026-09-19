const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const desktop = require('./test-desktop.cjs');
const timeouts = require('./smoke-timeout.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
exports.run = async ({win, backend}) => {
  const output = process.env.GRAFF_SHUTDOWN_OUTPUT;
  const workspace = process.env.GRAFF_CWD;
  const js = source => win.webContents.executeJavaScript(source);
  // Phase markers: the next hang shows which phase stalled, in CI output
  // and in the uploaded server-desktop dir.
  const phase = name => {
    console.log(`Shutdown fixture: ${name}`);
    try { fs.writeFileSync(path.join(output, 'phase.txt'), `${name}\n`); } catch {}
  };
  // Every wait ends before the external watchdog (see smoke-timeout.cjs), and
  // the timeout path dumps renderer + backend + model + worker state so the
  // next stall names where the prompt stopped instead of dying as a generic
  // "Test deadline exceeded" under SIGKILL.
  const outer = timeouts.outerMs(), startedAt = Date.now();
  const dumpTimeout = async (label, waitedMs) => {
    phase(`timed out: ${label}`);
    const record = { label, waitedMs, outerMs: outer, at: new Date().toISOString() };
    try { record.guiText = await js('document.body.innerText'); } catch (error) { record.guiText = `<unreadable: ${error.message}>`; }
    try {
      record.backend = await (async () => {
        const response = await fetch(`${backend.origin}/api/acp`, { signal: AbortSignal.timeout(5000) });
        const body = await response.json();
        return `sessions=${body.sessions ?? '?'} ok=${body.ok ?? response.ok}`;
      })();
    } catch (error) { record.backend = `<unreachable: ${error.message}>`; }
    record.workers = timeouts.collectWorkerState(workspace);
    record.model = timeouts.collectModelState(output);
    const file = timeouts.slug(label);
    try { fs.writeFileSync(path.join(output, `timeout-${file}.json`), JSON.stringify(record, null, 2)); } catch {}
    try { fs.writeFileSync(path.join(output, 'timeout-gui-text.txt'), record.guiText.slice(0, 20000)); } catch {}
    try { fs.writeFileSync(path.join(output, 'timeout.png'), (await win.webContents.capturePage()).toPNG()); } catch {}
    console.log(timeouts.formatTimeoutSummary({ label, elapsedMs: waitedMs, outerMs: outer,
      backend: record.backend, workers: record.workers, model: record.model, guiChars: record.guiText.length }));
  };
  const until = async (condition, label) => {
    const ms = timeouts.phaseBudget(label, outer, Date.now() - startedAt);
    const end = Date.now() + ms;
    while (Date.now() < end) { if (await condition()) return; await sleep(50); }
    await dumpTimeout(label, ms);
    throw Error(`Shutdown fixture timed out: ${label}`);
  };
  await until(() => js(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`), 'composer');
  phase('composer ready');
  async function submit(text) {
    const box = await js(`(() => { const e=document.querySelector('textarea[aria-label="Prompt"]');e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    await desktop.testInput(win.webContents, {type:'mouseDown',button:'left',clickCount:1,...box});
    await desktop.testInput(win.webContents, {type:'mouseUp',button:'left',clickCount:1,...box});
    for (const keyCode of text) await desktop.testInput(win.webContents, {type:'char',keyCode});
    await desktop.testInput(win.webContents, {type:'keyDown',keyCode:'Return'});
    await desktop.testInput(win.webContents, {type:'keyUp',keyCode:'Return'});
  }
  await submit('Start the isolated listener, check its socket, and report readiness.');
  phase('prompt submitted');
  await until(() => js(`document.body.innerText.includes('Listener ready for shutdown.')`), 'agent completion');
  phase('agent completion');
  if (process.env.GRAFF_SHUTDOWN_PIN === '1') {
    await submit('/jobs keep 1');
    await until(() => js(`document.body.innerText.includes('job 1 pinned')`), 'explicit user pin');
    phase('explicit user pin');
  }
  const listener = JSON.parse(fs.readFileSync(path.join(workspace,'listener.json'),'utf8'));
  const records = fs.readdirSync(path.join(process.env.HOME,'.codegraff/jobs')).map(name => JSON.parse(fs.readFileSync(path.join(process.env.HOME,'.codegraff/jobs',name),'utf8')));
  assert.equal(records.length, 1);
  assert.equal(records[0].pinned, process.env.GRAFF_SHUTDOWN_PIN === '1');
  fs.writeFileSync(path.join(output,'before-quit.json'),JSON.stringify({app:process.pid,backend:backend.child.pid,listener,record:records[0]},null,2));
  fs.writeFileSync(path.join(output,'gui-text.txt'),await js('document.body.innerText'));
  fs.writeFileSync(path.join(output,'before-quit.png'),(await win.webContents.capturePage()).toPNG());
  desktop.assertSafe();
  phase('before-quit captured; observing quit');
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
    phase('before-quit received');
    until(() => !alive(backend.child.pid) && !alive(records[0].owner_pid), 'production backend and worker shutdown')
      .then(() => {
        phase('backend and worker shutdown observed');
        fs.writeFileSync(path.join(output,'quit-observed.json'),JSON.stringify({backendGone:true,workerGone:true}));
        require('electron').app.exit(0);
      }).catch(error => { console.error(error); require('electron').app.exit(1); });
  });
};
