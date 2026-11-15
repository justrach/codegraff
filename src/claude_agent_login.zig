//! `graff login claude-agent` (ADR 0309): records that the user chose Claude
//! Agent. The login itself belongs to `claude` (`claude auth login`); graff
//! never reads Claude Code's saved credentials, it only asks `claude auth
//! status` whether a login exists. The marker holds which `claude` to run.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const credential_store = @import("credential_store.zig");

pub const marker_name = "claude-agent.json";

pub fn markerPath(arena: Allocator, home: []const u8) []const u8 {
    return credential_store.graffCredentialPath(arena, home, marker_name);
}

fn off(v: []const u8) bool {
    for ([_][]const u8{ "", "0", "off", "false", "no" }) |o| if (std.ascii.eqlIgnoreCase(v, o)) return true;
    return false;
}

/// The `claude` to run when the user opted in (the marker, or
/// GRAFF_CLAUDE_AGENT=1), else null. GRAFF_CLAUDE_PATH picks the binary.
pub fn enabled(io: Io, arena: Allocator, environ_map: anytype, home: []const u8) ?[]const u8 {
    const exe_env = environ_map.get("GRAFF_CLAUDE_PATH");
    if (environ_map.get("GRAFF_CLAUDE_AGENT")) |v| return if (off(v)) null else exe_env orelse "claude";
    if (home.len == 0) return null;
    const data = Io.Dir.cwd().readFileAlloc(io, markerPath(arena, home), arena, .limited(4096)) catch return null;
    if (exe_env) |e| return e;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return "claude";
    if (v == .object) if (v.object.get("claude")) |c| if (c == .string and c.string.len > 0) return c.string;
    return "claude";
}

pub const Status = struct {
    logged_in: bool,
    method: []const u8 = "",
    plan: []const u8 = "",
    email: []const u8 = "",
    organization: []const u8 = "",
};

pub const Marker = struct {
    claude: []const u8 = "claude",
    email: []const u8 = "",
    organization: []const u8 = "",
    plan: []const u8 = "",
};

pub fn readMarker(io: Io, arena: Allocator, home: []const u8) ?Marker {
    if (home.len == 0) return null;
    const data = Io.Dir.cwd().readFileAlloc(io, markerPath(arena, home), arena, .limited(4096)) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return .{};
    if (v != .object) return .{};
    const util = @import("util.zig");
    return .{
        .claude = if (util.strFieldObj(v.object, "claude")) |c| (if (c.len > 0) c else "claude") else "claude",
        .email = util.strFieldObj(v.object, "email") orelse "",
        .organization = util.strFieldObj(v.object, "organization") orelse "",
        .plan = util.strFieldObj(v.object, "plan") orelse "",
    };
}

pub fn saveMarker(io: Io, arena: Allocator, home: []const u8, m: Marker) !void {
    if (home.len == 0) return;
    const store = @import("credential_store.zig");
    const path = markerPath(arena, home);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "claude", .{ .string = if (m.claude.len > 0) m.claude else "claude" });
    if (m.email.len > 0) try obj.put(arena, "email", .{ .string = m.email });
    if (m.organization.len > 0) try obj.put(arena, "organization", .{ .string = m.organization });
    if (m.plan.len > 0) try obj.put(arena, "plan", .{ .string = m.plan });
    const data = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = obj }, .{});
    try store.replaceFile(io, Io.Dir.cwd(), path, data, store.private_file);
}

/// `claude auth status` reads Claude Code's own login and prints JSON.
pub fn status(io: Io, arena: Allocator, exe: []const u8) !Status {
    const pr = @import("process_runner.zig");
    const run = try pr.runCappedWithOptions(arena, io, &.{ exe, "auth", "status" }, 64 * 1024, 8192, 20_000, .{});
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, run.stdout, .{ .allocate = .alloc_always }) catch return .{ .logged_in = false };
    if (v != .object) return .{ .logged_in = false };
    const logged = if (v.object.get("loggedIn")) |l| l == .bool and l.bool else false;
    const str = struct {
        fn get(o: std.json.ObjectMap, k: []const u8) []const u8 {
            const x = o.get(k) orelse return "";
            return if (x == .string) x.string else "";
        }
    }.get;
    const org = blk: {
        const a = str(v.object, "orgName");
        break :blk if (a.len > 0) a else str(v.object, "organizationName");
    };
    return .{
        .logged_in = logged,
        .method = str(v.object, "authMethod"),
        .plan = str(v.object, "subscriptionType"),
        .email = str(v.object, "email"),
        .organization = org,
    };
}

