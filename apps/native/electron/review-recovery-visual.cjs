const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runReviewRecovery({ win, origin, output }) {
  const wc=win.webContents, js=code=>wc.executeJavaScript(code);
  const wait=async code=>{for(let i=0;i<120;i++){if(await js(code))return;await new Promise(r=>setTimeout(r,50));}throw Error(`Review recovery timed out: ${code}`);};
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('button[aria-label="Changes"]')`);
  await js(`(()=>{
    const previous=window.fetch,json=value=>new Response(JSON.stringify(value),{headers:{'content-type':'application/json'}});
    window.reviewRecovery={mode:'fail',holds:[]};
    window.fetch=async(input,options)=>{
      const url=new URL(String(input),location.origin),r=window.reviewRecovery;
      if(url.pathname!=='/api/git')return previous(input,options);
      if(r.mode==='fail')return new Response(JSON.stringify({error:'Cannot read changes for this folder'}),{status:503,headers:{'content-type':'application/json'}});
      if(options?.method==='POST') {
        if(r.mode==='diff-fail')return new Response(JSON.stringify({error:'Cannot read file diff'}),{status:503,headers:{'content-type':'application/json'}});
        const body=JSON.parse(options.body);
        return json({diff:'diff --git a/'+body.path+' b/'+body.path+'\\n--- a/'+body.path+'\\n+++ b/'+body.path+'\\n@@ -1 +1 @@\\n-old\\n+content-'+body.scope+'-'+body.root+'\\n'});
      }
      const scope=url.searchParams.get('scope'),root=url.searchParams.get('root');
      r.base??=root;
      if(scope==='staged'&&r.mode==='hold')await new Promise(resolve=>r.holds.push(resolve));
      return json({root,branch:root==='/demo/other-tree'?'other-branch':'main',files:[{path:scope+'.txt',add:1,del:1,untracked:false,status:' M'}],totalAdd:1,totalDel:1,commits:[],worktrees:[{path:r.base,branch:'main'},{path:'/demo/other-tree',branch:'other-branch'}]});
    };
  })()`);
  await js(`document.querySelector('button[aria-label="Changes"]').click()`);
  await wait(`!!document.querySelector('[aria-label="Workspace changes"] [role="alert"]')`);
  assert.equal(await js(`document.querySelector('[aria-label="File diff"]').textContent.includes('Working tree is clean')`),false,'Failed Git reads are not clean worktrees');
  assert.ok(await js(`!!document.querySelector('[aria-label="Updates unavailable"]')`),'Live indicator reflects failure');
  await js(`window.reviewRecovery.mode='normal';document.querySelector('[aria-label="Workspace changes"] [role="alert"] button').click()`);
  await wait(`document.querySelector('[aria-label="File diff"]').textContent.includes('content-all-')`);
  await js(`window.reviewRecovery.mode='hold';Array.from(document.querySelectorAll('[aria-label="Changes scope"] button')).find(b=>b.textContent==='Staged').click()`);
  await wait(`window.reviewRecovery.holds.length>0`);
  assert.equal(await js(`!!document.querySelector('[aria-label="Changed file"]')`),false,'Previous filter files must not remain selectable');
  assert.equal(await js(`document.querySelector('[aria-label="File diff"]').textContent.includes('content-all-')`),false,'Previous diff disappears while loading another filter');
  await js(`window.reviewRecovery.mode='normal';Array.from(document.querySelectorAll('[aria-label="Changes scope"] button')).find(b=>b.textContent==='Unstaged').click()`);
  await wait(`document.querySelector('[aria-label="File diff"]').textContent.includes('content-unstaged-')`);
  await js(`window.reviewRecovery.holds.forEach(resolve=>resolve())`);
  await js(`new Promise(r=>setTimeout(r,100))`);
  assert.equal(await js(`document.querySelector('[aria-label="Changed file"]').value`),'unstaged.txt','Late staged response cannot overwrite the selected scope');
  await js(`window.reviewRecovery.mode='fail';const e=document.querySelector('[aria-label="Review worktree"]');e.value='/demo/other-tree';e.dispatchEvent(new Event('change',{bubbles:true}))`);
  await wait(`!!document.querySelector('[aria-label="Workspace changes"] [role="alert"]')`);
  assert.equal(await js(`document.querySelector('[aria-label="File diff"]').textContent.includes('content-')`),false,'Failed worktree switch cannot retain another folder’s diff');
  fs.writeFileSync(path.join(output,'changes-retry.png'),(await wc.capturePage()).toPNG());
  await js(`window.reviewRecovery.mode='normal';document.querySelector('[aria-label="Refresh changes"]').click()`);
  await wait(`document.querySelector('[aria-label="File diff"]').textContent.includes('content-unstaged-/demo/other-tree')`);
  await js(`window.reviewRecovery.mode='diff-fail';document.querySelector('[aria-label="Refresh changes"]').click()`);
  await wait(`!!document.querySelector('[aria-label="Workspace changes"] [role="alert"]')`);
  assert.ok(await js(`document.querySelector('[aria-label="File diff"]').textContent.includes('Changes unavailable')`),'Diff failures must not masquerade as binary files');
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  win.focus();
  console.log('Review recovery passed: unavailable vs clean, explicit retry, stale filters/worktrees, and diff failures.');
}
module.exports={runReviewRecovery};
