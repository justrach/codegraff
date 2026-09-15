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
    head_status: HeadStatus = .unknown,
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
        if (state == 0 and std.mem.eql(u8, std.fs.path.basename(tok), first)) {
            state = 1;
            continue;
        }
        if (state == 1) {
            if (tok[0] == '-') {
                if (std.mem.eql(u8, tok, "-R") or std.mem.eql(u8, tok, "--repo")) _ = it.next();
                continue;
            }
            if (std.mem.eql(u8, tok, second)) {
                state = 2;
                continue;
            }
            state = 0;
            continue;
        }
        if (state == 2) {
            if (tok[0] == '-') {
                if (std.mem.eql(u8, tok, "-R") or std.mem.eql(u8, tok, "--repo")) _ = it.next();
                continue;
            }
            if (std.mem.eql(u8, tok, third)) return true;
            state = 0;
        }
    }
    return false;
}

pub fn isPrCreate(cmd: []const u8) bool {
    return @import("artifact_claim_command.zig").isPrCreate(cmd);
}

pub fn isPrReady(cmd: []const u8) bool {
    const command = @import("artifact_claim_command.zig");
    if (command.isPrReady(cmd)) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const parsed = @import("pr_command.zig").parse(arena.allocator(), cmd) catch return true;
        return !parsed.has("--undo");
    }
    if (!command.isPrEdit(cmd)) return false;
    return std.mem.indexOf(u8, cmd, "--draft=false") != null or std.mem.indexOf(u8, cmd, "--draft false") != null;
}

pub fn isPrChecksWatch(cmd: []const u8) bool {
    return seqAfter(cmd, "gh", "pr", "checks") and containsToken(cmd, "--watch");
}

pub fn isDraftFlag(cmd: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = @import("pr_command.zig").parse(arena.allocator(), cmd) catch return false;
    return parsed.draft();
}

pub fn isNonDraftPublish(cmd: []const u8) bool {
    if (isPrCreate(cmd)) return !isDraftFlag(cmd);
    return isPrReady(cmd);
}

pub fn extractBody(cmd: []const u8) []const u8 {
    // Keep this legacy pure helper for tests; production uses pr_command and
    // reads --body-file through the bounded evidence gatherer.
    for ([_][]const u8{ "--body ", "-b " }) |flag| {
        const index = std.mem.indexOf(u8, cmd, flag) orelse continue;
        const rest = std.mem.trimStart(u8, cmd[index + flag.len ..], " ");
        if (rest.len == 0) return "";
        if (rest[0] == '"' or rest[0] == '\'') {
            const end = std.mem.indexOfScalar(u8, rest[1..], rest[0]) orelse return "";
            return rest[1..][0..end];
        }
        return rest[0 .. std.mem.indexOfAny(u8, rest, " \t") orelse rest.len];
    }
    return "";
}

// A disclosure format check, not evidence that a command ran or covers a claim.
// Independent head observations and retained local failures remain authoritative.
fn containsInsensitive(text: []const u8, needle: []const u8) bool {
    if (text.len < needle.len) return false;
    for (0..text.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn reportedResult(text: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n.,:;()[]*!—");
    while (words.next()) |word| {
        for ([_][]const u8{ "pass", "passed", "fail", "failed", "success", "successful", "failure", "pending", "skipped", "blocked" }) |result| {
            if (std.ascii.eqlIgnoreCase(word, result)) return true;
        }
    }
    return containsInsensitive(text, "exit 0") or containsInsensitive(text, "exit code 0");
}

pub fn hasVerificationSection(body: []const u8) bool {
    var local = false;
    var remote = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r-*#");
        if (std.ascii.startsWithIgnoreCase(line, "local:")) {
            const value = std.mem.trim(u8, line[6..], " \t");
            // Keep the command separate from the result: a script named
            // test_passed.py is not a reported successful execution.
            const begin = std.mem.indexOfScalar(u8, value, '`') orelse continue;
            const tail = value[begin + 1 ..];
            const end = std.mem.indexOfScalar(u8, tail, '`') orelse continue;
            if (std.mem.trim(u8, tail[0..end], " \t").len == 0) continue;
            local = local or reportedResult(tail[end + 1 ..]);
        } else if (std.ascii.startsWithIgnoreCase(line, "remote:") or std.ascii.startsWithIgnoreCase(line, "ci:")) {
            remote = remote or reportedResult(line) or containsInsensitive(line, "no pre-pr run") or
                containsInsensitive(line, "no runs") or containsInsensitive(line, "not run") or
                containsInsensitive(line, "unavailable") or containsInsensitive(line, "unknown");
        }
    }
    return local and remote;
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
            "PR body needs Local: `command` — result and Remote: CI status (or no pre-PR runs); report the commands and results actually observed"
        else if (ev.head_status == .pending)
            "non-draft publication blocked: the exact head SHA still has a pending branch run"
        else if (ev.head_status == .failed)
            "non-draft publication blocked: the exact head SHA has an unexplained failed branch run"
        else
            "non-draft publication blocked: head readiness is unresolved",
    };
}

