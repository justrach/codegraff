// Local TLS/HTTP2 provider fixture. Never permits an HTTP/1 fallback.
const http2 = require('node:http2');
const fs = require('node:fs');
const crypto = require('node:crypto');
const [key, cert, log, completionMode] = process.argv.slice(2);
const record = value => fs.appendFileSync(log, JSON.stringify(value) + '\n');
const server = http2.createSecureServer({
  key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: false,
});
let sessions = 0, requests = 0;
const concurrent = [];
server.on('session', session => {
  session.fixtureId = ++sessions;
  record({ event: 'session', session: sessions, alpn: session.socket.alpnProtocol });
  session.on('error', () => {});
});
server.on('tlsClientError', error => record({ event: 'tls-error', code: error.code }));
server.on('stream', (stream, headers) => {
  const session = stream.session.fixtureId;
  stream.on('error', () => {});
  stream.on('finish', () => record({ event: 'response-finished', stream: stream.id }));
  stream.on('close', () => record({ event: 'stream-closed', session, stream: stream.id }));
  let body = '';
  stream.on('data', chunk => { body += chunk; });
  stream.on('end', () => {
    const request = ++requests;
    record({ event: 'request', request, session: stream.session.fixtureId,
      stream: stream.id, method: headers[':method'], path: headers[':path'], body: JSON.parse(body) });
    stream.respond({ ':status': 200, 'content-type': 'text/event-stream' });
    const delta = text => `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text }, finish_reason: null }] })}\n\n`;
    if (completionMode) {
      if (completionMode !== 'quiet-empty') stream.write(delta('OK'));
      if (completionMode !== 'quiet-unterminated')
        stream.write('data: {"choices": [{"index":0,"delta":{}, "finish_reason": "stop"}]}\n\n');
      const usage = 'data: {"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":2,"total_tokens":22}}\n\n';
      if (completionMode === 'done') stream.end(usage + 'data: [DONE]\n\n');
      if (completionMode === 'quiet-usage') setTimeout(() => {
        if (!stream.destroyed) stream.write(usage);
      }, 100);
      // Quiet cases deliberately send neither [DONE] nor END_STREAM.
      return;
    }
    if (request === 5) {
      const tool = { index: 0, id: 'fixture-child', type: 'function', function: {
        name: 'subagent', arguments: JSON.stringify({ description: 'Inspect fixture',
          prompt: 'CHILD-CONCURRENCY-FIXTURE: return child complete, no tools required.',
          run_in_background: true, isolation: 'shared_cwd', model: JSON.parse(body).model }) } };
      stream.end(`data: ${JSON.stringify({ choices: [{ index: 0, delta: { tool_calls: [tool] }, finish_reason: null }] })}\n\n` +
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\ndata: [DONE]\n\n');
      return;
    }
    if (request > 5) {
      const messages = JSON.parse(body).messages;
      const lastUser = messages.filter(m => m.role === 'user').at(-1);
      const child = JSON.stringify(lastUser).includes('CHILD-CONCURRENCY-FIXTURE');
      concurrent.push({ stream, session, child, delta });
      record({ event: 'concurrent-arrival', session, child });
      // Neither response completes until root and child are both reading.
      // Sharing one non-multiplexing Conn corrupts or deadlocks this boundary.
      if (concurrent.length === 2) {
        record({ event: 'concurrent-ready', sessions: concurrent.map(c => c.session),
          roles: concurrent.map(c => c.child) });
        for (const c of concurrent) c.stream.end(c.delta(c.child ? 'child complete' : 'root complete') +
          'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
      }
      return;
    }
    if (request === 3) {
      // No END_STREAM or completion event: only ACP cancellation can finish
      // this turn within the test deadline. The next request remains usable.
      stream.write(delta('before-cancel'), () => record({ event: 'stalled', request, session, stream: stream.id }));
      return;
    }
    // Cross the initial 65,535-byte connection/stream windows: success requires
    // the production client to replenish both, not just parse a short response.
    const text = `h2-response-${request}:` + Array.from({ length: 1500 }, (_, i) =>
      crypto.createHash('sha256').update(String(i)).digest('hex')).join('\n');
    stream.end(delta(text) + 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
