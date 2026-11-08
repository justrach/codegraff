//! Verbatim checkpoint regressions; imported by the main unit-test root.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const checkpoint = @import("compaction_checkpoint.zig");
const io = std.testing.io;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    name: [48]u8,

    fn init() !Fixture {
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        const hex = std.fmt.bytesToHex(raw, .lower);
        var f: Fixture = .{ .arena = .init(std.testing.allocator), .name = undefined };
        @memcpy(f.name[0..16], "checkpoint-test-");
        @memcpy(f.name[16..], &hex);
        return f;
    }

    fn deinit(f: *Fixture) void {
        var buf: [128]u8 = undefined;
        const session_path = std.fmt.bufPrint(&buf, ".graff/sessions/{s}", .{f.name}) catch unreachable;
        Io.Dir.cwd().deleteTree(io, session_path) catch {};
        f.arena.deinit();
    }

    fn agent(f: *Fixture) Agent {
        var agent_: Agent = undefined;
        agent_.gpa = f.arena.allocator();
        agent_.arena = f.arena.allocator();
        agent_.io = io;
        agent_.sub = false;
        agent_.session_name = &f.name;
        agent_.messages = std.json.Array.init(agent_.arena);
        agent_.compaction_window = .{};
        return agent_;
    }

    fn values(f: *Fixture, json: []const u8) ![]Value {
        return (try std.json.parseFromSliceLeaky(Value, f.arena.allocator(), json, .{ .allocate = .alloc_always })).array.items;
    }

    fn path(f: *Fixture, blob: Value) ![]const u8 {
        const a = f.arena.allocator();
        const bytes = try std.json.Stringify.valueAlloc(a, blob, .{});
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(a, ".graff/sessions/{s}/compaction/{s}.json", .{ f.name, hex });
    }
};

const window_json = "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque-test\"}]";

fn expectJson(expected: []const u8, values: []const Value) !void {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, values, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "compaction checkpoint restores verbatim prior history plus later tail" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const before = try f.values("[{\"role\":\"user\",\"content\":\"verbatim \\n λ\"},{\"type\":\"function_call\",\"arguments\":\"{\\\"x\\\":1}\"},{\"type\":\"function_call_output\",\"output\":\"untouched\"}]");
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, before, window);
    try agent.messages.appendSlice(window);
    try agent.messages.appendSlice(try f.values("[{\"role\":\"user\",\"content\":\"later\"}]"));
    try std.testing.expect(try checkpoint.restore(&agent));
    try expectJson("[{\"role\":\"user\",\"content\":\"verbatim \\n λ\"},{\"type\":\"function_call\",\"arguments\":\"{\\\"x\\\":1}\"},{\"type\":\"function_call_output\",\"output\":\"untouched\"},{\"role\":\"user\",\"content\":\"later\"}]", agent.messages.items);
    try std.testing.expect(agent.compaction_window.canonical_blob == null);
}

test "compaction checkpoint matches entire canonical standalone window" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const before = try f.values("[\"prior\"]");
    const window = try f.values("[\"retained prefix\",{\"type\":\"compaction_summary\",\"encrypted_content\":\"canonical\"},\"retained suffix\"]");
    try checkpoint.preserve(&agent, before, window);
    try agent.messages.appendSlice(window);
    try agent.messages.append(.{ .string = "later" });
    try std.testing.expect(try checkpoint.restore(&agent));
    try expectJson("[\"prior\",\"later\"]", agent.messages.items);
}

test "compaction checkpoint refuses prepended or changed canonical items" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const before = try f.values("[\"prior\"]");
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, before, window);
    try agent.messages.append(.{ .string = "unexpected prefix" });
    try agent.messages.appendSlice(window);
    const ptr = agent.messages.items.ptr;
    try std.testing.expect(!try checkpoint.restore(&agent));
    try std.testing.expectEqual(ptr, agent.messages.items.ptr);
    try expectJson("[\"unexpected prefix\",{\"type\":\"compaction\",\"encrypted_content\":\"opaque-test\"}]", agent.messages.items);

    const canonical = try f.values("[\"retained\",{\"type\":\"compaction\",\"encrypted_content\":\"other\"},\"suffix\"]");
    try checkpoint.preserve(&agent, before, canonical);
    agent.messages = std.json.Array.fromOwnedSlice(agent.arena, try agent.arena.dupe(Value, canonical));
    agent.messages.items[0] = .{ .string = "changed" };
    try std.testing.expect(!try checkpoint.restore(&agent));
    try std.testing.expectEqualStrings("changed", agent.messages.items[0].string);
    agent.messages.items[0] = canonical[0];
    agent.messages.items.len = 2;
    try std.testing.expect(!try checkpoint.restore(&agent));
}

