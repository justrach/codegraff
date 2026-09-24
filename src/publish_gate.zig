//! Bash-side publication gate (#840, #847): artifact claims and PR readiness
//! run before the command executes. Presence ACK is a separate one-shot and
//! does not clear either check.

const std = @import("std");
const builtin = @import("builtin");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ExecResult = tools_mod.ExecResult;
const artifact_claim = @import("artifact_claim.zig");
const pr_publish = @import("pr_publish.zig");

fn observe(self: *Agent, cmd: []const u8) !?ExecResult {
    const command = @import("pr_command.zig").parse(self.arena, cmd) catch return .{ .text = "PR publication preflight: the write was NOT performed. Use a separate literal gh pr command so its repository, head, draft flag and body can be verified.", .is_error = true };
    const evmod = @import("pr_evidence.zig");
    var target = evmod.Target{ .cwd = command.cwd orelse self.agent_cwd orelse ".", .repo = command.flag("--repo", "-R"), .selector = command.flag("--head", "-H") orelse "" };
    if (command.cwd != null and self.agent_cwd != null and !std.fs.path.isAbsolute(target.cwd)) target.cwd = try std.fs.path.join(self.arena, &.{ self.agent_cwd.?, target.cwd });
    var dir = try std.Io.Dir.cwd().openDir(self.io, target.cwd, .{});
    defer dir.close(self.io);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    target.cwd = try self.arena.dupe(u8, path_buf[0..try dir.realPath(self.io, &path_buf)]);
    const creating = std.mem.eql(u8, command.verb, "create");
    if (!creating) target.selector = command.selector() orelse "";
    if (target.selector.len == 0) target.selector = evmod.capture(self.gpa, self.io, self.arena, target, &.{ "git", "branch", "--show-current" }) catch "";
    if (target.selector.len == 0) return .{ .text = "PR publication preflight: cannot resolve the target branch or PR; write NOT performed", .is_error = true };
    var ev: pr_publish.Evidence = .{};
    const draft = creating and command.draft();
    if (!draft) {
        if (self.publication_checks.unresolved(try @import("pr_local_checks.zig").repositoryRoot(self, target.cwd))) |command_text|
            return .{ .text = try std.fmt.allocPrint(self.arena, "PR publication preflight: observed local check has no successful completion: {s}. Rerun it successfully or publish a draft; write NOT performed.", .{command_text}), .is_error = true };
        if (creating) {
            ev.head_sha = evmod.localHead(self.gpa, self.io, self.arena, target) catch "";
            // An explicit alternate head must be resolved independently of HEAD.
            if (command.flag("--head", "-H")) |head| {
                ev.head_sha = evmod.remoteHead(self.gpa, self.io, self.arena, target, head) catch "";
            }
            if (evmod.validSha(ev.head_sha)) {
                ev.head_status = headStatus(self, target, ev.head_sha);
            }
            ev.body = command.flag("--body", "-b") orelse "";
            if (command.flag("--body-file", "-F")) |body_file| {
                const file = if (std.fs.path.isAbsolute(body_file)) body_file else try std.fs.path.join(self.arena, &.{ target.cwd, body_file });
                ev.body = std.Io.Dir.cwd().readFileAlloc(self.io, file, self.arena, .limited(64 * 1024)) catch "";
            }
        } else {
            const receipt = evmod.pr(self.gpa, self.io, self.arena, target) catch evmod.Receipt{};
            ev = .{ .head_sha = receipt.head, .head_status = receipt.status, .body = receipt.body };
        }
    }
    if (!draft and ev.head_status == .pending) {
        var poll: PendingPoll = .{ .agent = self, .target = target, .creating = creating, .alternate_head = command.flag("--head", "-H"), .initial = ev, .started = std.Io.Timestamp.now(self.io, .awake) };
        ev = waitPending(&poll, ev) catch |err| return .{
            .text = if (err == error.Interrupted) "PR publication preflight: waiting for CI was cancelled; write NOT performed." else "PR publication preflight: the head changed or readiness could not be refreshed while waiting; write NOT performed.",
            .is_error = true,
            .cancelled = err == error.Interrupted,
        };
    }
    if (pr_publish.decide(draft, ev) != .allow) return .{ .text = pr_publish.refuseText(self.arena, cmd, ev), .is_error = true };
    if (!draft) {
        const review = @import("pr_claim_review.zig").review(self, target, command.flag("--base", "-B"), creating, ev.head_sha, ev.body, ev.head_status) catch |err|
            return .{ .text = if (err == error.ReviewTooLarge)
                "PR publication preflight: claim review input exceeded its size limit (128 KiB committed source budget or 256 KiB review packet); write NOT performed. Narrow the change or provide smaller relevant evidence."
            else
                "PR publication preflight: claim review could not establish readiness from the committed source and tests; write NOT performed. Keep a draft while evidence is unresolved.", .is_error = true };
        if (review.verdict != .supported) return .{ .text = try std.fmt.allocPrint(self.arena, "PR publication preflight: claim review is {s}: {s}. Write NOT performed; keep a draft or fix the unsupported claim and coverage.", .{ @tagName(review.verdict), review.reason }), .is_error = true };
    }
    @import("pr_verify.zig").arm(self, target, creating and command.flag("--head", "-H") == null) catch return .{ .text = "PR publication preflight: could not persist the CI verification obligation; write NOT performed", .is_error = true };
    return null;
}

