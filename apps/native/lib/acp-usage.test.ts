import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { applyAcpUpdate, emptyTurn, finishAcpTurn, parseRpcLine } from './acp';
import { parseAcpUsage, usageCaption, usageUpdate } from './acp-usage';
const update = { sessionUpdate: 'gui_usage', scope: 'connection', usage_complete: false, cost_complete: false,
  cost_usd: null, known_cost_usd: 0.012, input_tokens: 14, cache_read_tokens: 4, cache_write_tokens: 0, output_tokens: 2,
  api_calls: 1, missing_usage_calls: 0, unreported_failed_attempts: 1, subscription_calls: 0, unpriced_calls: 0 };
test('ACP usage wire keeps known subtotals distinct from unknown totals through reducer', () => {
  const line = parseRpcLine(JSON.stringify({ jsonrpc: '2.0', method: '_codegraff/usage', params: { sessionId: 's', usage: update } }));
  assert.ok(line && 'method' in line);
  const turn = applyAcpUpdate(emptyTurn(), usageUpdate(line, 's')!);
  assert.equal(usageUpdate(line, 'different-session'), undefined);
  assert.equal(turn.usage?.costUsd, null);
  assert.equal(turn.usage?.input, 14);
  assert.equal(turn.costUsd, undefined);
  const caption = usageCaption(turn.usage!);
  assert.match(caption, /Total cost unknown/);
  assert.match(caption, /known metered subtotal \$0.0120/);
  assert.match(caption, /total tokens unknown/);
  assert.match(caption, /1 failed attempt/);
  assert.match(caption, /Usage since connection/);
  assert.match(caption, /4 cached read · 0 cache write/);
});
test('complete subscription tokens still do not imply free or known total billing', () => {
  const value = parseAcpUsage({ ...update, usage_complete: true, unreported_failed_attempts: 0, subscription_calls: 1, known_cost_usd: 0 })!;
  assert.equal(value.usageComplete, true);
  assert.equal(value.costUsd, null);
  assert.match(usageCaption(value), /subscription billing/);
  assert.doesNotMatch(usageCaption(value), /\$0\.0000/);
  assert.equal(parseAcpUsage({ ...update, input_tokens: -1 }), undefined);
  assert.equal(parseAcpUsage({ ...update, usage_complete: undefined }), undefined);
});
test('network retry indicator preserves previous prose and excludes quoted matches', () => {
  const prior = { ...emptyTurn(), text: 'Working.' };
  const text = '[network error: EndOfStream — retrying in 200ms (1/6)]\n';
  const turn = applyAcpUpdate(prior, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } });
  assert.equal(turn.text, 'Working.');
  assert.match(turn.retryNotice!, /EndOfStream/);
  const quoted = applyAcpUpdate(prior, { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Example: ' + text } });
  assert.match(quoted.text, /Example:/);
  assert.equal(emptyTurn().usage, undefined);
});

test('real ACP failure and recovery receipts reach GUI without fabricated totals', { skip: !process.env.GRAFF_ACP_USAGE_CAPTURE }, () => {
  const lines = readFileSync(process.env.GRAFF_ACP_USAGE_CAPTURE!, 'utf8').trim().split('\n').map(line => JSON.parse(line));
  const receipts = lines.filter(line => line.method === '_codegraff/usage');
  assert.equal(receipts.length, 2);
  for (const [index, line] of receipts.entries()) {
    const turn = applyAcpUpdate(emptyTurn(), usageUpdate(line, line.params.sessionId)!);
    assert.equal(turn.usage?.failed, index === 0 ? 1 : 7);
    assert.equal(turn.usage?.calls, 1);
    assert.equal(turn.usage?.costUsd, null);
    assert.match(usageCaption(turn.usage!), /Total cost unknown/);
  }
  assert.ok(lines.some(line => line.error));
  assert.ok(lines.some(line => line.params?.update?.content?.text?.includes('network error:')));
});
