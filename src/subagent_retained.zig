//! Family-scoped worker checkpoints. No credentials or live pointers reach disk.
const std = @import("std");
const Io = std.Io;
const tools = @import("tools.zig");
const Agent = @import("agent.zig").Agent;
const identity = @import("proc_identity.zig");
const feedback = @import("subagent_feedback.zig");

pub const Record = struct {
    version: u8 = 1,
    id: []const u8,
    family: []const u8,
    label: []const u8,
    provider: []const u8,
    model: []const u8,
    context: u64 = 128000,
    text_only: bool = false,
    reasoning: @import("main.zig").ReasoningEffort = .medium,
    protocol: ?@import("provider.zig").Provider.Kind = null,
    deadline_ms: ?i64 = null,
    system_prompt: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    messages: []std.json.Value = &.{},
    pending: []const []const u8 = &.{},
    budget_limit: u64 = 0,
    finite_budget: bool = false,
    tool_budget_limit: ?u64 = null,
    pid: i64 = 0,
    start_id: u64 = 0,
    deleted: bool = false,
};
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,
    path: []const u8,
    lock: ?Io.File = null,
    persisted: bool = false,

    pub fn release(self: *State, io: Io) void {
        if (self.lock) |file| file.close(io);
        self.lock = null;
    }
    pub fn deinit(self: *State, gpa: std.mem.Allocator, io: Io) void {
        self.release(io);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub fn family(ctx: tools.ToolCtx) []const u8 {
    return if (ctx.worker_family.len > 0) ctx.worker_family else @import("http_headers.zig").sessionId(ctx.io);
}
pub fn validId(id: []const u8) bool {
    if (id.len != 32) return false;
    for (id) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}
fn pathFor(a: std.mem.Allocator, root: []const u8, owner: []const u8, id: []const u8) ![]const u8 {
    if (!validId(id)) return error.InvalidWorkerId;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(owner, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(a, "{s}/.graff/sessions/{s}/workers/{s}.json", .{ root, hex, id });
}
fn allocate(ctx: tools.ToolCtx, id: []const u8, root_override: ?[]const u8) !*State {
    const state = try ctx.gpa.create(State);
    state.* = .{ .arena = .init(ctx.gpa), .record = undefined, .path = undefined };
    errdefer state.deinit(ctx.gpa, ctx.io);
    const a = state.arena.allocator();
    const root = root_override orelse try Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", a);
    state.path = try pathFor(a, root, family(ctx), id);
    try Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(state.path).?);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{state.path});
    state.lock = try Io.Dir.cwd().createFile(ctx.io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = @import("credential_store.zig").private_file,
    }); // Unsupported locks fail closed; never run two writers on one history.
    return state;
}
pub fn create(ctx: tools.ToolCtx, label: []const u8) !*State {
    var random: [16]u8 = undefined;
    ctx.io.random(&random);
    const id = std.fmt.bytesToHex(random, .lower);
    const state = try allocate(ctx, &id, null);
    errdefer state.deinit(ctx.gpa, ctx.io);
    const a = state.arena.allocator();
    state.record = .{
        .id = try a.dupe(u8, &id),
        .family = try a.dupe(u8, family(ctx)),
        .label = try a.dupe(u8, label),
        .provider = "",
        .model = "",
    };
    return state;
}
pub fn load(ctx: tools.ToolCtx, id: []const u8) !*State {
    return loadAt(ctx, id, null);
}
fn loadAt(ctx: tools.ToolCtx, id: []const u8, root: ?[]const u8) !*State {
    const state = try allocate(ctx, id, root);
    errdefer state.deinit(ctx.gpa, ctx.io);
    const a = state.arena.allocator();
    const data = try Io.Dir.cwd().readFileAlloc(ctx.io, state.path, a, .limited(32 * 1024 * 1024));
    state.record = try std.json.parseFromSliceLeaky(Record, a, data, .{ .allocate = .alloc_always });
    if (state.record.version != 1 or !std.mem.eql(u8, state.record.id, id) or !std.mem.eql(u8, state.record.family, family(ctx))) return error.WorkerOwnershipMismatch;
    if (state.record.deleted) return error.WorkerForgotten;
    return state;
}
pub fn write(io: Io, state: *State) !void {
    const a = state.arena.allocator();
    const data = try std.json.Stringify.valueAlloc(a, state.record, .{});
    defer a.free(data);
    if (data.len > 32 * 1024 * 1024) return error.WorkerHistoryTooLarge;
    const owned_record = try std.json.parseFromSliceLeaky(Record, a, data, .{ .allocate = .alloc_always });
    var file = try Io.Dir.cwd().createFileAtomic(io, state.path, .{ .replace = true, .permissions = @import("credential_store.zig").private_file });
    defer file.deinit(io);
    try file.file.writePositionalAll(io, data, 0);
    try file.replace(io);
    state.record = owned_record;
    state.persisted = true;
}
pub fn budgetAllowed(record: Record, ctx: tools.ToolCtx) bool {
    if (record.deadline_ms) |deadline| if (@import("util.zig").unixMs(ctx.io) >= deadline) return false;
    if (!record.finite_budget and record.budget_limit == 0) return true;
    const budget = ctx.run_budget orelse return false;
    // We cannot reconstruct the root's calls AFTER the last worker checkpoint.
    // A finite budget therefore never silently renews in another process.
    return record.pid == identity.selfPid() and record.start_id != 0 and
        record.start_id == identity.selfStartId(ctx.io) and
        budget.hasFiniteLimits() and (record.tool_budget_limit == null or
        (budget.max_tool_calls != null and budget.max_tool_calls.? <= record.tool_budget_limit.? and budget.toolRemaining() > 0)) and (record.budget_limit == 0 or
        (budget.max_model_calls != 0 and budget.max_model_calls <= record.budget_limit)) and budget.remaining() > 1;
}
pub fn restore(agent: *Agent, ctx: tools.ToolCtx) !void {
    const state = ctx.retained_worker orelse return;
    const record = state.record;
    if (record.messages.len == 0) return;
    if (!budgetAllowed(record, ctx)) return error.RetainedWorkerBudgetUnavailable;
    if (!std.mem.eql(u8, record.provider, agent.provider.id)) return error.RetainedWorkerProviderChanged;
    const cwd = record.cwd orelse return error.RetainedWorkerWorkspaceMissing;
    var dir = Io.Dir.cwd().openDir(ctx.io, cwd, .{}) catch return error.RetainedWorkerWorkspaceMissing;
    dir.close(ctx.io);
    agent.agent_cwd = cwd;
    agent.text_only = record.text_only;
    agent.reasoning = record.reasoning;
    if (record.protocol) |kind| if (kind != agent.provider.kind) return error.RetainedWorkerProtocolChanged;
    if (record.deadline_ms) |deadline| agent.loop_deadline_ms = if (agent.loop_deadline_ms) |current| @min(current, deadline) else deadline;
    try agent.messages.appendSlice(record.messages);
    for (record.pending) |message| try agent.messages.append(try @import("messages.zig").textMessage(agent.arena, "user", message));
}
pub fn checkpoint(agent: *Agent, ctx: tools.ToolCtx) !void {
    const state = ctx.retained_worker orelse return;
    state.record.messages = agent.messages.items;
    state.record.cwd = agent.agent_cwd orelse try Io.Dir.cwd().realPathFileAlloc(ctx.io, ".", state.arena.allocator());
    state.record.provider = agent.provider.id;
    state.record.model = agent.provider.model;
    state.record.context = agent.provider.context;
    state.record.text_only = agent.text_only;
    state.record.reasoning = agent.reasoning;
    state.record.protocol = agent.provider.kind;
    state.record.deadline_ms = agent.loop_deadline_ms;
    state.record.system_prompt = agent.sys_override;
    state.record.pending = &.{};
    state.record.budget_limit = if (ctx.run_budget) |b| b.max_model_calls else 0;
    state.record.finite_budget = if (ctx.run_budget) |b| b.hasFiniteLimits() else false;
    state.record.tool_budget_limit = if (ctx.run_budget) |b| b.max_tool_calls else null;
    state.record.pid = identity.selfPid();
    state.record.start_id = identity.selfStartId(ctx.io);
    try write(ctx.io, state);
}
pub fn enqueue(state: *State, message: []const u8) !void {
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.EmptyMessage;
    if (!std.unicode.utf8ValidateSlice(message)) return error.InvalidUtf8;
    if (message.len > feedback.max_message_bytes) return error.MessageTooLarge;
    if (state.record.pending.len >= feedback.max_pending_messages) return error.InboxFull;
    var bytes: usize = message.len;
    for (state.record.pending) |p| bytes += p.len;
    if (bytes > feedback.max_pending_bytes) return error.InboxFull;
    const a = state.arena.allocator();
    const pending = try a.alloc([]const u8, state.record.pending.len + 1);
    @memcpy(pending[0..state.record.pending.len], state.record.pending);
    pending[pending.len - 1] = try a.dupe(u8, message);
    state.record.pending = pending;
}

