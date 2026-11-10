# Bots

A Bot is a standing role with one job. It keeps its own memory and work log
between runs, and can start work by itself on a schedule (ADR 0333). Bots live
in the folder you create them in, under `.graff/bots/<name>/`.

Bots are experimental and off until you turn them on:

```bash
graff bot enable      # once; writes ~/.graff/bots/enabled
graff bot disable     # off again; every bot and its memory is kept
```

While they are off every other `graff bot` command, `tick` included, exits 2
before it touches a bot store, and prints:

```
graff bot: bots are experimental and off. Turn them on with `graff bot enable`
```

`GRAFF_BOTS=1` turns them on for one process and `GRAFF_BOTS=0` off, whatever
the file says.

```bash
graff bot create triage "Read TODO.md and report what is still open"
graff bot run triage "what is open? from now on answer as a numbered list"
graff bot show triage          # job, memory, routines, recent log
```

A run is one headless graff turn with the bot's job, memory and recent log in
its system prompt. Approvals are the same as any headless run; create the bot
with `--yolo` to let its runs edit files and run commands, and with
`--model <name>` to pin a model.

## Memory and log

- `memory.md` holds rules and preferences. Tell the bot to remember or forget
  something and it ends its reply with `remember: …` or `forget: …` lines;
  graff applies them and prints `✓ memory: 1 added, 0 removed`. You can also
  edit the file.
- `log.md` gets one dated line per run. `graff bot log triage` shows it.

Keep secrets out of both files.

## Routines

```bash
graff bot routine add triage "@every 2h" "report anything new"
graff bot routine add triage 30m "post the weekly summary"     # once
graff bot routine list
graff bot routine pause|resume|rm triage r1
graff bot routine test triage r1    # run it now; the schedule does not move
```

Units are `s`, `m`, `h` and `d`; a repeat is a minute or more. A repeating
routine keeps its original times: one that was due five times while nothing
was running runs once, then waits for its next slot.

Nothing runs a routine by itself. `graff bot tick` runs every routine that is
due and exits, so put it on a timer in the project folder:

```cron
*/5 * * * * cd /path/to/project && graff bot tick >> .graff/bots/tick.log 2>&1
```

## Events

`graff bot trigger triage r1 "issue 12 was opened"` runs a routine now with a
payload (or pipe the payload on stdin), for a webhook receiver or a CI step.
The payload reaches the bot marked as data, and a run an event started cannot
change the bot's memory.

## Your own bots, in any project

`graff bot --user …` keeps bots in `~/.graff/bots`, not in one project.
Every command above works with it.

```bash
graff bot --user create main --primary -- "Keep my work moving across my projects."
graff bot --user create notes --project ~/code/comet -- "Draft release notes"
graff bot --user about -- "Alex. Pacific time."
graff bot --user set notes model claude-haiku-5-5
```

- `--project` is the folder a bot's runs work in.
- One bot can be primary: your main bot, the one thread for every project
  (ADR 0335). In a client such as Harness it starts each piece of work as
  its own chat in the project it belongs to, and the result comes back to
  its thread. It asks only when it cannot tell which project you mean. Your
  other bots are helpers it hands their own jobs to. From a terminal
  (`graff bot --user run main "…"`) it cannot reach another folder, so it
  says which project the work belongs in and gives you the command.
- `about` is a few facts about you that every one of your bots is shown.
- `remember NAME TEXT` and `forget NAME TEXT` change one memory entry
  without opening the file.

## What ran, and what did not

`graff bot tick --stale-after 300` does not run a slot that came due more
than five minutes ago. It records it. After a night with the laptop shut:

```bash
graff bot --user missed          # notes/r1  due 2026-11-11 04:10Z, did not run (1)
graff bot --user routine test notes r1    # run it now, if you still want it
graff bot --user missed clear notes r1
graff bot --user state           # every bot, and when routines were last checked
```

Without `--stale-after`, a late slot runs once when the next `tick` comes,
which is what a cron entry usually wants.

## Other clients

A client reads the same switch: the file `~/.graff/bots/enabled`, unless
`GRAFF_BOTS` is `1` or `0`. `graff bot --user enable` and `disable` change it.

`graff bot due --claim --json` returns each due routine with the text to run
it and moves it to its next slot, for a client that runs bots in its own
chats. `graff bot prompt NAME` prints a bot's standing text. `list`, `show`
and `routine list` take `--json`.

`graff bot state --json` returns every bot, its routines (each marked `due`
or not, with any missed slots), the last check and the last stretch in which
nothing checked. `due --claim --json` rows carry the bot's `project`, `model`
and `chat`, and `graff bot set NAME chat ID` stores a client's id for the
bot's standing conversation.

A client that passes text a person typed puts `--` before it:
`graff bot create notes -- --draft the notes`. After `--` every word is text,
so a job or an instruction that starts with dashes is never read as a flag.
