//! Batched edit_file: several spans, one call (#476 — the apply_patch
//! mechanic from the opencode session anatomy: their feature run paid 2
//! patch calls where graff paid 8-10 single-span edit_file calls; one
//! batched call per file is the 1:1). Spans apply sequentially to an in-memory
//! draft, then one verified write commits the complete batch. An invalid span
//! leaves the file unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const approvals = @import("approvals.zig");
const edit_verify = @import("edit_verify.zig");
const credential_store = @import("credential_store.zig");

const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const Value = std.json.Value;

/// The `edits`-array arm of edit_file; exec.zig routes here when the input
/// carries an `edits` field. Same confinement and worktree
/// resolution as edit_verify.execEdit.
pub fn execBatch(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const path = tools.strField(input, "path") orelse return tools.missingArg(gpa, "path");
    if (!approvals.confinedPath(path) or !approvals.noSymlinkEscape(ctx.io, path, ctx.agent_cwd))
        return .{ .text = try std.fmt.allocPrint(gpa, "{s} is outside the working directory — edit_file stays inside it", .{path}), .is_error = true };
    const edits = input.object.get("edits") orelse return tools.missingArg(gpa, "edits");
    if (edits != .array) return .{ .text = try gpa.dupe(u8, "edits must be an array of edit span objects"), .is_error = true };
    const list = edits.array;
    if (list.items.len == 0) return .{ .text = try gpa.dupe(u8, "edits must contain at least one span"), .is_error = true };

    // #747: same absolute selected-tree path as execEdit (write + verify).
    const resolved = try @import("codedbpro_paths.zig").sessionAbs(gpa, ctx.io, ctx.agent_cwd, path);
    defer gpa.free(resolved);

    const lock = edit_verify.lockPath(ctx.io, resolved);
    defer lock.unlock(ctx.io);

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const before = Io.Dir.cwd().readFileAlloc(ctx.io, resolved, gpa, .limited(edit_verify.edit_read_cap)) catch |err| {
            if (edit_verify.fsErrorText(gpa, .edit, path, err)) |message| return .{ .text = message, .is_error = true };
            return err;
        };
        defer gpa.free(before);
        const prev_stat = Io.Dir.cwd().statFile(ctx.io, resolved, .{}) catch null;

        var draft: []const u8 = before;
        var owned_draft: ?[]u8 = null;
        defer if (owned_draft) |bytes| gpa.free(bytes);
        for (list.items, 0..) |item, i| {
            // A separate applyEdit would re-read the result before this span.
            // Keep that source-size ceiling without writing an oversized draft.
            if (i > 0 and draft.len > edit_verify.edit_read_cap)
                return spanErr(gpa, i, list.items.len, "intermediate content exceeds the edit source limit");
            if (item != .object) return spanErr(gpa, i, list.items.len, "span is not an object");
            const old = tools.strField(item, "old_string") orelse return spanErr(gpa, i, list.items.len, "missing old_string");
            const new = tools.strField(item, "new_string") orelse return spanErr(gpa, i, list.items.len, "missing new_string");
            if (old.len == 0) return spanErr(gpa, i, list.items.len, "old_string must not be empty");

            const count = std.mem.count(u8, draft, old);
            if (count == 0) {
                const why = try std.fmt.allocPrint(gpa, "old_string not found in {s} — read_file it and match the existing text exactly", .{path});
                defer gpa.free(why);
                return spanErr(gpa, i, list.items.len, why);
            }
            if (count > 1 and !tools.json_args.flag(item, "replace_all")) {
                const why = try std.fmt.allocPrint(gpa, "old_string matches {d} places in {s} — include more surrounding context to make it unique, or set replace_all", .{ count, path });
                defer gpa.free(why);
                return spanErr(gpa, i, list.items.len, why);
            }
            const replaced = try gpa.alloc(u8, std.mem.replacementSize(u8, draft, old, new));
            _ = std.mem.replace(u8, draft, old, new, replaced);
            if (owned_draft) |bytes| gpa.free(bytes);
            owned_draft = replaced;
            draft = replaced;
        }

        if (attempt == 0 and edit_verify.drifted(ctx.io, resolved, prev_stat)) continue;
        if (ctx.snapshots) |snaps| if (!ctx.from_sub) snaps.record(path, .{ .content = before });

        // Stage the complete draft in the destination directory, then rename
        // it into place. This keeps a reader from seeing a truncated batch and
        // preserves the old mode (and a final symlink) like the companion path.
        try credential_store.replaceFile(ctx.io, Io.Dir.cwd(), resolved, draft, .default_file);
        const after = Io.Dir.cwd().readFileAlloc(ctx.io, resolved, gpa, .limited(edit_verify.verify_read_cap)) catch {
            return .{ .text = try edit_verify.verdictText(gpa, path, .unreadable, "the write"), .is_error = true };
        };
        defer gpa.free(after);
        const verdict = edit_verify.verifyNative(before, after, draft);
        if (verdict != .ok) return .{ .text = try edit_verify.verdictText(gpa, path, verdict, "the write"), .is_error = true };
        return .{ .text = try std.fmt.allocPrint(gpa, "applied {d} edit span(s) to {s} (verified)", .{ list.items.len, path }) };
    }
}

