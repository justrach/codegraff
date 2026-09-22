// Local TLS/HTTP2 provider fixture. Never permits an HTTP/1 fallback.
const http2 = require('node:http2');
const fs = require('node:fs');
const crypto = require('node:crypto');
const [key, cert, log] = process.argv.slice(2);
const record = value => fs.appendFileSync(log, JSON.stringify(value) + '\n');
const server = http2.createSecureServer({
  key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: false,
});
let sessions = 0, requests = 0;
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
