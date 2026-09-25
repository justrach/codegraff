# 0201. CLI beta updates require explicit channel selection

Status: accepted 2026-09-25

## Context

Beta releases are prereleases from numeric `release/v…` branches. GitHub's
stable `latest` endpoint excludes them, and release listing order does not
identify the newest branch. The beta CLI archive has no installer.

## Decision

`graff update` stays on the stable channel. `graff update --beta --check`
reports the newest published beta from the numerically newest release branch;
`graff update --beta` installs it for the next launch. The branch version may
have three or four numeric parts. Within that branch, the largest beta run and
attempt wins. No beta on the newest branch is an error, never a fallback to an
older branch.

The updater pins that prerelease tag, downloads the platform CLI archive and
`SHA256SUMS` from it, verifies the archive, and atomically places the binary
only at a supported user install path. It refuses package-managed and app
bundle paths. A stable release at the same numeric version is newer than a
beta. The running process keeps its original binary until the next launch.

## Consequences

Beta discovery reads the branch refs and paginated releases. A missing or malformed feed,
checksum, or asset fails closed. The stable updater and desktop stable feed
remain separate from beta updates.
