//! Human-readable provider and gateway error copy with accurate model/maker
//! attribution and preserved structured technical details (#1756).
//!
//! Surfaces (REPL, `-p`, `--json`, ACP v1/v2) share one classifier and one
//! message shape:
//!   `<Headline sentence>. <Remedy sentence>. Technical details — <technical>`
//! Clients that extract the lead sentence (e.g. Harness's banner summary) show
//! the model-attributed headline cleanly while expanding the full remedy,
//! verbatim provider diagnostic, retry count, and `[cg_req_<id>]` under Details.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider_mod = @import("provider.zig");
const model_maker = @import("model_maker.zig");
const quota = @import("agent_request_quota.zig");
const overflow = @import("agent_overflow.zig");
const util = @import("util.zig");

pub const Kind = enum {
    model_unavailable,
    capacity_throttle,
    quota_exhausted,
    context_overflow,
    auth_failed,
    access_denied,
    cyber_policy,
    content_policy,
    invalid_request,
    network_transport,
    provider_error,

    pub fn asText(self: Kind) []const u8 {
        return @tagName(self);
    }
};

pub var g_session_cyber_policy: bool = false;

pub const Attribution = enum {
    upstream_model,
    gateway,
    provider,
    local_server,
    network,

    pub fn asText(self: Attribution) []const u8 {
        return @tagName(self);
    }
};

pub const Detail = struct {
    kind: []const u8,
    attribution: []const u8,
    provider: []const u8,
    model: []const u8,
    maker: ?[]const u8 = null,
    headline: []const u8,
    remedy: []const u8,
    technical: []const u8,
    etype: ?[]const u8 = null,
    code: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    http_status: ?u16 = null,
    attempts: usize = 1,
};

pub const Formatted = struct {
    text: []const u8,
    detail: Detail,
};

pub const Input = struct {
    provider: provider_mod.Provider,
    etype: []const u8 = "",
    code: ?[]const u8 = null,
    message: []const u8 = "",
    request_id: ?[]const u8 = null,
    http_status: ?u16 = null,
    attempts: usize = 1,
    redact_urls: bool = false,
    technical_override: ?[]const u8 = null,
};

/// Extract `error.type` (or Google's `error.status`) from a parsed JSON root.
pub fn errorType(root: std.json.ObjectMap) []const u8 {
    if (root.get("error")) |ev| if (ev == .object) {
        if (ev.object.get("type")) |tv| if (tv == .string and tv.string.len > 0) return tv.string;
        if (ev.object.get("status")) |sv| if (sv == .string and sv.string.len > 0) return sv.string;
    };
    if (root.get("response")) |rv| if (rv == .object) {
        if (rv.object.get("error")) |ev| if (ev == .object) {
            if (ev.object.get("type")) |tv| if (tv == .string and tv.string.len > 0) return tv.string;
        };
    };
    return "";
}

