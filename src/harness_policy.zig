//! Terminal-free harness policy: where the harness keeps its own config, which
//! paths a model-supplied argument may name, and how a shell command is
//! classified. A pure std leaf — no ansi/term, no main, no I/O beyond the
//! symlink probe.
//!
//! Split out of approvals.zig (#422/#429). approvals.zig keeps what is
//! genuinely the *approval session*: the mutable allow-list, the plan-mode read
//! roots, the yolo flag, and the persistence around them — state a frontend
//! mutates when a human answers a prompt. What lives here is the pure half
//! engine code consults without ever touching that state, and the epic's import
//! ratchet bans engine files from reaching `approvals.zig` precisely because
//! doing so used to be the only way to ask these questions.
//!
//! Every decl is re-exported from `Approvals` (approvals.zig), so existing call
//! sites resolve unchanged — the move+alias pattern from the main.zig split
//! (#123). New engine-side callers should import THIS module directly.

const std = @import("std");
const Io = std.Io;

/// The project-local file the harness owns: approvals, hooks, skills opt-outs,
/// theme/animation choice. One spelling, so every reader and writer agrees.
pub const settings_dir = ".harness";
pub const settings_path = ".harness/settings.json";

/// Read-only basics plus the build, so subagents are useful out of the box.
/// Deliberately excludes `find` (its -exec/-delete make it an exec tool, not
/// read-only) — it falls through to a prompt at the root and is denied for
/// subagents. `rg`/`grep` keep their exotic --pre vector and `zig build` runs
/// build.zig; both are accepted for a self-hosting coding harness, so don't
/// seed-allow untrusted-input scenarios.
pub const seed = [_][]const u8{
    "ls",      "cat",      "head",       "tail",
    "wc",      "grep",     "rg",         "pwd",
    "which",   "file",     "git status", "git diff",
    "git log", "git show", "zig build",  "zig fmt",
};

/// Verbs that only ever read — a strict subset of `seed`, used to decide what
/// plan mode may run OUTSIDE cwd. `zig build`/`zig fmt` are omitted (they run
/// build.zig / rewrite files) so the external-read hatch can never mutate a
/// sibling repo (#64).
pub const read_only_seed = [_][]const u8{
    "ls",  "cat",   "head", "tail",       "wc",       "grep",    "rg",
    "pwd", "which", "file", "git status", "git diff", "git log", "git show",
};

/// No chaining, piping, redirection, or substitution — those can smuggle a
/// second command past a prefix match.
pub fn isSimple(cmd: []const u8) bool {
    for (cmd) |ch| switch (ch) {
        ';', '|', '&', '>', '<', '`', '$', '\n', '\r', '\t', 0 => return false,
        else => {},
    };
    return true;
}

pub fn matchesPrefix(cmd: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, cmd, prefix)) return false;
    return cmd.len == prefix.len or cmd[prefix.len] == ' ';
}

/// True if any whitespace-token in the command looks like a path leaving the
/// working directory: absolute (`/x`, `--f=/x`), home (`~`, `=~`), or
/// containing a `..` component. A heuristic — metacharacters are already
/// blocked by isSimple, so args really are space-separated tokens — that keeps
/// the auto-allowed seed commands (cat, grep, …) reading inside cwd.
pub fn escapesCwd(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (tok[0] == '/' or tok[0] == '~') return true;
        if (std.mem.indexOf(u8, tok, "=/") != null) return true;
        if (std.mem.indexOf(u8, tok, "=~") != null) return true;
        var pit = std.mem.tokenizeScalar(u8, tok, '/');
        while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) return true;
    }
    return false;
}

/// True when the command clears the read-only seed allowlist alone — the only
/// bash plan mode lets through (user approvals may be mutating).
pub fn readOnlyAllowed(cmd: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t");
    if (!isSimple(c) or escapesCwd(c)) return false;
    for (read_only_seed) |p| if (matchesPrefix(c, p)) return true;
    return false;
}

pub fn isReadOnlyVerb(cmd: []const u8) bool {
    for (read_only_seed) |p| if (matchesPrefix(cmd, p)) return true;
    return false;
}

/// A simple read-only-verb command that reads OUTSIDE cwd — the sibling-repo
/// exploration case. readOnlyAllowed handles the in-cwd case; plan mode prompts
/// on this instead of hard-denying. Mutating verbs and metacharacter smuggling
/// are NOT read-only-external (#64).
pub fn readOnlyExternal(cmd: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t");
    return isSimple(c) and escapesCwd(c) and isReadOnlyVerb(c);
}

