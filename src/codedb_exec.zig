//! Native `codedb` tool dispatch. Split out of exec.zig (600-line cap).
//!
//! In-process: `list_dir` (PathConfine + gitignore) and `status` (snapshot
//! health). Everything else is a read-only spawn of the codedb binary.
//! Path-bearing subcommands (read/outline/deps/file) get the same jail as
//! read_file — the binary is not a second way out of the cwd.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const harness_policy = @import("harness_policy.zig");
const list_dir = @import("list_dir.zig");
const codedb_health = @import("codedb_health.zig");
const jobs = @import("jobs.zig");
const main_mod = @import("main.zig");
const hooks = @import("hooks.zig");

pub const deadline_ms: u64 = 60 * 1000;

const ok_subs = [_][]const u8{
    "search",   "symbol", "callers", "find", "outline", "read", "tree",
    "list_dir", "status", "context", "word", "deps",    "glob", "ls",
    "file",     "hot",
};

const path_subs = [_][]const u8{ "outline", "read", "deps", "file" };

fn allowed(sub: []const u8) bool {
    for (ok_subs) |s| if (std.mem.eql(u8, s, sub)) return true;
    return false;
}

fn isPathSub(sub: []const u8) bool {
    for (path_subs) |s| if (std.mem.eql(u8, s, sub)) return true;
    return false;
}

fn firstPathArg(rest: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    var skip_next = false;
    while (it.next()) |tok| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (tok.len == 0) continue;
        if (tok[0] == '-') {
            if (std.mem.eql(u8, tok, "-L") or std.mem.eql(u8, tok, "--lines")) skip_next = true;
            continue;
        }
        return tok;
    }
    return null;
}

fn globEscapes(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '/') return true;
    var it = std.mem.tokenizeAny(u8, pattern, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

pub fn exec(ctx: ToolCtx, input: std.json.Value) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const cmd = tools.strField(input, "command") orelse return tools.missingArg(gpa, "command");
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const sub = it.next() orelse return .{
        .text = try gpa.dupe(u8, "usage: codedb <subcommand> [args] — e.g. search <q>, symbol <name>, callers <name>, outline <path>, list_dir <path>, status"),
        .is_error = true,
    };
    if (std.mem.eql(u8, sub, "list_dir")) return list_dir.exec(ctx, it.rest());
    if (std.mem.eql(u8, sub, "status")) return codedb_health.exec(ctx);
    if (!allowed(sub)) return .{
        .text = try std.fmt.allocPrint(gpa, "codedb subcommand '{s}' is not allowed here — use one of: search, symbol, callers, find, outline, read, tree, list_dir, status, context, word, deps, glob, ls, file, hot", .{sub}),
        .is_error = true,
    };

    if (isPathSub(sub)) {
        if (firstPathArg(it.rest())) |path| {
            if (!harness_policy.confinedPath(path) or !harness_policy.noSymlinkEscape(io, path, ctx.agent_cwd))
                return tools.outsideCwd(gpa, path);
        }
    }
    if (std.mem.eql(u8, sub, "glob")) {
        if (firstPathArg(it.rest())) |pat| {
            if (globEscapes(pat)) return tools.outsideCwd(gpa, pat);
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "codedb");
    try argv.append(gpa, sub);
    var rest = std.mem.tokenizeAny(u8, it.rest(), " \t");
    while (rest.next()) |tok| try argv.append(gpa, tok);

    const run = jobs.runCappedWithOptions(gpa, io, argv.items, 512 * 1024, 4096, deadline_ms, jobs.toolRunOptions(ctx.agent_cwd)) catch |e| switch (e) {
        error.FileNotFound => return .{
            .text = try gpa.dupe(u8, "codedb isn't installed — it's open source at github.com/justrach/codedb; install it, then run `codedb` once in the repo to index it. Folder listing still works: codedb list_dir ."),
            .is_error = true,
        },
        else => return tools.failure(gpa, e),
    };
    gpa.free(run.stderr);
    const text = run.stdout;
    if (run.timed_out) {
        defer gpa.free(text);
        return .{
            .text = try std.fmt.allocPrint(gpa, "codedb {s} timed out after {d}s and was killed — narrow the query, or run it through bash if it really needs that long", .{ sub, deadline_ms / 1000 }),
            .is_error = true,
        };
    }
    if (text.len == 0) {
        defer gpa.free(text);
        return .{ .text = try gpa.dupe(u8, "(codedb returned nothing — try `codedb status` or `codedb tree` to confirm the repo is indexed, or refine the query)") };
    }
    return .{ .text = text };
}

/// Opt-in exploratory read via `codedb read <path> [-L a-b] --compact`. Lossy
/// view for reasoning only; returns null on any codedb failure so the caller
/// falls back to the native byte-exact read (#66).
pub fn compactRead(gpa: Allocator, io: Io, path: []const u8, start: ?i64, end: ?i64) !?ToolOutput {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var lbuf: [48]u8 = undefined;
    try argv.append(gpa, "codedb");
    try argv.append(gpa, "read");
    try argv.append(gpa, path);
    if (start != null and end != null and start.? >= 1 and end.? >= start.?) {
        try argv.append(gpa, "-L");
        try argv.append(gpa, std.fmt.bufPrint(&lbuf, "{d}-{d}", .{ start.?, end.? }) catch return null);
    }
    try argv.append(gpa, "--compact");
    const run = jobs.runCapped(gpa, io, argv.items, tools.codedb_result_cap, 4096, 0) catch return null;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const ok = switch (run.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok or run.stdout.len == 0) return null;
    return ToolOutput{ .text = try std.fmt.allocPrint(gpa, "{s}\n[compact view — comments/blank lines stripped, line numbers shown; re-read WITHOUT compact before building an edit_file old_string]", .{run.stdout}) };
}

pub fn maybeCompactRead(ctx: ToolCtx, path: []const u8, start: ?i64, end: ?i64) !?ToolOutput {
    if (ctx.agent_cwd != null) return null;
    if (main_mod.g_codedb_present == null) main_mod.g_codedb_present = @import("skills.zig").binOnPath(ctx.io, "codedb");
    if (main_mod.g_codedb_present != true) return null;
    if (!hooks.codedbFileIndexed(ctx.io, ctx.gpa, path)) return null;
    return compactRead(ctx.gpa, ctx.io, path, start, end);
}

test "firstPathArg skips flags" {
    try std.testing.expectEqualStrings("src/main.zig", firstPathArg("-L 1-10 src/main.zig").?);
    try std.testing.expectEqualStrings("src/a.zig", firstPathArg("src/a.zig --compact").?);
    try std.testing.expect(firstPathArg("--compact") == null);
}

test "globEscapes rejects parent and absolute patterns" {
    try std.testing.expect(globEscapes("/etc/*"));
    try std.testing.expect(globEscapes("../**"));
    try std.testing.expect(globEscapes("foo/../bar"));
    try std.testing.expect(!globEscapes("**/*.zig"));
    try std.testing.expect(!globEscapes("src/*"));
}

test "allowed subcommands include list_dir and status, not update" {
    try std.testing.expect(allowed("list_dir"));
    try std.testing.expect(allowed("status"));
    try std.testing.expect(allowed("search"));
    try std.testing.expect(!allowed("update"));
    try std.testing.expect(!allowed("nuke"));
    try std.testing.expect(!allowed("mcp"));
}