fn spanErr(gpa: Allocator, idx: usize, total: usize, why: []const u8) !ToolOutput {
    return .{ .text = try std.fmt.allocPrint(gpa, "edit span {d}/{d} failed: {s} (no batch changes written)", .{ idx + 1, total, why }), .is_error = true };
}

test "execBatch: dependent spans commit together; a bad span leaves the file unchanged" {
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
        \\{"path":"P","edits":[{"old_string":"one","new_string":"1"},{"old_string":"alpha 1","new_string":"ALPHA 1"}]}
    , .{ .allocate = .alloc_always });
    good.object.put(a, "path", .{ .string = rel }) catch unreachable;
    const ok = try execBatch(ctx, good);
    try std.testing.expect(!ok.is_error);
    try std.testing.expect(std.mem.indexOf(u8, ok.text, "2 edit span(s)") != null);
    const data = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("ALPHA 1\nbeta two\ngamma three\n", data);

    var bad = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"gamma","new_string":"3"},{"old_string":"NOT PRESENT","new_string":"x"}]}
    , .{ .allocate = .alloc_always });
    bad.object.put(a, "path", .{ .string = rel }) catch unreachable;
    const err = try execBatch(ctx, bad);
    try std.testing.expect(err.is_error);
    try std.testing.expect(std.mem.indexOf(u8, err.text, "span 2/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.text, "no batch changes written") != null);
    const after = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
    try std.testing.expectEqualStrings(data, after);
}

test "execBatch dispatch rejects malformed edits then accepts a corrected array" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "alpha\nbeta\n" });
    const rel = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{ .gpa = a, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    for ([_][]const u8{ "\"serialized edits\"", "null", "{}", "true", "7" }) |bad| {
        const encoded = try std.fmt.allocPrint(a, "{{\"path\":\"P\",\"edits\":{s}}}", .{bad});
        var input = try std.json.parseFromSliceLeaky(Value, a, encoded, .{ .allocate = .alloc_always });
        try input.object.put(a, "path", .{ .string = rel });
        const out = @import("exec.zig").execTool(ctx, .{ .id = "bad-edit", .name = "edit_file", .input = input });
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "edits must be an array") != null);
        const unchanged = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
        try std.testing.expectEqualStrings("alpha\nbeta\n", unchanged);
    }
    var input = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"alpha","new_string":"ALPHA"},{"old_string":"beta","new_string":"BETA"}]}
    , .{ .allocate = .alloc_always });
    try input.object.put(a, "path", .{ .string = rel });
    const out = @import("exec.zig").execTool(ctx, .{ .id = "corrected-edit", .name = "edit_file", .input = input });
    try std.testing.expect(!out.is_error);
    const changed = try tmp.dir.readFileAlloc(io, "f.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("ALPHA\nBETA\n", changed);
}

