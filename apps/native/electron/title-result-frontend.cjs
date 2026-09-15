const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
exports.observe = win => win.webContents.executeJavaScript(`{
  const original = window.fetch;
  window.__titleResults = [];
  window.fetch = async (...args) => {
    const response = await original(...args);
    if(String(args[0]).includes('/api/title')) window.__titleResults.push(await response.clone().json());
    return response;
  };
  void 0;
}`);
exports.verify = async ({win,output,workspace,send,click,until,report}) => {
  const js = code => win.webContents.executeJavaScript(code);
  await until(() => js('window.__titleResults.length === 1'), 'failed title request finishes');
  assert.deepEqual(await js('window.__titleResults'), [{title:null}]);
  assert(await js(`document.querySelector('[data-tab-id]:has(button[aria-pressed="true"])').textContent.includes('Write the fixture file')`));
  fs.writeFileSync(path.join(output,'title-failure-fallback.png'),(await win.webContents.capturePage()).toPNG());
  await click('[title="New chat (⌘T)"]');
  await send('Check title recovery');
  await until(() => js(`window.__titleResults.length === 2 && document.querySelector('[data-tab-id]:has(button[aria-pressed="true"])').textContent.includes('Retained work') && !document.querySelector('article[aria-busy="true"]')`), 'successful title and agent completion');
  assert.deepEqual(await js('window.__titleResults'), [{title:null},{title:'Retained work'}]);
  fs.writeFileSync(path.join(output,'title-recovery.png'),(await win.webContents.capturePage()).toPNG());
  fs.cpSync(path.join(workspace,'.graff'),path.join(output,'title-harness-evidence'),{recursive:true});
  report.passed.push('actual title failure preserves provisional name and successful generation names the next chat');
};
