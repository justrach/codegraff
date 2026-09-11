const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
function validate(value) {
  if (value !== 'system' && value !== 'graff') throw Error('Invalid link preference');
  return value;
}
function linkSettings(directory) {
  const file = path.join(directory, 'web-links.json'); let pending = Promise.resolve();
  return {
    async load() {
      await pending;
      let data;
      try { data = await fs.readFile(file, 'utf8'); } catch (error) { if (error.code === 'ENOENT') return 'system'; throw error; }
      try { return validate(JSON.parse(data)); } catch { return 'system'; }
    },
    async save(value) {
      const data = validate(value);
      const write = pending.then(async () => {
        await fs.mkdir(directory, { recursive: true });
        const temporary = `${file}.${randomUUID()}.next`;
        try {
          await fs.writeFile(temporary, JSON.stringify(data), { mode: 0o600, flag: 'wx' });
          await fs.rename(temporary, file);
        } finally { await fs.unlink(temporary).catch(() => {}); }
        return data;
      });
      pending = write.catch(() => {}); return write;
    },
  };
}
module.exports = { linkSettings };
