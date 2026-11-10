# 0331. Rewind-proof attempt ledger, wall-clock grid schedules, and corrupt-safe playbook self-healing

Status: accepted 2026-11-09

## Context

Long-running autonomous and scheduled sessions hit four durability and latency sharp edges (`29941b47`):

1. When a user or agent ran `/undo` or `/rewind` to revert a failed approach and the session later compacted, the reverted turns disappeared from both the live messages and the compaction input, causing the model to repeat the exact reverted edit after compaction.
2. Recurring schedules (`/schedule`, `schedule_task`) computed `next_fire = now + interval`, drifting off wall-clock boundaries over time and lacking an explicit policy when a machine sleep or busy turn caused multiple intervals to be missed.
3. A torn write or manual edit in `.graff/playbook.jsonl` caused `playbook.load` to fail or silently drop constraints without warning the session or healing the file tail for subsequent `note_constraint` appends.
4. `job_foreground` polled fast shell commands at a fixed 100 ms interval, adding up to 100 ms of idle wait to sub-10 ms commands, and `tool_env` did not scrub newer OAuth/alias environment variables (`ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, `GOOGLE_API_KEY`, `KIMI_CODE_API_KEY`, `OPENAI_AUTH_TOKEN`) from child tool processes.

## Decision

- `snapshots.Snapshots` maintains an append-only, rewind-proof ledger (`rewinds: ArrayList(RewindEntry)`, `restoreWithReason`, `rewindDigest`) across `/undo` and `/rewind`, and `compact_handoff_note.durableState` injects the bounded digest so compacted sessions know which edits were reverted and why.
- `schedule` aligns recurring tasks to wall-clock grid boundaries (`nextGridSlot`) and supports `@every <delay>` and `--missed=once|skip` (`MissedPolicy.once | .skip`, defaulting to firing at most once per missed window rather than bursting).
- `playbook` provides corrupt-safe line-by-line recovery (`parseDetailed`, `loadDetailed`), backs up corrupted files to `.graff/playbook.jsonl.corrupt` while healing missing trailing newlines before `appendLine`, and surfaces `"storage_warning"` diagnostics in `recordedStateWithHealth`.
- `agent_file.validateMarkdown` reports 1-based `line:col` frontmatter diagnostics, `tool_env` scrubs OAuth/alias tokens while preserving provider control flags (`CHATGPT_NEW_DISABLED`, `GRAFF_CLAUDE_AGENT`), and `job_foreground.pollStepMs` ramps polling from `5ms -> 10ms -> 20ms -> 65ms -> 100ms`.

## Consequences

Rewound sessions retain memory of reverted attempts across compaction, recurring schedules stay grid-aligned without burst storms after sleep, corrupt playbook ledgers self-heal with backup preservation, and fast foreground commands complete with sub-20 ms polling latency.
