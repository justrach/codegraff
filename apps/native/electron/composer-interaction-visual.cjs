const assert = require('node:assert/strict');
const { ipcMain } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

async function runComposerInteractions({ win, origin, output }) {
  const wc = win.webContents, js = source => wc.executeJavaScript(source);
  const pause = () => new Promise(resolve => setTimeout(resolve, 80));
  const wait = async source => {
    for (let i = 0; i < 150; i++) { if (await js(source)) return; await pause(); }
    throw Error(`Composer interaction timed out: ${source}`);
  };
  const key = async (key, extra = {}) => {
    await js(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown',${JSON.stringify({ key, bubbles: true, cancelable: true, ...extra })}))`);
    await pause();
  };
  const input = async (text, selector = '[data-chat][data-focused="true"] textarea') => {
    await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});e.focus();Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(e,${JSON.stringify(text)});e.dispatchEvent(new Event('input',{bubbles:true}));})()`);
    await pause();
  };
  const frames = () => js('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>resolve(true))))');
  const pointer = async selector => {
    await js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'nearest',behavior:'instant'})`);
    for (let attempt = 0; attempt < 30; attempt++) {
      await frames();
      const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
      // Hover can scroll the active option or reposition its portal. Settle it
      // before pressing, then verify that the coordinates still hit this row.
      wc.sendInputEvent({ type: 'mouseMove', ...point });
      await frames();
      const ready = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)===${point.x}&&Math.round(r.y+r.height/2)===${point.y}&&e.contains(document.elementFromPoint(${point.x},${point.y}));})()`);
      if (!ready) continue;
      wc.sendInputEvent({ type: 'mouseDown', button: 'left', clickCount: 1, ...point });
      wc.sendInputEvent({ type: 'mouseUp', button: 'left', clickCount: 1, ...point });
      await pause();
      return;
    }
    throw Error(`Pointer target did not settle: ${selector}`);
  };
  const draft = id => js(`document.querySelector('[data-chat="${id}"] textarea').value`);
  const focused = () => js(`Number(document.querySelector('[data-chat][data-focused="true"]').dataset.chat)`);
  const windowActions = [];
  ipcMain.handle('window-control', (_event, action) => { windowActions.push(action); });
  try {
    await wc.loadURL(origin); win.setSize(1440, 900); win.show(); win.focus();
    await wait(`!!document.querySelector('textarea') && !document.querySelector('[aria-label="Choose model"]').textContent.includes('Loading')`);
    await js(`(()=>{
      const original=window.fetch;window.composerRequests=[];window.composerCancels=0;window.fileChooserClicks=0;
      window.fetch=async(input,options)=>{
        const url=String(input);
        if(url.includes('/api/attach'))return new Promise(resolve=>{window.finishComposerUpload=()=>resolve(new Response(JSON.stringify({path:'/demo/composer-image.png',name:'composer-image.png'}),{headers:{'content-type':'application/json'}}));});
        if(url.includes('/api/acp')&&options?.body){const body=JSON.parse(options.body);if(body.method==='session/prompt')window.composerRequests.push(body);if(body.method==='session/cancel')window.composerCancels++;}
        return original(input,options);
      };
      document.querySelector('input[type="file"]').addEventListener('click',event=>{event.preventDefault();window.fileChooserClicks++;});
    })()`);

    // Real pointer events must reach the portaled menu before it is dismissed.
    await pointer('[aria-label="Add attachments and sources"]');
    await wait(`!!document.querySelector('[data-composer-menu]')`);
    await pointer('[data-composer-menu] [role="option"][title^="Add photos"]');
    assert.equal(await js('window.fileChooserClicks'), 1, 'A portaled attach option must open the file chooser');
    await wait(`!document.querySelector('[data-composer-menu]')`);
    await pointer('[aria-label="Add attachments and sources"]');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="$gui-theme"]')`);
    await pointer('[data-composer-menu] [role="option"][title^="$gui-theme"]');
    assert.equal(await js('document.querySelector("textarea").value'), '$gui-theme ', 'A portaled skill selection must reach the composer');

    // Do not let a stationary pointer hover newly mounted options during IME checks.
    wc.sendInputEvent({ type: 'mouseMove', x: 1, y: 1 });
    await frames();
    await input('/');
    await wait(`document.querySelectorAll('[data-composer-menu] [role="option"]').length>10`);
    const firstOption = await js(`document.querySelector('textarea').getAttribute('aria-activedescendant')`);
    for (const candidate of ['ArrowDown', 'Enter', 'Tab']) await key(candidate, { isComposing: true });
    assert.equal(await js('document.querySelector("textarea").value'), '/', 'IME confirmation must not replace a command token');
    assert.equal(await js(`document.querySelector('textarea').getAttribute('aria-activedescendant')`), firstOption, 'IME navigation must not move completion selection');
    await key('Enter', { keyCode: 229 });
    assert.equal(await js('document.querySelector("textarea").value'), '/', 'Legacy IME key code must not submit or complete');
    await key('Tab', { shiftKey: true });
    assert.equal(await js('document.querySelector("textarea").value'), '/', 'Shift+Tab must not accept a completion');
    await key('Escape');
    await input('A draft before fullscreen');
    await key('Enter', { metaKey: true });
    assert.deepEqual(windowActions, ['fullscreen'], 'Cmd+Enter routes only to the desktop action');
    assert.equal(await js('document.querySelector("textarea").value'), 'A draft before fullscreen');
    assert.equal(await js('window.composerRequests.length'), 0, 'A fullscreen shortcut must not submit a prompt');

    const first = await focused();
    await input('First unsent draft');
    await js(`(()=>{const png=Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgnZYJAAGoAQXEcFHcAAAAAElFTkSuQmCC'),c=>c.charCodeAt(0));const transfer=new DataTransfer();transfer.items.add(new File([png],'composer-image.png',{type:'image/png'}));const e=document.querySelector('input[type="file"]');e.files=transfer.files;e.dispatchEvent(new Event('change',{bubbles:true}));})()`);
    await wait(`typeof window.finishComposerUpload==='function'`);
    await key('n', { metaKey: true });
    const second = await focused();
    await input('Second unsent draft');
    await js('window.finishComposerUpload()');
    await key('1', { metaKey: true });
    assert.equal(await draft(first), 'First unsent draft', 'Switching tabs preserves unsent text');
    await wait(`!!document.querySelector('[aria-label="Remove composer-image.png"]')`);
    await wait(`document.querySelector('[data-promptbar] img')?.naturalWidth===1`);
    assert.equal(await js(`!!document.querySelector('[data-promptbar] [role="status"]')`), false, 'A hidden upload completes in its own chat');
    await key('2', { metaKey: true });
    assert.equal(await draft(second), 'Second unsent draft', 'An older upload must not reset another chat');
    assert.equal(await js(`!!document.querySelector('[aria-label="Remove composer-image.png"]')`), false, 'Attachments never move between chats');
    // Delay the first shortcut's focus frame until a newer navigation has won.
    await js(`(()=>{const raf=window.requestAnimationFrame,frames=[];window.requestAnimationFrame=callback=>{frames.push(callback);return 0;};
      try{document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'1',metaKey:true,bubbles:true,cancelable:true}));}
      finally{window.requestAnimationFrame=raf;}window.flushOldFocus=()=>frames.forEach(callback=>callback(performance.now()));})()`);
    await wait(`document.querySelector('[data-chat][data-focused="true"]')?.dataset.chat==='${first}'`);
    await key('d', { metaKey: true });
    await wait(`document.querySelectorAll('[data-chat]').length===2`);
    const split = await focused();
    assert.notEqual(split, first, 'A new split becomes active');
    await js('window.flushOldFocus()');
    assert.equal(await focused(), split, 'An older shortcut focus frame must not steal the new split');
    await input('Keep this split draft');
    await pointer(`[data-chat="${first}"] textarea`);
    // Use a native key event so an accidental textarea newline is observable.
    wc.sendInputEvent({ type: 'keyDown', keyCode: 'Enter', modifiers: ['meta', 'shift'] });
    wc.sendInputEvent({ type: 'keyUp', keyCode: 'Enter', modifiers: ['meta', 'shift'] });
    await wait(`document.querySelectorAll('[data-chat]').length===1`);
    assert.equal(await draft(first), 'First unsent draft', 'Split zoom must not insert a newline');
    await key('Enter', { metaKey: true, shiftKey: true });
    await wait(`document.querySelectorAll('[data-chat]').length===2`);
    assert.equal(await draft(split), 'Keep this split draft', 'Zooming keeps the hidden split draft');
    assert.ok(await js(`!!document.querySelector('[data-chat="${first}"] [aria-label="Remove composer-image.png"]')`));
    await input('/', `[data-chat="${first}"] textarea`);
    await wait(`!!document.querySelector('[data-composer-menu]')`);
    await pointer(`[data-chat="${split}"] textarea`);
    assert.equal(await js(`!!document.querySelector('[data-composer-menu]')`), false, 'Switching composers closes the old completion portal');

    await js('window.galleryBenchmark=true');
    await input('Start a scripted response');
    await key('Enter');
    await wait(`!!document.querySelector('[data-chat][data-focused="true"] [aria-label="Stop"]')`);
    await input('A follow-up worth keeping');
    assert.equal(await js(`document.querySelector('[data-chat][data-focused="true"] [aria-label="Stop"]').disabled`), false, 'A draft must not remove cancellation');
    assert.equal(await js(`document.querySelector('[data-chat][data-focused="true"] [aria-label="Queue follow-up"]').disabled`), false);
    await pointer('[data-chat][data-focused="true"] [aria-label="Stop"]');
    await wait('window.composerCancels===1');
    assert.equal(await draft(split), 'A follow-up worth keeping', 'Stopping preserves the unsent follow-up');
    await pointer('[data-chat][data-focused="true"] [aria-label="Queue follow-up"]');
    await wait(`Array.from(document.querySelectorAll('[data-chat][data-focused="true"] li')).some(e=>e.textContent.includes('A follow-up worth keeping'))`);
    assert.equal(await draft(split), '', 'Queueing transfers the draft into its queue');
    fs.writeFileSync(path.join(output, 'composer-interactions.png'), (await wc.capturePage()).toPNG());
    console.log('Composer interactions passed: portaled pointer selection, IME, shortcut ownership, per-chat drafts and uploads, split zoom, independent stop and queue.');
  } finally {
    ipcMain.removeHandler('window-control');
    await wc.loadURL(origin);
    await wait(`!!document.querySelector('textarea')`);
  }
}
module.exports = { runComposerInteractions };
