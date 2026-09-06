const assert = require('node:assert/strict');
const fs = require('node:fs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function smokeModelPicker({ win }) {
  const js = async source => { try { return await win.webContents.executeJavaScript(source); } catch (error) { throw Error(`UI fixture failed (${source.slice(0, 160)}): ${error.message}`); } };
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await sleep(100); } throw Error(`Picker check timed out: ${source}`); };
  const click = source => js(`document.querySelector(${JSON.stringify(source)}).click()`);
  const type = value => js(`(()=>{const el=document.querySelector('[aria-label="Filter models"]');Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,${JSON.stringify(value)});el.dispatchEvent(new Event('input',{bubbles:true}));})()`);
  const bounds = () => js(`(()=>{const rect=document.querySelector('[aria-label="Choose a model"]').getBoundingClientRect(), search=document.querySelector('[aria-label="Filter models"]').getBoundingClientRect();return {top:rect.top,bottom:rect.bottom,left:rect.left,right:rect.right,width:innerWidth,height:innerHeight,searchTop:search.top,searchBottom:search.bottom}})()`);
  const [width, height] = win.getSize();
  try {
    win.setSize(900, 600); await sleep(250);
    await wait(`!!document.querySelector('[aria-label="Choose model"]')`);
    await click('[aria-label="Choose model"]');
    await wait(`!!document.querySelector('[aria-label="Choose a model"]')`);
    let rect = await bounds();
    assert.ok(rect.top >= 47 && rect.bottom <= rect.height - 8 && rect.left >= 8 && rect.right <= rect.width - 8, JSON.stringify(rect));
    assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Filter models');
    assert.equal(await js(`document.querySelector('[role=option]').getAttribute('aria-selected')`), 'true');
    const current = await js(`document.querySelector('[role=option]').textContent`);
    const before = await js(`document.querySelector('[aria-label="Filter models"]').getBoundingClientRect().top`);
    await js(`document.querySelector('[aria-label="Available models"]').scrollTop=10000`);
    assert.equal(await js(`document.querySelector('[aria-label="Filter models"]').getBoundingClientRect().top`), before);
    await type('no-model-matches-this');
    await wait(`document.querySelectorAll('[role=option]').length===0`);
    rect = await bounds(); assert.ok(rect.top >= 47 && rect.bottom <= rect.height - 8, JSON.stringify(rect));
    assert.equal(rect.searchTop, before, 'filtering keeps the search field in place');
    await type('');
    await wait(`document.querySelectorAll('[role=option]').length>0`);
    assert.equal(await js(`document.querySelector('[aria-label="Available models"]').scrollTop`), 0);
    await js(`document.querySelector('[aria-label="Filter models"]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}))`);
    assert.equal(await js(`document.activeElement.getAttribute('aria-activedescendant')===document.querySelectorAll('[role=option]')[1].id`), true);
    // Click the current choice through real mouse events; it must stay clickable in the portal.
    const point = await js(`(()=>{const r=document.querySelector('[role=option]').getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
    win.webContents.sendInputEvent({ type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
    win.webContents.sendInputEvent({ type: 'mouseUp', ...point, button: 'left', clickCount: 1 });
    await wait(`!document.querySelector('[aria-label="Choose a model"]')`);
    await click('[aria-label="Choose model"]');
    await wait(`!!document.querySelector('[aria-label="Choose a model"]')`);
    assert.equal(await js(`document.querySelector('[role=option]').textContent`), current);
    await sleep(150);
    if (process.env.GRAFF_MODEL_PICKER_SCREENSHOT) fs.writeFileSync(process.env.GRAFF_MODEL_PICKER_SCREENSHOT, (await win.webContents.capturePage()).toPNG());
    await js(`document.querySelector('[aria-label="Filter models"]').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))`);
    await wait(`!document.querySelector('[aria-label="Choose a model"]')`);
    assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Choose model');
    return 'minimum-window bounds, current-first order, fixed search, filtering, keyboard navigation, mouse selection and focus restoration';
  } finally { win.setSize(width, height); }
}
module.exports = { smokeModelPicker };
