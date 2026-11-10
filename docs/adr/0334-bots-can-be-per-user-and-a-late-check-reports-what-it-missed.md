# 0334. Bots can be per user, and a late check reports what it missed

Status: accepted 2026-11-11

## Context

ADR 0333 keeps a bot in one project's `.graff/bots`. A client that shows bots
as contacts (a list of named roles you message from any project, one of them
your default point of contact, with a list of what happened while you were
away) needs three things that store did not have.

- A bot that is not inside one folder. A project bot is invisible from every
  other project, and `.graff/` is ignored by git, so it never travels.
- A truthful answer to "what was due while nothing was checking". `tick`
  runs a late slot once and only counts the rest. After a night with the
  laptop shut that is a run nobody asked for at 08:06, and no record that
  the 23:05 one never happened.
- A place for what the client keeps per bot: the folder its runs work in,
  which conversation is its standing one, and which bot is primary.

A user-level store is outside the folder a client's chat works in, and
graff's file tools stay inside that folder, so a bot in a client's chat
cannot edit its own `memory.md`.

## Decision

- `graff bot --user …` is the same store rooted at the user's home:
  `~/.graff/bots/<name>/`. Every command works in either scope. A user-level
  bot has an optional `project` (a full path); its runs work there.
- `bot.json` also keeps `primary` and `chat`. At most one bot is primary:
  making one primary clears the others. `chat` is a client's id for the
  bot's standing conversation; graff stores it and never reads it.
  `graff bot set NAME KEY VALUE` changes `job`, `model`, `project`, `chat` or
  `primary`. It cannot change whether a bot skips approvals.
- (Superseded by ADR 0335: the primary bot is the main bot, works across
  projects, and hands off without waiting.) The primary bot's standing text
  lists the other bots and tells it to name
  the bot whose job a request is and wait for a yes. It never starts another
  bot's run unasked. The text is advice to a model, so a client that needs
  the confirmation to be certain has to enforce it where the run starts.
- `.graff/bots/about.md` holds a few facts about the user (2 KiB at most),
  set with `graff bot about TEXT` and shown to every bot in that store.
- `graff bot remember NAME TEXT` and `forget NAME TEXT` change one memory
  entry. In a client's chat the standing text tells the bot to use them, and
  `graff bot log`, in place of editing files.
- `tick` and `due --claim` record when they ran in `.graff/bots/check.json`.
  With `--stale-after SECONDS`, a slot older than that is not run late: the
  routine keeps the first slot it missed and how many (`missed_at_ms`,
  `missed_open`), and only the newest slot runs, if it is still fresh. A
  silence longer than the window is kept as the latest gap (`gap_from_ms`,
  `gap_to_ms`). `graff bot missed` lists them and `missed clear NAME ID`
  drops one after the user ran or dismissed it. Without the flag a late slot
  still runs once, as before, which is what a cron entry wants.
- `graff bot state --json` is everything a client draws in one call: the
  last check and gap, the about text, and every bot with its routines, each
  marked `due` or not.
- Bots are experimental and off until `graff bot enable`, which writes the
  file `~/.graff/bots/enabled`. While off, every other `graff bot`
  command refuses with exit 2 before it reads or writes a store. The switch
  is in the user's home for both scopes, so a terminal, a client's engine
  and a bot's own chat read one answer; `GRAFF_BOTS=1` or `=0` decides for
  one process. `disable` removes the file and keeps every bot.

## Consequences

- A cron entry or a client's timer that calls `tick` while bots are off gets
  the refusal and runs nothing. A client that wants to stay quiet checks the
  file itself and starts no process.
- The switch is per user, not per project: a project cannot turn bots on for
  someone who cloned it.
- A check in a folder with no bots writes nothing, so a client can check
  every project without leaving stores behind.
- The gap is "nothing checked between these two times". graff does not know
  why (asleep, quit, crashed) and a client should not guess.
- Two scopes means two lists. A client decides whether it shows project bots
  beside user bots; graff does not merge them or move one to the other.
- A missed one-shot routine is spent. Running it is the client's choice
  (`routine test`, or its own run), followed by `missed clear`.
- `remember` and `forget` are shell commands, so in a chat that asks before
  running commands, changing memory asks too. That is the intended cost of a
  store the chat's file tools cannot reach.
