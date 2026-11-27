# 0357. The managed MCP service installs transactionally and has its own lifecycle verbs

Status: accepted 2026-11-27

## Context

`graff mcp install` (ADR 0131) runs the shared HTTP MCP listener as a
launchd agent or user systemd unit with `RunAtLoad`/`KeepAlive`. Two gaps:

- The installer wrote and loaded the replacement job before its readiness
  probe and raised with no undo when the probe failed (#1929). A failed first
  install left a job that launchd kept relaunching against a taken port; a
  failed port change stopped the working service and left the job on the new
  port while `settings.json` and every client entry kept the old one.
- Nothing showed whether the service was installed or running, and stopping
  it meant `launchctl bootout` plus deleting the plist by hand: ending the
  process only got it relaunched (#1928).

`graff mcp status` already reports the MCP servers graff *consumes*
(ADR 0280), so the service's verbs cannot reuse that name.

## Decision

- **Install is a transaction.** Before writing anything the installer
  snapshots the managed job (its bytes, whether it is running, its port).
  If loading or readiness fails, or the run is interrupted, it rolls back,
  trying every step even when one fails: a first install unloads and deletes
  the job it created; a reconfigure writes the previous job file back byte for
  byte and restarts it only if it was running (a stopped one is disabled
  again). Settings and client entries are written only after readiness, so
  they never name a port the job does not serve. The error says what was put
  back; when a rollback step fails it quotes the service manager's stderr and
  gives the command that finishes the job.
- **Lifecycle verbs live under `graff mcp service`:** `status [--json]`
  (the default), `stop`, `start`, `uninstall`, with `graff mcp uninstall` as
  the mirror of `install`. They run the same bundled installer script as
  `install`, so there is one implementation of launchd/systemd handling,
  the managed-file check and the install lock.
- **`stop` is persistent:** it unloads and disables the job (`launchctl
  disable`, `systemctl --user disable --now`), so it does not return at the
  next login. `start` and `install` enable it again.
- **`uninstall` removes only the job.** It keeps the token and settings (a
  later install comes back on the same port, with client entries still
  valid) and never edits client configs; it names the files that still hold
  a `codegraff` entry. `stop` and `uninstall` on nothing installed succeed.
- **No confirmation prompt.** Each verb is a command a person runs; `install`
  has none, and `stop`/`uninstall` are undone by `start`/`install`. No model
  tool or slash command is added, so ADR 0085's rule that model output is not
  authorization is not engaged.
- **A job file graff did not write is reported and never touched.**

## Consequences

The installer script grows a `--service` entry point and stays the only code
that talks to launchd/systemd; tests drive it through recording fakes and
never load a real job. Linux without user systemd (the listener started
directly) gets a status report only. The opt-in idle timeout #1928 suggests
is not built: zero connected clients does not mean nobody expects the
service, and the listener would have to track activity, which is a daemon
change of its own.