const test_id = "0123456789abcdef0123456789abcdef";
fn testContext() tools.ToolCtx {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "NEVER-PERSIST-KEY", .model = "fixture", .context = 1000 }, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .worker_family = "parent-family" };
}
fn fixture(ctx: tools.ToolCtx, root: []const u8) !*State {
    const state = try allocate(ctx, test_id, root);
    state.record = .{ .id = test_id, .family = family(ctx), .label = "worker", .provider = "fixture", .model = "fixture", .cwd = root };
    return state;
}
test "retained worker history round trips without credentials and rejects parallel resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx = testContext();
    const root = try tmp.dir.realPathFileAlloc(ctx.io, ".", ctx.gpa);
    defer ctx.gpa.free(root);
    const state = try fixture(ctx, root);
    defer state.deinit(ctx.gpa, ctx.io);
    ctx.retained_worker = state;
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    var agent: Agent = .{ .sub = true, .label = "worker", .out = null, .gpa = ctx.gpa, .arena = arena.allocator(), .io = ctx.io, .client = undefined, .provider = ctx.provider, .messages = .init(arena.allocator()), .agent_cwd = root };
    try agent.messages.append(try @import("messages.zig").textMessage(agent.arena, "user", "original task"));
    try agent.messages.append(try @import("messages.zig").textMessage(agent.arena, "assistant", "retained evidence"));
    try checkpoint(&agent, ctx);
    const raw = try Io.Dir.cwd().readFileAlloc(ctx.io, state.path, ctx.gpa, .limited(100000));
    defer ctx.gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "NEVER-PERSIST-KEY") == null);
    try std.testing.expectError(error.WouldBlock, loadAt(ctx, test_id, root));
    state.release(ctx.io);
    const loaded = try loadAt(ctx, test_id, root);
    defer loaded.deinit(ctx.gpa, ctx.io);
    try std.testing.expectEqual(@as(usize, 2), loaded.record.messages.len);
    ctx.retained_worker = loaded;
    agent.messages = .init(arena.allocator());
    try restore(&agent, ctx);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings(root, agent.agent_cwd.?);
}
test "retained worker ownership and path validation fail closed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = testContext();
    const root = try tmp.dir.realPathFileAlloc(ctx.io, ".", ctx.gpa);
    defer ctx.gpa.free(root);
    try std.testing.expectError(error.InvalidWorkerId, loadAt(ctx, "../../other", root));
    const state = try fixture(ctx, root);
    defer state.deinit(ctx.gpa, ctx.io);
    state.record.family = "another-parent";
    try write(ctx.io, state);
    state.release(ctx.io);
    try std.testing.expectError(error.WorkerOwnershipMismatch, loadAt(ctx, test_id, root));
}
test "retained worker queue persists without execution and forget tombstones it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ctx = testContext();
    const root = try tmp.dir.realPathFileAlloc(ctx.io, ".", ctx.gpa);
    defer ctx.gpa.free(root);
    const state = try fixture(ctx, root);
    defer state.deinit(ctx.gpa, ctx.io);
    try enqueue(state, "additional evidence");
    try write(ctx.io, state);
    state.release(ctx.io);
    const loaded = try loadAt(ctx, test_id, root);
    defer loaded.deinit(ctx.gpa, ctx.io);
    try std.testing.expectEqual(@as(usize, 0), loaded.record.messages.len);
    try std.testing.expectEqualStrings("additional evidence", loaded.record.pending[0]);
    loaded.record.deleted = true;
    try write(ctx.io, loaded);
    loaded.release(ctx.io);
    try std.testing.expectError(error.WorkerForgotten, loadAt(ctx, test_id, root));
}
test "retained worker finite budget never renews after restart or exhaustion" {
    var ctx = testContext();
    var budget: @import("run_budget.zig").RunBudget = .{ .max_model_calls = 5 };
    ctx.run_budget = &budget;
    var record: Record = .{ .id = test_id, .family = "parent-family", .label = "worker", .provider = "fixture", .model = "fixture", .budget_limit = 5, .pid = identity.selfPid(), .start_id = identity.selfStartId(ctx.io) };
    try std.testing.expect(budgetAllowed(record, ctx));
    budget.model_calls.store(4, .release);
    try std.testing.expect(!budgetAllowed(record, ctx));
    budget.model_calls.store(0, .release);
    record.pid = -1;
    try std.testing.expect(!budgetAllowed(record, ctx));
}
test "retained worker rejects missing workspace rather than using parent cwd" {
    var ctx = testContext();
    var arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer arena.deinit();
    var message = try @import("messages.zig").textMessage(arena.allocator(), "user", "task");
    var state: State = .{ .arena = .init(ctx.gpa), .path = "", .record = .{ .id = test_id, .family = "parent-family", .label = "worker", .provider = "fixture", .model = "fixture", .cwd = "/nonexistent-retained-worker-workspace", .messages = @as(*[1]std.json.Value, &message) } };
    defer state.arena.deinit();
    ctx.retained_worker = &state;
    var agent: Agent = .{ .sub = true, .label = "worker", .out = null, .gpa = ctx.gpa, .arena = arena.allocator(), .io = ctx.io, .client = undefined, .provider = ctx.provider, .messages = .init(arena.allocator()) };
    try std.testing.expectError(error.RetainedWorkerWorkspaceMissing, restore(&agent, ctx));
}