pub fn makerDisplay(provider_id: []const u8, model: []const u8) ?[]const u8 {
    if (model_maker.of(provider_id, model)) |m| {
        if (std.mem.eql(u8, m, "moonshot") or std.mem.eql(u8, m, "kimi")) return "Kimi";
        if (std.mem.eql(u8, m, "anthropic")) return "Anthropic";
        if (std.mem.eql(u8, m, "openai")) return "OpenAI";
        if (std.mem.eql(u8, m, "google")) return "Google Gemini";
        if (std.mem.eql(u8, m, "deepseek")) return "DeepSeek";
        if (std.mem.eql(u8, m, "zai")) return "Z.AI";
        if (std.mem.eql(u8, m, "minimax")) return "MiniMax";
        if (std.mem.eql(u8, m, "xai")) return "xAI";
        if (std.mem.eql(u8, m, "xiaomi")) return "Xiaomi MiMo";
        if (std.mem.eql(u8, m, "mistral")) return "Mistral";
        if (std.mem.eql(u8, m, "alibaba")) return "Qwen";
        if (std.mem.eql(u8, m, "meta")) return "Meta";
    }
    var buf: [64]u8 = undefined;
    const n = @min(model.len, buf.len);
    for (model[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    var s = buf[0..n];
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |slash| s = s[slash + 1 ..];
    if (std.mem.startsWith(u8, s, "moonshot")) return "Kimi";
    if (std.mem.startsWith(u8, s, "qwen")) return "Qwen";
    if (std.mem.startsWith(u8, s, "llama")) return "Meta";
    if (std.mem.startsWith(u8, s, "mistral") or std.mem.startsWith(u8, s, "codestral") or std.mem.startsWith(u8, s, "devstral")) return "Mistral";
    if (std.mem.startsWith(u8, s, "abab")) return "MiniMax";
    return null;
}

pub fn providerDisplay(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "codegraff")) return "Codegraff";
    if (std.mem.eql(u8, id, "kimi")) return "Kimi";
    if (std.mem.eql(u8, id, "anthropic") or std.mem.eql(u8, id, "claude")) return "Anthropic";
    if (std.mem.eql(u8, id, "openai")) return "OpenAI";
    if (std.mem.eql(u8, id, "codex") or std.mem.eql(u8, id, "chatgpt-new")) return "OpenAI Codex";
    if (std.mem.eql(u8, id, "gemini")) return "Google Gemini";
    if (std.mem.eql(u8, id, "deepseek")) return "DeepSeek";
    if (std.mem.eql(u8, id, "zai")) return "Z.AI";
    if (std.mem.eql(u8, id, "minimax")) return "MiniMax";
    if (std.mem.eql(u8, id, "xai")) return "xAI";
    if (std.mem.eql(u8, id, "openrouter")) return "OpenRouter";
    if (id.len > 0) return id;
    return "Provider";
}

fn formatSubject(buf: []u8, p: provider_mod.Provider) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const model = std.mem.trim(u8, p.model, " \t\r\n");
    const maker = makerDisplay(p.id, model);
    if (model.len > 0) {
        if (maker) |mk| {
            if (std.ascii.eqlIgnoreCase(mk, model)) {
                w.print("{s}", .{mk}) catch return model;
            } else {
                w.print("{s} ({s})", .{ mk, model }) catch return model;
            }
        } else {
            w.print("Model {s}", .{model}) catch return model;
        }
        return w.buffered();
    }
    return providerDisplay(p.id);
}

fn containsAnyCI(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (util.indexOfIgnoreCase(hay, n) != null) return true;
    return false;
}

fn fieldContainsAnyCI(etype: []const u8, code: ?[]const u8, msg: []const u8, needles: []const []const u8) bool {
    if (containsAnyCI(etype, needles) or containsAnyCI(msg, needles)) return true;
    if (code) |c| if (containsAnyCI(c, needles)) return true;
    return false;
}

pub fn isCyberPolicy(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    return fieldContainsAnyCI(etype, code, msg, &.{ "cyber_policy", "cybersecurity risk", "extra care with some cybersecurity requests", "daybreak access", "organization/status-and-access" });
}

pub fn isContentPolicy(etype: []const u8, code: ?[]const u8, msg: []const u8) bool {
    return fieldContainsAnyCI(etype, code, msg, &.{ "content_policy_violation", "policy_violation", "content_filter", "safety_system", "violating our usage policy", "flagged as potentially violating" });
}

pub fn isGenericRequestRejected(code: ?[]const u8, msg: []const u8) bool {
    if (code) |c| if (std.ascii.eqlIgnoreCase(c, "request_rejected")) return true;
    return util.indexOfIgnoreCase(msg, "could not process this request") != null and util.indexOfIgnoreCase(msg, "check the request fields") != null;
}

const Subkind = enum {
    terminal_unavailable,
    model_not_found,
    upstream_timeout,
    upstream_overload,
    upstream_unavailable,
    gateway_capacity,
    provider_throttle,
    plan_quota,
    credits_quota,
    compaction_rejected,
    context_overflow,
    auth_failed,
    access_denied,
    cyber_policy,
    content_policy,
    request_rejected,
    invalid_request,
    gateway_internal,
    provider_error,
};

const Classification = struct { kind: Kind, sub: Subkind, attribution: Attribution };

