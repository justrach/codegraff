# Electron desktop trial

Run `./scripts/build_and_run.sh` from the repository root, or use the Codex Run
action. It builds the production UI with Bun, packages Chromium, Bun, graff,
and the SwiftUI Activity sheet, then opens `zig-out/electron/Codegraff.app`.
Builds currently target Apple Silicon macOS 14+; Liquid Glass uses macOS 26+.
Source builds are signed locally for development. The
[packaged desktop download](https://github.com/justrach/codegraff/releases/latest/download/Codegraff-macos-arm64.dmg)
is Developer ID signed and notarized. Open the disk image and drag Codegraff.app onto Applications;
the runtime, engine, browser and native components are included.

The application starts its own loopback server on port 3788 (a free port if
occupied). The stable origin retains local UI preferences; a fallback port has
separate preferences. An old Next
server on port 3000 is irrelevant. Opening the bundle directly uses the home
directory as its initial workspace; the Run action selects this checkout.

Install the shell launcher with **Tools → Install codegraff terminal command…**
in the packaged app, or `bun run install:cli` from `apps/native` for an app in
Applications. Ensure `$HOME/.local/bin` is on your shell's `PATH`.

- `codegraff` opens or activates the GUI.
- `codegraff .` opens the current directory as a project.
- `codegraff "/path/to/project"` selects that project even when the app is running.
- `codegraff "/path/to/file"` selects the parent project and opens the file in Files.

One existing path is accepted; missing paths and unsupported options produce a
terminal error. Existing conversations keep their original folders. The launcher
does not replace the `graff` engine command or unrelated user executables.
An older running app must be upgraded and restarted to support path handoff.

Coding remains in `graff acp`. The browser is a sandboxed `WebContentsView`:
normal typing, selection, scrolling, and navigation use Chromium directly.
Use **Pin element**, click the page, add a note, and **Ask graff**. The pinned
page's authenticated automation endpoint travels with the prompt. Electron
provides no model loop or coding tools of its own.

Blank browser panes and empty chats start no extra browser or coding renderer.
Hidden browser pages suspend after one minute; reopening reloads their URL.
This releases memory but discards unsaved web form state. Closing the browser
releases it immediately. At most three browser views remain live across chats.
The View menu can release every browser page.

**Codegraff → Activity…** (`⌘,`) opens a native SwiftUI sheet showing an on-demand
process-tree sample. macOS 26 uses grouped Liquid Glass surfaces. RSS sums may
double-count shared pages; CPU is the lifetime average from `ps`, not a sampled
instantaneous peak. Closing the application terminates its Bun/ACP process group.

**Settings → Session observer** (or View → Session observer) pins a SwiftUI
notch to the right screen edge while the app is in the background. Off until
you turn it on. Cells are live ACP work, not chat titles. Hover for the
label; click to focus that chat. The panel never becomes the key window.

Run checks with Bun from `apps/native`:

```sh
bun test electron/policy.test.cjs lib/browser/annotations.test.ts
bun x tsc --noEmit
```

After packaging, a real Electron smoke test needs no paid model calls:

```sh
GRAFF_CWD="$PWD" GRAFF_ELECTRON_SMOKE=/tmp/graff-electron-smoke.json \
  zig-out/electron/Codegraff.app/Contents/MacOS/Codegraff
```

The older AppKit shell remains available through
`bash apps/native/desktop/build-app.sh`. Browser permissions are denied by
default in the Electron build.

## Browser passkeys

Touch ID passkeys are optional in Developer ID distributions. Set
`GRAFF_WEBAUTHN_PROFILE` to enable them: the signer validates the macOS profile
for the signing team and actual bundle identifier, then embeds it and adds the
authorized application identifier and keychain group to the main app. It also
writes the group to signed `Contents/Resources/webauthn.json`, which configures
Electron before browser creation. Keep the team and bundle identifier stable
across releases so existing device credentials remain accessible. If the
signing identity is a certificate hash, set `GRAFF_SIGN_TEAM_ID` to its
ten-character Apple team identifier.

Without `GRAFF_WEBAUTHN_PROFILE`, the signer removes any stale embedded profile
and passkey resource and omits their restricted entitlements. The app can still
be signed and notarized, but in-app Touch ID passkeys are unavailable. A
provided profile must authorize the group (a team wildcard is accepted); an
invalid one fails signing rather than falling back to this mode.

On supported Macs, this enables device-bound Touch ID credentials created in
Codegraff's persistent browser partition. It does **not** expose existing iCloud
Keychain passkeys or sync credentials to other devices. Development/ad-hoc builds
without the signing configuration do not enable this authenticator. General
browser permission policy remains deny-by-default.

When a request offers accounts, choose one in the native account dialog; Cancel
rejects the request. Navigation, hiding the tab, and closing the page cancel the
selection. **Tools → Browser passkey help…** explains the limitations and offers
to open the active HTTP(S) page in the default browser, only after an explicit
click. Alternatively use the site's password or another sign-in method. A login
in the default browser does not transfer to the embedded browser.

Verification:

```sh
node --test apps/native/electron/webauthn*.test.cjs
node apps/native/scripts/test-webauthn.mjs
```

The virtual-authenticator regression checks Chromium's real credential and
account-selection dispatch without biometric prompts. It is **not** proof of
Secure Enclave access. Before claiming platform support in a release, validate
the Developer ID-signed app on a supported Mac: verify its signature and matching
keychain group, register a new device-bound credential on a test relying party,
complete Touch ID, quit/reopen and authenticate, select between two accounts,
and cancel a request. Also confirm that an existing iCloud-only credential has a
clear fallback. These hardware checks require a person; do not automate Touch ID
or claim a virtual authenticator verifies it. For a noninteractive availability
check on the signed bundle, run the packaged smoke test with
`GRAFF_SMOKE_LAUNCH_ONLY=1 GRAFF_SMOKE_WEBAUTHN=1`; this checks production startup,
not registration or biometric consent.

## macOS computer use and agent browser tools

**Codegraff → Computer use…** enables or disables laptop control for this launch
and requests macOS Accessibility and Screen Recording permissions. Grant those
to Codegraff in System Settings; a relaunch may be needed. The agent cannot
enable this switch. App snapshots, screenshots and input are requested on demand.
There is no background screen recorder. Native snapshots use expiring element
IDs and actions target an explicit foreground app. Secure fields need user input.

With workspace MCP enabled, graff discovers
`mcp__codegraff_desktop__browser` and `mcp__codegraff_desktop__computer` through the
bundled Bun MCP adapter. This works without a browser pin. The browser tool uses
the embedded page for snapshots, images, form input, selections, hover, keys,
scrolling, navigation, find and zoom. The toolbar also provides find and zoom.
The computer tool discovers running apps, inspects Accessibility trees, activates
apps, presses elements, sets values, clicks, types, sends shortcuts, scrolls and
captures screens. Screen captures include display bounds and image dimensions.

Legacy browser routes return 410. The embedded desktop browser is exposed
through the desktop bridge. Independently configured project/plugin tools are
separate and are not uninstalled.

## Profiler and feedback

The **Performance** menu starts/stops a bounded ten-minute recording, marks a
candidate phase, and exports a JSON feedback report through the native save
panel. Graff can perform the same measurements with
`mcp__codegraff_desktop__profiler`. Reports compare baseline and candidate RSS,
interval CPU, main-loop delays, renderer long tasks, navigation/action durations
and fixed failure categories. CPU can miss children that exit between samples.
Profiling is off by default and samples every two seconds while enabled.

Reports are assembled from an explicit field allowlist. They contain no prompts,
model names, page titles, URLs, file paths, account/session identifiers, raw
exceptions, screenshots or free-form labels. There is no upload endpoint or
automatic transmission. Review the local JSON before attaching it to feedback.

The model picker reads graff's live catalog through a short-lived ACP query
with MCP disabled, without creating a chat session. The selected model,
effort/fast state, supported levels and slash commands come from graff.
`/effort` opens the slider; `/effort high` and `/fast on` execute the harness's
normal persistent commands. Picker adjustments apply quietly, without chat messages,
conversation titles or a model turn. The picker confirms the saved state and
shows failures inline; a prompt waits for an in-flight settings save. The fast toggle appears for supported Codex models;
it is a priority-service request, not a promised speed multiplier.

## Shared review and response delivery

The toolbar's **Changes** panel refreshes every five seconds while open. It
shows staged, unstaged and untracked files, per-file diffs, recent commits and
a worktree selector. All actors editing the same working tree share that view;
uncommitted authorship is not inferred. This is local Git review, not remote
GitHub pull-request synchronization.

ACP clients can call `graff/changes` with `{ "action": "status" }` for Git
porcelain status, branch, worktrees and recent commits, or
`{ "action": "diff", "path": "relative/file", "scope": "all" }`. Scope can
also be `staged` or `unstaged`. Commands are read-only, bounded and run in the
harness workspace. The native GUI's ACP bridge uses one stdout reader and
routes replies by request ID so catalog refreshes cannot steal assistant text.

The macOS window keeps native close/minimize/full-screen controls in a reserved
draggable titlebar. Automated smoke runs stay hidden and non-focusable by default.
Native Activity sheets and OS keyboard/screen checks require explicit
`GRAFF_ELECTRON_FOREGROUND=1`, which can take desktop focus. The report records
skipped native checks. `GRAFF_SMOKE_SKIP_INPUT=1` disables native keyboard input
even when foreground mode is requested. See [visual test modes](VISUAL-TESTS.md).

The v2 profiler adds document LCP/FCP, maximum observed interaction duration,
recording-period layout shift, renderer heap and DOM size, GPU-process CPU/RSS
and allowlisted Chromium acceleration status. Unavailable metrics remain null.
It does not claim GPU utilization, dedicated VRAM, field INP/CLS or a Lighthouse
score. Chromium chooses its supported GPU backend; no forced driver flags or
custom Metal pipeline are needed for the current DOM-based interface.
See [repeatable performance scenarios](VISUAL-TESTS.md) for the model-free runner.

## Linux desktop

`build.sh` on Linux writes an unpacked app at `zig-out/electron/codegraff`, a `.deb`, and an AppImage when `appimagetool` is installed. Launch with `codegraff` in that directory. The window uses system decorations. The terminal helper is a POSIX PTY. macOS activity, Liquid Glass, and computer use stay out of the bundle. The launcher uses the setuid sandbox helper when the deb install sets it, a user namespace when `unshare --user` works, and `--no-sandbox` otherwise so the app still opens.

## Building a distribution disk image

`build.sh` produces a development app with a local signature. For public downloads,
run `distribute.sh` with a Developer ID Application identity and a `notarytool`
keychain profile. Add `GRAFF_WEBAUTHN_PROFILE` only when enabling in-app Touch ID
passkeys (see Browser passkeys above). Bun installs the pinned Electron signing
utility with the other development dependencies.

```sh
GRAFF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
GRAFF_NOTARY_PROFILE="notary-local" \
bash apps/native/electron/distribute.sh zig-out/electron/Codegraff.app zig-out/distribution
```

For a passkey-enabled build, set `GRAFF_WEBAUTHN_PROFILE` to an authorizing
profile when running the same command.

The command signs nested executables, notarizes and staples the app, creates the
Finder drag-to-Applications layout, then signs, notarizes and staples the DMG.
It verifies both artifacts with Gatekeeper and writes a separate DMG checksum.
The output directory must be new. Notarization logs stay there for local review;
only the DMG, checksum, versioned update ZIP and `latest-mac.yml` are release assets.
Never publish a development bundle as the signed download.

## Automatic updates

Signed distribution builds check the public GitHub release feed shortly after
launch and every six hours. Downloads happen in the background. The notification
shows progress and offers **Restart to update**; downloading never stops a task,
and closing the app does not silently install an update. The Codegraff menu has **Check for Updates…** and **Automatically Download Updates**.
The app chrome also has an **Updates** settings panel for the same check and preference.
Development builds, smoke tests and apps running from a mounted disk image do not
check online. Install the app in Applications first.

The updater verifies the archive checksum; macOS Squirrel verifies the application
signature before replacement. The updater receives no conversation or workspace
contents. HTTP requests still disclose ordinary connection information to the
release host. Only stable, newer releases are eligible.

`distribute.sh` adds the feed configuration before signing and creates the update
ZIP after the app has been stapled. To attach all desktop assets together:

```sh
bash apps/native/electron/publish-updates.sh vVERSION zig-out/distribution
```

The release must remain a draft until its CI checks pass and all desktop assets
are attached. Every latest stable release must carry `latest-mac.yml` and its
versioned ZIP alongside the DMG; a CLI-only latest release cannot serve a desktop
update. Publish the complete release atomically. Versions older than the first
updater-enabled release need one manual DMG installation.

The tag workflow also builds this tree on Linux and uploads the unsigned
package next to the CLI tarballs:

```sh
GRAFF_VERSION=VERSION bash apps/native/electron/build.sh
bash apps/native/electron/publish-linux.sh vVERSION zig-out/electron
```

That attaches `Codegraff-linux-amd64.deb` (or `arm64`) and
`Codegraff-linux-<arch>-SHA256SUMS`. An AppImage is included when
`appimagetool` was on `PATH` during the build. There is no notarization step
on Linux; the upload is the unsigned `.deb` `build.sh` wrote. A development
bundle (`GRAFF_DEV=1`) is not a release asset.

## Beta builds

Every push to the newest numeric `release/v...` branch starts the beta workflow.
The prerelease tag includes the branch version, workflow run number and attempt
(for example `v0.0.302.4-beta.20.1`). CI publishes CLI tarballs and an unsigned
Linux desktop package to a GitHub prerelease. The macOS job saves its built
`Codegraff.app` as a short-lived workflow artifact for signing. It is not a
download in the prerelease until a configured Mac signs and notarizes it.
The beta CLI has no `install.sh` asset: download the tarball from its specific
prerelease, since the general installer selects the latest stable release.

On that Mac, download and extract the matching `beta-macos-build` workflow
artifact. With the same signing environment used for stable releases, run:

```sh
GRAFF_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
GRAFF_NOTARY_PROFILE="notary-local" \
bash apps/native/electron/distribute.sh Codegraff.app zig-out/beta-distribution
bash apps/native/electron/publish-beta-macos.sh vVERSION-beta.RUN.ATTEMPT zig-out/beta-distribution
```

The beta DMG receives the same signing, notarization and Gatekeeper checks as
stable releases. Beta apps carry no stable update feed, and beta releases never
become GitHub's stable Latest release. Install a later release manually.