/// Only a successfully parsed empty array means no pre-PR runs.
pub fn headStatusFromRunList(json: []const u8) HeadStatus {
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return .unknown;
    defer parsed.deinit();
    if (parsed.value != .array) return .unknown;
    if (parsed.value.array.items.len == 0) return .none;
    var pending = false;
    var passed = false;
    var unknown = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) {
            unknown = true;
            continue;
        }
        const sv = item.object.get("status") orelse {
            unknown = true;
            continue;
        };
        const cv = item.object.get("conclusion") orelse {
            unknown = true;
            continue;
        };
        if (sv != .string or (cv != .string and cv != .null)) {
            unknown = true;
            continue;
        }
        const status = sv.string;
        const conclusion = if (cv == .string) cv.string else "";
        for ([_][]const u8{ "failure", "cancelled", "timed_out", "startup_failure", "action_required", "stale" }) |failure|
            if (std.mem.eql(u8, conclusion, failure)) return .failed;
        if (!std.mem.eql(u8, status, "completed")) {
            if (std.mem.eql(u8, status, "in_progress") or std.mem.eql(u8, status, "queued") or std.mem.eql(u8, status, "waiting") or std.mem.eql(u8, status, "pending") or std.mem.eql(u8, status, "requested")) pending = true else unknown = true;
        } else if (std.mem.eql(u8, conclusion, "success")) {
            passed = true;
        } else if (!std.mem.eql(u8, conclusion, "skipped") and !std.mem.eql(u8, conclusion, "neutral")) unknown = true;
    }
    if (unknown) return .unknown;
    if (pending) return .pending;
    return if (passed) .passed else .unknown;
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
    const body = "## Verification\nlocal: `zig build test` (pass)\nremote: pending";
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .failed, .body = body }));
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .pending, .body = body }));
    try std.testing.expectEqual(Decision.allow, decide(true, .{ .head_status = .failed, .body = body }));
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .passed, .body = body }));
}

test "#847 base-reproduced failure needs disclosure or a draft" {
    const bare = "## Verification\nzig build test";
    const disclosed = "## Verification\nknown failure reproduced on the base branch\nLocal: `zig build test` failed\nRemote: failed";
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .failed, .base_reproduced = true, .body = bare }));
    try std.testing.expectEqual(Decision.draft_only, decide(false, .{ .head_status = .failed, .base_reproduced = true, .body = disclosed }));
    try std.testing.expectEqual(Decision.allow, decide(true, .{ .head_status = .failed, .base_reproduced = true, .body = disclosed }));
}

test "#847 PR-only workflows with no pre-PR run stay allowed" {
    const body = "## Verification\nlocal: `zig build test` passed\nremote: no pre-PR run; CI is PR-triggered";
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .none, .body = body }));
}

test "#847 missing verification section blocks non-draft" {
    try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .passed, .body = "fixes the bug" }));
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .passed, .body = "## Verification\nLocal: `zig build test`: pass\nRemote: passed" }));
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
        .body = "Local: `zig build test` passed\nRemote: failed",
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
    try std.testing.expectEqual(HeadStatus.unknown, headStatusFromRunList(""));
}

test "extractBody reads --body quoted text" {
    try std.testing.expectEqualStrings("hello", extractBody("gh pr create --body \"hello\" --title x"));
    try std.testing.expect(hasVerificationSection("Local: `zig build test` passed\nRemote: no pre-PR runs"));
    try std.testing.expect(hasAbsoluteClaim("atomic delete is preserved"));
}

test "#847 compound checks cannot hide a later publication and ready undo stays available" {
    try std.testing.expect(isPrCreate("gh pr checks --watch && gh pr create --title t --body b"));
    try std.testing.expect(isNonDraftPublish("gh pr checks --watch && gh pr create --title t --body b"));
    try std.testing.expect(isPrCreate("/usr/local/bin/gh -R owner/repo pr create --body x"));
    try std.testing.expect(!isPrReady("gh pr ready --undo"));
    try std.testing.expect(!isDraftFlag("gh pr create --body '--draft'"));
}

test "#847 verification heading is not commands and results" {
    for ([_][]const u8{
        "verification",
        "## Verification\nLocal tests passed.",
        "Local: `zig build test`\nRemote: passed",
        "Local: `zig build test` passed",
        "Local: `test_passed.py`\nRemote: passed",
        "Local: `` passed\nRemote: passed",
    }) |body| {
        try std.testing.expectEqual(Decision.block, decide(false, .{ .head_status = .passed, .body = body }));
        try std.testing.expectEqual(Decision.allow, decide(true, .{ .head_status = .passed, .body = body }));
    }
}

test "#847 verification disclosure after long body is inspected" {
    var body: [3200]u8 = undefined;
    @memset(&body, 'x');
    const ending = "\n- LOCAL: `python3 -m unittest` — passed.\n- CI: no pre-PR runs.";
    @memcpy(body[body.len - ending.len ..], ending);
    try std.testing.expectEqual(Decision.allow, decide(false, .{ .head_status = .none, .body = &body }));
}
