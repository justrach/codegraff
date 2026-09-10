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
const process_runner = @import("process_runner.zig");

fn primeHead(self: *Agent) void {
    if (builtin.is_test or pr_publish.testEvidence() != null) return;
    const sha_run = process_runner.runCapped(self.gpa, self.io, &.{ "git", "rev-parse", "HEAD" }, 128, 256, 5_000) catch return;
    defer self.gpa.free(sha_run.stdout);
    defer self.gpa.free(sha_run.stderr);
    if (!process_runner.ranOk(sha_run)) return;
    const sha = std.mem.trim(u8, sha_run.stdout, " \t\r\n");
    if (sha.len < 7) return;
    const sha_owned = self.arena.dupe(u8, sha) catch return;
    const list_run = process_runner.runCapped(self.gpa, self.io, &.{
        "gh",                "run",     "list",
        "--commit",          sha_owned, "--json",
        "conclusion,status", "--limit", "20",
    }, 16 * 1024, 1024, 15_000) catch {
        pr_publish.setTestEvidence(.{ .head_sha = sha_owned, .head_status = .none });
        return;
    };
    defer self.gpa.free(list_run.stdout);
    defer self.gpa.free(list_run.stderr);
    const status = if (process_runner.ranOk(list_run)) pr_publish.headStatusFromRunList(list_run.stdout) else .none;
    pr_publish.setTestEvidence(.{ .head_sha = sha_owned, .head_status = status });
}

pub fn bash(self: *Agent, cmd: []const u8) !?ExecResult {
    if (artifact_claim.gateCommand(self.arena, self.io, cmd, "")) |blocked| return .{
        .text = blocked,
        .is_error = true,
    };
    if (!builtin.is_test and (pr_publish.isPrCreate(cmd) or pr_publish.isPrReady(cmd))) primeHead(self);
    if (pr_publish.gateCommand(self.arena, cmd)) |blocked| return .{
        .text = blocked,
        .is_error = true,
    };
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