test "compaction checkpoint missing and corrupt files leave history untouched" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try agent.messages.appendSlice(window);
    const ptr = agent.messages.items.ptr;
    try std.testing.expect(!try checkpoint.restore(&agent));
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    const path = try f.path(window[0]);
    for ([_][]const u8{ "", "{", "{}", "{\"version\":1,\"before\":[", "null", "[]" }) |bad| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bad });
        try std.testing.expect(!try checkpoint.restore(&agent));
        try std.testing.expectEqual(ptr, agent.messages.items.ptr);
        try expectJson(window_json, agent.messages.items);
    }
}

test "compaction checkpoint verifies history checksum and blob identity" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    const path = try f.path(window[0]);
    const original = try Io.Dir.cwd().readFileAlloc(io, path, f.arena.allocator(), .limited(checkpoint.max_checkpoint_bytes));
    const changed = try f.arena.allocator().dupe(u8, original);
    const index = std.mem.indexOf(u8, changed, "prior").?;
    changed[index] = 'X';
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = changed });
    try std.testing.expect(!try checkpoint.restore(&agent));
    @memcpy(changed, original);
    const blob_index = std.mem.indexOf(u8, changed, "opaque-test").?;
    changed[blob_index] = 'X';
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = changed });
    try std.testing.expect(!try checkpoint.restore(&agent));
    try expectJson(window_json, agent.messages.items);
}

test "compaction checkpoint immutable identity also binds complete ancestry" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const before = try f.values("[\"original\"]");
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, before, window);
    try checkpoint.preserve(&agent, before, window);
    try std.testing.expectError(error.ImmutableCheckpointConflict, checkpoint.preserve(&agent, try f.values("[\"different\"]"), window));
    try agent.messages.appendSlice(window);
    try std.testing.expect(try checkpoint.restore(&agent));
    try expectJson("[\"original\"]", agent.messages.items);
    try std.testing.expectError(error.NonExpandingCheckpoint, checkpoint.preserve(&agent, window, window));
}

test "compaction checkpoint unsafe session names and nondurable agents fail closed" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try agent.messages.appendSlice(window);
    for ([_][]const u8{ "..", "../escape", "a/b", "a\\b", "/absolute", ".hidden", "x\x00y", "x\ny" }) |name| {
        agent.session_name = name;
        try std.testing.expectError(error.UnsafeCheckpointSession, checkpoint.preserve(&agent, &.{}, window));
        try std.testing.expect(!try checkpoint.restore(&agent));
    }
    agent.session_name = "";
    try checkpoint.preserve(&agent, &.{}, window);
    try std.testing.expect(!try checkpoint.restore(&agent));
    agent.session_name = &f.name;
    agent.sub = true;
    try checkpoint.preserve(&agent, &.{}, window);
    try std.testing.expect(!try checkpoint.restore(&agent));
    try expectJson(window_json, agent.messages.items);
}

test "compaction checkpoint ignores symlinked session directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    const session_path = try std.fmt.allocPrint(agent.arena, ".graff/sessions/{s}", .{f.name});
    try Io.Dir.cwd().deleteTree(io, session_path);
    // A link to an existing cwd directory is rejected too: no redirected IO.
    try Io.Dir.cwd().symLink(io, ".", session_path, .{ .is_directory = true });
    defer Io.Dir.cwd().deleteFile(io, session_path) catch {};
    var rejected = false;
    checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window) catch {
        rejected = true;
    };
    try std.testing.expect(rejected);
    try std.testing.expect(!try checkpoint.restore(&agent));
    try expectJson(window_json, agent.messages.items);
}

