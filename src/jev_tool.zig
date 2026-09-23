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

pub const name = "jev_judge";
pub const description = "Ask Jev one closed-form judgment about a SHORT, NON-SENSITIVE state. Requires a Codegraff login and an eligible GPT-6 or MiMo model. Use for yes/no (noul), a choice, or an ordered score, not writing or open-ended reasoning. Never send source code, secrets, customer data, paths, or unrelated context. A low-confidence verdict escalates to you. If Jev fails once, this tool skips all later Jev calls for this session; decide yourself instead.";
pub const input_schema =
    \\{"type":"object","properties":{"state":{"type":"string","description":"Short non-sensitive facts needed for this judgment only; no code, paths or secrets"},"question":{"type":"string","description":"One closed-form question about state"},"type":{"type":"string","enum":["noul","choice","score"],"description":"noul=yes/no probability; choice=one option; score=ordered level"},"options":{"type":"array","items":{"type":"string"},"description":"Required for choice: 2-16 distinct labels"},"levels":{"type":"array","items":{"type":"string"},"description":"Required for score: 2-16 ordered descriptions"}},"required":["state","question","type"]}
;
const spec = ToolSpec{ .name = name, .desc = description, .schema = input_schema };
const endpoint = "https://api.typesafe.ai/v1/systemone";
const skip_text = "Jev unavailable: skipped. No more Jev requests will be sent this session; judge this step with the main model instead.";
const Backend = enum { typesafe, mock, mock_fail };
const State = struct {
    mu: Io.Mutex = .init,
    key: []const u8 = "",
    backend: Backend = .typesafe,
    codegraff_login: std.atomic.Value(bool) = .init(false),
    down: std.atomic.Value(bool) = .init(false),
    refresh: std.atomic.Value(bool) = .init(false),
    attempts: std.atomic.Value(usize) = .init(0),
};
var state: State = .{};

pub fn configure(env: anytype) void {
    // Called once at session startup, before any tool work begins. Retain the
    // environment's key in memory; it is never copied into a catalog/result.
    state.key = env.get("TYPESAFE_API_KEY") orelse "";
    const mode = env.get("JEV_BACKEND") orelse "";
    state.backend = if (std.mem.eql(u8, mode, "mock")) .mock else if (std.mem.eql(u8, mode, "mock-fail")) .mock_fail else .typesafe;
    state.codegraff_login.store(false, .release);
    state.down.store(false, .release);
    state.refresh.store(false, .release);
    state.attempts.store(0, .release);
}

/// Returns true when a login transition changes the live tool catalog.
pub fn setCodegraffLogin(logged_in: bool) bool {
    return state.codegraff_login.swap(logged_in, .acq_rel) != logged_in;
}

pub fn available(provider: Provider) bool {
    return state.codegraff_login.load(.acquire) and
        (state.backend != .typesafe or state.key.len > 0) and
        !state.down.load(.acquire) and scope.eligible(provider);
}

/// A model switch can change Jev visibility even when the wire format stays the same.
pub fn updateProvider(root: anytype, p: Provider) void {
    if (available(root.provider) != available(p)) root.invalidateRootTools();
    root.provider = p;
}

pub fn catalogExtras(provider: Provider) []const ToolSpec {
    return if (available(provider)) &.{spec} else &.{};
}

pub fn takeCatalogRefresh() bool {
    return state.refresh.swap(false, .acq_rel);
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

fn listValid(v: Value) bool {
    if (v != .array or v.array.items.len < 2 or v.array.items.len > 16) return false;
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
        if (!listValid(options)) return error.InvalidInput;
        var labels = std.json.ObjectMap.empty;
        for (options.array.items) |item| try labels.put(arena, item.string, item);
        try q.put(arena, "criteria", .{ .object = labels });
    } else if (std.mem.eql(u8, kind, "score")) {
        const levels = obj.get("levels") orelse return error.InvalidInput;
        if (!listValid(levels)) return error.InvalidInput;
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
    if (std.mem.eql(u8, kind, "noul")) return "{\"answers\":{\"q1\":{\"noul\":0.98}}}";
    if (std.mem.eql(u8, kind, "score")) return "{\"answers\":{\"q1\":{\"score\":0.9,\"confidence\":0.95}}}";
    const label = input.object.get("options").?.array.items[0].string;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .answers = .{ .q1 = .{ .choice = label, .confidence = 0.95 } } });
    return aw.writer.buffered();
}

fn fetch(ctx: ToolCtx, arena: Allocator, body: []const u8) ![]const u8 {
    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{state.key});
    var aw: Io.Writer.Allocating = .init(arena);
    const res = try ctx.client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .response_writer = &aw.writer,
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
    });
    if (@intFromEnum(res.status) != 200 or aw.writer.buffered().len > 64 * 1024) return error.JevUnavailable;
    return aw.writer.buffered();
}

fn verdict(arena: Allocator, input: Value, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidResponse;
    const answers = parsed.object.get("answers") orelse return error.InvalidResponse;
    if (answers != .object) return error.InvalidResponse;
    const answer = answers.object.get("q1") orelse return error.InvalidResponse;
    if (answer != .object) return error.InvalidResponse;
    const kind = input.object.get("type").?.string;
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
        if (n < 0 or (std.mem.eql(u8, kind, "noul") and n > 1)) return error.InvalidResponse;
    }
    const reported = if (answer.object.get("confidence")) |v| number(v) else null;
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
    if (!state.codegraff_login.load(.acquire)) return invalid(ctx.gpa, "jev_judge requires a Codegraff login (`graff login`)");
    if (!scope.eligible(ctx.provider)) return invalid(ctx.gpa, "jev_judge is available only with Codex/OpenAI GPT-6 or Xiaomi MiMo models");
    if (state.backend == .typesafe and state.key.len == 0) return skipped(ctx.gpa);
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
    if (state.down.load(.acquire)) return skipped(ctx.gpa);
    _ = state.attempts.fetchAdd(1, .acq_rel);
    const raw = switch (state.backend) {
        .mock => try mockResponse(arena, input),
        .mock_fail => error.JevUnavailable,
        .typesafe => fetch(ctx, arena, body),
    } catch {
        state.down.store(true, .release);
        state.refresh.store(true, .release);
        return skipped(ctx.gpa);
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
    _ = setCodegraffLogin(true);
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

test "native Jev mock uses TypeSafe wire and returns a typed verdict" {
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
    _ = setCodegraffLogin(true);
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
    const out = try execute(ctx, parsed.value);
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    const result = try std.json.parseFromSliceLeaky(Value, arena, out.text, .{});
    try std.testing.expect(@abs(number(result.object.get("answer").?).? - 0.98) < 0.0001);
    try std.testing.expect(!result.object.get("escalate").?.bool);
    try std.testing.expectEqual(@as(usize, 1), state.attempts.load(.acquire));
}
