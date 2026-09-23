//! Native, opt-in Jev effort selector. One failed upstream attempt opens a
//! session-long circuit: later calls skip the network and return control to
//! the main model. No MCP process and no automatic context transfer.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Provider = @import("provider.zig").Provider;
const ToolCtx = @import("tools.zig").ToolCtx;
const ToolOutput = @import("tools.zig").ToolOutput;
const ToolSpec = @import("schema.zig").ToolSpec;
const scope = @import("jev_model_scope.zig");
const effort_route = @import("effort_route.zig");
const ReasoningEffort = @import("main.zig").ReasoningEffort;
const pricing = @import("pricing.zig");
const buffered_https = @import("http2_buffered.zig");

pub const name = "jev_effort";
pub const description = "Optionally ask Jev to choose the reasoning effort for the next request on an eligible GPT-6 or MiMo v2.6 model. Give only a short non-sensitive task summary. This changes the session effort; it does not judge an answer or action. Never send code, secrets, customer data, or paths. A failed or invalid selection leaves effort unchanged.";
pub const input_schema =
    \\{"type":"object","properties":{"task":{"type":"string","description":"Short non-sensitive summary of the next task; no code, paths or secrets"}},"required":["task"],"additionalProperties":false}
;
const spec = ToolSpec{ .name = name, .desc = description, .schema = input_schema };
const endpoint = "https://gateway.codegraff.com/v1/systemone";
const skip_text = "Jev effort selection unavailable; session effort is unchanged. No more Jev requests will be sent this session.";
const auth_skip_text = "Jev effort selection unavailable (Codegraff authorization failed); session effort is unchanged.";
const credit_skip_text = "Jev effort selection unavailable (Codegraff credits or key budget); session effort is unchanged.";
const rate_skip_text = "Jev effort selection unavailable (Codegraff rate limit); session effort is unchanged.";
const Backend = enum { gateway, mock, mock_fail };
const State = struct {
    mu: Io.Mutex = .init,
    key: []const u8 = "",
    backend: Backend = .gateway,
    codegraff_login: std.atomic.Value(bool) = .init(false),
    down: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(false),
    attempts: std.atomic.Value(usize) = .init(0),
};
var state: State = .{};

pub fn configure(env: anytype) void {
    // Only a persisted Codegraff login may supply the gateway credential.
    // The provider's own key and any upstream-specific environment key are ignored.
    state.key = "";
    state.codegraff_login.store(false, .release);
    const mode = env.get("JEV_BACKEND") orelse "";
    state.backend = if (std.mem.eql(u8, mode, "mock")) .mock else if (std.mem.eql(u8, mode, "mock-fail")) .mock_fail else .gateway;
    state.down.store(false, .release);
    state.refresh.store(false, .release);
    state.attempts.store(0, .release);
}

/// Returns true when a login transition changes the live tool catalog.
pub fn setCodegraffLoginKey(io: Io, key: ?[]const u8) bool {
    state.mu.lockUncancelable(io);
    defer state.mu.unlock(io);
    const was_present = state.codegraff_login.load(.acquire);
    state.key = key orelse "";
    const present = state.key.len > 0;
    state.codegraff_login.store(present, .release);
    return was_present != present;
}

pub fn available(provider: Provider) bool {
    return state.codegraff_login.load(.acquire) and
        !state.down.load(.acquire) and scope.eligible(provider);
}

/// A model switch can change Jev visibility even when the wire format stays the same.
pub fn updateProvider(root: anytype, p: Provider) void {
    // A switch away and back must not revive a selection from the old route.
    root.jev_effort_pending.invalidate(root.io);
    // Each wire format has its own cached catalog. An older catalog for the
    // destination format may have been built before Jev became available.
    if (available(root.provider) != available(p) or
        (root.provider.kind != p.kind and (available(root.provider) or available(p))))
        root.invalidateRootTools();
    root.provider = p;
}

pub fn catalogExtras(provider: Provider) []const ToolSpec {
    return if (available(provider)) &.{spec} else &.{};
}

pub fn takeCatalogRefresh() bool {
    return state.refresh.swap(false, .acq_rel);
}

