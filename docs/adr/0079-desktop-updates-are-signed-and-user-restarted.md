# 0079. Desktop updates are signed and restarted explicitly

Status: accepted

## Decision

The Electron desktop uses electron-updater with the public GitHub stable release
feed. Distribution packaging embeds the feed before signing and produces a ZIP
of the signed, notarized, stapled app with a SHA-512 update manifest. Native
Squirrel.Mac verifies the app signature before replacement. All update assets
must be attached to the draft before the release becomes the latest stable one.

Checks run after startup and every six hours. Users can turn off automatic
downloads or check manually. Background failures remain quiet. Installation
requires the explicit Restart to update action, so a downloaded release cannot
interrupt running tasks or terminals. The normal shutdown path owns backend and
terminal cleanup. Development and smoke builds never use the online feed.

One desktop process owns each profile. A second launch focuses it instead of
starting another server with a different origin and separate UI preferences.

## Validation

Controller tests cover duplicate checks, offline recovery, download rejection,
preferences, development builds and explicit restart. Visual tests exercise
progress, quiet background checks and the restart action without a model.
Distribution validation checks the signed app and DMG; the archive manifest
identifies the exact stapled ZIP bytes.
