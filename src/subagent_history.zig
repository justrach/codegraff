//! Explicit conversation snapshots for fresh workers. Never restore root runtime state.
const std = @import("std");
const tools = @import("tools.zig");
const Provider = @import("provider.zig").Provider;
const retained = @import("subagent_retained.zig");
const session = @import("session.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Snapshot = struct {
    messages: []const Value,
    provider: []const u8,
    model: []const u8,
    protocol: Provider.Kind,
    read_only: bool = false,
    text_only: bool = false,
    deadline_ms: ?i64 = null,

    pub fn clone(self: Snapshot, a: Allocator) !Snapshot {
        var result = self;
        const bytes = try std.json.Stringify.valueAlloc(a, self.messages, .{});
        defer a.free(bytes);
        result.messages = (try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always })).array.items;
        result.provider = try a.dupe(u8, self.provider);
        result.model = try a.dupe(u8, self.model);
        return result;
    }

    pub fn seed(self: Snapshot, agent: *@import("agent.zig").Agent) !void {
        const source: Provider = .{ .id = self.provider, .model = self.model, .kind = self.protocol, .auth = .bearer, .url = "", .api_key = "", .context = 0 };
        agent.messages = try @import("subagent_history_copy.zig").copy(agent.arena, self.messages, source, agent.provider);
        if (agent.messages.items.len == 0) return error.NothingToFork;
        agent.compaction_window = try @import("compaction_window.zig").State.restore(agent.arena, .empty, agent.messages.items);
        agent.read_only = agent.read_only or self.read_only;
        agent.text_only = agent.text_only or self.text_only;
        if (self.deadline_ms) |deadline| agent.loop_deadline_ms = if (agent.loop_deadline_ms) |current| @min(current, deadline) else deadline;
    }
};

/// Resolve only explicit project-local names and family-owned worker ids.
/// No source credentials, approvals, cwd, goals, or live handles are adopted.
pub fn fromInput(ctx: tools.ToolCtx, input: Value, a: Allocator) !?Snapshot {
    if (input != .object) return error.InvalidForkSource;
    const value = input.object.get("fork_from") orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidForkSource;
    if (ctx.from_sub) return error.OnlyParentCanFork;
    const source = value.string;
    if (std.mem.eql(u8, source, "current")) {
        if (ctx.parent_messages.len == 0) return error.NothingToFork;
        return try (Snapshot{
            .messages = ctx.parent_messages,
            .provider = ctx.provider.id,
            .model = ctx.provider.model,
            .protocol = ctx.provider.kind,
            .read_only = ctx.read_only_shell,
            .deadline_ms = ctx.loop_deadline_ms,
        }).clone(a);
    }
    if (std.mem.startsWith(u8, source, "worker:")) {
        const state = try retained.load(ctx, source["worker:".len..]);
        defer state.deinit(ctx.gpa, ctx.io);
        const record = state.record;
        if (!retained.budgetAllowed(record, ctx)) return error.RetainedWorkerBudgetUnavailable;
        if (record.messages.len == 0) return error.NothingToFork;
        return try (Snapshot{
            .messages = record.messages,
            .provider = record.provider,
            .model = record.model,
            .protocol = record.protocol orelse protocol(record.provider, record.model),
            .read_only = record.read_only,
            .text_only = record.text_only,
            .deadline_ms = record.deadline_ms,
        }).clone(a);
    }
    if (!std.mem.startsWith(u8, source, "session:")) return error.InvalidForkSource;
    const name = source["session:".len..];
    if (!session.validSessionName(name)) return error.InvalidSessionName;
    session.flushSaves();
    const relative = try session.sessionPath(a, name);
    const path = if (ctx.agent_cwd) |cwd| try std.fs.path.join(a, &.{ cwd, relative }) else relative;
    const data = try std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(@import("session_index.zig").max_session_bytes));
    const saved = try std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always });
    if (saved != .object) return error.BadSession;
    const history = saved.object.get("messages") orelse return error.BadSession;
    if (history != .array) return error.BadSession;
    if (history.array.items.len == 0) return error.NothingToFork;
    const provider = tools.strField(saved, "provider") orelse return error.BadSession;
    const model = tools.strField(saved, "model") orelse return error.BadSession;
    // Imported saves contain Anthropic-shaped historical receipts regardless of route metadata.
    const imported = tools.strField(saved, "imported_from") orelse "";
    return .{
        .messages = history.array.items,
        .provider = provider,
        .model = model,
        .protocol = if (std.mem.eql(u8, imported, "claude")) .anthropic else protocol(provider, model),
    };
}

fn protocol(id: []const u8, model: []const u8) Provider.Kind {
    const base: Provider = .{ .id = id, .model = model, .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .context = 0 };
    return base.withModel(model).kind;
}
