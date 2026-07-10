# v0.0.193 handoff

This release branch is intentionally unfinished. Do not tag or publish it until
the remaining UX work and the full CI suite pass.

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
- Initial cross-provider fallback allowlist storage/filtering and persistent
  provider/fallback prompt badges.

## Finish in this order

1. Complete the fallback-consent UX: add `/fallback` show/allow/remove/off,
   block an unallowlisted startup fallback before any prompt is sent, and carry
   the allowlist/state through `graff repl`, JSON, and one-shot modes.
2. Reject unknown model names before `switchProvider` saves them as the default.
3. Make model/settings pickers responsive to terminal rows/columns and initially
   highlight the current value.
4. Generate `/help` from the same command registry as the bare `/` menu.
5. Add `/models health` with unified env/Keychain/OAuth availability and recent
   fallback/failure state.
6. Normalize prompt context units and clarify full context versus compact-at.

## Validation state

- `zig build test --summary all`: 147/147 passed before handoff.
- The last combined PTY command was interrupted; rerun all PTY tests. Prompt
  expectations likely need the new provider and `Fallback` badges added.
- Rerun JSON controls, SDK generation drift, formatting, and `git diff --check`.
- No release tag, GitHub release, or deployment has been created.

## Scope warning

The unrelated untracked design drafts (`Agentic_Operating_System.md`,
`graff-dgm.md`, `phase2-escalation.md`, and `vision.md`) are user-owned and were
not included in this branch.