pub fn refreshCatalogForRequest(root: anytype, tools_in: ?[]const u8) !?[]const u8 {
    // RLM calls host tools directly, so runTools may not observe a failed
    // Jev call. Replace the caller's pre-refresh catalog snapshot here.
    if (root.sub or !takeCatalogRefresh()) return tools_in;
    root.invalidateRootTools();
    try root.ensureRootTools(root.provider.kind);
    return if (tools_in == null) null else root.toolsJson();
}

fn skipped(gpa: Allocator) !ToolOutput {
    return .{ .text = try gpa.dupe(u8, skip_text) };
}

fn invalid(gpa: Allocator, text: []const u8) !ToolOutput {
    return .{ .text = try gpa.dupe(u8, text), .is_error = true };
}

fn string(v: Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}

fn number(v: Value) ?f64 {
    return switch (v) {
        .float => |n| if (std.math.isFinite(n)) n else null,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn effortDescription(tag: []const u8) []const u8 {
    if (std.mem.eql(u8, tag, "none")) return "Off: no model reasoning";
    if (std.mem.eql(u8, tag, "low")) return "Low: simple work";
    if (std.mem.eql(u8, tag, "medium")) return "Medium: ordinary work";
    if (std.mem.eql(u8, tag, "high")) return "High: complex work or MiMo thinking On";
    if (std.mem.eql(u8, tag, "xhigh")) return "Extra high: demanding work";
    return "Ultra: hardest work with delegation";
}

fn makeBody(arena: Allocator, input: Value, provider: Provider) ![]const u8 {
    const obj = input.object;
    if (obj.count() != 1) return error.InvalidInput;
    const task = string(obj.get("task") orelse return error.InvalidInput) orelse return error.InvalidInput;
    if (task.len == 0 or task.len > 512) return error.InvalidInput;
    var q = std.json.ObjectMap.empty;
    try q.put(arena, "type", .{ .string = "choice" });
    try q.put(arena, "instructions", .{ .string = "Choose one reasoning effort for the next model request. Use only the supplied task summary and the fixed available levels. Prefer the least effort sufficient for the task." });
    var labels = std.json.ObjectMap.empty;
    for (effort_route.levels(provider.id, provider.model)) |tag|
        try labels.put(arena, tag, .{ .string = effortDescription(tag) });
    try q.put(arena, "criteria", .{ .object = labels });
    var questions = std.json.ObjectMap.empty;
    try questions.put(arena, "q1", .{ .object = q });
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "model", .{ .string = "jev-latest" });
    try root.put(arena, "state", .{ .string = task });
    try root.put(arena, "questions", .{ .object = questions });
    var aw: Io.Writer.Allocating = .init(arena);
    var serializer: std.json.Stringify = .{ .writer = &aw.writer };
    try serializer.write(Value{ .object = root });
    return aw.writer.buffered();
}

fn mockResponse(arena: Allocator) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .answers = .{ .q1 = .{ .type = "choice", .choice = "high", .confidence = 0.95 } } });
    return aw.writer.buffered();
}

fn gatewayBearer(arena: Allocator, key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Bearer {s}", .{key});
}

fn skipForError(err: anyerror) []const u8 {
    return switch (err) {
        error.JevUnauthorized => auth_skip_text,
        error.JevNoCredits => credit_skip_text,
        error.JevRateLimited => rate_skip_text,
        else => skip_text,
    };
}

fn usageCount(v: Value) ?i64 {
    return if (v == .integer and v.integer >= 0) v.integer else null;
}

fn settledCharge(body: Value) ?u64 {
    if (body != .object) return null;
    const receipt = body.object.get("codegraff_billing") orelse return null;
    if (receipt != .object) return null;
    const settled = receipt.object.get("settled") orelse return null;
    const currency = receipt.object.get("currency") orelse return null;
    const charge = receipt.object.get("charge_micro_usd") orelse return null;
    if (settled != .bool or !settled.bool or currency != .string or
        !std.mem.eql(u8, currency.string, "USD") or charge != .integer or
        charge.integer < 0 or charge.integer > 9_007_199_254_740_991) return null;
    return @intCast(charge.integer);
}

