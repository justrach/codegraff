//! Publication creates a durable verification obligation separate from todos.
//! A fresh remote observation is required at every completion attempt.
const std = @import("std");
const evidence = @import("pr_evidence.zig");
const Agent = @import("agent.zig").Agent;
const A = std.mem.Allocator;
pub const State = enum { unused, pending, draft, passed };
const Record = struct { session: []const u8 = "", target: evidence.Target, match_local: bool = true };
fn ledgerPath(a: A, cwd: []const u8, session: []const u8) ![]const u8 {
    // Independent conversations cannot fill each other's bounded ledger.
    // Hash even a restored ID so malformed saved data cannot become a path.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(session, &digest, .{});
    const file = try std.fmt.allocPrint(a, "{s}.json", .{std.fmt.bytesToHex(digest, .lower)});
    return std.fs.path.join(a, &.{ cwd, ".graff/pr-verification", file });
}
fn path(agent: *const Agent) ![]const u8 {
    return ledgerPath(agent.arena, agent.agent_cwd orelse ".", @import("http_headers.zig").sessionId(agent.io));
}

/// Written before the command is allowed. A failed publication remains
/// unresolved until a real PR is found or the user explicitly changes scope.
pub fn arm(agent: *Agent, target: evidence.Target, match_local: bool) !void {
    const file = try path(agent);
    const tx = try @import("repo_transaction.zig").Transaction.begin(agent.io, agent.arena, file);
    defer tx.end();
    var records: std.ArrayList(Record) = .empty;
    const existing = try tx.read();
    if (existing) |json| {
        const parsed = try std.json.parseFromSliceLeaky([]Record, agent.arena, json, .{});
        try records.appendSlice(agent.arena, parsed);
    }
    const session = @import("http_headers.zig").sessionId(agent.io);
    var found = false;
    for (records.items) |r| if (std.mem.eql(u8, r.session, session) and std.mem.eql(u8, r.target.selector, target.selector) and std.mem.eql(u8, r.target.repo orelse "", target.repo orelse "")) {
        found = true;
        break;
    };
    if (!found) try records.append(agent.arena, .{ .session = session, .target = target, .match_local = match_local });
    if (records.items.len > 32) return error.TooManyPendingPRs;
    const json = try std.json.Stringify.valueAlloc(agent.arena, records.items, .{});
    try tx.write(json);
    agent.pr_verification = .pending;
}

pub fn decision(receipt: evidence.Receipt, local: ?[]const u8, draft_authorized: bool) State {
    if (local) |sha| if (!std.mem.eql(u8, sha, receipt.head)) return .pending;
    if (receipt.draft) return if (draft_authorized) .draft else .pending;
    return if (receipt.status == .passed) .passed else .pending;
}

