// Local TLS fixture: acknowledge one POST, then hold its JSON body open.
const fs = require('node:fs');
const http2 = require('node:http2');
const [key, cert, log] = process.argv.slice(2);
const server = http2.createSecureServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: true });
function record(row) { fs.appendFileSync(log, JSON.stringify(row) + '\n'); }
const sessions = new WeakMap(); let nextSession = 1;
server.on('session', session => {
  const id = nextSession++;
  sessions.set(session, id);
  record({ event: 'session', id, alpn: session.socket.alpnProtocol });
});
server.on('stream', (stream, headers) => {
  let body = '';
  stream.on('error', () => {}); // expected for the deliberate reset path
  stream.on('data', chunk => { body += chunk.toString(); });
  stream.on('end', () => {
    record({ event: 'request', path: headers[':path'], method: headers[':method'], auth: headers.authorization, body,
             session: sessions.get(stream.session), stream: stream.id });
    if (headers[':path'] === '/ok') {
      stream.respond({ ':status': 200, 'content-type': 'application/json' });
      stream.end('{"ok":true}');
      return;
    }
    if (headers[':path'] === '/drop') {
      stream.close(http2.constants.NGHTTP2_INTERNAL_ERROR);
      record({ event: 'dropped' });
      return;
    }
    stream.respond({ ':status': 200, 'content-type': 'application/json' });
    stream.write('{"answers":');
    record({ event: 'stalled' });
  });
  stream.on('close', () => record({ event: 'closed' }));
});
server.listen(0, () => process.stdout.write(String(server.address().port) + '\n'));