/// The escaping path a token carries, or null if it stays in cwd. Mirrors
/// escapesCwd's token classification exactly so cwd tokens are skipped.
pub fn flaggedPath(tok: []const u8) ?[]const u8 {
    if (tok.len == 0) return null;
    if (tok[0] == '/' or tok[0] == '~') return tok;
    if (std.mem.indexOf(u8, tok, "=/")) |i| return tok[i + 1 ..];
    if (std.mem.indexOf(u8, tok, "=~")) |i| return tok[i + 1 ..];
    var pit = std.mem.tokenizeScalar(u8, tok, '/');
    while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) return tok;
    return null;
}

/// True if `path` sits at or under one approved root (with a '/' boundary).
/// Any `..` component fails outright — blocks `<root>/../../etc` smuggling.
pub fn pathUnderRoots(path: []const u8, roots: []const []const u8) bool {
    var pit = std.mem.tokenizeScalar(u8, path, '/');
    while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) return false;
    for (roots) |root| {
        if (root.len == 0 or !std.mem.startsWith(u8, path, root)) continue;
        if (path.len == root.len or path[root.len] == '/') return true;
    }
    return false;
}

/// Pure core of Approvals.planReadAllowed: a simple read-only-verb command
/// whose every escaping token sits under an approved root.
pub fn planReadMatch(cmd: []const u8, roots: []const []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t");
    if (!isSimple(c) or !isReadOnlyVerb(c)) return false;
    var it = std.mem.tokenizeAny(u8, c, " \t");
    while (it.next()) |tok| {
        const p = flaggedPath(tok) orelse continue;
        if (!pathUnderRoots(p, roots)) return false;
    }
    return true;
}

/// "Always allow"ing one of these as a bash first word grants arbitrary code
/// execution (e.g. `python3 -c '...'`) — worth a heads-up.
pub fn isInterpreter(word: []const u8) bool {
    const interps = [_][]const u8{
        "python", "python3", "node", "deno",      "bun", "ruby", "perl",
        "php",    "sh",      "bash", "osascript", "awk",
    };
    for (interps) |i| if (std.mem.eql(u8, word, i)) return true;
    return false;
}

/// Git subcommands that can destroy committed or working-tree work — the
/// user's, or a -w worktree's auto-checkpoints. Codex keeps `.git` read-only to
/// the agent and opencode forbids `git reset --hard`; we do the same to a
/// degree: these never auto-run (not under --yolo, not via a blanket `git`
/// allow), so they always reach a human y/n. Scans the whole command so a
/// chained `cd x && git reset --hard` is caught too.
pub fn isDestructiveGit(cmd: []const u8) bool {
    if (std.mem.indexOf(u8, cmd, "git ") == null) return false;
    const pats = [_][]const u8{
        "reset --hard", "clean -f",  "checkout --", "checkout .",
        "push --force", "push -f",   "branch -D",   "stash clear",
        "stash drop",   "restore .",
    };
    for (pats) |p| if (std.mem.indexOf(u8, cmd, p) != null) return true;
    return false;
}

/// Whether a destructive git command may auto-run without a y/n. Gated
/// everywhere EXCEPT the root agent under --yolo, where the operator explicitly
/// opted out of prompts and is driving. Subagents never get it.
pub fn destructiveGitAllowed(yolo: bool, sub: bool) bool {
    return yolo and !sub;
}

/// Path tools (read/write/edit_file) are confined to the working directory:
/// no absolute paths and no `..` components. This keeps `read_file
/// /etc/shadow`, `write_file ../../foo`, and trace/approvals forgery via
/// traversal out of reach for both the root agent and subagents, structurally
/// (it is not bypassed by /yolo — use bash, which is gated, to touch files
/// elsewhere). Returns true when the path is safe.
pub fn confinedPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (@import("workspace_roots.zig").confined(path)) return true;
    if (std.fs.path.isAbsolute(path)) return false;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}

