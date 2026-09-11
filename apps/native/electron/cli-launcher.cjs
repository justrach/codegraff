const fs = require('node:fs/promises');
const path = require('node:path');
const marker = '# Codegraff GUI terminal launcher';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

function launcherSource(bundle) {
  const binary = path.join(bundle, 'Contents/MacOS/Codegraff');
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

async function installLauncher(bundle, home) {
  await fs.access(path.join(bundle, 'Contents/MacOS/Codegraff'), require('node:fs').constants.X_OK);
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
  return file;
}
module.exports = { launcherSource, installLauncher };
