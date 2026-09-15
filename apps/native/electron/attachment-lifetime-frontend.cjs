// Exercise the actual paste handler, upload route and ACP image staging.
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path');
const { nativeImage } = require('electron');
async function runAttachments({win,origin,temp,output,requests,workspace,send,click,until,report}) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  if(await js(`!!document.querySelector('[aria-label="Close browser"]')`))await click('[aria-label="Close browser"]');
  const directory = path.join(temp, 'graff-native-attachments');
  const pixels = Buffer.alloc(64*48*4);
  for(let i=0;i<pixels.length;i+=4) { pixels[i]=180;pixels[i+1]=120;pixels[i+2]=30;pixels[i+3]=255; }
  const png = nativeImage.createFromBitmap(pixels,{width:64,height:48}).toPNG().toString('base64');
  const paste = async name => {
    await click('textarea[aria-label="Prompt"]');
    await js(`(()=>{
      const bytes=Uint8Array.from(atob(${JSON.stringify(png)}),c=>c.charCodeAt(0));
      const data=new DataTransfer();data.items.add(new File([bytes],${JSON.stringify(name)},{type:'image/png'}));
      document.querySelector('textarea[aria-label="Prompt"]').dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));
    })()`);
    await until(()=>js(`!!document.querySelector(${JSON.stringify(`[aria-label="Preview ${name}"]`)})`),'uploaded paste '+name);
    const found=fs.readdirSync(directory).find(file=>file.endsWith('-'+name));
    assert.ok(found,'Paste must write a real owned file');return path.join(directory,found);
  };
  await send('/model lmstudio mock-vision');
  await until(()=>js(`document.body.textContent.includes('mock-vision') && !document.querySelector('article[aria-busy="true"]')`),'vision model selected');
  const aged=await paste('aged.png');
  const old=new Date(Date.now()-48*60*60*1000);fs.utimesSync(aged,old,old);
  const removed=await paste('remove.png');
  assert.ok(fs.existsSync(aged),'Another upload must preserve an aged active draft');
  await click('[aria-label="Preview aged.png"]');
  await until(()=>js(`!!document.querySelector('dialog img')?.complete`),'draft preview pixels');
  fs.writeFileSync(path.join(output,'attachment-aged-draft.png'),(await wc.capturePage()).toPNG());
  await click('[aria-label="Close image preview"]');
  await click('[aria-label="Remove remove.png"]');
  await until(()=>!fs.existsSync(removed),'discarded paste file cleanup');
  await send('Describe the pasted image in one sentence.');
  await until(()=>js(`document.body.textContent.includes('The pasted image was received.') && !document.querySelector('article[aria-busy="true"]')`),'real image turn completion',25000);
  const calls=JSON.parse(fs.readFileSync(requests,'utf8'));
  fs.writeFileSync(path.join(output,'attachment-requests.json'),JSON.stringify(calls,null,2));
  assert.ok(JSON.stringify(calls).includes(png),'Actual model requests must contain the pasted PNG bytes');
  const record=JSON.parse(fs.readFileSync(path.join(directory,'.ownership',path.basename(aged)+'.json'),'utf8'));
  assert.equal(record.retained,true,'ACP acceptance must retain replay pixels');
  await fetch(origin+'/api/attach',{method:'DELETE',headers:{'content-type':'application/json'},body:JSON.stringify({paths:[aged]})});
  assert.ok(fs.existsSync(aged),'Discard cannot delete pixels retained by an accepted message');
  assert.equal((await fetch(origin+'/api/attach?name='+encodeURIComponent(path.basename(aged)))).status,200);
  fs.writeFileSync(path.join(output,'attachment-sent-retained.png'),(await wc.capturePage()).toPNG());
  await click('[title="New chat (⌘T)"]');
  const focused=await js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`);
  const closed=await paste('closed.png');
  await click(`[data-tab-members="${focused}"] [aria-label="Close tab"]`);
  await until(()=>!fs.existsSync(closed),'closed draft file cleanup');
  for (const name of ['sessions','traces']) {
    const source=path.join(workspace,'.graff',name);
    if(fs.existsSync(source))fs.cpSync(source,path.join(output,'attachment-'+name),{recursive:true});
  }
  const savedDirectory=path.join(workspace,'.graff','sessions');
  const savedName=fs.readdirSync(savedDirectory).find(name=>name.endsWith('.session.json') && fs.readFileSync(path.join(savedDirectory,name),'utf8').includes(path.basename(aged)));
  assert.ok(savedName,'Find the actual saved image conversation before deleting it');
  const savedFile=path.join(savedDirectory,savedName);
  const transcriptFile=savedFile.replace(/\.session\.json$/,'.transcript.jsonl');
  assert.ok(fs.existsSync(transcriptFile),'The real harness must have written its companion transcript');
  // Seed a rotated generation from the real transcript; rotation itself is covered by harness tests.
  const rotatedFile=savedFile.replace(/\.session\.json$/,'.transcript.1.jsonl');
  fs.copyFileSync(transcriptFile,rotatedFile);
  const archiveName='attachment-archive-check';
  fs.copyFileSync(savedFile,path.join(savedDirectory,archiveName+'.session.json'));
  fs.copyFileSync(transcriptFile,path.join(savedDirectory,archiveName+'.transcript.jsonl'));
  fs.copyFileSync(rotatedFile,path.join(savedDirectory,archiveName+'.transcript.1.jsonl'));
  const archiveResponse=await fetch(origin+'/api/sessions?'+new URLSearchParams({root:workspace,name:archiveName}),{method:'DELETE'});
  assert.equal(archiveResponse.status,200,'Archive the copied real checkpoint through the production route');
  assert.equal(fs.existsSync(path.join(savedDirectory,archiveName+'.transcript.jsonl')),false);
  assert.equal(fs.existsSync(path.join(savedDirectory,archiveName+'.transcript.1.jsonl')),false);
  const archivedRotated=path.join(savedDirectory,'archived',archiveName+'.transcript.1.jsonl');
  assert.ok(fs.readFileSync(archivedRotated,'utf8').includes(path.basename(aged)));
  const archivedTranscript=path.join(savedDirectory,'archived',archiveName+'.transcript.jsonl');
  assert.ok(fs.readFileSync(archivedTranscript,'utf8').includes(path.basename(aged)),'Archived replay must retain its image reference');
  assert.ok(fs.existsSync(path.join(savedDirectory,'archived',archiveName+'.session.json')));
  await click('[data-tab-id]:has(button[aria-pressed="true"]) [aria-label="Close tab"]');
  if(await js(`!!document.querySelector('[aria-label="Expand sidebar"]')?.checkVisibility()`))await click('[aria-label="Expand sidebar"]');
  else if(await js(`!!document.querySelector('[aria-label="Open navigation"]')?.checkVisibility()`))await click('[aria-label="Open navigation"]');
  await until(()=>js(`!!document.querySelector('#sidebar-chat-list button[data-row]')`),'closed image conversation in History');
  await js(`document.querySelector('#sidebar-chat-list button[data-row]').parentElement.querySelector('button[aria-label^="Actions for "]').setAttribute('data-audit-delete-menu','true')`);
  await click('[data-audit-delete-menu="true"]');
  await until(()=>js(`!!document.querySelector('button[aria-label^="Delete "]')`),'saved conversation delete action');
  await click('button[aria-label^="Delete "]');
  await until(()=>!fs.existsSync(savedFile),'session removed after its writer exits');
  assert.equal(fs.existsSync(transcriptFile),false,'Deleting a saved chat must also remove its full transcript');
  assert.equal(fs.existsSync(rotatedFile),false,'Deleting a saved chat must remove its rotated transcript');
  await new Promise(resolve=>setTimeout(resolve,250));
  assert.equal(fs.existsSync(savedFile),false,'An exiting chat worker must not recreate its deleted session');
  fs.writeFileSync(path.join(output,'attachment-session-deleted.png'),(await wc.capturePage()).toPNG());
  assert.ok(fs.existsSync(archivedTranscript),'Deleting the original chat must preserve its independent archive');
  assert.ok(fs.existsSync(archivedRotated),'Deleting the original must preserve the archived rotated transcript');
  assert.ok(fs.existsSync(aged),'An independent archived replay still needs the original image pixels');
  report.passed.push('real sidebar delete retires its writer and removes checkpoint plus both transcript generations; production archive preserves all replay files');
  report.passed.push('synthetic clipboard event through real GUI paste/upload/ACP: aged draft survives, removed and closed drafts release files, sent PNG reaches model and stays available for replay');
  fs.writeFileSync(path.join(output,'attachment-requests.json'),JSON.stringify(calls,null,2));
}
module.exports={runAttachments};
