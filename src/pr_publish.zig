//! Non-draft PR publication preflight (#847). The public-write note is
//! disclosure policy; this module is the readiness gate in front of raw
//! `gh pr create` (and ready/undraft) issued through bash. `gh pr checks
//! --watch` after create is not this gate.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HeadStatus = enum { none, pending, failed, passed, unknown };

pub const Coverage = struct {
    helper_only: bool = false,
    one_separator_only: bool = false,
    untested_multi_separator: bool = false,
};

pub const Evidence = struct {
    head_sha: []const u8 = "",
    head_status: HeadStatus = .none,
    base_reproduced: bool = false,
    known_failures_disclosed: bool = false,
    body: []const u8 = "",
    coverage: Coverage = .{},
};

pub const Decision = enum { allow, block, draft_only };

const absolute_words = [_][]const u8{ "atomic", "preserved", "always", "guaranteed", "never fails", "fully preserved" };

pub fn containsToken(cmd: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| if (std.mem.eql(u8, tok, needle)) return true;
    return false;
}

fn seqAfter(cmd: []const u8, first: []const u8, second: []const u8, third: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    var state: u8 = 0;
    while (it.next()) |tok| {
        if (state == 0 and std.mem.eql(u8, tok, first)) {
            state = 1;
            continue;
        }
        if (state == 1) {
            if (tok[0] == '-') continue;
            if (std.mem.eql(u8, tok, second)) {
                state = 2;
                continue;
            }
            state = 0;
            continue;
        }
        if (state == 2) {
            if (tok[0] == '-') continue;
            return std.mem.eql(u8, tok, third);
        }
    }
    return false;
}

pub fn isPrCreate(cmd: []const u8) bool {
    return seqAfter(cmd, "gh", "pr", "create");
}

pub fn isPrReady(cmd: []const u8) bool {
    if (seqAfter(cmd, "gh", "pr", "ready")) return true;
    if (!seqAfter(cmd, "gh", "pr", "edit")) return false;
    return std.mem.indexOf(u8, cmd, "--draft=false") != null or std.mem.indexOf(u8, cmd, "--draft false") != null;
}

pub fn isPrChecksWatch(cmd: []const u8) bool {
    return seqAfter(cmd, "gh", "pr", "checks") and containsToken(cmd, "--watch");
}

pub fn isDraftFlag(cmd: []const u8) bool {
    if (std.mem.indexOf(u8, cmd, "--draft=false") != null) return false;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "--draft") or std.mem.eql(u8, tok, "--draft=true")) return true;
    }
    return false;
}

pub fn isNonDraftPublish(cmd: []const u8) bool {
    if (isPrChecksWatch(cmd)) return false;
    if (isPrCreate(cmd)) return !isDraftFlag(cmd);
    return isPrReady(cmd);
}

fn flagValue(cmd: []const u8, flag: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, cmd, flag) orelse return "";
    var rest = std.mem.trimStart(u8, cmd[idx + flag.len ..], " \t=");
    if (rest.len == 0) return "";
    if (rest[0] == '"' or rest[0] == '\'') {
        const q = rest[0];
        const end = std.mem.indexOfScalar(u8, rest[1..], q) orelse return rest[1..];
        return rest[1 .. 1 + end];
    }
    const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return rest[0..end];
}

pub fn extractBody(cmd: []const u8) []const u8 {
    const from_body = flagValue(cmd, "--body");
    if (from_body.len > 0) return from_body;
    return flagValue(cmd, "-b");
}

