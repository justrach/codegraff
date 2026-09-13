// Synthetic data for headless motion checks.
function installMotionFixture() {
  const fallback = window.fetch;
  const models = ['Graff', 'Studio', 'sprinkles-5'];
  const catalog = { result: {
    current: { model: 'Graff', provider: '', effort: 'medium', fast: false, effortLevels: ['low', 'medium', 'high'] },
    models: models.map(name => ({ name, provider: '', context: 128000, authenticated: true, cost: 'local', current: name === 'Graff' })),
    commands: [{ name: 'help', description: 'Explore available commands' }, { name: 'compact', description: 'Summarize the conversation' }, { name: 'review', description: 'Review workspace changes' }],
  } };
  window.fetch = async (input, options) => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.origin);
    const body = options?.body && typeof options.body === 'string' ? JSON.parse(options.body) : null;
    if (url.pathname === '/api/models' || (url.pathname === '/api/acp' && body?.method === 'graff/models')) {
      return new Response(JSON.stringify(catalog), { headers: { 'content-type': 'application/json' } });
    }
    if (url.pathname === '/api/acp' && body?.method === 'bootstrap') {
      return new Response(JSON.stringify({ sessionId: 'demo', commands: catalog.result.commands }), { headers: { 'content-type': 'application/json' } });
    }
    if (url.pathname === '/api/acp' && body?.method === 'session/prompt' && window.motionControlledStream) {
      return new Response(new ReadableStream({ start(controller) {
        const send = value => controller.enqueue(new TextEncoder().encode(JSON.stringify(value) + '\n'));
        window.motionStreamChunk = (text, thought = false) => send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'demo',
          update: { sessionUpdate: thought ? 'agent_thought_chunk' : 'agent_message_chunk', content: { type: 'text', text } } } });
        window.motionStreamFinish = () => { send({ jsonrpc: '2.0', id: 1, result: { stopReason: 'end_turn' } }); controller.close(); };
      } }), { headers: { 'content-type': 'application/x-ndjson' } });
    }
    return fallback(input, options);
  };
}
module.exports = { installMotionFixture };
