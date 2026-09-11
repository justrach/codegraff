const fs = require('node:fs');
const path = require('node:path');

function workspaceTarget(value) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.length > 4096 || value.includes('\0')) return null;
  try {
    const target = fs.realpathSync(value), stat = fs.statSync(target);
    if (stat.isDirectory()) return { cwd: target };
    if (stat.isFile()) return { cwd: path.dirname(target), file: path.basename(target) };
  } catch {}
  return null;
}

// Startup and reload may take longer than a terminal launch. Keep the latest
// request until project restoration and the renderer's listener are ready.
function workspaceOpen(send) {
  let ready = false, pending = null;
  const flush = () => {
    if (!ready || !pending) return;
    const target = pending;
    pending = null;
    send(target);
  };
  return {
    open(value) { const target = workspaceTarget(value); if (!target) return false; pending = target; flush(); return true; },
    ready() { ready = true; flush(); },
    loading() { ready = false; },
  };
}
module.exports = { workspaceTarget, workspaceOpen };