pub fn classify(in: Input) Classification {
    const code = in.code;
    const c = code orelse "";
    const is_gw = std.mem.eql(u8, in.provider.id, "codegraff");
    const base_attr: Attribution = if (is_gw) .upstream_model else .provider;

    if (@import("compaction_window.zig").rejectedByProvider(in.message, code)) {
        return .{ .kind = .invalid_request, .sub = .compaction_rejected, .attribution = base_attr };
    }
    if (isCyberPolicy(in.etype, code, in.message)) {
        return .{ .kind = .cyber_policy, .sub = .cyber_policy, .attribution = base_attr };
    }
    if (isContentPolicy(in.etype, code, in.message)) {
        return .{ .kind = .content_policy, .sub = .content_policy, .attribution = base_attr };
    }
    if (quota.classify(in.etype, code, in.message)) |fault| return switch (fault) {
        .quota => blk: {
            const is_credits = containsAnyCI(c, &.{ "402", "insufficient_quota", "credit", "billing", "payment", "funds" }) or
                containsAnyCI(in.etype, &.{ "insufficient_quota", "credit", "billing", "payment" }) or
                containsAnyCI(in.message, &.{ "credit", "billing", "payment required", "insufficient_quota", "exceeded your current quota", "insufficient funds" });
            const attr: Attribution = if (is_gw and !containsAnyCI(in.etype, &.{"exceeded_current_quota_error"}) and !containsAnyCI(in.message, &.{ "5-hour", "kimi", "claude", "chatgpt" })) .gateway else base_attr;
            break :blk .{ .kind = .quota_exhausted, .sub = if (is_credits) .credits_quota else .plan_quota, .attribution = attr };
        },
        .authentication => .{ .kind = .auth_failed, .sub = .auth_failed, .attribution = if (is_gw) .gateway else .provider },
        .access_denied => .{ .kind = .access_denied, .sub = .access_denied, .attribution = base_attr },
    };
    if (quota.isPlanUsageLimit(code)) return .{ .kind = .quota_exhausted, .sub = .plan_quota, .attribution = base_attr };
    if (std.mem.eql(u8, c, "model_not_found") or in.http_status == 404 or
        fieldContainsAnyCI(in.etype, code, in.message, &.{ "model_not_found", "model not found", "does not exist", "no such model", "decommissioned" }))
        return .{ .kind = .model_unavailable, .sub = .model_not_found, .attribution = base_attr };
    if (std.mem.eql(u8, c, "model_unavailable")) return .{ .kind = .model_unavailable, .sub = .terminal_unavailable, .attribution = base_attr };
    if (overflow.isContextOverflow(in.message, code)) return .{ .kind = .context_overflow, .sub = .context_overflow, .attribution = base_attr };
    if (fieldContainsAnyCI(in.etype, code, in.message, &.{ "gateway_timeout", "upstream_timeout", "timed out", "deadline_exceeded" }) or in.http_status == 504 or in.http_status == 524)
        return .{ .kind = .model_unavailable, .sub = .upstream_timeout, .attribution = base_attr };
    if (fieldContainsAnyCI(in.etype, code, in.message, &.{ "overloaded", "server_is_overloaded", "model_capacity_exhausted", "engine_overloaded", "no capacity available" }) or in.http_status == 529)
        return .{ .kind = .model_unavailable, .sub = .upstream_overload, .attribution = base_attr };
    if (fieldContainsAnyCI(in.etype, code, in.message, &.{ "rate_limit", "throttl", "too many requests", "temporarily at capacity", "at capacity", "retry shortly" }) or in.http_status == 429) {
        const mentions_cg = is_gw and util.indexOfIgnoreCase(in.message, "codegraff") != null;
        return .{ .kind = .capacity_throttle, .sub = if (mentions_cg) .gateway_capacity else .provider_throttle, .attribution = if (mentions_cg) .gateway else base_attr };
    }
    if (fieldContainsAnyCI(in.etype, code, in.message, &.{ "service_unavailable", "bad_gateway", "bad gateway", "temporarily unavailable", "upstream_error", "upstream unavailable", "server_error", "internal server error", "token parsing" }) or
        (in.http_status != null and in.http_status.? >= 500))
    {
        if (is_gw and util.indexOfIgnoreCase(in.message, "codegraff") != null and !containsAnyCI(in.message, &.{ "model", "upstream", "timed out" }))
            return .{ .kind = .provider_error, .sub = .gateway_internal, .attribution = .gateway };
        return .{ .kind = .model_unavailable, .sub = .upstream_unavailable, .attribution = base_attr };
    }
    if (isGenericRequestRejected(code, in.message)) {
        if (g_session_cyber_policy) return .{ .kind = .cyber_policy, .sub = .cyber_policy, .attribution = base_attr };
        return .{ .kind = .invalid_request, .sub = .request_rejected, .attribution = if (is_gw) .gateway else base_attr };
    }
    if (in.http_status == 400 or fieldContainsAnyCI(in.etype, code, in.message, &.{ "invalid_request", "bad_request", "unsupported_parameter", "unknown_parameter", "malformed" }))
        return .{ .kind = .invalid_request, .sub = .invalid_request, .attribution = base_attr };
    if (is_gw and (util.indexOfIgnoreCase(in.etype, "gateway") != null or util.indexOfIgnoreCase(in.message, "codegraff") != null))
        return .{ .kind = .provider_error, .sub = .gateway_internal, .attribution = .gateway };
    return .{ .kind = .provider_error, .sub = .provider_error, .attribution = base_attr };
}

