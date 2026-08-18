# Skills

A skill is a markdown playbook the harness discovers on disk and loads into
context only when a task calls for it. Skills are how a project teaches the
agent a workflow once instead of re-explaining it every session.

Two kinds of thing are called "skills" in graff, and `/skills` lists both:

- **SKILL.md playbooks** (this document): markdown instructions loaded on
  demand through the `skill` tool. Implemented in `src/skill_docs.zig`.
- **Companion tools** (`src/skills.zig`): optional CLI binaries such as `kuri`
  or the codedb suite, which the harness detects on PATH and mentions in one
  context line each. `/skills add <name>` installs those.

## Layout and precedence

| Location | Scope |
| --- | --- |
| bundled in the binary | every install |
| `~/.claude/skills/` | you, every project (compatibility) |
| `~/.harness/skills/` | you, every project |
| `~/.grok/skills/`, `~/.codex/skills/`, `~/.agents/skills/`, `~/.cursor/skills-cursor/` | you, every project (other harnesses, in place) |
| `~/.cursor/plugins/*/skills/` and `~/.claude/plugins/*/skills/` (and Grok/Codex/graff plugin trees, plus Claude `commands/*.md` and a plugin-root `SKILL.md`) | you, every project (ADR 0007) |
| `.claude/skills/` | this project (compatibility) |
| `.grok/skills/`, `.codex/skills/` | this project |
| `.claude/plugins/*/skills/` (and project plugin trees) | this project |
| `.harness/skills/` | this project |

Later rows win: a project skill shadows a personal skill of the same name,
which shadows a bundled one. Names come from frontmatter when present,
otherwise from the file or directory name.

Both layouts are read in every location:

```
.harness/skills/run-migrations/SKILL.md   # a skill that ships helper files
.harness/skills/release-notes.md          # a single-file skill
```

Skills written for Claude Code need no changes, which is why the `.claude`
directories are read as they are.

## File format

```markdown
---
name: run-migrations
description: Apply or roll back database migrations in this repo, and when to reach for it.
---

# Run migrations

1. ...
```

`name` is optional and defaults to the file or directory name. `description` is
the trigger: it is the only part another session sees before deciding whether
to load the skill, so it should say what the skill does and when to use it.
Unknown frontmatter keys are ignored, and a file with no frontmatter is treated
as all body.

Limits: a SKILL.md is read up to 256 KB, a single load hands the model at most
32 KB (longer bodies are truncated with a pointer to the file), and each
description contributes at most 500 bytes to the system prompt.

## Progressive disclosure

At startup the harness scans every tier and appends one line per skill to the
system prompt: name, source, description. Bodies are never in that block. When a
task matches, the model calls the `skill` tool with a name and gets the body
back, plus the directory the skill came from so it can read helper files with
`read_file`.

`skill` with no name lists every available skill; an unknown name comes back as
an error result listing the ones that exist. Subagents have the tool too, and
discover the catalog the same way.

The tool re-scans the skill directories on every call, so a SKILL.md written
earlier in the same session is immediately loadable. The startup catalog itself
is rebuilt at the next launch, and `/skills` re-scans when it runs.

## Managing skills

```
/skills                  list playbooks and companion tools, with sources
/skills remove <name>    hide one from the catalog and the tool
/skills add <name>       bring a hidden one back
```

An opt-out persists as `{"skills": {"<name>": false}}` in
`.harness/settings.json`, the same key the companion registry uses. A disabled
skill is absent everywhere: no catalog line, and the `skill` tool will not serve
it.

## Bundled skills

Two skills are compiled into every binary, so a fresh install can already teach
itself:

- `skill-creator`: where skills live, the file format, how to install one, and
  what is worth capturing as a skill.
- `mcp-config`: the `.mcp.json` shape, the `graff mcp` CLI, the in-session
  `/mcp` commands, and why a server may not have connected.

Their sources are `assets/skills/*.md`, embedded through `build.zig` and parsed
at compile time, so a bundled skill missing its description or body fails the
build rather than going quietly absent.

## Skills, agents, and project instructions

- `AGENTS.md` / `CLAUDE.md` / `HARNESS.md`: always-on project instructions, in
  context for every turn. Use for conventions that apply to all work.
- Skills: loaded on demand. Use for detailed procedures that only matter
  sometimes.
- `.harness/agents/*.md` personas: whole system prompts for delegated
  subagents, not instructions for the current agent.
