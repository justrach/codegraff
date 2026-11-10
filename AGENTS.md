# Repository instructions

## Public tracker: bare minimum, no internals, no attribution

This repository is **public**. Issues, pull requests, commits, comments, and edit histories are visible to everyone.

- **Never post internal details.** No private-repo paths or links (website, frontend, gateway, zigrepper), asset/deploy names, infra or performance numbers, session/run ids, trace/transcript excerpts, local paths (`~/…`), quoted user messages, or provider/model/account details. Nothing from `.graff/` traces, sessions, or tool results.
- **Keep issues, PRs, and commits to the bare minimum**: generic symptom, verbatim harness error text, root cause in code terms, and fix. Evidence stays in the conversation.
- **No assistant or model-vendor attribution anywhere** — not in issues, PRs, commit messages, or trailers. No OpenAI/Anthropic/Cursor/session links. Commits use the repository owner's git identity as Author; when graff commits, `Co-Authored-By: Codegraff <blackfloofie@codegraff.com>` is the only allowed trailer (omit if asked).
- **If something sensitive was posted, delete it** (`gh api graphql` `deleteIssue` with the node id from `gh issue view N --json id`); editing leaves edit history visible. Tell the user what was exposed and for how long.

## Issue format: every report states its versions

Open every issue with `graff`, `Harness` (`~/.harness/bin/graff --version`, `Info.plist`), `Surface`, and `Platform`, followed by `Symptom`, `Repro`, `Root cause` (citing a tag or commit like `v0.0.302.25:src/x.zig:93`, never bare line numbers), and `Fix`. Search open/closed issues first, verify against the latest release, and never put model/provider/account details in headers. Full template and version commands: [docs/contributing-checks.md](docs/contributing-checks.md).

## Keychain: never dump it

Never run `security dump-keychain` (with or without `-d`) or walk every keychain item — macOS pops an unlock dialog per secret. Check one named notary profile with `security find-generic-password -l <profile-name>` or read the release scripts. Do not `pkill` `security`/`securityd`.

## Imported conversations continue in graff

A conversation imported from another agent (Claude Code, Codex, etc.) continues in a graff session on graff's configured provider. The source transcript is read-only input: never re-launch or `--resume` the source agent, and never spend its subscription or credits ( across REPL, ACP, and Harness).

## Decisions live in docs/adr/

Read [docs/adr/README.md](docs/adr/README.md) before changing behavior an ADR covers (e.g., ADR 0001 on structured outputs). Add an ADR in the same branch when settling a new load-bearing decision.

## Terminal UI & separate TUI

- **Colors, bold/dim, glyphs, layout are ours** (`src/ansi.zig`, Codegraff Dark palette: amber `#e8a33d`, cream text, warm neutrals; coral/red for errors only).
- **Fonts and HDR/wide-gamut are the terminal emulator's**, not ours: never emit `OSC 50` (point users to their terminal config, e.g. `font-family = Geist Mono`), and pick 8-bit sRGB colors that read cleanly on both P3 and sRGB displays.
- **Fullscreen TUI is separate**: `graff tui` launches an installed `graff-tui` (beside `graff`, then `PATH`) and never downloads one. Keep TUI rendering tests there; this repo owns the engine, line REPL, ACP protocol, and launcher boundary.

## File size

- Keep every hand-written source file at or below **600 lines of code**.
- Split cohesive responsibilities into focused sibling modules in the same change before crossing 600 LOC; if a touched file is already over 600 LOC, do not grow it.
- Generated files, vendored dependencies, lockfiles, and machine-produced artifacts are exempt (change their generator instead).

## Engine features are the same on REPL and ACP

Messaging (`peer_message`, idle peer mail, Accord live wake) and engine behavior (turns, tools, compaction, goals, workspace/worktree cwd handoffs) must work identically on the line REPL and ACP clients (`graff acp` / Harness / `graff-tui`). Wire wakes, latches, delivery rules, and workspace behavior through both paths in the same change.

## nanocua: this repo holds the original

`apps/nanocua` is graff's macOS computer-use package (ADR 0314) with its own `zig build test`. Edit it here and sync via `scripts/vendor-nanocua.sh`, never the reverse.

## Running & reaching tests

- During edits, run targeted unit tests: `zig build unit -Dtest-filter="<name>"` (repeatable). Run `zig build test` before pushing.
- **Tests must be reachable**: every new test-bearing module must be referenced in `src/main.zig`'s `test {}` block (`_ = @import("your_module.zig");`). Verify the suite total increases and `scripts/eval-tier1.sh --only reach` passes.

## Merging pull requests & release branch beta versions

- **Merging onto a release branch**: when asked to merge open PRs onto a `release/v…` branch, merge **only** onto that release branch — never `main` unless explicitly asked. Do not use `gh pr merge` when the PR targets `main`; cherry-pick or merge the PR head into `release/v…`.
- **Beta versions**: the newest numeric `release/vX.Y.Z` or `release/vX.Y.Z.W` branch (comparing numeric components, missing 4th = 0) builds `v<branch-version>-beta.<workflow-run>.<attempt>` GitHub prereleases and must never move the stable `latest` pointer. Queued builds must recheck remote branch and commit so older branches or superseded commits never replace the latest beta.

## Before you push (Tier 1) & Tier 2 behavior evals

Install hooks once with `scripts/install-hooks.sh` (`.githooks/pre-push` runs `scripts/eval-tier1.sh`; use `--only fmt,reach,sdk` for fast local checks — full command list in [docs/contributing-checks.md](docs/contributing-checks.md)). Two rules easy to trip:

- **Suite count ratchet (`scripts/eval/tier1-manifest.json`)**: the unit test count may grow and never shrink without an explicit `test_count_baseline` update + commit rationale; bump the floor at release cuts (`test_count_slack` is 25).
- **Generated SDKs**: run `python3 sdk/generate.py --harness ./zig-out/bin/graff` after changing the model catalog, tool schemas, or provider list, and commit the result.
- **Tier 2 (`python3 scripts/eval-tier2.py`)**: scripted offline model-backed regressions in `evals/harness_behavior.jsonl`. Add a case when fixing a harness behavior bug.
