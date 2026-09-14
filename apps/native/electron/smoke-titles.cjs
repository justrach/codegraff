const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const { nativeImage } = require('electron');
const desktop = require('./test-desktop.cjs');
async function run({win, backend}) {
  const wc=win.webContents, js=code=>wc.executeJavaScript(code), output=process.env.GRAFF_PACKAGED_OUTPUT;
  const root=fs.realpathSync(process.env.GRAFF_CWD), directory=path.join(root,'.graff/sessions');
  const until=async (condition,label)=>{const end=Date.now()+25000;while(Date.now()<end){if(await condition())return;await new Promise(r=>setTimeout(r,50));}fs.writeFileSync(path.join(output,'title-failure.txt'),await js('document.body.innerText'));fs.writeFileSync(path.join(output,'title-failure.png'),(await wc.capturePage()).toPNG());throw Error('Packaged title check: '+label);};
  const click=async selector=>{
    let point;
    await until(async()=>{point=await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});if(!e)return null;e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect(),x=Math.round(r.x+r.width/2),y=Math.round(r.y+r.height/2);return{x,y,hit:e.contains(document.elementFromPoint(x,y))}})()`);return point?.hit;},'pointer target '+selector);
    for(const type of ['mouseDown','mouseUp'])await desktop.testInput(wc,{type,x:point.x,y:point.y,button:'left',clickCount:1});
  };
  const send=async text=>{await click('textarea[aria-label="Prompt"]');for(const keyCode of text)await desktop.testInput(wc,{type:'char',keyCode});await click('[aria-label="Send"]');};
  const shot=async name=>{await js(`new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))`);await new Promise(r=>setTimeout(r,150));fs.writeFileSync(path.join(output,name),(await wc.capturePage()).toPNG());};
  await until(()=>js(`!!document.querySelector('[data-workspace-ready="true"] textarea')`),'workspace ready');
  if(await js(`!!document.querySelector('[aria-label="Close browser"]')`))await click('[aria-label="Close browser"]');
  const phase=process.env.GRAFF_SMOKE_TITLES, report={phase,passed:[]};
  if(phase==='create') {
    const catalog=await js(`fetch('/api/models').then(r=>r.json())`);assert.match(JSON.stringify(catalog.result.current),/lmstudio/i);
    await send('Write retained work to proof.txt.');
    await until(()=>js(`document.body.textContent.includes('Retained work is saved.') && !document.querySelector('article[aria-busy="true"]')`),'text conversation complete');
    assert.equal(fs.readFileSync(path.join(root,'proof.txt'),'utf8'),'retained work');
    const saved=()=>fs.readdirSync(directory).filter(n=>n.endsWith('.session.json')).map(name=>({name,data:JSON.parse(fs.readFileSync(path.join(directory,name),'utf8'))}));
    await until(()=>saved().some(row=>typeof row.data.title==='string' && /retained work/i.test(row.data.title)),'meaningful title saved');
    const text=saved().find(row=>typeof row.data.title==='string' && /retained work/i.test(row.data.title));
    fs.writeFileSync(path.join(output,'text-session.json'),JSON.stringify(text.data,null,2));
    await shot('packaged-text-title.png');
    await click('[title="New chat (⌘T)"]');
    await send('/model lmstudio mock-vision');
    await until(()=>js(`document.body.textContent.includes('mock-vision') && !document.querySelector('article[aria-busy="true"]')`),'image model selected');
    const png=nativeImage.createFromBitmap(Buffer.alloc(48*32*4,180),{width:48,height:32}).toPNG().toString('base64');
    await click('textarea[aria-label="Prompt"]');
    await js(`(()=>{const data=new DataTransfer();data.items.add(new File([Uint8Array.from(atob(${JSON.stringify(png)}),c=>c.charCodeAt(0))],'title-image.png',{type:'image/png'}));document.querySelector('textarea[aria-label="Prompt"]').dispatchEvent(new ClipboardEvent('paste',{clipboardData:data,bubbles:true,cancelable:true}));})()`);
    await until(()=>js(`!!document.querySelector('[aria-label="Preview title-image.png"]')`),'image uploaded');
    await send('Review this image of retained work.');
    await until(()=>js(`document.body.textContent.includes('The image of retained work is visible.') && !document.querySelector('article[aria-busy="true"]')`),'image conversation complete');
    await until(()=>saved().some(row=>row.name!==text.name && typeof row.data.title==='string' && /retained work/i.test(row.data.title)),'image title persisted');
    assert.ok(fs.readFileSync(path.join(process.env.HOME,'requests.json'),'utf8').includes(png),'actual bundled harness sends pasted pixels');
    await shot('packaged-image-title.png');
    // Build historical and explicitly named fixtures from a real saved state.
    const legacy=structuredClone(text.data);legacy.title='Untitled session';
    const user=legacy.messages.find(message=>message.role==='user');assert.ok(user);
    user.content=[{type:'input_text',text:'Recover a legacy conversation title'}];
    fs.writeFileSync(path.join(directory,'legacy-title.session.json'),JSON.stringify(legacy));
    const named=structuredClone(legacy);named.title='My explicit project title';
    fs.writeFileSync(path.join(directory,'named-title.session.json'),JSON.stringify(named));
    report.passed.push('packaged GUI text prompt creates real file and meaningful saved title','image-bearing prompt reaches bundled harness as pixels and saves meaningful title');
  } else {
    await until(()=>js(`document.querySelector('#sidebar-chat-list')?.textContent.includes('Recover a legacy conversation title') && document.querySelector('#sidebar-chat-list')?.textContent.includes('My explicit project title')`),'fresh packaged process recovers legacy and preserves explicit titles');
    assert.equal(await js(`document.querySelector('#sidebar-chat-list').textContent.includes('Untitled session')`),false);
    await js(`Array.from(document.querySelectorAll('#sidebar-chat-list button[data-row]')).find(e=>e.textContent.includes('Recover a legacy conversation title')).setAttribute('data-title-recovery','true')`);
    await click('[data-title-recovery="true"]');
    await until(()=>js(`document.querySelector('[data-tab-id] button[aria-pressed=\"true\"]')?.textContent.includes('Recover a legacy')`),'legacy snapshot opens');
    await until(()=>js(`document.querySelector('[data-chat][data-focused=\"true\"]')?.textContent.includes('Recover a legacy conversation title')`),'recovered transcript renders');
    await shot('packaged-recovered-titles.png');
    report.passed.push('fresh packaged process recovers saved input_text placeholder title','explicit saved title remains unchanged','recovered saved conversation opens through real sidebar');
  }
  report.desktop=desktop.assertSafe();fs.writeFileSync(path.join(output,`titles-${phase}.json`),JSON.stringify(report,null,2));
}
module.exports={run};
