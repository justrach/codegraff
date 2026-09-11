import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import path from 'node:path';
const { installLauncher } = createRequire(import.meta.url)('../electron/cli-launcher.cjs');
const file = await installLauncher(path.resolve(process.argv[2] || '/Applications/Codegraff.app'), homedir());
console.log(`Installed ${file}. Ensure its directory is on your PATH.`);
