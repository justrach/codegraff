//! Early Responses execution. Jobs own arguments and join before the next request.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const tools = @import("tools.zig");
const batch = @import("agent_tool_batch.zig");
const policy = @import("async_tool_policy.zig");
const Job = struct {
    call: tools.ToolCall,
    history_seen: bool = false,
    announced: bool = false,
    presented: bool = false,
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,
    output: ?tools.ToolOutput = null,
    result: ?tools.ExecResult = null,
};
pub const State = struct {
    arena: std.heap.ArenaAllocator,
    jobs: std.ArrayList(*Job) = .empty,
    barrier: bool = false,
};

pub fn started(self: *const Agent) bool {
    const state = self.async_tools orelse return false;
    return state.jobs.items.len != 0;
}

pub fn join(self: *Agent) !void {
    const state = self.async_tools orelse return;
    if (state.jobs.items.len == 0) return;
    if (started(self) and Agent.esc_cancel.load(.acquire)) return error.Interrupted;
    const main = @import("main.zig");
    const tty = @import("term.zig").tty;
    var terminal: ?tty.RawState = null;
    var watcher: ?std.Io.Future(void) = null;
    if (!self.sub and self.in != null and main.use_color and !main.json_mode) {
        terminal = Agent.rawNonblockStdin();
        if (terminal != null) {
            Agent.esc_watch_done.store(false, .release);
            watcher = self.io.async(Agent.escWatchTask, .{});
        }
    }
    defer if (terminal) |saved| {
        Agent.esc_watch_done.store(true, .release);
        if (watcher) |*f| f.await(self.io);
        Agent.drainStdin();
        tty.restore(saved);
    };
    for (state.jobs.items) |job| if (job.future) |*f| {
        while (!job.done.load(.acquire)) {
            if (Agent.esc_cancel.load(.acquire)) return error.Interrupted;
            try std.Io.sleep(self.io, .fromMilliseconds(10), .awake);
        }
        f.await(self.io);
        job.future = null;
    };
}

pub fn reset(self: *Agent) void {
    const state = self.async_tools orelse return;
    for (state.jobs.items) |job| {
        if (job.future) |*f| f.cancel(self.io);
        if (job.announced and !job.presented) self.sayToolResult(job.call, .{
            .text = "async tool result discarded because the response was interrupted",
            .is_error = true,
            .cancelled = true,
        });
        if (job.output) |output| self.gpa.free(output.text);
    }
    state.arena.deinit();
    self.gpa.destroy(state);
    self.async_tools = null;
}

fn execute(job: *Job, ctx: tools.ToolCtx) void {
    defer job.done.store(true, .release);
    job.output = @import("exec.zig").execTool(ctx, job.call);
}

/// No allocations or tool work for unsupported providers/models.
pub fn onLine(self: *Agent, raw: []const u8) void {
    if (!self.async_tools_armed or self.eval_cmd != null or !policy.enabled(self.provider) or self.compaction_request or self.server_compaction_request) return;
    const payload = if (std.mem.startsWith(u8, raw, "data:")) std.mem.trim(u8, raw[5..], " \r\n") else raw;
    if (std.mem.indexOf(u8, payload, "response.output_item.") == null) return;
    const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, payload, .{}) catch return;
    defer parsed.deinit();
    onEvent(self, parsed.value) catch {
        // Admission failure must not reopen early execution later in this response.
        if (self.async_tools) |state| state.barrier = true;
    };
}