/// Sanitize a single-line diagnostic message and optionally redact embedded URLs
/// (e.g. OpenRouter BYOK/user URLs on raw 429/5xx bodies).
pub fn sanitizeMessage(buf: []u8, raw: []const u8, redact_urls: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const capped = util.utf8Prefix(trimmed, 360);
    var i: usize = 0;
    while (i < capped.len) {
        if (redact_urls and (std.mem.startsWith(u8, capped[i..], "https://") or std.mem.startsWith(u8, capped[i..], "http://"))) {
            w.writeAll("[url redacted]") catch break;
            while (i < capped.len and capped[i] > ' ' and capped[i] != ')' and capped[i] != ']' and capped[i] != '"' and capped[i] != '\'') : (i += 1) {}
            continue;
        }
        const b = capped[i];
        w.writeByte(if (b < 0x20 or b == 0x7f) ' ' else b) catch break;
        i += 1;
    }
    if (capped.len < trimmed.len) w.writeAll("…") catch {};
    return w.buffered();
}

fn formatRetryPrefix(buf: []u8, attempts: usize) []const u8 {
    if (attempts <= 1) return "";
    const retries = attempts - 1;
    var w: std.Io.Writer = .fixed(buf);
    if (retries == 1) {
        w.writeAll("Retried once; ") catch return "";
    } else {
        w.print("Retried {d} times; ", .{retries}) catch return "";
    }
    return w.buffered();
}

fn lowerAfterRetryPrefix(remedy: []const u8, has_prefix: bool, buf: []u8) []const u8 {
    if (!has_prefix or remedy.len == 0) return remedy;
    const n = @min(remedy.len, buf.len);
    @memcpy(buf[0..n], remedy[0..n]);
    buf[0] = std.ascii.toLower(buf[0]);
    return buf[0..n];
}

fn writeTechnicalEnvelope(w: *std.Io.Writer, in: Input, safe_msg: []const u8) !void {
    try w.writeAll("api error:");
    const has_type = in.etype.len > 0 and !std.mem.eql(u8, in.etype, "error");
    const code = if (in.code) |c| (if (c.len > 0) c else null) else null;
    if (has_type or code != null) {
        try w.writeAll(" (");
        if (has_type) try w.writeAll(in.etype);
        if (has_type and code != null) try w.writeByte(' ');
        if (code) |c| try w.writeAll(c);
        try w.writeByte(')');
    }
    if (safe_msg.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(safe_msg);
    }
    if (in.http_status != null or in.attempts > 1) {
        try w.writeAll(" (");
        if (in.http_status) |st| try w.print("status={d}", .{st});
        if (in.http_status != null and in.attempts > 1) try w.writeAll(", ");
        if (in.attempts > 1) try w.print("gave up after {d} attempts", .{in.attempts});
        try w.writeByte(')');
    }
    if (in.request_id) |rid| if (rid.len > 0) {
        try w.print(" [{s}]", .{rid});
    };
}

