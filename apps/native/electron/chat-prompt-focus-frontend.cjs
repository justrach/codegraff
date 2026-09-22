const assert = require('node:assert/strict');
const desktop = require('./test-desktop.cjs');

async function runChatPromptFocus({ win, click, until, report }) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const pointerClick = async selector => {
    await until(() => js(`!!document.querySelector(${JSON.stringify(selector)})`), 'pointer target mounts');
    const point = await js(`(()=>{const e=document.querySelector(${JSON.stringify(selector)}),r=e.getBoundingClientRect();return{x:r.x+r.width/2,y:r.y+r.height/2};})()`);
    for (const type of ['mouseDown', 'mouseUp']) await desktop.testInput(wc, { type, ...point, button: 'left', clickCount: 1 });
  };
  assert.equal(await js(`innerWidth < 1024`), true, 'Exercise narrow responsive navigation');
  const first = await js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`);
  const firstDraft = await js(`document.querySelector('[data-chat][data-focused="true"] textarea[aria-label="Prompt"]').value`);
  await click('[title="New chat (⌘T)"]');
  const second = await js(`document.querySelector('[data-chat][data-focused="true"]').dataset.chat`);
  assert.notEqual(second, first);
  await click('[aria-label="Open navigation"]');
  await until(() => js(`!!document.querySelector('[data-navigation-panel]:popover-open')`), 'navigation opens');
  await js(`window.__promptTypingTarget=null;document.addEventListener('beforeinput',event=>window.__promptTypingTarget=event.target.closest?.('[data-chat]')?.dataset.chat,{capture:true,once:true})`);
  await pointerClick(`[data-session-navigation="sidebar"] [data-tab-members="${first}"] button[aria-pressed]`);
  await until(() => js(`document.querySelector('[data-chat][data-focused="true"]')?.dataset.chat==="${first}"`), 'chat selection handled');
  await desktop.testInput(wc, { type: 'char', keyCode: 'x' });
  await until(() => js(`!document.querySelector('[data-navigation-panel]:popover-open') && document.activeElement===document.querySelector('[data-chat="${first}"] textarea[aria-label="Prompt"]')`), 'chat selection dismisses navigation and focuses its prompt');
  assert.equal(await js(`window.__promptTypingTarget`), first, 'the first typed character targets the selected prompt');
  assert.equal(await js(`document.querySelector('[data-chat="${first}"] textarea[aria-label="Prompt"]').value`), `${firstDraft}x`, 'the first character typed after chat selection appends to its prompt');
  report.passed.push('selecting a chat from narrow navigation closes the popover, focuses its prompt and sends typing there');
}

module.exports = { runChatPromptFocus };
