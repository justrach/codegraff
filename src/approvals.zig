//! The command / tool approval SESSION: the mutable allow-list a human grows
//! by answering y/n, the plan-mode read roots, the yolo flag, and the
//! .harness/settings.json persistence around them. Split out of main.zig
//! (#123); the pure half split out again into harness_policy.zig (#429).
//!
//! What stayed here is exactly what a frontend mutates on user consent — which
//! is why the #422 import ratchet bans engine files from reaching this module.
//! What left is the terminal-free policy engine code legitimately needs: the
//! settings-file location, path confinement, and the command classifiers. Every
//! one is re-exported below, so `Approvals.readOnlyAllowed`, the bare
//! `confinedPath`/`noSymlinkEscape` aliases, and main's `pub const Approvals`
//! re-export all resolve unchanged.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const policy = @import("harness_policy.zig");

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

    // The pure, terminal-free half of the gate lives in harness_policy.zig
    // (#429): the seeds, the command classifiers, the settings-file location
    // and the path-confinement rules. Re-exported here — unqualified, so every
    // method body below and every `Approvals.x` call site resolves unchanged.
    pub const seed = policy.seed;
    pub const read_only_seed = policy.read_only_seed;

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

    pub const settings_dir = policy.settings_dir;
    pub const settings_path = policy.settings_path;

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

    pub const readOnlyAllowed = policy.readOnlyAllowed;
    pub const isReadOnlyVerb = policy.isReadOnlyVerb;
    pub const readOnlyExternal = policy.readOnlyExternal;
    pub const flaggedPath = policy.flaggedPath;
    pub const pathUnderRoots = policy.pathUnderRoots;
    pub const planReadMatch = policy.planReadMatch;

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

    pub const isSimple = policy.isSimple;
    pub const matchesPrefix = policy.matchesPrefix;
    pub const escapesCwd = policy.escapesCwd;
    pub const isInterpreter = policy.isInterpreter;
    pub const isDestructiveGit = policy.isDestructiveGit;
    pub const destructiveGitAllowed = policy.destructiveGitAllowed;
};

// The path-confinement pair is re-exported at file level too: exec.zig,
// edit_verify.zig and imagegen.zig alias them straight off this module.
pub const confinedPath = policy.confinedPath;
pub const noSymlinkEscape = policy.noSymlinkEscape;

test "the re-exports really are harness_policy's, not a second implementation" {
    // The classifiers and path rules moved to harness_policy.zig (#429) so
    // engine code can consult them without importing the approval gate. Every
    // decl below is an alias; if one were ever re-implemented here the two
    // copies could drift, and a security predicate that drifts is a hole.
    try std.testing.expectEqual(&policy.readOnlyAllowed, &Approvals.readOnlyAllowed);
    try std.testing.expectEqual(&policy.isDestructiveGit, &Approvals.isDestructiveGit);
    try std.testing.expectEqual(&policy.isInterpreter, &Approvals.isInterpreter);
    try std.testing.expectEqual(&policy.confinedPath, &confinedPath);
    try std.testing.expectEqualStrings(policy.settings_path, Approvals.settings_path);
    try std.testing.expectEqualStrings(policy.settings_dir, Approvals.settings_dir);
}
