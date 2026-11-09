const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const copy = @import("provider_error_copy.zig");
const provider_mod = @import("provider.zig");
const agent_mod = @import("agent.zig");
const quota = @import("agent_request_quota.zig");
const headless_result = @import("headless_result.zig");
const subagent_run = @import("subagent_run.zig");
const subagent_retry = @import("subagent_retry.zig");
const acp_engine = @import("acp_engine.zig");
const acp_live_turn = @import("acp_live_turn.zig");
const acp_v2 = @import("acp_v2.zig");
const util = @import("util.zig");

fn makeProvider(id: []const u8, model: []const u8) provider_mod.Provider {
    return .{
        .id = id,
        .kind = .openai,
        .auth = .bearer,
        .url = "https://api.codegraff.com/v1/chat/completions",
        .api_key = "test-key",
        .model = model,
        .context = 200_000,
    };
}

fn makeTestAgent(a: Allocator, out: ?*Io.Writer, id: []const u8, model: []const u8) agent_mod.Agent {
    return .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = makeProvider(id, model),
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = out,
    };
}

test "#1756: gateway capacity formats model-first copy, retry count, and preserves request id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const f = try copy.format(a, .{
        .provider = makeProvider("codegraff", "kimi-k3.1-pro-highspeed"),
        .etype = "rate_limit_error",
        .code = "rate_limit_exceeded",
        .message = "Codegraff is temporarily at capacity. Retry shortly.",
        .request_id = "cg_req_019da5a21d087c24",
        .attempts = 4,
    });

    try testing.expectEqualStrings("capacity_throttle", f.detail.kind);
    try testing.expectEqualStrings("gateway", f.detail.attribution);
    try testing.expectEqualStrings("Kimi", f.detail.maker.?);
    try testing.expectEqualStrings(
        "Kimi (kimi-k3.1-pro-highspeed) could not respond because request capacity is temporarily full.",
        f.detail.headline,
    );
    try testing.expectEqualStrings(
        "Retried 3 times; try again shortly, or switch models with /model.",
        f.detail.remedy,
    );
    try testing.expect(std.mem.startsWith(u8, f.text, "Kimi (kimi-k3.1-pro-highspeed) could not respond"));
    try testing.expect(std.mem.endsWith(u8, f.text, "[cg_req_019da5a21d087c24]"));
    try testing.expect(std.mem.indexOf(u8, f.text, "api error: (rate_limit_error rate_limit_exceeded)") != null);
    try testing.expect(std.mem.indexOf(u8, f.text, "(gave up after 4 attempts)") != null);

    // Must not trip Harness's LIMITED/SIGNED_OUT login-chip heuristics on transient capacity.
    for ([_][]const u8{ "rate limit", "rate-limit", "http 429", "status 429", "(429)", "too many requests", "unauthorized" }) |needle| {
        try testing.expect(util.indexOfIgnoreCase(f.text, needle) == null);
    }

    const hr = headless_result.classify(error.ApiError, f.text);
    try testing.expectEqualStrings("transient_failure", hr.reason);
    try testing.expectEqual(@as(u8, 75), hr.exit_code);
    try testing.expect(hr.retryable);
}

