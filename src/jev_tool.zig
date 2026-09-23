//! Native, opt-in Jev judgment tool. One failed upstream attempt opens a
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
const pricing = @import("pricing.zig");
const buffered_https = @import("http2_buffered.zig");

pub const name = "jev_judge";
pub const description = "Ask Jev one closed-form judgment about a SHORT, NON-SENSITIVE state. Requires a Codegraff login and an eligible GPT-6 or MiMo v2.6 model. Use for yes/no (noul), a choice, or an ordered score, not writing or open-ended reasoning. Never send source code, secrets, customer data, paths, or unrelated context. A low-confidence verdict escalates to you. If Jev fails once, this tool skips all later Jev calls for this session; decide yourself instead.";
pub const input_schema =
    \\{"type":"object","properties":{"state":{"type":"string","description":"Short non-sensitive facts needed for this judgment only; no code, paths or secrets"},"question":{"type":"string","description":"One closed-form question about state"},"type":{"type":"string","enum":["noul","choice","score"],"description":"noul=yes/no probability; choice=one option; score=ordered level"},"options":{"type":"array","items":{"type":"string"},"description":"Required for choice: 2-16 distinct labels"},"levels":{"type":"array","items":{"type":"string"},"description":"Required for score: 2-10 ordered descriptions"}},"required":["state","question","type"]}
;
const spec = ToolSpec{ .name = name, .desc = description, .schema = input_schema };
const endpoint = "https://gateway.codegraff.com/v1/systemone";
const skip_text = "Jev unavailable: skipped. No more Jev requests will be sent this session; judge this step with the main model instead.";
const auth_skip_text = "Jev unavailable (Codegraff authorization failed): skipped. No more Jev requests will be sent this session; judge this step with the main model instead.";
const credit_skip_text = "Jev unavailable (Codegraff credits or key budget): skipped. No more Jev requests will be sent this session; judge this step with the main model instead.";
const rate_skip_text = "Jev unavailable (Codegraff rate limit): skipped. No more Jev requests will be sent this session; judge this step with the main model instead.";
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

fn listValid(v: Value, max: usize) bool {
    if (v != .array or v.array.items.len < 2 or v.array.items.len > max) return false;
    for (v.array.items, 0..) |item, i| {
        const label = string(item) orelse return false;
        if (label.len == 0 or label.len > 120) return false;
        for (v.array.items[0..i]) |old| if (std.mem.eql(u8, old.string, label)) return false;
    }
    return true;
}

fn makeBody(arena: Allocator, input: Value) ![]const u8 {
    const obj = input.object;
    const state_text = (obj.get("state") orelse return error.InvalidInput);
    const facts = string(state_text) orelse return error.InvalidInput;
    const question = string(obj.get("question") orelse return error.InvalidInput) orelse return error.InvalidInput;
    const kind = string(obj.get("type") orelse return error.InvalidInput) orelse return error.InvalidInput;
    if (facts.len == 0 or facts.len > 8192 or question.len == 0 or question.len > 512) return error.InvalidInput;
    var q = std.json.ObjectMap.empty;
    try q.put(arena, "type", .{ .string = kind });
    try q.put(arena, "instructions", .{ .string = question });
    if (std.mem.eql(u8, kind, "choice")) {
        const options = obj.get("options") orelse return error.InvalidInput;
        if (!listValid(options, 16)) return error.InvalidInput;
        var labels = std.json.ObjectMap.empty;
        for (options.array.items) |item| try labels.put(arena, item.string, item);
        try q.put(arena, "criteria", .{ .object = labels });
    } else if (std.mem.eql(u8, kind, "score")) {
        const levels = obj.get("levels") orelse return error.InvalidInput;
        if (!listValid(levels, 10)) return error.InvalidInput;
        try q.put(arena, "criteria", levels);
    } else if (!std.mem.eql(u8, kind, "noul")) return error.InvalidInput;
    var questions = std.json.ObjectMap.empty;
    try questions.put(arena, "q1", .{ .object = q });
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "model", .{ .string = "jev-latest" });
    try root.put(arena, "state", state_text);
    try root.put(arena, "questions", .{ .object = questions });
    var aw: Io.Writer.Allocating = .init(arena);
    var serializer: std.json.Stringify = .{ .writer = &aw.writer };
    try serializer.write(Value{ .object = root });
    return aw.writer.buffered();
}

