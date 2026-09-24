# 0132. Desktop passkeys use signed device credentials

Status: accepted

## Context

The embedded browser did not configure Electron's macOS WebAuthn authenticator.
Platform requests therefore had no Touch ID integration, and signing supplied
no credential keychain group. The pinned Electron API supports Secure Enclave
credentials, not access to existing iCloud Keychain passkeys. Configuring it is
not sufficient evidence that every stalled sign-in is fixed.

## Decision

When an authorizing profile is supplied, the distribution signer derives one
credential group from the signing team and actual bundle identifier, puts it in
the main application's keychain entitlement, and writes the identical value to
a signed resource. Startup configures Touch ID from that resource before browser
creation. Builds without it leave the authenticator disabled.

The profile is optional for general Developer ID signing and notarization. If
supplied, the signer strictly validates and embeds it, and includes its
authorized application identifier in the main app's entitlements. If omitted,
the signer omits the profile-gated entitlements and removes any stale embedded
profile and signed passkey resource from the copied bundle. Supplying a keychain
entitlement alone can pass `codesign --verify` while macOS refuses launch for
lack of a matching profile; the build must not mistake signature integrity for
authorization. An invalid supplied profile is an error, not a reason to fall
back to a profile-free build.

The persistent browser session handles account selection through a parented
native dialog. Only the visible owned browser page can prompt; cancellation,
navigation, hiding, and destruction fail closed. No credential is silently chosen.
The existing sandbox and general permission denial remain unchanged.

An explicit Tools menu action explains device-bound credentials and offers to
open the active web page in the default browser. It never automatically forwards
a failed authentication request or implies that external login transfers a
session back to Codegraff. We do not enable a different provider API or claim
third-party iCloud credentials are accessible.

## Consequences

For passkey-enabled builds, signing team, bundle identifier, and browser
partition must remain stable to retain credential access. Profile-free builds
cannot use in-app Touch ID passkeys; unsupported credentials still need another
sign-in method. Automated virtual-authenticator checks establish request
dispatch and selection behavior, not biometric or keychain access. Passkey
release support requires registration, persistence, authentication, and
cancellation validation in the Developer ID-signed application on supported
hardware.
