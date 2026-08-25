# 0025. io_uring is not the process Io; ublk is not ours

Status: accepted 2026-08-25

## Context

A follow-up asked whether [spec-ptc](https://github.com/alexzhang13/spec-ptc)
is already in this build, and whether
[LWN 903855](https://lwn.net/Articles/903855/) (ublk: an io_uring user-space
block driver) plus Zig's `std.Io.Uring` backend would shrink the binary or
SWE wall.

spec-ptc is already the default loop (ADR 0022): `src/spec_ptc.zig` segments
streaming `rlm` source; `rlm.feedLive` / `rlm_spec` launch closed literal
calls as the `code` argument streams; `runScript` claims the futures. Host
functions are graff tools (`read_file`, `edit_file`, `write_file`, `codedb`,
`bash`, `webfetch`) plus `sleep_ms` / `llm_query` / `print` / `subagent`.
`--old` / `--no-rlm` restore structured-only. This is Zig, not the Python
shadow REPL and not Prime's IPython kernel.

ublk is a kernel `/dev/ublk-control` protocol for implementing *block
devices* in user space (null/loop). Graff is a coding harness. Wiring ublk
would add a storage driver, not a faster `read_file`.

Zig 0.17's `std.process.Init` still constructs `std.Io.Threaded`
(`lib/std/start.zig`). `std.Io.Evented` on Linux *is* `Io/Uring.zig` (fiber
stacks, 512 KiB idle). `src/proc_identity.zig` already avoids `Io.Dir` for
`/proc/<pid>/stat` because the io_uring test backend can EBADF and panic.

## Decision

Keep process Io as Zig's default `Threaded`. Do not switch `main` to
`std.Io.Uring` / Evented. Do not implement ublk. Linux `io_uring` stays
available for a hand probe (`scripts/io-uring-probe.zig`), not the REPL,
HTTP client, or TTY.

## Consequences

A 64×4 KiB batch (200 rounds) on this host (`zig run
scripts/io-uring-probe.zig`, two reps): serial `pread` **20 µs/round**,
io_uring submit-and-wait **75 µs/round** (~3.7× slower — setup + enter
dominate small reads). SWE is 41 model turns vs grok's 31; the prefix is
already ~5.7k vs ~5.1k per call. An io_uring process Io would also break
Windows, fight the TTY, and re-expose the `/proc` EBADF panic. Revisit
only if a measured Linux-only path (MCP stdio fan-out, large parallel
walks) shows Threaded as the wall.