fn mockResponse(arena: Allocator, input: Value) ![]const u8 {
    const kind = input.object.get("type").?.string;
    if (std.mem.eql(u8, kind, "noul")) return "{\"answers\":{\"q1\":{\"type\":\"noul\",\"noul\":0.98}}}";
    if (std.mem.eql(u8, kind, "score")) return "{\"answers\":{\"q1\":{\"type\":\"score\",\"score\":0.9,\"confidence\":0.95}}}";
    const label = input.object.get("options").?.array.items[0].string;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .answers = .{ .q1 = .{ .type = "choice", .choice = label, .confidence = 0.95 } } });
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

fn verdict(arena: Allocator, input: Value, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidResponse;
    const answers = parsed.object.get("answers") orelse return error.InvalidResponse;
    if (answers != .object) return error.InvalidResponse;
    const answer = answers.object.get("q1") orelse return error.InvalidResponse;
    if (answer != .object) return error.InvalidResponse;
    const kind = input.object.get("type").?.string;
    const answer_type = string(answer.object.get("type") orelse return error.InvalidResponse) orelse return error.InvalidResponse;
    if (!std.mem.eql(u8, kind, answer_type)) return error.InvalidResponse;
    const value: Value = if (std.mem.eql(u8, kind, "noul")) answer.object.get("noul") orelse return error.InvalidResponse else if (std.mem.eql(u8, kind, "choice")) answer.object.get("choice") orelse return error.InvalidResponse else answer.object.get("score") orelse return error.InvalidResponse;
    if (std.mem.eql(u8, kind, "choice")) {
        const label = string(value) orelse return error.InvalidResponse;
        const options = input.object.get("options").?.array.items;
        var found = false;
        for (options) |opt| if (std.mem.eql(u8, opt.string, label)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidResponse;
    } else {
        const n = number(value) orelse return error.InvalidResponse;
        const max: f64 = if (std.mem.eql(u8, kind, "score")) @floatFromInt(input.object.get("levels").?.array.items.len - 1) else 1;
        if (n < 0 or n > max) return error.InvalidResponse;
    }
    const reported = if (answer.object.get("confidence")) |v| number(v) orelse return error.InvalidResponse else null;
    if (!std.mem.eql(u8, kind, "noul") and reported == null) return error.InvalidResponse;
    if (reported) |c| if (c < 0 or c > 1) return error.InvalidResponse;
    const estimated: f64 = if (std.mem.eql(u8, kind, "noul")) 2 * @abs(number(value).? - 0.5) else 0;
    const confidence = reported orelse estimated;
    const threshold: f64 = if (reported != null) 0.5 else 0.4;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .answer = value, .confidence = confidence, .confidence_source = if (reported != null) "reported" else "estimated", .escalate = confidence < threshold });
    return aw.writer.buffered();
}

pub fn execute(ctx: ToolCtx, input: Value) !ToolOutput {
    if (ctx.from_sub) return invalid(ctx.gpa, "jev_judge is available only to the root agent");
    if (!state.codegraff_login.load(.acquire)) return invalid(ctx.gpa, "jev_judge requires a Codegraff login (`graff login`)");
    if (!scope.eligible(ctx.provider)) return invalid(ctx.gpa, "jev_judge is available only with Codex/OpenAI GPT-6 or Xiaomi MiMo v2.6 models");
    if (state.down.load(.acquire)) return skipped(ctx.gpa);
    if (input != .object) return invalid(ctx.gpa, "jev_judge needs state, question and type");
    var temp = std.heap.ArenaAllocator.init(ctx.gpa);
    defer temp.deinit();
    const arena = temp.allocator();
    const body = makeBody(arena, input) catch |err| switch (err) {
        error.InvalidInput => return invalid(ctx.gpa, "jev_judge needs a short state, one question, and valid noul/choice/score options"),
        else => return err,
    };
    state.mu.lockUncancelable(ctx.io);
    defer state.mu.unlock(ctx.io);
    if (state.key.len == 0) return invalid(ctx.gpa, "jev_judge requires a Codegraff login (`graff login`)");
    if (state.down.load(.acquire)) return skipped(ctx.gpa);
    _ = state.attempts.fetchAdd(1, .acq_rel);
    const raw = switch (state.backend) {
        .mock => try mockResponse(arena, input),
        .mock_fail => error.JevUnavailable,
        .gateway => fetch(ctx, arena, body),
    } catch |err| {
        state.down.store(true, .release);
        state.refresh.store(true, .release);
        return .{ .text = try ctx.gpa.dupe(u8, skipForError(err)) };
    };
    const result = verdict(arena, input, raw) catch {
        state.down.store(true, .release);
        state.refresh.store(true, .release);
        return skipped(ctx.gpa);
    };
    return .{ .text = try ctx.gpa.dupe(u8, result) };
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
    const ctx: ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = p, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"state\":\"10 tests passed\",\"question\":\"Did CI pass?\",\"type\":\"noul\"}", .{});
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

