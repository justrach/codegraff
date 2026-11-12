//! Boot prewarm: run the companion handshake (`codedb-pro --mcp`) while the
//! rest of a one-shot boots, and join it where `connectCompanion` would have
//! called `addServer` (ADR 0337; formal/BootPrewarm.tla).
//!
//! `-p` connects the companion synchronously (ADR 0230 defers only
//! interactive and ACP sessions), so its spawn + handshake used to sit in
//! series with credentials, the plugin scan and the MCP merge. Only the case
//! where the result is known in advance prewarms: lean `-p` (not a
//! subcommand), no `-w`, no project `.mcp.json` and no registry env override. There the
//! registry is the empty one (`oneshotSkipsImportedMcp`), so the companion is
//! the only server that can connect and the adopted outcome fills exactly the
//! slot `addServer` would have. Every other case keeps the serial path.
//!
//! One slot, touched only by the boot thread: `start` in `main` once
//! credentials resolved and the banner settled the cwd (a run that exits
//! there spawns nothing, as before), `take` in `connectCompanion` (await,
//! then merge under the registry mutex, ADR 0197), `discard` (stop, join,
//! tear down) when it is not adopted, on any return before the registry's
//! teardown, and `stopAtExit` at that teardown. A cwd or registry-setting
//! mismatch discards and the inline `addServer` runs; an attempt that ran to
//! a result is the one attempt, its error included. The worker owns copies of
//! everything it reads: `std.process.Init` frees `environ_map` before it
//! joins worker threads.
//!
//! The join is bounded (ADR 0339). A companion that is silent for the stdio
//! probe's 5 s and the handshake's 15 s held the first request for ~20.1 s;
//! `take` now waits `default_budget_ms` (250 ms, the ACP
//! `attach_budget_ms` precedent) and then returns, leaving the attempt
//! running: it merges into that registry the moment it lands, exactly where a
//! deferred start would. `GRAFF_MCP_COMPANION_BOOT_MS` is the knob; it is
//! read here, not in `mcp_rpc.applyHandshakeTimeoutEnv`, which
//! `oneshotSkipsImportedMcp` skips on this path. A slow-and-cold companion
//! can therefore miss the first catalog, and a late merge changes the catalog
//! mid-run (ADR 0221) — the two costs of not stalling.
//!
//! Reporting is exact on both sides of the budget, and about who ended the
//! attempt. A failure that lands before the budget is `take`'s error,
//! `error.McpClosed` included; one that lands after it has no request left to
//! return to, so the worker records it (`lateOutcome` / `lateError`) and names
//! it on stderr — `-p` prints no notices of its own — and `take` reports
//! `.late`, never `.connected`. A stop the exit path asked for is neither: it
//! ends the child on both platforms (`Watch.signal`) before it joins the
//! worker, and the `McpClosed` that kill produces is the run ending, so the
//! attempt publishes `.stopped` and says nothing. Before that distinction a
//! healthy companion printed "failed to connect" on its way out of a normal
//! exit (ADR 0339). The exit path costs the kill, not the probe plus handshake
//! caps.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const mcp = @import("mcp.zig");
const mcp_boot = @import("mcp_boot.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const skills = @import("skills.zig");

/// What `addServer(name, command, args)` would start, plus the registry
/// settings `startServer` reads. `take` adopts only when the live registry
/// carries the same settings.
pub const Spec = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    home: []const u8 = "",
    stdio_probe: bool = true,
    lazy_stdio: bool = true,
    show_diagnostics: bool = true,
};

const Joined = struct { outcome: mcp_boot.StartOutcome = .{}, err: ?anyerror = null };

/// What the attempt did (ADR 0339): merged into the registry it was handed,
/// dropped because the name connected meanwhile (#505), failed — or `.stopped`,
/// which is the exit path's own doing and no failure at all. `.none` means it
/// has not landed yet — or nobody handed it a registry.
pub const LateOutcome = enum { none, merged, duplicate, failed, stopped };

/// What `take` / `connect` report. `.connected`: the catalog is in the
/// registry. `.late`: the attempt is still running with this registry as its
/// merge target — not a catalog, and not a failure either, so no caller may
/// report it as connected.
pub const Adopted = enum { connected, late };

const Slot = struct {
    future: Io.Future(Joined),
    owned: std.heap.ArenaAllocator,
    spec: Spec,
    watch: *Watch,
    /// `budgetMs` of the environment `main` started this run with.
    budget_ms: u32 = default_budget_ms,
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
};

