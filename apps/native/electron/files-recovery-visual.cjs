const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runFilesRecovery({ win, origin, output }) {
  const wc = win.webContents;
  const js = async code => {
    try { return await wc.executeJavaScript(code); }
    catch (error) { console.error('Files recovery expression:', code); throw error; }
  };
  const wait = async code => {
    for (let i = 0; i < 120; i++) { if (await js(code)) return; await new Promise(r => setTimeout(r, 50)); }
    throw Error(`Files recovery timed out: ${code}`);
  };
  const pane = '[data-files-pane]';
  const text = `document.querySelector('${pane}')?.textContent ?? ''`;
  const click = (selector, label) => js(`(()=>{const e=Array.from(document.querySelectorAll(${JSON.stringify(selector)})).find(e=>e.textContent.trim()===${JSON.stringify(label)});if(!e)throw Error('Missing button '+${JSON.stringify(label)});e.click();})()`);
  const clickPane = label => click(`${pane} button`, label);
  // File/changed-file rows also contain size or diff statistics. Match the
  // dedicated filename span, keeping breadcrumb buttons out of the selection.
  const pickEntry = label => js(`(()=>{const e=Array.from(document.querySelectorAll('${pane} button')).find(e=>Array.from(e.children).some(c=>c.tagName==='SPAN'&&c.textContent.trim()===${JSON.stringify(label)}));if(!e)throw Error('Missing file row '+${JSON.stringify(label)});e.click();})()`);
  const settle = () => js(`new Promise(r=>setTimeout(r,100))`);
  const focusTab = index => js(`document.querySelectorAll('[aria-label="Close tab"]')[${index}].parentElement.querySelector('button[aria-pressed]').click()`);

  await wc.loadURL(origin);
  await wait(`!!document.querySelector('button[aria-label="Files"]')`);
  const firstTab = await js(`document.querySelectorAll('[aria-label="Close tab"]').length`);
  await js(`document.querySelector('button[aria-label="Projects"]').click()`);
  await wait(`!!document.querySelector('[data-project-path="/demo/folder-41"]')`);
  await js(`document.querySelector('[data-project-path="/demo/folder-41"] button:last-child').click()`);
  await wait(`document.querySelectorAll('[aria-label="Close tab"]').length===${firstTab + 1}`);
  const count = firstTab + 1;
  await js(`document.querySelector('button[aria-label="Projects"]').click()`);
  await wait(`!!document.querySelector('[data-project-path="/demo/folder-42"]')`);
  await js(`document.querySelector('[data-project-path="/demo/folder-42"] button:last-child').click()`);
  await wait(`document.querySelectorAll('[aria-label="Close tab"]').length===${count + 1}`);
  await focusTab(firstTab);
  await js(`(()=>{
    const previous=window.fetch;
    const json=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});
    window.filesRecovery={stat:'fail',changes:'normal',diff:'normal',action:'normal',holds:{},requests:[]};
    window.fetch=async(input,options)=>{
      const url=new URL(String(input),location.origin),r=window.filesRecovery;
      if(!['/api/fs','/api/git'].includes(url.pathname))return previous(input,options);
      const body=options?.body?JSON.parse(options.body):null;
      const root=body?.root??url.searchParams.get('root'),target=body?.path??url.searchParams.get('path')??'';
      const kind=url.pathname==='/api/fs'?(body?'action':'stat'):(body?'diff':'changes');
      const mode=r[kind];r.requests.push({kind,root,path:target,action:body?.action});
      if(mode==='hold'||mode==='hold-fail')await new Promise(resolve=>r.holds[kind]=resolve);
      if(mode==='network')throw Error('File action connection lost');
      if(mode==='fail'||mode==='hold-fail')return json({error:kind+' temporarily unavailable'},503);
      if(kind==='action')return json({ok:true});
      if(kind==='diff')return json({diff:'@@ -1 +1 @@\\n-old\\n+current-diff-'+target+'\\n'});
      if(kind==='changes')return json({root,files:[{path:'alpha.txt',add:1,del:1,untracked:false},{path:'beta.txt',add:2,del:0,untracked:true}],totalAdd:3,totalDel:1});
      if(!target||target==='src')return json({root,path:target,dir:true,entries:target?[{name:'notes.md',dir:false,size:20}]:[{name:root==='/demo/folder-42'?'second-project.txt':'first-project.txt',dir:false,size:20},{name:'src',dir:true,size:0}]});
      return json({root,path:target,dir:false,size:20,binary:false,truncated:false,text:'File contents for '+target});
    };
  })()`);

  await js(`document.querySelector('button[aria-label="Files"]').click()`);
  await wait(`!!document.querySelector('${pane} [role="alert"]')`);
  assert.equal(await js(`(${text}).includes('Empty folder')`), false, 'Failed listing is distinct from empty folder');
  await js(`window.filesRecovery.stat='normal'`);
  await clickPane('Retry');
  await wait(`(${text}).includes('first-project.txt')`);

  await js(`window.filesRecovery.stat='fail'`);
  await pickEntry('src');
  await wait(`!!document.querySelector('${pane} [role="alert"]')`);
  await js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))');
  fs.writeFileSync(path.join(output, 'files-retry.png'), (await wc.capturePage()).toPNG());
  await js(`window.filesRecovery.stat='normal'`);
  await clickPane('Retry');
  await wait(`(${text}).includes('notes.md')`);
  assert.equal(await js(`window.filesRecovery.requests.filter(r=>r.kind==='stat').at(-1).path`), 'src', 'Retry retains the failed directory');
  await pickEntry('notes.md');
  await wait(`(${text}).includes('File contents for src/notes.md')`);

  await js(`window.filesRecovery.action='fail'`);
  await clickPane('Open');
  await wait(`!!document.querySelector('${pane} [role="alert"]')`);
  assert.ok(await js(`(${text}).includes('File contents for src/notes.md')`), 'External action failure keeps the file visible');
  await js(`window.filesRecovery.action='normal'`);
  await clickPane('Retry');
  await wait(`!document.querySelector('${pane} [role="alert"]')&&!document.querySelector('${pane} [role="status"]')`);
  assert.deepEqual(await js(`window.filesRecovery.requests.filter(r=>r.kind==='action').slice(-2).map(r=>({action:r.action,path:r.path}))`), [{action:'open',path:'src/notes.md'},{action:'open',path:'src/notes.md'}], 'Action retry retains Open and its file');
  await js(`window.filesRecovery.action='network'`);
  await clickPane('Reveal');
  await wait(`(${text}).includes('File action connection lost')`);
  await js(`window.filesRecovery.action='normal';window.filesRecovery.changes='fail'`);
  await clickPane('Changes');
  await wait(`(${text}).includes('changes temporarily unavailable')`);
  assert.equal(await js(`(${text}).includes('Working tree is clean')`), false, 'Failed changes are not a clean tree');
  await js(`window.filesRecovery.changes='normal'`);
  await clickPane('Retry');
  await wait(`(${text}).includes('alpha.txt')`);

  await js(`window.filesRecovery.diff='fail'`);
  await pickEntry('alpha.txt');
  await wait(`(${text}).includes('diff temporarily unavailable')`);
  await js(`window.filesRecovery.diff='normal'`);
  await clickPane('Retry');
  await wait(`(${text}).includes('current-diff-alpha.txt')`);
  assert.equal(await js(`window.filesRecovery.requests.filter(r=>r.kind==='diff').at(-1).path`), 'alpha.txt', 'Retry retains the requested diff');
  await clickPane('‹ Changes');

  await js(`window.filesRecovery.diff='hold';delete window.filesRecovery.holds.diff`);
  await pickEntry('alpha.txt');
  await wait(`!!window.filesRecovery.holds.diff`);
  assert.ok(await js(`(${text}).includes('Loading diff')`), 'Pending diff has a loading state');
  await clickPane('‹ Changes');
  await js(`window.filesRecovery.diff='normal'`);
  await pickEntry('beta.txt');
  await wait(`(${text}).includes('current-diff-beta.txt')`);
  await js(`window.filesRecovery.holds.diff()`);
  await settle();
  assert.equal(await js(`(${text}).includes('current-diff-alpha.txt')`), false, 'Late diff cannot overwrite newer selection');
  await clickPane('‹ Changes');
  await js(`window.filesRecovery.diff='hold-fail';delete window.filesRecovery.holds.diff`);
  await pickEntry('alpha.txt');
  await wait(`!!window.filesRecovery.holds.diff`);
  await clickPane('‹ Changes');
  await js(`window.filesRecovery.holds.diff()`);
  await settle();
  assert.equal(await js(`!!document.querySelector('${pane} [role="alert"]')`), false, 'Back also retires late diff errors');
  assert.ok(await js(`(${text}).includes('beta.txt')`), 'Back retains the changes list');

  await js(`window.filesRecovery.changes='hold-fail';delete window.filesRecovery.holds.changes`);
  await clickPane('Refresh');
  await wait(`!!window.filesRecovery.holds.changes`);
  // The header's count is hidden while loading, so this remains an exact label.
  await clickPane('Changes');
  await wait(`(${text}).includes('File contents for src/notes.md')`);
  await js(`window.filesRecovery.holds.changes()`);
  await settle();
  assert.equal(await js(`!!document.querySelector('${pane} [role="alert"]')`), false, 'Leaving Changes retires its pending failure');

  await js(`window.filesRecovery.stat='hold';delete window.filesRecovery.holds.stat`);
  await focusTab(count);
  await wait(`!!window.filesRecovery.holds.stat`);
  assert.ok(await js(`(${text}).includes('Loading files')`), 'Project switch shows a loading state');
  assert.equal(await js(`(${text}).includes('File contents for src/notes.md')||(${text}).includes('alpha.txt')`), false, 'Old files, diffs, and counts disappear on project switch');
  await js(`window.filesRecovery.stat='normal';window.filesRecovery.holds.stat()`);
  await wait(`(${text}).includes('second-project.txt')`);
  // Start a read in this root, then return to the first root before it fails.
  await js(`window.filesRecovery.stat='hold-fail';delete window.filesRecovery.holds.stat`);
  await pickEntry('src');
  await wait(`!!window.filesRecovery.holds.stat`);
  await js(`window.filesRecovery.stat='normal'`);
  await focusTab(firstTab);
  await wait(`(${text}).includes('first-project.txt')`);
  await js(`window.filesRecovery.holds.stat()`);
  await settle();
  assert.equal(await js(`!!document.querySelector('${pane} [role="alert"]')`), false, 'Old project failure cannot replace the current root');

  await wc.loadURL(origin);
  await wait(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`);
  console.log('Files recovery passed: loading, directory/diff/action retry, stale navigation and errors, and workspace isolation.');
}
module.exports = { runFilesRecovery };
