// Offline ACP retry peer: records complete POST bodies and serves one SSE reply.
const http2 = require('node:http2');
const fs = require('node:fs');
const crypto = require('node:crypto');
const [key, cert, log] = process.argv.slice(2);
const record = row => fs.appendFileSync(log, JSON.stringify(row) + '\n');
const server = http2.createSecureServer({
  key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: true,
});
let sessions = 0;
const reply = 'data: {"choices":[{"index":0,"delta":{"content":"OK"},"finish_reason":null}]}\n\n' +
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n' +
  'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}\n\n' +
  'data: [DONE]\n\n';
function post(protocol, body, extra) {
  record({event:'post', protocol, bytes:Buffer.byteLength(body),
    sha256:crypto.createHash('sha256').update(body).digest('hex'),
    atMs:Number(process.hrtime.bigint() / 1000000n), ...extra});
}
server.on('session', session => {
  session.fixtureId = ++sessions;
  session.on('error', () => {});
  record({event:'session', id:sessions, alpn:session.socket.alpnProtocol});
});
server.on('stream', (stream, headers) => {
  const session = stream.session.fixtureId;
  stream.on('error', () => {});
  let body = '';
  stream.on('data', chunk => { body += chunk; });
  stream.on('end', () => {
    post('h2', body, {session, stream:stream.id,
      method:headers[':method'], path:headers[':path']});
    try { stream.respond({':status':200,'content-type':'text/event-stream'}); stream.end(reply); }
    catch (_) { /* The injected client failure may close its stream. */ }
  });
});
server.on('request', (req, res) => {
  if (req.httpVersionMajor !== 1) return;
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    post('h1', body, {method:req.method, path:req.url});
    res.writeHead(200, {'content-type':'text/event-stream'}); res.end(reply);
  });
});
server.on('tlsClientError', error => record({event:'tls-error', code:error.code}));
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