fn onEvent(self: *Agent, event: std.json.Value) !void {
    if (event != .object) return;
    const ty = event.object.get("type") orelse return;
    if (ty != .string) return;
    const complete = std.mem.eql(u8, ty.string, "response.output_item.done");
    if (!complete and !std.mem.eql(u8, ty.string, "response.output_item.added")) return;
    const item = event.object.get("item") orelse return;
    if (item != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "message") or std.mem.eql(u8, kind.string, "reasoning")) return;
    // Hosted schema discovery has no pending local execution or mutations.
    // Deferred direct tools must still be able to start after being discovered.
    if (std.mem.eql(u8, kind.string, "tool_search_call") or std.mem.eql(u8, kind.string, "tool_search_output")) return;
    if (self.async_tools == null) {
        const state = try self.gpa.create(State);
        state.* = .{ .arena = .init(self.gpa) };
        self.async_tools = state;
    }
    const state = self.async_tools.?;
    if (state.barrier) return;
    const id = item.object.get("call_id");
    if (id) |v| if (v == .string) for (state.jobs.items) |job| {
        if (std.mem.eql(u8, job.call.id, v.string)) return;
    };
    const name = item.object.get("name");
    const asynchronous = item.object.get("async");
    if (!std.mem.eql(u8, kind.string, "function_call") or name == null or name.? != .string or
        !policy.eligible(name.?.string) or asynchronous == null or asynchronous.? != .bool or !asynchronous.?.bool or
        item.object.contains("caller") or id == null or id.? != .string or id.?.string.len == 0)
    {
        state.barrier = true;
        return;
    }
    if (!complete) return;
    const args = item.object.get("arguments") orelse {
        state.barrier = true;
        return;
    };
    if (args != .string) {
        state.barrier = true;
        return;
    }
    const arena = state.arena.allocator();
    const input = @import("tool_call_args.zig").parse(arena, args.string);
    const job = try arena.create(Job);
    job.* = .{ .call = .{
        .id = try arena.dupe(u8, id.?.string),
        .name = try arena.dupe(u8, name.?.string),
        .input = input.input,
        .args_ok = input.valid,
    } };
    // Publish before admission: any admitted/rejected call must be claimed once.
    try state.jobs.append(arena, job);
    job.result = .{ .text = "async tool admission failed", .is_error = true };
    if (try self.rejectToolCall(job.call)) |denied| {
        job.result = denied;
        return;
    }
    try self.sayToolUse(job.call);
    job.announced = true;
    if (try self.gateTool(job.call)) |denied| {
        job.result = denied;
        return;
    }
    var ctx = batch.context(self);
    // These fields are owner-thread state. webfetch does not need them.
    ctx.read_miss = null;
    ctx.publication_observer = null;
    job.future = self.io.concurrent(execute, .{ job, ctx }) catch {
        job.result = .{ .text = "async tool worker unavailable", .is_error = true };
        return;
    };
    job.result = null;
}

pub fn claim(self: *Agent, call: tools.ToolCall) !?tools.ExecResult {
    const state = self.async_tools orelse return null;
    for (state.jobs.items) |job| {
        if (!std.mem.eql(u8, job.call.id, call.id)) continue;
        if (job.future) |*f| {
            f.await(self.io);
            job.future = null;
        }
        if (job.result) |result| return result;
        const output = job.output orelse return error.AsyncToolMissingResult;
        job.result = try batch.takeOutput(self, job.call, output, @import("tool_handle.zig").effectiveThreshold(self.provider.perOutputCap()), batch.handleTarget(self));
        return job.result;
    }
    return null;
}

pub fn duplicateItem(self: *Agent, item: std.json.Value) bool {
    const state = self.async_tools orelse return false;
    if (item != .object) return false;
    const kind = item.object.get("type") orelse return false;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function_call")) return false;
    const id = item.object.get("call_id") orelse return false;
    if (id != .string) return false;
    for (state.jobs.items) |job| if (std.mem.eql(u8, job.call.id, id.string)) {
        if (job.history_seen) return true;
        job.history_seen = true;
        return false;
    };
    return false;
}

const fixture_event = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"async\":true,\"call_id\":\"fetch-1\",\"name\":\"webfetch\",\"arguments\":\"{\\\"url\\\":\\\"invalid://fixture\\\"}\"}}";
fn fixture(arena: std.mem.Allocator, client: *std.http.Client) Agent {
    return .{ .gpa = std.testing.allocator, .arena = arena, .io = std.testing.io, .client = client, .provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-astra", .context = 100_000 }, .async_tools_armed = true, .messages = .init(arena), .sub = false, .label = "fixture", .out = null };
}

test "async tools complete call dispatches once in headless mode and claims once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = fixture(arena.allocator(), &client);
    defer reset(&agent);
    defer agent.tools_used.deinit(agent.gpa);
    onLine(&agent, "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"tool_search_call\"}}");
    onLine(&agent, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"tool_search_call\"}}");
    onLine(&agent, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"tool_search_output\"}}");
    try std.testing.expect(agent.async_tools == null);
    @import("agent_stream.zig").printDelta(&agent, fixture_event);
    @import("agent_stream.zig").printDelta(&agent, fixture_event);
    try std.testing.expectEqual(@as(usize, 1), agent.async_tools.?.jobs.items.len);
    try std.testing.expectEqual(@as(usize, 1), agent.tool_calls_this_turn);
    try join(&agent);
    const call = agent.async_tools.?.jobs.items[0].call;
    const result = (try claim(&agent, call)).?;
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings(result.text, (try claim(&agent, call)).?.text);
    const results = try agent.runTools(&.{call});
    try std.testing.expectEqual(@as(usize, 1), agent.tool_calls_this_turn);
    try std.testing.expect(results[0].is_error);
    try std.testing.expect(agent.async_tools == null);
}

test "async tools do not cross a synchronous predecessor or execute partial arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = fixture(arena.allocator(), &client);
    defer reset(&agent);
    onLine(&agent, "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\"}");
    try std.testing.expect(agent.async_tools == null);
    onLine(&agent, "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"name\":\"write_file\"}}");
    onLine(&agent, fixture_event);
    try std.testing.expect(!started(&agent));
    const saved_cancel = Agent.esc_cancel.swap(true, .acq_rel);
    defer Agent.esc_cancel.store(saved_cancel, .release);
    try join(&agent); // a barrier with no jobs has nothing to watch or cancel
    try std.testing.expectEqual(@as(usize, 0), agent.tool_calls_this_turn);
    reset(&agent);
    onLine(&agent, "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"name\":\"write_file\"}}");
    onLine(&agent, fixture_event);
    try std.testing.expect(!started(&agent));
}

