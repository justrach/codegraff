# Issue Format & Evaluation Reference

Detailed templates and command references linked from [AGENTS.md](../AGENTS.md).

## Issue report template

Every issue, whether filed by a person or an agent, opens with this version header (`Surface: Harness` means graff misbehaved under the app; see [Which repository](#which-repository) for the app's own bugs):

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

Version lookup commands:
- **graff:** run the binary that hit the bug (`~/.harness/bin/graff --version` for Harness's managed copy). Latest release: `gh release view --repo justrach/codegraff --json tagName`.
- **Harness (macOS):** `plutil -extract CFBundleShortVersionString raw /Applications/Harness.app/Contents/Info.plist`.
- If the binary is older than the latest release, check release notes and closed issues first, and reproduce on the latest release (or state in the header that it was not rechecked).
- Cite source from a named version (`v0.0.302.25:src/x.zig:93` or commit hash), never a bare line number.
- Search open and closed issues by error text before filing; never include model/provider names, account details, or private paths.

## Which repository

This repository is graff; the Harness app is `justrach/nanoharness`, whose `harness-engine` is not "the engine" here. File nothing new in `justrach/harness` (the previous desktop client), or here about the desktop GUI and iOS client that used to live here.

1. Reproduce with `graff acp`, `graff -p` or the terminal. Wrong there: here. Right there, but the app shows, launches or stores it wrongly: `justrach/nanoharness`.
2. For an ACP problem, read the frames graff wrote. A missing or wrong update, method or `_meta`: here. A right frame shown wrongly: the app.
3. If both sides must change, file the primary issue where the wrong behavior starts and link a counterpart in the other.
4. Move a misfiled issue with `gh issue transfer <n> <owner/repo>`, not by re-filing, so its author and history stay.

Examples:

- **A turn still shows as working.** graff ends a turn by answering `session/prompt` with a `stopReason` (`end_turn`, `cancelled`, `max_turn_requests`; `src/acp_engine.zig`). No answer: here. Answered and still spinning: the app.
- **A model is missing from the picker.** Look for its row in the `graff/models` reply (`src/acp_models_rpc.zig`). Missing, or `authenticated` wrong for this install: here. Present but not offered: the app.
- **Edits land in an unexpected folder.** Read `_meta["graff/worktree"]` and `_meta["graff/cwd"]` in the `session/new` or `session/load` reply and any `session_info_update` (`src/acp_workspace.zig`). Wrong tree or cwd: here. Right tree, the app opens another: the app.
- **The context meter is wrong.** Compare `used` and `size` in graff's `usage_update` (`src/acp_context_meter.zig`). Wrong numbers: here. Right numbers drawn wrong: the app.

## Tier 1 & Tier 2 commands

Install tracked git hooks once:

```bash
scripts/install-hooks.sh
```

Run Tier 1 checks (`zig fmt`, 600-line ceiling, test reachability, `zig build`, unit suite + count ratchet, named goal/loop/todo invariants, SDK drift, PTY terminal checks; manifest in `scripts/eval/tier1-manifest.json`):

```bash
scripts/eval-tier1.sh                   # full deterministic offline suite
scripts/eval-tier1.sh --only sdk        # single check
scripts/eval-tier1.sh --only fmt,reach  # comma-separated subset
scripts/eval-tier1.sh --list            # list check names
git push --no-verify                    # emergency skip (or GRAFF_SKIP_PREPUSH=1)
```

Run Tier 2 scripted/model-backed behavior checks (`evals/harness_behavior.jsonl` + `scripts/eval/mock_model.py`):

```bash
python3 scripts/eval-tier2.py           # every scripted case (offline, free)
python3 scripts/eval-tier2.py --list    # list cases and guarded regressions
python3 scripts/eval-tier2.py --only <id>
python3 scripts/eval-tier2.py --dump <id>
```
