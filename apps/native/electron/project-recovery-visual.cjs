const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runProjectRecovery({ win, origin, output }) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const wait = async code => { for (let i = 0; i < 120; i++) { if (await js(code)) return; await new Promise(r => setTimeout(r, 50)); } throw Error(`Recovery check timed out: ${code}`); };
  const click = (selector, text) => js(`Array.from(document.querySelectorAll(${JSON.stringify(selector)})).find(e=>e.textContent.trim()===${JSON.stringify(text)}).click()`);
  const input = (label, value) => js(`(()=>{const e=document.querySelector('[aria-label="${label}"]');e.focus();Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,${JSON.stringify(value)});e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  const library = '[data-conversation-library]';
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('[data-project-context]')`);
  await js(`(() => {
    const previous = window.fetch;
    const json = (value, status=200) => new Response(JSON.stringify(value), {status,headers:{'content-type':'application/json'}});
    window.recovery = {mode:'fail',detail:'fail',holds:{},requests:[],pageFailures:0};
    const row = name => ({name,title:name,updatedMs:Date.now(),model:null,provider:null,size:100,local:true});
    window.fetch = async (input, options) => {
      const url = new URL(String(input),location.origin), r=window.recovery;
      r.requests.push({url:String(input),body:options?.body});
      if(url.pathname==='/api/workspaces') {
        const folder=url.searchParams.get('path');
        const listing={path:folder,parent:'/demo',home:'/demo',default:'/demo/field-notes',git:false,entries:[{name:'child',path:folder+'/child',git:false}]};
        if(folder==='/demo/missing') return json({error:'Folder does not exist'},404);
        if(folder==='/demo/slow') await new Promise(resolve=>r.holds.folder=resolve);
        return json(listing);
      }
      if(url.pathname==='/api/sessions'&&url.searchParams.has('name')) {
        const name=url.searchParams.get('name');
        if(r.detail==='fail') return json({error:'Temporarily unavailable'},503);
        if(r.detail==='hold') await new Promise(resolve=>r.holds.detail=resolve);
        return json({...row(name),messages:[{role:'user',content:'Continue this saved work.'},{role:'assistant',content:'Restored test conversation.'}]});
      }
      if(url.pathname==='/api/sessions'&&url.searchParams.get('limit')==='24') {
        if(r.mode==='fail') return json({error:'Temporarily unavailable'},503);
        const q=url.searchParams.get('q');
        if(q==='pending') { await new Promise(resolve=>r.holds.list=resolve); return json({sessions:[row('stale-conversation')],total:1,nextCursor:null}); }
        if(q==='fresh') return json({sessions:[row('fresh-conversation')],total:1,nextCursor:null});
        if(r.mode==='more') {
          if(url.searchParams.has('cursor')&&r.pageFailures++===0) return json({error:'Page unavailable'},503);
          return json({sessions:[row(url.searchParams.has('cursor')?'recovery-b':'recovery-a')],total:2,nextCursor:url.searchParams.has('cursor')?null:'next'});
        }
        return json({sessions:[row('recovery-a'),row('recovery-b')],total:2,nextCursor:null});
      }
      return previous(input, options);
    };
  })()`);

  await js(`document.querySelector('button[aria-label="Conversations"]').click()`);
  await wait(`!!document.querySelector('${library} [role="alert"]')`);
  assert.equal(await js(`document.querySelector('${library}').textContent.includes('No conversations')`), false, 'Failure must not masquerade as an empty project');
  await js(`window.recovery.mode='normal'`);
  await click(`${library} button`, 'Retry');
  await wait(`document.querySelector('${library}').textContent.includes('recovery-a')`);

  await input('Search conversations', 'pending');
  await wait(`!!window.recovery.holds.list`);
  assert.equal(await js(`document.querySelector('${library}').textContent.includes('recovery-a')`), false, 'Old results cannot remain selectable during a new lookup');
  await input('Search conversations', 'fresh');
  await wait(`document.querySelector('${library}').textContent.includes('fresh-conversation')`);
  await js(`window.recovery.holds.list()`);
  await js(`new Promise(r=>setTimeout(r,100))`);
  assert.equal(await js(`document.querySelector('${library}').textContent.includes('stale-conversation')`), false, 'Late search response cannot replace the latest results');

  await js(`window.recovery.mode='more'`);
  await input('Search conversations', '');
  await wait(`!!document.querySelector('${library} [role="alert"]')`);
  assert.ok(await js(`document.querySelector('${library}').textContent.includes('recovery-a')`), 'Pagination failure keeps the loaded page');
  await click(`${library} button`, 'Retry');
  await wait(`document.querySelector('${library}').textContent.includes('recovery-b')`);

  const tabs = await js(`document.querySelectorAll('[aria-label="Close tab"]').length`);
  const pick = name => js(`Array.from(document.querySelectorAll('${library} li button')).find(e=>e.textContent.includes(${JSON.stringify(name)})).click()`);
  await pick('recovery-a');
  await wait(`!!document.querySelector('[data-conversation-open] [role="alert"]')`);
  assert.ok(await js(`!!document.querySelector('[aria-label="Search conversations"]')`), 'Failed resume keeps the conversation picker visible');
  fs.writeFileSync(path.join(output,'conversation-retry.png'),(await wc.capturePage()).toPNG());
  await js(`window.recovery.detail='normal'`);
  await click('[data-conversation-open] button', 'Retry');
  await wait(`document.body.textContent.includes('Restored test conversation.')`);
  assert.equal(await js(`document.querySelectorAll('[aria-label="Close tab"]').length`), tabs+1);
  assert.equal(await js(`!!document.querySelector('[data-conversation-open]')`),false);

  await js(`document.querySelector('button[aria-label="Conversations"]').click();window.recovery.mode='normal';window.recovery.detail='hold'`);
  await wait(`document.querySelector('${library}')?.textContent.includes('recovery-b')`);
  await pick('recovery-b');
  await wait(`!!window.recovery.holds.detail`);
  await click('[data-conversation-open] button', 'Cancel');
  await js(`window.recovery.holds.detail()`);
  await js(`new Promise(r=>setTimeout(r,100))`);
  assert.equal(await js(`document.querySelectorAll('[aria-label="Close tab"]').length`),tabs+1,'Cancelled resume cannot open a late tab');
  await js(`delete window.recovery.holds.detail`);
  await pick('recovery-b');
  await wait(`!!window.recovery.holds.detail`);
  await js(`document.querySelector('button[aria-label="New chat"]').click()`);
  await wait(`!document.querySelector('[data-conversation-open]')`);
  await js(`window.recovery.holds.detail()`);
  await js(`new Promise(r=>setTimeout(r,100))`);
  assert.equal(await js(`document.querySelectorAll('[aria-label="Close tab"]').length`),tabs+2,'Starting a new chat cancels a pending resume');

  await js(`document.querySelector('button[aria-label="Open folder…"]').click()`);
  await wait(`!!document.querySelector('[role="dialog"] button[title$="/child"]')`);
  await input('Folder path','/demo/missing');
  await click('[role="dialog"] button','Open folder');
  await wait(`!!document.querySelector('[role="dialog"] [role="alert"]')`);
  assert.equal(await js(`document.querySelectorAll('[role="dialog"] button[title$="/child"]').length`),0,'Failed path must not leave the old folder selectable');
  fs.writeFileSync(path.join(output,'folder-retry.png'),(await wc.capturePage()).toPNG());
  await input('Folder path','/demo/slow');
  await click('[role="dialog"] button','Go');
  await wait(`!!window.recovery.holds.folder`);
  await input('Folder path','/demo/recovered');
  await click('[role="dialog"] button','Open folder');
  await wait(`!document.querySelector('[role="dialog"]')&&document.querySelector('[data-project-context]')?.textContent.includes('/demo/recovered')`);
  await js(`window.recovery.holds.folder()`);
  await js(`new Promise(r=>setTimeout(r,100))`);
  assert.ok(await js(`document.querySelector('[data-project-context]').textContent.includes('/demo/recovered')`),'A late folder listing cannot replace the chosen folder');
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  win.show(); win.focus();
  console.log('Project recovery passed: initial/paged retry, stale searches, resume retry/cancel, navigation races, and typed folder validation.');
}
module.exports={runProjectRecovery};
