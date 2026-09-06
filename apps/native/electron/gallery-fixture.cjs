// Synthetic content for reproducible screenshots; never reads the user's workspace.
function installGalleryFixture() {
  const original = window.fetch;
  // Page unload must use the mocked fetch path too, never a real ACP beacon.
  navigator.sendBeacon = () => false;
  localStorage.setItem('graff.native.browser.open', '0');
  const root = '/demo/field-notes';
  const catalog = { result: { current: { model: 'Graff', provider: '', effort: 'medium', fast: false, effortLevels: ['low', 'medium', 'high'] }, models: [{ name: 'Graff', provider: '', context: 128000, authenticated: true, cost: 'local', current: true }] } };
  const json = body => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
  const delta = text => ({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'demo', update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } } } });
  window.fetch = async (input, options) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.origin);
    if (!url.pathname.startsWith('/api/')) return original(input, options);
    if (url.pathname === '/api/agents') return json({ agents: [
      { session: 'navigation', startId: '1', pid: 1, title: 'Refine navigation', task: 'Improve focus order and keyboard shortcuts', workspace: root, status: 'working', resources: null },
      { session: 'review', startId: '2', pid: 2, title: 'Review accessibility', task: 'Check the updated sidebar', workspace: root, status: 'waiting', resources: null }
    ], messages: [{ from_session: 'navigation', to: 'review', text: 'The sidebar update is ready. Please check keyboard navigation.', kind: 'handoff', ts_ms: 1788652800000 }], delivery: 'Queued' });
    if (url.pathname === '/api/models') return json(catalog);
    if (url.pathname === '/api/sessions') return json({ cwd: root, sessions: [], total: 0, nextCursor: null });
    if (url.pathname === '/api/themes') return json({ themes: [], issues: [] });
    if (url.pathname === '/api/title') return json({ title: 'A calmer workspace' });
    if (url.pathname === '/api/git') {
      if (options?.method === 'POST') return json({ diff: 'diff --git a/palette.css b/palette.css\n--- a/palette.css\n+++ b/palette.css\n@@ -1,5 +1,6 @@\n :root {\n-  --paper: #ffffff;\n-  --ink: #000000;\n+  --paper: #f6eedf;\n+  --ink: #211e19;\n+  --accent: #567568;\n   --radius: 12px;\n }\n' });
      return json({ root, branch: 'main', files: [{ path: 'palette.css', add: 3, del: 2, untracked: false, status: ' M', binary: false }], totalAdd: 3, totalDel: 2, commits: [], worktrees: [{ path: root, branch: 'main' }] });
    }
    if (url.pathname === '/api/acp') {
      if (!options?.body) return json({ ok: true, cwd: root, home: '/demo' });
      const body = JSON.parse(options.body);
      if (body.method === 'bootstrap') return json({ sessionId: 'demo', commands: [] });
      if (body.method === 'graff/models') return json(catalog);
      if (body.method === 'session/prompt') {
        const text = window.galleryBenchmark ? ('A responsive workspace keeps the conversation readable as updates arrive.\n\n').repeat(80) : 'The workspace now has a softer palette and a clearer review flow.\n\n### Ready to explore\n\n- **Appearance:** switch between White, Black, Website and CodeGraff, or add your own theme.\n- **Changes:** review edits beside the conversation and drag the divider to make room.\n- **Browser:** open a page, pin an element and ask Graff to work with it.\n\nEverything is ready for your review.';
        return new Response(new ReadableStream({ start(controller) {
          let index = 0;
          const send = value => controller.enqueue(new TextEncoder().encode(JSON.stringify(value) + '\n'));
          const timer = setInterval(() => {
            send(delta(text.slice(index, index + 24))); index += 24;
            if (index >= text.length) { clearInterval(timer); send({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } }); controller.close(); }
          }, window.galleryBenchmark ? 25 : 5);
        }}), { headers: { 'content-type': 'application/x-ndjson' } });
      }
      return json({ result: {} });
    }
    return new Response('{}', { status: 404 });
  };
}
module.exports = { installGalleryFixture };
