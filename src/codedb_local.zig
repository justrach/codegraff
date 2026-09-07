//! Local-only retrieval policy for native `codedb context` (#765).
//!
//! codedb's default composer may send relative paths and bounded snippets to a
//! hosted embeddings lane for advisory rerank. "No remote retention" is not no
//! egress. When repository policy or the per-call `local_only` argument
//! requires on-device retrieval, graff injects `context --local` before spawn
//! and never dispatches hybrid/semantic rerank. If that boundary cannot be
//! guaranteed, dispatch is refused. Ordinary reads stay native codedb
//! (ADR 0040) — this is not a codedb-pro redirect.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json_args = @import("json_args.zig");
const util = @import("util.zig");

pub const instruction_names = [_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" };
pub const policy_json_path = ".graff/policy.json";
pub const retrieval_policy_path = ".graff/retrieval-policy";

const phrases = [_][]const u8{
    "local-only retrieval",
    "local only retrieval",
    "local-only search",
    "local only search",
    "no transmission of working data",
    "do not transmit working data",
    "don't transmit working data",
    "never transmit working data",
    "prohibit transmission of working",
    "prohibiting transmission of working",
    "working data must not leave",
    "no remote rerank",
    "no remote ranking",
    "do not send working data",
    "never send working data",
    "do not transmit repository",
};

pub const Kind = enum { local, remote, refuse };

pub const Plan = struct {
    kind: Kind,
    inject_local: bool,
    refuse_reason: []const u8 = "",
};

pub const refuse_remote =
    "codedb context: repository policy requires local-only retrieval. Remote reranking sends relative paths and snippets over the network even when the provider claims no remote retention, so the call was not dispatched. Omit --hybrid/--semantic (graff will run `codedb context --local`) or pass local_only=true.";

const remote_flags = [_][]const u8{ "--hybrid", "--semantic" };
const local_flags = [_][]const u8{ "--local", "--no-semantic" };

pub fn textRequiresLocal(text: []const u8) bool {
    for (phrases) |p| {
        if (util.indexOfIgnoreCase(text, p) != null) return true;
    }
    return false;
}

pub fn policyJsonRequiresLocal(body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, std.mem.trim(u8, body, " \t\r\n"), .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    if (stringIsLocal(parsed.value.object.get("retrieval"))) return true;
    if (boolIsTrue(parsed.value.object.get("local_only"))) return true;
    const codedb = parsed.value.object.get("codedb") orelse return false;
    if (codedb != .object) return false;
    return stringIsLocal(codedb.object.get("retrieval")) or boolIsTrue(codedb.object.get("local_only"));
}

fn stringIsLocal(v: ?std.json.Value) bool {
    const val = v orelse return false;
    if (val != .string) return false;
    return std.ascii.eqlIgnoreCase(val.string, "local-only") or
        std.ascii.eqlIgnoreCase(val.string, "local_only") or
        std.ascii.eqlIgnoreCase(val.string, "local");
}

fn boolIsTrue(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}

pub fn retrievalPolicyRequiresLocal(body: []const u8) bool {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(trimmed, "local")) return true;
    return util.indexOfIgnoreCase(trimmed, "local-only") != null or
        util.indexOfIgnoreCase(trimmed, "local_only") != null;
}

pub fn dirRequiresLocal(io: Io, gpa: Allocator, dir: Io.Dir) bool {
    for (instruction_names) |name| {
        const body = dir.readFileAlloc(io, name, gpa, .limited(64 * 1024)) catch continue;
        defer gpa.free(body);
        if (textRequiresLocal(body)) return true;
    }
    if (dir.readFileAlloc(io, policy_json_path, gpa, .limited(16 * 1024))) |body| {
        defer gpa.free(body);
        if (policyJsonRequiresLocal(body)) return true;
    } else |_| {}
    if (dir.readFileAlloc(io, retrieval_policy_path, gpa, .limited(4 * 1024))) |body| {
        defer gpa.free(body);
        if (retrievalPolicyRequiresLocal(body)) return true;
    } else |_| {}
    return false;
}