pub fn format(arena: Allocator, in: Input) !Formatted {
    const cls = classify(in);
    var subj_buf: [160]u8 = undefined;
    const subject = formatSubject(&subj_buf, in.provider);
    const maker = makerDisplay(in.provider.id, in.provider.model);

    var retry_buf: [48]u8 = undefined;
    const retry_prefix = formatRetryPrefix(&retry_buf, in.attempts);

    var head_buf: [256]u8 = undefined;
    var hw: std.Io.Writer = .fixed(&head_buf);
    var base_remedy: []const u8 = "Try again shortly, or switch models with /model.";
    var allow_retry_prefix = true;

    switch (cls.sub) {
        .model_not_found => {
            try hw.print("{s} is not available on this route.", .{subject});
            base_remedy = "Switch models with /model and try again.";
            allow_retry_prefix = false;
        },
        .terminal_unavailable => {
            try hw.print("{s} is currently unavailable.", .{subject});
            base_remedy = "Switch models with /model, or try again later.";
            allow_retry_prefix = false;
        },
        .upstream_timeout => try hw.print("{s} timed out before completing a response.", .{subject}),
        .upstream_overload => try hw.print("{s} is temporarily overloaded.", .{subject}),
        .upstream_unavailable => try hw.print("{s} is temporarily unavailable.", .{subject}),
        .gateway_capacity => try hw.print("{s} could not respond because request capacity is temporarily full.", .{subject}),
        .provider_throttle => try hw.print("{s} is temporarily throttled due to high demand.", .{subject}),
        .plan_quota => {
            try hw.print("{s} has reached its plan usage limit.", .{subject});
            base_remedy = "Wait for your usage window to reset, or switch models with /model.";
            allow_retry_prefix = false;
        },
        .credits_quota => {
            const target = if (cls.attribution == .gateway) "Codegraff account" else subject;
            try hw.print("{s} is out of credits or billing allowance.", .{target});
            base_remedy = "Top up your account credits, or switch models with /model.";
            allow_retry_prefix = false;
        },
        .compaction_rejected => {
            try hw.print("Saved compaction state was rejected by {s}; your conversation history is unchanged.", .{subject});
            base_remedy = "Run /compact or start a new session if this continues.";
            allow_retry_prefix = false;
        },
        .context_overflow => {
            try hw.print("This conversation exceeds {s}'s context window.", .{subject});
            base_remedy = "Run /compact to shorten history, or switch to a larger-context model with /model.";
            allow_retry_prefix = false;
        },
        .auth_failed => {
            try hw.print("Authentication failed for {s}.", .{providerDisplay(in.provider.id)});
            base_remedy = "Run graff login or check your API key.";
            allow_retry_prefix = false;
        },
        .access_denied => {
            try hw.print("Access to {s} was denied (403).", .{subject});
            base_remedy = "Check your account permissions for this model, or switch models with /model.";
            allow_retry_prefix = false;
        },
        .cyber_policy => {
            if (isGenericRequestRejected(in.code, in.message)) {
                try hw.print("CYBER_POLICY: The API rejected this continuation (request_rejected) after an earlier OpenAI cybersecurity policy flag (cyber_policy).", .{});
            } else {
                try hw.print("CYBER_POLICY: {s} blocked this request under OpenAI's cybersecurity policy (cyber_policy).", .{subject});
            }
            base_remedy = "Verify Daybreak access at https://platform.openai.com/settings/organization/status-and-access, start a new session with /new, or switch to a non-OpenAI model with /model.";
            allow_retry_prefix = false;
        },
        .content_policy => {
            try hw.print("CONTENT_POLICY: {s} blocked this request under its usage or content policy.", .{subject});
            base_remedy = "Start a new session with /new or switch models with /model; continuing in a flagged session usually repeats the block.";
            allow_retry_prefix = false;
        },
        .request_rejected => {
            try hw.print("The API rejected this request without specifying which field or policy failed (request_rejected).", .{});
            base_remedy = "If this session was previously flagged by a provider policy (such as cyber_policy) or carries incompatible saved state, start a new session with /new or switch models with /model.";
            allow_retry_prefix = false;
        },
        .invalid_request => {
            try hw.print("{s} rejected the request parameters.", .{subject});
            base_remedy = "Try rephrasing your prompt, or switch models with /model.";
            allow_retry_prefix = false;
        },
        .gateway_internal => try hw.print("The request to {s} failed due to a temporary gateway error.", .{subject}),
        .provider_error => try hw.print("{s} returned an unexpected error.", .{subject}),
    }

    var rem_low_buf: [200]u8 = undefined;
    const use_prefix = allow_retry_prefix and retry_prefix.len > 0;
    const tail_remedy = lowerAfterRetryPrefix(base_remedy, use_prefix, &rem_low_buf);
    var rem_buf: [256]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&rem_buf);
    if (use_prefix) try rw.writeAll(retry_prefix);
    try rw.writeAll(tail_remedy);

    var safe_buf: [400]u8 = undefined;
    const safe_msg = sanitizeMessage(&safe_buf, in.message, in.redact_urls and cls.sub != .cyber_policy);
    var tech_buf: [640]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&tech_buf);
    if (cls.kind == .quota_exhausted) {
        try tw.print("{s} — ", .{quota.quota_cap_marker});
    } else if (cls.kind == .access_denied) {
        try tw.writeAll("provider access denied — ");
    } else if (in.http_status != null and in.http_status.? >= 500) {
        try tw.writeAll("server error (5xx) — ");
    }
    try writeTechnicalEnvelope(&tw, in, safe_msg);

    const headline = try arena.dupe(u8, hw.buffered());
    const remedy = try arena.dupe(u8, rw.buffered());
    const technical = if (in.technical_override) |o| try arena.dupe(u8, o) else try arena.dupe(u8, tw.buffered());
    const text = try std.fmt.allocPrint(arena, "{s} {s} Technical details — {s}", .{ headline, remedy, technical });

    return .{
        .text = text,
        .detail = .{
            .kind = cls.kind.asText(),
            .attribution = cls.attribution.asText(),
            .provider = in.provider.id,
            .model = in.provider.model,
            .maker = maker,
            .headline = headline,
            .remedy = remedy,
            .technical = technical,
            .etype = if (in.etype.len > 0) try arena.dupe(u8, in.etype) else null,
            .code = if (in.code) |c| (if (c.len > 0) try arena.dupe(u8, c) else null) else null,
            .request_id = if (in.request_id) |r| (if (r.len > 0) try arena.dupe(u8, r) else null) else null,
            .http_status = in.http_status,
            .attempts = in.attempts,
        },
    };
}

