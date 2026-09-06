import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';
const require = createRequire(import.meta.url);
const child = spawn(require('electron'), ['electron/visual-tests.cjs'], { stdio: 'inherit', env: { ...process.env, GRAFF_TEST_BUN: process.execPath } });
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', code => { process.exitCode = code ?? 1; });
