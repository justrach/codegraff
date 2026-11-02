# 0298. Recurrence reports update the canonical issue's state

Status: accepted

## Context

[#1701](https://github.com/justrach/codegraff/issues/1701) exposed a gap in the
reporting instructions: searching closed issues and adding fresh evidence
avoided duplicates, but left unresolved recurrences classified as resolved.
The `/issue` brief also demanded a new issue even when a matching report existed.

## Decision

Ordinary reporting and `/issue` share issue-lifecycle guidance. Inspect the
matching issue's state, closure reason, and latest resolution. When current
reproduction evidence contradicts a resolved closure, reopen the canonical
issue and attach the evidence. Follow duplicate closures to their canonical
tracker; do not reopen deliberately rejected, withdrawn, or out-of-scope reports
merely because they receive comments. Confirm and accurately report the final
state, including a denied reopening that requires a maintainer. Custom and
learned root prompts retain this policy across replacement, as worker personas
already do. `/issue` expands the same reporting brief in the REPL and over ACP.

## Consequences

Duplicate detection is not evidence that reporting is complete. The agent
still needs to judge whether the new evidence contradicts the resolution;
automatically reopening every commented-on issue would undo intentional
closures. No GitHub-specific shell interception is introduced: the same rule
applies to CLI and connector reporting. The offline issue-reporting cases in
`evals/harness_behavior.jsonl` verify prompt delivery and stateful local CLI
roundtrips, not a live model's judgment about arbitrary reports.
