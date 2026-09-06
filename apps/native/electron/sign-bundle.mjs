import { sign } from '@electron/osx-sign';
const app = process.argv[2];
if (!app || !process.env.GRAFF_SIGN_IDENTITY) throw Error('Provide an app path and GRAFF_SIGN_IDENTITY.');
await sign({ app, platform: 'darwin', type: 'distribution', identity: process.env.GRAFF_SIGN_IDENTITY,
  preAutoEntitlements: false, preEmbedProvisioningProfile: false,
  optionsForFile(file) {
    const bun = file.endsWith('/Resources/bun');
    const jit = bun || file === app || file.endsWith('.app') || file.includes('/Electron Framework.framework/');
    const entitlements = jit ? ['com.apple.security.cs.allow-jit'] : [];
    if (bun) entitlements.push('com.apple.security.cs.allow-unsigned-executable-memory');
    return { hardenedRuntime: true, entitlements };
  },
});
