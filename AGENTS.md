# Repository instructions

## Public tracker: bare minimum, no internals, no attribution

This repository is **public**. Issues, pull requests, commits, comments, and
their edit histories are visible to everyone.

- **Never post internal details.** No private-repo paths or links (website,
  frontend, gateway, zigrepper), no asset or deploy names, no infrastructure or
  performance numbers, no session/run ids, no trace or transcript excerpts, no
  local paths (`~/…`), no quoted user messages, no provider/model/account
  details. Nothing from `.graff/` traces, sessions, or tool results.
- **An issue is the bare minimum**: a generic symptom, the harness's own error
  text, the root cause in code terms, and the fix. Evidence stays in the
  conversation, not the tracker. Same for PR bodies and commit messages.
- **No assistant or model-vendor attribution anywhere** — not in issues, PRs,
  commit messages, or trailers. No OpenAI/Anthropic/Cursor/session links. Commits
  still use the repository owner's git identity as Author. When graff makes the
  commit, `Co-Authored-By: Codegraff <blackfloofie@codegraff.com>` is allowed
  (and is the only allowed trailer). Omit it if the user says not to.
- **If something sensitive was already posted, delete it** (`gh api graphql`
  `deleteIssue` with the node id from `gh issue view N --json id`); editing is
  not enough because edit history stays visible. Then tell the user what was
  exposed and for how long.

## Issue format: every report states its versions

Every issue, whether a person or an agent files it, opens with this header.
A report without versions can't be told apart from a bug that a newer release
already fixed.

```markdown
**graff:** 0.0.302.25 (latest: 0.0.302.25)
**Harness:** 0.2.109, or "not used"
**Surface:** Harness | terminal | `graff -p` | ACP client | SDK
**Platform:** macOS arm64 | Linux x64 | Windows x64 | ...

## Symptom
What went wrong, in generic terms, with the tool's own error text verbatim.

## Repro
The smallest sequence of steps that shows it.

## Root cause
In code terms (`file.zig::function`), naming the tag or commit the line
numbers come from. Leave this section out if the cause isn't known.

## Fix
The expected behavior, or the proposed change.
```

- **graff:** run the binary that hit the bug. Harness runs its managed copy,
  not the `graff` on `PATH`: `~/.harness/bin/graff --version` (macOS and
  Linux). For the latest release, run
  `gh release view --repo justrach/codegraff --json tagName`.
- **Harness:** on macOS, run
  `plutil -extract CFBundleShortVersionString raw /Applications/Harness.app/Contents/Info.plist`.
- **If the graff that failed is older than the latest release**, check
  whether the release notes or a closed issue already cover the bug. Reproduce
  it on the latest release before filing, or say plainly in the header that it
  wasn't rechecked.
- **Cite source from a named version.** If a report cites code from a local
  checkout that isn't the running version, it describes code that may already
  have changed. Use `v0.0.302.25:src/x.zig:93` (or a commit hash), never a bare
  line number.
- **Search before filing.** Search open and closed issues by the error text.
  Comment on an existing issue only when you have a new repro or diagnostic.
- **What the header must not contain:** model or provider names, account
  details, or paths. The public-tracker rules above still apply.

## Keychain: never dump it

Never run `security dump-keychain` (with or without `-d`), and never walk every
keychain item. macOS pops an unlock dialog per secret and floods the desktop.
To check one named notary profile, use
`security find-generic-password -l <profile-name>` or read the documented
default from the release scripts. Do not `pkill` `security`/`securityd`.

## Imported conversations continue in graff

A conversation brought in from another agent (Claude Code, Codex, or any other)
continues in a graff session, on graff's configured provider (for example
Codegraff). The source agent's transcript is read-only input. Never re-launch or
`--resume` the source agent to continue it, and never spend that agent's
subscription or credits. This applies in the REPL, over ACP, and in Harness.

## Decisions live in docs/adr/

Settled, evidence-backed decisions are recorded as ADRs. Read the one-line
index in [docs/adr/README.md](docs/adr/README.md) before changing behavior a
record covers; what looks like an easy improvement may be a measured
regression (see ADR 0001 on structured outputs). When your change settles a
new load-bearing decision, add a record in the same branch.

## Terminal UI: what's ours to change

- **Colors, bold/dim, glyphs, layout are ours.** Styling travels in the output byte stream as SGR escape sequences, so the app controls it per character. The palette lives in `src/ansi.zig` (the line REPL follows Harness's Codegraff Dark theme: amber `#e8a33d`, cream text, and warm neutrals; coral/red hues are reserved for errors).
- **The font is not ours.** The terminal emulator owns the typeface — it loads the font, measures the cell grid, and rasterizes glyphs itself; the wire protocol has no sequence for an app to request a font. (xterm's legacy `OSC 50` is unimplemented by modern emulators and would hijack the user's whole terminal — do not emit it.) If a user asks to "change the REPL font," the answer is their terminal's config, e.g. `font-family = Geist Mono` (the site's typeface) in Ghostty — never a code change here.
- **HDR/wide-gamut color is not ours either.** Truecolor SGR is 8-bit sRGB per channel — the protocol's ceiling; no sequence expresses Display P3 or EDR headroom, and macOS terminals clip app colors to SDR regardless of the panel. Pick values that look right on both P3 and sRGB displays (as `#059669` does); that's the whole lever.

## Separate terminal UI

The fullscreen terminal UI is maintained separately. `graff tui` launches an
installed `graff-tui` executable (beside graff first, then on `PATH`); it does
not download one. Keep UI rendering tests in that project. This repository
owns the engine, line REPL, ACP protocol, and external-launcher boundary.

