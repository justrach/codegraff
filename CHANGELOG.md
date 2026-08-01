# Changelog

Notable changes per release, newest first. Some releases also have longer
narrative notes under [docs/releases/](docs/releases/), `graff --version`
prints a short what's-new, and the
[releases page](https://github.com/justrach/codegraff/releases) has the full
commit history for every tag.

The release workflow uses a tag's section here as its release notes (a
hand-written `docs/releases/<tag>.md` wins if present), so keeping this file
current is part of cutting a release.

## v0.0.231 (2026-08-01)

- `edit_file` now verifies every edit actually landed on disk before reporting
  success: a silent no-op becomes a loud tool error instead of a false
  "replaced 1 occurrence(s)" (#337, #338).
- Batched edits to the same file are serialized per path, fixing a race where
  parallel tool calls could erase each other's writes (#338).
- Embedder mode part 1: a hard `--no-local-tools` / `GRAFF_NO_LOCAL_TOOLS=1`
  gate disables local bash/file/codedb tools for the whole process, subagents
  included, so coding tools can come from a sandbox MCP server instead (#330,
  #335).
- Embedder mode part 2: resumable `graff serve` streams with monotonic `seq`
  ids, `?from=N` replay after a dropped connection, and durable sessions.
  `--json` schema 0.10 (#330, #336).
- Longer notes: [docs/releases/v0.0.231.md](docs/releases/v0.0.231.md).

## v0.0.230 (2026-08-01)

- The bundled `skill-creator` skill teaches the full authoring loop: capture
  intent from the live conversation, write trigger-rich descriptions,
  forward-test with fresh subagents against baseline runs, and iterate on user
  feedback until it comes back empty (#334).

## v0.0.229 (2026-07-31)

- SKILL.md skills: drop a markdown playbook in `.harness/skills/<name>/` (or
  `~/.harness/skills/` for every project) and graff loads it only when a task
  calls for it. Only name + description enter the system prompt;
  `.claude/skills/` is read for compatibility; `/skills` lists, hides, and
  restores them. Ships with `skill-creator` and `mcp-config` built in (#333).
  See [docs/skills.md](docs/skills.md).

## v0.0.228 (2026-07-31)

- Local learning defaults corrected to the documented privacy posture, with
  the full write-up in [docs/learning-privacy.md](docs/learning-privacy.md)
  (#332).
- Test-dispatch fixes: modules whose tests were silently never running are now
  wired into the test root (#331).

## v0.0.227 (2026-07-31)

- kuri, the headless-browser companion that backs `webfetch`'s markdown path
  and the kuri skill, installs by default now; opt out with
  `HARNESS_NO_KURI=1` (#329).
- Both the root and subagent system prompts now ask for parallel tool calls,
  with the dependency caveat that keeps same-file writes from racing (#329).

## v0.0.226 (2026-07-31)

- `/images` opens image URLs from the last response (for example a
  `gh issue view` with attachments) in your browser (#103).
- The prompt line is width-budgeted so long model and mode badges cannot break
  interactive redraw (#209).
- Kimi and xAI OAuth tokens refresh selectively at startup (#274).

## v0.0.225 (2026-07-31)

- Remote MCP supports stateless-core servers, with a legacy fallback.
- The system-prompt variants are built through one funnel, removing drift
  between the interactive, subagent, and review prompts (#326).

## v0.0.224 (2026-07-30)

- `/goal` hardening follow-ups: pinned call-site coverage and a real-PTY
  regression for goal collapse.

## v0.0.223 (2026-07-30)

- Orchestration hardening: worktree commit-loss fix, JSON tag guards against
  undefined-behavior derefs, subagent task pinning, and five ultracode audit
  fixes (retry gating, all-failed abort, phase budgets, worktree rejection in
  pipelines, shared context slots).
- Anthropic models stream summarized thinking (#322), and review mode no
  longer races the background learning writer (#324).

## v0.0.222 (2026-07-30)

- `/goal` and `/loop` are one autonomous run: the same engine with or without
  a standing objective, including time budgets like `/goal 30m <text>`.

## v0.0.221 (2026-07-30)

- Goal epochs, and a standing `--goal` that survives compaction via an
  objective snapshot (#318).
- Retained reasoning is pinned across all wire formats.
- MCP servers get a bounded teardown at session exit (#305).

## v0.0.220 (2026-07-26)

- `learn` auto-initialization fix (#304).

## v0.0.219 (2026-07-26)

- The local learning loop closed end to end: zero-config `graff learn init`,
  session-triggered background trials, and the learned genome becomes the root
  prompt (#302). See [docs/local-learning.md](docs/local-learning.md).

## v0.0.218 (2026-07-26)

- Workspace router configuration for providers; router cache entries
  serialize independently.
- GUI: provider surfaces reachable in QA mock mode, useful sidebar empty
  states, and narrow-window fixes (#300).

## v0.0.217 (2026-07-25)

- Zig 0.17 nightly compatibility for CI (#298).
- OAuth refresh is single-flight (#245), clipboard paste gets a vision guard
  (#258), a provider-routing fix (#294), and the ultracode shape catalog with
  a slot axis (#290, #293).

## v0.0.216 (2026-07-24)

- `/review` is bounded correctly without a hard call cap (#280, #281).
- Subagent harness orchestration (#279).

Older releases: narrative notes for v0.0.211, v0.0.212, and v0.0.215 live in
[docs/releases/](docs/releases/), and `graff --version` prints highlights back
to v0.0.192.