test "#1756: upstream model failures on codegraff attribute to maker/model and never blame Codegraff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const MakerCase = struct { model: []const u8, maker: []const u8, code: []const u8, etype: []const u8, msg: []const u8 };
    const cases = [_]MakerCase{
        .{ .model = "kimi-k3.1-pro-highspeed", .maker = "Kimi", .etype = "overloaded_error", .code = "model_capacity_exhausted", .msg = "No capacity available for model." },
        .{ .model = "claude-opus-4-6", .maker = "Anthropic", .etype = "overloaded_error", .code = "overloaded_error", .msg = "Overloaded" },
        .{ .model = "gpt-5.4", .maker = "OpenAI", .etype = "server_error", .code = "engine_overloaded", .msg = "The engine is currently overloaded." },
        .{ .model = "gemini-2.5-pro", .maker = "Google Gemini", .etype = "UNAVAILABLE", .code = "503", .msg = "The model is overloaded. Please try again later." },
        .{ .model = "deepseek-r1", .maker = "DeepSeek", .etype = "gateway_timeout", .code = "upstream_timeout", .msg = "Upstream model timed out." },
        .{ .model = "glm-5", .maker = "Z.AI", .etype = "service_unavailable", .code = "model_unavailable", .msg = "Requested model is temporarily overloaded." },
        .{ .model = "grok-4.6", .maker = "xAI", .etype = "invalid_request_error", .code = "model_not_found", .msg = "Model does not exist on this endpoint." },
        .{ .model = "minimax-m2.5", .maker = "MiniMax", .etype = "bad_gateway", .code = "502", .msg = "Bad gateway from upstream." },
        .{ .model = "mimo-v2-pro", .maker = "Xiaomi MiMo", .etype = "server_error", .code = "service_unavailable", .msg = "Temporarily unavailable." },
    };

    for (cases) |tc| {
        const f = try copy.format(a, .{
            .provider = makeProvider("codegraff", tc.model),
            .etype = tc.etype,
            .code = tc.code,
            .message = tc.msg,
            .attempts = if (std.mem.eql(u8, tc.code, "model_unavailable") or std.mem.eql(u8, tc.code, "model_not_found")) 1 else 4,
        });
        try testing.expectEqualStrings("model_unavailable", f.detail.kind);
        try testing.expectEqualStrings("upstream_model", f.detail.attribution);
        try testing.expectEqualStrings(tc.maker, f.detail.maker.?);
        try testing.expect(std.mem.indexOf(u8, f.detail.headline, tc.maker) != null);
        try testing.expect(std.mem.indexOf(u8, f.detail.headline, tc.model) != null);
        try testing.expect(util.indexOfIgnoreCase(f.detail.headline, "codegraff") == null);
        try testing.expect(util.indexOfIgnoreCase(f.detail.remedy, "codegraff") == null);
    }

    // Subagent classification keeps terminal model_unavailable / model_not_found non-retryable.
    const unavail = try copy.format(a, .{
        .provider = makeProvider("codegraff", "kimi-k3.1-pro-highspeed"),
        .etype = "service_unavailable",
        .code = "model_unavailable",
        .message = "Requested model is temporarily overloaded.",
    });
    const unavail_kind = subagent_run.classifyFailure(error.ApiError, unavail.text);
    try testing.expectEqual(subagent_run.FailKind.model, unavail_kind);
    try testing.expectEqual(@as(u8, 1), subagent_retry.attemptBudget(unavail_kind, unavail.text));
}

test "#1756: quota and access-denied faults preserve cap markers and structured detail without retrying" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var refreshed = false;
    var agent = makeTestAgent(a, null, "kimi", "kimi-k3.1-pro-highspeed");
    const qerr = quota.handle(&agent, "", null, "{\"error\":{\"type\":\"exceeded_current_quota_error\",\"message\":\"You've reached your 5-hour usage limit.\"},\"request_id\":\"req_kimi_1\"}", &refreshed);
    try testing.expectError(error.ProviderQuotaExceeded, qerr);
    try testing.expect(quota.isQuotaExceeded(agent.last_api_error.?));
    try testing.expect(subagent_retry.hardQuotaCap(agent.last_api_error));
    try testing.expect(std.mem.startsWith(u8, agent.last_api_error.?, "Kimi (kimi-k3.1-pro-highspeed) has reached its plan usage limit."));
    try testing.expectEqualStrings("quota_exhausted", agent.last_api_error_detail.?.kind);
    try testing.expectEqualStrings("req_kimi_1", agent.last_api_error_detail.?.request_id.?);

    var denied = makeTestAgent(a, null, "codegraff", "claude-opus-4-6");
    const derr = quota.handle(&denied, "permission_error", "403", "Model route forbidden for this tier.", &refreshed);
    try testing.expectError(error.ProviderAccessDenied, derr);
    try testing.expect(std.mem.startsWith(u8, denied.last_api_error.?, "Access to Anthropic (claude-opus-4-6) was denied (403)."));
    try testing.expectEqualStrings("access_denied", denied.last_api_error_detail.?.kind);
}

