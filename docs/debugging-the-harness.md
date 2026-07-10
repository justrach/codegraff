# Debugging the harness — a latency & correctness playbook

How we chase down "why is graff slow / wrong here" bugs, distilled from real sessions
(most recently #117, the first-turn latency hunt that found *three* stacked synchronous
calls, and the 💩-spinner hunt that exposed non-representative testing).

## The one core lesson
Almost every "graff feels slow" bug is the **main thread blocking on a network or model
round-trip that should run in the background.** Zig's `io.async` makes overlapping
trivial — so the bug is nearly always a stray `.await(io)` / join sitting on the critical
path. Find it, move it off the path, apply the result somewhere free.

## 1. Measure the RIGHT path
- **Interactive ≠ oneshot.** `graff -p` skips the TUI header/card, so it misses the
  session-title call, the card render, etc. For anything the user feels *interactively*,
  drive a real PTY. `scripts/pty-debug.py` provides ordered command/key/expect actions
  over the shared `scripts/pty_harness.py`; `test-pty-spinner.py` and
  `test-pty-repl.py` exercise the same driver in CI. Oneshot benchmarks hid the entire
  title-gen call in #117.
- **Split the phases.** `time-to-prompt` (startup) and `time-to-first-response` (the turn)
  have completely different culprits. Profile them separately or you'll fix the wrong one.

### Agent-friendly PTY debugger

Build once, then describe the terminal interaction in command-line order:

```bash
zig build
scripts/pty-debug.py --bin zig-out/bin/graff --cwd /tmp \
  --arg --model --arg gpt-5.6-sol \
  --cmd '/effort xhigh' \
  --expect 'reasoning effort: Extra high' \
  --expect-prompt
```

Full-screen pickers can be driven with real key sequences:

```bash
scripts/pty-debug.py --bin zig-out/bin/graff \
  --cmd /effort --expect 'Reasoning level for' \
  --key down --key enter --expect 'reasoning effort:'
```

Useful debugging options:

- `--raw-out /tmp/graff.pty` preserves exact ANSI, alternate-screen, and cursor bytes.
- `--text-out /tmp/graff.txt` writes the cleaned transcript agents normally want to inspect.
- `--rows 24 --cols 80` reproduces wrapping, clipping, and picker-layout bugs at an exact
  terminal size (the deterministic default is 40×120).
- `--env KEY=VALUE` / `--unset KEY` isolate feature flags, auth, and inherited shell state.
- `--no-color` intentionally tests the promptless line-oriented fallback and implies
  `--no-ready`; normal runs force a real `TERM` and unset `NO_COLOR` so a CI/agent shell
  cannot silently disable the TUI.
- Every expectation has a timeout and only matches output produced after the most recent
  input action, so stale startup text cannot create a false pass while several assertions
  can still inspect one terminal redraw.

## 2. Isolate with toggles
Bisect by flipping one thing at a time and re-timing:
- `GRAFF_FLEET=off` — drops the fleet `pullElites` GET.
- `--no-telemetry` — empties the telemetry endpoint (and anything gated on it, incl. the
  fleet pull and the end-of-session flush).
- Strip a companion from `PATH` (e.g. `codedbpro`) — skips its MCP connect.
- `env -i HOME=/tmp/empty LMSTUDIO_API_KEY=local` — strips real auth/Codex and points at a
  local (non-dialing) provider, isolating startup from the model call.

Whichever toggle collapses the time is your culprit.

## 3. Find where the main thread blocks
On macOS, `sample <pid>` during the slow window. The tell: the main thread parked in
`Io.Threaded.Thread.futexWait` while a worker is in `crypto.tls.Client.readVec` /
`http.Client.connect` — a synchronous network call the main thread is waiting on.

## 4. Read the call site
Find the `.await(io)` / join on the critical path. Real ones found this way:
- `pullElites` (fleet `GET /v1/elites`) joined at the top of `runTurn` → blocked the turn.
- `titleTask` (AI session-title summarize) `await`ed before the card *and* the response
  (#91) → a whole extra model round-trip in front of turn 1.

## 5. The fix pattern — background + apply later
1. Spawn with `io.async(fn, .{args})` → a `Future`. (`arena.dupe` any stack-buffer args;
   the task outlives the frame.)
2. **Do not await it on the critical path.** Proceed with a fast fallback:
   `titleFromPrompt` instead of the AI summary; the baked agent types instead of fleet
   champions.
3. **Apply the result where it's free:** a *redrawable* surface (the OSC window title,
   never the scrolled-past printed card) or the **next** turn (the post-turn handler).
4. **It's safe to overlap your turn's request** — the single shared `std.http.Client` is
   already hit concurrently by parallel subagents, so one more background call is fine.

## 6. Verify like you mean it
- **Mutation-test the guard.** Reintroduce the bug and confirm the *exact* test reddens.
  A green suite that doesn't fail when you break the code proves nothing — that blind spot
  is how the runtime-built 💩 spinner survived `strings`/`grep` for hours.
- **Representative > surface.** Scan rendered bytes from a real PTY, hit a real-socket
  mock — not `strings`, not a frame-fn called in isolation (which can't see a
  startup-gated override).
- Let `ci.yml` gate it: `zig build`, `zig fmt --check`, `zig build test`, the JSON
  live-control test, the **PTY anti-stealth scan**, and **SDK-drift regen** (CI was red for
  the whole history once because a model/tool landed without regenerating `sdk/`).

## Traps that cost real time
- **Prompt caching neutralizes tool-list size.** With ~99% cached input (`9216/9289 in`),
  "load fewer tools" saves ~0 per request — only the cold first request. Chase blocking
  calls, not prompt bytes.
- **`-p` hides the TUI.** The title-gen call was invisible to every oneshot benchmark.
- **Atomic install only.** `mv` a freshly-signed binary onto a new inode; never `cp` over
  a running one — the kernel SIGKILLs the next exec (exit 137). `install.sh place_bin`
  already does this; don't hand-roll a `cp`.
