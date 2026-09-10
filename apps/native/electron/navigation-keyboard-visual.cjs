const assert = require('node:assert/strict');

async function runNavigationKeyboard({win, origin}) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const pause = () => new Promise(resolve => setTimeout(resolve, 60));
  const wait = async code => {
    for (let attempt = 0; attempt < 120; attempt++) { if (await js(code)) return; await pause(); }
    throw Error(`Keyboard navigation check timed out: ${code}`);
  };
  // Real input is essential: synthetic KeyboardEvents do not move Tab focus.
  const key = async (keyCode, modifiers = []) => {
    wc.sendInputEvent({type: 'keyDown', keyCode, modifiers});
    wc.sendInputEvent({type: 'keyUp', keyCode, modifiers});
    await pause();
  };
  const click = selector => js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)});e.focus();e.click();})()`);
  const tabs = () => js(`Array.from(document.querySelectorAll('[aria-label="Close tab"]')).map(e=>e.parentElement.textContent)`);
  const modalContainsFocus = () => js(`document.querySelector('[aria-modal="true"]')?.contains(document.activeElement)`);
  const focusDiagnostic = () => js(`JSON.stringify({hasFocus:document.hasFocus(),active:document.activeElement?.outerHTML.slice(0,2500),modal:document.querySelector('[aria-modal="true"]')?.getAttribute('aria-label')})`);

  await wc.loadURL(origin); require('./test-window.cjs').presentWindow(win);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  wc.send('desktop-action', 'new');
  await wait(`document.querySelectorAll('[aria-label="Close tab"]').length===2`);
  const originalTabs = await tabs();
  const opener = 'button[aria-label="Open folder…"]';
  await click(opener);
  await wait(`!!document.querySelector('[aria-label="Folder path"]')`);
  await wait(`Array.from(document.querySelectorAll('[aria-modal="true"] button')).some(e=>e.textContent==='Open folder'&&!e.disabled)`);
  assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Folder path', 'The folder picker starts in its path field');
  await click('[aria-modal="true"] [aria-label="Close"]');
  await wait(`!document.querySelector('[aria-modal="true"]')`);
  assert.equal(await js(`document.activeElement.matches(${JSON.stringify(opener)})`), true, 'Close restores the folder picker trigger');

  await click(opener);
  await wait(`!!document.querySelector('[aria-label="Folder path"]')`);
  await wait(`Array.from(document.querySelectorAll('[aria-modal="true"] button')).some(e=>e.textContent==='Open folder'&&!e.disabled)`);
  await js(`document.querySelector('[aria-modal="true"] [aria-label="Close"]').focus()`);
  await key('Tab', ['shift']);
  assert.equal(await js(`document.activeElement.textContent`), 'Open folder', 'Shift+Tab wraps from the first to last dialog control');
  await key('Tab');
  assert.equal(await js(`document.activeElement.getAttribute('aria-label')`), 'Close', 'Tab wraps from the last to first dialog control');
  for (let index = 0; index < 18; index++) {
    await key('Tab');
    assert.equal(await modalContainsFocus(), true, 'Tab never reaches the chat behind the folder picker: ' + await focusDiagnostic());
  }
  await js(`document.querySelector('textarea[aria-label="Prompt"]').focus()`);
  assert.equal(await modalContainsFocus(), true, 'Programmatic focus cannot escape the active modal: ' + await focusDiagnostic());
  await js(`(()=>{const current=document.activeElement;window.keyboardDisabledControl=current instanceof HTMLButtonElement?current:null;if(window.keyboardDisabledControl)window.keyboardDisabledControl.disabled=true;document.querySelector('[aria-modal="true"]').focus();})()`);
  await key('Tab');
  assert.equal(await modalContainsFocus(), true, 'Tab recovers when the focused control becomes unavailable: ' + await focusDiagnostic());
  await js(`if(window.keyboardDisabledControl)window.keyboardDisabledControl.disabled=false;delete window.keyboardDisabledControl;`);
  for (const action of ['close', 'new', 'split-right', 'workspace']) wc.send('desktop-action', action);
  await pause();
  assert.deepEqual(await tabs(), originalTabs, 'Native menu actions cannot change background chats while a dialog is open');
  assert.equal(await js(`document.querySelector('[aria-modal="true"]')?.getAttribute('aria-label')`), 'Open a folder');
  await key('Escape');
  await wait(`!document.querySelector('[aria-modal="true"]')`);
  assert.equal(await js(`document.activeElement.matches(${JSON.stringify(opener)})`), true, 'Escape restores the folder picker trigger');

  await click('[data-workspace-trigger]');
  await wait(`!!document.querySelector('[data-workspace-menu]')`);
  await js(`Array.from(document.querySelectorAll('[data-workspace-menu] button')).find(e=>e.textContent==='Project settings…').click()`);
  await wait(`!!document.querySelector('[aria-modal="true"] [role="switch"]')`);
  assert.equal(await modalContainsFocus(), true, 'Replacing the workspace menu keeps focus in settings');
  await js(`(()=>{const original=window.fetch;window.fetch=(input,options)=>String(input)==='/api/fs'&&options?.method==='POST'?Promise.resolve(new Response(JSON.stringify({error:'Cannot reveal this folder'}),{status:500,headers:{'content-type':'application/json'}})):original(input,options);})()`);
  await js(`Array.from(document.querySelectorAll('[aria-modal="true"] button')).find(e=>e.textContent==='Reveal').click()`);
  await wait(`document.querySelector('[aria-modal="true"] [role="alert"]')?.textContent==='Cannot reveal this folder'`);
  await key('Escape');
  await wait(`!document.querySelector('[aria-modal="true"]')`);
  assert.equal(await js(`document.activeElement.matches('[data-workspace-trigger]')`), true, 'Settings returns focus to the workspace trigger after its menu unmounts');

  await js(`document.querySelector('button[aria-label="Search chats"]').focus()`);
  await key('Tab');
  assert.equal(await js(`document.activeElement.matches('[aria-label="Search chat history"], [aria-label="Close chat search"]')`), false, 'Closed search controls do not intercept Tab');
  await click('button[aria-label="Search chats"]');
  await wait(`document.activeElement.matches('[aria-label="Search chat history"]')`);
  await key('Escape');
  assert.equal(await js(`document.activeElement.matches('[aria-label="Search chats"]')`), true, 'Closing chat search restores its trigger');
  await click('button[aria-label="Collapse sidebar"]');
  await wait(`document.activeElement.matches('[aria-label="Expand sidebar"]')`);
  await js(`document.querySelector('button[aria-label="Browser"]').focus()`);
  await key('Tab');
  assert.equal(await js(`!!document.activeElement.closest('[aria-label="Workspace navigation"]')`), false, 'Collapsed chat rows and footer are skipped after the visible navigation icons');
  await click('button[aria-label="Expand sidebar"]');
  await wait(`document.activeElement.matches('[aria-label="Collapse sidebar"]')`);
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  console.log('Keyboard navigation passed: modal Tab boundaries, focus restoration, native menu guards, reveal errors, and hidden sidebar controls.');
}

module.exports = {runNavigationKeyboard};
