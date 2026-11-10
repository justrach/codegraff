# Bots

A Bot is a standing role with one job. It keeps its own memory and work log
between runs, and can start work by itself on a schedule (ADR 0333). Bots live
in the folder you create them in, under `.graff/bots/<name>/`.

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

## Other clients

`graff bot due --claim --json` returns each due routine with the text to run
it and moves it to its next slot, for a client that runs bots in its own
chats. `graff bot prompt NAME` prints a bot's standing text. `list`, `show`
and `routine list` take `--json`.

A client that passes text a person typed puts `--` before it:
`graff bot create notes -- --draft the notes`. After `--` every word is text,
so a job or an instruction that starts with dashes is never read as a flag.