test "async tools reset cancels and joins workers before freeing owned state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = fixture(arena.allocator(), &client);
    const state = try agent.gpa.create(State);
    state.* = .{ .arena = .init(agent.gpa) };
    agent.async_tools = state;
    defer reset(&agent);
    const job = try state.arena.allocator().create(Job);
    job.* = .{ .call = .{ .id = "cancel", .name = "webfetch", .input = .null } };
    try state.jobs.append(state.arena.allocator(), job);
    const Worker = struct {
        fn run(io: std.Io, entered: *std.atomic.Value(bool), exited: *std.atomic.Value(bool)) void {
            defer exited.store(true, .release);
            entered.store(true, .release);
            std.Io.sleep(io, .fromSeconds(60), .awake) catch return;
        }
    };
    var entered: std.atomic.Value(bool) = .init(false);
    var exited: std.atomic.Value(bool) = .init(false);
    job.future = try agent.io.concurrent(Worker.run, .{ agent.io, &entered, &exited });
    while (!entered.load(.acquire)) try std.Io.sleep(agent.io, .fromMilliseconds(1), .awake);
    reset(&agent);
    try std.testing.expect(exited.load(.acquire));
    try std.testing.expect(agent.async_tools == null);
}

test "async tools reject malformed args and remain inert outside armed turns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = fixture(arena.allocator(), &client);
    defer reset(&agent);
    agent.async_tools_armed = false;
    onLine(&agent, fixture_event);
    try std.testing.expect(agent.async_tools == null);
    agent.async_tools_armed = true;
    agent.eval_cmd = "true";
    onLine(&agent, fixture_event);
    try std.testing.expect(agent.async_tools == null);
    agent.eval_cmd = null;
    const malformed = "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"async\":true,\"call_id\":\"bad\",\"name\":\"webfetch\",\"arguments\":\"[]\"}}";
    onLine(&agent, malformed);
    const job = agent.async_tools.?.jobs.items[0];
    try std.testing.expect(job.future == null);
    try std.testing.expect(job.result.?.is_error);
    const event = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), malformed[6..], .{});
    const item = event.object.get("item").?;
    try std.testing.expect(!duplicateItem(&agent, item));
    try std.testing.expect(duplicateItem(&agent, item));
}

/// Called at the terminal frontend event boundary, including exceptional cleanup.
pub fn presented(self: *Agent, call: tools.ToolCall) void {
    const state = self.async_tools orelse return;
    for (state.jobs.items) |job| if (std.mem.eql(u8, job.call.id, call.id)) {
        job.presented = true;
        return;
    };
}

test "async tools interrupted and delivered calls each close frontend lifecycle once" {
    const Sink = struct {
        starts: usize = 0,
        results: usize = 0,
        finishes: usize = 0,
        cancelled: bool = false,
        fn emit(ctx: *anyopaque, event: @import("engine_sink.zig").Stamped) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event.event) {
                .tool_call_started => |call| {
                    std.debug.assert(std.mem.eql(u8, call.id, "fetch-1"));
                    self.starts += 1;
                },
                .tool_result => |result| {
                    self.results += 1;
                    self.cancelled = result.cancelled;
                },
                .tool_call_finished => self.finishes += 1,
                else => {},
            }
        }
        const vt: @import("engine_sink.zig").VTable = .{ .emit = emit, .durable = false };
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = fixture(arena.allocator(), &client);
    defer reset(&agent);
    defer agent.tools_used.deinit(agent.gpa);
    var sink: Sink = .{};
    agent.sink = .{ .ctx = &sink, .vt = &Sink.vt };
    onLine(&agent, fixture_event);
    reset(&agent); // failed response: cancellation joins before terminal events/free
    reset(&agent);
    try std.testing.expectEqual(@as(usize, 1), sink.starts);
    try std.testing.expectEqual(@as(usize, 1), sink.results);
    try std.testing.expectEqual(@as(usize, 1), sink.finishes);
    try std.testing.expect(sink.cancelled);
    sink = .{};
    onLine(&agent, fixture_event);
    try join(&agent);
    const call = agent.async_tools.?.jobs.items[0].call;
    _ = try agent.runTools(&.{call}); // ordinary delivery, followed by reset
    reset(&agent);
    try std.testing.expectEqual(@as(usize, 1), sink.starts);
    try std.testing.expectEqual(@as(usize, 1), sink.results);
    try std.testing.expectEqual(@as(usize, 1), sink.finishes);
    try std.testing.expect(!sink.cancelled);
}
