//! One-shot codedb composers. Graphify's hop win is `explain` / `path` /
//! `query` — one call, a neighborhood. codedb already has the graph
//! (`callpath`) and a task composer (`context`); this module collapses the
//! remaining "symbol then callers" dance the model otherwise pays two
//! round-trips for.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const jobs = @import("jobs.zig");

const deadline_ms: u64 = 60 * 1000;
const section_cap = 24 * 1024;

pub fn firstIdent(rest: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0 or tok[0] == '-') continue;
        return tok;
    }
    return null;
}

pub fn pathEnds(rest: []const u8) ?struct { from: []const u8, to: []const u8 } {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const from = it.next() orelse return null;
    const to = it.next() orelse return null;
    if (from[0] == '-' or to[0] == '-') return null;
    return .{ .from = from, .to = to };
}

fn interpretRun(gpa: Allocator, subcmd: []const u8, run: anytype) !ToolOutput {
    defer gpa.free(run.stderr);
    const text = run.stdout;
    if (run.timed_out) {
        defer gpa.free(text);
        return .{
            .text = try std.fmt.allocPrint(gpa, "codedb {s} timed out after {d}s and was killed — narrow the query", .{ subcmd, deadline_ms / 1000 }),
            .is_error = true,
        };
    }
    const ok = switch (run.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        defer gpa.free(text);
        const detail = std.mem.trim(u8, if (run.stderr.len > 0) run.stderr else text, " \t\r\n");
        return .{
            .text = if (detail.len > 0)
                try gpa.dupe(u8, detail)
            else
                try std.fmt.allocPrint(gpa, "codedb {s} exited non-zero — check `codedb status` in this workspace", .{subcmd}),
            .is_error = true,
        };
    }
    if (text.len == 0 and run.stderr.len > 0) {
        defer gpa.free(text);
        return .{ .text = try gpa.dupe(u8, run.stderr) };
    }
    return .{ .text = text };
}

fn spawn(ctx: ToolCtx, argv_tail: []const []const u8) !ToolOutput {
    const gpa = ctx.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "codedb");
    try argv.appendSlice(gpa, argv_tail);
    const run = jobs.runCappedWithOptions(gpa, ctx.io, argv.items, 512 * 1024, 4096, deadline_ms, jobs.toolRunOptions(ctx.agent_cwd)) catch |e| switch (e) {
        error.FileNotFound => return .{
            .text = try gpa.dupe(u8, "codedb isn't installed — it's open source at github.com/justrach/codedb; install it, then run `codedb` once in the repo to index it. Folder listing still works: codedb list_dir ."),
            .is_error = true,
        },
        else => return tools.failure(gpa, e),
    };
    return interpretRun(gpa, argv_tail[0], run);
}

fn take(gpa: Allocator, out: ToolOutput, cap: usize) ![]u8 {
    defer gpa.free(out.text);
    const src = if (out.text.len > cap) out.text[0..cap] else out.text;
    return gpa.dupe(u8, src);
}

pub fn execAround(ctx: ToolCtx, rest: []const u8) !ToolOutput {
    const gpa = ctx.gpa;
    const name = firstIdent(rest) orelse return .{
        .text = try gpa.dupe(u8, "usage: codedb around <name> — definition body + callers in one call (graphify explain). Alias: explain <name>."),
        .is_error = true,
    };
    if (!@import("codedb_health.zig").probe(ctx.io, ctx.agent_cwd orelse ".").present) {
        return .{
            .text = try gpa.dupe(u8, "codedb index missing — no codedb.snapshot in this cwd; use read_file or bash grep/rg directly, or run `codedb` outside the agent to index this worktree"),
            .is_error = true,
        };
    }

    const def = try spawn(ctx, &.{ "symbol", name, "--body" });
    if (def.is_error) return def;
    const def_text = try take(gpa, def, section_cap);
    defer gpa.free(def_text);

    const callers = try spawn(ctx, &.{ "callers", name });
    if (callers.is_error) {
        defer gpa.free(callers.text);
        return .{ .text = try std.fmt.allocPrint(gpa, "## definition\n{s}\n\n## callers\n{s}", .{ def_text, callers.text }), .is_error = true };
    }
    const callers_text = try take(gpa, callers, section_cap);
    defer gpa.free(callers_text);

    return .{ .text = try std.fmt.allocPrint(gpa, "## definition\n{s}\n\n## callers\n{s}", .{ def_text, callers_text }) };
}

pub fn execPath(ctx: ToolCtx, rest: []const u8) !ToolOutput {
    const ends = pathEnds(rest) orelse return .{
        .text = try ctx.gpa.dupe(u8, "usage: codedb callpath <from> <to> — shortest resolved call chain (graphify path). Alias: path <from> <to>."),
        .is_error = true,
    };
    if (!@import("codedb_health.zig").probe(ctx.io, ctx.agent_cwd orelse ".").present) {
        return .{
            .text = try ctx.gpa.dupe(u8, "codedb index missing — no codedb.snapshot in this cwd; use read_file or bash grep/rg directly, or run `codedb` outside the agent to index this worktree"),
            .is_error = true,
        };
    }
    return spawn(ctx, &.{ "callpath", ends.from, ends.to });
}

test "firstIdent skips flags" {
    try std.testing.expectEqualStrings("handleCallpath", firstIdent("handleCallpath").?);
    try std.testing.expectEqualStrings("Store", firstIdent("--body Store").?);
    try std.testing.expect(firstIdent("") == null);
    try std.testing.expect(firstIdent("   ") == null);
}

test "pathEnds needs two identifiers" {
    const got = pathEnds("handleContext handleCallpath").?;
    try std.testing.expectEqualStrings("handleContext", got.from);
    try std.testing.expectEqualStrings("handleCallpath", got.to);
    try std.testing.expect(pathEnds("onlyOne") == null);
    try std.testing.expect(pathEnds("") == null);
}

test "#54: interpretRun marks non-zero codedb subprocess exits as errors" {
    const gpa = std.testing.allocator;
    const MockRun = struct {
        stdout: []u8,
        stderr: []u8,
        term: std.process.Child.Term,
        timed_out: bool,
        cancelled: bool,
    };
    const err_out = try interpretRun(gpa, "symbol", MockRun{
        .stdout = try gpa.dupe(u8, ""),
        .stderr = try gpa.dupe(u8, "refusing to index temporary root\n"),
        .term = .{ .exited = 1 },
        .timed_out = false,
        .cancelled = false,
    });
    defer gpa.free(err_out.text);
    try std.testing.expect(err_out.is_error);
    try std.testing.expectEqualStrings("refusing to index temporary root", err_out.text);

    const ok_out = try interpretRun(gpa, "symbol", MockRun{
        .stdout = try gpa.dupe(u8, "fn foo() void {}"),
        .stderr = try gpa.dupe(u8, ""),
        .term = .{ .exited = 0 },
        .timed_out = false,
        .cancelled = false,
    });
    defer gpa.free(ok_out.text);
    try std.testing.expect(!ok_out.is_error);
    try std.testing.expectEqualStrings("fn foo() void {}", ok_out.text);
}
