const assert = require('node:assert/strict');

// Exercise the actual GUI wiring for #825 and #839 using saved-file and
// transport fixtures. Never connects to a real REPL or a search engine.
async function runYxlyxRegressions({ win, origin }) {
  const wc = win.webContents, js = async code => {
    try { return await wc.executeJavaScript(code); }
    catch (error) { console.error('Tagged regression expression:', code); throw error; }
  };
  const wait = async code => {
    for (let i = 0; i < 120; i++) { if (await js(code)) return; await new Promise(r => setTimeout(r, 50)); }
    throw Error(`Tagged regression timed out: ${code}`);
  };
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`);
  await js(`(() => {
    const previous = window.fetch;
    const json = body => new Response(JSON.stringify(body), {headers:{'content-type':'application/json'}});
    const row = {name:'active-snapshot',title:'Active snapshot fixture',updatedMs:Date.now(),size:100,local:true};
    window.snapshotPrompts = [];
    window.fetch = async (input, options) => {
      const url = new URL(String(input), location.origin);
      if (url.pathname === '/api/sessions') {
        if (!url.searchParams.has('name')) return json({sessions:[row],total:1,nextCursor:null});
        return json({...row,view:'snapshot',execution:'unknown',messages:[
          {role:'user',content:'Continue the pending check'},
          {role:'assistant',content:'Working.',tool_calls:[
            {id:'todo',function:{name:'todo_write',arguments:JSON.stringify({todos:[{content:'Verify pending work',status:'in_progress'}]})}},
            {id:'pending',function:{name:'bash',arguments:JSON.stringify({command:'pending-check'})}}
          ]}
        ]});
      }
      if (url.pathname === '/api/acp' && options?.body) window.snapshotPrompts.push(JSON.parse(options.body));
      return previous(input, options);
    };
  })()`);
  await js(`document.querySelector('button[aria-label="Conversations"]').click()`);
  await wait(`document.querySelector('[data-conversation-library]')?.textContent.includes('Active snapshot fixture')`);
  await js(`Array.from(document.querySelectorAll('[data-conversation-library] li button')).find(e=>e.textContent.includes('Active snapshot fixture')).click()`);
  await wait(`!!document.querySelector('[data-session-snapshot]')`);
  assert.match(await js(`document.querySelector('[data-session-snapshot]').textContent`), /not attached to a live REPL/);
  await wait(`!!document.querySelector('[data-saved-snapshot]')`);
  assert.equal(await js(`document.querySelector('[data-chat][data-focused="true"] textarea')`), null, 'A saved snapshot cannot accept input before explicit continuation');
  assert.match(await js(`document.querySelector('[data-saved-snapshot]').textContent`), /Live status unknown/);
  assert.equal(await js(`document.querySelector('[data-chat][data-focused="true"]').textContent.includes('Turn finished')`), false);
  assert.equal(await js(`window.snapshotPrompts.some(r=>r.method==='session/prompt')`), false, 'Opening a snapshot never sends a prompt');

  await wait(`!document.querySelector('[aria-label="Show tasks"]').disabled`);
  assert.equal(await js(`!!document.querySelector('[data-tasks-sidebar]')`), false, 'Saved todos never force open Tasks');
  await js(`document.querySelector('[aria-label="Show tasks"]').click()`);
  await wait(`!!document.querySelector('[data-tasks-sidebar]')`);
  assert.equal(await js(`getComputedStyle(document.querySelector('[data-tasks-sidebar]')).display`), 'flex');
  await js(`document.querySelector('[aria-label="Close tasks"]').click()`);
  await wait(`!document.querySelector('[data-tasks-sidebar]')`);
  await js(`document.querySelector('[aria-label="Files"]').click()`);
  await js(`document.querySelector('[aria-label="Files"]').click()`);
  assert.equal(await js(`!!document.querySelector('[data-tasks-sidebar]')`), false, 'Navigation respects closing Tasks');
  for (let count = 2; count <= 4; count++) {
    wc.send('desktop-action', 'split-right');
    await wait(`document.querySelectorAll('[data-chat]').length===${count}`);
  }
  wc.send('desktop-action', 'split-right');
  await wait(`!!document.querySelector('[data-split-limit]')`);
  assert.equal(await js(`document.querySelectorAll('[data-chat]').length`), 4);
  assert.match(await js(`document.querySelector('[data-split-limit]').textContent`), /four|4/i);
  assert.match(await js(`document.querySelector('[data-split-limit]').textContent`), /read/i);
  await wc.loadURL(origin);
  await wait(`!!document.querySelector('[data-workspace-ready="true"] textarea[aria-label="Prompt"]')`);
  console.log('Tagged GUI checks passed: #839 saved snapshot disclosure and no false completion; #825 optional Tasks, close/navigation, four-pane limit explanation.');
}
module.exports = { runYxlyxRegressions };