test "execBatch rejects a later ambiguous span without partial writes or snapshots" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "alpha beta\nreturn v\nreturn v\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = original });
    const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    defer gpa.free(rel);

    var input_arena = std.heap.ArenaAllocator.init(gpa);
    defer input_arena.deinit();
    const a = input_arena.allocator();
    var input = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[
        \\{"old_string":"alpha","new_string":"ALPHA"},
        \\{"old_string":"beta","new_string":"BETA"},
        \\{"old_string":"return v","new_string":"return value"},
        \\{"old_string":"x4","new_string":"y4"},
        \\{"old_string":"x5","new_string":"y5"},
        \\{"old_string":"x6","new_string":"y6"},
        \\{"old_string":"x7","new_string":"y7"},
        \\{"old_string":"x8","new_string":"y8"},
        \\{"old_string":"x9","new_string":"y9"}]}
    , .{ .allocate = .alloc_always });
    try input.object.put(a, "path", .{ .string = rel });

    var client: std.http.Client = undefined;
    var snapshots: tools.Snapshots = .{ .gpa = gpa, .io = io };
    defer snapshots.deinit();
    var ctx = edit_verify.testCtx(&client);
    ctx.snapshots = &snapshots;
    const result = try execBatch(ctx, input);
    defer gpa.free(result.text);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "edit span 3/9 failed: old_string matches 2 places") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "(no batch changes written)"));
    try std.testing.expectEqual(@as(usize, 0), snapshots.list.items.len);
    const after = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings(original, after);
}

test "execBatch uses selected worktree, replace_all, one snapshot, and preserves mode" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    var selected = std.testing.tmpDir(.{});
    defer selected.cleanup();
    try other.dir.writeFile(io, .{ .sub_path = "task.sh", .data = "old old\n" });
    try selected.dir.writeFile(io, .{
        .sub_path = "task.sh",
        .data = "old old\n",
        .flags = .{ .permissions = @enumFromInt(0o755) },
    });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try selected.dir.realPath(io, &root_buf);
    const root = try gpa.dupe(u8, root_buf[0..root_len]);
    defer gpa.free(root);

    var input_arena = std.heap.ArenaAllocator.init(gpa);
    defer input_arena.deinit();
    const input = try std.json.parseFromSliceLeaky(Value, input_arena.allocator(),
        \\{"path":"task.sh","edits":[{"old_string":"old","new_string":"new","replace_all":true},{"old_string":"new new","new_string":"done"}]}
    , .{});
    var client: std.http.Client = undefined;
    var snapshots: tools.Snapshots = .{ .gpa = gpa, .io = io };
    defer snapshots.deinit();
    var ctx = edit_verify.testCtx(&client);
    ctx.agent_cwd = root;
    ctx.snapshots = &snapshots;
    const result = try execBatch(ctx, input);
    defer gpa.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqual(@as(usize, 1), snapshots.list.items.len);
    try std.testing.expectEqualStrings("old old\n", snapshots.list.items[0].before.content);

    const on_selected = try selected.dir.readFileAlloc(io, "task.sh", gpa, .limited(4096));
    defer gpa.free(on_selected);
    const on_other = try other.dir.readFileAlloc(io, "task.sh", gpa, .limited(4096));
    defer gpa.free(on_other);
    try std.testing.expectEqualStrings("done\n", on_selected);
    try std.testing.expectEqualStrings("old old\n", on_other);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), (try selected.dir.statFile(io, "task.sh", .{})).permissions.toMode() & 0o777);
}

