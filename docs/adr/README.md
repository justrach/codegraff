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
| [0007](0007-plugins-are-read-in-place.md) | Cursor/Claude/Grok/Codex plugins and MCP are read in place (Claude/Cursor cache via installed_plugins.json, Codex via config.toml PluginStore, never walked); skills stay on-demand; MCP stays consent-gated. |
| [0008](0008-synthetic-evals-use-external-verifiers.md) | Synthetic coding evals promote only external-verifier passes; model judges may tiebreak correctness, never decide it. |
| [0009](0009-gpt-5-6-explicit-prompt-cache-boundary.md) | GPT-5.6 OpenAI Platform marks the stable prefix explicitly; Codex and xAI stay on their supported keyed automatic-cache paths. |
| [0010](0010-background-jobs-wait-for-exit.md) | `bash_output`/`agent_output` `wait_ms>0` blocks until exit (10h cap); do not poll every 30s. |
| [0011](0011-prompt-cache-max-is-visible.md) | Prompt-cache max is on: stable catalog by default; `/cache` is the HUD; `/btw` rides the parent prefix; children share role-lane `x-grok-conv-id` / `prompt_cache_key` (not the root id). |
| [0012](0012-overflow-handles-named-limits-extra-roots.md) | Fat tool results become `tr_N` handles; named `--context-limit` caps prefix bytes; `--add-dir` extra roots are PathConfine allow-lists, not cwd/skill/session sources. |
| [0013](0013-list-dir-lives-in-codedb.md) | Directory listing is `codedb list_dir` (in-process BFS, gitignore, 10k cap), not a new always-on catalog tool. |
| [0014](0014-session-resume-carries-the-room-cursor.md) | `/resume` restores the peer-channel byte cursor and inbox; it does not replay the room into history. |
| [0015](0015-ask-user-images-are-a-follow-up-user-message.md) | `ask_user` images ride a follow-up user message after the text tool result; Responses/OpenAI tool output stays text-only. |
| [0016](0016-line-repl-is-a-working-block.md) | Line REPL chrome is a `WORKING` block plus a bare `›`; tool fan-out is a tree, never `✓ bash`. |
| [0017](0017-model-election-ranks-signed-in-plans-first.md) | `/model` and `/models` on both frontends rank signed-in plan seats above credits and metered keys (`src/models_rank.zig`). |
| [0018](0018-standing-chrome-shows-last-turn-cache-hit.md) | Last-turn cache hit % rides with `ctx` on the line-REPL meter and the TUI footer; `/cache` stays the posture HUD. |
| [0019](0019-codedb-one-shot-over-hop-chains.md) | Advertise only `context` / `around` / `callpath` / `list_dir` / `status`; hop verbs stay callable, not on the menu. |
| [0020](0020-transcript-shows-decisions.md) | Transcript shows decisions: one interpreted tool line, collapsed infra failures, compact WORKING; raw output is `/debug` / TUI-fold. |
| [0021](0021-transcript-is-the-task-not-the-bus.md) | Transcript is the task, not the event bus: bookkeeping is silent, todos are WORKING, subagents are scouts. |
| [0022](0022-rlm-is-opt-in-speculative-ptc.md) | `rlm` (Alex Zhang spec-ptc + RLM, Zig) is the default loop. `--old` restores structured-only. Prime persist + `subagent()` only — no IPython. |
| [0023](0023-codex-subagent-is-sidecar-not-v8.md) | Codex check: take sidecar-vs-critical-path spawn prompts; reject V8 Code Mode, extra spawn tools, and parent-history fork. |
| [0024](0024-three-harness-compare-prompt-subagent-rss.md) | Steal short child briefs + sidecar spawn; `print(read_file)` returns the file; `-p` skips the shared-tree checkpoint (evals are sibling sandboxes); reject rlm-only catalog, grok heap, Harbor. |
| [0025](0025-io-uring-is-not-the-process-io.md) | Process Io stays Zig `Threaded`. spec-ptc is already the default loop (ADR 0022). Do not take ublk or switch `main` to `std.Io.Uring`. |
| [0026](0026-foreground-bash-auto-backgrounds.md) | Root foreground `bash` auto-backgrounds after 120s (or `timeout` ms); it is not killed. Subagents still kill at 120s (#93). |
| [0027](0027-kimi-identity-is-graff.md) | Kimi Coding User-Agent is `graff/<version>`, not a spoofed `kimi-code-cli` token. X-Msh device fields follow kimi-code's shapes. |
| [0028](0028-codex-session-id-is-the-cache-key.md) | Codex HTTP/WS `session_id` is the `prompt_cache_key` (openai/codex ModelClient default), not a per-process random UUID. |
| [0029](0029-mcp-inside-rlm-and-return-shapes.md) | Loaded MCP tools are rlm host functions; persist return shapes on the load result, never the prefix; fat MCP results auto-slim; default `-p` connects `.mcp.json` (folded, not skipped). |
| [0030](0030-rlm-late-showcase.md) | Small turns hide `rlm` (and sPTC). Showcase on `--rlm`, a ≥4 native batch, context ≥50% of compactAt, or an explicit load — never on MCP fan-out or the prefix. |
| [0031](0031-xai-hosted-x-search.md) | xAI Responses splices hosted `x_search` onto tools turns. It is not a catalog function; `GRAFF_XAI_X_SEARCH=0` opts out. |
| [0032](0032-acp-streams-mid-turn.md) | `graff acp` streams thought / tool / text `session/update`s mid-turn. The native app is an ACP client; it does not need `graff serve`. |
| [0033](0033-user-can-retire-a-standing-constraint.md) | Only the user retires a standing constraint: `/never` (REPL or ACP prompt) or an explicit override in the current message. The model cannot. |

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
