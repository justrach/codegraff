const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runSplitComposerVisual({ win, output, key }) {
  const js = source => win.webContents.executeJavaScript(source);
  await key('d', { metaKey: true });
  await key('d', { metaKey: true });
  await new Promise(resolve => setTimeout(resolve, 1600));
  try {
    assert.equal(await js(`document.querySelectorAll('[data-chat]').length`), 3);
    win.setSize(1440, 900);
    await new Promise(resolve => setTimeout(resolve, 150));
    await js(`document.querySelectorAll('textarea[aria-label="Prompt"]').forEach(e=>{
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'Please review the changes in this workspace and explain how the new application controls work when I resize the window.');
      e.dispatchEvent(new Event('input',{bubbles:true}));
    })`);
    await new Promise(resolve => setTimeout(resolve, 150));
    for (const width of [1440, 1100, 900]) {
      win.setSize(width, 900);
      await new Promise(resolve => setTimeout(resolve, 150));
      const geometry = await js(`Array.from(document.querySelectorAll('[data-chat]')).map(pane => {
        const p=pane.querySelector('[data-promptbar]'), area=p.getBoundingClientRect();
        const buttons=Array.from(p.querySelectorAll('button[aria-label]')).filter(b=>b.offsetWidth);
        const rects=buttons.map(b=>{const r=b.getBoundingClientRect();return {label:b.ariaLabel,x:r.x,y:r.y,right:r.right,bottom:r.bottom,width:r.width}});
        const overlaps=[];
        for(let i=0;i<rects.length;i++)for(let j=i+1;j<rects.length;j++){
          const a=rects[i],b=rects[j];if(a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y)overlaps.push([a.label,b.label]);
        }
        const input=p.querySelector('textarea');
        return {width:area.width, overlaps, outside:rects.filter(r=>r.x<area.x-1||r.right>area.right+1),
          clipped:input.scrollHeight>input.clientHeight+1&&getComputedStyle(input).overflowY==='hidden',
          modelWidth:p.querySelector('[aria-label="Choose model"]').getBoundingClientRect().width};
      })`);
      fs.writeFileSync(path.join(output, `three-splits-${width}.png`), (await win.webContents.capturePage()).toPNG());
      for (const pane of geometry) {
        assert.deepEqual(pane.overlaps, [], `${width}px split: ${JSON.stringify(pane)}`);
        assert.deepEqual(pane.outside, [], `${width}px split: ${JSON.stringify(pane)}`);
        assert.ok(pane.modelWidth >= 44, `${width}px split model is usable: ${JSON.stringify(pane)}`);
        assert.equal(pane.clipped, false, `${width}px resize hides part of the draft: ${JSON.stringify(pane)}`);
      }
    }
  } finally {
    await js(`Array.from(document.querySelectorAll('[aria-label="Close this split"]')).forEach(b=>b.click())`);
    await key('w', { metaKey: true });
    await key('w', { metaKey: true });
    await js(`document.querySelectorAll('textarea[aria-label="Prompt"]').forEach(e=>{
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,'');e.dispatchEvent(new Event('input',{bubbles:true}));
    })`);
    win.setSize(1100, 760);
  }
}
module.exports = { runSplitComposerVisual };
