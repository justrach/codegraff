# Custom agent files

Copy into `~/.harness/agents/` (every project) or `.harness/agents/` (this repo).
Spawn with `subagent agent:"<name>"`.

```toml
name = "pr_explorer"
description = "Read-only codebase explorer."
model = "grok-4.6"
model_reasoning_effort = "medium"   # alias for effort
isolation = "shared_cwd"            # or worktree
developer_instructions = """
Stay in exploration mode.
"""
```

Also loaded: `~/.codex/agents` and `.codex/agents`. A `.harness` file of the
same name wins. Markdown frontmatter still works; `/agents promote` still
writes `.md`.