var slot: ?Slot = null;

/// The worker's live child, so `discard` can end a handshake in progress by
/// stopping the child: the read sees end of stream, the attempt fails and
/// cleans up on its own, and `discard` joins it. The worker is never
/// cancelled: a cancel that lands inside the bounded handshake's `Io.Select`
/// returns before the select's read task stops, and that task outlives its
/// frame. The worker publishes each child it spawns (`Registry.spawnStdio`)
/// and forgets it before it reaps it, both under `lock`, so `stop` only ever
/// signals a child nobody has waited on: its pid cannot have been reused.
pub const Watch = struct {
    lock: std.atomic.Mutex = .unlocked,
    stopping: bool = false,
    child: ?std.process.Child.Id = null,
    /// Worker: it reached a result. Boot thread: that result is on the future
    /// for it to await, or — with `late_merge` set — already merged.
    done: bool = false,
    /// Boot thread, over budget at the join: the live registry this attempt
    /// merges into when it lands (ADR 0339). Under `lock` with `done`, so
    /// exactly one side consumes the outcome.
    late_merge: ?*mcp.Registry = null,
    /// Worker: what that attempt then did — `.none` until it lands, `.stopped`
    /// when the exit path ended it first. Under `lock`, read through `outcome`.
    late_state: LateOutcome = .none,
    /// Worker: the error a handed-off attempt ended with, when it failed.
    late_err: ?anyerror = null,
    /// Set by the worker's last write, so the join's bounded wait is a
    /// deadline on the kernel timer rather than a poll: a 2 ms sleep on this
    /// platform costs ~4 ms of overshoot apiece, which a 250 ms budget cannot
    /// afford.
    done_event: Io.Event = .unset,

    fn acquire(w: *Watch) void {
        while (!w.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Worker, right after a spawn. A child spawned after `stop` is stopped at once.
    pub fn publish(w: *Watch, id: ?std.process.Child.Id) void {
        w.acquire();
        defer w.lock.unlock();
        w.child = id;
        if (w.stopping) w.signal();
    }

    /// Worker, before it reaps the child or hands it to the consumer.
    pub fn forget(w: *Watch) void {
        w.acquire();
        defer w.lock.unlock();
        w.child = null;
    }

    /// Boot thread: end the attempt now.
    fn stop(w: *Watch) void {
        w.acquire();
        defer w.lock.unlock();
        w.stopping = true;
        w.signal();
    }

    /// End the child, not the worker. Both platforms can: POSIX has `SIGKILL`,
    /// and on Windows `Child.Id` *is* the process handle, so the same
    /// `NtTerminateProcess` `Child.kill` issues works there too. Neither waits
    /// nor frees the `Child` — the worker still owns the reap — so teardown is
    /// bounded by "the read sees end of stream", not by the 5 s probe plus the
    /// 15 s handshake. The caller holds `lock`, so the handle cannot have been
    /// reaped (and on Windows closed) underneath it.
    fn signal(w: *Watch) void {
        const id = w.child orelse return;
        switch (@import("builtin").os.tag) {
            .windows => _ = std.os.windows.ntdll.NtTerminateProcess(id, @fromBackingInt(1)),
            else => std.posix.kill(id, .KILL) catch {},
        }
    }

    /// Boot thread, at the join: publish `reg` as the merge target for an
    /// attempt still running, or report that it already finished — then the
    /// caller awaits and adopts the result itself. Write-once: it runs once per
    /// attempt and the worker takes the target under this lock, so "exactly
    /// once" is a property of the field, asserted rather than assumed.
    fn handOff(w: *Watch, reg: *mcp.Registry) bool {
        w.acquire();
        defer w.lock.unlock();
        if (w.done) return true;
        std.debug.assert(w.late_merge == null);
        w.late_merge = reg;
        return false;
    }

    /// What `settle` saw, in one critical section: the merge target the boot
    /// thread installed, and whether a stop was already requested. A stop is
    /// requested before the child is killed, so an attempt whose read returned
    /// `McpClosed` because of that kill reads `stopped` here — the run is
    /// ending, which is not the same thing as the companion failing (ADR 0339).
    const Settled = struct {
        target: ?*mcp.Registry = null,
        stopped: bool = false,
    };

    /// Worker, last write: publish the result and claim a merge target the
    /// boot thread installed while it was still running. Each attempt settles
    /// once, so the outcome is consumed exactly once: here, or by `take` /
    /// `stopAtExit` through the future.
    fn settle(w: *Watch, io: Io) Settled {
        w.acquire();
        const settled: Settled = .{ .target = w.late_merge, .stopped = w.stopping };
        w.done = true;
        w.lock.unlock();
        w.done_event.set(io); // wakes the join's bounded wait
        return settled;
    }

    /// The outcome the worker published, under the same lock as `done`.
    fn outcome(w: *Watch) LateOutcome {
        w.acquire();
        defer w.lock.unlock();
        return w.late_state;
    }

    /// Worker: publish what the handed-off attempt did. Same lock `done` uses,
    /// so a reader that waits for `lateOutcome` to leave `.none` also sees the
    /// registry in its final shape.
    fn recordLate(w: *Watch, state: LateOutcome, err: ?anyerror) void {
        w.acquire();
        defer w.lock.unlock();
        w.late_state = state;
        w.late_err = err;
    }

    fn finished(w: *Watch) bool {
        w.acquire();
        defer w.lock.unlock();
        return w.done;
    }

    fn handedOff(w: *Watch) bool {
        w.acquire();
        defer w.lock.unlock();
        return w.late_merge != null;
    }
};

/// Settings that only `Registry.init` reads. With any of them set the
/// prewarm could not match the registry, so it does not start.
const registry_env = [_][]const u8{ "GRAFF_MCP_PROBE", "GRAFF_MCP_EAGER", "GRAFF_MCP_HANDSHAKE_SECS", "GRAFF_MCP_PROBE_MS" };

/// How long `take` waits for the attempt before it leaves it running (ADR
/// 0339). The ACP `attach_budget_ms` precedent: long enough for the 50 ms
/// handshake a warm companion answers in, short enough that no first request
/// pays a silent companion's 5 s probe + 15 s handshake. Windows takes the
/// ACP figure too (the platform boots slower).
pub const default_budget_ms: u32 = if (@import("builtin").os.tag == .windows) 1_500 else 250;

/// The knob for that budget. Unset, unparsable or `0` mean the default, and
/// anything above `budget_cap_ms` is clamped to it — a typo buys the cap, never
/// the unbounded join.
pub const budget_env = "GRAFF_MCP_COMPANION_BOOT_MS";
pub const budget_cap_ms: u32 = 60_000;

pub fn budgetMs(environ_map: anytype) u32 {
    const raw = environ_map.get(budget_env) orelse return default_budget_ms;
    const v = std.fmt.parseInt(u32, raw, 10) catch return default_budget_ms;
    if (v == 0) return default_budget_ms; // 0 is "unset", not "wait forever"
    return @min(v, budget_cap_ms); // above the cap is a bound, not the default
}

/// The flag/env half of the gate: a lean one-shot that will build the empty
/// registry. Interactive and ACP sessions queue the companion instead.
pub fn wantsCompanion(flags: args.Flags, environ_map: anytype) bool {
    if (flags.oneshot_prompt == null) return false; // the prompt is the positionals; subcommands have none
    if (flags.is_subcommand or flags.worktree_flag != null) return false;
    if (!(flags.effectiveLean() or environ_map.get("GRAFF_LEAN") != null)) return false;
    for (registry_env) |k| if (environ_map.get(k) != null) return false;
    return true;
}

/// Called once credentials resolved and the cwd is final (after
/// `setupWorktreeAndBanner`). Picks the companion `connectCompanion` would
/// try first and starts it. The caller defers `discard`.
pub fn startCompanion(io: Io, gpa: Allocator, environ_map: anytype, flags: args.Flags) void {
    if (!wantsCompanion(flags, environ_map)) return;
    if (Io.Dir.cwd().access(io, ".mcp.json", .{})) |_| return else |_| {} // project servers: not the empty registry
    const path_env = environ_map.get("PATH") orelse "";
    for (skills.companion_servers) |c| {
        if (optedOut(io, c.server)) continue;
        var buf: [1024]u8 = undefined;
        if (@import("path_lookup.zig").resolve(io, path_env, c.bin, &buf) == null) continue;
        startWithin(io, gpa, .{ .name = c.server, .command = c.bin, .args = &.{"--mcp"}, .home = @import("keys_cli.zig").homeEnv(environ_map) orelse "" }, budgetMs(environ_map));
        return;
    }
}

/// `skills.loadSkillSettings` has not run yet at prewarm time; read the same
/// `{"skills": {"<server>": false}}` opt-out it will apply.
fn optedOut(io: Io, server: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data = Io.Dir.cwd().readFileAlloc(io, @import("harness_policy.zig").settings_path, a, .limited(1 << 20)) catch return false;
    return optedOutIn(a, data, server);
}

/// Pub for `boot_prewarm_tests.zig` (the opt-out test); pure, no I/O.
pub fn optedOutIn(a: Allocator, data: []const u8, server: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const section = v.object.get("skills") orelse return false;
    if (section != .object) return false;
    const entry = section.object.get(server) orelse return false;
    return entry == .bool and !entry.bool;
}

pub fn pending() bool {
    return slot != null;
}

/// Start one prewarm with the default join budget.
pub fn start(io: Io, gpa: Allocator, spec: Spec) void {
    startWithin(io, gpa, spec, default_budget_ms);
}

/// Start one prewarm, joining it for at most `budget_ms`. A second call, an
/// allocation failure or a pool with no thread to spare leaves the slot
/// empty: the consumer then runs inline.
pub fn startWithin(io: Io, gpa: Allocator, spec: Spec, budget_ms: u32) void {
    if (slot != null) return;
    var owned = std.heap.ArenaAllocator.init(gpa);
    const copy = dupSpec(owned.allocator(), spec) catch {
        owned.deinit();
        return;
    };
    const watch = owned.allocator().create(Watch) catch {
        owned.deinit();
        return;
    };
    watch.* = .{};
    var s: Slot = .{ .future = undefined, .owned = owned, .spec = copy, .watch = watch, .budget_ms = budget_ms };
    s.cwd_len = cwdKey(io, &s.cwd);
    // Never `io.async`: run inline it would serialize the boot again.
    s.future = io.concurrent(connectTask, .{ gpa, io, copy, watch }) catch {
        s.owned.deinit();
        return;
    };
    slot = s;
}

fn dupSpec(a: Allocator, spec: Spec) Allocator.Error!Spec {
    var copy = spec;
    copy.name = try a.dupe(u8, spec.name);
    copy.command = try a.dupe(u8, spec.command);
    copy.home = try a.dupe(u8, spec.home);
    const list = try a.alloc([]const u8, spec.args.len);
    for (spec.args, list) |src, *dst| dst.* = try a.dupe(u8, src);
    copy.args = list;
    return copy;
}

fn cwdKey(io: Io, buf: *[std.fs.max_path_bytes]u8) usize {
    return Io.Dir.cwd().realPath(io, buf) catch 0;
}

/// The recorded cwd key `take` compares against. `boot_prewarm_tests.zig` sets
/// a different one to exercise the mismatch: a test cannot move the process
/// cwd under a live attempt without racing every other test.
pub fn testSetCwdKey(len: usize) void {
    if (slot) |*s| s.cwd_len = len;
}

/// The worker: `addServer`'s connect on a task-local registry (the pattern
/// `mcp_start.attempt` uses), one attempt, no retry, no failure record.
fn connectTask(gpa: Allocator, io: Io, spec: Spec, watch: *Watch) Joined {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const outcome = connectInto(gpa, io, spec, watch, &arena_state) catch |err| {
        arena_state.deinit();
        const settled = watch.settle(io);
        if (settled.stopped) {
            // Teardown ended this attempt because the run is ending: this
            // `McpClosed` is the stop, so it is published as one and said to
            // nobody. Reporting it was the bug this fixes (ADR 0339).
            watch.recordLate(.stopped, null);
            return .{ .err = err };
        }
        // An error has nothing to merge, but a handed-off attempt still owes
        // its failure to someone: the boot thread released the request on the
        // promise that this would land, so a silent failure here is
        // indistinguishable from a connect (ADR 0339). Record it, and say it
        // on stderr — the only channel left once the answer is out.
        if (settled.target != null) {
            watch.recordLate(.failed, err);
            std.debug.print("companion: {s} failed to connect after the boot budget ({t}); native tools only\n", .{ spec.name, err });
        }
        return .{ .err = err };
    };
    watch.forget(); // the outcome owns the child now
    if (watch.settle(io).target) |reg| {
        // The join went over budget and handed this attempt to the live
        // registry (ADR 0339). `adoptStarted` is the one merge point, so a
        // server that connected meanwhile keeps its tools and this one is
        // torn down (#505); the registry owns the outcome either way.
        watch.recordLate(if (mcp_boot.adoptStarted(reg, outcome)) .merged else .duplicate, null);
        return .{};
    }
    return .{ .outcome = outcome };
}

fn connectInto(gpa: Allocator, io: Io, spec: Spec, watch: *Watch, arena_state: *std.heap.ArenaAllocator) !mcp_boot.StartOutcome {
    const a = arena_state.allocator();
    var tmp: mcp.Registry = .{
        .gpa = gpa,
        .io = io,
        .home = spec.home,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .stdio_probe = spec.stdio_probe,
        .lazy_stdio = spec.lazy_stdio,
        .show_diagnostics = spec.show_diagnostics,
        .spawn_watch = watch,
    };
    defer tmp.arena_state.deinit();
    // Same object, same key order as `Registry.addServer`: the cache key and
    // the relaunch config are derived from it.
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = try a.dupe(u8, spec.command) });
    var argv = std.json.Array.init(a);
    for (spec.args) |arg| try argv.append(.{ .string = try a.dupe(u8, arg) });
    try cfg.put(a, "args", .{ .array = argv });
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    try tmp.startServer(a, &servers, &tools, try a.dupe(u8, spec.name), cfg);
    return .{ .server = servers.items[0], .tools = tools.items, .arena_state = arena_state.* };
}

