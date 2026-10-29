# 0302. SSE idle watchdogs follow body-byte progress

Status: accepted

## Context

An SSE event can contain a large completed output item rather than small text
fragments. Racing a whole newline-delimited read against an inactivity timer
mistakes a steadily arriving partial event for a silent connection (#1686).
Reconnect then discards progress and repeats the request. The existing prose,
reasoning and reconnect policies choose the idle allowance; they do not make a
missing newline evidence of missing bytes.

## Decision

Keep those allowances and cancellation rules. During each line read, publish
body progress through an atomic timestamp and expire inactivity only when that
progress stops. The HTTP/1 delimiter reader uses an unbuffered forwarding writer;
the HTTP/2 reader consumes `LineStream.readChunk`, preserving bytes after a
newline for its next read. HTTP/2 control traffic is not response-body progress.
Buffers remain owned by the read task, and cancellation joins it before cleanup.

Bound an unfinished event separately: at most 128 MiB and fifteen minutes of
assembly. An explicitly longer idle allowance also raises the assembly deadline,
so the new deadline does not shorten an explicit silence setting. These bounds
prevent oversized events and indefinitely dripping partial lines from disabling
recovery. Event-size and assembly-deadline failures have distinct errors and are
not replayed as transient network failures. Normal completion, delayed usage
trailers, and genuine silence retain their existing outcomes.

## Consequences

A large event may take longer than one idle allowance while its body continues
to arrive, without reconnecting. HTTP/2 reports body progress at DATA-chunk
boundaries exposed by the pinned transport; no dependency change or raw
connection/control-frame activity is needed. Synthetic HTTP/1 and HTTP/2 tests
cover flowing and stopped partial events; `sse-partial-line-byte-progress` runs
the actual engine against a fragmented scripted response and asserts one request.