test "compaction checkpoint supports bounded expansion through actual ancestors" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const first = try f.values(window_json);
    const second = try f.values("[{\"type\":\"compaction\",\"encrypted_content\":\"newer\"}]");
    try checkpoint.preserve(&agent, try f.values("[\"original\"]"), first);
    var ancestor = std.json.Array.init(agent.arena);
    try ancestor.appendSlice(first);
    try ancestor.append(.{ .string = "between" });
    try checkpoint.preserve(&agent, ancestor.items, second);
    try agent.messages.appendSlice(second);
    try agent.messages.append(.{ .string = "tail" });
    try std.testing.expect(try checkpoint.restore(&agent));
    try std.testing.expect(try checkpoint.restore(&agent));
    try std.testing.expect(!try checkpoint.restore(&agent));
    try expectJson("[\"original\",\"between\",\"tail\"]", agent.messages.items);
}

test "compaction checkpoint restores fresh Agent from saved history without original memory" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    try agent.messages.append(.{ .string = "saved tail" });
    const saved = try std.json.Stringify.valueAlloc(std.testing.allocator, agent.messages.items, .{});
    defer std.testing.allocator.free(saved);
    const path = try std.fmt.allocPrint(agent.arena, ".graff/sessions/{s}/resume.json", .{f.name});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = saved });
    var reloaded_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer reloaded_arena.deinit();
    const a = reloaded_arena.allocator();
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    var reloaded = f.agent();
    reloaded.gpa = a;
    reloaded.arena = a;
    reloaded.messages = (try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always })).array;
    // Destroy all original message/snapshot memory, not just the Agent value.
    f.arena.deinit();
    f.arena = .init(std.testing.allocator);
    try std.testing.expect(try checkpoint.restore(&reloaded));
    try expectJson("[\"prior\",\"saved tail\"]", reloaded.messages.items);
    // The parsed checkpoint's temporary arena has been released already.
    try reloaded.messages.append(.{ .string = "still owned" });
    try expectJson("[\"prior\",\"saved tail\",\"still owned\"]", reloaded.messages.items);
}

test "compaction checkpoint oversized file is rejected before loading" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    const file = try Io.Dir.cwd().openFile(io, try f.path(window[0]), .{ .mode = .read_write });
    defer file.close(io);
    try file.setLength(io, checkpoint.max_checkpoint_bytes + 1);
    try std.testing.expect(!try checkpoint.restore(&agent));
    try expectJson(window_json, agent.messages.items);
}

test "compaction checkpoint private snapshot and worker isolation" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"root prior\"]"), window);
    const stat = try Io.Dir.cwd().statFile(io, try f.path(window[0]), .{});
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
    var child = f.agent();
    child.sub = true;
    try checkpoint.preserve(&child, try f.values("[\"worker prior\"]"), window);
    try agent.messages.appendSlice(window);
    try std.testing.expect(try checkpoint.restore(&agent));
    try expectJson("[\"root prior\"]", agent.messages.items);
}

test "compaction checkpoint never skips an unmatched newest opaque item" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    try agent.messages.appendSlice(try f.values("[{\"type\":\"compaction\",\"encrypted_content\":\"missing-newer\"}]"));
    const ptr = agent.messages.items.ptr;
    try std.testing.expect(!try checkpoint.restore(&agent));
    try std.testing.expectEqual(ptr, agent.messages.items.ptr);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
}

test "compaction checkpoint rename moves only checkpoints and preserves recovery" {
    var f = try Fixture.init();
    defer f.deinit();
    var titled = try Fixture.init();
    defer titled.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    const marker_path = try std.fmt.allocPrint(agent.arena, ".graff/sessions/{s}/artifact", .{f.name});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = "leave in place" });
    try checkpoint.rename(&agent, &f.name, &titled.name);
    try std.testing.expectEqualStrings(&f.name, agent.session_name);
    const marker = try Io.Dir.cwd().readFileAlloc(io, marker_path, agent.arena, .limited(100));
    try std.testing.expectEqualStrings("leave in place", marker);
    agent.session_name = &titled.name;
    try agent.messages.appendSlice(window);
    try std.testing.expect(try checkpoint.restore(&agent));
    try expectJson("[\"prior\"]", agent.messages.items);
}

