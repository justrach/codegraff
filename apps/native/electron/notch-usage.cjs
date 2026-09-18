const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const CODEX_USAGE = 'https://chatgpt.com/backend-api/wham/usage';

function clip(text, limit) {
  const trimmed = String(text || '').trim();
  if (trimmed.length <= limit) return trimmed;
  return `${trimmed.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

function usedPercent(window) {
  const n = window?.used_percent;
  if (typeof n !== 'number' || !Number.isFinite(n)) return null;
  return Math.max(0, Math.min(100, Math.round(n)));
}

function resetDetail(window) {
  const seconds = Number(window?.reset_after_seconds);
  if (!Number.isFinite(seconds) || seconds <= 0) return '';
  if (seconds < 60) return `resets in ${Math.round(seconds)}s`;
  if (seconds < 3600) return `resets in ${Math.round(seconds / 60)}m`;
  return `resets in ${Math.round(seconds / 3600)}h`;
}

function usageCell(id, title, percent, detail) {
  const used = Math.max(0, Math.min(100, Math.round(percent)));
  const state = used >= 100 ? 'error' : used >= 80 ? 'waiting' : 'working';
  return {
    id: hash(`usage:${id}`),
    title,
    caption: `${used}%`,
    state,
    label: `${title} ${used}%`,
    detail: clip(detail, 120),
    kind: 'usage',
    percent: used,
  };
}

function hash(key) {
  let value = 0;
  for (let i = 0; i < key.length; i++) value = (Math.imul(value, 31) + key.charCodeAt(i)) | 0;
  if (value === 0) return -1;
  return value > 0 ? -value : value;
}

/** Map a Codex `/wham/usage` body to notch cells. Tokens never leave this module. */
function cellsFromCodexUsage(json) {
  const primary = usedPercent(json?.rate_limit?.primary_window);
  if (primary == null) return [];
  return [usageCell('codex', 'Codex', primary, resetDetail(json.rate_limit.primary_window))];
}

function readCodexAuth(home = os.homedir()) {
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(home, '.codex', 'auth.json'), 'utf8'));
    const token = raw?.tokens?.access_token;
    const account = raw?.tokens?.account_id || raw?.account_id;
    if (typeof token === 'string' && token.length > 0) {
      return { token, account: typeof account === 'string' ? account : '' };
    }
  } catch { /* unsigned-in Codex is a missing cell, not an error */ }
  return null;
}

async function pollCodexUsage({ home, fetchImpl } = {}) {
  const auth = readCodexAuth(home);
  if (!auth) return [];
  const headers = { Authorization: `Bearer ${auth.token}`, Accept: 'application/json', 'Cache-Control': 'no-cache' };
  if (auth.account) headers['ChatGPT-Account-Id'] = auth.account;
  const fetchFn = fetchImpl || globalThis.fetch;
  if (!fetchFn) return [];
  try {
    const res = await fetchFn(CODEX_USAGE, { method: 'GET', headers });
    if (!res || !res.ok) return [];
    return cellsFromCodexUsage(await res.json());
  } catch {
    return [];
  }
}

module.exports = { cellsFromCodexUsage, readCodexAuth, pollCodexUsage, usageCell };