fn headStatus(self: *Agent, target: @import("pr_evidence.zig").Target, head: []const u8) pr_publish.HeadStatus {
    const json = @import("pr_evidence.zig").capture(self.gpa, self.io, self.arena, target, &.{ "gh", "run", "list", "--commit", head, "--json", "conclusion,status", "--limit", "1000" }) catch return .unknown;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, json, .{}) catch return .unknown;
    if (parsed == .array and parsed.array.items.len >= 1000) return .unknown;
    return pr_publish.headStatusFromRunList(json);
}

const PendingPoll = struct {
    agent: *Agent,
    target: @import("pr_evidence.zig").Target,
    creating: bool,
    alternate_head: ?[]const u8,
    initial: pr_publish.Evidence,
    started: std.Io.Timestamp,

    fn expired(self: *PendingPoll) bool {
        return self.started.untilNow(self.agent.io, .awake).toMilliseconds() >= 60_000;
    }
    fn cancelled(self: *PendingPoll) bool {
        return Agent.esc_cancel.load(.acquire) or if (self.agent.loop_deadline_ms) |deadline| @import("util.zig").unixMs(self.agent.io) >= deadline else false;
    }
    fn pause(self: *PendingPoll) !void {
        for (0..8) |_| {
            if (self.cancelled()) return error.Interrupted;
            if (self.expired()) return;
            try self.agent.io.sleep(.fromMilliseconds(250), .awake);
        }
    }
    fn read(self: *PendingPoll) !pr_publish.Evidence {
        const ev = @import("pr_evidence.zig");
        const a = self.agent;
        if (!self.creating) {
            const latest = try ev.pr(a.gpa, a.io, a.arena, self.target);
            return .{ .head_sha = latest.head, .head_status = latest.status, .body = latest.body };
        }
        const status = headStatus(a, self.target, self.initial.head_sha);
        const current = if (self.alternate_head) |branch|
            try ev.remoteHead(a.gpa, a.io, a.arena, self.target, branch)
        else
            try ev.localHead(a.gpa, a.io, a.arena, self.target);
        return .{ .head_sha = current, .head_status = status, .body = self.initial.body };
    }
};

// The poller is injectable so expiry, cancellation and head changes are tested
// without delaying the unit suite. Missing runs after a pending sample are not
// proof of completion; only an observed terminal result resolves that wait.
fn waitPending(poll: anytype, initial: pr_publish.Evidence) !pr_publish.Evidence {
    var current = initial;
    while (current.head_status == .pending) {
        if (poll.cancelled()) return error.Interrupted;
        if (poll.expired()) return current;
        try poll.pause();
        if (poll.cancelled()) return error.Interrupted;
        if (poll.expired()) return current;
        current = try poll.read();
        if (poll.cancelled()) return error.Interrupted;
        if (!std.mem.eql(u8, initial.head_sha, current.head_sha)) return error.HeadChanged;
        if (current.head_status == .none) current.head_status = .unknown;
    }
    return current;
}

