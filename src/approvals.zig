//! Command / tool approval gate + path-confinement helpers. Split out of
//! main.zig (#123). A pure std leaf: no back-import of main, no ansi/util. The
//! tool-exec gate and anim.zig reach it via main's `pub const Approvals =
//! approvals.Approvals;` re-export (plus the two `confinedPath`/`noSymlinkEscape`
//! aliases), so every existing call site resolves unchanged.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Shared approval state: a yolo flag plus a list of user-approved keys
/// (command first-words for bash, exact tool names for write_file/edit_file/
/// MCP). The root agent prompts on misses and appends under the mutex;
/// subagent pool threads only read. Commands with shell metacharacters
/// (chaining, pipes, redirection, substitution, newlines) never match a
/// prefix — they always prompt at the root and are denied in subagents.
pub const Approvals = struct {
    mutex: Io.Mutex = .init,
    prefixes: std.ArrayList([]const u8) = .empty,
    /// Session-only (never persisted) path roots the user OK'd for read-only
    /// plan-mode exploration outside cwd (#64); freed alongside prefixes.
    plan_read_roots: std.ArrayList([]const u8) = .empty,
    yolo: bool = false,

    /// Read-only basics plus the build, so subagents are useful out of the
    /// box. Deliberately excludes `find` (its -exec/-delete make it an exec
    /// tool, not read-only) — it falls through to a prompt at the root and is
    /// denied for subagents. `rg`/`grep` keep their exotic --pre vector and
    /// `zig build` runs build.zig; both are accepted for a self-hosting
    /// coding harness, so don't seed-allow untrusted-input scenarios.
    const seed = [_][]const u8{
        "ls",      "cat",      "head",       "tail",
        "wc",      "grep",     "rg",         "pwd",
        "which",   "file",     "git status", "git diff",
        "git log", "git show", "zig build",  "zig fmt",
    };

    /// Verbs that only ever read — a strict subset of `seed`, used to decide what
    /// plan mode may run OUTSIDE cwd. `zig build`/`zig fmt` are omitted (they run
    /// build.zig / rewrite files) so the external-read hatch can never mutate a
    /// sibling repo (#64).
    const read_only_seed = [_][]const u8{
        "ls",  "cat",   "head", "tail",       "wc",       "grep",    "rg",
        "pwd", "which", "file", "git status", "git diff", "git log", "git show",
    };

    pub fn allowed(self: *Approvals, io: Io, cmd: []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.yolo) return true;
        if (!isSimple(c)) return false;
        // Auto-allow only when every path argument stays in the cwd subtree;
        // a command touching outside (e.g. `cat /etc/passwd`) falls through to
        // a prompt at the root and is denied for subagents. Explicit per-call
        // approval or /yolo is still the escape hatch.
        if (escapesCwd(c)) return false;
        for (seed) |p| if (matchesPrefix(c, p)) return true;
        for (self.prefixes.items) |p| if (matchesPrefix(c, p)) return true;
        return false;
    }

    /// Exact-match gate for non-command tools (write_file, edit_file, MCP):
    /// the approval key is the tool name itself, not a command prefix.
    pub fn allowedExact(self: *Approvals, io: Io, name: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.yolo) return true;
        for (self.prefixes.items) |p| if (std.mem.eql(u8, p, name)) return true;
        return false;
    }

    pub const settings_dir = ".harness";
    pub const settings_path = ".harness/settings.json";

    /// "Always allow" appends the key and persists the allow-list to the
    /// project's .harness/settings.json, so approvals survive restarts.
    pub fn approve(self: *Approvals, io: Io, gpa: Allocator, key: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.prefixes.append(gpa, try gpa.dupe(u8, key));
        _ = self.savePersisted(io, gpa);
    }

    /// Load persisted allow-rules ({"allow": ["git push", "write_file", …]})
    /// from .harness/settings.json into the session list. Returns the count.
    pub fn loadPersisted(self: *Approvals, io: Io, gpa: Allocator, arena: Allocator) usize {
        const data = Io.Dir.cwd().readFileAlloc(io, settings_path, arena, .limited(1 << 20)) catch return 0;
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return 0;
        if (v != .object) return 0;
        const allow = v.object.get("allow") orelse return 0;
        if (allow != .array) return 0;
        var n: usize = 0;
        for (allow.array.items) |item| {
            if (item != .string or item.string.len == 0) continue;
            self.prefixes.append(gpa, gpa.dupe(u8, item.string) catch continue) catch continue;
            n += 1;
        }
        return n;
    }

    /// Best-effort write of the allow-list back to .harness/settings.json,
    /// preserving every other key in the file (hooks live there too — a
    /// mid-session "always allow" must not clobber them). Caller holds the
    /// mutex.
    fn savePersisted(self: *Approvals, io: Io, gpa: Allocator) bool {
        Io.Dir.cwd().createDir(io, settings_dir, .default_dir) catch {}; // already-exists is fine
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // Start from the existing object (or empty) and swap in "allow".
        var root_obj: std.json.ObjectMap = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, settings_path, a, .limited(1 << 20))) |data| {
            if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
                if (v == .object) root_obj = v.object;
            } else |_| {}
        } else |_| {}
        var allow_arr = std.json.Array.init(a);
        for (self.prefixes.items) |p| allow_arr.append(.{ .string = p }) catch return false;
        root_obj.put(a, "allow", .{ .array = allow_arr }) catch return false;
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
        s.write(Value{ .object = root_obj }) catch return false;
        const f = Io.Dir.cwd().createFile(io, settings_path, .{}) catch return false;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = f.writer(io, &wbuf);
        fw.interface.writeAll(aw.writer.buffered()) catch return false;
        fw.interface.writeAll("\n") catch return false;
        fw.interface.flush() catch return false;
        return true;
    }

    /// True when the command clears the read-only seed allowlist alone —
    /// the only bash plan mode lets through (user approvals may be mutating).
    pub fn readOnlyAllowed(cmd: []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        if (!isSimple(c) or escapesCwd(c)) return false;
        for (seed) |p| if (matchesPrefix(c, p)) return true;
        return false;
    }

    fn isReadOnlyVerb(cmd: []const u8) bool {
        for (read_only_seed) |p| if (matchesPrefix(cmd, p)) return true;
        return false;
    }

    /// A simple read-only-verb command that reads OUTSIDE cwd — the sibling-repo
    /// exploration case. readOnlyAllowed handles the in-cwd case; plan mode
    /// prompts on this instead of hard-denying. Mutating verbs and metacharacter
    /// smuggling are NOT read-only-external (#64).
    pub fn readOnlyExternal(cmd: []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        return isSimple(c) and escapesCwd(c) and isReadOnlyVerb(c);
    }

    /// The escaping path a token carries, or null if it stays in cwd. Mirrors
    /// escapesCwd's token classification exactly so cwd tokens are skipped.
    fn flaggedPath(tok: []const u8) ?[]const u8 {
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
    fn pathUnderRoots(path: []const u8, roots: []const []const u8) bool {
        var pit = std.mem.tokenizeScalar(u8, path, '/');
        while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) return false;
        for (roots) |root| {
            if (root.len == 0 or !std.mem.startsWith(u8, path, root)) continue;
            if (path.len == root.len or path[root.len] == '/') return true;
        }
        return false;
    }

    /// Pure core of planReadAllowed: a simple read-only-verb command whose every
    /// escaping token sits under an approved root.
    fn planReadMatch(cmd: []const u8, roots: []const []const u8) bool {
        const c = std.mem.trim(u8, cmd, " \t");
        if (!isSimple(c) or !isReadOnlyVerb(c)) return false;
        var it = std.mem.tokenizeAny(u8, c, " \t");
        while (it.next()) |tok| {
            const p = flaggedPath(tok) orelse continue;
            if (!pathUnderRoots(p, roots)) return false;
        }
        return true;
    }

    /// Plan mode: whether `cmd` is a read-only command cleared to run outside cwd
    /// by a session approval. Thread-safe (called from the tool-exec pool).
    pub fn planReadAllowed(self: *Approvals, io: Io, cmd: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.yolo) return true;
        return planReadMatch(cmd, self.plan_read_roots.items);
    }

    /// Record every escaping path in `cmd` as an approved read root for the rest
    /// of the session. Skips `..` tokens (never approvable) and duplicates.
    pub fn approvePlanRead(self: *Approvals, io: Io, gpa: Allocator, cmd: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        outer: while (it.next()) |tok| {
            const p = flaggedPath(tok) orelse continue;
            var pit = std.mem.tokenizeScalar(u8, p, '/');
            while (pit.next()) |comp| if (std.mem.eql(u8, comp, "..")) continue :outer;
            for (self.plan_read_roots.items) |r| if (std.mem.eql(u8, r, p)) continue :outer;
            try self.plan_read_roots.append(gpa, try gpa.dupe(u8, p));
        }
    }

    pub fn toggleYolo(self: *Approvals, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.yolo = !self.yolo;
        return self.yolo;
    }

    pub fn yoloEnabled(self: *Approvals, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.yolo;
    }

    /// No chaining, piping, redirection, or substitution — those can smuggle
    /// a second command past a prefix match.
    fn isSimple(cmd: []const u8) bool {
        for (cmd) |ch| switch (ch) {
            ';', '|', '&', '>', '<', '`', '$', '\n', '\r', '\t', 0 => return false,
            else => {},
        };
        return true;
    }

    fn matchesPrefix(cmd: []const u8, prefix: []const u8) bool {
        if (!std.mem.startsWith(u8, cmd, prefix)) return false;
        return cmd.len == prefix.len or cmd[prefix.len] == ' ';
    }

    /// True if any whitespace-token in the command looks like a path leaving
    /// the working directory: absolute (`/x`, `--f=/x`), home (`~`, `=~`), or
    /// containing a `..` component. A heuristic — metacharacters are already
    /// blocked by isSimple, so args really are space-separated tokens — that
    /// keeps the auto-allowed seed commands (cat, grep, …) reading inside cwd.
    fn escapesCwd(cmd: []const u8) bool {
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

    /// "Always allow"ing one of these as a bash first word grants arbitrary
    /// code execution (e.g. `python3 -c '...'`) — worth a heads-up.
    pub fn isInterpreter(word: []const u8) bool {
        const interps = [_][]const u8{
            "python", "python3", "node", "deno",      "bun", "ruby", "perl",
            "php",    "sh",      "bash", "osascript", "awk",
        };
        for (interps) |i| if (std.mem.eql(u8, word, i)) return true;
        return false;
    }

    /// Git subcommands that can destroy committed or working-tree work — the
    /// user's, or a -w worktree's auto-checkpoints. Codex keeps `.git` read-only
    /// to the agent and opencode forbids `git reset --hard`; we do the same to a
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
    /// everywhere EXCEPT the root agent under --yolo, where the operator
    /// explicitly opted out of prompts and is driving. Subagents never get it.
    pub fn destructiveGitAllowed(yolo: bool, sub: bool) bool {
        return yolo and !sub;
    }
};

