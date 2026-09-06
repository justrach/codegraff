# Remote control: security model

What remote control can and cannot do, who can make it do it, and the
bounds each side enforces. Companion to [remote-control.md](remote-control.md).

## What is at stake

A machine running `graff remote-control` will run turns on request, and a
turn can run tools: read and edit files, run commands. Whoever can reach the
machine through the relay can do what a person at its keyboard could do,
within what that person allowed. So the question is who can reach it.

## Who can reach a machine

- Only a Codegraff key with the **`remote` scope**, on the **same account**
  the machine signed in with. `graff login` keys carry it; dashboard keys
  get it only when the person issuing the key turns it on. A plain `api`
  key (the kind that ships inside a product) can never reach a machine, and
  neither can a `sessions` key (synced history is a different grant).
- Revoking the key ends the pipe: the machine's next poll is refused and it
  exits, telling you to sign in again.
- The relay is per account. A machine cannot be listed, created on, or
  driven from another account, and the relay never accepts an inbound
  connection to the machine; the machine only executes what arrives on the
  connection it opened.

## What the machine itself enforces

The relay carries requests; the machine is the last word.

- **Unattended sessions are the machine's call.** A viewer cannot start a
  `yolo` session unless the machine was started with `graff remote-control
  --yolo`. Without it, such a request is refused with an explanation, and
  sessions run with the normal tool approvals.
- The same flags that shape `graff serve` sessions (`--model`,
  `--system-prompt`, `--max-tool-calls`, ...) set the defaults for remote
  sessions and are chosen on the machine, not by the viewer.
- Command and session ids are validated before they touch the filesystem:
  a session name is one path segment under `.graff/`, never a walk out of it.
- Nothing is bound. There is no port, no LAN exposure, no pairing secret to
  type; the only credential is the account key already on the machine.

## What the relay enforces

- Request bodies and event lines are capped; an oversized line reaches
  viewers as an envelope-only stub (the machine's tape keeps the full line).
- Each session's recent window is bounded in bytes and count, the number of
  windows is bounded, and windows are freed when a session closes.
- A machine's command queue is bounded; past it a viewer gets 429.
- Only the machine that owns a session may push its events or answer its
  commands, even within one account.
- Results nobody is waiting for are not kept.

## Residual risks and follow-ups

- A `remote` key is as powerful as the machines it can reach. Treat it like
  an SSH key: never embed it, revoke it when a device is lost.
- Per-session, short-lived viewer tokens (shareable links) are not built
  yet; today every viewer holds the account key.
- The relay and the machine trust the gateway's TLS; `GRAFF_REMOTE_BASE` is
  a development knob and should never point at a plain-HTTP host you do not
  control.
