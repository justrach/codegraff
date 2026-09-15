// Never allow this offline regression to display windows or activate the app.
process.env.GRAFF_ELECTRON_FOREGROUND = '0';
process.env.GRAFF_TEST_FOREGROUND = '0';
process.env.GRAFF_ELECTRON_VISIBLE = '0';
const { mkdtemp, rm } = await import('node:fs/promises');
const { tmpdir } = await import('node:os');
const { join } = await import('node:path');
const { runElectron } = await import('./test-electron.mjs');
const profile = await mkdtemp(join(tmpdir(), 'graff-webauthn-'));
try { await runElectron('electron/webauthn-integration.cjs', [profile]); }
finally { await rm(profile, { recursive: true, force: true }); }
