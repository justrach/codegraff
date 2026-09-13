//! Fresh, bounded GitHub observations. CLI prose and local tests are never a
//! receipt for a remote PR head. Missing data is unknown, not an empty run list.
const std = @import("std");
const runner = @import("process_runner.zig");
const publish = @import("pr_publish.zig");
const A = std.mem.Allocator;
pub const Target = struct { cwd: []const u8 = ".", repo: ?[]const u8 = null, selector: []const u8 };
pub const Receipt = struct { head: []const u8 = "", status: publish.HeadStatus = .unknown, draft: bool = false, body: []const u8 = "" };

pub fn capture(gpa: A, io: std.Io, a: A, target: Target, argv: []const []const u8) ![]const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(a, argv);
    if (std.mem.eql(u8, argv[0], "gh")) if (target.repo) |repo| try args.appendSlice(a, &.{ "--repo", repo });
    const r = try runner.runCappedWithOptions(gpa, io, args.items, 256 * 1024, 2048, 15_000, .{ .cwd = .{ .path = target.cwd } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!runner.ranOk(r) or r.stdout_truncated or r.stderr_truncated) return error.EvidenceUnavailable;
    return a.dupe(u8, std.mem.trim(u8, r.stdout, " \r\n\t"));
}

pub fn localHead(gpa: A, io: std.Io, a: A, target: Target) ![]const u8 {
    const sha = try capture(gpa, io, a, target, &.{ "git", "rev-parse", "--verify", "HEAD" });
    if (!validSha(sha)) return error.InvalidHead;
    return sha;
}

/// --head selects an already-pushed remote branch, not the local checkout.
pub fn remoteHead(gpa: A, io: std.Io, a: A, target: Target, head: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, head, ":?%#") != null) return error.UnsupportedHead;
    const endpoint = try std.fmt.allocPrint(a, "repos/{s}/git/ref/heads/{s}", .{ target.repo orelse "{owner}/{repo}", head });
    var api_target = target;
    api_target.repo = null; // gh api selects the repository in its endpoint
    const sha = try capture(gpa, io, a, api_target, &.{ "gh", "api", endpoint, "--jq", ".object.sha" });
    if (!validSha(sha)) return error.InvalidHead;
    return sha;
}

pub fn validSha(sha: []const u8) bool {
    if (sha.len != 40 and sha.len != 64) return false;
    for (sha) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn pr(gpa: A, io: std.Io, a: A, target: Target) !Receipt {
    const json = try capture(gpa, io, a, target, &.{ "gh", "pr", "view", target.selector, "--json", "headRefOid,isDraft,body,statusCheckRollup" });
    return parsePr(a, json);
}

pub fn parsePr(a: A, json: []const u8) !Receipt {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    if (v != .object) return error.InvalidReceipt;
    const head = v.object.get("headRefOid") orelse return error.InvalidReceipt;
    const draft = v.object.get("isDraft") orelse return error.InvalidReceipt;
    const body = v.object.get("body") orelse return error.InvalidReceipt;
    const checks = v.object.get("statusCheckRollup") orelse return error.InvalidReceipt;
    if (head != .string or !validSha(head.string) or draft != .bool or body != .string) return error.InvalidReceipt;
    return .{ .head = head.string, .draft = draft.bool, .body = body.string, .status = checkStatus(checks) };
}

pub fn checkStatus(checks: std.json.Value) publish.HeadStatus {
    if (checks != .array) return .unknown;
    if (checks.array.items.len == 0) return .none;
    var pending = false;
    var passed = false;
    var unknown = false;
    for (checks.array.items) |item| {
        if (item != .object) {
            unknown = true;
            continue;
        }
        const state = text(item, "state");
        const status = text(item, "status");
        const conclusion = text(item, "conclusion");
        if (eq(state, "FAILURE") or eq(state, "ERROR") or eq(conclusion, "FAILURE") or eq(conclusion, "CANCELLED") or eq(conclusion, "TIMED_OUT") or eq(conclusion, "ACTION_REQUIRED") or eq(conclusion, "STALE") or eq(conclusion, "STARTUP_FAILURE")) return .failed;
        if (eq(state, "PENDING") or eq(status, "IN_PROGRESS") or eq(status, "QUEUED") or eq(status, "WAITING") or eq(status, "PENDING") or eq(status, "REQUESTED")) {
            pending = true;
            continue;
        }
        if (eq(state, "SUCCESS") or (eq(status, "COMPLETED") and eq(conclusion, "SUCCESS"))) {
            passed = true;
            continue;
        }
        if (eq(status, "COMPLETED") and (eq(conclusion, "SKIPPED") or eq(conclusion, "NEUTRAL"))) continue;
        unknown = true;
    }
    if (unknown) return .unknown;
    if (pending) return .pending;
    return if (passed) .passed else .unknown;
}
fn text(v: std.json.Value, key: []const u8) []const u8 {
    const field = v.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "#853 remote receipt cannot turn missing, pending, failed or partial checks into verified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = .{
        .{ "null", publish.HeadStatus.unknown },
        .{ "[]", publish.HeadStatus.none },
        .{ "[{\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"}]", publish.HeadStatus.passed },
        .{ "[{\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},{}]", publish.HeadStatus.unknown },
        .{ "[{\"state\":\"SUCCESS\"},{\"state\":\"PENDING\"}]", publish.HeadStatus.pending },
        .{ "[{\"state\":\"SUCCESS\"},{\"state\":\"FAILURE\"}]", publish.HeadStatus.failed },
    };
    inline for (cases) |c| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), c[0], .{});
        try std.testing.expectEqual(c[1], checkStatus(v));
    }
}