fn noteGatewayUsage(io: Io, tally: *pricing.CostTally, arena: Allocator, raw: []const u8) void {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch {
        tally.missingUsage(io);
        return;
    };
    const usage = if (parsed == .object) parsed.object.get("usage") orelse .null else Value.null;
    if (usage == .object) {
        const input = usageCount(usage.object.get("input_tokens") orelse .null);
        const output = usageCount(usage.object.get("output_tokens") orelse .null);
        if (input != null and output != null) {
            // This parser is called only for the authenticated gateway endpoint.
            // A published list rate cannot replace a confirmed charge receipt.
            if (settledCharge(parsed)) |charge| {
                tally.addSettled(io, input.?, output.?, charge);
            } else {
                tally.addForProvider(io, .unpriced, "codegraff", "jev-latest", input.?, 0, 0, output.?);
            }
            return;
        }
    }
    tally.missingUsage(io);
}

fn fetch(ctx: ToolCtx, arena: Allocator, body: []const u8) ![]const u8 {
    const bearer = try gatewayBearer(arena, state.key);
    var completed = false;
    defer if (!completed) pricing.g_cost.failedWithoutUsage(ctx.io, 1);
    const res = try buffered_https.post(ctx.gpa, arena, ctx.io, ctx.client, endpoint, bearer, body, 10_000);
    switch (res.status) {
        200 => {},
        401, 403 => return error.JevUnauthorized,
        402 => return error.JevNoCredits,
        429 => return error.JevRateLimited,
        else => return error.JevUnavailable,
    }
    noteGatewayUsage(ctx.io, &pricing.g_cost, arena, res.body);
    completed = true;
    return res.body;
}

fn selectedEffort(arena: Allocator, provider: Provider, raw: []const u8) !ReasoningEffort {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidResponse;
    const answers = parsed.object.get("answers") orelse return error.InvalidResponse;
    if (answers != .object) return error.InvalidResponse;
    const answer = answers.object.get("q1") orelse return error.InvalidResponse;
    if (answer != .object) return error.InvalidResponse;
    const answer_type = string(answer.object.get("type") orelse return error.InvalidResponse) orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, answer_type, "choice")) return error.InvalidResponse;
    const label = string(answer.object.get("choice") orelse return error.InvalidResponse) orelse return error.InvalidResponse;
    if (!effort_route.allows(provider.id, provider.model, label)) return error.InvalidResponse;
    if (answer.object.get("confidence")) |reported| {
        const confidence = number(reported) orelse return error.InvalidResponse;
        if (confidence < 0 or confidence > 1) return error.InvalidResponse;
    }
    return std.meta.stringToEnum(ReasoningEffort, label) orelse error.InvalidResponse;
}

pub fn execute(ctx: ToolCtx, input: Value) !ToolOutput {
    if (ctx.from_sub) return invalid(ctx.gpa, "jev_effort is available only to the root agent");
    if (!state.codegraff_login.load(.acquire)) return invalid(ctx.gpa, "jev_effort requires a Codegraff login (`graff login`)");
    if (!scope.eligible(ctx.provider)) return invalid(ctx.gpa, "jev_effort is available only with Codex/OpenAI GPT-6 or Xiaomi MiMo v2.6 models");
    if (state.down.load(.acquire)) return skipped(ctx.gpa);
    if (input != .object) return invalid(ctx.gpa, "jev_effort needs one short task summary");
    const pending = ctx.jev_effort_pending orelse return invalid(ctx.gpa, "jev_effort needs an active session");
    var temp = std.heap.ArenaAllocator.init(ctx.gpa);
    defer temp.deinit();
    const arena = temp.allocator();
    const body = makeBody(arena, input, ctx.provider) catch |err| switch (err) {
        error.InvalidInput => return invalid(ctx.gpa, "jev_effort accepts only a short task summary"),
        else => return err,
    };
    const token = pending.begin(ctx.io, ctx.provider) orelse return invalid(ctx.gpa, "jev_effort already has a selection in progress or awaiting application");
    defer pending.abort(ctx.io, token);
    state.mu.lockUncancelable(ctx.io);
    defer state.mu.unlock(ctx.io);
    if (state.key.len == 0) return invalid(ctx.gpa, "jev_effort requires a Codegraff login (`graff login`)");
    if (state.down.load(.acquire)) return skipped(ctx.gpa);
    _ = state.attempts.fetchAdd(1, .acq_rel);
    const raw = switch (state.backend) {
        .mock => try mockResponse(arena),
        .mock_fail => error.JevUnavailable,
        .gateway => fetch(ctx, arena, body),
    } catch |err| {
        state.down.store(true, .release);
        state.refresh.store(true, .release);
        return .{ .text = try ctx.gpa.dupe(u8, skipForError(err)) };
    };
    const selected = selectedEffort(arena, ctx.provider, raw) catch {
        state.down.store(true, .release);
        state.refresh.store(true, .release);
        return skipped(ctx.gpa);
    };
    if (!pending.commit(ctx.io, token, selected)) return invalid(ctx.gpa, "jev_effort selection was canceled");
    return .{ .text = try std.fmt.allocPrint(ctx.gpa, "reasoning effort selected: {s}; applies at the next request boundary", .{@tagName(selected)}) };
}

