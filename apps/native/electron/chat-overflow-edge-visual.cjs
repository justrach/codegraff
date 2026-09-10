const assert = require('node:assert/strict');

async function runOverflowEdges({ win, origin }) {
  const js = code => win.webContents.executeJavaScript(code);
  const settle = () => js(`new Promise(resolve => setTimeout(resolve, 350))`);
  win.setSize(1540, 900);
  await win.loadURL(`${origin}/visual-tests/overflow`);
  for (let i = 0; i < 100; i++) {
    if (await js(`!!document.querySelector('[data-overflow-select="all"]')`)) break;
    await settle();
  }
  await js(`document.fonts.ready`);
  const click = async selector => { await js(`document.querySelector(${JSON.stringify(selector)}).click()`); await settle(); };
  const check = async label => {
    const panes = await js(`Array.from(document.querySelectorAll('[data-chat-transcript]'), e => {
      const box = e.getBoundingClientRect(), failures = [];
      const walker = document.createTreeWalker(e, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        if (!node.textContent.trim() || node.parentElement.closest('pre, table')) continue;
        const range = document.createRange(); range.selectNodeContents(node);
        for (const r of range.getClientRects()) {
          if (r.width && (r.left < box.left - 1 || r.right > box.left + e.clientWidth + 1)) failures.push(node.textContent.slice(0, 40));
          for (let p = node.parentElement; p && p !== e; p = p.parentElement) {
            const s = getComputedStyle(p), b = p.getBoundingClientRect();
            if (r.width && ['hidden', 'clip', 'auto', 'scroll'].includes(s.overflowX) &&
                (r.left < b.left - 1 || r.right > b.right + 1)) failures.push('clipped: ' + node.textContent.slice(0, 40));
          }
        }
      }
      const before = e.scrollTop; e.scrollTop = e.scrollHeight;
      const scrolls = e.scrollHeight <= e.clientHeight || e.scrollTop > 0;
      e.scrollTop = before;
      return { width: e.clientWidth, scrollWidth: e.scrollWidth, left: e.scrollLeft, scrolls, failures: failures.slice(0, 8) };
    })`);
    assert.equal(panes.length, 2, `${label}: two independent panes`);
    for (const pane of panes) {
      assert.ok(pane.scrollWidth <= pane.width, `${label}: viewport overflow ${JSON.stringify(pane)}`);
      assert.equal(pane.left, 0, `${label}: fixed horizontal position`);
      assert.ok(pane.scrolls, `${label}: vertical scrolling works`);
      assert.deepEqual(pane.failures, [], `${label}: all prose glyphs readable`);
    }
  };
  for (const width of [720, 360, 260, 720]) {
    await click(`[data-overflow-width="${width}"]`);
    for (const name of ['url', 'prose', 'inline-path', 'nested', 'table', 'fence', 'error', 'recap', 'reasoning', 'user']) {
      await click(`[data-overflow-select="${name}"]`);
      await check(`${width}px/${name}`);
      if (name === 'inline-path') {
        await js(`document.querySelector('[data-overflow-scroller="left"] code[title]').click()`);
        assert.equal(await js(`document.querySelector('[data-overflow-path-opened="left"]').textContent`), 'Path clicked');
      }
      if (name === 'table' || name === 'fence') {
        const local = await js(`Array.from(document.querySelectorAll('[data-chat-transcript]'), e => {
          let block = e.querySelector(${JSON.stringify(name === 'table' ? 'table' : 'pre')});
          while (block && block !== e && !(block.scrollWidth > block.clientWidth && ['auto', 'scroll'].includes(getComputedStyle(block).overflowX))) block = block.parentElement;
          if (!block || block === e) return false;
          block.scrollLeft = block.scrollWidth;
          return block.scrollLeft > 0 && block.scrollLeft + block.clientWidth >= block.scrollWidth - 1 && e.scrollLeft === 0;
        })`);
        assert.deepEqual(local, [true, true], `${width}px/${name}: rightmost content reachable locally`);
      }
    }
  }
  await click('[data-overflow-width="260"]');
  await click('[data-overflow-select="stream"]');
  for (const step of [1, 2, 3]) {
    await click(`[data-overflow-stream="${step}"]`);
    await check(`stream step ${step}`);
  }
  assert.ok(await js(`document.querySelector('[data-chat-transcript]').textContent.includes('STREAM_FINISHED')`));
  console.log('Overflow edge cases passed: nested Markdown, paths, errors, recaps, reasoning, wide blocks and streaming in two 260/360/720px panes.');
}
module.exports = { runOverflowEdges };
