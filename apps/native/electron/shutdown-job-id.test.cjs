const { test } = require('node:test');
const assert = require('node:assert/strict');
const { listenerJobId } = require('./shutdown-job-id.cjs');
const result = id => ({role:'tool',content:`[job ${id} started: python3 listener.py]\npersistent server`});
test('shutdown pin targets actual JS-exact handle, deduplicating replayed tool history', () => {
 for (const id of ['1','4294967296','9007199254740991']) {
  assert.equal(listenerJobId([{messages:[result(id)]},{messages:[result(id),{role:'tool',content:'[job 7 started: python3 ready.py]'}]}]),id);
 }
});
test('shutdown pin rejects guessed, ambiguous and inexact handles', () => {
 assert.throws(()=>listenerJobId([{messages:[{role:'assistant',content:result(1).content}]}]),/exactly one/);
 assert.throws(()=>listenerJobId([{messages:[result(1),result(2)]}]),/exactly one/);
 assert.throws(()=>listenerJobId([{messages:[result('9007199254740992')]}]),/exact/);
});
