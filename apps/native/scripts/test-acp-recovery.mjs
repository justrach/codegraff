import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { applyAcpUpdate, emptyTurn, finishAcpTurn, parseRpcLine } from '../lib/acp.ts';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const temporary = await mkdtemp(join(tmpdir(), 'graff-gui-acp-'));
try {
  const capture = join(temporary, 'updates.json');
  const run = spawnSync('python3', [join(root, 'scripts/test-acp-released-fixes.py'),
    process.argv[2] ?? join(root, 'zig-out/bin/graff'), '--capture', capture],
  { cwd: root, encoding: 'utf8', timeout: 120_000 });
  assert.equal(run.error, undefined, run.error?.message);
  assert.equal(run.status, 0, `${run.stdout}\n${run.stderr}`);
  const { messages } = JSON.parse(await readFile(capture, 'utf8'));
  const turns = [];
  let turn = emptyTurn();
  let rejectedBatch = false;
  let largeHandle = false;
  for (const message of messages) {
    const parsed = parseRpcLine(JSON.stringify(message));
    assert.ok(parsed);
    if (parsed.method === 'session/update') {
      const update = parsed.params.update;
      turn = applyAcpUpdate(turn, update);
      if (typeof update.rawInput?.id === 'number' && update.rawInput.id >= 2 ** 32) {
        assert.ok(Number.isSafeInteger(update.rawInput.id));
        largeHandle = true;
      }
      const text = (Array.isArray(update.content) ? update.content : []).map(item => item.content?.text ?? '').join('\n');
      if (update.status === 'failed' && text.includes('no batch changes written')) {
        assert.deepEqual(turn.diffs, []);
        assert.equal(turn.tools.at(-1)?.status, 'error');
        rejectedBatch = true;
      }
    } else if (parsed.result?.stopReason) {
      turns.push(finishAcpTurn(turn));
      turn = emptyTurn();
    }
  }
  assert.equal(rejectedBatch, true);
  assert.equal(largeHandle, true);
  assert.equal(turns.length, 3);
  assert.deepEqual(turns[0].tools.map(tool => tool.status), ['error', 'ok']);
  assert.equal(turns[0].diffs.length, 1);
  assert.equal(turns[1].tools.filter(tool => tool.status === 'error').length, 2);
  assert.equal(turns[2].tools[0]?.status, 'ok');
  console.log('PASS GUI ACP recovery: real wire errors, corrected edit, large handles, and follow-up render correctly');
} finally {
  await rm(temporary, { recursive: true, force: true });
}
