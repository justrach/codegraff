//! Formatter selection and bounded argv execution. The caller holds the file
//! mutation lock and has already verified the write. Formatter failures restore
//! the verified pre-format bytes, never the pre-edit snapshot.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const registry = @import("formatters.zig");
const policy = @import("harness_policy.zig");
const process = @import("process_runner.zig");

pub const Result = struct {
    bytes: ?[]u8 = null,
    name: []const u8 = "",
    status: enum { skipped, formatted, failed, timed_out, output_limit, unavailable, unsafe_path } = .skipped,
    failed_restore: bool = false,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self.bytes) |bytes| gpa.free(bytes);
    }
    pub fn appendNote(self: Result, gpa: Allocator, base: []u8) ![]u8 {
        const suffix: []const u8 = if (self.failed_restore) "failed; final bytes unknown" else switch (self.status) {
            .skipped => return base,
            .formatted => "formatted",
            .failed => "failed; verified edit kept",
            .timed_out => "timed out; verified edit kept",
            .output_limit => "output limit exceeded; verified edit kept",
            .unavailable => "unavailable; verified edit kept",
            .unsafe_path => "refused unsafe path",
        };
        const text = try std.fmt.allocPrint(gpa, "{s}; formatter {s}: {s}{s}", .{ base, self.name, suffix, if (self.failed_restore) "; RESTORE FAILED — read_file before continuing" else "" });
        gpa.free(base);
        return text;
    }
};

pub const Selection = struct { formatter: registry.Formatter, cwd: []const u8, executable: []const u8 };

fn beneath(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and (std.mem.endsWith(u8, root, "/") or std.mem.endsWith(u8, root, "\\") or (path.len > root.len and (path[root.len] == '/' or path[root.len] == '\\'))));
}

/// Canonical paths only. Reject dangling, escaping and non-regular entries.
fn safeFile(io: Io, arena: Allocator, root: []const u8, path: []const u8) ?[]const u8 {
    const canonical = Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch return null;
    if (!beneath(canonical, root)) return null;
    const stat = Io.Dir.cwd().statFile(io, canonical, .{}) catch return null;
    if (stat.kind != .file) return null;
    return canonical;
}

/// The target gets exactly the scope already authorized by the native tool.
/// Extra roots never contribute settings, only a formatter cwd/detection bound.
fn toolRoot(io: Io, arena: Allocator, agent_cwd: ?[]const u8, path: []const u8) ?[]const u8 {
    var root = agent_cwd orelse ".";
    if (std.fs.path.isAbsolute(path)) {
        root = "";
        for (@import("workspace_roots.zig").items()) |extra| if (beneath(path, extra) and extra.len > root.len) {
            root = extra;
        };
        if (root.len == 0) return null;
    }
    return Io.Dir.cwd().realPathFileAlloc(io, root, arena) catch null;
}