test "destructive git gate: only the root agent under --yolo skips the y/n" {
    // The 'yolo fails on destructive git' report: --yolo lets the operator through
    // (they opted out of prompts), but never a subagent and never a non-yolo run.
    try std.testing.expect(Approvals.destructiveGitAllowed(true, false));
    try std.testing.expect(!Approvals.destructiveGitAllowed(true, true));
    try std.testing.expect(!Approvals.destructiveGitAllowed(false, false));
    try std.testing.expect(!Approvals.destructiveGitAllowed(false, true));
    try std.testing.expect(Approvals.isDestructiveGit("git reset --hard origin/main"));
    try std.testing.expect(Approvals.isDestructiveGit("git clean -fd"));
    try std.testing.expect(!Approvals.isDestructiveGit("git status"));
}

/// Path tools (read/write/edit_file) are confined to the working directory:
/// no absolute paths and no `..` components. This keeps `read_file
/// /etc/shadow`, `write_file ../../foo`, and trace/approvals forgery via
/// traversal out of reach for both the root agent and subagents, structurally
/// (it is not bypassed by /yolo — use bash, which is gated, to touch files
/// elsewhere). Returns true when the path is safe.
pub fn confinedPath(path: []const u8) bool {
    if (path.len == 0) return false;
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
test "Approvals.isSimple: rejects shell metacharacters that could smuggle a second command" {
    try std.testing.expect(Approvals.isSimple("grep foo src/main.zig"));
    try std.testing.expect(Approvals.isSimple("ls -la"));
    try std.testing.expect(!Approvals.isSimple("ls; rm -rf /"));
    try std.testing.expect(!Approvals.isSimple("cat a | sh"));
    try std.testing.expect(!Approvals.isSimple("echo $(whoami)"));
    try std.testing.expect(!Approvals.isSimple("echo `id`"));
    try std.testing.expect(!Approvals.isSimple("foo > bar"));
    try std.testing.expect(!Approvals.isSimple("foo < bar"));
    try std.testing.expect(!Approvals.isSimple("a && b"));
    try std.testing.expect(!Approvals.isSimple("a\nb"));
    try std.testing.expect(!Approvals.isSimple("echo $HOME"));
}

test "Approvals.matchesPrefix: whole-word prefix, never a bare substring" {
    try std.testing.expect(Approvals.matchesPrefix("git status", "git status"));
    try std.testing.expect(Approvals.matchesPrefix("git status -s", "git status"));
    try std.testing.expect(Approvals.matchesPrefix("ls", "ls"));
    try std.testing.expect(Approvals.matchesPrefix("ls -la", "ls"));
    try std.testing.expect(!Approvals.matchesPrefix("lsof", "ls")); // not a word boundary
    try std.testing.expect(!Approvals.matchesPrefix("git statusx", "git status"));
    try std.testing.expect(!Approvals.matchesPrefix("git", "git status")); // prefix longer than cmd
}

test "Approvals.escapesCwd: flags tokens that point outside the working directory" {
    try std.testing.expect(!Approvals.escapesCwd("cat src/main.zig"));
    try std.testing.expect(!Approvals.escapesCwd("grep foo ./a/b.zig"));
    try std.testing.expect(!Approvals.escapesCwd("prog --flag=value"));
    try std.testing.expect(Approvals.escapesCwd("cat /etc/passwd"));
    try std.testing.expect(Approvals.escapesCwd("cat ~/secrets"));
    try std.testing.expect(Approvals.escapesCwd("cat ../outside"));
    try std.testing.expect(Approvals.escapesCwd("grep foo a/../../b"));
    try std.testing.expect(Approvals.escapesCwd("prog --file=/abs/path"));
    try std.testing.expect(Approvals.escapesCwd("prog --file=~/x"));
}

test "Approvals.readOnlyAllowed: only simple, in-cwd, seed-listed commands pass in plan mode" {
    try std.testing.expect(Approvals.readOnlyAllowed("ls -la"));
    try std.testing.expect(Approvals.readOnlyAllowed("git status"));
    try std.testing.expect(Approvals.readOnlyAllowed("cat src/main.zig"));
    try std.testing.expect(Approvals.readOnlyAllowed("  grep foo bar  ")); // leading/trailing trimmed
    try std.testing.expect(!Approvals.readOnlyAllowed("rm -rf x")); // not in the seed
    try std.testing.expect(!Approvals.readOnlyAllowed("cat /etc/passwd")); // escapes cwd
    try std.testing.expect(!Approvals.readOnlyAllowed("ls; rm x")); // not simple
    try std.testing.expect(!Approvals.readOnlyAllowed("git push")); // mutating git verb, not seeded
}

test "Approvals.readOnlyExternal: read-only verb reading outside cwd, simple only (#64)" {
    try std.testing.expect(Approvals.readOnlyExternal("ls ~/projects/merjs"));
    try std.testing.expect(Approvals.readOnlyExternal("cat /abs/file"));
    try std.testing.expect(!Approvals.readOnlyExternal("cat src/main.zig")); // in cwd
    try std.testing.expect(!Approvals.readOnlyExternal("rm -rf /x")); // mutating verb
    try std.testing.expect(!Approvals.readOnlyExternal("zig fmt /x.zig")); // not read-only-seeded
    try std.testing.expect(!Approvals.readOnlyExternal("ls /x; rm y")); // not simple
}

test "Approvals.planReadMatch: reads under an approved root pass; escapes/mutations/smuggling do not (#64)" {
    const roots = [_][]const u8{ "~/projects/merjs", "/opt/data" };
    const r: []const []const u8 = &roots;
    try std.testing.expect(Approvals.planReadMatch("ls ~/projects/merjs", r));
    try std.testing.expect(Approvals.planReadMatch("ls ~/projects/merjs/src", r));
    try std.testing.expect(Approvals.planReadMatch("cat ~/projects/merjs/README.md", r));
    try std.testing.expect(Approvals.planReadMatch("grep foo /opt/data/x.txt", r));
    try std.testing.expect(Approvals.planReadMatch("grep foo ~/projects/merjs/a src/b.zig", r)); // cwd token ok alongside
    try std.testing.expect(!Approvals.planReadMatch("cat /etc/passwd", r)); // outside every root
    try std.testing.expect(!Approvals.planReadMatch("ls ~/secrets", r));
    try std.testing.expect(!Approvals.planReadMatch("cat ~/projects/merjs/../../etc/passwd", r)); // .. smuggling
    try std.testing.expect(!Approvals.planReadMatch("rm -rf ~/projects/merjs", r)); // mutating verb
    try std.testing.expect(!Approvals.planReadMatch("ls ~/projects/merjs; rm x", r)); // metachar
    try std.testing.expect(!Approvals.planReadMatch("ls ~/projects/merjs", &.{})); // nothing approved
}

test "Approvals.isInterpreter: flags first words that grant arbitrary code execution" {
    try std.testing.expect(Approvals.isInterpreter("python3"));
    try std.testing.expect(Approvals.isInterpreter("node"));
    try std.testing.expect(Approvals.isInterpreter("bash"));
    try std.testing.expect(Approvals.isInterpreter("osascript"));
    try std.testing.expect(!Approvals.isInterpreter("ls"));
    try std.testing.expect(!Approvals.isInterpreter("git"));
    try std.testing.expect(!Approvals.isInterpreter("python3x"));
}

test "Approvals.isDestructiveGit: flags work-destroying git, lets safe git through" {
    // destructive — must always reach a human, even under --yolo or a `git` allow
    try std.testing.expect(Approvals.isDestructiveGit("git reset --hard HEAD~3"));
    try std.testing.expect(Approvals.isDestructiveGit("git clean -fd"));
    try std.testing.expect(Approvals.isDestructiveGit("git push --force origin main"));
    try std.testing.expect(Approvals.isDestructiveGit("git push -f"));
    try std.testing.expect(Approvals.isDestructiveGit("git branch -D worktree-docs"));
    try std.testing.expect(Approvals.isDestructiveGit("git checkout -- src/main.zig"));
    try std.testing.expect(Approvals.isDestructiveGit("git checkout ."));
    try std.testing.expect(Approvals.isDestructiveGit("git stash clear"));
    try std.testing.expect(Approvals.isDestructiveGit("cd sub && git reset --hard")); // chained
    try std.testing.expect(Approvals.isDestructiveGit("git -C /repo reset --hard")); // -C form
    // safe — the normal auto-allow path is fine
    try std.testing.expect(!Approvals.isDestructiveGit("git status"));
    try std.testing.expect(!Approvals.isDestructiveGit("git commit -m wip"));
    try std.testing.expect(!Approvals.isDestructiveGit("git reset --soft HEAD~1"));
    try std.testing.expect(!Approvals.isDestructiveGit("git checkout main"));
    try std.testing.expect(!Approvals.isDestructiveGit("git branch -d merged-feature"));
    try std.testing.expect(!Approvals.isDestructiveGit("git restore --staged f.txt"));
    try std.testing.expect(!Approvals.isDestructiveGit("ls -la"));
}
test "confinedPath: rejects absolute, empty, and parent-escaping paths" {
    try std.testing.expect(confinedPath("src/main.zig"));
    try std.testing.expect(confinedPath("a/b/c"));
    try std.testing.expect(!confinedPath(""));
    try std.testing.expect(!confinedPath("/etc/passwd"));
    try std.testing.expect(!confinedPath("../outside"));
    try std.testing.expect(!confinedPath("a/../../b"));
}