test "pending publication waits for exact-head terminal evidence and fails closed" {
    const Poll = struct {
        samples: []const pr_publish.Evidence,
        at: usize = 0,
        stop: bool = false,
        elapsed: bool = false,
        fn expired(self: *@This()) bool {
            return self.elapsed;
        }
        fn cancelled(self: *@This()) bool {
            return self.stop;
        }
        fn pause(_: *@This()) !void {}
        fn read(self: *@This()) !pr_publish.Evidence {
            const result = self.samples[self.at];
            self.at += 1;
            return result;
        }
    };
    const initial: pr_publish.Evidence = .{ .head_sha = "a", .head_status = .pending };
    for ([_]pr_publish.HeadStatus{ .passed, .failed, .unknown, .none }) |status| {
        const samples = [_]pr_publish.Evidence{ initial, .{ .head_sha = "a", .head_status = status } };
        var poll: Poll = .{ .samples = &samples };
        try std.testing.expectEqual(if (status == .none) pr_publish.HeadStatus.unknown else status, (try waitPending(&poll, initial)).head_status);
        try std.testing.expectEqual(@as(usize, 2), poll.at);
    }
    var moved: Poll = .{ .samples = &.{.{ .head_sha = "b", .head_status = .passed }} };
    try std.testing.expectError(error.HeadChanged, waitPending(&moved, initial));
    var stopped: Poll = .{ .samples = &.{}, .stop = true };
    try std.testing.expectError(error.Interrupted, waitPending(&stopped, initial));
    var expired: Poll = .{ .samples = &.{}, .elapsed = true };
    try std.testing.expectEqual(pr_publish.HeadStatus.pending, (try waitPending(&expired, initial)).head_status);
    try std.testing.expectEqual(@as(usize, 0), expired.at);
}

pub fn bash(self: *Agent, cmd: []const u8) !?ExecResult {
    const key = if (builtin.is_test) "" else mutationKey(self, cmd);
    if (artifact_claim.gateCommandIn(self.arena, self.io, cmd, key, self.agent_cwd orelse ".")) |blocked| return .{ .text = blocked, .is_error = true };
    if (!pr_publish.isPrCreate(cmd) and !pr_publish.isPrReady(cmd)) return null;
    if (!builtin.is_test) return observe(self, cmd);
    if (pr_publish.gateCommand(self.arena, cmd)) |blocked| return .{ .text = blocked, .is_error = true };
    return null;
}

fn mutationKey(self: *Agent, cmd: []const u8) []const u8 {
    if (!artifact_claim.isClaimedMutation(cmd)) return "";
    // Interpolation and globbing do not establish a comparable branch target.
    // Compound `;&|` still resolves via cwd or `git -C` (#1014).
    if (std.mem.indexOfAny(u8, cmd, "`$\"'\\*?{}") != null or
        std.mem.indexOf(u8, cmd, " -R") != null or std.mem.indexOf(u8, cmd, " --repo") != null) return "";
    const ev = @import("pr_evidence.zig");
    const c = @import("pr_command.zig").parse(self.arena, cmd) catch null;
    if (c) |command| {
        if (command.flag("--head", "-H")) |head| return head;
        if (!std.mem.eql(u8, command.verb, "create") and command.selector() != null) return "";
    }
    const git_c = @import("artifact_claim_command.zig").gitWorkDir(cmd);
    const cwd = git_c orelse if (c) |command| command.cwd orelse self.agent_cwd orelse "." else self.agent_cwd orelse ".";
    return ev.capture(self.gpa, self.io, self.arena, .{ .cwd = cwd, .selector = "" }, &.{ "git", "branch", "--show-current" }) catch "";
}

/// Recheck at the common bash execution boundary, including RLM host calls.
/// A permission checkpoint earlier in the turn is not a fresh handoff check.
pub fn beforeExec(ctx: tools_mod.ToolCtx, cmd: []const u8) !?tools_mod.ToolOutput {
    if (builtin.is_test) return null;
    if (!artifact_claim.isClaimedMutation(cmd)) return null;
    var scratch = std.heap.ArenaAllocator.init(ctx.gpa);
    defer scratch.deinit();
    var agent: Agent = .{ .gpa = ctx.gpa, .arena = scratch.allocator(), .io = ctx.io, .client = ctx.client, .provider = ctx.provider, .messages = undefined, .sub = ctx.from_sub, .label = "", .out = null, .agent_cwd = ctx.agent_cwd, .run_budget = ctx.run_budget, .depth = ctx.depth, .tracer = ctx.tracer, .publication_checks = if (ctx.publication_observer) |observer| try observer.state.snapshot(scratch.allocator(), ctx.io) else ctx.publication_checks, .loop_deadline_ms = ctx.loop_deadline_ms };
    if (try bash(&agent, cmd)) |denied| return .{ .text = try ctx.gpa.dupe(u8, denied.text), .is_error = true, .cancelled = denied.cancelled };
    return null;
}

test "#840 conflicting gh pr create never reaches execution after an acknowledged handoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    pr_publish.clearTestEvidence();
    artifact_claim.setTestOwner(.{ .session = "s-owner", .pid = 1, .start_id = 1 });
    _ = try artifact_claim.handleTool(ar, std.testing.io, "claim", "publication", "", "");
    artifact_claim.setTestOwner(.{ .session = "s-other", .pid = 2, .start_id = 2 });
    artifact_claim.setTestOwnerLive(true);
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = std.testing.io;
    const denied = (try bash(&agent, "gh pr create --title x --body '## Verification\\nzig build test'")).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "NOT performed") != null);
}

