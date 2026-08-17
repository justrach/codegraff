//! #554's REPL surface: `/snapshot` captures the active sandbox's filesystem
//! into `.graff/sessions/<session>/snapshots/<id>/`, `/rewind <id>` brings one
//! back up.
//!
//! `/rewind` was already taken by the CONVERSATION rewind (commands_model.zig,
//! `/rewind <n>`), and the two are deliberately the same word: they are the
//! same gesture on two different substrates. The argument decides which — a
//! number is a prompt index and falls through to the old handler untouched,
//! anything else is a snapshot id. This module is dispatched from
//! commands_session.tryHandle, which runs BEFORE commands_model, so the
//! numeric path is reached exactly as it was.
//!
//! A sandbox rewind restores FILESYSTEM state and nothing else. The
//! conversation and the event log stay canonical, every output here says so,
//! and processes inside the sandbox are relaunched rather than resumed.
//!
//! Every failure here is an explanation. No sandbox attached, no docker
//! installed, no such snapshot, a backend that cannot capture at all: each
//! prints what is true and returns, because a slash command that panics on a
//! missing container runtime is worse than one that does nothing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const ansi = @import("ansi.zig");
const style = &ansi.style;
const main_mod = @import("main.zig");
const sandbox = @import("sandbox.zig");
const sandbox_docker = @import("sandbox_docker.zig");
const util = @import("util.zig");

/// The process's Docker backend, once `/snapshot attach` has built one. A
/// live `Handle` points into a Sandbox that points back here, so this outlives
/// any one command — the same process-wide shape as sandbox.active().
var g_docker: sandbox_docker.Docker = undefined;

/// The sentence every rewind output carries. A user who believed the
/// transcript had moved too would read it as the record of a run that never
/// happened, so this is pinned by a test rather than left to phrasing.
pub const log_note = "the conversation and event log are NOT rewound — filesystem state only";

/// True when `/rewind <arg>` means a snapshot rather than a prompt index.
/// An empty or all-digit argument belongs to the conversation rewind.
pub fn isSnapshotArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    for (arg) |c| if (!std.ascii.isDigit(c)) return true;
    return false;
}

/// What went wrong, in words a user can act on.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.SandboxUnavailable => "the sandbox backend is not usable here — `docker` is not on PATH, or the daemon refused the command",
        error.SnapshotUnsupported => "this backend cannot capture state (the local backend runs without isolation, so there is nothing to snapshot) — attach a Docker sandbox instead",
        error.SnapshotFailed => "the capture failed — `docker commit`/`docker save` did not succeed",
        error.RestoreFailed => "the restore failed — `docker load`/`docker run` did not succeed, and the previous sandbox was already released; nothing is attached now, so `/snapshot attach` starts a fresh one",
        error.ExecFailed => "the sandbox command could not be run",
        else => "the sandbox operation failed",
    };
}

/// `/snapshot` (capture), `/snapshot attach [image]`, `/snapshot detach`,
/// `/snapshot list`, and `/rewind <id>`. Returns false for anything else,
/// including `/rewind` with a numeric or absent argument.
pub fn tryHandle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (argOf(line, "/snapshot")) |arg| {
        if (std.mem.eql(u8, arg, "list") or std.mem.eql(u8, arg, "ls")) {
            try renderList(root, arena, out);
        } else if (argOf(arg, "attach")) |image| {
            try attach(root, image, out);
        } else if (std.mem.eql(u8, arg, "detach")) {
            try detach(out);
        } else {
            try capture(root, arena, out);
        }
        try out.flush();
        return true;
    }
    if (argOf(line, "/rewind")) |arg| {
        if (!isSnapshotArg(arg)) return false; // the conversation rewind owns it
        try restore(root, arena, arg, out);
        try out.flush();
        return true;
    }
    return false;
}

/// The argument after `cmd`, or null when `line` is a different command.
/// `/rewinds` is not `/rewind`: the next byte has to be a space or the end.
fn argOf(line: []const u8, cmd: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, cmd)) return null;
    const rest = line[cmd.len..];
    if (rest.len > 0 and rest[0] != ' ' and rest[0] != '\t') return null;
    return std.mem.trim(u8, rest, " \t");
}

/// Put this session in a Docker sandbox so there is something to capture.
/// Nothing attaches one automatically in the MVP — the bot runner and the DGM
/// trials that #554 exists for will call sandbox.attach directly — so this is
/// how a person drives the seam by hand.
fn attach(root: *Agent, image: []const u8, out: *Io.Writer) !void {
    // One Docker slot per process, and a live Handle points into it, so a
    // second attach would move the ground under the first. Refusing is the
    // honest answer; `/snapshot detach` is one keystroke away.
    if (sandbox.active()) |prev| {
        try out.print("a sandbox is already attached ({s}) — /snapshot detach first\n", .{prev.handle.id});
        return;
    }
    g_docker = .{
        .io = root.io,
        .path_env = main_mod.g_path_env,
        .image = if (image.len > 0) image else sandbox_docker.default_image,
    };
    const backend = g_docker.backend();
    if (!backend.available()) {
        try out.print("docker backend: {s}\n", .{explain(error.SandboxUnavailable)});
        return;
    }
    const handle = backend.acquire(root.gpa, root.session_name) catch |err| {
        try out.print("could not start a sandbox — {s}\n", .{explain(err)});
        return;
    };
    sandbox.attach(.{ .backend = backend, .handle = handle });
    try out.print("sandbox attached — {s} on {s} (key {s})\n", .{ handle.id, g_docker.image, handle.key });
}

fn detach(out: *Io.Writer) !void {
    const act = sandbox.active() orelse {
        try out.writeAll("no sandbox is attached\n");
        return;
    };
    act.handle.release();
    sandbox.detach();
    try out.writeAll("sandbox released — its snapshots stay on disk\n");
}