pub fn hasVerificationSection(body: []const u8) bool {
    const lower_needles = [_][]const u8{
        "## verification", "## verify", "verification",
        "commands run",    "local:",    "remote:",
        "zig build test",  "tier 1",    "ci:",
    };
    var buf: [2048]u8 = undefined;
    const n = @min(body.len, buf.len);
    for (body[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const slice = buf[0..n];
    for (lower_needles) |need| if (std.mem.indexOf(u8, slice, need) != null) return true;
    return false;
}

pub fn hasAbsoluteClaim(body: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const n = @min(body.len, buf.len);
    for (body[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const slice = buf[0..n];
    for (absolute_words) |w| if (std.mem.indexOf(u8, slice, w) != null) return true;
    return false;
}

pub fn knownFailuresDisclosed(body: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const n = @min(body.len, buf.len);
    for (body[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const slice = buf[0..n];
    return std.mem.indexOf(u8, slice, "known failure") != null or
        std.mem.indexOf(u8, slice, "known-failures") != null or
        std.mem.indexOf(u8, slice, "reproduced on") != null or
        std.mem.indexOf(u8, slice, "reproduces on the base") != null or
        std.mem.indexOf(u8, slice, "pre-existing on") != null;
}

pub fn claimOverreach(body: []const u8, coverage: Coverage) bool {
    if (coverage.helper_only and hasAbsoluteClaim(body)) return true;
    if (coverage.one_separator_only and coverage.untested_multi_separator) return true;
    if (!hasAbsoluteClaim(body)) return false;
    var buf: [2048]u8 = undefined;
    const n = @min(body.len, buf.len);
    for (body[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const slice = buf[0..n];
    const helperish = std.mem.indexOf(u8, slice, "helper") != null or
        std.mem.indexOf(u8, slice, "one separator") != null or
        std.mem.indexOf(u8, slice, "one-separator") != null;
    const dispatch = std.mem.indexOf(u8, slice, "dispatch") != null or
        std.mem.indexOf(u8, slice, "multiple separator") != null or
        std.mem.indexOf(u8, slice, "deletion path") != null;
    return helperish and !dispatch;
}

pub fn decide(draft: bool, ev: Evidence) Decision {
    if (draft) return .allow; // draft is the unresolved-readiness fallback
    if (claimOverreach(ev.body, ev.coverage)) return .block;
    if (!hasVerificationSection(ev.body)) return .block;
    return switch (ev.head_status) {
        .pending, .failed => if (ev.base_reproduced and (ev.known_failures_disclosed or knownFailuresDisclosed(ev.body)))
            .draft_only
        else
            .block,
        .unknown => .block,
        .none, .passed => .allow,
    };
}

pub fn reason(decision: Decision, ev: Evidence) []const u8 {
    return switch (decision) {
        .allow => "ready",
        .draft_only => "create as a draft, or disclose the base-reproduced failure in the PR body",
        .block => if (claimOverreach(ev.body, ev.coverage))
            "behavior claim overreaches the committed regression (helper/one-separator coverage is not the changed dispatch path)"
        else if (!hasVerificationSection(ev.body))
            "PR body needs a Verification section listing the commands and results actually run"
        else if (ev.head_status == .pending)
            "non-draft publication blocked: the exact head SHA still has a pending branch run"
        else if (ev.head_status == .failed)
            "non-draft publication blocked: the exact head SHA has an unexplained failed branch run"
        else
            "non-draft publication blocked: head readiness is unresolved",
    };
}

/// Classify `gh run list --json conclusion,status` output. Empty / unreadable
/// JSON is `none` so PR-only workflows stay allowed.
pub fn headStatusFromRunList(json: []const u8) HeadStatus {
    const trimmed = std.mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return .none;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, trimmed, .{}) catch return .none;
    defer parsed.deinit();
    if (parsed.value != .array) return .none;
    if (parsed.value.array.items.len == 0) return .none;
    var pending = false;
    var passed = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const status = if (item.object.get("status")) |v| (if (v == .string) v.string else "") else "";
        const conclusion = if (item.object.get("conclusion")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, status, "in_progress") or std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "waiting") or std.mem.eql(u8, status, "pending"))
            pending = true;
        if (std.mem.eql(u8, conclusion, "failure") or std.mem.eql(u8, conclusion, "cancelled") or std.mem.eql(u8, conclusion, "timed_out") or std.mem.eql(u8, conclusion, "startup_failure"))
            return .failed;
        if (std.mem.eql(u8, conclusion, "success")) passed = true;
    }
    if (pending) return .pending;
    if (passed) return .passed;
    return .unknown;
}

pub fn refuseText(arena: Allocator, cmd: []const u8, ev: Evidence) []const u8 {
    const draft = isDraftFlag(cmd);
    const d = decide(draft, ev);
    const why = reason(d, ev);
    return std.fmt.allocPrint(arena, "PR publication preflight: the GitHub write was NOT performed. {s}. Inspect the exact head SHA before `gh pr create`; `gh pr checks --watch` after create is not this gate. Use --draft when readiness is unresolved.", .{why}) catch why;
}

var g_evidence: ?Evidence = null;

pub fn setTestEvidence(ev: Evidence) void {
    g_evidence = ev;
}

pub fn clearTestEvidence() void {
    g_evidence = null;
}

pub fn testEvidence() ?Evidence {
    return g_evidence;
}

/// Live gatherer: tests inject evidence. Production treats a missing remote
/// run as `none` (PR-only workflows). Recorded failures stay failures.
pub fn evidenceFor(cmd: []const u8) Evidence {
    var ev = g_evidence orelse Evidence{};
    const body = extractBody(cmd);
    if (ev.body.len == 0) ev.body = body;
    if (knownFailuresDisclosed(ev.body)) ev.known_failures_disclosed = true;
    return ev;
}

pub fn gateCommand(arena: Allocator, cmd: []const u8) ?[]const u8 {
    if (isPrChecksWatch(cmd)) return null;
    if (!isPrCreate(cmd) and !isPrReady(cmd)) return null;
    const ev = evidenceFor(cmd);
    const draft = isDraftFlag(cmd) and !isPrReady(cmd);
    return switch (decide(draft, ev)) {
        .allow => null,
        .block, .draft_only => refuseText(arena, cmd, ev),
    };
}

test "classifies create, draft, ready, and checks --watch" {
    try std.testing.expect(isPrCreate("gh pr create --title x --body y"));
    try std.testing.expect(isPrCreate("GH_PAGER=cat gh pr create --fill"));
    try std.testing.expect(isDraftFlag("gh pr create --draft --title x"));
    try std.testing.expect(!isDraftFlag("gh pr create --draft=false"));
    try std.testing.expect(isNonDraftPublish("gh pr create --title x --body y"));
    try std.testing.expect(!isNonDraftPublish("gh pr create --draft --title x"));
    try std.testing.expect(isPrReady("gh pr ready"));
    try std.testing.expect(isPrChecksWatch("gh pr checks --watch"));
    try std.testing.expect(!isNonDraftPublish("gh pr checks --watch"));
}

test "#847 failed or pending head blocks non-draft create" {
    const body = "## Verification\nlocal: zig build test (pass)\nremote: pending";
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .failed, .body = body }));
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .pending, .body = body }));
    try std.testing.expectEqual(Decision.allow, decide(true, .{ .head_status = .failed, .body = body }));
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .passed, .body = body }));
}

