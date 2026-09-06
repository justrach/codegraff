const fs = require('node:fs/promises');
const path = require('node:path');
function validate(value) {
  if (!value || !Array.isArray(value.list) || value.list.length > 50) throw Error('Invalid project list');
  const list = value.list.map(row => {
    if (!row || typeof row.path !== 'string' || !path.isAbsolute(row.path) || row.path.length > 4096 || typeof row.name !== 'string' || row.name.length > 512) throw Error('Invalid project');
    return { path: row.path, name: row.name, ...(typeof row.model === 'string' ? { model: row.model.slice(0, 256) } : {}),
      ...(typeof row.yolo === 'boolean' ? { yolo: row.yolo } : {}), ...(typeof row.mcp === 'boolean' ? { mcp: row.mcp } : {}) };
  });
  return { list, active: list.some(row => row.path === value.active) ? value.active : null };
}
function projectStore(directory) {
  const file = path.join(directory, 'projects.json'); let pending = Promise.resolve();
  return {
    async load() { await pending; try { return validate(JSON.parse(await fs.readFile(file, 'utf8'))); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } },
    save(value) {
      const data = validate(value);
      const write = pending.then(async () => {
        await fs.mkdir(directory, { recursive: true });
        await fs.writeFile(`${file}.next`, JSON.stringify(data), { mode: 0o600 });
        await fs.rename(`${file}.next`, file);
      });
      pending = write.catch(() => {}); return write;
    },
  };
}
module.exports = { projectStore };