/// Diagnostic receipts are never read as acceptance authority. Write an
/// unavailable observation before the lookup so old green evidence is retired.
fn observe(agent: *Agent, record: Record, receipt: ?evidence.Receipt, local: ?[]const u8) !void {
    const key = try std.json.Stringify.valueAlloc(agent.arena, record.target, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
    const file = try std.fmt.allocPrint(agent.arena, "{s}.{s}.receipt.json", .{ try path(agent), std.fmt.bytesToHex(digest, .lower) });
    const tx = try @import("repo_transaction.zig").Transaction.begin(agent.io, agent.arena, file);
    defer tx.end();
    const json = try std.json.Stringify.valueAlloc(agent.arena, .{
        .target = record.target,
        .observation = if (receipt != null) "observed" else "unavailable",
        .receipt = receipt,
        .local_head = local,
    }, .{});
    try tx.write(json);
}

fn deferred(a: A, receipt: evidence.Receipt, local: ?[]const u8) ![]const u8 {
    const reason = if (local != null and !std.mem.eql(u8, local.?, receipt.head))
        "stale: local and remote heads differ"
    else if (receipt.draft)
        "draft: verified readiness requires a ready PR"
    else switch (receipt.status) {
        .pending => "pending: CI has not finished",
        .failed => "failed: CI reported a failure",
        .none => "missing: no CI checks were reported",
        .unknown => "unknown: CI evidence is incomplete",
        .passed => "unresolved",
    };
    // The complete bounded rollup is retained in the local receipt; avoid
    // flooding the model context when repositories have hundreds of checks.
    var limit = @min(receipt.checks_json.len, 16 * 1024);
    while (limit < receipt.checks_json.len and limit > 0 and receipt.checks_json[limit] & 0xc0 == 0x80) limit -= 1;
    return std.fmt.allocPrint(a, "completion deferred: current-head PR verification is {s}. Remote head: {s}. Observed checks: {s}{s}. Repeating attempt_completion or completing todos cannot waive verification. Draft publication and base-branch failures do not waive verification. Only the user can authorize a draft-only scope with /pr-acceptance draft.", .{ reason, receipt.head, receipt.checks_json[0..limit], if (limit < receipt.checks_json.len) " [truncated; full checks retained in local receipt]" else "" });
}

pub fn completionGate(agent: *Agent) ?[]const u8 {
    if (agent.review_mode) return null;
    const file = path(agent) catch return "completion deferred: unable to read PR verification obligation";
    const json = std.Io.Dir.cwd().readFileAlloc(agent.io, file, agent.arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return "completion deferred: PR verification obligation is unreadable",
    };
    agent.pr_verification = .pending;
    const records = std.json.parseFromSliceLeaky([]Record, agent.arena, json, .{}) catch return "completion deferred: PR verification obligation is malformed";
    if (records.len == 0 or records.len > 32) return "completion deferred: PR verification obligation is incomplete";
    var result: State = .passed;
    for (records) |record| {
        if (!std.mem.eql(u8, record.session, @import("http_headers.zig").sessionId(agent.io))) continue;
        observe(agent, record, null, null) catch return "completion deferred: unable to retire previous PR observation";
        const receipt = evidence.pr(agent.gpa, agent.io, agent.arena, record.target) catch return "completion deferred: current-head PR checks could not be observed. Local tests and completed todos are not remote CI evidence; retry the lookup. Draft-only completion requires explicit user authorization.";
        const local = if (record.match_local) evidence.localHead(agent.gpa, agent.io, agent.arena, record.target) catch return "completion deferred: local publication head could not be resolved" else null;
        observe(agent, record, receipt, local) catch return "completion deferred: unable to retain current PR observation";
        switch (decision(receipt, local, @import("pr_acceptance.zig").allowsDraft(agent))) {
            .pending, .unused => return deferred(agent.arena, receipt, local) catch "completion deferred: unable to describe PR verification evidence",
            .draft => result = .draft,
            .passed => {},
        }
    }
    agent.pr_verification = result;
    return null;
}

test "#853 a changed head or a second completion attempt cannot reuse a passing receipt" {
    const receipt = evidence.Receipt{ .head = "new", .status = .passed };
    try std.testing.expectEqual(State.pending, decision(receipt, "old", false));
    try std.testing.expectEqual(State.passed, decision(receipt, "new", false));
    for (0..2) |_| try std.testing.expectEqual(State.pending, decision(.{ .head = "new", .status = .pending }, "new", false));
    try std.testing.expectEqual(State.draft, decision(.{ .head = "new", .status = .failed, .draft = true }, "new", true));
}

pub fn hasObligation(agent: *const Agent) bool {
    const file = path(agent) catch return true;
    const json = std.Io.Dir.cwd().readFileAlloc(agent.io, file, agent.arena, .limited(64 * 1024)) catch |err| return err != error.FileNotFound;
    const records = std.json.parseFromSliceLeaky([]Record, agent.arena, json, .{}) catch return true;
    for (records) |record| if (std.mem.eql(u8, record.session, @import("http_headers.zig").sessionId(agent.io))) return true;
    return false;
}

pub fn taskVerified(agent: *const Agent) bool {
    if (!hasObligation(agent)) return true;
    if (agent.pr_verification != .passed) return false;
    return completionGate(@constCast(agent)) == null and agent.pr_verification == .passed;
}

test "PR obligations isolate conversations and cannot use restored IDs as paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try ledgerPath(a, "/workspace", "conversation-a");
    const second = try ledgerPath(a, "/workspace", "conversation-b");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings(first, try ledgerPath(a, "/workspace", "conversation-a"));
    const hostile = try ledgerPath(a, "/workspace", "../../elsewhere/../record");
    try std.testing.expect(std.mem.indexOf(u8, hostile, "..") == null);
    try std.testing.expectEqualStrings(std.fs.path.dirname(first).?, std.fs.path.dirname(hostile).?);
}

test "draft PRs require user-authorized scope even with passing or base-failing checks" {
    for ([_]@import("pr_publish.zig").HeadStatus{ .passed, .failed, .pending, .none, .unknown }) |status| {
        const receipt = evidence.Receipt{ .head = "new", .status = status, .draft = true };
        try std.testing.expectEqual(State.pending, decision(receipt, "new", false));
        try std.testing.expectEqual(State.draft, decision(receipt, "new", true));
        try std.testing.expectEqual(State.pending, decision(receipt, "old", true));
    }
    try std.testing.expectEqual(State.pending, decision(.{ .head = "new", .status = .failed }, "new", true));
}
