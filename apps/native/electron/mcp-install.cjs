const { promisify } = require('node:util');
const { execFile } = require('node:child_process');
const fs = require('node:fs/promises');
const path = require('node:path');

async function installMcp(binary, home, { once = false } = {}) {
  if (process.env.GRAFF_NO_MCP === '1') return 'MCP setup skipped';
  const receipt = path.join(home, '.graff/mcp/gui-installed');
  if (once) {
    try { await fs.access(receipt); return 'MCP already configured'; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const { stdout, stderr } = await promisify(execFile)(binary, ['mcp', 'install'], {
    env: { ...process.env, HOME: home }, timeout: 35000, maxBuffer: 32768,
  });
  await fs.mkdir(path.dirname(receipt), { recursive: true, mode: 0o700 });
  await fs.writeFile(receipt, '1\n', { mode: 0o600 });
  return stdout + stderr;
}
module.exports = { installMcp };
