# Remote control

Drive the graff sessions on one machine from anywhere your Codegraff login
is valid: a laptop at home from the office, a build box from your phone, a
cloud sandbox from the CLI. The machine never opens a port. It dials out.

```
# on the machine that runs the agent
graff login                 # once
graff remote-control        # stays in the foreground; Ctrl-C disconnects

# anywhere else, same login
graff remote                # sessions on every machine running remote-control
graff remote new nightly    # a durable session on that machine
graff remote send nightly "run the tests and fix what fails"
graff remote tail nightly   # watch it work
graff remote close nightly  # end the process; its history stays on the machine
```

## How it works

`graff remote-control` is [`graff serve`](embedding.md) with no listener. It
runs the same pool of `graff --json` children, keeps the same durable named
sessions (`--resume <id>`, autosaved after every turn) and the same
seq-stamped event tape under `.graff/serve/`. Instead of accepting
connections it:

1. registers with the gateway using the `graff login` key, as a device with
   a stable id (`~/.graff/remote-device.json`), a name (`--name`, default
   hostname) and its working directory;
2. long-polls the account's relay for commands, sending its live sessions
   (id, idle/busy, last seq) with every poll;
3. runs each command exactly as serve would (create a session, one protocol
   request, close) and streams the resulting event lines back as they land
   on the local tape.

The relay keeps one object per account: the registered machines, their
sessions, queued commands and a bounded recent window of each session's
events. The machine keeps the complete tape. A viewer whose cursor falls
behind the window sends `reattach` and gets a replay from the machine.

Nothing is ever pushed *to* the machine. It only executes what arrives on
the connection it opened, and revoking the key ends the pipe.

## Commands

| command | what it does |
|---|---|
| `graff remote-control [--name n]` | run the supervisor on this machine; `--model`, `--yolo`, `--system-prompt` and the other serve flags set the defaults for its sessions |
| `graff remote` / `graff remote sessions` | sessions on every machine, with state and machine name |
| `graff remote agents` | the machines themselves, online or not |
| `graff remote new [session] [agent]` | create (or resume) a session; with one machine online the agent is implied; `--model` / `--yolo` apply |
| `graff remote send <session> <text>` | one turn; events stream back until it ends |
| `graff remote answer <session> <text>` | answer the session's `ask_user` prompt |
| `graff remote tail <session> [from]` | watch a session's events from a cursor (default: the recent window) |
| `graff remote cancel <session>` | cancel the in-flight turn |
| `graff remote close <session>` | end the session process; `graff remote new <session>` resumes it later |

## Auth

- Machine → gateway: the `graff login` device key. Remote control requires
  the `sessions` scope (device keys have it; dashboard keys opt in), so a
  plain `api` key embedded in a product can never drive anyone's machine.
- Viewer → gateway: the same account login.
- Gateway → machine: nothing inbound.

`CODEGRAFF_API_KEY` overrides the login file on either side.
`GRAFF_REMOTE_BASE` points both at a different gateway (a local one while
developing the relay).

## Wire

The viewer API is the gateway's `/v1/remote/*`, bearer-authenticated:

```
GET    /v1/remote/agents                       machines + their sessions
GET    /v1/remote/sessions                     sessions across machines
POST   /v1/remote/agents/:agent/sessions       create; body = serve's create options
POST   /v1/remote/sessions/:id                 one protocol request; 202 {command_id, from}
GET    /v1/remote/sessions/:id/events?from=N&wait=MS   long-poll: {events, next_from, in_flight, gap}
DELETE /v1/remote/sessions/:id                 close
```

Events are the NDJSON lines serve streams (`text`, `reasoning`, `tool_call`,
`ask_user`, `turn`, `error`, …), each with its `seq`, so a client written
against `graff serve` needs only a base URL change plus the cursor loop.
`gap: true` means the window no longer starts at your cursor: send
`{"type":"reattach","resume_from":N}` and tail again. Event lines above
256 KiB reach the relay as an envelope-only stub (`truncated: true`); the
full line is on the machine's tape and a `reattach` replays it.

## Verifying from another computer

`scripts/e2e-remote-control.py` does it without a second laptop: it spins
up a gateway sandbox (a cloud Linux VM on your account), puts a Linux build
of graff in it, and from there lists this machine, creates a session on it
and asks the session to run `hostname`. The answer must name this machine,
not the VM. Same commands work from any real computer after `graff login`.

## Not yet

- Sessions this supervisor did not start (a TUI you left open) are not
  listed; only its own children are. See #469 for the device-local bridge.
- Per-session short-lived viewer tokens (shareable links).
- ACP `session/list` / `session/load` over relayed sessions.
