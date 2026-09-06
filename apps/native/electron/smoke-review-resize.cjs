const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function smokeReviewResize({ win }) {
  const js = source => win.webContents.executeJavaScript(source);
  const paneWidth = () => js(`document.querySelector('[aria-label="Workspace changes"]').getBoundingClientRect().width`);
  const original = await paneWidth();
  const point = await js(`(()=>{const r=document.querySelector('[aria-label="Resize changes panel"]').getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+100)}})()`);
  win.webContents.sendInputEvent({ type: 'mouseMove', ...point });
  win.webContents.sendInputEvent({ type: 'mouseDown', ...point, button: 'left', clickCount: 1 });
  win.webContents.sendInputEvent({ type: 'mouseMove', x: point.x + 90, y: point.y, button: 'left' });
  await sleep(100);
  win.webContents.sendInputEvent({ type: 'mouseUp', x: point.x + 90, y: point.y, button: 'left', clickCount: 1 });
  await sleep(100);
  const resized = await paneWidth();
  assert.ok(Math.abs(original - resized - 90) < 3, `drag changed width ${original} → ${resized}`);
  await js(`document.querySelector('[aria-label="Close changes"]').click()`); await sleep(100);
  await js(`document.querySelector('[aria-label="Review workspace changes"]').click()`); await sleep(150);
  assert.ok(Math.abs(await paneWidth() - resized) < 2, 'width survives reopening');
  await js(`document.querySelector('[aria-label="Resize changes panel"]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',bubbles:true}))`); await sleep(100);
  assert.ok(Math.abs(await paneWidth() - resized - 20) < 2, 'keyboard expands pane');
  await js(`document.querySelector('[aria-label="Resize changes panel"]').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}))`); await sleep(100);
  assert.ok(Math.abs(await paneWidth() - original) < 2, 'double-click restores default');
  assert.equal(await js('document.body.style.cursor'), '');
  return 'mouse drag, reopen persistence, keyboard adjustment and double-click reset';
}
module.exports = { smokeReviewResize };
