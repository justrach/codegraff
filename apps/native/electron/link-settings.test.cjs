const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const { linkSettings } = require('./link-settings.cjs');
async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'link-settings-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}
test('missing directory defaults to system without creating files', async t => {
  const directory = path.join(await fixture(t), 'nested', 'settings');
  assert.equal(await linkSettings(directory).load(), 'system');
  await assert.rejects(fs.stat(directory), { code: 'ENOENT' });
});
test('missing file defaults to system and leaves other settings alone', async t => {
  const root = await fixture(t);
  await fs.writeFile(path.join(root, 'projects.json'), '{"list":[]}');
  const store = linkSettings(root);
  assert.equal(await store.load(), 'system');
  await store.save('graff');
  assert.equal(await fs.readFile(path.join(root, 'projects.json'), 'utf8'), '{"list":[]}');
  assert.deepEqual((await fs.readdir(root)).sort(), ['projects.json', 'web-links.json']);
});
for (const data of ['', '{', 'undefined', 'null', 'true', '42', '[]', '{}', '"GRAFF"', '"graff "', '{"preference":"graff"}']) {
  test(`corrupt or invalid stored data defaults to system: ${JSON.stringify(data)}`, async t => {
    const root = await fixture(t);
    await fs.writeFile(path.join(root, 'web-links.json'), data);
    const store = linkSettings(root);
    assert.equal(await store.load(), 'system');
    assert.equal(await store.save('graff'), 'graff');
    assert.equal(await store.load(), 'graff');
  });
}
for (const value of ['system', 'graff']) {
  test(`${value} roundtrips through a new store and a new process`, async t => {
    const directory = path.join(await fixture(t), 'nested');
    const store = linkSettings(directory);
    assert.equal(await store.save(value), value);
    assert.equal(await store.load(), value);
    assert.equal(await linkSettings(directory).load(), value);
    assert.equal(JSON.parse(await fs.readFile(path.join(directory, 'web-links.json'), 'utf8')), value);
    const { stdout } = await execFile(process.execPath, ['-e',
      'require(process.argv[1]).linkSettings(process.argv[2]).load().then(value => process.stdout.write(value));',
      require.resolve('./link-settings.cjs'), directory]);
    assert.equal(stdout, value);
  });
}
test('invalid saves reject promises without changing the saved preference', async t => {
  const root = await fixture(t), store = linkSettings(root);
  await store.save('graff');
  for (const value of [undefined, null, false, 0, '', 'SYSTEM', 'Graff', 'system ', ' graff', [], {}, new String('graff')]) {
    await assert.rejects(store.save(value), /Invalid link preference/);
    assert.equal(await store.load(), 'graff');
  }
  assert.equal(await store.save('system'), 'system');
});
test('concurrent saves resolve in call order and load waits for all queued writes', async t => {
  const root = await fixture(t), store = linkSettings(root), completed = [];
  const values = Array.from({ length: 40 }, (_, i) => i % 2 ? 'graff' : 'system');
  const writes = values.map((value, i) => store.save(value).then(result => { completed.push(i); return result; }));
  const read = store.load();
  assert.equal(await read, 'graff');
  assert.deepEqual(await Promise.all(writes), values);
  assert.deepEqual(completed, values.map((_, i) => i));
  assert.equal(await linkSettings(root).load(), 'graff');
  assert.deepEqual(await fs.readdir(root), ['web-links.json']);
});
test('independent stores write complete JSON using separate temporary files', async t => {
  const root = await fixture(t);
  await Promise.all(Array.from({ length: 20 }, (_, i) => linkSettings(root).save(i % 2 ? 'graff' : 'system')));
  assert.ok(['system', 'graff'].includes(await linkSettings(root).load()));
  assert.deepEqual(await fs.readdir(root), ['web-links.json']);
});
test('directory creation failure rejects without poisoning subsequent saves', async t => {
  const root = await fixture(t), directory = path.join(root, 'settings');
  await fs.writeFile(directory, 'blocked');
  const store = linkSettings(directory);
  await assert.rejects(store.save('graff'));
  await fs.unlink(directory);
  assert.equal(await store.load(), 'system');
  assert.equal(await store.save('graff'), 'graff');
  assert.equal(await store.load(), 'graff');
});
test('rename failure cleans temporary files and allows recovery', async t => {
  const root = await fixture(t), file = path.join(root, 'web-links.json');
  await fs.mkdir(file);
  const store = linkSettings(root);
  await assert.rejects(store.save('graff'));
  assert.deepEqual(await fs.readdir(root), ['web-links.json']);
  await fs.rmdir(file);
  assert.equal(await store.save('system'), 'system');
  assert.equal(await store.load(), 'system');
});
test('saved files are private, including replacement of a permissive file', { skip: process.platform === 'win32' }, async t => {
  const root = await fixture(t), file = path.join(root, 'web-links.json'), store = linkSettings(root);
  await store.save('graff');
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  await fs.chmod(file, 0o644);
  await store.save('system');
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
});
test('permission failure preserves the old preference and subsequent saves recover', { skip: process.platform === 'win32' || process.getuid?.() === 0 }, async t => {
  const root = await fixture(t), store = linkSettings(root);
  await store.save('system');
  await fs.chmod(root, 0o500);
  try {
    await assert.rejects(store.save('graff'), { code: 'EACCES' });
    assert.equal(await store.load(), 'system');
  } finally { await fs.chmod(root, 0o700); }
  assert.equal(await store.save('graff'), 'graff');
  assert.equal(await store.load(), 'graff');
});
