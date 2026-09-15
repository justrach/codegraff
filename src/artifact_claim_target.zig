//! Bounded literal targets; unknown shell forms retain conservative checks.
const std = @import("std");
const claims = @import("artifact_claim.zig");

pub const Target = struct { kind: claims.Kind, key: []const u8, repo: ?[]const u8 = null, branch: ?[]const u8 = null, head_repo: ?[]const u8 = null };

fn unqualifiedHead(head: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, head, ':')) |i| head[i + 1 ..] else head;
}

pub fn explicit(cmd: []const u8, kind: claims.Kind) ?Target {
    // Do not infer one target for a compound command.
    if (std.mem.indexOfAny(u8, cmd, ";|&`$\n\"'\\*?{}") != null) return null;
    if (!std.mem.startsWith(u8, cmd, "gh pr ") and !std.mem.startsWith(u8, cmd, "gh issue ")) return null;
    var words = std.mem.tokenizeAny(u8, cmd, " \t\r\"'");
    var previous: []const u8 = "";
    var object = false;
    var action = false;
    while (words.next()) |word| {
        if (std.mem.eql(u8, previous, "--head") or std.mem.eql(u8, previous, "-H")) return .{ .kind = .branch, .key = unqualifiedHead(word) };
        if (std.mem.startsWith(u8, word, "--head=")) return .{ .kind = .branch, .key = unqualifiedHead(word[7..]) };
        if (action) {
            // Branch names and URLs need a fresh PR lookup before comparing
            // them with a numeric claim. Unknown evidence stays conservative.
            if (word.len == 0) return null;
            for (word) |c| if (!std.ascii.isDigit(c)) return null;
            return .{ .kind = kind, .key = word };
        }
        if (object and (std.mem.eql(u8, word, "edit") or std.mem.eql(u8, word, "ready") or std.mem.eql(u8, word, "close") or std.mem.eql(u8, word, "reopen") or std.mem.eql(u8, word, "comment"))) action = true;
        if ((kind == .issue and std.mem.eql(u8, word, "issue")) or (kind == .pull_request and std.mem.eql(u8, word, "pr"))) object = true;
        previous = word;
    }
    return null;
}

/// Only a fully parsed literal PR command may narrow repository ownership.
/// A branch lookup lets publication/branch claims match a numbered PR.
pub fn resolve(a: std.mem.Allocator, io: std.Io, cmd: []const u8, kind: claims.Kind, cwd: []const u8) ?Target {
    const parsed = @import("pr_command.zig").parse(a, cmd) catch return null;
    const work = if (parsed.cwd) |path| std.fs.path.resolve(a, &.{ cwd, path }) catch return null else cwd;
    const selector = parsed.selectorChecked() catch return null;
    if (!std.mem.eql(u8, parsed.verb, "create")) {
        const pr = @import("artifact_repository.zig").pullRequest(a, io, .{
            .cwd = work,
            .repo = parsed.flag("--repo", "-R"),
            .selector = selector orelse "",
        }) orelse return null;
        return .{ .kind = kind, .key = pr.number, .repo = pr.repo, .branch = pr.branch, .head_repo = pr.head_repo };
    }
    const repo = @import("artifact_repository.zig").resolve(a, io, work, parsed.flag("--repo", "-R"));
    if (parsed.flag("--head", "-H")) |head| {
        const branch = unqualifiedHead(head);
        // Fork-qualified create has no observed head repository yet.
        return .{ .kind = .branch, .key = branch, .branch = branch, .repo = if (std.mem.indexOfScalar(u8, head, ':') == null) repo else null };
    }
    return .{ .kind = .branch, .key = "", .repo = repo };
}
