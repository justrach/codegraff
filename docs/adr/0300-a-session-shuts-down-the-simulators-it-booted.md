# 0300. A session shuts down the simulators it booted

Status: accepted 2026-10-22

## Context

Agents verify iOS work with ad-hoc shell commands (`xcrun simctl boot`,
`xcodebuild test`, a project's run script). A device booted that way outlives
the command and the session: stopping the command's process group does not
shut a CoreSimulator device down. Finished runs left devices booted, their
apps running and the Simulator app open, and parallel verification tasks
accumulated them (#407). The in-repo iOS scripts that once guarded this have
left the repository.

## Decision

`sim_ledger.zig` brackets each shell command that looks like simulator work
with two `simctl list devices booted` snapshots. A device booted after the
command that was not booted before it belongs to the session and is recorded
under `~/.codegraff/simulators/<udid>/` with a lease naming the process
(`proc_identity` records). When the session ends, the job reaper shuts down
every recorded device that no live graff process holds a lease on, then
removes its record.

- A device already booted before the command is never recorded, so the
  user's own devices are left alone.
- Another graff session that runs simulator commands while a recorded device
  is booted takes its own lease; the last session to end shuts it down.
- A session that died leaves only dead leases; the next session to end shuts
  its devices down.
- The Simulator app is quit only when this session started it and no device
  remains booted.
- `GRAFF_KEEP_SIMULATORS=1` turns the ledger off.

## Consequences

Sessions that run simulator commands pay two `simctl` runs per such command
and a shutdown per device at exit. A snapshot cannot tell who booted a
device: one the user boots while a bracketed command runs is attributed to
the session, and a command with no simulator or iOS word in it (a script
named for something else) is not bracketed. Apps launched on a device the
user had already booted are not terminated.
