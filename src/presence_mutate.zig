//! Shared-tree mutation classifiers for the #469 collision gate.
//! Split out of presence.zig so that file can hold the durable room cursor
//! without crossing the 600-line ceiling.

const std = @import("std");

/// Git subcommands that mutate the index, refs, or working tree — the shared
/// state the #469 collision tore up. Read-only git (status/log/diff) and
/// remote-only git (fetch/push) stay ungated: the checkpoint exists because
/// two sessions edit ONE uncommitted tree, not because git ran.
fn isSharedTreeSubcommand(sub: []const u8) bool {
    const subs = [_][]const u8{
        "add",     "rm",       "mv",           "commit", "reset",
        "restore", "checkout", "switch",       "stash",  "pull",
        "rebase",  "merge",    "cherry-pick",  "revert", "am",
        "apply",   "clean",    "update-index",
    };
    for (subs) |s| if (std.mem.eql(u8, sub, s)) return true;
    return false;
}

/// Whether `cmd` runs an index/tree-mutating git subcommand. Tokenizes on
/// shell separators so `cd x && git add -A` and `sh -c 'git rm y'` classify by
/// the subcommand, and skips git's global options so `git -C repo reset` is
/// seen as `reset`. A quoted "git add" inside an echo string is a known false
/// positive — the cost is one needless checkpoint line, the same trade
/// harness_policy.isDestructiveGit makes for its substring scan.
pub fn isSharedTreeGit(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, "git")) continue;
        while (it.next()) |arg| {
            if (arg[0] == '-') {
                // -C/-c take the NEXT token as their value; skip it too.
                if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "-c")) _ = it.next();
                continue;
            }
            return isSharedTreeSubcommand(arg);
        }
        return false; // a bare `git` mutates nothing
    }
    return false;
}

/// The shell half of the #469 incident vector: `mv` (any form — a rename can
/// disappear a file a peer just wrote) and recursive `rm`. Plain `rm` of one
/// file stays ungated: the checkpoint exists for tree-level disruption, and
/// it fires once per peer regardless, so the odd false positive costs one
/// line, never a workflow.
pub fn isSharedTreeShell(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "mv")) {
            var operands: usize = 0;
            while (it.next()) |arg| {
                if (arg[0] == '-') continue;
                operands += 1;
            }
            if (operands >= 2) return true;
            continue;
        }
        if (std.mem.eql(u8, tok, "rm")) {
            while (it.next()) |arg| {
                if (arg[0] != '-') break;
                if (std.mem.indexOfAny(u8, arg, "rR") != null) return true;
            }
            continue;
        }
    }
    return false;
}

/// Directory a mutating command actually touches, when we can resolve it
/// without a shell. `git -C PATH` wins; a leading `cd PATH` is next.
/// Quoted, globbed, or otherwise ambiguous forms return null so the caller
/// stays conservative and still checkpoints the session worktree (#851).
pub fn mutationTarget(cmd: []const u8) ?[]const u8 {
    if (gitDashC(cmd)) |p| return p;
    return leadingCd(cmd);
}

fn gitDashC(cmd: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, "git")) continue;
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "-C")) return nonemptyPath(it.next() orelse return null);
            if (std.mem.startsWith(u8, arg, "-C") and arg.len > 2) return nonemptyPath(arg[2..]);
            if (arg[0] == '-') {
                if (std.mem.eql(u8, arg, "-c")) _ = it.next();
                continue;
            }
            break;
        }
    }
    return null;
}

fn leadingCd(cmd: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, cmd, " \t");
    if (!std.mem.startsWith(u8, t, "cd")) return null;
    if (t.len < 4 or (t[2] != ' ' and t[2] != '\t')) return null;
    const rest = std.mem.trimStart(u8, t[2..], " \t");
    if (rest.len == 0 or std.mem.indexOfScalar(u8, "-$\"'`", rest[0]) != null) return null;
    var i: usize = 0;
    while (i < rest.len and std.mem.indexOfScalar(u8, " \t;&|", rest[i]) == null) : (i += 1) {}
    return nonemptyPath(rest[0..i]);
}

fn nonemptyPath(p: []const u8) ?[]const u8 {
    if (p.len == 0 or std.mem.indexOfAny(u8, p, "*?{}") != null) return null;
    return p;
}

test "isSharedTreeGit: flags index/tree-mutating git, ignores read-only git" {
    try std.testing.expect(isSharedTreeGit("git add -A"));
    try std.testing.expect(isSharedTreeGit("git commit -m \"wip\""));
    try std.testing.expect(isSharedTreeGit("GIT_EDITOR=true git commit --amend"));
    try std.testing.expect(isSharedTreeGit("git -C /tmp/repo reset HEAD~1"));
    try std.testing.expect(isSharedTreeGit("git -c user.name=x commit"));
    try std.testing.expect(isSharedTreeGit("cd sub && git stash"));
    try std.testing.expect(isSharedTreeGit("sh -c 'git rm -r old/'"));
    try std.testing.expect(isSharedTreeGit("git checkout -- src/"));
    try std.testing.expect(!isSharedTreeGit("git status"));
    try std.testing.expect(!isSharedTreeGit("git log --oneline -5"));
    try std.testing.expect(!isSharedTreeGit("git diff HEAD"));
    try std.testing.expect(!isSharedTreeGit("git push origin main"));
    try std.testing.expect(!isSharedTreeGit("git branch"));
    try std.testing.expect(!isSharedTreeGit("gh issue list"));
    try std.testing.expect(!isSharedTreeGit("git"));
    try std.testing.expect(!isSharedTreeGit("ls src/"));
}

test "isSharedTreeShell: flags mv and recursive rm, leaves everyday commands alone" {
    try std.testing.expect(isSharedTreeShell("mv old/ new/"));
    try std.testing.expect(isSharedTreeShell("mv a.ts b.ts"));
    try std.testing.expect(isSharedTreeShell("mv src/a src/b dest/"));
    try std.testing.expect(isSharedTreeShell("rm -rf node_modules"));
    try std.testing.expect(isSharedTreeShell("rm -r build"));
    try std.testing.expect(isSharedTreeShell("cd x && mv a b"));
    try std.testing.expect(!isSharedTreeShell("rm -f .lock"));
    try std.testing.expect(!isSharedTreeShell("rm one-file.txt"));
    try std.testing.expect(!isSharedTreeShell("mv")); // no operands: a usage error, not a tree event
    try std.testing.expect(!isSharedTreeShell("ls -la"));
    try std.testing.expect(!isSharedTreeShell("echo moved"));
}

test "#851 mutationTarget reads git -C and a leading cd, ignores ambiguous forms" {
    try std.testing.expectEqualStrings("/tmp/wt", mutationTarget("git -C /tmp/wt cherry-pick abc").?);
    try std.testing.expectEqualStrings("/tmp/wt", mutationTarget("git -C/tmp/wt reset HEAD~1").?);
    try std.testing.expectEqualStrings("/tmp/wt", mutationTarget("cd /tmp/wt && git stash").?);
    try std.testing.expectEqualStrings("sub", mutationTarget("cd sub && git commit -m x").?);
    try std.testing.expect(mutationTarget("git cherry-pick abc") == null);
    try std.testing.expect(mutationTarget("git -c user.name=x commit") == null);
    try std.testing.expect(mutationTarget("cd \"$wt\" && git stash") == null);
    try std.testing.expect(mutationTarget("cd /tmp/wt*") == null);
}
