const testDesktop = require('./test-desktop.cjs');
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
  const nativeKey = async key => {
    await testDesktop.testInput(wc, { type: 'keyDown', keyCode: key });
    await testDesktop.testInput(wc, { type: 'keyUp', keyCode: key });
    await frames();
  };
  const hover = async selector => {
    await js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'nearest',behavior:'instant'})`);
    await frames();
    const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
    await testDesktop.testInput(wc, { type: 'mouseMove', ...point });
    await frames();
  };
  const pointer = async selector => {
    await js(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:'nearest',behavior:'instant'})`);
    for (let attempt = 0; attempt < 30; attempt++) {
      await frames();
      const point = await js(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:Math.round(r.x+r.width/2),y:Math.round(r.y+r.height/2)}})()`);
      // Hover can scroll the active option or reposition its portal. Settle it
      // before pressing, then verify that the coordinates still hit this row.
      await testDesktop.testInput(wc, { type: 'mouseMove', ...point });
      await frames();
      const ready = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect();return Math.round(r.x+r.width/2)===${point.x}&&Math.round(r.y+r.height/2)===${point.y}&&e.contains(document.elementFromPoint(${point.x},${point.y}));})()`);
      if (!ready) continue;
      await testDesktop.testInput(wc, { type: 'mouseDown', button: 'left', clickCount: 1, ...point });
      await testDesktop.testInput(wc, { type: 'mouseUp', button: 'left', clickCount: 1, ...point });
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
    await js(`localStorage.removeItem('graff.native.open-tabs.v1')`);
    await wc.loadURL(origin); win.setSize(1440, 900); testDesktop.present(win);
    await wait(`!!document.querySelector('textarea') && !document.querySelector('[aria-label="Choose model"]').textContent.includes('Loading')`);

    // A completion row only owns Enter/Tab after its dark hover state makes
    // that selection visible. Before engagement, Enter submits and Tab keeps
    // normal focus traversal instead of silently choosing the attach row.
    await js(`(()=>{
      const original=window.fetch;window.composerKeyboardProbe={fileClicks:0,requests:0};
      window.fetch=async(input,options)=>{
        if(String(input).includes('/api/acp')&&options?.body){
          const body=JSON.parse(options.body);
          if(body.method==='session/prompt'){
            window.composerKeyboardProbe.requests++;
            return new Response(JSON.stringify({jsonrpc:'2.0',id:body.id??1,result:{stopReason:'end_turn'}})+'\\n',{headers:{'content-type':'application/x-ndjson'}});
          }
        }
        return original(input,options);
      };
      document.querySelector('input[type="file"]').addEventListener('click',event=>{event.preventDefault();window.composerKeyboardProbe.fileClicks++;});
    })()`);
    await testDesktop.testInput(wc, { type: 'mouseMove', x: 1, y: 1 });
    await input('@tab-without-selection');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]')`);
    assert.equal(await js(`document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]').classList.contains('bg-hover')`), false, 'An untouched @ menu has no visibly selected row');
    await nativeKey('Tab');
    assert.equal(await js('window.composerKeyboardProbe.fileClicks'), 0, 'Unengaged Tab must not open the file chooser');
    assert.equal(await js('window.composerKeyboardProbe.requests'), 0, 'Unengaged Tab must not submit');
    assert.notEqual(await js('document.activeElement.tagName'), 'TEXTAREA', 'Unengaged Tab keeps normal focus traversal');
    await input('@enter-without-selection');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]')`);
    assert.equal(await js(`document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]').classList.contains('bg-hover')`), false, 'A changed @ query resets visible selection');
    await nativeKey('Enter');
    await wait(`window.composerKeyboardProbe.requests===1`);
    assert.equal(await js('window.composerKeyboardProbe.fileClicks'), 0, 'Unengaged Enter submits instead of opening the file chooser');
    assert.equal(await js('document.querySelector("textarea").value'), '', 'Unengaged Enter clears the submitted draft');

    await wc.loadURL(origin);
    await wait(`!!document.querySelector('textarea') && !document.querySelector('[aria-label="Choose model"]').textContent.includes('Loading')`);
    await js(`(()=>{window.composerKeyboardProbe={fileClicks:0};document.querySelector('input[type="file"]').addEventListener('click',event=>{event.preventDefault();window.composerKeyboardProbe.fileClicks++;});})()`);
    await testDesktop.testInput(wc, { type: 'mouseMove', x: 1, y: 1 });
    await input('@hover-selection');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]')`);
    await hover('[data-composer-menu] [role="option"][title^="Add photos"]');
    await wait(`document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]').classList.contains('bg-hover')`);
    await nativeKey('Enter');
    assert.equal(await js('window.composerKeyboardProbe.fileClicks'), 1, 'Hover-highlighted Enter opens the file chooser');
    await testDesktop.testInput(wc, { type: 'mouseMove', x: 1, y: 1 });
    await frames();
    await input('@arrow-selection');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]')`);
    assert.equal(await js(`document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]').classList.contains('bg-hover')`), false, 'A fresh @ query starts without a visible selection');
    await nativeKey('ArrowDown');
    await wait(`document.querySelector('[data-composer-menu] [role="option"][title^="Add photos"]').classList.contains('bg-hover')`);
    await nativeKey('Tab');
    assert.equal(await js('window.composerKeyboardProbe.fileClicks'), 2, 'Arrow-highlighted Tab opens the file chooser');
    assert.equal(await js('document.activeElement.tagName'), 'TEXTAREA', 'Engaged Tab is consumed and returns focus to the composer');

    const recalled = 'Please inspect the folder mention selection behavior and explain why recalling this submitted message should not rearrange the entire compact composer while I edit it.';
    await js(`localStorage.setItem('graff.native.prompt-history', JSON.stringify([${JSON.stringify(recalled)}]))`);
    await wc.loadURL(origin);
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

    await key('d', { metaKey: true });
    await wait(`document.querySelectorAll('[data-chat]').length===2`);
    const compactLayout = () => js(`(()=>{const input=document.querySelector('[data-chat][data-focused="true"] textarea'),model=input.parentElement.querySelector('[data-model-controls]');const a=input.getBoundingClientRect(),b=model.getBoundingClientRect();return {width:a.width,stacked:b.top>=a.bottom-1}})()`);
    await js(`document.querySelector('[data-chat][data-focused="true"] textarea').focus()`);
    const beforeRecall = await compactLayout();
    await key('ArrowUp');
    const afterRecall = await compactLayout();
    assert.equal(await draft(await focused()), recalled, 'ArrowUp recalls the previous prompt in a split chat');
    assert.equal(beforeRecall.stacked, true, `split composer starts stacked: ${JSON.stringify(beforeRecall)}`);
    assert.equal(afterRecall.stacked, true, `split composer stays stacked after recall: ${JSON.stringify(afterRecall)}`);
    assert.ok(Math.abs(afterRecall.width - beforeRecall.width) < 1, `history recall keeps the textarea width stable: ${JSON.stringify({ beforeRecall, afterRecall })}`);
    await key('ArrowDown');
    await js(`document.querySelector('[data-chat][data-focused="true"] [aria-label="Close this split"]').click()`);
    await wait(`document.querySelectorAll('[data-chat]').length===1`);

    // Real pointer events must reach the portaled menu before it is dismissed.
    await pointer('[aria-label="Add attachments and sources"]');
    await wait(`!!document.querySelector('[data-composer-menu]')`);
    await pointer('[data-composer-menu] [role="option"][title^="Add photos"]');
    assert.equal(await js('window.fileChooserClicks'), 1, 'A portaled attach option must open the file chooser');
    await wait(`!document.querySelector('[data-composer-menu]')`);
    await pointer('[aria-label="Add attachments and sources"]');
    await wait(`!!document.querySelector('[data-composer-menu] [role="option"][title^="$theme"]')`);
    await pointer('[data-composer-menu] [role="option"][title^="$theme"]');
    assert.equal(await js('document.querySelector("textarea").value'), '$theme ', 'A portaled skill selection must reach the composer');

    // Do not let a stationary pointer hover newly mounted options during IME checks.
    await testDesktop.testInput(wc, { type: 'mouseMove', x: 1, y: 1 });
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
    await testDesktop.testInput(wc, { type: 'keyDown', keyCode: 'Enter', modifiers: ['meta', 'shift'] });
    await testDesktop.testInput(wc, { type: 'keyUp', keyCode: 'Enter', modifiers: ['meta', 'shift'] });
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

    // Hold real ACP response streams locally: the gallery adapter acknowledges
    // cancellation without ending its stream, so it cannot exercise queue drain.
    const actionsBeforeSteering = windowActions.length;
    await js(`(()=>{
      const original=window.fetch;
      const state=window.composerSteering={requests:[],cancels:[],live:new Map()};
      state.finish=(chat,stopReason='end_turn')=>{
        const controller=state.live.get(chat);if(!controller)throw Error('No controlled prompt to finish');
        state.live.delete(chat);
        controller.enqueue(new TextEncoder().encode(JSON.stringify({jsonrpc:'2.0',id:1,result:{stopReason}})+'\\n'));
        controller.close();
      };
      state.restore=()=>{window.fetch=original;};
      window.fetch=async(input,options)=>{
        if(String(input).includes('/api/acp')&&options?.body){
          const body=JSON.parse(options.body);
          if(body.method==='session/prompt'){
            state.requests.push(body);
            return new Response(new ReadableStream({start(controller){
              state.live.set(body.chat,controller);
              controller.enqueue(new TextEncoder().encode(JSON.stringify({jsonrpc:'2.0',method:'session/update',params:{update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'Working'}}}})+'\\n'));
            }}),{headers:{'content-type':'application/x-ndjson'}});
          }
          if(body.method==='session/cancel'){
            state.cancels.push(body);state.finish(body.chat,'cancelled');
            return new Response(JSON.stringify({result:{}}),{headers:{'content-type':'application/json'}});
          }
        }
        return original(input,options);
      };
    })()`);
    try {
      const nativeEnter = async modifiers => {
        await testDesktop.testInput(wc, { type: 'keyDown', keyCode: 'Enter', modifiers });
        await testDesktop.testInput(wc, { type: 'keyUp', keyCode: 'Enter', modifiers });
        await frames();
      };
      const queued = `[data-chat="${split}"] [data-queued-prompt]`;
      // Exercise both platform modifiers, including an empty composer and a
      // separate unsent draft. Each turn stays busy until explicitly finished.
      for (const [index, modifier] of ['meta', 'control'].entries()) {
        const payload = `Steered queued payload ${index}`;
        const keptDraft = index ? 'Do not submit this unsent draft' : '';
        const base = await js('window.composerSteering.requests.length');
        await input(`Controlled active turn ${index}`);
        await nativeEnter([]);
        await wait(`window.composerSteering.requests.length===${base + 1} && !!document.querySelector('[data-chat="${split}"] [aria-label="Stop"]')`);
        await input(payload);
        await nativeEnter([]);
        await wait(`document.querySelector(${JSON.stringify(queued)})?.textContent.includes(${JSON.stringify(payload)})`);
        assert.equal(await draft(split), '', 'Plain Enter transfers the draft into the queue');
        assert.equal(await js('window.composerSteering.cancels.length'), index, 'Plain Enter while busy must not cancel');
        assert.equal(await js('window.composerSteering.requests.length'), base + 1, 'Queued text must not dispatch before steering');
        await input(keptDraft);
        for (const guard of [{ repeat: true }, { isComposing: true }, { keyCode: 229 }]) {
          await key('Enter', { [modifier === 'meta' ? 'metaKey' : 'ctrlKey']: true, ...guard });
        }
        assert.equal(await js('window.composerSteering.cancels.length'), index, 'Repeat and IME shortcuts must not steer');
        await nativeEnter([modifier]);
        await wait(`window.composerSteering.requests.length===${base + 2}`);
        assert.equal(await js('window.composerSteering.cancels.length'), index + 1, 'Steering cancels exactly once');
        assert.equal(windowActions.length, actionsBeforeSteering, 'Busy queue shortcuts must not toggle fullscreen');
        assert.equal(await draft(split), keptDraft, 'Steering preserves the current unsent draft');
        assert.deepEqual(await js(`window.composerSteering.requests[${base + 1}].params.prompt`), [{ type: 'text', text: payload }], 'Queue drain dispatches the queued payload, not the draft');
        assert.equal(await js(`window.composerSteering.cancels[${index}].chat===window.composerSteering.requests[${base + 1}].chat`), true, 'Cancellation and queue dispatch belong to the same chat');
        assert.equal(await draft(first), '/', 'Steering must not alter another visible composer');
        assert.equal(await js(`!!document.querySelector('[data-chat="${first}"] [data-queued-prompt]')`), false, 'Queue state must not leak into another chat');
        await js(`window.composerSteering.finish(window.composerSteering.requests[${base + 1}].chat)`);
        await wait(`!document.querySelector('[data-chat="${split}"] [aria-label="Stop"]') && !document.querySelector(${JSON.stringify(queued)})`);
        await frames();
        assert.equal(await js('window.composerSteering.requests.length'), base + 2, 'The queued payload is dispatched exactly once after completion');
        assert.equal(await draft(split), keptDraft, 'Completing the steered turn preserves the draft');
      }
    } finally {
      await js('window.composerSteering.restore()');
    }

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
    await js('window.galleryBenchmark=false');
    await wait(`!document.querySelector('[data-chat][data-focused="true"] [aria-label="Stop"]') && !document.querySelector('[data-chat][data-focused="true"] [data-queued-prompt]')`);
    console.log('Composer interactions passed: portaled pointer selection, IME, shortcut ownership, per-chat drafts and uploads, split zoom, independent stop and queue.');
  } finally {
    ipcMain.removeHandler('window-control');
  }
}
module.exports = { runComposerInteractions };
