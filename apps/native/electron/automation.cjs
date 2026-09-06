const http = require('node:http');
const { randomBytes } = require('node:crypto');
const { authorized } = require('./policy.cjs');
const { browserAction } = require('./browser-actions.cjs');

async function startAutomation(browser, computer, profiler) {
  const token = randomBytes(32).toString('hex');
  const server = http.createServer(async (req, res) => {
    const reply = (status, body) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(body)); };
    if (!authorized(req, token)) return reply(401, { error: 'Unauthorized' });
    if (req.method !== 'POST' || !['/command', '/computer', '/profiler'].includes(req.url)) return reply(404, { error: 'Unknown endpoint' });
    try {
      let raw = ''; for await (const chunk of req) { raw += chunk; if (raw.length > 1024 * 1024) throw new Error('Request too large'); }
      const { chat, method, params = {} } = JSON.parse(raw);
      const started = performance.now();
      let result;
      try {
        result = req.url === '/profiler' ? await profiler.command(method, params) : req.url === '/computer' ? await computer.command(method, params) : await browserAction(browser, chat, method, params);
        if (req.url !== '/profiler') profiler?.record(req.url === '/computer' ? 'computer-action' : 'browser-action', performance.now() - started);
      } catch (error) { profiler?.record('action-failed', performance.now() - started); throw error; }
      reply(200, { result });
    } catch (error) { reply(400, { error: error.message }); }
  });
  server.requestTimeout = 30_000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return { server, handle: chat => ({ port: server.address().port, token, tabId: chat, backend: 'electron' }) };
}
module.exports = { startAutomation };