/// `addServer(name, command, args)` for the consumer, served by the prewarm
/// when it ran this companion: one start either way.
pub fn connect(reg: *mcp.Registry, name: []const u8, command: []const u8, argv: []const []const u8) !Adopted {
    if (take(reg, name)) |joined| return joined;
    _ = try reg.addServer(name, command, argv);
    return .connected;
}

/// The consumer. Null: no attempt ran to a result for `name` (none started,
/// or discarded on a mismatch) — connect inline as before.
/// Otherwise `.connected` with the server merged into `reg`, or the error the
/// attempt ended with, which is the error `addServer` would have returned (the
/// pre-budget contract, `error.McpClosed` included; see `budgetMs`). A failed
/// attempt is not repeated: the serial path made one.
/// Over budget (ADR 0339) the attempt is neither adopted nor stopped: it keeps
/// running and merges into `reg` when it lands, so this returns `.late` — no
/// catalog yet, no inline second spawn, and nothing claiming a connect.
pub fn take(reg: *mcp.Registry, name: []const u8) ?anyerror!Adopted {
    const s = if (slot) |*s| s else return null;
    if (!std.mem.eql(u8, s.spec.name, name)) return null;
    if (!matches(reg, s)) {
        discard(reg.io);
        return null;
    }
    if (!awaitWithin(s, reg.io) and !s.watch.handOff(reg)) return .late;
    const joined = s.future.await(reg.io);
    release();
    if (joined.err) |err| return err;
    if (!mcp_boot.adoptStarted(reg, joined.outcome)) return error.McpServerAlreadyConnected;
    return .connected;
}