test "compaction checkpoint rename existing destination keeps both ancestries" {
    var f = try Fixture.init();
    defer f.deinit();
    var other = try Fixture.init();
    defer other.deinit();
    var agent = f.agent();
    var destination = other.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"first ancestry\"]"), window);
    try checkpoint.preserve(&destination, try f.values("[\"second ancestry\"]"), window);
    var rejected = false;
    checkpoint.rename(&agent, &f.name, &other.name) catch {
        rejected = true;
    };
    try std.testing.expect(rejected);
    try agent.messages.appendSlice(window);
    try destination.messages.appendSlice(window);
    try std.testing.expect(try checkpoint.restore(&agent));
    try std.testing.expect(try checkpoint.restore(&destination));
    try expectJson("[\"first ancestry\"]", agent.messages.items);
    try expectJson("[\"second ancestry\"]", destination.messages.items);
}

test "compaction checkpoint rename absent source is harmless and unsafe names fail" {
    var f = try Fixture.init();
    defer f.deinit();
    var other = try Fixture.init();
    defer other.deinit();
    var agent = f.agent();
    try checkpoint.rename(&agent, &f.name, &other.name);
    try std.testing.expectError(error.UnsafeCheckpointSession, checkpoint.rename(&agent, "../escape", &other.name));
    try std.testing.expectError(error.UnsafeCheckpointSession, checkpoint.rename(&agent, &f.name, "../escape"));
    try checkpoint.rename(&agent, &f.name, &f.name);
}

test "compaction checkpoint allocation failure never installs partial history" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, try f.values("[\"prior\"]"), window);
    try agent.messages.appendSlice(window);
    const ptr = agent.messages.items.ptr;
    var failing = std.testing.FailingAllocator.init(agent.arena, .{ .fail_index = 0 });
    agent.arena = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, checkpoint.restore(&agent));
    try std.testing.expectEqual(ptr, agent.messages.items.ptr);
    try expectJson(window_json, agent.messages.items);
}

test "a seat switch expands opaque state instead of replaying foreign ciphertext" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.tracer = null;
    agent.history_rewrites = 0;
    const recovery = @import("agent_encrypted_recovery.zig");

    const before = try f.values("[{\"role\":\"user\",\"content\":\"exact input\"}]");
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, before, window);
    try agent.messages.appendSlice(window);
    try agent.messages.appendSlice(try f.values("[{\"role\":\"user\",\"content\":\"later\"}]"));

    try std.testing.expect(recovery.expandForSeatChange(&agent));
    try expectJson("[{\"role\":\"user\",\"content\":\"exact input\"},{\"role\":\"user\",\"content\":\"later\"}]", agent.messages.items);
    // The window no longer describes the history, so it must not be replayed.
    try std.testing.expect(agent.compaction_window.canonical_blob == null);
    // Nothing opaque left: the guard is idempotent on the expanded history.
    try std.testing.expect(!recovery.expandForSeatChange(&agent));
}

test "a seat switch without a checkpoint leaves history and window untouched" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.tracer = null;
    agent.history_rewrites = 0;
    try agent.messages.appendSlice(try f.values(window_json));

    try std.testing.expect(!@import("agent_encrypted_recovery.zig").expandForSeatChange(&agent));
    try expectJson(window_json, agent.messages.items);
}

test "#1833 cross-format applyProviderInner expands checkpoint before translating history" {
    var f = try Fixture.init();
    defer f.deinit();
    var agent = f.agent();
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.tracer = null;
    agent.history_rewrites = 0;
    agent.jev_effort_pending = .{};
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    agent.subagent_provider = null;
    agent.subagent_provider_explicit = true;
    agent.registry = null;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.tools_responses = "";
    agent.keep_context = true;
    agent.reasoning = .medium;

    const before = try f.values("[{\"role\":\"user\",\"content\":\"checkpointed prompt\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"checkpointed reply\"}]}]");
    const window = try f.values(window_json);
    try checkpoint.preserve(&agent, before, window);
    try agent.messages.appendSlice(window);
    try agent.messages.appendSlice(try f.values("[{\"role\":\"user\",\"content\":\"tail prompt\"}]"));

    const target: @import("provider.zig").Provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "kimi-k3.1-pro", .context = 256_000 };
    const note = try @import("providers.zig").applyProviderInner(&agent, agent.arena, target, false);
    try std.testing.expectEqualStrings("context translated & kept; opaque state expanded from checkpoint", note);
    try expectJson("[{\"role\":\"user\",\"content\":\"checkpointed prompt\"},{\"role\":\"assistant\",\"content\":\"checkpointed reply\"},{\"role\":\"user\",\"content\":\"tail prompt\"}]", agent.messages.items);
}