test "native Jev mock uses SystemOne wire and returns a typed verdict" {
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
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"state\":\"10 passed, 0 failed\",\"question\":\"Did CI pass?\",\"type\":\"noul\"}", .{});
    defer parsed.deinit();
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    const arena = temp.allocator();
    const body = try makeBody(arena, parsed.value);
    const wire = try std.json.parseFromSliceLeaky(Value, arena, body, .{});
    try std.testing.expectEqualStrings("jev-latest", wire.object.get("model").?.string);
    try std.testing.expectEqualStrings("10 passed, 0 failed", wire.object.get("state").?.string);
    const q1 = wire.object.get("questions").?.object.get("q1").?.object;
    try std.testing.expectEqualStrings("Did CI pass?", q1.get("instructions").?.string);
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = p, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const before = pricing.g_cost.snap(std.testing.io);
    const out = try execute(ctx, parsed.value);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    const result = try std.json.parseFromSliceLeaky(Value, arena, out.text, .{});
    try std.testing.expect(@abs(number(result.object.get("answer").?).? - 0.98) < 0.0001);
    try std.testing.expect(!result.object.get("escalate").?.bool);
    try std.testing.expectEqual(@as(usize, 1), state.attempts.load(.acquire));
    const after = pricing.g_cost.snap(std.testing.io);
    try std.testing.expectEqual(before.api_calls, after.api_calls);
    try std.testing.expectEqual(before.missing_usage_calls, after.missing_usage_calls);
    try std.testing.expectEqual(before.unreported_failed_attempts, after.unreported_failed_attempts);
}

test "native Jev rejects out-of-range scores and malformed confidence" {
    var temp = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer temp.deinit();
    const a = temp.allocator();
    const input = try std.json.parseFromSliceLeaky(Value, a, "{\"state\":\"build passed\",\"question\":\"How complete?\",\"type\":\"score\",\"levels\":[\"none\",\"some\",\"all\"]}", .{});
    try std.testing.expectError(error.InvalidResponse, verdict(a, input, "{\"answers\":{\"q1\":{\"type\":\"score\",\"score\":2.5,\"confidence\":0.9}}}"));
    try std.testing.expectError(error.InvalidResponse, verdict(a, input, "{\"answers\":{\"q1\":{\"type\":\"score\",\"score\":1.5,\"confidence\":\"certain\"}}}"));
    try std.testing.expectError(error.InvalidResponse, verdict(a, input, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"score\":1.5,\"confidence\":0.9}}}"));
    const good = try verdict(a, input, "{\"answers\":{\"q1\":{\"type\":\"score\",\"score\":1.5,\"confidence\":0.9}}}");
    try std.testing.expect(std.mem.indexOf(u8, good, "\"answer\":1.5") != null);
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
    const input = try std.json.parseFromSliceLeaky(Value, a, "{\"state\":\"build passed\",\"question\":\"Did CI pass?\",\"type\":\"noul\"}", .{});
    const out = try verdict(a, input, "{\"answers\":{\"q1\":{\"type\":\"noul\",\"noul\":0.98}},\"usage\":{\"input_tokens\":20,\"output_tokens\":5}}");
    const parsed = try std.json.parseFromSliceLeaky(Value, a, out, .{});
    try std.testing.expect(parsed.object.get("usage") == null);
    try std.testing.expect(parsed.object.get("cost") == null);
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
    noteGatewayUsage(io, &tally, temp.allocator(),
        "{\"usage\":{\"input_tokens\":296,\"output_tokens\":20},\"codegraff_billing\":{\"settled\":true,\"charge_micro_usd\":12,\"currency\":\"USD\"}}");
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