test "native Jev failure makes exactly one attempt then skips without retry" {
    const fake = struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "JEV_BACKEND")) "mock-fail" else null;
        }
    }{};
    configure(fake);
    defer configure(struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    }{});
    _ = setCodegraffLoginKey(std.testing.io, "synthetic-login");
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    var client: std.http.Client = undefined;
    var pending: @import("jev_effort_state.zig").Pending = .{};
    const ctx: ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = p, .jev_effort_pending = &pending, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"task\":\"choose effort for a small test fix\"}", .{});
    defer parsed.deinit();
    const first = try execute(ctx, parsed.value);
    defer std.testing.allocator.free(first.text);
    const second = try execute(ctx, parsed.value);
    defer std.testing.allocator.free(second.text);
    try std.testing.expect(!first.is_error and !second.is_error);
    try std.testing.expectEqualStrings(skip_text, first.text);
    try std.testing.expectEqualStrings(skip_text, second.text);
    try std.testing.expectEqual(@as(usize, 1), state.attempts.load(.acquire));
    try std.testing.expect(!available(p));
    try std.testing.expect(takeCatalogRefresh());
    try std.testing.expect(!takeCatalogRefresh());
}

test "native Jev mock sends fixed effort choices and queues the next effort" {
    configure(struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "JEV_BACKEND")) "mock" else null;
        }
    }{});
    defer configure(struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    }{});
    _ = setCodegraffLoginKey(std.testing.io, "synthetic-login");
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"task\":\"fix a complex failing test\"}", .{});
    defer parsed.deinit();
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    const arena = temp.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    const body = try makeBody(arena, parsed.value, p);
    const wire = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    try std.testing.expectEqualStrings("jev-latest", wire.object.get("model").?.string);
    try std.testing.expectEqualStrings("fix a complex failing test", wire.object.get("state").?.string);
    const q1 = wire.object.get("questions").?.object.get("q1").?.object;
    try std.testing.expectEqualStrings("choice", q1.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 5), q1.get("criteria").?.object.count());
    try std.testing.expect(q1.get("criteria").?.object.get("high") != null);
    var client: std.http.Client = undefined;
    var pending: @import("jev_effort_state.zig").Pending = .{};
    const ctx: ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = p, .jev_effort_pending = &pending, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const before = pricing.g_cost.snap(std.testing.io);
    const out = try execute(ctx, parsed.value);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "high") != null);
    try std.testing.expectEqual(ReasoningEffort.high, pending.take(std.testing.io, p).?);
    try std.testing.expectEqual(@as(usize, 1), state.attempts.load(.acquire));
    const after = pricing.g_cost.snap(std.testing.io);
    try std.testing.expectEqual(before.api_calls, after.api_calls);
    try std.testing.expectEqual(before.missing_usage_calls, after.missing_usage_calls);
    try std.testing.expectEqual(before.unreported_failed_attempts, after.unreported_failed_attempts);
}

