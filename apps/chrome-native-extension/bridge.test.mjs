import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import {frames, tools} from './bridge.mjs';

test('native framing handles fragmentation, coalescing and oversize input', () => {
  const values = []; const read = frames(v => values.push(v));
  const body = Buffer.from('{"id":1}'); const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
  const wire = Buffer.concat([header, body]);
  read(wire.subarray(0, 2)); read(Buffer.concat([wire.subarray(2), wire]));
  assert.deepEqual(values, [{id: 1}, {id: 1}]);
  header.writeUInt32LE(1024 * 1024 + 1);
  assert.throws(() => read(header), /exceeds/);
});
test('MCP initialization and discovery run over actual stdio', async () => {
  const child = spawn(process.execPath, ['bridge.mjs'], {cwd: import.meta.dirname});
  let output = ''; child.stdout.on('data', chunk => output += chunk);
  child.stdin.end(JSON.stringify({jsonrpc: '2.0', id: 1, method: 'initialize'}) + '\n' + JSON.stringify({jsonrpc: '2.0', id: 2, method: 'tools/list'}) + '\n');
  const [code] = await once(child, 'exit'); assert.equal(code, 0);
  const results = output.trim().split('\n').map(JSON.parse);
  assert.equal(results[0].result.serverInfo.name, 'graff-chrome');
  assert.equal(results[1].result.tools.length, tools.length);
});
test('native host carries a socket request to Chrome and returns its response', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-chrome-'));
  const socket = path.join(directory, 'bridge.sock');
  const child = spawn(process.execPath, ['bridge.mjs', '--native'], {cwd: import.meta.dirname, env: {...process.env, GRAFF_CHROME_DIR: directory}});
  try {
    child.stdout.on('data', frames(message => {
      assert.equal(message.name, 'chrome_tabs');
      const body = Buffer.from(JSON.stringify({id: message.id, result: [{id: 7}]}));
      const header = Buffer.alloc(4); header.writeUInt32LE(body.length);
      child.stdin.write(Buffer.concat([header, body]));
    }));
    for (let i = 0; !fs.existsSync(socket) && i < 100; i++) await new Promise(r => setTimeout(r, 10));
    assert.equal(fs.statSync(socket).mode & 0o777, 0o600);
    const client = net.createConnection(socket); let result = '';
    client.on('data', chunk => result += chunk);
    await once(client, 'connect'); client.write('{"name":"chrome_tabs"}\n');
    await once(client, 'end'); assert.deepEqual(JSON.parse(result).result, [{id: 7}]);
  } finally {
    child.stdin.end(); await once(child, 'exit'); fs.rmSync(directory, {recursive: true, force: true});
  }
});