pub fn inputRequiresLocal(input: std.json.Value) bool {
    return json_args.flag(input, "local_only");
}

pub fn tokenIsRemoteFlag(tok: []const u8) bool {
    for (remote_flags) |f| if (std.mem.eql(u8, tok, f)) return true;
    return false;
}

pub fn tokenIsLocalFlag(tok: []const u8) bool {
    for (local_flags) |f| if (std.mem.eql(u8, tok, f)) return true;
    return false;
}

pub fn restHasFlag(rest: []const u8, check: *const fn ([]const u8) bool) bool {
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |tok| {
        if (check(tok)) return true;
    }
    return false;
}

/// Default `context` is hybrid (remote advisory rerank) unless `--local`.
pub fn defaultWouldRemoteRerank(rest: []const u8) bool {
    return !restHasFlag(rest, tokenIsLocalFlag);
}

pub fn planContext(required_local: bool, rest: []const u8) Plan {
    if (!required_local) {
        if (restHasFlag(rest, tokenIsLocalFlag)) return .{ .kind = .local, .inject_local = false };
        return .{ .kind = .remote, .inject_local = false };
    }
    if (restHasFlag(rest, tokenIsRemoteFlag)) {
        return .{ .kind = .refuse, .inject_local = false, .refuse_reason = refuse_remote };
    }
    return .{ .kind = .local, .inject_local = !restHasFlag(rest, tokenIsLocalFlag) };
}

pub fn wouldInvokeRemoteRerank(plan: Plan) bool {
    return plan.kind == .remote;
}

/// Caller has already pushed `codedb` and `context`.
pub fn appendContextArgs(gpa: Allocator, argv: *std.ArrayList([]const u8), plan: Plan, rest: []const u8) !void {
    if (plan.inject_local) try argv.append(gpa, "--local");
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |tok| {
        if (tokenIsRemoteFlag(tok)) continue;
        try argv.append(gpa, tok);
    }
}

pub fn contextArgv(gpa: Allocator, plan: Plan, rest: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.append(gpa, "codedb");
    try argv.append(gpa, "context");
    try appendContextArgs(gpa, &argv, plan, rest);
    return argv.toOwnedSlice(gpa);
}

test "project-instruction phrases require local-only; generic offline notes do not" {
    try std.testing.expect(textRequiresLocal("Do not transmit working data to any network service."));
    try std.testing.expect(textRequiresLocal("Repository policy: local-only retrieval for codedb."));
    try std.testing.expect(textRequiresLocal("explicit project instructions prohibiting transmission of working data"));
    try std.testing.expect(textRequiresLocal("Use no remote rerank on context queries."));
    try std.testing.expect(!textRequiresLocal("tier 1 is deterministic and offline (no provider calls, no network, no spend)"));
    try std.testing.expect(!textRequiresLocal("Invalid remote compaction falls back locally"));
}

test "policy files honor local-only retrieval" {
    try std.testing.expect(policyJsonRequiresLocal("{\"retrieval\":\"local-only\"}"));
    try std.testing.expect(policyJsonRequiresLocal("{\"local_only\":true}"));
    try std.testing.expect(policyJsonRequiresLocal("{\"codedb\":{\"retrieval\":\"local\"}}"));
    try std.testing.expect(!policyJsonRequiresLocal("{\"retrieval\":\"hybrid\"}"));
    try std.testing.expect(!policyJsonRequiresLocal("{\"local_only\":false}"));
    try std.testing.expect(!policyJsonRequiresLocal("not json"));
    try std.testing.expect(retrievalPolicyRequiresLocal("local-only\n"));
    try std.testing.expect(retrievalPolicyRequiresLocal("local"));
    try std.testing.expect(!retrievalPolicyRequiresLocal("hybrid"));
}

