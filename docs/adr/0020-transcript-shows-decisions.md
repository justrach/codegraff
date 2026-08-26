# 0020. The transcript shows decisions, not raw tool output

Status: accepted 2026-08-21

## Context

ADR 0016 made the line REPL a WORKING block plus a bare `›`, and tool rows a
tree of verbs. Live bash chunks (0.0.268) and command-as-detail then dumped
branch lists, CI runs, and repeated `McpClosed` rows into that transcript. A
question like "is 0.0.269 passing tests?" became ten near-identical failed CI
lines. The user-relevant fact was "CI is red."

## Decision

- Never print data merely because a tool returned it. Print it only if the
  user would notice its absence.
- A tool row is one interpreted line (`✓ git  3 commits`). The command is not
  conversational. `/debug` (and the TUI fold) keeps the raw bytes inspectable.
- Repeated infrastructure failures of the same family collapse to one
  `! codedb unavailable`. The batch `↯ N failed` tally stays off when every
  failure was that family.
- WORKING is compact: `WORKING  {goal}  {done}/{total}` and a `├─`/`└─`
  checklist. No rules, no progress bar.

## Consequences

JSON `bash_output_chunk` events are unchanged. The hosted TUI sink still
streams into the fold. In the line REPL, a row whose interpretation hid raw
bytes carries `↵ raw`; empty Enter reveals the newest unseen result, explicitly
and terminal-safely. `/debug` remains the continuous escape hatch. ADR 0016's
progress bar is retired.
