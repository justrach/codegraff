const assert = require('node:assert/strict');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function smokeToolDisclosure({ win, backend }) {
  const js = async source => { try { return await win.webContents.executeJavaScript(source); } catch (error) { throw Error(`UI fixture failed (${source.slice(0, 160)}): ${error.message}`); } };
  const wait = async source => { for (let i = 0; i < 100; i++) { if (await js(source)) return; await sleep(100); } throw Error(`Tool disclosure check timed out: ${source}; state=${await js("JSON.stringify({visibility:document.visibilityState,headers:[...document.querySelectorAll('[data-tool-summary]')].map(e=>e.textContent)})")}`); };
  // Script the transport inside this isolated smoke profile. No model turn or file write.
  const setup = await js(`(async()=>{try {
    const catalog=await fetch('/api/models').then(r=>r.json()); const original=window.fetch;
    const json=body=>new Response(JSON.stringify(body),{headers:{'content-type':'application/json'}});
    window.fetch=(url,options)=>{
      if(url==='/api/title')return Promise.resolve(json({title:'Disclosure fixture'}));
      if(url==='/api/acp' && options?.body){const body=JSON.parse(options.body);
        if(body.method==='bootstrap')return Promise.resolve(json({sessionId:'disclosure-fixture',commands:[]}));
        if(body.method==='graff/models')return Promise.resolve(json(catalog));
        if(body.method==='session/prompt')return Promise.resolve(new Response(new ReadableStream({start(controller){window.disclosureEmit=update=>controller.enqueue(new TextEncoder().encode(JSON.stringify({jsonrpc:'2.0',method:'session/update',params:{sessionId:'disclosure-fixture',update}})+'\\n'));window.disclosureDone=()=>{controller.enqueue(new TextEncoder().encode(JSON.stringify({jsonrpc:'2.0',id:1,result:{stopReason:'end_turn'}})+'\\n'));controller.close()}}}),{headers:{'content-type':'application/x-ndjson'}}));
      }
      return original(url,options);
    };
    const input=document.querySelector('textarea[aria-label="Prompt"]');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(input,'Check the disclosure fixture');input.dispatchEvent(new Event('input',{bubbles:true}));
  } catch (error) { return error.stack; } })()`);
  assert.equal(setup, undefined);
  await wait(`!document.querySelector('[aria-label="Send"]').disabled`);
  await js(`document.querySelector('[aria-label="Send"]').click()`);
  await wait(`!!window.disclosureEmit`);
  const tool = index => js(`window.disclosureEmit({sessionUpdate:'tool_call',toolCallId:'fixture-${index}',title:'fixture-${index}.txt',kind:'read',status:'pending',rawInput:{path:'fixture-${index}.txt'}})`);
  await tool(1);
  await wait(`!!document.querySelector('[data-tool-summary]')`);
  assert.equal(await js(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')`), 'false');
  for (let i = 2; i <= 7; i++) await tool(i);
  await wait(`document.querySelector('[data-tool-summary]').textContent.includes('7')`);
  assert.equal(await js(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')`), 'false');
  await js(`document.querySelector('[data-tool-summary]').click()`);
  await wait(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')==='true'`);
  await tool(8); await sleep(100);
  assert.equal(await js(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')`), 'true');
  await js(`document.querySelector('[data-tool-summary]').click()`);
  await tool(9); await sleep(100);
  assert.equal(await js(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')`), 'false');
  await js(`window.disclosureDone()`);
  await sleep(200);
  assert.equal(await js(`document.querySelector('[data-tool-summary]').getAttribute('aria-expanded')`), 'false');
  await win.loadURL(backend.origin);
  await wait(`!!document.querySelector('[aria-label="Appearance"]')`);
  return 'single and batched tools start collapsed; new updates and completion preserve the reader selection';
}
module.exports = { smokeToolDisclosure };
