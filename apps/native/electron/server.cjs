const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

async function startServer(resources, root, token, logDirectory, desktopEnv = {}) {
  const probe = net.createServer();
  // Keep the UI origin stable so Chromium retains local UI preferences across launches.
  await new Promise((resolve, reject) => {
    probe.once('error', error => {
      if (error.code !== 'EADDRINUSE') return reject(error);
      probe.once('error', reject); probe.listen(0, '127.0.0.1', resolve);
    });
    probe.listen(3788, '127.0.0.1', resolve);
  });
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  fs.mkdirSync(logDirectory, { recursive: true });
  const log = fs.openSync(path.join(logDirectory, 'server.log'), 'a');
  const child = spawn(path.join(resources, 'bun'), [path.join(resources, 'ui/server.js')], {
    cwd: path.join(resources, 'ui'), detached: true, stdio: ['ignore', log, log],
    env: { ...process.env, ...desktopEnv, NODE_ENV: 'production', PORT: String(port), HOSTNAME: '127.0.0.1',
      GRAFF_BIN: path.join(resources, 'graff'), GRAFF_CWD: root, GRAFF_DESKTOP_TOKEN: token },
  });
  fs.closeSync(log);
  let spawnError; child.on('error', error => { spawnError = error; });
  const origin = `http://127.0.0.1:${port}`;
  const stop = () => { if (child.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} } };
  try {
    for (let attempt = 0; attempt < 120; attempt++) {
      if (spawnError) throw spawnError;
      if (child.exitCode !== null) throw new Error(`UI server exited (${child.exitCode})`);
      try { const response = await fetch(origin, { signal: AbortSignal.timeout(1000) }); if (response.ok) return { origin, child, stop }; } catch {}
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    throw new Error('UI server did not start');
  } catch (error) { stop(); throw error; }
}
module.exports = { startServer };
