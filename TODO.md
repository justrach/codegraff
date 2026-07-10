# v0.0.193 handoff

The planned REPL UX hardening is implemented and the full local CI-equivalent
suite passes. The newest changes are still local: review and commit them before
updating the draft PR. Do not tag or publish without an explicit release request.

## Implemented

- Terminal Markdown hierarchy, lists, task boxes, quotes, inline styles, and a
  deterministic real-PTY regression.
- Colored prompt modes with `Fast` prioritized and YOLO moved to warning/status
  output.
- Explicit sibling-repository guidance that preserves native cwd confinement.
- Persisted model choice plus session-local model/provider fallback plumbing.
- Real-PTY model preference, missing-credential fallback, rollout replacement,
  and preference recovery coverage.
- `/key <provider> <secret>` is masked while typed and excluded from both live
  and persisted input history; legacy leaked key commands are filtered on load.
- Cross-provider fallback is opt-in per workspace through `/fallback`; an
  unallowlisted startup fallback is blocked before a prompt can reach it.
- Unknown remote model names are rejected before switching or changing the
  saved default. Explicit local LM Studio/MLX model IDs remain supported.
- Model and settings pickers resize to the live terminal and initially select
  the current value.
- `/help`, the bare `/` menu, and tab completion share `command_catalog.zig`.
- `/models health` reports active/saved model state, context/compaction limits,
  credential source (never value), Codex catalog source/count, WebSocket→SSE
  status, and fallback policy.
- Prompt context is unambiguous (`used/full ctx (% · compact@limit)`) and token
  counts are compacted to readable units.
- API-key entry is hidden in both `/key` and the model picker's auth flow.

## Remaining release handoff

1. Review the local diff and commit only the tracked implementation files plus
   `src/command_catalog.zig` and this handoff.
2. Push `release/v0.0.193` to update draft PR #141.
3. Run hosted checks. Tag/publish only after explicit approval.

## Validation state

- `zig build test --summary all`: 150/150 passed.
- `scripts/test-json-controls.py`: 19/19 passed.
- `scripts/test-pty-spinner.py`: passed in repo, home, and `/tmp` cwd variants.
- `scripts/test-pty-repl.py`: passed, including 44×12 responsive pickers,
  secret masking/history, generated help, and `/models health`.
- `scripts/test-pty-markdown.py`: passed.
- `scripts/test-model-preference.py`: passed.
- `zig build` and `git diff --check`: passed.
- No release tag, GitHub release, or deployment has been created.

## Scope warning

The unrelated untracked design drafts (`Agentic_Operating_System.md`,
`graff-dgm.md`, `phase2-escalation.md`, and `vision.md`) are user-owned and were
not included in this branch.
