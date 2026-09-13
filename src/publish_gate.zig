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
        if (creating) {
            ev.head_sha = evmod.localHead(self.gpa, self.io, self.arena, target) catch "";
            // An explicit alternate head must be resolved independently of HEAD.
            if (command.flag("--head", "-H")) |head| {
                ev.head_sha = evmod.remoteHead(self.gpa, self.io, self.arena, target, head) catch "";
            }
            if (evmod.validSha(ev.head_sha)) {
                const json = evmod.capture(self.gpa, self.io, self.arena, target, &.{ "gh", "run", "list", "--commit", ev.head_sha, "--json", "conclusion,status", "--limit", "1000" }) catch "";
                ev.head_status = pr_publish.headStatusFromRunList(json);
                // This cap must not silently hide a failing/pending older run.
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, json, .{}) catch .null;
                if (parsed == .array and parsed.array.items.len >= 1000) ev.head_status = .unknown;
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
    if (pr_publish.decide(draft, ev) != .allow) return .{ .text = pr_publish.refuseText(self.arena, cmd, ev), .is_error = true };
    @import("pr_verify.zig").arm(self, target, creating and command.flag("--head", "-H") == null) catch return .{ .text = "PR publication preflight: could not persist the CI verification obligation; write NOT performed", .is_error = true };
    return null;
}

pub fn bash(self: *Agent, cmd: []const u8) !?ExecResult {
    const key = if (builtin.is_test) "" else mutationKey(self, cmd);
    if (artifact_claim.gateCommand(self.arena, self.io, cmd, key)) |blocked| return .{ .text = blocked, .is_error = true };
    if (!pr_publish.isPrCreate(cmd) and !pr_publish.isPrReady(cmd)) return null;
    if (!builtin.is_test) return observe(self, cmd);
    if (pr_publish.gateCommand(self.arena, cmd)) |blocked| return .{ .text = blocked, .is_error = true };
    return null;
}

fn mutationKey(self: *Agent, cmd: []const u8) []const u8 {
    if (!artifact_claim.isClaimedMutation(cmd)) return "";
    const ev = @import("pr_evidence.zig");
    const c = @import("pr_command.zig").parse(self.arena, cmd) catch null;
    if (c) |command| {
        if (command.flag("--head", "-H")) |head| return head;
        if (!std.mem.eql(u8, command.verb, "create") and command.selector() != null) return "";
    }
    const cwd = if (c) |command| command.cwd orelse self.agent_cwd orelse "." else self.agent_cwd orelse ".";
    return ev.capture(self.gpa, self.io, self.arena, .{ .cwd = cwd, .selector = "" }, &.{ "git", "branch", "--show-current" }) catch "";
}

/// Recheck at the common bash execution boundary, including RLM host calls.
/// A permission checkpoint earlier in the turn is not a fresh handoff check.
pub fn beforeExec(ctx: tools_mod.ToolCtx, cmd: []const u8) !?tools_mod.ToolOutput {
    if (builtin.is_test) return null;
    if (!artifact_claim.isClaimedMutation(cmd)) return null;
    var scratch = std.heap.ArenaAllocator.init(ctx.gpa);
    defer scratch.deinit();
    var agent: Agent = .{ .gpa = ctx.gpa, .arena = scratch.allocator(), .io = ctx.io, .client = ctx.client, .provider = ctx.provider, .messages = undefined, .sub = ctx.from_sub, .label = "", .out = null, .agent_cwd = ctx.agent_cwd };
    if (try bash(&agent, cmd)) |denied| return .{ .text = try ctx.gpa.dupe(u8, denied.text), .is_error = true };
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