test "#879 read-only heredoc with publication text bypasses the claim gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setTestOwner(.{ .session = "s-owner", .pid = 1, .start_id = 1 });
    _ = try artifact_claim.handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    artifact_claim.setTestOwner(.{ .session = "s-reader", .pid = 2, .start_id = 2 });
    artifact_claim.setTestOwnerLive(true);
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = std.testing.io;
    const probe = "python3 - <<'PY'\nneedle = 'gh pr create --title x'\nprint(needle)\nPY";
    try std.testing.expect(try bash(&agent, probe) == null);
}

test "#840 warm dispatch observes late claims, lock contention and corrupt storage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    const path = "zig-cache/claim-dispatch-840.json";
    const lock_path = path ++ ".lock";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setPersistPath(path);
    artifact_claim.setTestOwner(.{ .session = "reader" });
    _ = try artifact_claim.handleTool(ar, io, "status", "publication", "feat/a", "");
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = io;
    // A separate writer's persisted state, without resetting the warm reader.
    const foreign = "[{\"kind\":\"branch\",\"key\":\"feat/a\",\"session\":\"writer\",\"pid\":1,\"start_id\":0}]";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = foreign });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh pr list") == null);
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/b") == null);
    for ([_][]const u8{
        "gh issue list && gh pr create --draft --head feat/a",
        "gh issue list; gh pr create --draft --head feat/a",
        "gh issue list\ngh pr create --draft --head feat/a",
    }) |cmd| try std.testing.expect((try bash(&agent, cmd)).?.is_error);
    const held = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    const blocked = try artifact_claim.handleTool(ar, io, "claim", "issue", "841", "");
    try std.testing.expect(blocked.is_error);
    held.close(io);
    const unchanged = try std.Io.Dir.cwd().readFileAlloc(io, path, ar, .limited(4096));
    try std.testing.expectEqualStrings(foreign, unchanged);
    var transferred: artifact_claim.Ledger = .{};
    try artifact_claim.loadJson(ar, &transferred, foreign);
    _ = try artifact_claim.handoff(&transferred, ar, .branch, "feat/a", .{ .session = "writer", .pid = 1 }, .{ .session = "reader" }, 0, true);
    try @import("credential_store.zig").replaceFile(io, std.Io.Dir.cwd(), path, try artifact_claim.persistJson(ar, &transferred), .default_file);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/a") == null);
    artifact_claim.setTestOwner(.{ .session = "writer", .pid = 1 });
    try std.testing.expect((try bash(&agent, "gh pr create --draft --head feat/a")).?.is_error);
    _ = try artifact_claim.handleTool(ar, io, "claim", "issue", "840", "");
    artifact_claim.setTestOwner(.{ .session = "reader" });
    try std.testing.expect((try bash(&agent, "gh issue edit 840 --title x")).?.is_error);
    try std.testing.expect(try bash(&agent, "gh issue edit 841 --title x") == null);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "not json" });
    try std.testing.expect((try bash(&agent, "gh pr create --draft")).?.is_error);
    try std.testing.expect((try artifact_claim.handleTool(ar, io, "claim", "issue", "841", "")).is_error);
}

test "#840 publication branch keys are not compared with PR numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    artifact_claim.setTestOwner(.{ .session = "owner" });
    _ = try artifact_claim.handleTool(arena.allocator(), std.testing.io, "claim", "publication", "feat/a", "");
    artifact_claim.setTestOwner(.{ .session = "reader" });
    var agent: Agent = undefined;
    agent.arena = arena.allocator();
    agent.io = std.testing.io;
    try std.testing.expect(try bash(&agent, "gh pr edit 123 --title x") == null);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --head feat/b") == null);
}

test "#847 non-draft create with failed head is stopped before bash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    artifact_claim.resetForTest();
    defer artifact_claim.resetForTest();
    pr_publish.setTestEvidence(.{
        .head_sha = "deadbeef",
        .head_status = .failed,
        .body = "## Verification\nzig build test",
    });
    defer pr_publish.clearTestEvidence();
    var agent: Agent = undefined;
    agent.arena = ar;
    agent.io = std.testing.io;
    const denied = (try bash(&agent, "gh pr create --title t --body '## Verification\\nzig build test'")).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "preflight") != null);
    try std.testing.expect(try bash(&agent, "gh pr checks --watch") == null);
    try std.testing.expect(try bash(&agent, "gh pr create --draft --title t --body '## Verification\\nzig build test'") == null);
}
