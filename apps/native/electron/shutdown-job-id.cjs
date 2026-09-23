const assert = require('node:assert/strict');
/** Read the listener's actual handle from captured model tool results. */
exports.listenerJobId = requests => {
  const ids = new Set();
  for (const request of requests) for (const message of request.messages || []) {
    if (message.role !== 'tool' || typeof message.content !== 'string') continue;
    const match = message.content.match(/^\[job (\d+) started: python3 listener\.py\](?:\n|$)/);
    if (!match) continue;
    const id = Number(match[1]);
    assert(Number.isSafeInteger(id) && id > 0, 'Listener handle must be an exact positive JSON integer');
    ids.add(String(id));
  }
  assert.equal(ids.size, 1, 'Expected exactly one listener handle in completed tool results');
  return [...ids][0];
};
