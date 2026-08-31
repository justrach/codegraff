# 0055. Lean `-p` bash auto-backgrounds at 15s

Status: accepted 2026-08-29

#675 numbered this 0051. 282 already owns 0051 (sandbox teleport / GC);
this cut remaps the record.

## Context

ADR 0026 waits 120s before promoting root foreground bash: a human
may be watching a long compile. Lean `-p` has no human. After ADR
0054 killed DeepSeek CoT dumps, SWE wall was **5/6 in 353s** —
`json-stream` sat **120s** on `python3 test_json_stream.py`,
`cookie-store` **71s** on another hang. API calls were 2–13s.
OpenCode’s 261s lead was those waits, not catalog or heap.

## Decision

Unattended + lean (`-p` default) auto-backgrounds at **15s**. The
process is not killed (ADR 0026). An explicit `timeout` still wins.
Interactive / `--no-lean` stay 120s. Do not steal Pi’s catalog.

## Consequences

A hung test returns a job id in 15s; the model can edit or
`bash_kill`. A 20-minute compile on `-p` also backgrounds at 15s —
`bash_output(wait_ms>0)` still waits for exit (ADR 0010).

## Confirm (2026-08-29)

`run-20260829-075402`, thinking off + 15s bash. cookie-store **30s**
(was 114s / 71s hang). json-stream **22s** (was 155s / 120s hang).
Suite 4/6 in **143s** / 91M — `validated` died on a concurrent
reservation / empty balance, not the wait. Same `label-sort` miss.
0-token follow-ups after that are burnt gateway. Do not stitch.
