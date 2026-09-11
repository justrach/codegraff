const testDesktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runChatScroll({ win, origin, output }) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const wait = async code => {
    for (let i = 0; i < 120; i++) {
      if (await js(code)) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw Error(`Chat scroll timed out: ${code}`);
  };
  await wc.loadURL(origin); win.setSize(1100, 760); testDesktop.present(win);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
  await js(`(() => {
    const previous = window.fetch;
    window.fetch = async (input, options) => {
      if (String(input).includes('/api/acp') && options?.body && JSON.parse(options.body).method === 'session/prompt') {
        return new Response(new ReadableStream({ start(controller) {
          window.scrollReply = text => controller.enqueue(new TextEncoder().encode(JSON.stringify({
            jsonrpc:'2.0',method:'session/update',params:{sessionId:'demo',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text}}}
          })+'\\n'));
          window.finishScrollReply = () => {
            controller.enqueue(new TextEncoder().encode(JSON.stringify({jsonrpc:'2.0',id:1,result:{stopReason:'end_turn'}})+'\\n'));
            controller.close();
          };
          window.scrollReply('First reply in a newly opened chat.');
        }}), {headers:{'content-type':'application/x-ndjson'}});
      }
      return previous(input, options);
    };
    const input = document.querySelector('textarea[aria-label="Prompt"]');
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,('Please review this numbered note carefully.\\n').repeat(80));
    input.dispatchEvent(new Event('input',{bubbles:true}));
  })()`);
  await wait(`document.querySelector('textarea').value.length > 1000`);
  await js(`document.querySelector('textarea').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}))`);
  await wait(`!!window.scrollReply && document.querySelector('[data-chat-transcript]')?.scrollHeight > 1200`);
  await js(`new Promise(resolve=>setTimeout(resolve,200))`);
  await js(`(()=>{const e=document.querySelector('[data-chat-transcript]');e.scrollTop=120;e.dispatchEvent(new Event('scroll'));})()`);
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  await js(`window.scrollReply('\\n\\nLATE_REPLY_MARKER\\n\\n'+('More details arrive while you read earlier notes.\\n\\n').repeat(20))`);
  await wait(`document.querySelector('[data-chat-transcript]').textContent.includes('LATE_REPLY_MARKER')`);
  await js(`new Promise(resolve=>setTimeout(resolve,200))`);
  assert.ok(await js(`Math.abs(document.querySelector('[data-chat-transcript]').scrollTop-120)<3`), 'First-turn streaming must preserve a reader who scrolled away from the tail');
  await js(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'n',metaKey:true,bubbles:true,cancelable:true}))`);
  await wait(`!document.querySelector('[data-chat-transcript]')`);
  await js(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',ctrlKey:true,shiftKey:true,bubbles:true,cancelable:true}))`);
  await wait(`!!document.querySelector('[data-chat-transcript]')`);
  assert.ok(await js(`Math.abs(document.querySelector('[data-chat-transcript]').scrollTop-120)<3`), 'Returning to a chat restores its reading position');
  fs.writeFileSync(path.join(output,'chat-reading-position.png'),(await wc.capturePage()).toPNG());
  await js(`(()=>{const e=document.querySelector('[data-chat-transcript]');e.scrollTop=e.scrollHeight;e.dispatchEvent(new Event('scroll'));})()`);
  await js(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`);
  await js(`window.scrollReply('\\n\\nTAIL_REPLY_MARKER\\n\\n'+('Following the latest reply.\\n\\n').repeat(20));window.finishScrollReply()`);
  await wait(`document.querySelector('[data-chat-transcript]').textContent.includes('TAIL_REPLY_MARKER') && !document.querySelector('article[aria-busy="true"]')`);
  await wait(`(()=>{const e=document.querySelector('[data-chat-transcript]');return e.scrollHeight-e.scrollTop-e.clientHeight<50})()`);
  console.log('Chat reading passed: first reply preserves scroll position and resumes following at the tail.');
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
}
module.exports = { runChatScroll };