test "#1756: transport give-up parses captured JSON/SSE bodies, redacts URLs, and handles network drops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: Io.Writer.Allocating = .init(a);

    var agent = makeTestAgent(a, &aw.writer, "codegraff", "kimi-k3.1-pro-highspeed");
    const body_503 =
        \\{"error":{"type":"overloaded_error","code":"model_capacity_exhausted","message":"Upstream overloaded — see https://openrouter.ai/keys/secret for info"},"request_id":"cg_req_503_abc"}
    ;
    try copy.reportTransportGiveUp(&agent, error.ServerError, 5, body_503, "");
    try testing.expectEqualStrings("model_unavailable", agent.last_api_error_detail.?.kind);
    try testing.expectEqualStrings("upstream_model", agent.last_api_error_detail.?.attribution);
    try testing.expectEqual(@as(u16, 503), agent.last_api_error_detail.?.http_status.?);
    try testing.expectEqual(@as(usize, 5), agent.last_api_error_detail.?.attempts);
    try testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "Retried 4 times;") != null);
    try testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "[url redacted]") != null);
    try testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "openrouter.ai") == null);
    try testing.expect(std.mem.endsWith(u8, agent.last_api_error.?, "[cg_req_503_abc]"));

    const sse_env = copy.parseCapturedHttpBody(
        a,
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"code\":\"rate_limit_exceeded\",\"message\":\"Codegraff is temporarily at capacity.\"},\"request_id\":\"cg_req_sse\"}\n\n",
    ).?;
    try testing.expectEqualStrings("rate_limit_error", sse_env.etype);
    try testing.expectEqualStrings("rate_limit_exceeded", sse_env.code.?);
    try testing.expectEqualStrings("cg_req_sse", sse_env.request_id.?);

    var local_agent = makeTestAgent(a, &aw.writer, "ollama", "qwen3-coder");
    try copy.reportTransportGiveUp(&local_agent, error.ConnectionRefused, 1, "", "http://127.0.0.1:11434/v1");
    try testing.expectEqualStrings("network_transport", local_agent.last_api_error_detail.?.kind);
    try testing.expectEqualStrings("local_server", local_agent.last_api_error_detail.?.attribution);
    try testing.expect(std.mem.indexOf(u8, local_agent.last_api_error.?, "http://127.0.0.1:11434/v1") != null);
}

test "#1756: context overflow, invalid request, and compaction rejection produce actionable copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ovf = try copy.format(a, .{
        .provider = makeProvider("anthropic", "claude-sonnet-4-6"),
        .etype = "invalid_request_error",
        .code = "context_length_exceeded",
        .message = "Prompt is too long: 215000 tokens > 200000 maximum.",
    });
    try testing.expectEqualStrings("context_overflow", ovf.detail.kind);
    try testing.expect(std.mem.indexOf(u8, ovf.detail.remedy, "/compact") != null);

    const cmp = try copy.format(a, .{
        .provider = makeProvider("openai", "gpt-5.4"),
        .etype = "invalid_request_error",
        .code = "invalid_encrypted_content",
        .message = "The encrypted content could not be verified.",
    });
    try testing.expectEqualStrings("invalid_request", cmp.detail.kind);
    try testing.expect(std.mem.indexOf(u8, cmp.detail.headline, "Saved compaction state was rejected") != null);

    const bad = try copy.format(a, .{
        .provider = makeProvider("openai", "gpt-5.4"),
        .etype = "invalid_request_error",
        .message = "Unsupported parameter: top_k.",
        .http_status = 400,
    });
    try testing.expectEqualStrings("invalid_request", bad.detail.kind);
    try testing.expect(std.mem.startsWith(u8, bad.detail.headline, "OpenAI (gpt-5.4) rejected the request parameters."));
}