pub const CapturedEnvelope = struct {
    etype: []const u8 = "",
    code: ?[]const u8 = null,
    message: []const u8 = "",
    request_id: ?[]const u8 = null,
};

/// Parse a captured 429/5xx HTTP error body (JSON or SSE error frame) into
/// `arena` without ever echoing raw unparsed bytes.
pub fn parseCapturedHttpBody(arena: Allocator, raw: []const u8) ?CapturedEnvelope {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{ .allocate = .alloc_always })) |v| {
        const obj: std.json.ObjectMap = switch (v) {
            .object => |o| o,
            .array => |arr| if (arr.items.len == 1 and arr.items[0] == .object) arr.items[0].object else return null,
            else => return null,
        };
        if (@import("tools.zig").apiErrorMessage(obj)) |msg| {
            return .{
                .etype = errorType(obj),
                .code = @import("agent_request_policy.zig").errorCode(obj),
                .message = msg,
                .request_id = @import("agent_responses.zig").errorRequestId(obj),
            };
        }
    } else |_| {}
    var named_err = false;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) {
            named_err = @import("sse_error_event.zig").namesError(line, named_err);
            continue;
        }
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{ .allocate = .alloc_always }) catch continue;
        if (parsed != .object) continue;
        const env = (@import("sse_error_event.zig").envelope(arena, parsed.object, named_err) catch null) orelse continue;
        if (@import("tools.zig").apiErrorMessage(env)) |msg| {
            return .{
                .etype = errorType(env),
                .code = @import("agent_request_policy.zig").errorCode(env),
                .message = msg,
                .request_id = @import("agent_responses.zig").errorRequestId(env),
            };
        }
    }
    return null;
}

