# 0194. Separate desktop release follows CLI publication

Status: accepted 2026-09-24

## Context

The new desktop client has its own source repository, app identity, and update
feed. Codegraff's existing desktop updater installs `com.codegraff.app` from
the Codegraff stable release. It cannot replace that app with a differently
identified client. The CLI release workflows already distinguish current
release-branch betas from stable tags, and a stable release starts as a draft
until its notarized desktop assets have been attached.

## Decision

Codegraff owns the CLI build and its immutable beta or stable release. The
separate desktop repository owns GUI builds, signing, updater manifests, and
installation of the bundled `graff` command on PATH. The repositories stay
separate; the desktop build pins a particular published Codegraff release.

After publishing a beta prerelease from the newest numeric release branch,
Codegraff rechecks the remote branch head and sends the beta tag, source commit,
and branch to the desktop repository. After a stable release is published,
Codegraff verifies the released CLI checksum, disk image checksum, app
signature, and notarization tickets before sending its stable tag and commit.
Both notifications use `repository_dispatch` when a scoped
`HARNESS_SYNC_TOKEN` is configured. The desktop repository also polls the
published releases, so a missing token or lost notification does not prevent
eventual synchronization. It independently validates the release and current
branch before packaging. Beta builds never enter the stable desktop updater
feed; stable desktop updates follow signed desktop releases.

`HARNESS_SYNC_TOKEN` is a repository secret in Codegraff holding a fine-grained
token with Contents write permission on the desktop repository. Its absence is
logged as a skipped immediate notification; it does not masquerade as a
successful push to that repository.

## Consequences

The two apps need a one-time user installation handoff. An existing
`Codegraff.app` updater cannot silently migrate a user to the other bundle ID
or its update feed. Public download guidance should switch only after a signed
desktop release exists and the handoff instructions are ready. A dispatch is a
build request, not evidence that the desktop package was published; its own
signing and release checks remain authoritative.