/// What the attempt did: `.none` while it is still running, then `.merged`,
/// `.duplicate`, `.failed`, or `.stopped` when the exit path ended it.
/// `boot_prewarm_tests` polls it — the late merge and the duplicate guard are
/// otherwise invisible (a dropped latecomer leaves no trace, and neither does
/// a missing merge). The exit path frees the slot, so it reads the same state
/// through `stopAtExit`'s return instead.
pub fn lateOutcome() LateOutcome {
    const s = if (slot) |*s| s else return .none;
    return s.watch.outcome();
}

/// The error a handed-off attempt ended with, when `lateOutcome` is `.failed`.
pub fn lateError() ?anyerror {
    const s = if (slot) |*s| s else return null;
    s.watch.acquire();
    defer s.watch.lock.unlock();
    return s.watch.late_err;
}

/// Wait for the attempt's result, for at most `s.budget_ms`. True: it is on
/// the future now, so awaiting it does not block. False: still running (or the
/// wait was cancelled), and the caller hands it to the registry instead of
/// waiting. The worker's last write sets the event, so a 50 ms companion is
/// adopted at once and a silent one costs the budget, not the probe plus
/// handshake caps.
fn awaitWithin(s: *Slot, io: Io) bool {
    if (s.watch.finished()) return true;
    const budget: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(@intCast(s.budget_ms)), .clock = .awake } };
    s.watch.done_event.waitTimeout(io, budget) catch {}; // Timeout, or a cancelled wait
    return s.watch.finished();
}

