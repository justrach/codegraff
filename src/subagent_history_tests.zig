const std = @import("std");
const Io = std.Io;
const tools = @import("tools.zig");
const history = @import("subagent_history.zig");
const retained = @import("subagent_retained.zig");
const Value = std.json.Value;

fn context() tools.ToolCtx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = undefined, .provider = .{ .id = "fixture", .model = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "NOT_HISTORY", .context = 10000 }, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .worker_family = "fork-family" };
}
fn input(a: std.mem.Allocator, source: []const u8) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "fork_from", .{ .string = source });
    return .{ .object = obj };
}
fn messages(a: std.mem.Allocator) ![]Value {
    return (try std.json.parseFromSliceLeaky(Value, a, "[{\"role\":\"user\",\"content\":\"saved evidence\"}]", .{})).array.items;
}

test "fork history source is opt-in and rejects arbitrary paths and nested children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = context();
    try std.testing.expect(try history.fromInput(ctx, .{ .object = .empty }, a) == null);
    try std.testing.expectError(error.InvalidForkSource, history.fromInput(ctx, try input(a, "other.json"), a));
    try std.testing.expectError(error.InvalidSessionName, history.fromInput(ctx, try input(a, "session:../other"), a));
    try std.testing.expectError(error.NothingToFork, history.fromInput(ctx, try input(a, "current"), a));
    ctx.from_sub = true;
    try std.testing.expectError(error.OnlyParentCanFork, history.fromInput(ctx, try input(a, "current"), a));
}

test "fork history detached context owns its snapshot after the parent turn ends" {
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    var owned = @import("subagent_owned.zig").Owned.init(std.testing.allocator);
    defer owned.deinit();
    var ctx = context();
    ctx.parent_messages = try messages(source.allocator());
    ctx.fork_source = try history.fromInput(ctx, try input(source.allocator(), "current"), source.allocator());
    const detached = try owned.context(ctx);
    source.deinit();
    try std.testing.expectEqual(@as(usize, 0), detached.parent_messages.len);
    const snapshot = detached.fork_source.?;
    try std.testing.expectEqualStrings("saved evidence", snapshot.messages[0].object.get("content").?.string);
    const serialized = try std.json.Stringify.valueAlloc(owned.arena.allocator(), snapshot, .{});
    try std.testing.expect(std.mem.indexOf(u8, serialized, "NOT_HISTORY") == null);
    owned.releaseHistory();
    try std.testing.expect(owned.history == null);
}

test "fork history reads a project-local session without adopting credentials or rewriting it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".graff/sessions");
    const raw = "{\"provider\":\"fixture\",\"model\":\"fixture\",\"api_key\":\"NOT_HISTORY\",\"messages\":[{\"role\":\"user\",\"content\":\"saved evidence\"}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".graff/sessions/source.session.json", .data = raw });
    var ctx = context();
    ctx.agent_cwd = try tmp.dir.realPathFileAlloc(ctx.io, ".", a);
    const snapshot = (try history.fromInput(ctx, try input(a, "session:source"), a)).?;
    const serialized = try std.json.Stringify.valueAlloc(a, snapshot, .{});
    try std.testing.expect(std.mem.indexOf(u8, serialized, "saved evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "NOT_HISTORY") == null);
    try std.testing.expectEqualStrings(raw, try tmp.dir.readFileAlloc(ctx.io, ".graff/sessions/source.session.json", a, .unlimited));
    try std.testing.expectError(error.FileNotFound, history.fromInput(ctx, try input(a, "session:missing"), a));
}

test "fork history worker snapshot preserves restrictions ownership and original bytes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var original = try Io.Dir.cwd().openDir(io, ".", .{});
    defer original.close(io);
    defer _ = std.posix.system.fchdir(original.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    var ctx = context();
    const state = try retained.create(ctx, "source");
    defer state.deinit(ctx.gpa, io);
    state.record.provider = "fixture";
    state.record.model = "fixture";
    state.record.protocol = .openai;
    state.record.messages = try messages(a);
    state.record.read_only = true;
    state.record.text_only = true;
    state.record.deadline_ms = @import("util.zig").unixMs(io) + 60000;
    try retained.enqueue(state, "queued only for source");
    try retained.write(io, state);
    state.release(io);
    const source = try std.fmt.allocPrint(a, "worker:{s}", .{state.record.id});
    const before = try Io.Dir.cwd().readFileAlloc(io, state.path, a, .unlimited);
    const snapshot = (try history.fromInput(ctx, try input(a, source), a)).?;
    try std.testing.expect(snapshot.read_only and snapshot.text_only);
    try std.testing.expectEqual(state.record.deadline_ms, snapshot.deadline_ms);
    try std.testing.expectEqual(@as(usize, 1), snapshot.messages.len);
    try std.testing.expectEqualStrings(before, try Io.Dir.cwd().readFileAlloc(io, state.path, a, .unlimited));
    ctx.worker_family = "foreign-family";
    try std.testing.expectError(error.FileNotFound, history.fromInput(ctx, try input(a, source), a));
    ctx.worker_family = "fork-family";
    state.record.finite_budget = true;
    try retained.write(io, state);
    try std.testing.expectError(error.RetainedWorkerBudgetUnavailable, history.fromInput(ctx, try input(a, source), a));
    state.record.finite_budget = false;
    state.record.deadline_ms = 1;
    try retained.write(io, state);
    try std.testing.expectError(error.RetainedWorkerBudgetUnavailable, history.fromInput(ctx, try input(a, source), a));
}

test "fork history seeding cannot relax worker restrictions or deadlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = context();
    var agent: @import("agent.zig").Agent = .{ .gpa = ctx.gpa, .arena = a, .io = ctx.io, .client = undefined, .provider = ctx.provider, .messages = std.json.Array.init(a), .sub = true, .label = "fork", .out = null, .loop_deadline_ms = 5 };
    const snapshot: history.Snapshot = .{ .messages = try messages(a), .provider = "fixture", .model = "fixture", .protocol = .openai, .read_only = true, .text_only = true, .deadline_ms = 10 };
    try snapshot.seed(&agent);
    try std.testing.expect(agent.read_only and agent.text_only);
    try std.testing.expectEqual(@as(?i64, 5), agent.loop_deadline_ms);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
}
