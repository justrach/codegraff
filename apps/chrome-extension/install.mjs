import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const id = process.argv[2];
if (!/^[a-p]{32}$/.test(id || '')) throw new Error('Usage: node install.mjs <Chrome extension ID>');
if (!['darwin', 'linux'].includes(process.platform)) throw new Error('This initial bridge supports macOS and Linux');
const home = os.homedir();
const directory = path.join(home, '.graff', 'chrome');
fs.mkdirSync(directory, {recursive: true, mode: 0o700});
const bridge = fileURLToPath(new URL('bridge.mjs', import.meta.url));
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";
const launcher = path.join(directory, 'native-host');
fs.writeFileSync(launcher, `#!/bin/sh\nexec ${quote(process.execPath)} ${quote(bridge)} --native "$@"\n`, {mode: 0o700});
const manifests = process.platform === 'darwin'
  ? path.join(home, 'Library/Application Support/Google/Chrome/NativeMessagingHosts')
  : path.join(home, '.config/google-chrome/NativeMessagingHosts');
fs.mkdirSync(manifests, {recursive: true});
fs.writeFileSync(path.join(manifests, 'dev.codegraff.chrome.json'), JSON.stringify({
  name: 'dev.codegraff.chrome', description: 'Graff explicitly connected tabs',
  path: launcher, type: 'stdio', allowed_origins: [`chrome-extension://${id}/`],
}, null, 2));
console.log('Native host installed. Add this server to Graff MCP settings:');
console.log(JSON.stringify({mcpServers: {'graff-chrome': {command: process.execPath, args: [bridge]}}}, null, 2));