## File size

- Keep every hand-written source file at or below 600 lines of code.
- When a change would push a file past 600 LOC, split cohesive responsibilities into focused sibling modules as part of the same change.
- If a touched file is already over 600 LOC, do not grow it; move it toward the limit before adding more behavior.
- Generated files, vendored dependencies, lockfiles, and machine-produced artifacts are exempt; change their generator or source instead of hand-editing them.

## Engine features are the same on REPL and ACP

Messaging (`peer_message`, idle peer mail, Accord live wake) and other
engine-side behavior (turns, tools, compaction, goals) must work the same on
the line REPL and ACP clients such as Harness (`graff acp`) and the separate
terminal UI. Surface
chrome can differ; the engine path cannot. If you add a wake, a latch, or a
delivery rule, wire it through the REPL and ACP engine paths in the same change.

The desktop app is Harness, which lives in its own repository and drives
graff over ACP. A new-chat folder rule, a worktree handoff, or a session cwd
that exists only in a client is not done — wire the same behavior through the ACP session in the same
change. The workspace the agent runs in is not chrome.

## Running tests

- While you work, run only what you touched: `zig build unit -Dtest-filter="<part of a test name>"` builds and runs just the unit tests (repeat the flag for several names).
- `zig build test` also runs the subprocess integration scripts and takes several minutes. Run it once before you push; the pre-push hook does.

## Tests must be reachable

- `zig build test` only runs the tests in files the test root pulls in. A new module's `test {}` blocks compile to nothing until something references it, and the suite still reports green.
- A new test-bearing module needs a reference in `src/main.zig`'s `test {}` block: `_ = @import("your_module.zig");`.
- Prove it with the count, not with hope: the suite total must go up by the number of tests you added. `scripts/eval-tier1.sh --only reach` fails on any file that declares tests nothing imports.

## Merging pull requests

If asked to merge open PRs onto the **release branch**, merge **only** that branch. Do not merge them into `main` unless that was explicitly asked.

`gh pr merge` uses the PR's base, which is usually `main`. That is not landing on `release/v…`. Cherry-pick or merge the PR head into the named release branch instead.

## Release branch beta versions

The newest numeric `release/vX.Y.Z` or `release/vX.Y.Z.W` branch is the beta
source. Compare numeric components, treating a missing fourth component as
zero; do not use lexical branch order or assume releases always have three
components. Every push to the current branch builds a unique
`v<branch-version>-beta.<workflow-run>.<attempt>` prerelease from that exact
commit. A queued build must recheck the remote branch and commit before it
publishes. Older release branches and superseded commits cannot replace the
latest beta.

Beta releases are GitHub prereleases and must explicitly remain outside the
stable `latest` pointer. The stable tag workflow is restricted to numeric
stable tags. The beta CLI release has no installer; download the versioned
tarball from the specific prerelease.

## Before you push

Install the tracked hooks once, and the checks run themselves:

```bash
scripts/install-hooks.sh
```

That points `core.hooksPath` at `.githooks/`, whose `pre-push` runs **tier 1** of the internal eval set: `zig fmt`, the 600-line ceiling, test reachability, `zig build`, the unit suite plus a count that may grow and never shrink, the named goal/loop/todo invariants, SDK drift, plus the terminal regression checks. It is deterministic and offline (no provider calls, no network, no spend). A warm `fmt`/`reach`/`sdk` subset is seconds; a post-`src` change rebuilds zig and runs the PTY probes, which is minutes (see #641). Prefer `scripts/eval-tier1.sh --only <check>` for a local edit. A push that only touches docs skips it.

```bash
scripts/eval-tier1.sh                 # run it by hand
scripts/eval-tier1.sh --only sdk      # rerun one check
scripts/eval-tier1.sh --only fmt,reach  # a comma-separated list (#641)
scripts/eval-tier1.sh --list          # the check names
git push --no-verify                  # emergency skip (GRAFF_SKIP_PREPUSH=1 also works)
```

Failures name the invariant, say which regression it guards, and print the command that reruns only that check. The required invariants and the docs-only path list are data in `scripts/eval/tier1-manifest.json`.

Two rules the hook enforces that are easy to trip:

- **The suite count is a ratchet.** If it drops, either restore the tests or lower `test_count_baseline` in the manifest in the same commit, with a reason in the message. Nothing raises it for you: bump it at each release cut, and tier 1 warns once the real suite has run more than `test_count_slack` (25) tests ahead of the floor, because a floor that far behind would not notice a whole module falling out of the test root.
- **The SDKs are generated, not written.** Run `python3 sdk/generate.py --harness ./zig-out/bin/graff` after any change to the model catalog, tool schemas, or provider list, and commit the result.

## Tier 2: model-backed behavior

Behavior regressions do not show up in a unit suite. **Tier 2** runs the harness for real, so it is opt-in and never in the hook. Cases are data in `evals/harness_behavior.jsonl`, one line each, carrying the regression it guards. The model is scripted (`scripts/eval/mock_model.py`), so the default run is offline and free.

```bash
python3 scripts/eval-tier2.py                 # every case
python3 scripts/eval-tier2.py --list          # the cases and what they guard
python3 scripts/eval-tier2.py --only <id>
python3 scripts/eval-tier2.py --dump <id>     # every event and request from one case
```

Add a case when you fix a behavior bug: script the model replies that provoke it, then assert on the events the harness emitted or on what it sent back to the model. Run it against a real provider with `--provider`/`--model` when you care how the model behaves rather than how the harness does.