test "native Jev rejects arbitrary judgments and unsupported or malformed effort" {
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    const a = temp.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    const arbitrary = try std.json.parseFromSliceLeaky(Value, a, "{\"state\":\"build passed\",\"question\":\"Did CI pass?\",\"type\":\"noul\"}", .{});
    try std.testing.expectError(error.InvalidInput, makeBody(a, arbitrary, p));
    try std.testing.expectError(error.InvalidResponse, selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"noul\",\"noul\":0.9}}}"));
    try std.testing.expectError(error.InvalidResponse, selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"none\",\"confidence\":0.9}}}"));
    try std.testing.expectError(error.InvalidResponse, selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"high\",\"confidence\":\"certain\"}}}"));
    try std.testing.expectEqual(ReasoningEffort.high, try selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"high\"}}}"));
    try std.testing.expectEqual(ReasoningEffort.high, try selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"high\",\"confidence\":0.9}}}"));
    const mimo: Provider = .{ .id = "xiaomi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "mimo-v2.6-flash", .context = 100_000 };
    const task = try std.json.parseFromSliceLeaky(Value, a, "{\"task\":\"answer a trivial question\"}", .{});
    const body = try makeBody(a, task, mimo);
    const wire = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    const criteria = wire.object.get("questions").?.object.get("q1").?.object.get("criteria").?.object;
    try std.testing.expectEqual(@as(usize, 2), criteria.count());
    try std.testing.expect(criteria.get("none") != null and criteria.get("high") != null);
    try std.testing.expectEqual(ReasoningEffort.none, try selectedEffort(a, mimo, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"none\"}}}"));
    try std.testing.expectError(error.InvalidResponse, selectedEffort(a, mimo, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"low\"}}}"));
}

test "native Jev gateway uses persisted login independent of chat provider and upstream key" {
    configure(struct {
        fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "TYPESAFE_API_KEY")) "upstream-secret" else null;
        }
    }{});
    defer configure(struct {
        fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    }{});
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "chat-key", .model = "gpt-6-sol", .context = 100_000 };
    try std.testing.expect(!available(p));
    try std.testing.expect(setCodegraffLoginKey(std.testing.io, "persisted-login"));
    try std.testing.expect(available(p));
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/systemone", endpoint);
    const bearer = try gatewayBearer(std.testing.allocator, state.key);
    defer std.testing.allocator.free(bearer);
    try std.testing.expectEqualStrings("Bearer persisted-login", bearer);
    try std.testing.expect(std.mem.indexOf(u8, bearer, p.api_key) == null);
    try std.testing.expect(std.mem.indexOf(u8, bearer, "upstream-secret") == null);
    try std.testing.expect(setCodegraffLoginKey(std.testing.io, null));
    try std.testing.expect(!available(p));
}

