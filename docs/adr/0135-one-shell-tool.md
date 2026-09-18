# 0135. One `shell` tool: run, output, kill

Status: accepted 2026-09-15

## Context

The catalog advertised `bash`, `bash_output`, and `bash_kill` as three tools
for one job table. fx ships a single `shell` tool with `action=run|interact|stop`.
Twenty-nine native names is already a lot; the split taught models to poll.

fx `interact` writes into a PTY session. Graff jobs spawn with stdin ignored
(`jobs.spawnJobOpts`). The composer already queues mid-turn follow-ups
(`queueSteerLine` / `drainSteer`).

## Decision

Advertise one `shell` tool with `action=run|output|kill`. Keep
`bash` / `bash_output` / `bash_kill` as dispatch aliases so rlm `bash()`,
`!cmd`, and in-flight sessions still run. Refuse `action=interact`: it is
not a PTY. Do not change the 120s / 15s auto-background waits (ADR 0026,
ADR 0055).

User typing while a command runs stays steer — it does not become process
stdin.

## Consequences

The advertised catalog shrinks by two names. The tool-catalog kernel cube
is regenerated. `--no-local-tools` still blocks the aliases.

Rejected: stealing fx's PTY `interact`, hiding the aliases from dispatch,
and shortening the foreground wait to fx's 30s yield cap.
