const { test, expect } = require('bun:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { cellsFromCodexUsage, pollCodexUsage, readCodexAuth } = require('./notch-usage.cjs');

test('Codex primary window becomes a percent cell without leftover tokens', () => {
  const cells = cellsFromCodexUsage({
    rate_limit: { primary_window: { used_percent: 42.4, reset_after_seconds: 3600 } },
  });
  expect(cells).toHaveLength(1);
  expect(cells[0]).toMatchObject({ title: 'Codex', caption: '42%', kind: 'usage', percent: 42, detail: 'resets in 1h' });
  expect(JSON.stringify(cells)).not.toMatch(/Bearer|access_token/);
});

test('missing or unreadable usage windows yield no cells', () => {
  expect(cellsFromCodexUsage({})).toEqual([]);
  expect(cellsFromCodexUsage({ rate_limit: { primary_window: { used_percent: null } } })).toEqual([]);
});

test('unsigned Codex auth is a missing cell, and fetch never sees a token dump', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'graff-codex-'));
  expect(readCodexAuth(home)).toBe(null);
  expect(await pollCodexUsage({ home, fetchImpl: () => { throw new Error('should not fetch'); } })).toEqual([]);
  fs.mkdirSync(path.join(home, '.codex'));
  fs.writeFileSync(path.join(home, '.codex', 'auth.json'), JSON.stringify({
    tokens: { access_token: 'secret-token', account_id: 'acct' },
  }));
  const headers = [];
  const cells = await pollCodexUsage({
    home,
    fetchImpl: async (_url, init) => {
      headers.push(init.headers);
      return { ok: true, json: async () => ({ rate_limit: { primary_window: { used_percent: 9 } } }) };
    },
  });
  expect(cells[0]).toMatchObject({ caption: '9%', kind: 'usage' });
  expect(headers[0].Authorization).toBe('Bearer secret-token');
  expect(JSON.stringify(cells)).not.toContain('secret-token');
});
