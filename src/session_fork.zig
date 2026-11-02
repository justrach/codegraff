//! Fork the CURRENT conversation in one step: save it, clone-on-write it into
//! a new session identity, and continue in the branch. Shared by the `/fork`
//! slash command (line REPL, and ACP clients through the same handler) and
//! ACP `session/fork`. The copy itself is session_branch.restore (#689/#697);
//! this module only chooses the names and makes sure the source is on disk.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const session = @import("session.zig");
const session_branch = @import("session_branch.zig");

pub const Error = error{NothingToFork};

const marker = "-fork-";

/// The first `<base>-fork-<n>` (n from 1) that `exists` does not claim. A
/// source that is itself an auto-named fork keeps one flat suffix, so forking
/// `chat-fork-1` offers `chat-fork-2` rather than `chat-fork-1-fork-1`; the
/// session file's `parent` still records the real lineage.
pub fn nextName(arena: Allocator, source: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    var base = stem(source);
    // Leave room for the suffix inside the 128-byte session-name limit.
    const room = 128 - marker.len - 10;
    if (base.len > room) base = base[0..room];
    var n: u32 = 1;
    while (n < std.math.maxInt(u32)) : (n += 1) {
        const candidate = try std.fmt.allocPrint(arena, "{s}{s}{d}", .{ base, marker, n });
        if (!exists(ctx, candidate)) return candidate;
    }
    return error.BranchAlreadyExists;
}

fn stem(source: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, source, marker) orelse return source;
    const digits = source[at + marker.len ..];
    if (at == 0 or digits.len == 0) return source;
    for (digits) |c| if (!std.ascii.isDigit(c)) return source;
    return source[0..at];
}

fn savedHere(root: *agent_mod.Agent, name: []const u8) bool {
    var scratch: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    return session.sessionExists(root, fba.allocator(), name);
}

/// A fork name for `source` that no save in this workspace uses yet.
pub fn autoName(root: *agent_mod.Agent, arena: Allocator, source: []const u8) ![]const u8 {
    return nextName(arena, source, root, savedHere);
}

/// Save the live conversation under its own name (so a never-saved one lands
/// where its autosave would), then branch it to `dest` or an automatic name.
/// The source file is not rewritten after this save: every later turn writes
/// the branch. `model_override` follows session_branch.restore.
pub fn forkCurrent(root: *agent_mod.Agent, keys: *provider_mod.Keys, arena: Allocator, dest: ?[]const u8, model_override: ?provider_mod.Provider) !session_branch.Result {
    const source = try arena.dupe(u8, root.session_name);
    if (!session.validSessionName(source)) return error.InvalidSessionName;
    try session.saveSession(root, arena, source);
    // #184: a conversation with nothing in it is never written, so there is
    // nothing durable to branch from.
    if (!session.sessionExists(root, arena, source)) return Error.NothingToFork;
    const target = dest orelse try autoName(root, arena, source);
    return session_branch.restore(root, keys, arena, source, target, model_override);
}

fn takenIn(set: []const []const u8, name: []const u8) bool {
    for (set) |taken| if (std.mem.eql(u8, taken, name)) return true;
    return false;
}

test "fork auto-names count up past existing saves and stay flat for forks of forks" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const none: []const []const u8 = &.{};
    try std.testing.expectEqualStrings("chat-fork-1", try nextName(a, "chat", none, takenIn));
    const some: []const []const u8 = &.{ "chat-fork-1", "chat-fork-2" };
    try std.testing.expectEqualStrings("chat-fork-3", try nextName(a, "chat", some, takenIn));
    try std.testing.expectEqualStrings("chat-fork-3", try nextName(a, "chat-fork-2", some, takenIn));
    // Only a numeric suffix is ours to strip.
    try std.testing.expectEqualStrings("my-fork-x-fork-1", try nextName(a, "my-fork-x", none, takenIn));
    try std.testing.expectEqualStrings("-fork-3-fork-1", try nextName(a, "-fork-3", none, takenIn));
    const long = &@import("util.zig").repeatBytes("x", 128);
    const named = try nextName(a, long, none, takenIn);
    try std.testing.expect(session.validSessionName(named));
    try std.testing.expect(std.mem.endsWith(u8, named, "-fork-1"));
}

test "/fork branches the current conversation and leaves the source save untouched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // fchdir isolation is POSIX-only
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: provider_mod.Keys = .{ .values = @splat("k") };
    var root: agent_mod.Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "[{\"role\":\"user\",\"content\":\"fork me\"},{\"role\":\"assistant\",\"content\":\"forked answer\"}]", .{})).array,
        .sub = false,
        .label = "root",
        .out = null,
        .home = "home", // relative to the tmp cwd; no saves there
        .stored_keys_loaded = true,
    };
    defer root.tools_used.deinit(gpa);
    root.session_name = "chat"; // never saved yet: /fork saves it first
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try @import("main.zig").handleCommand(&root, &keys, arena, "/fork", &aw.writer);
    const said = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, said, "forked chat into chat-fork-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "/resume chat") != null);
    try std.testing.expectEqualStrings("chat-fork-1", root.session_name);
    try std.testing.expectEqualStrings("chat", root.session_parent.?);
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    session.flushSaves();
    const source_before = try tmp.dir.readFileAlloc(io, ".graff/sessions/chat.session.json", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, source_before, "forked answer") != null);
    const branch = try tmp.dir.readFileAlloc(io, ".graff/sessions/chat-fork-1.session.json", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, branch, "\"parent\":\"chat\"") != null);

    // A turn on the branch writes the branch, never the source.
    var turn: std.json.ObjectMap = .empty;
    try turn.put(arena, "role", .{ .string = "user" });
    try turn.put(arena, "content", .{ .string = "only on the branch" });
    try root.messages.append(.{ .object = turn });
    try session.saveSession(&root, arena, root.session_name);
    const source_after = try tmp.dir.readFileAlloc(io, ".graff/sessions/chat.session.json", arena, .unlimited);
    try std.testing.expectEqualStrings(source_before, source_after);
    const branch_after = try tmp.dir.readFileAlloc(io, ".graff/sessions/chat-fork-1.session.json", arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, branch_after, "only on the branch") != null);

    // Forking the branch picks the next free flat name; an explicit name that
    // is taken is refused without moving the session.
    aw.clearRetainingCapacity();
    try @import("main.zig").handleCommand(&root, &keys, arena, "/fork", &aw.writer);
    try std.testing.expectEqualStrings("chat-fork-2", root.session_name);
    try std.testing.expectEqualStrings("chat-fork-1", root.session_parent.?);
    try std.testing.expectEqualStrings(source_before, try tmp.dir.readFileAlloc(io, ".graff/sessions/chat.session.json", arena, .unlimited));
    aw.clearRetainingCapacity();
    try @import("main.zig").handleCommand(&root, &keys, arena, "/fork chat-fork-1", &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "already exists") != null);
    try std.testing.expectEqualStrings("chat-fork-2", root.session_name);
}