pub fn login(io: Io, arena: Allocator, environ_map: anytype, home: []const u8) !void {
    const style = &@import("ansi.zig").style;
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &buf);
    const out = &w.interface;
    const exe = environ_map.get("GRAFF_CLAUDE_PATH") orelse "claude";
    var st = status(io, arena, exe) catch |err| switch (err) {
        error.FileNotFound => {
            try out.writeAll(
                \\✗ Claude Agent runs your own Claude Code (`claude`), which isn't installed. Install it (https://code.claude.com/docs/en/setup), then sign in to Claude Agent again.
                \\
            );
            try out.flush();
            return error.ClaudeNotInstalled;
        },
        else => return err,
    };
    // The login belongs to `claude`. With no terminal (a client such as the
    // desktop app runs this), say where to sign in rather than start it.
    if (!st.logged_in and !(Io.File.stdin().isTty(io) catch false)) {
        try out.writeAll("✗ Claude Code is not signed in. Run `claude auth login` in a terminal, then sign in to Claude Agent again.\n");
        try out.flush();
        return error.ClaudeNotSignedIn;
    }
    if (!st.logged_in) {
        try out.writeAll("Claude Code is not signed in; starting `claude auth login`.\n");
        try out.flush();
        var child = try std.process.spawn(io, .{ .argv = &.{ exe, "auth", "login" }, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit });
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            try out.writeAll("✗ claude auth login did not finish; nothing changed.\n");
            try out.flush();
            return error.ClaudeLoginIncomplete;
        }
        st = try status(io, arena, exe);
        if (!st.logged_in) {
            try out.writeAll("✗ Claude Code still reports no login; nothing changed.\n");
            try out.flush();
            return error.ClaudeLoginIncomplete;
        }
    }
    try saveMarker(io, arena, home, .{
        .claude = exe,
        .email = st.email,
        .organization = st.organization,
        .plan = st.plan,
    });
    try out.print("{s}✓{s} Claude Agent is ready: graff runs your Claude Code login", .{ style.green, style.reset });
    if (st.method.len > 0) try out.print(" ({s}{s}{s})", .{ st.method, if (st.plan.len > 0) ", " else "", st.plan });
    try out.writeAll(".\n  Claude models now run through it: `graff --model claude-opus-5-5` (or sonnet, haiku, fable), or /model.\n");
    try out.flush();
}

/// `graff logout claude-agent`: forget the choice. Claude Code's own login stays.
pub fn logout(io: Io, arena: Allocator, home: []const u8) !void {
    Io.Dir.cwd().deleteFile(io, markerPath(arena, home)) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const Env = struct {
    map: []const [2][]const u8,
    pub fn get(self: Env, key: []const u8) ?[]const u8 {
        for (self.map) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
        return null;
    }
};

test "claude-agent opt-in: env wins, 0 turns it off, no marker and no env is off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    try std.testing.expectEqualStrings("claude", enabled(io, arena, Env{ .map = &.{.{ "GRAFF_CLAUDE_AGENT", "1" }} }, "").?);
    try std.testing.expectEqualStrings("/opt/claude", enabled(io, arena, Env{ .map = &.{ .{ "GRAFF_CLAUDE_AGENT", "1" }, .{ "GRAFF_CLAUDE_PATH", "/opt/claude" } } }, "").?);
    try std.testing.expect(enabled(io, arena, Env{ .map = &.{.{ "GRAFF_CLAUDE_AGENT", "0" }} }, "/nonexistent-home") == null);
    try std.testing.expect(enabled(io, arena, Env{ .map = &.{} }, "/nonexistent-home") == null);
}