test "#847 base-reproduced failure needs disclosure or a draft" {
    const bare = "## Verification\nzig build test";
    const disclosed = "## Verification\nknown failure reproduced on the base branch\nzig build test";
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .failed, .base_reproduced = true, .body = bare }));
    try std.testing.expectEqual(Decision.draft_only, decide(false, .{ .head_status = .failed, .base_reproduced = true, .body = disclosed }));
    try std.testing.expectEqual(Decision.allow, decide(true, .{ .head_status = .failed, .base_reproduced = true, .body = disclosed }));
}

test "#847 PR-only workflows with no pre-PR run stay allowed" {
    const body = "## Verification\nlocal: zig build test\nremote: no pre-PR run; CI is PR-triggered";
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .none, .body = body }));
}

test "#847 missing verification section blocks non-draft" {
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .passed, .body = "fixes the bug" }));
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .passed, .body = "## Verification\nzig build test: pass" }));
}

test "#847 one-separator helper test cannot publish an atomic claim" {
    const body =
        \\Atomic token deletion is preserved.
        \\## Verification
        \\helper test: one separator boundary
    ;
    const cov = Coverage{ .helper_only = true, .one_separator_only = true, .untested_multi_separator = true };
    try std.testing.expect(claimOverreach(body, cov));
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .passed, .body = body, .coverage = cov }));
    const wide =
        \\Atomic delete on the dispatch path.
        \\## Verification
        \\exercised multiple separators on the deletion path
    ;
    try std.testing.expect(!claimOverreach(wide, .{}));
}

test "#847 gh pr checks --watch is not the readiness gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(gateCommand(arena_state.allocator(), "gh pr checks --watch") == null);
}

test "#847 gateCommand blocks a non-draft create with failed head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    setTestEvidence(.{
        .head_sha = "abc123",
        .head_status = .failed,
        .body = "## Verification\nzig build test",
    });
    defer clearTestEvidence();
    const msg = gateCommand(arena_state.allocator(), "gh pr create --title t --body '## Verification\nzig build test'").?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "NOT performed") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "checks --watch") != null);
}

test "#847 run-list JSON maps failed, pending, passed, and empty" {
    try std.testing.expectEqual(HeadStatus.failed, headStatusFromRunList(
        \\[{"conclusion":"failure","status":"completed","headSha":"abc"}]
    ));
    try std.testing.expectEqual(HeadStatus.pending, headStatusFromRunList(
        \\[{"conclusion":"","status":"in_progress","headSha":"abc"}]
    ));
    try std.testing.expectEqual(HeadStatus.passed, headStatusFromRunList(
        \\[{"conclusion":"success","status":"completed"}]
    ));
    try std.testing.expectEqual(HeadStatus.none, headStatusFromRunList("[]"));
    try std.testing.expectEqual(HeadStatus.none, headStatusFromRunList(""));
}

test "extractBody reads --body quoted text" {
    try std.testing.expectEqualStrings("hello", extractBody("gh pr create --body \"hello\" --title x"));
    try std.testing.expect(hasVerificationSection("## Verification\nran zig build test"));
    try std.testing.expect(hasAbsoluteClaim("atomic delete is preserved"));
}