/// Defense-in-depth on top of confinedPath: a confined path with no `..` and no
/// absolute prefix can still escape the cwd through a symlink that points
/// outside (e.g. `evil -> /etc`, then `read_file evil/passwd`). We refuse to
/// traverse symlinks at all: walk each path prefix and
/// reject if any component is a symlink (readLink succeeds). Conservative — a
/// symlink inside the repo becomes unreadable via the file tools — but it makes
/// confinement structural rather than lexical. bash (gated) is unaffected.
/// `base` is the agent's isolated worktree root (#276 P0-1) when its tool
/// calls are pinned there instead of the shared cwd — each checked prefix is
/// then resolved under `base` (an absolute path, so `Io.Dir.cwd()` below is
/// just the dir-fd the readLink call ignores for an absolute sub_path) rather
/// than the process's real cwd, which a worktree-isolated agent never enters.
/// `base == null` (the shared-cwd default) keeps the original behavior exactly.
pub fn noSymlinkEscape(io: Io, path: []const u8, base: ?[]const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var join_buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: usize = 0;
    while (i <= path.len) {
        const slash = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
        const prefix = path[0..slash];
        if (prefix.len > 0) {
            const check_path = if (base) |b|
                std.fmt.bufPrint(&join_buf, "{s}/{s}", .{ b, prefix }) catch return false
            else
                prefix;
            if (Io.Dir.cwd().readLink(io, check_path, &buf)) |_| {
                return false; // this component is a symlink → refuse
            } else |_| {} // not a symlink (or doesn't exist yet) → fine
        }
        if (slash == path.len) break;
        i = slash + 1;
    }
    return true;
}

test "isSimple: rejects shell metacharacters that could smuggle a second command" {
    try std.testing.expect(isSimple("grep foo src/main.zig"));
    try std.testing.expect(isSimple("ls -la"));
    try std.testing.expect(!isSimple("ls; rm -rf /"));
    try std.testing.expect(!isSimple("cat a | sh"));
    try std.testing.expect(!isSimple("echo $(whoami)"));
    try std.testing.expect(!isSimple("echo `id`"));
    try std.testing.expect(!isSimple("foo > bar"));
    try std.testing.expect(!isSimple("foo < bar"));
    try std.testing.expect(!isSimple("a && b"));
    try std.testing.expect(!isSimple("a\nb"));
    try std.testing.expect(!isSimple("echo $HOME"));
}

test "matchesPrefix: whole-word prefix, never a bare substring" {
    try std.testing.expect(matchesPrefix("git status", "git status"));
    try std.testing.expect(matchesPrefix("git status -s", "git status"));
    try std.testing.expect(matchesPrefix("ls", "ls"));
    try std.testing.expect(matchesPrefix("ls -la", "ls"));
    try std.testing.expect(!matchesPrefix("lsof", "ls")); // not a word boundary
    try std.testing.expect(!matchesPrefix("git statusx", "git status"));
    try std.testing.expect(!matchesPrefix("git", "git status")); // prefix longer than cmd
}

test "escapesCwd: flags tokens that point outside the working directory" {
    try std.testing.expect(!escapesCwd("cat src/main.zig"));
    try std.testing.expect(!escapesCwd("grep foo ./a/b.zig"));
    try std.testing.expect(!escapesCwd("prog --flag=value"));
    try std.testing.expect(escapesCwd("cat /etc/passwd"));
    try std.testing.expect(escapesCwd("cat ~/secrets"));
    try std.testing.expect(escapesCwd("cat ../outside"));
    try std.testing.expect(escapesCwd("grep foo a/../../b"));
    try std.testing.expect(escapesCwd("prog --file=/abs/path"));
    try std.testing.expect(escapesCwd("prog --file=~/x"));
}

test "readOnlyAllowed: only simple, in-cwd, seed-listed commands pass in plan mode" {
    try std.testing.expect(readOnlyAllowed("ls -la"));
    try std.testing.expect(readOnlyAllowed("git status"));
    try std.testing.expect(readOnlyAllowed("cat src/main.zig"));
    try std.testing.expect(readOnlyAllowed("  grep foo bar  ")); // leading/trailing trimmed
    try std.testing.expect(!readOnlyAllowed("rm -rf x")); // not in the seed
    try std.testing.expect(!readOnlyAllowed("cat /etc/passwd")); // escapes cwd
    try std.testing.expect(!readOnlyAllowed("ls; rm x")); // not simple
    try std.testing.expect(!readOnlyAllowed("git push")); // mutating git verb, not seeded
    try std.testing.expect(!readOnlyAllowed("zig build")); // build.zig can execute arbitrary code
    try std.testing.expect(!readOnlyAllowed("zig fmt src")); // formatter rewrites files
}

test "readOnlyExternal: read-only verb reading outside cwd, simple only (#64)" {
    try std.testing.expect(readOnlyExternal("ls ~/projects/merjs"));
    try std.testing.expect(readOnlyExternal("cat /abs/file"));
    try std.testing.expect(!readOnlyExternal("cat src/main.zig")); // in cwd
    try std.testing.expect(!readOnlyExternal("rm -rf /x")); // mutating verb
    try std.testing.expect(!readOnlyExternal("zig fmt /x.zig")); // not read-only-seeded
    try std.testing.expect(!readOnlyExternal("ls /x; rm y")); // not simple
}