pub fn reportEnvelope(self: *@import("agent.zig").Agent, etype: []const u8, code: ?[]const u8, msg: []const u8, request_id: ?[]const u8, attempts: usize) !void {
    if (isCyberPolicy(etype, code, msg)) g_session_cyber_policy = true;
    const formatted = try format(self.arena, .{ .provider = self.provider, .etype = etype, .code = code, .message = msg, .request_id = request_id, .attempts = @max(attempts, 1) });
    self.last_api_error_detail = formatted.detail;
    try self.sayApiError("{s}", .{formatted.text});
}

pub fn reportResponses(self: *@import("agent.zig").Agent, failure: @import("agent_responses.zig").ResponsesFailure, diagnostic: []const u8, attempts: usize) !void {
    const policy = @import("agent_request_policy.zig");
    if (@import("compaction_window.zig").rejectedByProvider(failure.message, failure.code) or
        policy.isPlanUsageLimit(failure.code) or
        (std.mem.eql(u8, self.provider.id, "chatgpt-new") and policy.isAuthError(failure.authText())))
        return self.sayApiError("{s}", .{diagnostic});
    if (isCyberPolicy(failure.etype, failure.code, failure.message)) g_session_cyber_policy = true;
    const formatted = try format(self.arena, .{ .provider = self.provider, .etype = failure.etype, .code = failure.code, .message = failure.message, .request_id = failure.request_id, .attempts = @max(attempts, 1), .technical_override = diagnostic });
    self.last_api_error_detail = formatted.detail;
    try self.sayApiError("{s}", .{formatted.text});
}

pub fn reportTransportGiveUp(self: *@import("agent.zig").Agent, err: anyerror, max_attempts: usize, captured_body: []const u8, local_down_url: []const u8) !void {
    if (err == error.RateLimited or err == error.ServerError) {
        const status: u16 = if (err == error.RateLimited) 429 else 503;
        const env = parseCapturedHttpBody(self.arena, captured_body);
        const formatted = try format(self.arena, .{
            .provider = self.provider,
            .etype = if (env != null and env.?.etype.len > 0) env.?.etype else if (err == error.RateLimited) "rate_limit_error" else "server_error",
            .code = if (env) |e| (e.code orelse if (err == error.RateLimited) "rate_limit_exceeded" else null) else if (err == error.RateLimited) "rate_limit_exceeded" else null,
            .message = if (env) |e| e.message else @errorName(err),
            .request_id = if (env) |e| e.request_id else null,
            .http_status = status,
            .attempts = max_attempts,
            .redact_urls = env != null,
        });
        self.last_api_error_detail = formatted.detail;
        self.last_api_error = formatted.text;
        try self.say("{s}\n", .{formatted.text});
        return;
    }

    var subj_buf: [160]u8 = undefined;
    const subject = formatSubject(&subj_buf, self.provider);
    var retry_buf: [48]u8 = undefined;
    const retry_prefix = formatRetryPrefix(&retry_buf, max_attempts);

    const headline = if (local_down_url.len > 0)
        try std.fmt.allocPrint(self.arena, "Could not connect to the local model server at {s}.", .{local_down_url})
    else
        try std.fmt.allocPrint(self.arena, "Lost network connection while contacting {s}.", .{subject});
    const remedy = if (local_down_url.len > 0)
        try self.arena.dupe(u8, "Start the local server, or switch models with /model.")
    else
        try std.fmt.allocPrint(self.arena, "{s}check your network connection and try again.", .{if (retry_prefix.len > 0) retry_prefix else "Please "});
    const technical = self.h2_reset.giveUpApiError(self.arena, "network error", err, local_down_url, max_attempts) orelse return error.OutOfMemory;
    const text = try std.fmt.allocPrint(self.arena, "{s} {s} Technical details — {s}", .{ headline, remedy, technical });
    self.last_api_error_detail = .{
        .kind = Kind.network_transport.asText(),
        .attribution = if (local_down_url.len > 0) Attribution.local_server.asText() else Attribution.network.asText(),
        .provider = self.provider.id,
        .model = self.provider.model,
        .maker = makerDisplay(self.provider.id, self.provider.model),
        .headline = headline,
        .remedy = remedy,
        .technical = technical,
        .attempts = max_attempts,
    };
    self.last_api_error = text;
    try self.say("{s}\n", .{text});
}