fn matches(reg: *const mcp.Registry, s: *const Slot) bool {
    if (reg.stdio_probe != s.spec.stdio_probe or reg.lazy_stdio != s.spec.lazy_stdio) return false;
    if (!std.mem.eql(u8, reg.home, s.spec.home)) return false;
    var now: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwdKey(reg.io, &now);
    return n > 0 and std.mem.eql(u8, now[0..n], s.cwd[0..s.cwd_len]);
}

/// Stop, join and tear down a prewarm nobody adopted. No-op when the slot is
/// empty, so every exit path may call it — and no-op for an attempt `take`
/// handed to the live registry, which is still running on purpose (ADR 0339).
pub fn discard(io: Io) void {
    const s = if (slot) |*s| s else return;
    if (s.watch.handedOff()) return;
    _ = stopJoin(io);
}

/// Exit-path teardown: stop and join the attempt even when `take` handed it
/// to the live registry, so no worker outlives the registry or its `io`
/// (#325). `Registry.deinitAtExit` calls this before the registry goes away,
/// which is also what makes the worker's late merge safe; the one-shot's own
/// `std.process.exit` paths (`oneshot.zig`, which skip every `defer`) call it
/// too. The join is bounded because `stop` ends the child on both platforms:
/// a silent companion costs the kill plus a reap, not its 5 s probe and 15 s
/// handshake. Returns what the attempt did when the stop ended it: `.stopped`
/// is the quiet case, `.failed` a companion that had already failed on its own
/// (ADR 0339). The slot and its watch are freed here, so this is where that
/// outcome is read — `lateOutcome` has nothing left to read afterwards.
pub fn stopAtExit(io: Io) LateOutcome {
    return stopJoin(io);
}

