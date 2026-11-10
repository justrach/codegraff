# 0324. Workspace-invariant skill catalog prefix ordering and deepseekChat repo_context split

Status: accepted 2026-11-09

## Context

Across multi-repository evaluations (`e9b3e1fe`), sessions switching between workspaces missed the provider prompt cache on the system prompt and tool definitions because:

1. `startup.buildSystemPrompt` placed workspace-varying segments (`AGENTS.md`, `--append-system-prompt`, `repo_map`) ahead of machine-wide `# Skills`, or mixed `.project` skills ahead of global `~/.codegraff/skills`, causing the system prompt prefix to diverge before the static skill catalog.
2. On `deepseekChat` routes (Kimi / DeepSeek / OpenAI-compatible chat-completions wires that cache the longest shared prefix from message 0), leaving workspace instructions and repository layout inside `messages[0]` (`role: "system"`) invalidated the prefix before the `tools` block or immediately after the base instructions.

## Decision

- `startup.buildSystemPrompt` places the `# Skills` catalog before workspace-varying segments (`AGENTS.md`, `--append-system-prompt`, `repo_map`), with machine-global skills sorted deterministically ahead of workspace-local `.project` skills.
- On `deepseekChat` routes, `repo_context.split` moves workspace instructions and the repository layout out of `messages[0]` (`system`) and prepends them to the first `user` message (mirroring ADR 0243 and ADR 0258), keeping `system` + `tools` byte-identical across workspaces.

## Consequences

Sessions across different repositories share the full `system` + `tools` + global `# Skills` prefix cache on chat-completions and native routes alike. Snapshot and prompt-ordering tests must preserve the invariant prefix boundary before workspace-local instructions.
