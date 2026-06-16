# Zig 0.17 port plan

**Status: not started — graff stays on Zig 0.16 (stable).** Revisit when **0.17.0
releases**. Do **not** pin to a `0.17.0-dev` nightly: it's a moving target with
at least one core operator mid-refactor (see below).

This plan is grounded in a real dry run against `0.17.0-dev.864+3deb86baf`
(June 2026): a throwaway `git worktree` built against `zigup run master`, so the
default toolchain was never touched.

---

## TL;DR

- The scary part — graff's **182 `std.Io` uses** (the async I/O layer) — showed
  **no breakage** in everything that compiled. That's the load-bearing
  dependency and it looks stable 0.16 → 0.17.
- What broke was **mechanical**: one Build-API rename, one removed stdlib
  helper, and a language-level change to the `**` array-repeat operator.
- Estimated effort once 0.17.0 is stable: **an afternoon**, assuming `std.Io`
  holds (it must be re-verified — the dry run couldn't get past `**` to fully
  exercise it).

---

## How to run the port (procedure)

1. `zigup fetch 0.17.0` (the stable release, not `master`).
2. `git worktree add --detach /tmp/graff017 HEAD` — isolate; never change the
   default `zig`. Build with `zigup run 0.17.0 build`.
3. Fix errors in waves (each `zig build` stops early; fix the surfaced batch,
   rebuild, repeat). Categories below.
4. When it compiles: `zigup run 0.17.0 build test`, then
   `python3 scripts/test-json-controls.py`, then a GUI smoke test (the GUI
   shells out to the `graff` binary, so only the harness rebuild matters).
5. Only then bump the default toolchain / README badge and merge.

Rollback is free: `zigup` keeps 0.16 installed; nothing in the port touches the
default until the last step.

---

## Confirmed breaking changes + fixes

### 1. Build API: `b.build_root` removed
`build.zig:13` uses `b.build_root.path orelse "."` for the `git describe`
version stamp. The `build_root` field is gone.
- **Fix:** `b.path(".")`/`b.pathFromRoot(".")` (verify the exact accessor on the
  stable release), or just `"."` — `zig build` already runs from the project
  root, so `git -C "."` is correct.

### 2. `std.ascii.indexOfIgnoreCase` removed
0.17 keeps `std.ascii.eqlIgnoreCase` / `startsWithIgnoreCase` but drops
`indexOfIgnoreCase`. graff calls it at:
- `src/main.zig:357` — `/models` name filter
- `src/main.zig:4214` — the `ultracode` codeword detector
- `src/main.zig:4521` — a substring helper
- **Fix:** add a small portable shim (compiles on 0.16 too), then point the
  three call sites at it:
  ```zig
  fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
      if (needle.len == 0) return 0;
      if (needle.len > haystack.len) return null;
      var i: usize = 0;
      while (i + needle.len <= haystack.len) : (i += 1)
          if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
      return null;
  }
  ```

### 3. `**` array-repeat operator — language change in flight ⚠️
In `0.17.0-dev.864`, **every** form of `arr ** n` failed: the spaced form
(` ** `) trips a new "binary operator has whitespace on one side but not the
other" lint; the tight form (`**n`) parses the right operand as a *type*
(`expected type, found comptime_int`). 0.17's own std uses `**` **zero** times —
they've purged it. So this is a deliberate refactor, not a regression, and its
final shape won't be known until 0.17.0 ships.
- graff sites: `src/main.zig:2230` (`g_skill_disabled`), `:11192` (`keys`
  init), and `:10968` (a test's `"─" ** N` separators).
- **Fix:** rewrite each to an explicit comptime construction, e.g.
  ```zig
  var g_skill_disabled = blk: {
      var a: [skills_registry.len]bool = undefined;
      for (&a) |*x| x.* = false;
      break :blk a;
  };
  ```
  Confirm against the stable release whether `**` survives in some form before
  committing the rewrite; the comptime-loop form is portable regardless.

### 4. Stricter binary-operator whitespace lint
New in 0.17. Cosmetic — `zig fmt` against the new compiler should resolve most;
the only graff collisions are the `**` sites above.

---

## Unverified — must re-check during the real port

The dry run was blocked at the `**` errors before deep compilation, so these are
**assumptions to validate**, not confirmed-clean:

- **`std.Io` (182 uses)** — the big one. Re-verify: `Io.Select` +
  `concurrent`/`await`/`cancelDiscard` (post watchdogs, the stream stall
  watchdog), `io.sleep`/`io.async`, `Io.Writer`/`Io.Reader`
  (`streamDelimiterEnding`, `takeDelimiter`, `readerDecompressing`), `Io.Dir`
  (`createDir`, `readFileAlloc`, `createFile`), `Io.net` (the OAuth callback
  server), `Io.Duration`.
- **`std.http.Client`** — `client.request`/`fetch`, `receiveHead`, the
  `.headers`/`.extra_headers` request options, connection-pool `closing`.
- **`std.json`** — `Stringify`, `parseFromSliceLeaky`, `ObjectMap`/`Value` (used
  everywhere).
- **`std.crypto` / `std.base64`** — OAuth (codex PKCE, kimi device flow).
- `src/mcp.zig` — stdio pipes, `ArrayList` API.

If any of these shifted, effort grows from "an afternoon" accordingly — `std.Io`
churn is the only thing that would make this a multi-day port.

---

## Validation checklist (port is done when all pass)

- [ ] `zig build` clean on 0.17.0
- [ ] `zig build test` — all unit tests
- [ ] `python3 scripts/test-json-controls.py` — 15/15
- [ ] real streaming call (kimi/deepseek) + the stream stall watchdog still fire
- [ ] GUI smoke: new chat, a tool call, an image paste
- [ ] README badge + any `build.zig.zon` min-version bumped **last**
