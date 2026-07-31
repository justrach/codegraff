---
name: skill-creator
description: Create, improve, or test a graff skill (a SKILL.md playbook). Use whenever the user wants to capture a repeatable workflow as a skill, says "turn this into a skill", wants to edit or tune an existing skill, wants to check that a skill actually works or triggers, or asks how skills are written - even if they never say the word "skill".
---

# Creating a graff skill

A skill is a markdown playbook the harness discovers on disk and loads on
demand. Only its name and description sit in the system prompt; the body stays
on disk until the `skill` tool loads it. That split is the whole point: the
catalog line stays cheap, and the detail arrives when a task needs it.

Your job with this skill is to find where the user is in this loop and carry
them forward:

capture intent -> draft -> test on realistic prompts -> let the user judge ->
improve -> repeat until they are happy.

If the user just wants to vibe ("write it, skip the testing"), do that - the
loop is the default, not a mandate.

## Capture intent first

The conversation often already contains the workflow the user wants captured
("turn this into a skill"). Extract what you can before asking anything: the
tools used, the order of steps, the corrections the user made along the way.
The corrections are the most valuable lines in a skill - they are exactly what
a fresh session would get wrong. Then fill the gaps:

- What should the skill let a future session do?
- When should it fire - which user phrases and situations?
- What does a good result look like, concretely?

Confirm your understanding in a sentence or two before writing.

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

## The description is the trigger

The description is the only thing a future session sees before deciding to
load the skill, so it carries the entire triggering burden. Two rules:

- Say what the skill does AND when to reach for it, in one frontmatter line.
- Models undertrigger skills: a description that only names the topic
  ("migrations") will not fire. Make it a little pushy - name the tasks, the
  phrasings, the situations, including ones where the user does not use the
  obvious word. "Apply or roll back database migrations - use when the user
  wants to migrate, mentions a schema change, or a deploy needs the database
  updated, even if they never say migration."

## Write the body for a smart reader

- Use the imperative, and explain why a step matters instead of stacking
  ALL-CAPS MUSTs. A model that understands the reason generalizes past your
  examples; one that only has the rule breaks the moment reality differs.
  Rigid capitalized commands in a draft are a sign to reframe.
- Keep it general. You are iterating against a handful of examples, but the
  skill will run against prompts neither of you wrote. If a fix only works for
  the test case in front of you, it is overfit - widen it or drop it.
- Show one or two concrete input -> output examples where format matters.
- If test runs keep writing the same helper script, stop and bundle it: put it
  next to SKILL.md, reference it by relative path, and have the body say when
  to run it. Write it once instead of letting every future session reinvent it.
- Bodies over 32 KB are truncated on load, with a pointer to the file. Well
  before that, move reference detail into helper files and keep SKILL.md the
  index, not the encyclopedia.
- A skill must never surprise the user who installed it: no hidden data
  collection, nothing beyond what its description advertises.

## Test it with fresh subagents

A skill has to work in a session that lacks today's context, and you are the
worst possible tester - you wrote it, so you cannot not know what it means.
The `subagent` tool gives you what you need: a fresh context that has never
seen this conversation.

1. Write 2-3 realistic test prompts - concrete, detailed, the way users
   actually type, not clean abstractions. Show them to the user before
   running: "do these look right?"
2. For each prompt, spawn a pair of subagents in the same turn so they finish
   together:
   - with-skill: "Load the skill '<name>' with the skill tool and follow it
     for this task: <prompt>. Save what you produce under <dir>/with/."
   - baseline: the same task, no mention of the skill, saving under
     <dir>/without/. When improving an existing skill, the baseline is the old
     version instead: copy it aside first and point the subagent at the copy.
3. Read both transcripts, not just the outputs. If the with-skill run wasted
   turns on something the body made it do, that part of the skill is costing
   more than it pays.
4. Show the user both results per prompt and collect their reactions. Their
   complaints, not your judgment, drive the next revision.

To test triggering separately: give a fresh subagent the catalog lines (name +
description, exactly as the system prompt shows them) plus a dozen candidate
prompts - some that should trigger, some near-misses that should not - and ask
which skill, if any, it would load for each. Near-misses that share keywords
with the skill are the valuable cases; obviously-unrelated prompts prove
nothing. Tune the description until both directions hold.

## Improve

Generalize from the feedback rather than patching the example: ask what the
user's complaint says about the class of task, put that understanding into the
body, and delete anything that is not pulling its weight. Then rerun the same
test prompts and compare against the previous round. Stop when the user is
happy, the feedback comes back empty, or a round stops producing real change.

## Installing one

1. `write_file` the SKILL.md (create the directory first if it does not exist).
2. Load it back with the `skill` tool to confirm it parses. The tool rescans
   every call, so a skill you just wrote is usable immediately in this session.
3. Its catalog line reaches the system prompt at the next start. Until then,
   load it by name.

## Managing skills

- `/skills` lists every skill with its source and file.
- `/skills remove <name>` disables one (persisted as
  `{"skills": {"<name>": false}}` in `.harness/settings.json`); `/skills add`
  brings it back.

## What is worth a skill

- A workflow repeated across sessions with steps that are easy to get wrong:
  releases, deploys, migrations, codegen, incident checklists.
- Project conventions too long to sit in CLAUDE.md or AGENTS.md.
- Not worth it: one-off instructions, or anything already obvious from reading
  the code. A skill nobody loads is context tax for every future session.
