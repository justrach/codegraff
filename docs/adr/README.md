# Architecture Decision Records

Settled decisions with their reasoning, so nobody (human or agent) has to
re-derive or re-litigate them from scratch. Each record is one decision: the
context that forced it, what was decided, and what it costs.

**Start here.** The index below gives you the rule in one line; open the
record only when you need the evidence or the edge cases.

## Index

| ADR | The rule |
|---|---|
| [0001](0001-structured-outputs-are-a-formatting-step.md) | Structured output is a final formatting step. Never constrain the agentic phase with a schema grammar, and do not use `--output-schema` unless a program consumes the result. |
| [0002](0002-xai-defaults-to-the-responses-wire.md) | xAI runs on the Responses wire by default (WS turns, lossless server compaction). `GRAFF_XAI_WIRE=chat` opts out; WS stays an explicit provider list. |
| [0003](0003-codegraff-wire-follows-model-capability.md) | Codegraff uses Responses + WS for GPT-5.6 and grok-4.6 aliases; Claude, Gemini, and other aliases stay on Chat Completions. |
| [0004](0004-peer-speech-is-a-working-set.md) | Peer speech is pull: a one-line `[peer]` wake in history, bodies in the inbox ring; compact drops spent injects and never treats them as the human. |
| [0005](0005-standing-goal-lives-in-the-prefix.md) | Standing goal is one prefix line; the user-message essay injects on change only, never every N turns. |
| [0006](0006-workspace-switch-is-a-tool.md) | Mid-session worktree switch is a real `workspace` tool; a skill cannot move file-tool cwd. |
| [0007](0007-plugins-are-read-in-place.md) | Cursor/Claude/Grok/Codex plugins and MCP are read in place; skills stay on-demand; MCP stays consent-gated. |

## When to write one

Write an ADR when a decision is load-bearing and non-obvious: it was reached
through measurement, a debate, or a failure, and someone later would
plausibly "fix" it back. Do not write ADRs for conventions the linter or
tier 1 already enforces (those live in [AGENTS.md](../../AGENTS.md)).

## How to add one

1. Copy the template below into `docs/adr/NNNN-short-slug.md` (next free number).
2. Add one row to the index above with the rule stated in one line.
3. Keep it under a page. Evidence beats prose: link the eval, issue, or commit.

```markdown
# NNNN. Title stating the decision

Status: accepted YYYY-MM-DD

## Context

What forced a decision, with the measurements or failures that framed it.

## Decision

What we do now, stated so a reader can comply without reading anything else.

## Consequences

What this costs, what it protects, and what would justify revisiting it.
```
