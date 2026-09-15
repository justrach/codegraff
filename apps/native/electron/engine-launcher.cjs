const fs = require('node:fs/promises');
const path = require('node:path');
const marker = '# Codegraff bundled engine launcher';
const pathMarker = '# Codegraff GUI CLI PATH';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

async function ensurePath(home, directory, shell = process.env.SHELL || '/bin/zsh') {
  if (process.env.HARNESS_NO_PATH) return;
  const shellName = path.basename(shell);
  const candidates = [
    [path.join(home, '.zshrc'), shellName === 'zsh', `export PATH=${quote(directory)}:"$PATH"`],
    [path.join(home, '.bash_profile'), shellName === 'bash', `export PATH=${quote(directory)}:"$PATH"`],
    [path.join(home, '.bashrc'), shellName === 'bash', `export PATH=${quote(directory)}:"$PATH"`],
    [path.join(home, '.profile'), !['zsh', 'bash', 'fish'].includes(shellName), `export PATH=${quote(directory)}:"$PATH"`],
    [path.join(home, '.config/fish/config.fish'), shellName === 'fish', `fish_add_path -m ${quote(directory)}`],
  ];
  for (const [file, create, line] of candidates) {
    let source;
    try { source = await fs.readFile(file, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; if (!create) continue; source = ''; }
    if (source.includes(pathMarker)) continue;
    await fs.mkdir(path.dirname(file), {recursive:true});
    await fs.appendFile(file, `\n${pathMarker}\n${line}\n`, {mode:0o600});
  }
}

async function installEngine(binary, home, {shell} = {}) {
  await fs.access(binary, require('node:fs').constants.X_OK);
  const directory = path.join(home, '.local/bin'), file = path.join(directory, 'graff');
  await fs.mkdir(directory, {recursive:true});
  let owned = true;
  try {
    const stat = await fs.lstat(file);
    owned = stat.isFile() && stat.size < 16384 && (await fs.readFile(file, 'utf8')).includes(marker);
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!owned) return 'Existing graff command preserved';
  const source = `#!/bin/sh\n${marker}\nexec ${quote(binary)} "$@"\n`;
  const temporary = `${file}.${process.pid}.next`;
  try {
    await fs.writeFile(temporary, source, {mode:0o755, flag:'wx'});
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, {force:true}); }
  await ensurePath(home, directory, shell);
  return `Installed graff in ${directory}. Open a new terminal to use it.`;
}
module.exports = {installEngine, ensurePath};
