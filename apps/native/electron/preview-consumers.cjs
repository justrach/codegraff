const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const counts = new Map();
const file = () => path.join(os.homedir(), '.codegraff', 'preview-consumers.json');

function portOf(url) {
  try {
    const parsed = new URL(url);
    if (parsed.hostname !== 'localhost' && parsed.hostname !== '127.0.0.1' && parsed.hostname !== '::1') return 0;
    const n = Number(parsed.port || (parsed.protocol === 'https:' ? 443 : 80));
    return Number.isInteger(n) && n > 0 ? n : 0;
  } catch { return 0; }
}

function write() {
  const dir = path.dirname(file());
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const body = {};
  for (const [port, n] of counts) body[String(port)] = n;
  const tmp = `${file()}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(body)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file());
}

function add(url) {
  const port = portOf(url);
  if (!port) return 0;
  counts.set(port, (counts.get(port) || 0) + 1);
  write();
  return port;
}

function remove(url) {
  const port = portOf(url);
  if (!port) return 0;
  const next = Math.max(0, (counts.get(port) || 1) - 1);
  counts.set(port, next);
  write();
  return port;
}

module.exports = { portOf, add, remove, write, counts };
