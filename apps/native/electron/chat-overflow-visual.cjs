const testDesktop = require('./test-desktop.cjs');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function runChatOverflow({ win, origin, output }) {
  const wc = win.webContents, js = code => wc.executeJavaScript(code);
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const wait = async code => {
    for (let i = 0; i < 120; i++) {
      if (await js(code)) return;
      await sleep(50);
    }
    throw Error(`Chat overflow timed out: ${code}`);
  };
  const settle = async () => {
    await js(`document.fonts.ready.then(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true)))))`);
    await sleep(150);
  };
  const transcript = `document.querySelector('[data-chat-transcript]')`;
  const userWord = 'FictionalUserRibbon'.repeat(32);
  const assistantWord = 'FictionalAssistantRibbon'.repeat(32);
  const url = 'https://example.invalid/' + 'fictional-link-segment'.repeat(32);
  const www = 'www.example.invalid/' + 'fictional-public-note'.repeat(32);
  const inline = 'fictional_inline_value_'.repeat(32);
  const user = `Please inspect these fictional overflow samples.\n\n${userWord}\n\n${url}\n\n${www}\n\n\`${inline}\`\n\n` +
    'A readable user note stays inside the conversation pane.\n'.repeat(12);
  const prose = `${assistantWord}\n\n${url}\n\n[${www}](https://${www})\n\n\`${inline}\`\n\n` +
    'A readable assistant paragraph stays inside the conversation pane.\n\n'.repeat(12);
  const fence = '```text\n' + 'fictional_code_column_'.repeat(100);
  const headers = Array.from({ length: 12 }, (_, i) => `Fictional column ${i + 1}`);
  const table = '\n\n| ' + headers.join(' | ') + ' |\n| ' + headers.map(() => '---').join(' | ') +
    ' |\n| ' + headers.map((_, i) => `Sample value ${i + 1}`).join(' | ') + ' |\n\nOVERFLOW_REPLY_DONE';
  const originalSize = win.getSize();

  // Text ranges catch clipped glyphs as well as expanded boxes: overflow:hidden alone is not a fix.
  const bounds = async label => {
    const result = await js(`(() => {
      const e = ${transcript}, box = e.getBoundingClientRect();
      const failures = [], wrapped = {};
      const tokens = ${JSON.stringify([userWord, assistantWord, url, www, inline])};
      const walker = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        const parent = node.parentElement;
        if (!node.textContent.trim() || parent.closest('pre, table, [data-streamdown="code-block"]')) continue;
        const range = document.createRange(); range.selectNodeContents(node);
        const rects = Array.from(range.getClientRects()).filter(r => r.width && r.height);
        for (const r of rects) {
          if (r.left < box.left - 1 || r.right > box.left + e.clientWidth + 1) {
            failures.push({ text: node.textContent.slice(0, 32), left: r.left - box.left, right: r.right - box.left });
          }
          // Check every ancestor too, so clipping inside a bubble cannot masquerade as readable wrapping.
          for (let p = parent; p && p !== e; p = p.parentElement) {
            const style = getComputedStyle(p), b = p.getBoundingClientRect();
            if (['hidden', 'clip', 'auto', 'scroll'].includes(style.overflowX) &&
                (r.left < b.left - 1 || r.right > b.right + 1)) failures.push({ clipped: p.tagName });
          }
        }
        for (const token of tokens) if (node.textContent.includes(token)) {
          const start = node.textContent.indexOf(token);
          range.setStart(node, start); range.setEnd(node, start + token.length);
          const lines = new Set(Array.from(range.getClientRects()).map(r => Math.round(r.top))).size;
          const role = parent.closest('article') ? 'assistant' : 'user';
          wrapped[role + ':' + tokens.indexOf(token)] = lines;
        }
      }
      return { width: e.clientWidth, scrollWidth: e.scrollWidth, left: e.scrollLeft,
        documentWidth: document.documentElement.clientWidth, documentScrollWidth: document.documentElement.scrollWidth,
        failures: failures.slice(0, 8), wrapped };
    })()`);
    assert.ok(result.width > 100, `${label}: usable transcript width`);
    assert.ok(result.scrollWidth <= result.width, `${label}: transcript overflow ${JSON.stringify(result)}`);
    assert.equal(result.left, 0, `${label}: transcript scrollLeft`);
    assert.ok(result.documentScrollWidth <= result.documentWidth, `${label}: page overflow`);
    assert.deepEqual(result.failures, [], `${label}: prose must remain readable`);
    for (const key of ['user:0', 'user:2', 'user:3', 'user:4', 'assistant:1', 'assistant:2', 'assistant:3', 'assistant:4']) {
      assert.ok(result.wrapped[key] > 1, `${label}: ${key} must exist and wrap onto multiple lines`);
    }
    return result.width;
  };
  const wheel = async (point, deltaX, deltaY) => {
    await testDesktop.testInput(wc, { type: 'mouseMove', ...point });
    await testDesktop.testInput(wc, { type: 'mouseWheel', ...point, deltaX, deltaY, canScroll: true });
    await sleep(200);
  };
  const viewportWheels = async label => {
    // The blank left gutter targets the transcript, not an intentionally scrollable code block.
    const point = await js(`(() => {
      const e = ${transcript}; e.scrollTop = 0; e.dispatchEvent(new Event('scroll'));
      const r = e.getBoundingClientRect(); return { x: Math.round(r.left + 3), y: Math.round(r.top + r.height / 2) };
    })()`);
    await settle();
    const top = () => js(`${transcript}.scrollTop`);
    const before = await top();
    for (const delta of [-240, 240]) {
      await wheel(point, delta, 0);
      assert.equal(await js(`${transcript}.scrollLeft`), 0, `${label}: horizontal wheel cannot pan transcript`);
      assert.ok(Math.abs(await top() - before) < 2, `${label}: horizontal wheel cannot move vertically`);
    }
    await wheel(point, 0, -180);
    assert.ok(await top() > before + 10, `${label}: vertical wheel scrolls down`);
    const down = await top();
    await wheel(point, -180, -180);
    assert.ok(await top() > down + 10, `${label}: diagonal wheel retains vertical movement`);
    assert.equal(await js(`${transcript}.scrollLeft`), 0, `${label}: diagonal wheel cannot pan transcript`);
    const diagonal = await top();
    await wheel(point, 180, 120);
    assert.ok(await top() < diagonal - 10, `${label}: reverse diagonal wheel scrolls up`);
    await bounds(label);
  };
  const localScroll = async (selector, label) => {
    const point = await js(`(() => {
      const e = ${transcript}, target = e.querySelector(${JSON.stringify(selector)});
      if (!target) return null;
      let local = target;
      while (local && local !== e) {
        if (local.scrollWidth > local.clientWidth && ['auto', 'scroll'].includes(getComputedStyle(local).overflowX)) break;
        local = local.parentElement;
      }
      if (!local || local === e) return null;
      window.overflowLocal = local;
      local.scrollLeft = 0;
      e.scrollTop += local.getBoundingClientRect().top - e.getBoundingClientRect().top - 60;
      e.dispatchEvent(new Event('scroll'));
      return true;
    })()`);
    assert.ok(point, `${label}: wide content needs its own horizontal scroller`);
    await settle();
    const geometry = await js(`(() => {
      const e = ${transcript}, local = window.overflowLocal, r = local.getBoundingClientRect(), b = e.getBoundingClientRect();
      return { x: Math.round(r.left + Math.min(r.width / 2, 100)), y: Math.round(Math.max(r.top, b.top) + Math.min(r.height / 2, 45)),
        contained: r.left >= b.left - 1 && r.right <= b.left + e.clientWidth + 1, top: e.scrollTop };
    })()`);
    assert.ok(geometry.contained, `${label}: local scroller fits transcript`);
    await wheel({ x: geometry.x, y: geometry.y }, -240, 0);
    assert.ok(await js(`window.overflowLocal.scrollLeft > 10`), `${label}: horizontal wheel reveals wide content`);
    assert.equal(await js(`${transcript}.scrollLeft`), 0, `${label}: local scrolling never pans transcript`);
    assert.ok(Math.abs(await js(`${transcript}.scrollTop`) - geometry.top) < 2, `${label}: local horizontal wheel preserves vertical position`);
    await js(`window.overflowLocal.scrollLeft = window.overflowLocal.scrollWidth`);
    assert.ok(await js(`window.overflowLocal.scrollLeft + window.overflowLocal.clientWidth >= window.overflowLocal.scrollWidth - 1`), `${label}: far edge is reachable`);
    await js(`window.overflowLocal.scrollLeft = 0`);
  };
  const screenshot = async name => fs.writeFileSync(path.join(output, `chat-overflow-${name}.png`), (await wc.capturePage()).toPNG());

  try {
    await wc.loadURL('about:blank');
    wc.debugger.attach('1.3');
    await wc.debugger.sendCommand('Page.enable');
    await wc.debugger.sendCommand('Page.addScriptToEvaluateOnNewDocument', {
      source: `(${require('./gallery-fixture.cjs').installGalleryFixture.toString()})()`,
    });
    await wc.loadURL(origin); win.setSize(1100, 760);
    await wait(`!!document.querySelector('textarea[aria-label="Prompt"]')`);
    await js(`(() => {
      const previous = window.fetch;
      window.fetch = async (input, options) => {
        const url = new URL(typeof input === 'string' ? input : input.url, location.href);
        if (url.pathname.startsWith('/api/')) {
          const request = options?.body ? JSON.parse(options.body) : {};
          if (url.pathname === '/api/acp' && request.method === 'session/prompt') {
            return new Response(new ReadableStream({ start(controller) {
              const send = value => controller.enqueue(new TextEncoder().encode(JSON.stringify(value) + '\\n'));
              window.overflowReply = text => send({ jsonrpc: '2.0', method: 'session/update', params: {
                sessionId: 'demo', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } }
              } });
              window.finishOverflowReply = () => {
                send({ jsonrpc: '2.0', id: request.id ?? 1, result: { stopReason: 'end_turn' } }); controller.close();
              };
            } }), { headers: { 'content-type': 'application/x-ndjson' } });
          }
          // Bootstrap, title and split-pane requests still use the installed gallery mock.
          return previous(input, options);
        }
        return previous(input, options);
      };
      const input = document.querySelector('textarea[aria-label="Prompt"]');
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(input, ${JSON.stringify(user)});
      input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`);
    await wait(`document.querySelector('textarea[aria-label="Prompt"]').value.length > 1000`);
    await js(`document.querySelector('textarea[aria-label="Prompt"]').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))`);
    await wait(`!!window.overflowReply`);
    await js(`window.overflowReply(${JSON.stringify(prose)})`);
    await wait(`${transcript}?.textContent.includes(${JSON.stringify(inline)}) && !!document.querySelector('article code')`);
    await wait(`document.querySelector('article')?.textContent.includes(${JSON.stringify(inline)})`);
    await settle();
    await bounds('streaming prose');
    await js(`window.overflowReply(${JSON.stringify(fence)})`);
    await wait(`document.querySelector('[data-code-streaming]')?.textContent.includes(${JSON.stringify('fictional_code_column_'.repeat(100))})`);
    await localScroll('[data-code-streaming] pre', 'open fence');
    await screenshot('streaming');
    await js(`window.overflowReply(${JSON.stringify('\n```' + table)}); window.finishOverflowReply()`);
    await wait(`${transcript}?.textContent.includes('OVERFLOW_REPLY_DONE') && !document.querySelector('article[aria-busy="true"]') && !!document.querySelector('article table')`);
    await settle();

    const check = async label => {
      await bounds(label);
      await viewportWheels(label);
      await screenshot(`${label}-prose`);
      await localScroll('article pre', `${label} code`);
      await screenshot(`${label}-code`);
      await localScroll('article table', `${label} table`);
      await screenshot(`${label}-table`);
    };
    await check('wide');
    win.setSize(640, 760); await settle();
    const narrowWidth = await bounds('narrow');
    await check('narrow');
    win.setSize(1100, 760); await settle();
    assert.ok(await bounds('expanded') > narrowWidth + 100, 'Resizing expands the actual chat viewport');
    await check('expanded');
    await js(`document.querySelector('textarea[aria-label="Prompt"]').focus(); document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', metaKey: true, bubbles: true, cancelable: true }))`);
    await wait(`document.querySelectorAll('[data-chat]').length === 2`);
    await settle();
    assert.ok(await bounds('split') < narrowWidth, 'Split shortcut creates a narrower real chat pane');
    await check('split');
    win.setSize(900, 760); await settle();
    await check('split-narrow');
    console.log('Chat overflow passed: streamed/final text wraps, transcript wheels stay vertical, wide code/tables scroll locally, window and split resizing remain readable.');
  } finally {
    win.setSize(...originalSize);
    // Navigation discards the fetch mock and unfinished streams, including on assertion failure.
    await wc.loadURL('about:blank');
    if (wc.debugger.isAttached()) wc.debugger.detach();
  }
}
module.exports = { runChatOverflow };
