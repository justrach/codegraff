const { execFileSync } = require('node:child_process');
const path = require('node:path');

// Node-API entrypoints intentionally use dynamic_lookup. Our Swift bridge
// entrypoints must not: a missing one can become a null call during addon load.
function checkNativeSymbols(directory) {
  const imports = execFileSync('nm', ['-u', path.join(directory, 'activity.node')], { encoding: 'utf8' });
  const exports = execFileSync('nm', ['-gU', path.join(directory, 'libGraffActivity.dylib')], { encoding: 'utf8' });
  const symbols = text => new Set(text.match(/\b_graff_[a-zA-Z0-9_]+\b/g) || []);
  const required = symbols(imports), provided = symbols(exports);
  if (!required.size) throw new Error('Native bridge exposes no graff imports to verify');
  const missing = [...required].filter(symbol => !provided.has(symbol));
  if (missing.length) throw new Error(`Native bridge symbols not exported: ${missing.join(', ')}`);
  // Exercise NAPI_MODULE_INIT in the same Electron runtime used by the app,
  // without opening windows or installing a click callback.
  execFileSync(require('electron'), ['-e', `
    const bridge = require(process.env.GRAFF_NATIVE_ADDON);
    for (const key of ['show', 'computer', 'glass', 'updateNotch', 'hideNotch', 'inspectNotch', 'layoutNotch', 'onNotchClick']) {
      if (typeof bridge[key] !== 'function') throw new Error('Missing native method: ' + key);
    }
  `], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', GRAFF_NATIVE_ADDON: path.resolve(directory, 'activity.node') },
    timeout: 15000, stdio: 'pipe',
  });
  return required.size;
}

if (require.main === module) {
  if (process.argv.length !== 3) throw new Error('Usage: check-native-symbols.cjs <native directory>');
  console.log(`Native bridge exports verified: ${checkNativeSymbols(process.argv[2])}`);
}
module.exports = { checkNativeSymbols };
