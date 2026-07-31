---
name: skill-creator
description: Author, install, or edit a graff skill (a SKILL.md playbook) - use when the user wants to capture a repeatable workflow as a reusable skill, asks how skills work, or asks you to write or update a skill.
---

# Writing a graff skill

A skill is a markdown playbook the harness finds on disk and loads on demand.
Only its name and description sit in the system prompt; the body stays on disk
until the `skill` tool loads it. That split is the whole point: the catalog
line stays cheap, and the detail is there when a task actually needs it.

## Where skills live

| Location | Scope |
| --- | --- |
| `.harness/skills/` | this project, checked in with the repo |
| `~/.harness/skills/` | you, in every project |
| `.claude/skills/`, `~/.claude/skills/` | read as-is, for Claude Code compatibility |

Precedence, lowest to highest: bundled, `~/.claude/skills`, `~/.harness/skills`,
`.claude/skills`, `.harness/skills`. A project skill shadows a personal skill of
the same name, which shadows a bundled one.

Two layouts, both valid:

- `.harness/skills/<name>/SKILL.md` - use this when the skill ships helper files
- `.harness/skills/<name>.md` - a single-file skill

## Format

```markdown
---
name: run-migrations
description: Apply or roll back database migrations in this repo - use when the user wants to migrate, add a migration, or a schema change needs deploying.
---

# Run migrations

1. ...
```

- `name` is optional; it defaults to the file or directory name. Keep it
  kebab-case, since that is what the user types after `/skills`.
- `description` is the trigger, and the only thing another session sees before
  deciding to load the skill. Say what it does AND when to reach for it, on one
  line. A description that only names the topic ("migrations") will not fire.
- The body is plain markdown. Bodies over 32 KB are truncated on load, with a
  pointer to the file, so keep it focused.

## Installing one

1. `write_file` the SKILL.md (create the directory first if it does not exist).
2. Load it back with the `skill` tool to confirm it parses. The tool rescans
   every call, so a skill you just wrote is usable immediately in this session.
3. Its catalog line reaches the system prompt at the next start. Until then,
   load it by name.

## What is worth a skill

- A workflow repeated across sessions with steps that are easy to get wrong:
  releases, deploys, migrations, codegen, incident checklists.
- Project conventions too long to sit in CLAUDE.md or AGENTS.md.
- Not worth it: one-off instructions, or anything already obvious from reading
  the code. A skill nobody loads is context tax for every future session.

## Helper files

Anything next to SKILL.md travels with the skill. Reference it by relative path
in the body and read it with `read_file` at the point it is needed - the loaded
body tells you which directory the skill came from. Keep SKILL.md the index,
not the encyclopedia.

## Managing skills

- `/skills` lists every skill with its source and file.
- `/skills remove <name>` disables one. That persists as
  `{"skills": {"<name>": false}}` in `.harness/settings.json`, and the skill
  disappears from the catalog and from the `skill` tool entirely.