test "#1756: ACP v1 keeps error.data clean while ACP v2 emits structured graff/errorDetail" {
    defer acp_v2.resetForTest();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const formatted = try copy.format(a, .{
        .provider = makeProvider("codegraff", "kimi-k3.1-pro-highspeed"),
        .etype = "overloaded_error",
        .code = "model_capacity_exhausted",
        .message = "Upstream model overloaded.",
        .request_id = "cg_req_acp_99",
        .attempts = 4,
    });

    var root = makeTestAgent(a, null, "codegraff", "kimi-k3.1-pro-highspeed");
    root.last_api_error = formatted.text;
    root.last_api_error_detail = formatted.detail;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    var live_out: Io.Writer.Allocating = .init(a);
    var live: acp_live_turn.LiveTurn = .{ .root = &root, .keys = &keys, .out = &live_out.writer };

    const Failing = struct {
        fn turn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.ApiError;
        }
    };
    var d: acp_engine.Dispatch = .{
        .turn = Failing.turn,
        .ctx = &live,
        .error_message = acp_live_turn.LiveTurn.errorMessage,
        .error_recovery = acp_live_turn.LiveTurn.errorRecovery,
        .error_detail = acp_live_turn.LiveTurn.errorDetail,
    };

    // ACP v1: JSON-RPC -32603 carries formatted message and NO error.data (unless auth recovery).
    acp_v2.gate = false;
    var out_v1: Io.Writer.Allocating = .init(a);
    try acp_engine.handleLine(&d, a, &out_v1.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}");
    try acp_engine.handleLine(&d, a, &out_v1.writer, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    out_v1.clearRetainingCapacity();
    try acp_engine.handleLine(&d, a, &out_v1.writer, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":\"hi\"}}");
    const v1_json = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.trim(u8, out_v1.writer.buffered(), " \r\n"), .{});
    const v1_err = v1_json.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32603), v1_err.get("code").?.integer);
    try testing.expectEqualStrings(formatted.text, v1_err.get("message").?.string);
    try testing.expect(v1_err.get("data") == null);

    // ACP v2: state_update _error carries both graff/error and structured graff/errorDetail.
    acp_v2.gate = true;
    var out_v2: Io.Writer.Allocating = .init(a);
    try acp_engine.handleLine(&d, a, &out_v2.writer, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2}}");
    try acp_engine.handleLine(&d, a, &out_v2.writer, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\",\"mcpServers\":[]}}");
    out_v2.clearRetainingCapacity();
    try acp_engine.handleLine(&d, a, &out_v2.writer, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-0-1\",\"prompt\":\"hi\"}}");

    var found_detail = false;
    var lines = std.mem.splitScalar(u8, out_v2.writer.buffered(), '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const msg = try std.json.parseFromSliceLeaky(std.json.Value, a, trimmed, .{});
        const params = msg.object.get("params") orelse continue;
        const upd = params.object.get("update") orelse continue;
        const stop = upd.object.get("stopReason") orelse continue;
        if (stop != .string or !std.mem.eql(u8, stop.string, "_error")) continue;
        const meta = upd.object.get("_meta").?.object;
        try testing.expectEqualStrings(formatted.text, meta.get("graff/error").?.string);
        const det = meta.get("graff/errorDetail").?.object;
        try testing.expectEqualStrings("model_unavailable", det.get("kind").?.string);
        try testing.expectEqualStrings("upstream_model", det.get("attribution").?.string);
        try testing.expectEqualStrings("kimi-k3.1-pro-highspeed", det.get("model").?.string);
        try testing.expectEqualStrings("Kimi", det.get("maker").?.string);
        try testing.expectEqualStrings("cg_req_acp_99", det.get("request_id").?.string);
        try testing.expectEqual(@as(i64, 4), det.get("attempts").?.integer);
        found_detail = true;
    }
    try testing.expect(found_detail);
}