fn stopJoin(io: Io) LateOutcome {
    const s = if (slot) |*s| s else return .none;
    s.watch.stop();
    var joined = s.future.await(io);
    const ended = s.watch.outcome(); // before `release` frees the watch
    release();
    if (joined.outcome.server) |server| mcp_rpc.deinitServer(server, io, .init(io, mcp_teardown.teardown_grace));
    if (joined.outcome.arena_state) |*ta| ta.deinit();
    return ended;
}

fn release() void {
    if (slot) |*s| s.owned.deinit();
    slot = null;
}

const testing = std.testing;

// The fixtures, the join-budget cases and the late-merge cases live in
// boot_prewarm_tests.zig, pulled in here so `zig build test` reaches them
// (`src/main.zig` references this module). Split out to stay inside the
// 600-line ceiling after ADR 0339 added the budget.
test {
    _ = @import("boot_prewarm_tests.zig");
}

test "boot prewarm: early-exit and interactive invocations start nothing" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expect(!wantsCompanion(.{ .help_flag = true }, &env));
    try testing.expect(!wantsCompanion(.{ .version_flag = true }, &env));
    try testing.expect(!wantsCompanion(.{}, &env)); // REPL: ADR 0230 queues it
    // What args.parse builds for `graff -p hi`: the prompt is the positionals.
    var words: [1][]const u8 = .{"hi"};
    const oneshot: args.Flags = .{ .print_flag = true, .positionals = .fromOwnedSlice(&words), .oneshot_prompt = "hi" };
    try testing.expect(wantsCompanion(oneshot, &env));
    var no_lean = oneshot;
    no_lean.no_lean_flag = true;
    try testing.expect(!wantsCompanion(no_lean, &env));
    var worktree = oneshot;
    worktree.worktree_flag = "w";
    try testing.expect(!wantsCompanion(worktree, &env));
    var title: [2][]const u8 = .{ "title", "hi" };
    try testing.expect(!wantsCompanion(.{ .positionals = .fromOwnedSlice(&title), .is_subcommand = true }, &env));
    var probe = std.process.Environ.Map.init(testing.allocator);
    defer probe.deinit();
    try probe.put("GRAFF_MCP_EAGER", "1");
    try testing.expect(!wantsCompanion(oneshot, &probe));
    try testing.expect(!pending());
}
