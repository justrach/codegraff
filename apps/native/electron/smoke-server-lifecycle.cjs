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
  const until = async (condition, label) => {
    const ms = timeouts.phaseBudget(label, outer, Date.now() - startedAt);
    const end = Date.now() + ms;
    while (Date.now() < end) { if (await condition()) return; await sleep(50); }
    await timeouts.dumpTimeout({ label, waitedMs: ms, outer, output, workspace, js,
      capturePage: () => win.webContents.capturePage().then(page => page.toPNG()),
      backendOrigin: backend.origin, writePhase: phase });
    throw Error(`Shutdown fixture timed out: ${label}`);
  };
  await until(() => js(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`), 'composer');
  phase('composer ready');
  // Same click + wait-for-value + Send path as frontend-runtime.cjs. Return
  // after a missed click left the composer empty and every worker idle at
  // recipe (native CI, pinned shutdown pass).
  async function click(selector) {
    const send = selector === '[aria-label="Send"]';
    for (let attempt = 0; attempt < (send ? 2 : 1); attempt++) {
      const box = await js(`(() => { const e=document.querySelector(${JSON.stringify(selector)});e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return {x,y,hit:e.contains(document.elementFromPoint(x,y))}; })()`);
      if (!box.hit) { if (attempt === 0 && send) { await sleep(100); continue; } throw Error(`Click target obscured: ${selector}`); }
      if (send) await js(`(() => { window.__shutdownSendClick=false;window.__shutdownSendObserver=e=>{if(e.target.closest('[aria-label="Send"]'))window.__shutdownSendClick=true};document.addEventListener('click',window.__shutdownSendObserver,true); })()`);
      try {
        await desktop.testInput(win.webContents, {type:'mouseDown',button:'left',clickCount:1,...box});
        const release = await js(`(() => { const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;return e.contains(document.elementFromPoint(x,y))?{x,y}:null; })()`);
        await desktop.testInput(win.webContents, {type:'mouseUp',button:'left',clickCount:1,...box,...release});
        if (!send) return;
        const end = Date.now() + (attempt ? 1000 : 300);
        while (Date.now() < end && !(await js('window.__shutdownSendClick'))) await sleep(50);
        if (await js('window.__shutdownSendClick')) return;
      } finally {
        if (send) await js("document.removeEventListener('click',window.__shutdownSendObserver,true)");
      }
    }
    throw Error('Shutdown fixture Send click did not reach its button');
  }
  let skipFirstComposerClick = process.env.GRAFF_SHUTDOWN_SKIP_FIRST_COMPOSER_CLICK === '1';
  async function focusComposer() {
    // A hidden macOS window can report a visible hit point while Chromium
    // drops the first trusted press. Retry only before any text was entered.
    const observations = [];
    for (let attempt = 0; attempt < 3; attempt++) {
      await js(`(() => {
        window.__shutdownComposerEvents={down:false,click:false};
        window.__shutdownComposerObserver=e=>{
          if(!e.isTrusted || !e.target?.closest?.('textarea[aria-label="Prompt"]'))return;
          window.__shutdownComposerEvents[e.type==='pointerdown'?'down':'click']=true;
        };
        document.addEventListener('pointerdown',window.__shutdownComposerObserver,true);
        document.addEventListener('click',window.__shutdownComposerObserver,true);
      })()`);
      try {
        if (skipFirstComposerClick) skipFirstComposerClick = false;
        else await click('textarea[aria-label="Prompt"]');
        const end = Date.now() + 1000;
        while (Date.now() < end) {
          const state = await js(`(() => {
            const e=document.querySelector('textarea[aria-label="Prompt"]');
            return {down:window.__shutdownComposerEvents.down,
              click:window.__shutdownComposerEvents.click,
              focused:document.activeElement===e};
          })()`);
          observations[attempt] = {attempt:attempt + 1,...state};
          if (state.down && state.click && state.focused) {
            fs.appendFileSync(path.join(output, 'composer-clicks.jsonl'), JSON.stringify(observations)+'\n');
            return;
          }
          await sleep(50);
        }
      } finally {
        await js(`(() => {
          document.removeEventListener('pointerdown',window.__shutdownComposerObserver,true);
          document.removeEventListener('click',window.__shutdownComposerObserver,true);
        })()`);
      }
      phase(`composer trusted click missed; retrying ${attempt + 1}`);
    }
    fs.appendFileSync(path.join(output, 'composer-clicks.jsonl'), JSON.stringify(observations)+'\n');
    await timeouts.dumpTimeout({ label: 'composer focus', waitedMs: 3000, outer, output, workspace, js,
      capturePage: () => win.webContents.capturePage().then(page => page.toPNG()),
      backendOrigin: backend.origin, writePhase: phase });
    throw Error('Shutdown fixture trusted composer click did not focus its textarea');
  }
  async function submit(text) {
    const ready = () => js(`document.querySelector('textarea[aria-label="Prompt"]').value === ${JSON.stringify(text)} && !document.querySelector('[aria-label="Send"]').disabled`);
    for (let attempt = 0; attempt < 2 && !(await ready()); attempt++) {
      await focusComposer();
      for (const keyCode of text) await desktop.testInput(win.webContents, {type:'char',keyCode});
      const end = Date.now() + 8000;
      while (Date.now() < end && !(await ready())) await sleep(50);
      if (!(await ready()) && attempt === 0) phase('typed prompt missed; retrying');
    }
    if (!(await ready())) {
      await timeouts.dumpTimeout({ label: 'typed prompt ready', waitedMs: 8000, outer, output, workspace, js,
        capturePage: () => win.webContents.capturePage().then(page => page.toPNG()),
        backendOrigin: backend.origin, writePhase: phase });
      throw Error('Shutdown fixture failed to land the composer text');
    }
    await click('[aria-label="Send"]');
  }
  await submit('Start the isolated listener, check its socket, and report readiness.');
  phase('prompt submitted');
  await until(() => js(`document.body.innerText.includes('Listener ready for shutdown.')`), 'agent completion');
  phase('agent completion');
  if (process.env.GRAFF_SHUTDOWN_PIN === '1') {
    const jobId = require('./shutdown-job-id.cjs').listenerJobId(JSON.parse(fs.readFileSync(path.join(output, 'requests.json'), 'utf8')));
    await submit(`/jobs keep ${jobId}`);
    await until(() => js(`document.body.innerText.includes(${JSON.stringify(`job ${jobId} pinned`)})`), 'explicit user pin');
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
