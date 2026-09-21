const fs = require('node:fs/promises');
const path = require('node:path');
const marker = '# Codegraff GUI terminal launcher';
const desktopMarker = '# Codegraff GUI desktop entry';
const linuxMarker = 'Codegraff Linux desktop launcher';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

function bundleRoot(exe, platform = process.platform) {
  if (platform === 'darwin') return path.resolve(exe, '../../..');
  return path.dirname(exe);
}

function bundleExecutable(bundle) {
  const candidates = [
    path.join(bundle, 'Contents/MacOS/Codegraff'),
    path.join(bundle, 'codegraff.bin'),
    path.join(bundle, 'Codegraff.exe'),
  ];
  for (const file of candidates) {
    try { if (require('node:fs').statSync(file).isFile()) return file; } catch { /* try the next layout */ }
  }
  return candidates[0];
}

function launchCommand(bundle) {
  const wrapper = path.join(bundle, 'codegraff');
  try {
    if (require('node:fs').readFileSync(wrapper, 'utf8').includes(linuxMarker)) return wrapper;
  } catch { /* macOS bundles have no Linux wrapper */ }
  return bundleExecutable(bundle);
}

function launcherSource(bundle) {
  const binary = launchCommand(bundle);
  return `#!/bin/sh
${marker}
APP_BIN=${quote(binary)}
case "\$1" in
  -h|--help) echo 'Usage: codegraff [folder-or-file]'; echo 'Open the GUI, or open a project there. Files open in their parent folder.'; exit 0 ;;
  --) shift ;;
  -*) echo 'Unknown option. Use codegraff --help, or -- before a path.' >&2; exit 2 ;;
esac
if [ "\$#" -gt 1 ]; then echo 'Expected one folder or file.' >&2; exit 2; fi
if [ ! -x "\$APP_BIN" ]; then echo 'Codegraff app was not found. Reinstall the terminal command from the app.' >&2; exit 1; fi
unset GRAFF_OPEN_PATH GRAFF_CWD
if [ "\$#" -eq 1 ]; then
  case "\$1" in /*) target="\$1" ;; *) target="\$PWD/\$1" ;; esac
  if [ -d "\$target" ]; then
    GRAFF_OPEN_PATH="\$(CDPATH= cd -- "\$target" && pwd -P)" || exit 1
    GRAFF_CWD="\$GRAFF_OPEN_PATH"
  elif [ -f "\$target" ]; then
    GRAFF_CWD="\$(CDPATH= cd -- "\$(dirname "\$target")" && pwd -P)" || exit 1
    GRAFF_OPEN_PATH="\$GRAFF_CWD/\$(basename "\$target")"
  else
    echo "Path does not exist or is not a file or folder: \$1" >&2; exit 1
  fi
  export GRAFF_OPEN_PATH GRAFF_CWD
fi
nohup "\$APP_BIN" </dev/null >/dev/null 2>&1 &
`;
}

async function installDesktopEntry(home, command, bundle) {
  const applications = path.join(home, '.local/share/applications');
  const file = path.join(applications, 'codegraff.desktop');
  try {
    const previous = await fs.readFile(file, 'utf8');
    if (!previous.includes(desktopMarker)) throw Error('An unrelated codegraff desktop entry already exists.');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const icon = path.join(bundle, 'codegraff.png');
  let iconName = 'codegraff';
  try { await fs.access(icon); iconName = icon; } catch { /* theme icon name */ }
  const body = `${desktopMarker}
[Desktop Entry]
Type=Application
Name=Codegraff
Exec="${command.replaceAll('"', '\\"')}" %U
Icon=${iconName}
Terminal=false
Categories=Development;
StartupWMClass=codegraff
`;
  await fs.mkdir(applications, { recursive: true });
  await fs.writeFile(file, body, { mode: 0o644 });
  return file;
}

async function installLauncher(bundle, home) {
  const binary = bundleExecutable(bundle);
  await fs.access(binary, require('node:fs').constants.X_OK);
  const command = launchCommand(bundle);
  if (command !== binary) await fs.access(command, require('node:fs').constants.X_OK);
  const directory = path.join(home, '.local/bin'), file = path.join(directory, 'codegraff');
  await fs.mkdir(directory, { recursive: true });
  try {
    const stat = await fs.lstat(file);
    if (!stat.isFile() || stat.size > 16384) throw Error('An unrelated codegraff command already exists.');
    const previous = await fs.readFile(file, 'utf8');
    if (!previous.includes(marker) && !previous.startsWith('#!/bin/sh\n# Open Codegraff, optionally rooted at a directory or a file\'s parent.')) {
      throw Error('An unrelated codegraff command already exists.');
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = `${file}.${process.pid}.next`;
  try {
    await fs.writeFile(temporary, launcherSource(bundle), { mode: 0o755, flag: 'wx' });
    await fs.rename(temporary, file);
  } finally { await fs.rm(temporary, { force: true }); }
  if (command !== binary) await installDesktopEntry(home, command, bundle);
  return file;
}
module.exports = { launcherSource, installLauncher, bundleRoot, launchCommand };