test "planReadMatch: reads under an approved root pass; escapes/mutations/smuggling do not (#64)" {
    const r: []const []const u8 = &.{ "~/projects/merjs", "/opt/data" };
    try std.testing.expect(planReadMatch("ls ~/projects/merjs", r));
    try std.testing.expect(planReadMatch("ls ~/projects/merjs/src", r));
    try std.testing.expect(planReadMatch("cat ~/projects/merjs/README.md", r));
    try std.testing.expect(planReadMatch("grep foo /opt/data/x.txt", r));
    try std.testing.expect(planReadMatch("grep foo ~/projects/merjs/a src/b.zig", r)); // cwd token ok alongside
    try std.testing.expect(!planReadMatch("cat /etc/passwd", r)); // outside every root
    try std.testing.expect(!planReadMatch("ls ~/secrets", r));
    try std.testing.expect(!planReadMatch("cat ~/projects/merjs/../../etc/passwd", r)); // .. smuggling
    try std.testing.expect(!planReadMatch("rm -rf ~/projects/merjs", r)); // mutating verb
    try std.testing.expect(!planReadMatch("ls ~/projects/merjs; rm x", r)); // metachar
    try std.testing.expect(!planReadMatch("ls ~/projects/merjs", &.{})); // nothing approved
}

test "isInterpreter: flags first words that grant arbitrary code execution" {
    try std.testing.expect(isInterpreter("python3"));
    try std.testing.expect(isInterpreter("node"));
    try std.testing.expect(isInterpreter("bash"));
    try std.testing.expect(isInterpreter("osascript"));
    try std.testing.expect(!isInterpreter("ls"));
    try std.testing.expect(!isInterpreter("git"));
    try std.testing.expect(!isInterpreter("python3x"));
}

test "isDestructiveGit: flags work-destroying git, lets safe git through" {
    try std.testing.expect(isDestructiveGit("git reset --hard HEAD~3"));
    try std.testing.expect(isDestructiveGit("git clean -fd"));
    try std.testing.expect(isDestructiveGit("git push --force origin main"));
    try std.testing.expect(isDestructiveGit("git push -f"));
    try std.testing.expect(isDestructiveGit("git branch -D worktree-docs"));
    try std.testing.expect(isDestructiveGit("git checkout -- src/main.zig"));
    try std.testing.expect(isDestructiveGit("git checkout ."));
    try std.testing.expect(isDestructiveGit("git stash clear"));
    try std.testing.expect(isDestructiveGit("cd sub && git reset --hard")); // chained
    try std.testing.expect(isDestructiveGit("git -C /repo reset --hard")); // -C form

    try std.testing.expect(!isDestructiveGit("git status"));
    try std.testing.expect(!isDestructiveGit("git commit -m wip"));
    try std.testing.expect(!isDestructiveGit("git reset --soft HEAD~1"));
    try std.testing.expect(!isDestructiveGit("git checkout main"));
    try std.testing.expect(!isDestructiveGit("git branch -d merged-feature"));
    try std.testing.expect(!isDestructiveGit("git restore --staged f.txt"));
    try std.testing.expect(!isDestructiveGit("ls -la"));
}

test "destructiveGitAllowed: only the root agent under --yolo skips the y/n" {
    // The 'yolo fails on destructive git' report: --yolo lets the operator
    // through (they opted out of prompts), but never a subagent and never a
    // non-yolo run.
    try std.testing.expect(destructiveGitAllowed(true, false));
    try std.testing.expect(!destructiveGitAllowed(true, true));
    try std.testing.expect(!destructiveGitAllowed(false, false));
    try std.testing.expect(!destructiveGitAllowed(false, true));
}

test "confinedPath: rejects absolute, empty, and parent-escaping paths" {
    try std.testing.expect(confinedPath("src/main.zig"));
    try std.testing.expect(confinedPath("a/b/c"));
    try std.testing.expect(!confinedPath(""));
    try std.testing.expect(!confinedPath("/etc/passwd"));
    try std.testing.expect(!confinedPath("../outside"));
    try std.testing.expect(!confinedPath("a/../../b"));
}

test "the settings file has one spelling, and it lives in the settings dir" {
    // Every reader and writer of the harness's own config resolves through
    // these two constants; a drift between them would split the file in two.
    try std.testing.expect(std.mem.startsWith(u8, settings_path, settings_dir ++ "/"));
    try std.testing.expect(confinedPath(settings_path)); // never escapes the project
}
