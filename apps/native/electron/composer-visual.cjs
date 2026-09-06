const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
async function runComposerVisual({ win, output }) {
  const js = code => win.webContents.executeJavaScript(code);
  await new Promise(r => setTimeout(r, 1600));
  await js(`document.querySelector('[aria-label="Choose model"] span.truncate').textContent='Example model with a long display name'`);
  for (const width of [220, 280, 360, 420, 520]) {
    console.log('Composer geometry:', width);
    await js(`document.querySelector('[data-promptbar]').style.width='${width}px'`);
    await js('Promise.race([new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))),new Promise((_,reject)=>setTimeout(()=>reject(Error("Composer did not receive a paint frame")),3000))])');
    const result = await js(`(()=>{
      const p=document.querySelector('[data-promptbar]'),area=p.getBoundingClientRect();
      const labels=['Add attachments and sources','Choose model','Select effort','Start dictation','Send'];
      const rects=labels.map(label=>{const b=p.querySelector('[aria-label="'+label+'"]'),r=b?.getBoundingClientRect();return r&&{label,x:r.x,y:r.y,right:r.right,bottom:r.bottom,width:r.width}}).filter(Boolean);
      const overlaps=[];for(let i=0;i<rects.length;i++)for(let j=i+1;j<rects.length;j++){
        const a=rects[i],b=rects[j];if(a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y)overlaps.push([a.label,b.label]);
      }
      return {rects,overlaps,outside:rects.filter(r=>r.x<area.x||r.right>area.right),model:p.querySelector('[aria-label="Choose model"]').getBoundingClientRect().width};
    })()`);
    assert.deepEqual(result.overlaps, [], `${width}px: ${JSON.stringify(result)}`);
    assert.deepEqual(result.outside, [], `${width}px: controls must remain inside composer`);
    assert.ok(result.model >= 44, `model remains selectable at ${width}px: ${JSON.stringify(result)}`);
    await js(`document.querySelector('[aria-label="Choose model"]').click()`);
    await new Promise(r => setTimeout(r, 100));
    assert.equal(await js(`document.querySelector('[aria-label="Choose model"]').getAttribute('aria-expanded')`), 'true');
    await js(`document.querySelector('[aria-label="Close model picker"]').click()`);
    if (width === 280) fs.writeFileSync(path.join(output, 'composer-narrow.png'), (await win.webContents.capturePage()).toPNG());
  }
  await js(`document.querySelector('[data-promptbar]').style.width=''`);
  console.log('Composer geometry passed at five pane widths; controls remain separate and model picker opens.');
}
module.exports = { runComposerVisual };
