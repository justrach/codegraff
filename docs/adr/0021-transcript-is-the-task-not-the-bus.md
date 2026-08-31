# 0021. The transcript is the task, not the event bus

Status: accepted 2026-08-21

## Context

ADR 0016 and 0020 made tool rows verbs and WORKING chrome, but the line REPL
still printed harness bookkeeping: `⛔ constraint recorded`, `# skill:`,
`[compacting…]`, `[~]` todo dumps, `read_tool_re` paging, and eight-line
subagent cards with `sa-000-…` ids. To the user those are one fact — the
work — not six UI concepts.

## Decision

Every harness event is one of four classes:

| Class | User sees |
| --- | --- |
| Internal bookkeeping | nothing |
| Work in progress | one ephemeral line, or WORKING on change |
| Useful operation | a semantic one-liner |
| New information | model narration |

`note_constraint`, `skill`, `read_tool_result`, successful compaction, mid-turn
stall/reconnect, and inner-loop "model call N" pulses are bookkeeping (`/debug`
still prints compaction). `todo_write` reprints a
`WORKING` block only when the checklist changes, and the same block sits
above `›`. Subagents are `↯ scout` / `✓ scout` one-liners; the `sa-` id is
not foreground UI. `batch` is `inspect`. Observe, then conclude, then act.

## Consequences

JSON events and tool results the model reads are unchanged. `/debug` and
`.graff/subagents/<id>.md` remain the escape hatch. A later TUI chrome pass
can bind WORKING to the pager footer the same way. The pager claims the
alt-screen before session construction (ADR 0042); the welcome stays empty.
