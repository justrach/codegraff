# 0333. A Bot is a folder, and a routine runs only when something ticks

Status: accepted 2026-11-10

## Context

Hosted assistants such as Grok Bot give a user several standing roles
("Bots"). Each holds one job, keeps its own memory (rules, preferences, a
dated work log), and owns routines that start work on a schedule or on an
event. They run on a cloud computer, so they keep going with the laptop shut.

graff had the pieces but not the role. `schedule_task` (#556, ADR 0331) wakes
the session that created it, so the work dies with that session and shares its
context. Skills hold a method, not who uses it or when. Subagent personas have
no memory between runs. `graff peer` (ADR 0203) showed that a shell command is
the smallest interface every surface and every other agent can drive.

graff has no always-on host. A daemon would be a second long-lived process to
install, supervise and update on three operating systems.

## Decision

- A Bot is the folder `.graff/bots/<name>/`: `bot.json` (name, job, model,
  whether its runs skip approvals), `memory.md`, `log.md` and
  `routines/<id>.json`. Names are `a-z 0-9 - _`, 32 at most.
- A run is one headless graff turn (`--no-resume -p`) with the bot's job, the
  newest 16 KiB of its memory and its last 20 log lines appended to the system
  prompt. graff appends one dated line to `log.md` per run, taken from the
  reply's first line, and marks a failed run `FAILED`.
- A headless run has no file tools unless it is `--yolo`, so it changes
  memory with the last lines of its reply: `remember: <rule>` and
  `forget: <entry, word for word>`. graff applies them and takes them out of
  the reply. Only an unbroken block at the end counts. A run an event started
  has those lines removed and not applied.
- Approvals are graff's headless default. Only a bot created with `--yolo`
  skips them, and that choice is stored in `bot.json` where the user can read
  it. A routine cannot raise its own permissions.
- A routine is `5m` (once) or `@every 2h` (`s`, `m`, `h`, `d`; a repeat is a
  minute or more). Recurring routines stay on their original grid
  (`schedule.nextGridSlot`). Slots missed while nothing ticked are counted and
  run once, not replayed. A resumed routine waits for its next slot.
- Nothing fires by itself. `graff bot tick` runs every due routine once and
  exits, for cron or launchd. A client with its own timer calls
  `graff bot due --claim --json`, which moves each due routine to its next
  slot and returns the system text and the turn so the client can run it where
  the user sees it. That text (also `graff bot prompt NAME`) tells the bot to
  change its memory with `graff bot remember` and `forget` and to log with
  `graff bot log` (ADR 0334), since the client's session runs commands its
  user approves.
- An event starts a routine with `graff bot trigger NAME ID [PAYLOAD]`. The
  payload reaches the run inside `<payload>` tags, labelled as data and not
  instructions. A paused routine refuses an event; `routine test` still runs.
- Bot runs can start other bot runs. `GRAFF_BOT_DEPTH` stops at three.

## Consequences

- A routine is late by up to one tick period, and does not run while the
  machine sleeps or nothing calls `tick`. That is the price of no daemon.
- `.graff/` is ignored by git, so a bot belongs to one checkout and is not
  shared with a team or between worktrees. Sharing would be a new decision.
- The store is plain files with one writer per run. Two `tick` processes in
  the same instant can both claim one slot; a cron entry is one process.
- Marking a payload as data lowers the risk from injected text; it does not
  remove it. Keep approvals on for a bot that events can reach. Memory is the
  one thing an injected run could make permanent, which is why an event's run
  cannot write it.
- There is no vault, connector catalog or hosted computer. A bot can do what
  a graff session in that folder can do, with that session's logins.
- Revisit if graff gains a supervised long-lived host (`graff serve` running
  routines), or if clients need per-bot conversations rather than one-shot
  runs.
