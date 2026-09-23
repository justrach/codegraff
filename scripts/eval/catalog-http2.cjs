// Local TLS model-list fixture with cursor pages and bounded-body failures.
const fs = require('node:fs');
const http2 = require('node:http2');
const https = require('node:https');
const [key, cert, log] = process.argv.slice(2);
const server = http2.createSecureServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: true });
const sessions = new WeakMap(); let nextSession = 1;
function record(row) { fs.appendFileSync(log, JSON.stringify(row) + '\n'); }
server.on('session', session => { const id = nextSession++; sessions.set(session, id); record({ event: 'session', id, alpn: session.socket.alpnProtocol }); });
server.on('stream', (stream, headers) => {
  stream.on('error', () => {});
  const path = headers[':path'];
  record({ event: 'request', path, method: headers[':method'], key: headers['x-api-key'], version: headers['anthropic-version'], accept: headers.accept, session: sessions.get(stream.session), stream: stream.id });
  if (path === '/stall') { stream.respond({ ':status': 200 }); stream.write('{'); return; }
  if (path === '/deny') { stream.respond({ ':status': 401 }); stream.end('private error'); return; }
  if (path === '/redirect') { stream.respond({ ':status': 302, location: '/v1/models?limit=1000' }); stream.end(); return; }
  if (path === '/cross-redirect') { stream.respond({ ':status': 302, location: `https://localhost:${h1.address().port}/v1/models?limit=1000` }); stream.end(); return; }
  if (path === '/cross-loop') { stream.respond({ ':status': 302, location: `https://localhost:${h1.address().port}/cross-loop` }); stream.end(); return; }
  stream.respond({ ':status': 200, 'content-type': 'application/json' });
  if (path === '/oversize') { stream.end('x'.repeat(2048)); return; }
  if (path === '/large-valid') { stream.end(JSON.stringify({ data: [{ id: 'large', description: 'x'.repeat(3 * 1024 * 1024) }] })); return; }
  if (path.includes('after_id=first')) { stream.end('{"data":[{"id":"second"}],"has_more":false}'); return; }
  stream.end('{"data":[{"id":"first"}],"has_more":true,"last_id":"first"}');
});
const h1 = https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, (req, res) => {
  record({ event: 'h1_request', path: req.url, method: req.method, key: req.headers['x-api-key'], version: req.headers['anthropic-version'], accept: req.headers.accept });
  if (req.url === '/redirect') { res.writeHead(302, { location: '/v1/models?limit=1000' }); res.end(); return; }
  if (req.url === '/cross-redirect') { res.writeHead(302, { location: `https://localhost:${server.address().port}/v1/models?limit=1000` }); res.end(); return; }
  if (req.url === '/cross-loop') { res.writeHead(302, { location: `https://localhost:${server.address().port}/cross-loop` }); res.end(); return; }
  if (req.url === '/deny-stall') { res.writeHead(401); res.write('private error'); return; }
  if (req.url === '/oversize') { res.end('x'.repeat(2048)); return; }
  res.setHeader('content-type', 'application/json');
  res.end('{"data":[{"id":"first"}],"has_more":false}');
});
server.listen(0, () => h1.listen(0, () => process.stdout.write(`${server.address().port} ${h1.address().port}\n`)));
