// Local model stream and delayed lookup; no external network or credentials.
const http2 = require('node:http2');
const http = require('node:http');
const fs = require('node:fs');
const [key, cert, log, mode] = process.argv.slice(2);
const record = value => fs.appendFileSync(log, JSON.stringify({ ...value, ms: performance.now() }) + '\n');
const lookup = http.createServer((req, res) => {
  record({ event: 'lookup-start' });
  setTimeout(() => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('LOOKUP_RESULT_OK');
    record({ event: 'lookup-end' });
  }, 700);
});
const server = http2.createSecureServer({key: fs.readFileSync(key), cert: fs.readFileSync(cert), allowHTTP1: false});
let requests = 0;
server.on('session', session => {
  record({ event: 'session', alpn: session.socket.alpnProtocol });
  session.on('error', error => record({ event: 'session-error', code: error.code }));
  session.on('frameError', (type, code, id) => record({ event: 'frame-error', type, code, id }));
});
server.on('stream', (stream, headers) => {
  record({ event: 'stream-start' });
  stream.on('error', error => record({ event: 'stream-error', code: error.code }));
  let raw = '';
  stream.on('data', chunk => { raw += chunk; record({ event: 'body-chunk', size: chunk.length, total: raw.length }); });
  stream.on('close', () => record({ event: 'stream-close' }));
  stream.on('end', () => {
    const body = JSON.parse(raw), request = ++requests;
    record({ event: 'request', request, body });
    stream.respond({ ':status': 200, 'content-type': 'text/event-stream' });
    const send = event => { if (!stream.destroyed) stream.write(`data: ${JSON.stringify(event)}\n\n`); };
    const text = value => {
      send({ type: 'response.output_text.delta', delta: value });
      send({ type: 'response.output_item.done', item: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: value }] } });
    };
    const done = () => {
      record({ event: 'response-completed', request });
      send({ type: 'response.completed', response: { id: `resp_fixture_${request}`, output: [], usage: { input_tokens: 20, output_tokens: 5, total_tokens: 25 } } });
      stream.end();
    };
    if (request > 1) {
      const results = body.input.filter(item => item.type === 'function_call_output' && item.call_id === 'fixture_lookup');
      record({ event: 'delivered', count: results.length, correct: results.length === 1 && results[0].output.includes('LOOKUP_RESULT_OK') });
      text('ASYNC_FIXTURE_DONE');
      done();
      return;
    }
    const item = { type: 'function_call', call_id: 'fixture_lookup', name: 'webfetch', arguments: JSON.stringify({ url: `http://127.0.0.1:${lookup.address().port}/lookup` }) };
    if (mode !== 'off') item.async = true;
    send({ type: 'response.output_item.added', item: { type: 'tool_search_call' } });
    send({ type: 'response.output_item.done', item: { type: 'tool_search_call' } });
    send({ type: 'response.output_item.done', item: { type: 'tool_search_output' } });
    send({ type: 'response.output_item.done', item });
    if (mode === 'duplicate') send({ type: 'response.output_item.done', item });
    setTimeout(() => { record({ event: 'independent-prose' }); text('INDEPENDENT_WORK'); }, 100);
    setTimeout(() => {
      if (mode === 'failed') {
        record({ event: 'response-failed' });
        send({ type: 'response.failed', response: { error: { code: 'server_error', message: 'fixture interrupted after dispatch' } } });
        stream.end();
      } else done();
    }, 350);
  });
});
lookup.listen(0, '127.0.0.1', () => server.listen(0, '127.0.0.1', () => console.log(server.address().port)));
