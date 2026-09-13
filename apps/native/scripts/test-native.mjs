import { runBounded } from './process-deadline.mjs';
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { runElectron } from './test-electron.mjs';
const require = createRequire(import.meta.url);
const { testWindowMode } = require('../electron/test-window.cjs');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const buildOnly = process.argv.length === 3 && process.argv[2] === '--build-only';
if (process.argv.length > (buildOnly ? 3 : 2)) throw Error('Usage: test-native.mjs [--build-only]');
if (!buildOnly && testWindowMode() !== 'foreground') {
  throw Error('Native GUI tests require GRAFF_ELECTRON_FOREGROUND=1. Run them on an isolated CI desktop; --build-only does not launch windows.');
}
if (process.platform !== 'darwin') throw Error('Native GUI tests require macOS.');
const resources = path.resolve(process.env.GRAFF_NATIVE_TEST_RESOURCES || path.join(root, '../../zig-out/native-tests/build'));
const native = path.join(resources, 'native');
mkdirSync(native, { recursive: true });
const run = async (command, args) => {
  const result = await runBounded(command, args, { cwd: root, stdio: 'inherit' }, { timeoutMs: 120000 });
  if (result.code !== 0 || result.timedOut) throw Error(`${command} ${result.timedOut ? 'timed out' : `exited ${result.code}`}`);
};
const target = `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`;
await run('xcrun', ['swiftc', '-O', '-emit-library', '-module-name', 'GraffActivity', '-target', target,
  'electron/native/Activity.swift', 'electron/native/ComputerUse.swift', '-o', path.join(native, 'libGraffActivity.dylib'),
  '-Xlinker', '-install_name', '-Xlinker', '@rpath/libGraffActivity.dylib']);
const common = ['clang', '-O2', '-bundle', '-undefined', 'dynamic_lookup', '-mmacosx-version-min=14.0',
  '-I', path.join(root, 'node_modules/node-api-headers/include')];
await run('xcrun', [...common, 'electron/native/activity.c', '-L', native, '-lGraffActivity',
  '-Wl,-rpath,@loader_path', '-o', path.join(native, 'activity.node')]);
await run('xcrun', [...common, '-fobjc-arc', '-framework', 'AppKit', 'electron/native/test-window-probe.m',
  '-o', path.join(native, 'test-window-probe.node')]);
if (buildOnly) console.log('Native test bridge compiled. No GUI was launched.');
else await runElectron('electron/native-gui.cjs', [resources]);