fn capture(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    if (!sandbox.safeName(root.session_name)) {
        try out.writeAll("this session has no name a snapshot directory could be built from\n");
        return;
    }
    const act = sandbox.active() orelse {
        try out.print("no sandbox is active — {s}/snapshot{s} captures the filesystem of a sandbox this session is running in, and there is none attached\n", .{ style.accent, style.reset });
        try renderList(root, arena, out);
        return;
    };
    if (!act.backend.available()) {
        try out.print("{s} backend: {s}\n", .{ act.backend.name(), explain(error.SandboxUnavailable) });
        return;
    }
    const id = try sandbox.newId(arena, root.io);
    const blob: sandbox.Blob = .{
        .io = root.io,
        .dir = sandbox.workspace(),
        .rel = try sandbox.payloadPath(arena, root.session_name, id),
    };
    const payload = act.handle.snapshot(root.gpa, blob) catch |err| {
        try out.print("snapshot failed — {s}\n", .{explain(err)});
        return;
    };
    sandbox.writeManifest(root.io, sandbox.workspace(), arena, root.session_name, .{
        .id = id,
        .backend = act.backend.name(),
        .kind = payload.kind.tag(),
        .ref = payload.ref,
        .len = payload.len,
        .created_ms = util.unixMs(root.io),
    }) catch |err| {
        try out.print("captured the payload but could not record it: {s}\n", .{@errorName(err)});
        return;
    };
    try out.print("📸 snapshot {s}{s}{s} — {d} bytes at {s}\n", .{ style.accent, id, style.reset, payload.len, blob.rel });
    try out.print("{s}   /rewind {s} brings this filesystem back; {s}{s}\n", .{ style.dim, id, log_note, style.reset });
}

fn restore(root: *Agent, arena: Allocator, id: []const u8, out: *Io.Writer) !void {
    const found = sandbox.find(root.io, sandbox.workspace(), arena, root.session_name, id) orelse {
        try out.print("no snapshot {s} in this session — {s}/snapshot list{s} shows what there is\n", .{ id, style.accent, style.reset });
        return;
    };
    const act = sandbox.active() orelse {
        try out.print("no sandbox is active — a rewind restores a snapshot ONTO a backend, and there is none attached\n", .{});
        return;
    };
    if (!act.backend.available()) {
        try out.print("{s} backend: {s}\n", .{ act.backend.name(), explain(error.SandboxUnavailable) });
        return;
    }
    const blob: sandbox.Blob = .{
        .io = root.io,
        .dir = sandbox.workspace(),
        .rel = try sandbox.payloadPath(arena, root.session_name, found.id),
    };
    // Release BEFORE restoring, not after. The restore acquires the same key,
    // and a backend evicts the warm container on a key before it starts one —
    // so releasing afterwards would `docker rm -f` the container the restore
    // had just brought up. The old sandbox is doomed either way; this order is
    // the one where the new one survives.
    const key = try arena.dupe(u8, act.handle.key);
    act.handle.release();
    sandbox.detach();
    const fresh = act.backend.acquireFromSnapshot(root.gpa, key, found.payload(), blob) catch |err| {
        try out.print("rewind failed — {s}\n", .{explain(err)});
        return;
    };
    sandbox.attach(.{ .backend = act.backend, .handle = fresh });
    try out.print("⏪ sandbox rewound to {s}{s}{s} ({s}, {d} bytes)\n", .{ style.accent, found.id, style.reset, found.backend, found.len });
    try out.print("{s}   {s}; processes inside the sandbox were relaunched, not resumed{s}\n", .{ style.dim, log_note, style.reset });
}

fn renderList(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    const items = try sandbox.list(root.io, sandbox.workspace(), arena, root.session_name);
    if (items.len == 0) {
        try out.writeAll("no snapshots in this session yet\n");
        return;
    }
    try out.print("{s}snapshots{s}\n", .{ style.bold, style.reset });
    for (items) |m| {
        try out.print("  {s}{s}{s}  {s:<8} {d:>10} B  {s}\n", .{ style.accent, m.id, style.reset, m.backend, m.len, m.ref });
    }
    try out.print("{s}usage: /rewind <id> — restores that filesystem; {s}{s}\n", .{ style.dim, log_note, style.reset });
}

test "a numeric /rewind argument stays with the conversation rewind" {
    try std.testing.expect(!isSnapshotArg(""));
    try std.testing.expect(!isSnapshotArg("3"));
    try std.testing.expect(!isSnapshotArg("12"));
    try std.testing.expect(isSnapshotArg("1754000000-ab12cd34"));
    try std.testing.expect(isSnapshotArg("abc"));
}

test "argOf claims only the exact command" {
    try std.testing.expectEqualStrings("", argOf("/snapshot", "/snapshot").?);
    try std.testing.expectEqualStrings("list", argOf("/snapshot list", "/snapshot").?);
    try std.testing.expect(argOf("/snapshots", "/snapshot") == null);
    try std.testing.expect(argOf("/rewinds 3", "/rewind") == null);
    try std.testing.expectEqualStrings("3", argOf("/rewind 3", "/rewind").?);
}

test "every sandbox failure has an explanation, and rewind never claims the log moved" {
    inline for (.{
        error.SandboxUnavailable,
        error.SnapshotUnsupported,
        error.SnapshotFailed,
        error.RestoreFailed,
        error.ExecFailed,
    }) |err| {
        try std.testing.expect(explain(err).len > 20);
    }
    try std.testing.expect(std.mem.indexOf(u8, log_note, "NOT rewound") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_note, "filesystem state only") != null);
}
