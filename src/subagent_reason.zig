//! Why a child agent ended failed or cancelled, for the terminal frames an
//! ACP client gets (ADR 0358): the last progress row's
//! `_meta["graff/subagent"]`, the draft `subagent_update`, and the background
//! `graff/subagent_event` terminal event. A detached child's spawn call
//! already succeeded, so for it this is the only place the cause reaches the
//! client at all.
//!
//! The text is the cause the parent's tool result carries
//! (subagent_run.subagentFailure) and its class bracket, without the
//! "failed before producing a report" prefix or the retry advice. It is one
//! line of at most `max_bytes`, cut on a UTF-8 boundary with an ellipsis;
//! terminal escapes and control bytes are removed
//! (line_repl_disclosure.sanitized), credential-looking runs, absolute paths
//! and URL query strings are redacted (codedbpro_report.redact), and text
//! that trips the secret canary (learning_privacy.scanSecrets) is withheld.

const std = @import("std");
const util = @import("util.zig");
const subagent_run = @import("subagent_run.zig");
const subagent_retry = @import("subagent_retry.zig");

/// The longest `reason`, in bytes, ellipsis and class bracket included.
pub const max_bytes = 280;
pub const no_report = "subagent finished without a report";
/// What a child that unwound with an error before its outcome was recorded says.
pub const no_outcome = "subagent stopped before it recorded an outcome";
pub const withheld = "failure detail withheld: it looked like it contained a credential";
const ellipsis = "…";

/// What a failed or cancelled child's terminal frame adds.
pub const Why = struct {
    reason: []const u8,
    /// The `FailKind` tag (`quota`, `transport`, `model`, `invalid`, `auth`,
    /// `budget_exhausted`, `cancelled`, `synthesis_limit`, `unknown`). Null
    /// when the run ended without a classified error (an empty report).
    failure_kind: ?[]const u8 = null,

    /// Append `reason` and, when classified, `failureKind` to an object the
    /// caller has open.
    pub fn writeFields(self: Why, jw: anytype) !void {
        try jw.objectField("reason");
        try jw.write(self.reason);
        if (self.failure_kind) |kind| {
            try jw.objectField("failureKind");
            try jw.write(kind);
        }
    }
};

/// The cause subagentFailure writes after its colon. Shared so the parent's
/// result and the client's frame cannot name different causes.
pub fn cause(kind: subagent_run.FailKind, err: anyerror, detail: ?[]const u8) []const u8 {
    return if (kind == .cancelled or kind == .synthesis_limit) @errorName(err) else detail orelse @errorName(err);
}

pub const Reason = struct {
    buf: [max_bytes]u8 = undefined,
    len: usize = 0,
    kind: ?subagent_run.FailKind = null,

    pub fn why(r: *const Reason) ?Why {
        if (r.len == 0) return null;
        return .{ .reason = r.buf[0..r.len], .failure_kind = if (r.kind) |k| @tagName(k) else null };
    }

    /// "<cause> [<class> failure, N attempts]", classified exactly as
    /// subagentFailure classifies it. The bracket always survives the bound.
    pub fn fromFailure(r: *Reason, err: anyerror, detail: ?[]const u8, attempts: u8) void {
        const kind = subagent_run.classifyFailure(err, detail);
        var tag_buf: [96]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, " [{s} failure, {d} {s}]", .{ kind.label(), attempts, subagent_retry.attemptsWord(attempts) }) catch "";
        const head = clean(r.buf[0 .. max_bytes - tag.len], cause(kind, err, detail));
        @memcpy(r.buf[head.len..][0..tag.len], tag);
        r.len = head.len + tag.len;
        r.kind = kind;
    }

    /// The provisional reason runSub starts with, so an error that unwinds
    /// past the run (setup, allocation) still ends with a cause.
    pub fn unfinished() Reason {
        var r: Reason = .{};
        r.len = fit(&r.buf, no_outcome).len;
        return r;
    }

    /// Record why a child that ended in `state` did so, from runSub's
    /// outcome, replacing anything provisional. A completed child has no
    /// reason and its frames are unchanged.
    pub fn record(r: *Reason, state: []const u8, report: anyerror![]const u8, detail: ?[]const u8, attempts: u8) void {
        r.* = .{};
        if (std.mem.eql(u8, state, "completed")) return;
        if (report) |_| {
            // A report and a stop request: the stop is the cause.
            if (std.mem.eql(u8, state, "cancelled")) return r.fromFailure(error.Interrupted, null, attempts);
            r.len = clean(&r.buf, no_report).len;
            r.kind = null;
        } else |err| r.fromFailure(err, detail, attempts);
    }
};

