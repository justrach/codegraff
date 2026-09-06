const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function runTerminalVisual({win,output}) {
  const wc=win.webContents,js=source=>wc.executeJavaScript(source);
  const wait=async source=>{for(let i=0;i<150;i++){if(await js(source))return;await sleep(50);}throw Error(`Terminal UI timeout: ${source}`);};
  const toggle=()=>js(`window.dispatchEvent(new CustomEvent('graff-desktop-action',{detail:'terminal'}))`);
  await toggle();await wait(`!!document.querySelector('.xterm-helper-textarea')`);
  await wait(`document.querySelector('[data-workspace-terminal]').textContent.includes('Shell ready')`);
  await js(`document.querySelector('.xterm-helper-textarea').focus()`);
  await wc.insertText("printf '\\n%s\\n' TERMINAL_GUI_READY");
  wc.sendInputEvent({type:"keyDown",keyCode:"Return"});wc.sendInputEvent({type:"keyUp",keyCode:"Return"});
  await wait(`Array.from(document.querySelectorAll('.xterm-rows > div')).some(row=>row.textContent.trim()==='TERMINAL_GUI_READY')`);
  const before=await js(`document.querySelector('[data-workspace-terminal]').getBoundingClientRect().height`);
  await js(`document.querySelector('[aria-label="Resize terminal"]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowUp',bubbles:true}))`);
  assert.ok(await js(`document.querySelector('[data-workspace-terminal]').getBoundingClientRect().height`)>before);
  await toggle();assert.equal(await js(`document.querySelector('[data-workspace-terminal]').hidden`),true);
  await toggle();await wait(`!document.querySelector('[data-workspace-terminal]').hidden`);
  assert.ok(await js(`Array.from(document.querySelectorAll('.xterm-rows > div')).some(row=>row.textContent.trim()==='TERMINAL_GUI_READY')`));
  await js(`new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))`);
  if(output)fs.writeFileSync(path.join(output,'terminal.png'),(await wc.capturePage()).toPNG());
  await js(`Array.from(document.querySelectorAll('[data-workspace-terminal] button')).find(b=>b.textContent==='End session').click()`);
  await wait(`document.querySelector('[data-workspace-terminal]').textContent.includes('Shell exited')`);
  await toggle();console.log('Terminal GUI checks passed: real shell input, rendering, resize, hide/restore and end session.');
}
module.exports={runTerminalVisual};
