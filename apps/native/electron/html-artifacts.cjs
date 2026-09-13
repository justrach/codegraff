const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { randomBytes } = require('node:crypto');
const MAX_BYTES = 256 * 1024;
const validId = id => typeof id === 'string' && /^[a-f0-9]{32}$/.test(id);
function validate(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !['title','html'].includes(key))) throw Error('Expected title and html only');
  if (typeof value.title !== 'string' || !value.title.trim() || value.title.length > 120) throw Error('Title must contain 1–120 characters');
  if (typeof value.html !== 'string' || !value.html.trim() || Buffer.byteLength(value.html) > MAX_BYTES) throw Error('HTML must contain 1–262144 bytes');
  return { title: value.title.trim(), html: value.html };
}
async function directory(home, create) {
  const base = path.join(home, '.graff'), root = path.join(base, 'html-artifacts');
  for (const dir of [base, root]) {
    if (create) await fs.mkdir(dir, { mode: 0o700 }).catch(error => { if(error.code!=='EEXIST')throw error; });
    const stat = await fs.lstat(dir);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw Error('Invalid preview directory');
  }
  return root;
}
async function saveHtml(value, home = os.homedir()) {
  const data = validate(value), root = await directory(home, true);
  if ((await fs.readdir(root)).length >= 512) throw Error('Saved preview storage is full; remove unneeded previews first');
  const id = randomBytes(16).toString('hex');
  await fs.writeFile(path.join(root, `${id}.json`), JSON.stringify(data), { mode: 0o600, flag: 'wx' });
  return id;
}
async function readHtml(id, home = os.homedir()) {
  if (!validId(id)) throw Error('Invalid preview id');
  const root = await directory(home, false);
  const file = await fs.open(path.join(root, `${id}.json`), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > MAX_BYTES * 6 + 1024) throw Error('Invalid preview snapshot');
    return validate(JSON.parse(await file.readFile('utf8')));
  } finally { await file.close(); }
}
module.exports = { saveHtml, readHtml, validId, MAX_BYTES };
