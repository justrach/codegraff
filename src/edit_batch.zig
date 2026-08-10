//! Batched edit_file: several spans, one call (#476 — the apply_patch
//! mechanic from the opencode session anatomy: their feature run paid 2
//! patch calls where graff paid 8-10 single-span edit_file calls; one
//! batched call per file is the 1:1). Spans apply SEQUENTIALLY through
//! edit_verify.applyEdit, so each one gets the same lock, drift check,
//! mode preservation and post-write verify as a single edit. A failing
//! span stops the batch and the result says how many earlier spans DID
//! apply — no silent partial state.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const approvals = @import("approvals.zig");
const edit_verify = @import("edit_verify.zig");

const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const Value = std.json.Value;

/// The `edits`-array arm of edit_file; exec.zig routes here when the input
/// carries a non-null `edits` field. Same confinement and worktree
/// resolution as edit_verify.execEdit.
pub fn execBatch(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const path = tools.strField(input, "path") orelse return tools.missingArg(gpa, "path");
    if (!approvals.confinedPath(path) or !approvals.noSymlinkEscape(ctx.io, path, ctx.agent_cwd))
        return .{ .text = try std.fmt.allocPrint(gpa, "{s} is outside the working directory — edit_file stays inside it", .{path}), .is_error = true };
    const list = input.object.get("edits").?.array;
    if (list.items.len == 0) return .{ .text = try gpa.dupe(u8, "edits must contain at least one span"), .is_error = true };

    // #276 P0-1, same as execEdit: resolve under the agent's worktree.
    const resolved: []const u8 = if (ctx.agent_cwd) |base| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path }) else path;
    defer if (ctx.agent_cwd != null) gpa.free(resolved);

    var applied: usize = 0;
    for (list.items, 0..) |item, i| {
        if (item != .object) return spanErr(gpa, i, list.items.len, "span is not an object", applied, path);
        const old = tools.strField(item, "old_string") orelse return spanErr(gpa, i, list.items.len, "missing old_string", applied, path);
        const new = tools.strField(item, "new_string") orelse return spanErr(gpa, i, list.items.len, "missing new_string", applied, path);
        if (old.len == 0) return spanErr(gpa, i, list.items.len, "old_string must not be empty", applied, path);
        const all = tools.json_args.flag(item, "replace_all");
        const r = try edit_verify.applyEdit(ctx, path, resolved, old, new, all);
        if (r.is_error) return spanErr(gpa, i, list.items.len, r.text, applied, path);
        applied += 1;
    }
    return .{ .text = try std.fmt.allocPrint(gpa, "applied {d} edit span(s) to {s} (each verified)", .{ applied, path }), .is_error = false };
}

fn spanErr(gpa: Allocator, idx: usize, total: usize, why: []const u8, applied: usize, path: []const u8) !ToolOutput {
    const suffix: []const u8 = if (applied > 0)
        try std.fmt.allocPrint(gpa, " ({d} earlier span(s) DID apply to {s} — read it before retrying)", .{ applied, path })
    else
        "";
    return .{ .text = try std.fmt.allocPrint(gpa, "edit span {d}/{d} failed: {s}{s}", .{ idx + 1, total, why, suffix }), .is_error = true };
}

test "execBatch: two spans apply in one call; a bad span reports its index and prior applies" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha one\nbeta two\ngamma three\n" });
    const rel = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{ .gpa = a, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };

    var good = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"one","new_string":"1"},{"old_string":"two","new_string":"2"}]}
    , .{ .allocate = .alloc_always });
    good.object.put(a, "path", .{ .string = rel }) catch unreachable;
    const ok = try execBatch(ctx, good);
    try std.testing.expect(!ok.is_error);
    try std.testing.expect(std.mem.indexOf(u8, ok.text, "2 edit span(s)") != null);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, data, "alpha 1\nbeta 2") != null);

    var bad = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"gamma","new_string":"3"},{"old_string":"NOT PRESENT","new_string":"x"}]}
    , .{ .allocate = .alloc_always });
    bad.object.put(a, "path", .{ .string = rel }) catch unreachable;
    const err = try execBatch(ctx, bad);
    try std.testing.expect(err.is_error);
    try std.testing.expect(std.mem.indexOf(u8, err.text, "span 2/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.text, "1 earlier span(s) DID apply") != null);
    const after = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, after, "3 three") != null); // span 1 landed
}
