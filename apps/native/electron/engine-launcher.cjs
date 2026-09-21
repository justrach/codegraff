const fs = require('node:fs/promises');
const path = require('node:path');
const marker = '# Codegraff bundled engine launcher';
const pathMarker = '# Codegraff GUI CLI PATH';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

async function writeShim(file, source) {
  let owned = true;
  try {
    const stat = await fs.lstat(file);
    owned = stat.isFile() && stat.size < 16384 && (await fs.readFile(file, 'utf8')).includes(marker);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  if (!owned) return false;
  const temporary = `${file}.${process.pid}.next`;
  await fs.mkdir(path.dirname(file), {recursive: true});
  try {
    await fs.writeFile(temporary, source, {mode: 0o755, flag: 'wx'});
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, {force: true}); }
  return true;
}

async function ensurePath(home, directory) {
  if (process.env.HARNESS_NO_PATH) return;
  const line = `export PATH=${quote(directory)}:"$PATH"`;
  const files = [
    [path.join(home, '.zshrc'), line, true],
    [path.join(home, '.zprofile'), line, true],
    [path.join(home, '.bash_profile'), line, true],
    [path.join(home, '.bashrc'), line, true],
    [path.join(home, '.profile'), line, false],
    [path.join(home, '.config/fish/config.fish'), `fish_add_path -m ${quote(directory)}`, false],
  ];
  for (const [file, snippet, create] of files) {
    let source;
    try { source = await fs.readFile(file, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; if (!create) continue; source = ''; }
    if (source.includes(pathMarker)) continue;
    await fs.mkdir(path.dirname(file), {recursive: true});
    await fs.appendFile(file, `\n${pathMarker}\n${snippet}\n`, {mode: 0o600});
  }
}

async function installEngine(binary, home, {extraBin} = {}) {
  await fs.access(binary, require('node:fs').constants.X_OK);
  const directory = path.join(home, '.local/bin'), file = path.join(directory, 'graff');
  const source = `#!/bin/sh\n${marker}\nexec ${quote(binary)} "$@"\n`;
  const installed = await writeShim(file, source);
  // PATH even when ~/.local/bin/graff is someone else's binary — otherwise the
  // user still cannot type `graff` after installing the app.
  await ensurePath(home, directory);
  for (const dir of extraBin ?? [path.join(home, 'bin')]) {
    try { await writeShim(path.join(dir, 'graff'), source); } catch { /* not writable */ }
  }
  return installed ? `Installed graff in ${directory}. Open a new terminal to use it.` : 'Existing graff command preserved';
}
module.exports = {installEngine, ensurePath};