test "retained worker queue bounds reject excess without changing accepted mail" {
    var state: State = .{ .arena = .init(std.testing.allocator), .path = "", .record = .{ .id = test_id, .family = "parent", .label = "worker", .provider = "fixture", .model = "fixture" } };
    defer state.arena.deinit();
    try std.testing.expectError(error.EmptyMessage, enqueue(&state, " "));
    try std.testing.expectError(error.InvalidUtf8, enqueue(&state, "\xff"));
    for (0..feedback.max_pending_messages) |_| try enqueue(&state, "note");
    try std.testing.expectError(error.InboxFull, enqueue(&state, "excess"));
    try std.testing.expectEqual(feedback.max_pending_messages, state.record.pending.len);
}

test "retained worker keeps explicit effort and refuses a changed wire protocol" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ctx = testContext();
    var message = try @import("messages.zig").textMessage(arena.allocator(), "user", "task");
    var state: State = .{ .arena = .init(gpa), .path = "", .record = .{ .id = test_id, .family = "parent-family", .label = "worker", .provider = "fixture", .model = "fixture", .cwd = ".", .messages = @as(*[1]std.json.Value, &message), .reasoning = .high, .protocol = .openai } };
    defer state.arena.deinit();
    ctx.retained_worker = &state;
    var agent: Agent = .{ .sub = true, .label = "worker", .out = null, .gpa = gpa, .arena = arena.allocator(), .io = ctx.io, .client = undefined, .provider = ctx.provider, .messages = .init(arena.allocator()) };
    try restore(&agent, ctx);
    try std.testing.expectEqual(@import("main.zig").ReasoningEffort.high, agent.reasoning);
    agent.provider.kind = .responses;
    try std.testing.expectError(error.RetainedWorkerProtocolChanged, restore(&agent, ctx));
}

test "retained worker cannot resume an expired deadline after parent clears it" {
    const ctx = testContext();
    const record: Record = .{ .id = test_id, .family = "parent-family", .label = "worker", .provider = "fixture", .model = "fixture", .deadline_ms = 1 };
    try std.testing.expect(!budgetAllowed(record, ctx));
}
