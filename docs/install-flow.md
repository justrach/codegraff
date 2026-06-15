# Install flow — diagnosis & fix

Working notes for the `curl | sh` install path. Branch: `fix/install-flow`.

## Symptom

User runs the one-liner (`curl -fsSL https://codegraff.com/install-graff.sh | sh`)
and sees:

```
install: /var/folders/.../graff-aarch64-macos/graff: No such file or directory
  | download  ok (prebuilt release)
  | install   ok
  installed -> /Users/<u>/bin/graff
  | graff            <- cursor sits here forever
```

i.e. an `install: No such file` error, a *false* "ok", and then a hang.
It "worked before", so something changed — `install.sh` itself did **not**
(byte-identical on `main`, the GUI branch, and the published release asset).

## How the install actually works

`curl | sh` runs `install.sh` -> `main()`, top to bottom:

1. **`fetch_release`** — download the single `graff` tarball from GitHub
   Releases, extract, drop the binary at `~/bin/graff`. **The only step that
   makes graff work.** Falls back to a Zig **source build** on failure or
   `HARNESS_BUILD=source`.
2. Symlink `harness -> graff` (back-compat).
3. **Companion suite** step — installs muonry + zigrep tools + codedb.
4. **kuri** step (opt-in).
5. PATH check, done.

Only step 1 is required; the harness "works fine without it, premium paths just
stay dormant."

## The URLs (how hosting fits together — all live)

zigrepper's Next.js frontend (deployed to codegraff.com) owns these routes:

| URL | Route file | Serves |
| --- | --- | --- |
| `codegraff.com/install-graff.sh` | `app/install-graff.sh/route.ts` | proxies `github.com/justrach/codegraff/releases/latest/download/install.sh` = **the harness installer** (correct: this is the public "install graff" one-liner) |
| `codegraff.com/install.sh` | `app/install.sh/route.ts` | **the companion/tools installer** (inline script: 8 zig tools + muonry + codedb, `BASE_URL=codegraff.com/v`) |
| `codegraff.com/v/latest.json` | `app/v/[...path]/route.ts` | `{"version":"0.2.8"}` |
| `codegraff.com/v/v<ver>/<tool>-<platform>` | same | the tool binaries (verified: muonry-darwin-arm64 -> 200, 2.3 MB) |

All live and healthy. (Earlier I tested `get.codegraff.com/*` and saw 500/404 —
that's a *different/stale* host; the real infra is `codegraff.com` + `/v`.)

## Root causes

### 1. Tarball layout mismatch -> `No such file` + false success
`fetch_release` assumed `graff-<target>/graff` inside the tarball. CI
(`release.yml`) packs it that way, but the **live macOS asset is flat**
(`graff`/`README.md`/`LICENSE` at the root) because the macOS tarballs are
repacked by hand in the local sign+notarize flow (CI has no mac signing
target). So `install` failed. And because `fetch_release` runs inside
`if ... fetch_release`, **`set -e` is suppressed** and it returned its last
command's status (`rm -rf` -> 0) — printing `download ok / install ok`, never
falling back to source, leaving `~/bin/graff` unwritten -> `command not found`.

### 2. Companion step called the wrong URL -> recursion / hang
The companion step ran `curl codegraff.com/install-graff.sh | sh`. But
`install-graff.sh` proxies the **harness** release installer — so it reinstalled
the harness, hit the same companion step, curled itself again -> infinite
recursion. The `command -v muonry && zigpatch` guard never trips because the
harness installer never installs those. **The companion installer is a
different route: `codegraff.com/install.sh`** (the tools installer). One wrong
URL was the entire hang.

## Fix applied here (`install.sh`)

1. **Robust binary location + fail-closed** in `fetch_release`: handle flat
   *and* nested layouts, fall back to `find`, and `return 1` if the binary
   didn't land so it falls through to a source build instead of lying.
2. **Companion URL corrected** to `codegraff.com/install.sh` (the tools
   installer) instead of the self-recursing `install-graff.sh`. Kept **default
   ON / opt-out** via `HARNESS_NO_GRAFF=1` (product decision — restores prior
   behavior), overridable via `GRAFF_SUITE_URL`, and now bounded by
   `curl --max-time 120` so a slow network can never freeze the install.

Verified: plain install lands a working `graff` in seconds; the companion step
detects already-present tools and skips, or installs from the live endpoint, and
never recurses/hangs.

## Still TODO (other repos / nice-to-have)

- **zigrepper `install.sh` / the `codegraff.com/install.sh` route** — the 9
  tools download in a sequential `for` loop; parallelize (background curls +
  `wait`) so the companion step is seconds, not ~a minute on a fresh machine.
  This is the "make it parallel" piece — it lives in zigrepper, not here.
- **Release packaging** — make the hand-repacked macOS tarball nest like CI (or
  let CI own the mac sign+notarize) so the flat/nested split stops recurring.
  The script now tolerates both, but artifacts should be consistent.
- **(optional UX)** the companion `curl | sh` is silenced (`>/dev/null 2>&1`),
  so on a fresh machine it looks idle while ~20 MB downloads. Once the downloads
  are parallel this is a few seconds; otherwise consider a progress hint.
