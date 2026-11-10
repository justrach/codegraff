# 0335. The primary bot is the main bot, and it works across projects

Status: accepted 2026-11-11

## Context

ADR 0334 made one bot primary and told it to route: name the bot whose job a
request is, and wait for a yes. That is a switchboard for single-job bots,
each tied to one project. It is not what people mean by a main agent.

Always-on agents such as OpenAI's dots and Anthropic's Claude Duet are one
agent with one ongoing thread. You hand it work in any project, it starts
that work as a separate task where it belongs, and it comes back to the
thread with the result or with a decision it needs.

Two things were missing here. The primary bot's standing text said nothing
about projects, only about other bots. And it asked for a yes before every
handoff, which makes one thread for everything slower than opening the
project yourself.

A client such as Harness already gives a chat tools to list projects, start
a chat in one, read it and message it, and it records which chat started a
chat. So the main bot needs no new store and no new command: it needs to be
told what it is for, and the client has to tell it when work it started
stops.

## Decision

- The primary bot's standing text calls it the user's main bot. Its
  conversation is the one thread the user keeps with it, and that
  conversation's folder is not a project. It starts each piece of work where
  the work belongs and does not do a project's work in its own thread.
- In a client's chat (`graff bot prompt`, `due --claim`) the text tells it to
  use the client's tools for projects and chats, and names Harness's:
  `list_projects`, `create_chat`, `list_chats`, `read_chat`, `send_message`.
  It starts a chat with a complete brief, on graff unless the user names
  another agent (the client's own default may be a different one), tells the
  user in one line what it started and where, and ends its turn. The client puts a message into
  its thread when that chat finishes, asks a question or fails (Harness
  does), and it reports the result then. graff sends nothing itself.
- It starts work without asking when the request is clear. It asks when more
  than one project could be meant. Publishing, sending, paying and deleting
  stay the user's: it has the chat prepare the step and stop.
- In a headless run (`graff bot run`) it has no way into another folder. It
  says which project the work belongs in and gives the command that starts
  it there.
- Single-job bots stay, as helpers. The text lists them, and the main bot
  hands a request to the one whose job it is and says that it did. It offers
  a new bot when the user keeps asking for the same kind of work, and
  creates one only after a yes.
- It keeps what it learns about the user's projects in its memory.
- The store does not change. `primary` in `bot.json` is still the flag, and
  at most one bot has it.

## Consequences

- All of this is text given to a model. Nothing in graff stops the main bot
  from doing a project's work in its own thread, or makes it stop before a
  step that cannot be undone. A started chat's own approvals are the real
  limit, and a client that needs more enforces it where the chat starts.
- The handoff no longer waits for a yes (it did under ADR 0334). The cost is
  a run the user did not expect when the main bot misreads a request; the
  run is an ordinary chat they can see, stop and answer.
- graff's text names one client's tools. A second client with different tool
  names needs its own line here, or a way to pass its names in.
- What the main bot has in progress is not recorded by graff. A client reads
  it from the chats the main bot's conversation started.
- The main bot ends its turn after starting work, on the promise that it
  will be told. A client that does not tell it leaves the thread silent, and
  its text should not be used there as it is.