test "execBatch replaces without truncating open readers and rejects symlink paths" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "real.txt", .data = "before\n" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});
    const held = try tmp.dir.openFile(io, "real.txt", .{});
    defer held.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = try gpa.dupe(u8, root_buf[0..root_len]);
    defer gpa.free(root);

    var input_arena = std.heap.ArenaAllocator.init(gpa);
    defer input_arena.deinit();
    const input = try std.json.parseFromSliceLeaky(Value, input_arena.allocator(),
        \\{"path":"real.txt","edits":[{"old_string":"before","new_string":"after"}]}
    , .{});
    var client: std.http.Client = undefined;
    var ctx = edit_verify.testCtx(&client);
    ctx.agent_cwd = root;
    const result = try execBatch(ctx, input);
    defer gpa.free(result.text);
    try std.testing.expect(!result.is_error);

    var old_bytes: [32]u8 = undefined;
    const old_len = try held.readPositionalAll(io, &old_bytes, 0);
    try std.testing.expectEqualStrings("before\n", old_bytes[0..old_len]);
    const new_bytes = try tmp.dir.readFileAlloc(io, "real.txt", gpa, .limited(4096));
    defer gpa.free(new_bytes);
    try std.testing.expectEqualStrings("after\n", new_bytes);
    const via_link = try tmp.dir.readFileAlloc(io, "link.txt", gpa, .limited(4096));
    defer gpa.free(via_link);
    try std.testing.expectEqualStrings("after\n", via_link);
    var link_target: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "link.txt", &link_target);
    try std.testing.expectEqualStrings("real.txt", link_target[0..link_len]);

    const linked_input = try std.json.parseFromSliceLeaky(Value, input_arena.allocator(),
        \\{"path":"link.txt","edits":[{"old_string":"after","new_string":"escaped"}]}
    , .{});
    const refused = try execBatch(ctx, linked_input);
    defer gpa.free(refused.text);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "outside the working directory") != null);
    const unchanged = try tmp.dir.readFileAlloc(io, "real.txt", gpa, .limited(4096));
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("after\n", unchanged);
}

test "execBatch and single edit share the same-file write lock" {
    if (@import("builtin").os.tag == .windows or @import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "slow",
        .data = "#!/bin/sh\ndir=$(dirname \"$0\")\n: > \"$dir/entered\"\nwhile [ ! -e \"$dir/release\" ]; do /bin/sleep 0.01; done\nexit 1\n",
        .flags = .{ .permissions = @enumFromInt(0o755) },
    });
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const stub = try std.fmt.allocPrint(gpa, "{s}/slow", .{real_buf[0..real_len]});
    defer gpa.free(stub);
    const saved = edit_verify.companion_bin;
    defer edit_verify.companion_bin = saved;
    edit_verify.companion_bin = stub;

    const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/f.txt", .{&tmp.sub_path});
    defer gpa.free(rel);
    const resolved = try @import("codedbpro_paths.zig").sessionAbs(gpa, io, null, rel);
    defer gpa.free(resolved);
    var input_arena = std.heap.ArenaAllocator.init(gpa);
    defer input_arena.deinit();
    const a = input_arena.allocator();
    var input = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"first","new_string":"FIRST"},{"old_string":"second","new_string":"SECOND"}]}
    , .{});
    try input.object.put(a, "path", .{ .string = rel });
    var client: std.http.Client = undefined;
    const ctx = edit_verify.testCtx(&client);

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "first\nsecond\nthird\n" });
    var single = try io.concurrent(edit_verify.applyEdit, .{ ctx, rel, resolved, "third", "THIRD", false });
    var entered = false;
    for (0..500) |_| {
        if (tmp.dir.statFile(io, "entered", .{})) |_| {
            entered = true;
            break;
        } else |_| {}
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    if (!entered) try tmp.dir.writeFile(io, .{ .sub_path = "release", .data = "" });
    try std.testing.expect(entered);

    var batch = try io.concurrent(execBatch, .{ ctx, input });
    // The single edit is inside its companion call while holding the stripe.
    // A batch that ignores that stripe would finish and change the file here.
    try io.sleep(.fromMilliseconds(50), .awake);
    const while_blocked = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
    defer gpa.free(while_blocked);
    try tmp.dir.writeFile(io, .{ .sub_path = "release", .data = "" });
    const single_result = try single.await(io);
    defer gpa.free(single_result.text);
    const batch_result = try batch.await(io);
    defer gpa.free(batch_result.text);
    try std.testing.expectEqualStrings("first\nsecond\nthird\n", while_blocked);
    try std.testing.expect(!single_result.is_error);
    try std.testing.expect(!batch_result.is_error);
    const after = try tmp.dir.readFileAlloc(io, "f.txt", gpa, .limited(4096));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("FIRST\nSECOND\nTHIRD\n", after);
}
