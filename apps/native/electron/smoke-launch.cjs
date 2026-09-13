// Packaging check without changing coding settings or sending a prompt.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function run({ win, backend, browser, token }) {
  const js = source => win.webContents.executeJavaScript(source);
  let ready = false;
  for (let n = 0; n < 200; n++) {
    ready = await js(`!!document.querySelector('[data-graff-main]') && !!document.querySelector('textarea[aria-label="Prompt"]')`);
    if (ready) break;
    await sleep(50);
  }
  assert.ok(ready, 'Packaged renderer must mount its composer');
  assert.equal(browser.liveCount, 0, 'An empty app must not create browser views');
  assert.equal((await fetch(`${backend.origin}/api/acp`)).status, 403);
  assert.equal(await js(`fetch('/api/acp').then(response => response.status)`), 200);
  const { app } = require('electron');
  assert.equal(app.isPackaged, true, 'Packaged launch must report isPackaged');
  assert.notEqual(path.basename(process.execPath), 'Electron', 'Packaged executable must not keep the development name');
  const resources = process.env.GRAFF_ELECTRON_RESOURCES || process.resourcesPath;
  const native = require(path.join(resources, 'native/activity.node'));
  assert.equal(typeof native.show, 'function');
  const version = execFileSync(path.join(resources, 'graff'), ['--version'], { encoding: 'utf8', timeout: 10000 }).trim().split('\n')[0];
  assert.match(version, /graff/i);
  if (process.env.GRAFF_SMOKE_HTML_TOOL) await require('./smoke-html.cjs').run({ win, backend, token });
  const report = { passed: ['bundled server', 'production composer', 'empty browser lifecycle', 'request authentication', 'native module ABI', 'bundled engine executable', 'packaged executable'], version };
  fs.writeFileSync(process.env.GRAFF_ELECTRON_SMOKE, JSON.stringify(report, null, 2));
  console.log(process.env.GRAFF_SMOKE_HTML_TOOL ? 'Packaged launch and offline HTML tool checks passed.' : 'Packaged launch checks passed. No prompt sent or coding setting changed.');
}
module.exports = { run };