test "#1756: OpenAI cyber_policy, content_policy, and request_rejected scream on ACP and never retry" {
    defer copy.g_session_cyber_policy = false;
    copy.g_session_cyber_policy = false;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Standalone generic request_rejected does not blame user prompt wording or claim upstream model fault.
    const rej = try copy.format(a, .{
        .provider = makeProvider("codegraff", "gpt-5.4"),
        .code = "request_rejected",
        .message = "We could not process this request. Check the request fields and try again.",
        .request_id = "cg_req_rej_1",
    });
    try testing.expectEqualStrings("invalid_request", rej.detail.kind);
    try testing.expectEqualStrings("gateway", rej.detail.attribution);
    try testing.expect(std.mem.startsWith(u8, rej.detail.headline, "The API rejected this request without specifying which field or policy failed (request_rejected)."));
    try testing.expect(std.mem.indexOf(u8, rej.detail.remedy, "cyber_policy") != null);
    try testing.expect(!@import("agent_gateway_retry.zig").isShortGatewayFlake("", "request_rejected", "We could not process this request. Check the request fields and try again."));
    try testing.expectEqual(subagent_run.FailKind.invalid, subagent_run.classifyFailure(error.ApiError, rej.text));

    // 2. OpenAI / Codex cyber_policy screams CYBER_POLICY in headline and preserves Daybreak remediation URL.
    var agent = makeTestAgent(a, null, "chatgpt-new", "gpt-5.4");
    const failure: @import("agent_responses.zig").ResponsesFailure = .{
        .code = "cyber_policy",
        .message = "This content was flagged for possible cybersecurity risk. Apply for Daybreak access via https://platform.openai.com/settings/organization/status-and-access",
    };
    const diag = try @import("agent_responses.zig").failureDiagnostic(a, "chatgpt-new", failure);
    try copy.reportResponses(&agent, failure, diag, 1);
    try testing.expect(copy.g_session_cyber_policy);
    try testing.expectEqualStrings("cyber_policy", agent.last_api_error_detail.?.kind);
    try testing.expect(std.mem.startsWith(u8, agent.last_api_error.?, "CYBER_POLICY: OpenAI (gpt-5.4) blocked this request under OpenAI's cybersecurity policy (cyber_policy)."));
    try testing.expect(std.mem.indexOf(u8, agent.last_api_error.?, "https://platform.openai.com/settings/organization/status-and-access") != null);
    try testing.expectEqual(subagent_run.FailKind.invalid, subagent_run.classifyFailure(error.ApiError, agent.last_api_error));
    try testing.expectEqual(@as(u8, 78), headless_result.classify(error.ApiError, agent.last_api_error.?).exit_code);

    // 3. Subsequent continuation on codegraff that collapses to request_rejected retains the CYBER_POLICY banner.
    const cont = try copy.format(a, .{
        .provider = makeProvider("codegraff", "gpt-5.4"),
        .code = "request_rejected",
        .message = "We could not process this request. Check the request fields and try again.",
    });
    try testing.expectEqualStrings("cyber_policy", cont.detail.kind);
    try testing.expect(std.mem.startsWith(u8, cont.detail.headline, "CYBER_POLICY: The API rejected this continuation (request_rejected) after an earlier OpenAI cybersecurity policy flag (cyber_policy)."));

    // 4. General usage/content policy block (invalid_prompt with usage policy wording).
    const pol = try copy.format(a, .{
        .provider = makeProvider("openai", "gpt-5.4"),
        .etype = "invalid_request_error",
        .code = "invalid_prompt",
        .message = "Invalid prompt: your prompt was flagged as potentially violating our usage policy.",
    });
    try testing.expectEqualStrings("content_policy", pol.detail.kind);
    try testing.expect(std.mem.startsWith(u8, pol.detail.headline, "CONTENT_POLICY: OpenAI (gpt-5.4) blocked this request under its usage or content policy."));
}