/// One safe line of `raw` in `out`: escapes and control bytes removed,
/// whitespace collapsed, secrets redacted or withheld, and a UTF-8-boundary
/// cut with an ellipsis when it does not fit.
pub fn clean(out: []u8, raw: []const u8) []const u8 {
    if (!@import("learning_privacy.zig").scanSecrets(raw).safe()) return fit(out, withheld);
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plain = @import("line_repl_disclosure.zig").sanitized(a, util.utf8Prefix(raw, 2048)) catch return fit(out, "");
    const redacted = @import("codedbpro_report.zig").redact(a, plain) catch return fit(out, "");
    return fit(out, redacted);
}

fn fit(out: []u8, text: []const u8) []const u8 {
    if (text.len <= out.len) {
        @memcpy(out[0..text.len], text);
        return out[0..text.len];
    }
    if (out.len < ellipsis.len) return out[0..0];
    const kept = util.utf8Prefix(text, out.len - ellipsis.len);
    @memcpy(out[0..kept.len], kept);
    @memcpy(out[kept.len..][0..ellipsis.len], ellipsis);
    return out[0 .. kept.len + ellipsis.len];
}

test "an over-long reason is cut on a character boundary and keeps its class" {
    var long: [900]u8 = undefined;
    for (&long, 0..) |*c, k| c.* = if (k % 3 == 0) 0xE2 else if (k % 3 == 1) 0x96 else 0xB8; // "▸" repeated
    var r: Reason = .{};
    r.fromFailure(error.Unexpected, &long, 2);
    const why = r.why().?;
    try std.testing.expect(why.reason.len <= max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(why.reason));
    try std.testing.expect(std.mem.endsWith(u8, why.reason, "… [unknown failure, 2 attempts]"));
    try std.testing.expectEqualStrings("unknown", why.failure_kind.?);
}

test "control bytes and terminal escapes are removed from a reason" {
    var r: Reason = .{};
    r.fromFailure(error.Unexpected, "boom\x00\x07\x1b[31mred\x1b[0m\r\nnext\tline\x7f", 1);
    const reason = r.why().?.reason;
    for (reason) |b| try std.testing.expect(b >= 0x20 and b != 0x7f);
    try std.testing.expectEqualStrings("boomred next line [unknown failure, 1 attempt]", reason);
}

test "a reason never carries a credential the failure text echoed" {
    var r: Reason = .{};
    r.fromFailure(error.Unexpected, "401 Unauthorized: Authorization: Bearer abc.def", 1);
    try std.testing.expectEqualStrings(withheld ++ " [auth failure, 1 attempt]", r.why().?.reason);
    r = .{};
    r.fromFailure(error.Unexpected, "rejected key Ab3dEf9012345678ijklMNOP for https://api.example.test/v1?key=zz", 1);
    const reason = r.why().?.reason;
    try std.testing.expect(std.mem.indexOf(u8, reason, "Ab3dEf9012345678ijklMNOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "key=zz") == null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "<redacted>") != null);
}

test "the reason is the cause the parent's failed result names" {
    const detail = "openai 429: rate limited, try again later";
    const out = subagent_run.subagentFailure(std.testing.allocator, "sa-001-scout", error.Unexpected, detail, 3);
    defer std.testing.allocator.free(out.text);
    var r: Reason = .{};
    r.fromFailure(error.Unexpected, detail, 3);
    const why = r.why().?;
    try std.testing.expectEqualStrings(detail ++ " [quota/rate-limit failure, 3 attempts]", why.reason);
    try std.testing.expect(std.mem.indexOf(u8, out.text, why.reason) != null);
    try std.testing.expectEqualStrings("quota", why.failure_kind.?);
}

test "only a child that did not complete records a reason" {
    var r = Reason.unfinished();
    try std.testing.expectEqualStrings(no_outcome, r.why().?.reason);
    try std.testing.expect(r.why().?.failure_kind == null);
    r.record("completed", "the report", null, 1);
    try std.testing.expect(r.why() == null);
    r.record("failed", "", null, 1);
    try std.testing.expectEqualStrings(no_report, r.why().?.reason);
    try std.testing.expect(r.why().?.failure_kind == null);
    r = .{};
    r.record("cancelled", "partial report", null, 1);
    try std.testing.expectEqualStrings("Interrupted [cancelled failure, 1 attempt]", r.why().?.reason);
    try std.testing.expectEqualStrings("cancelled", r.why().?.failure_kind.?);
    r = .{};
    const failed: anyerror![]const u8 = error.Canceled;
    r.record("cancelled", failed, null, 1);
    try std.testing.expectEqualStrings("Canceled [cancelled failure, 1 attempt]", r.why().?.reason);
}