test "native Jev reports safe gateway failures and does not invent usage or cost" {
    try std.testing.expect(std.mem.indexOf(u8, skipForError(error.JevUnauthorized), "authorization failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipForError(error.JevNoCredits), "credits or key budget") != null);
    try std.testing.expect(std.mem.indexOf(u8, skipForError(error.JevRateLimited), "rate limit") != null);
    try std.testing.expectEqualStrings(skip_text, skipForError(error.ConnectionRefused));
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    const a = temp.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    try std.testing.expectEqual(ReasoningEffort.high, try selectedEffort(a, p, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"high\",\"confidence\":0.9}},\"usage\":{\"input_tokens\":20,\"output_tokens\":5}}"));
}

test "native Jev gateway usage preserves tokens but marks unsettled cost unknown" {
    const io = std.testing.io;
    var tally: pricing.CostTally = .{};
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    noteGatewayUsage(io, &tally, temp.allocator(), "{\"answers\":{},\"usage\":{\"input_tokens\":20,\"output_tokens\":5}}");
    var c = tally.snap(io);
    try std.testing.expectEqual(@as(u64, 1), c.api_calls);
    try std.testing.expectEqual(@as(u64, 20), c.in_tokens);
    try std.testing.expectEqual(@as(u64, 5), c.out_tokens);
    try std.testing.expectEqual(@as(u64, 1), c.unpriced_calls);
    try std.testing.expectEqual(@as(f64, 0), c.usd); // known subtotal, not an invented settled charge
    var wire: Io.Writer.Allocating = .init(std.testing.allocator);
    defer wire.deinit();
    try @import("acp_usage.zig").write(&wire.writer, "fixture", &tally, io);
    const event = try std.json.parseFromSliceLeaky(Value, temp.allocator(), wire.written(), .{});
    const usage = event.object.get("params").?.object.get("usage").?.object;
    try std.testing.expect(usage.get("usage_complete").?.bool);
    try std.testing.expect(!usage.get("cost_complete").?.bool);
    try std.testing.expect(usage.get("cost_usd").? == .null);
    noteGatewayUsage(io, &tally, temp.allocator(), "{\"answers\":{}}");
    noteGatewayUsage(io, &tally, temp.allocator(), "{\"usage\":{\"input_tokens\":-1,\"output_tokens\":5}}");
    noteGatewayUsage(io, &tally, temp.allocator(), "{\"usage\":{\"input_tokens\":2.5,\"output_tokens\":5}}");
    c = tally.snap(io);
    try std.testing.expectEqual(@as(u64, 4), c.api_calls);
    try std.testing.expectEqual(@as(u64, 3), c.missing_usage_calls);
    const turn = @import("turn_event.zig").fromTally(&tally, io, "done", 100, true);
    try std.testing.expect(!turn.usage_complete);
    tally.failedWithoutUsage(io, 1); // a sent request failed before a receipt
    c = tally.snap(io);
    try std.testing.expectEqual(@as(u64, 1), c.unreported_failed_attempts);
    try std.testing.expectEqual(@as(u64, 4), c.api_calls); // failed attempts are separate
}

test "native Jev gateway confirmed receipt records exact charge once" {
    const io = std.testing.io;
    var tally: pricing.CostTally = .{};
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    noteGatewayUsage(io, &tally, temp.allocator(), "{\"usage\":{\"input_tokens\":296,\"output_tokens\":20},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":12,\"currency\":\"USD\"}}");
    const c = tally.snap(io);
    try std.testing.expectEqual(@as(u64, 1), c.api_calls);
    try std.testing.expectEqual(@as(u64, 296), c.in_tokens);
    try std.testing.expectEqual(@as(u64, 20), c.out_tokens);
    try std.testing.expectEqual(@as(u64, 0), c.unpriced_calls);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000012), c.usd, 1e-12);
    var wire: Io.Writer.Allocating = .init(std.testing.allocator);
    defer wire.deinit();
    try @import("acp_usage.zig").write(&wire.writer, "fixture", &tally, io);
    const event = try std.json.parseFromSliceLeaky(Value, temp.allocator(), wire.written(), .{});
    const usage = event.object.get("params").?.object.get("usage").?.object;
    try std.testing.expect(usage.get("usage_complete").?.bool);
    try std.testing.expect(usage.get("cost_complete").?.bool);
    try std.testing.expectApproxEqAbs(@as(f64, 0.000012), usage.get("cost_usd").?.float, 1e-12);
}

test "native Jev gateway refuses malformed and unconfirmed charge claims" {
    const io = std.testing.io;
    var tally: pricing.CostTally = .{};
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    for ([_][]const u8{
        "{\"usage\":{\"input_tokens\":20,\"output_tokens\":5},\"codegraff_billing\":{\"settled\":false,\"charge_micro_usd\":1,\"currency\":\"USD\"}}",
        "{\"usage\":{\"input_tokens\":20,\"output_tokens\":5},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":-1,\"currency\":\"USD\"}}",
        "{\"usage\":{\"input_tokens\":20,\"output_tokens\":5},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":1.5,\"currency\":\"USD\"}}",
        "{\"usage\":{\"input_tokens\":20,\"output_tokens\":5},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":1,\"currency\":\"EUR\"}}",
        "{\"usage\":{\"input_tokens\":20,\"output_tokens\":5},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":9007199254740992,\"currency\":\"USD\"}}",
    }) |raw| noteGatewayUsage(io, &tally, temp.allocator(), raw);
    const c = tally.snap(io);
    try std.testing.expectEqual(@as(u64, 5), c.api_calls);
    try std.testing.expectEqual(@as(u64, 5), c.unpriced_calls);
    try std.testing.expectEqual(@as(u64, 100), c.in_tokens);
    try std.testing.expectEqual(@as(f64, 0), c.usd);
}
