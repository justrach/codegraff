import { sign } from '@electron/osx-sign';
import { signBundle } from './webauthn-signing.cjs';

await signBundle({
  app: process.argv[2],
  identity: process.env.GRAFF_SIGN_IDENTITY,
  teamId: process.env.GRAFF_SIGN_TEAM_ID,
  profilePath: process.env.GRAFF_WEBAUTHN_PROFILE,
  sign,
});
