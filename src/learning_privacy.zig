//! Privacy policy for federated prompt-policy learning.
//!
//! This is deliberately separate from ordinary usage telemetry. The mode is a
//! ceiling, not blanket content consent: template text also needs an exact,
//! session-local approval before the OTLP fleet path may carry it. Raw task
//! instances, bindings, reports, and traces have no upload path here.

const std = @import("std");
const Io = std.Io;
const util = @import("util.zig");

pub const Mode = enum(u8) {
    local,
    aggregate,
    templates,
    examples,

    pub fn label(self: Mode) []const u8 {
        return switch (self) {
            .local => "Local",
            .aggregate => "Aggregate",
            .templates => "Templates",
            .examples => "Examples",
        };
    }

    pub fn badge(self: Mode) []const u8 {
        return switch (self) {
            .local => "Privacy:Local",
            .aggregate => "Privacy:Aggregate",
            .templates => "Privacy:Templates",
            .examples => "Privacy:Examples",
        };
    }
};

/// Aggregate is the default ceiling: the fleet loop only improves anything if
/// prompt-free signed grades actually reach it, and this tier carries counts,
/// deltas, significance, and fingerprints — never prompt text, tasks, code,
/// paths, or traces. Every higher tier (template/example text) still requires
/// an explicit per-artifact approval, and `--learning-privacy local`,
/// `GRAFF_LEARNING_PRIVACY=local`, `/privacy local`, `GRAFF_FLEET=off`, or
/// `--no-telemetry` each turn contribution off.
var mode_value: std.atomic.Value(u8) = .init(@intFromEnum(Mode.aggregate));
var approvals_mu: Io.Mutex = .init;
const max_approved_templates = 64;
var approved_hashes: [max_approved_templates][32]u8 = undefined;
var approved_len: usize = 0;
var aggregate_once: bool = false;

/// Exact lowercase values only. Unknown, case-varied, or whitespace-padded
/// configuration fails closed to Local when passed through init(): a garbled
/// setting must never silently raise the ceiling, even though an absent one
/// leaves the Aggregate default in place.
pub fn parse(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "aggregate")) return .aggregate;
    if (std.mem.eql(u8, value, "templates")) return .templates;
    if (std.mem.eql(u8, value, "examples")) return .examples;
    return null;
}

pub const default_mode: Mode = .aggregate;

pub fn init(cli_mode: ?Mode, env_value: ?[]const u8) void {
    const selected = cli_mode orelse if (env_value) |value| parse(value) orelse .local else default_mode;
    mode_value.store(@intFromEnum(selected), .release);
    // Startup is single-threaded. Artifact approvals never persist between
    // processes, and a repo-controlled file cannot silently grant them.
    approved_len = 0;
    aggregate_once = false;
}

pub fn current() Mode {
    return @enumFromInt(mode_value.load(.acquire));
}

pub fn setMode(io: Io, mode: Mode) void {
    approvals_mu.lockUncancelable(io);
    defer approvals_mu.unlock(io);
    mode_value.store(@intFromEnum(mode), .release);
    // A mode change invalidates content approvals. Raising the ceiling must
    // still ask for each artifact; lowering it revokes them immediately.
    approved_len = 0;
    aggregate_once = false;
}

pub fn allowsAggregate() bool {
    return @intFromEnum(current()) >= @intFromEnum(Mode.aggregate);
}

pub fn allowsTemplateReview() bool {
    return @intFromEnum(current()) >= @intFromEnum(Mode.templates);
}

pub fn allowsExamples() bool {
    return current() == .examples;
}

/// The model-facing learning tool may request one explicit evaluate → grade →
/// submit operation while the session otherwise remains Local. This permit is
/// memory-only, single-use, and deliberately separate from --yolo/approvals.
pub fn authorizeAggregateOnce(io: Io) void {
    approvals_mu.lockUncancelable(io);
    defer approvals_mu.unlock(io);
    aggregate_once = true;
}

pub fn consumeAggregateOnce(io: Io) bool {
    approvals_mu.lockUncancelable(io);
    defer approvals_mu.unlock(io);
    if (!aggregate_once) return false;
    aggregate_once = false;
    return true;
}

pub const SecretScan = struct {
    matches: usize = 0,
    first_kind: []const u8 = "",

    pub fn safe(self: SecretScan) bool {
        return self.matches == 0;
    }
};

const secret_markers = [_]struct { needle: []const u8, kind: []const u8 }{
    .{ .needle = "-----BEGIN PRIVATE KEY-----", .kind = "private key" },
    .{ .needle = "-----BEGIN OPENSSH PRIVATE KEY-----", .kind = "SSH private key" },
    .{ .needle = "authorization: bearer ", .kind = "authorization header" },
    .{ .needle = "aws_access_key_id", .kind = "AWS credential" },
    .{ .needle = "aws_secret_access_key", .kind = "AWS credential" },
    .{ .needle = "openai_api_key", .kind = "API key assignment" },
    .{ .needle = "anthropic_api_key", .kind = "API key assignment" },
    .{ .needle = "github_token", .kind = "GitHub token assignment" },
    .{ .needle = "ghp_", .kind = "GitHub token" },
    .{ .needle = "github_pat_", .kind = "GitHub token" },
    .{ .needle = "sk-proj-", .kind = "API key" },
    .{ .needle = "xoxb-", .kind = "Slack token" },
    .{ .needle = "xoxp-", .kind = "Slack token" },
};