test "dirRequiresLocal reads instructions and .graff policy files" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(!dirRequiresLocal(io, gpa, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "no remote rerank\n" });
    try std.testing.expect(!dirRequiresLocal(io, gpa, tmp.dir));

    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "Do not transmit working data.\n" });
    try std.testing.expect(dirRequiresLocal(io, gpa, tmp.dir));
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "be helpful\n" });
    try std.testing.expect(!dirRequiresLocal(io, gpa, tmp.dir));

    try tmp.dir.createDirPath(io, ".graff");
    try tmp.dir.writeFile(io, .{ .sub_path = policy_json_path, .data = "{\"retrieval\":\"local-only\"}\n" });
    try std.testing.expect(dirRequiresLocal(io, gpa, tmp.dir));
}

test "local-only context never selects remote rerank" {
    const gpa = std.testing.allocator;
    const task = "find the request authentication path";
    const plan = planContext(true, task);
    try std.testing.expectEqual(Kind.local, plan.kind);
    try std.testing.expect(plan.inject_local);
    try std.testing.expect(!wouldInvokeRemoteRerank(plan));
    try std.testing.expect(defaultWouldRemoteRerank(task));

    const argv = try contextArgv(gpa, plan, task);
    defer gpa.free(argv);
    try std.testing.expectEqualStrings("codedb", argv[0]);
    try std.testing.expectEqualStrings("context", argv[1]);
    try std.testing.expectEqualStrings("--local", argv[2]);
    try std.testing.expectEqualStrings(task[0..4], argv[3][0..4]);
    for (argv) |tok| {
        try std.testing.expect(!tokenIsRemoteFlag(tok));
        try std.testing.expect(!std.mem.eql(u8, tok, "--hybrid"));
        try std.testing.expect(!std.mem.eql(u8, tok, "--semantic"));
    }
}

test "local-only refuses hybrid flags before dispatch" {
    const plan = planContext(true, "--hybrid find auth");
    try std.testing.expectEqual(Kind.refuse, plan.kind);
    try std.testing.expect(!wouldInvokeRemoteRerank(plan));
    try std.testing.expect(std.mem.indexOf(u8, plan.refuse_reason, "not dispatched") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.refuse_reason, "local-only") != null);

    const semantic = planContext(true, "--semantic how does auth work");
    try std.testing.expectEqual(Kind.refuse, semantic.kind);
    try std.testing.expect(!wouldInvokeRemoteRerank(semantic));
}

test "per-call local_only and existing --local stay on-device" {
    const gpa = std.testing.allocator;
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"context auth\",\"local_only\":true}", .{});
        defer parsed.deinit();
        try std.testing.expect(inputRequiresLocal(parsed.value));
        const plan = planContext(inputRequiresLocal(parsed.value), "auth");
        try std.testing.expect(!wouldInvokeRemoteRerank(plan));
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"context auth\"}", .{});
        defer parsed.deinit();
        try std.testing.expect(!inputRequiresLocal(parsed.value));
    }
    const already = planContext(true, "--local auth");
    try std.testing.expectEqual(Kind.local, already.kind);
    try std.testing.expect(!already.inject_local);
    try std.testing.expect(!wouldInvokeRemoteRerank(already));
    const argv = try contextArgv(gpa, already, "--local auth");
    defer gpa.free(argv);
    var locals: usize = 0;
    for (argv) |tok| {
        if (std.mem.eql(u8, tok, "--local")) locals += 1;
        try std.testing.expect(!tokenIsRemoteFlag(tok));
    }
    try std.testing.expectEqual(@as(usize, 1), locals);
}

test "without local-only policy default context still allows remote rerank" {
    const plan = planContext(false, "find auth");
    try std.testing.expectEqual(Kind.remote, plan.kind);
    try std.testing.expect(wouldInvokeRemoteRerank(plan));
    try std.testing.expect(defaultWouldRemoteRerank("find auth"));
    try std.testing.expect(!defaultWouldRemoteRerank("--local find auth"));
    try std.testing.expect(!defaultWouldRemoteRerank("--no-semantic find auth"));
}