fn projectDir(io: Io, arena: Allocator, f: registry.Formatter, root: []const u8, file: []const u8) ?[]const u8 {
    if (f.detect.len == 0 and !f.local_binary) return root;
    var dir = std.fs.path.dirname(file) orelse return null;
    while (beneath(dir, root)) {
        var detected = f.detect.len == 0;
        for (f.detect) |marker| {
            if (!policy.confinedPath(marker) or std.fs.path.isAbsolute(marker)) continue;
            const full = std.fs.path.join(arena, &.{ dir, marker }) catch return null;
            if (safeFile(io, arena, root, full) != null) {
                detected = true;
                break;
            }
        }
        if (detected) {
            if (!f.local_binary) return dir;
            const bin = std.fs.path.join(arena, &.{ dir, f.command[0] }) catch return null;
            if (safeFile(io, arena, root, bin) != null) return dir;
        }
        if (std.mem.eql(u8, dir, root)) break;
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return null;
}

/// One formatter per mutation: custom entries in settings order first, then
/// enabled built-ins in stable registry order. Missing built-ins are skipped.
pub fn select(reg: registry.Registry, io: Io, arena: Allocator, root: []const u8, file: []const u8) ?Selection {
    for ([_]bool{ true, false }) |custom| {
        for (reg.entries) |f| {
            if (f.custom != custom or !registry.matches(f, file) or f.command.len == 0) continue;
            const cwd = projectDir(io, arena, f, root, file) orelse continue;
            var executable = f.command[0];
            if (std.mem.indexOfAny(u8, executable, "/\\") != null and !std.fs.path.isAbsolute(executable)) {
                if (!policy.confinedPath(executable)) continue;
                const full = std.fs.path.join(arena, &.{ cwd, executable }) catch continue;
                executable = safeFile(io, arena, root, full) orelse continue;
            } else if (!f.custom) {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const found = @import("path_lookup.zig").resolve(io, reg.path_env, executable, &buf) orelse continue;
                // Avoid making a relative PATH entry relative to the child's cwd.
                executable = Io.Dir.cwd().realPathFileAlloc(io, found, arena) catch continue;
            }
            return .{ .formatter = f, .cwd = cwd, .executable = executable };
        }
    }
    return null;
}

pub fn run(reg: registry.Registry, gpa: Allocator, io: Io, agent_cwd: ?[]const u8, path: []const u8, resolved: []const u8) !Result {
    if (reg.entries.len == 0) return .{}; // off: no allocation, stat, or spawn
    var matching = false;
    for (reg.entries) |f| if (registry.matches(f, path)) {
        matching = true;
        break;
    };
    if (!matching) return .{};
    if (!policy.confinedPath(path) or !policy.noSymlinkEscape(io, path, agent_cwd) or policy.protectsGitMetadata(path) or policy.symlinkEntersGitMetadata(io, path, agent_cwd)) return .{ .status = .unsafe_path, .failed_restore = true };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = toolRoot(io, arena, agent_cwd, path) orelse return .{ .status = .unsafe_path, .failed_restore = true };
    const target = safeFile(io, arena, root, resolved) orelse return .{ .status = .unsafe_path, .failed_restore = true };
    const selection = select(reg, io, arena, root, target) orelse return .{};
    const f = selection.formatter;
    const before = Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(registry.file_cap)) catch return .{ .name = f.name, .status = .unavailable };
    errdefer gpa.free(before);
    const stat = try Io.Dir.cwd().statFile(io, target, .{});
    var argv: std.ArrayList([]const u8) = .empty;
    var has_file = false;
    for (f.command, 0..) |arg, i| {
        const is_file = std.mem.eql(u8, arg, "{file}");
        has_file = has_file or is_file;
        try argv.append(arena, if (i == 0) selection.executable else if (is_file) target else arg);
    }
    if (!has_file) try argv.append(arena, target);
    var result: Result = .{ .name = f.name, .bytes = before };
    // rustup proxies must not install a project-pinned toolchain implicitly.
    var formatter_env: ?std.process.Environ.Map = null;
    if (@import("tool_env.zig").get()) |parent| {
        formatter_env = try parent.clone(arena);
        try formatter_env.?.put("RUSTUP_AUTO_INSTALL", "0");
    } else if (std.mem.eql(u8, f.name, "rustfmt")) {
        result.status = .unavailable;
        return result;
    }
    const outcome = process.runCappedWithOptions(gpa, io, argv.items, registry.output_cap, registry.output_cap, @min(@max(f.timeout_ms, 1), registry.max_timeout_ms), .{
        .cwd = .{ .path = selection.cwd },
        .environ_map = if (formatter_env) |*env| env else @import("tool_env.zig").get(),
        .kill_process_tree = true,
    });
    if (outcome) |capture| {
        defer gpa.free(capture.stdout);
        defer gpa.free(capture.stderr);
        result.status = if (capture.timed_out) .timed_out else if (capture.stdout_truncated or capture.stderr_truncated) .output_limit else if (process.ranOk(capture)) .formatted else .failed;
    } else |_| result.status = .unavailable;

    // Re-check before reading/chmod/restoring; never follow a formatter-created
    // escaping symlink. Like native file tools, this is not a race-proof sandbox.
    const relative_target = std.mem.trimStart(u8, target[root.len..], "/\\");
    const now = Io.Dir.cwd().realPathFileAlloc(io, resolved, arena) catch null;
    const same_target = if (now) |canonical| std.mem.eql(u8, target, canonical) else true;
    const safe = same_target and policy.noSymlinkEscape(io, path, agent_cwd) and !policy.symlinkEntersGitMetadata(io, path, agent_cwd) and policy.noSymlinkEscape(io, relative_target, root) and !policy.symlinkEntersGitMetadata(io, relative_target, root);
    if (!safe) {
        result.status = .unsafe_path;
        result.failed_restore = true;
        return result;
    }
    if (result.status == .formatted) {
        if (Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(registry.file_cap))) |after| {
            gpa.free(before);
            result.bytes = after;
        } else |_| result.status = .failed;
    }
    if (result.status != .formatted) {
        @import("credential_store.zig").replaceFile(io, Io.Dir.cwd(), target, before, stat.permissions) catch {
            result.failed_restore = true;
        };
    }
    const file = Io.Dir.cwd().openFile(io, target, .{ .mode = .read_write }) catch return result;
    defer file.close(io);
    file.setPermissions(io, stat.permissions) catch {};
    return result;
}