/// A deliberately conservative local canary scan. It is a second boundary,
/// not a claim that arbitrary text can be perfectly sanitized: typed schemas,
/// exact approval, and server-side validation remain required too.
pub fn scanSecrets(text: []const u8) SecretScan {
    var result: SecretScan = .{};
    for (secret_markers) |marker| {
        if (util.indexOfIgnoreCase(text, marker.needle) == null) continue;
        result.matches += 1;
        if (result.first_kind.len == 0) result.first_kind = marker.kind;
    }
    return result;
}

fn contentHash(text: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return digest;
}

pub fn displayFingerprint(text: []const u8) [16]u8 {
    const digest = contentHash(text);
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

/// Approve this exact template version for this process only. A changed byte
/// has a different hash and asks again. Secret-like content fails closed.
pub fn approveTemplate(io: Io, text: []const u8) bool {
    if (!allowsTemplateReview() or text.len == 0 or !scanSecrets(text).safe()) return false;
    const digest = contentHash(text);
    approvals_mu.lockUncancelable(io);
    defer approvals_mu.unlock(io);
    for (approved_hashes[0..approved_len]) |approved| {
        if (std.mem.eql(u8, &approved, &digest)) return true;
    }
    if (approved_len == max_approved_templates) return false;
    approved_hashes[approved_len] = digest;
    approved_len += 1;
    return true;
}

pub fn isTemplateApproved(io: Io, text: []const u8) bool {
    if (!allowsTemplateReview() or text.len == 0 or !scanSecrets(text).safe()) return false;
    const digest = contentHash(text);
    approvals_mu.lockUncancelable(io);
    defer approvals_mu.unlock(io);
    for (approved_hashes[0..approved_len]) |approved| {
        if (std.mem.eql(u8, &approved, &digest)) return true;
    }
    return false;
}

/// The only function fleet telemetry uses to admit prompt text. This makes an
/// omitted check at an individual propose call site safe by construction.
pub fn templateTextForUpload(io: Io, text: []const u8) []const u8 {
    return if (isTemplateApproved(io, text)) text else "";
}

test "learning privacy defaults to aggregate, fails closed, and modes form a ceiling" {
    init(null, null);
    try std.testing.expectEqual(Mode.aggregate, current());
    try std.testing.expect(allowsAggregate());
    try std.testing.expect(!allowsTemplateReview());
    init(null, "local");
    try std.testing.expectEqual(Mode.local, current());
    try std.testing.expect(!allowsAggregate());
    // A garbled value must not silently raise the ceiling to the default.
    init(null, "AGGREGATE");
    try std.testing.expectEqual(Mode.local, current());
    init(null, "aggregate ");
    try std.testing.expectEqual(Mode.local, current());
    init(.templates, "local");
    try std.testing.expectEqual(Mode.templates, current());
    try std.testing.expect(allowsAggregate());
    try std.testing.expect(allowsTemplateReview());
    try std.testing.expect(!allowsExamples());
}

test "secret canaries are blocked without flagging ordinary agent templates" {
    const canaries = [_][]const u8{
        "OPENAI_API_KEY=sk-proj-test-only-not-real",
        "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.test.signature",
        "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-real",
        "export AWS_SECRET_ACCESS_KEY=not-real",
        "token=ghp_abcdefghijklmnopqrstuvwxyz",
        "slack xoxb-111111111-222222222-notreal",
    };
    for (canaries) |canary| try std.testing.expect(!scanSecrets(canary).safe());
    const benign = [_][]const u8{
        "Review the selected files and report defensible correctness bugs.",
        "Run the repository test command, then summarize failures with file and line.",
        "Do not print credentials, authorization headers, environment values, or private keys.",
        "Compare the implementation against the task and give a concise verdict.",
    };
    for (benign) |text| try std.testing.expect(scanSecrets(text).safe());
}

test "template approval is exact, session-local, and cannot approve a canary" {
    const io = std.testing.io;
    setMode(io, .templates);
    defer setMode(io, .local);
    const safe = "You are a careful reviewer.";
    try std.testing.expectEqualStrings("", templateTextForUpload(io, safe));
    try std.testing.expect(approveTemplate(io, safe));
    try std.testing.expectEqualStrings(safe, templateTextForUpload(io, safe));
    try std.testing.expectEqualStrings("", templateTextForUpload(io, "You are a careful reviewer!"));
    try std.testing.expect(!approveTemplate(io, "GITHUB_TOKEN=ghp_not_a_real_token"));
    try std.testing.expectEqualStrings("", templateTextForUpload(io, "GITHUB_TOKEN=ghp_not_a_real_token"));
    setMode(io, .aggregate);
    try std.testing.expectEqualStrings("", templateTextForUpload(io, safe));
}

test "bundled aggregate consent is single-use and revoked by mode changes" {
    const io = std.testing.io;
    setMode(io, .local);
    authorizeAggregateOnce(io);
    try std.testing.expect(consumeAggregateOnce(io));
    try std.testing.expect(!consumeAggregateOnce(io));
    authorizeAggregateOnce(io);
    setMode(io, .local);
    try std.testing.expect(!consumeAggregateOnce(io));
}
