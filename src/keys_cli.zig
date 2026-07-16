//! API-key storage + the `graff key` CLI + OpenAI-compatible model listing.
//! Split out of main.zig (600-line goal, #123).
//!
//! Safe API-key store: on macOS, keys live in the login Keychain (service
//! "simple-harness", account=provider id) via the `security` CLI — never on
//! disk in plaintext. Elsewhere they fall back to a 0600 file
//! (~/.simple-harness-keys.json). `harness key set <provider> <key>` writes;
//! startup reads the selected provider first (env always wins), then fills the
//! remaining providers when a picker, switch, resume, or fallback needs them.
//!
//! storeKey stays pub — commands_model.zig and pickers.zig back-import it as
//! `main_mod.storeKey`; isLocalUrl/openAiModelsUrl/fetchOpenAIModels stay pub
//! for the same reason (commands_model.zig's local-server model picker).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const provider_specs = provider_mod.provider_specs;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;

/// True for a provider served by a local server (LM Studio, mlx-lm) on the
/// loopback host — these expose a live, user-controlled model set.
pub fn isLocalUrl(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "127.0.0.1") != null or std.mem.indexOf(u8, url, "localhost") != null;
}

/// Derive the OpenAI-compatible `/v1/models` URL from a provider's chat URL
/// (`…/v1/chat/completions` → `…/v1/models`).
pub fn openAiModelsUrl(arena: Allocator, chat_url: []const u8) []const u8 {
    const suffix = "/chat/completions";
    if (std.mem.endsWith(u8, chat_url, suffix))
        return std.fmt.allocPrint(arena, "{s}/models", .{chat_url[0 .. chat_url.len - suffix.len]}) catch chat_url;
    return chat_url;
}

/// GET an OpenAI-compatible `/v1/models` endpoint and return every model id it
/// advertises (arena-owned), or an empty slice on any failure. Lets `/model
/// <local-provider>` list what a local server (LM Studio :1234, mlx-lm :8080)
/// actually has loaded instead of a baked-in name.
pub fn fetchOpenAIModels(io: Io, gpa: Allocator, arena: Allocator, models_url: []const u8, key: []const u8) [][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{key}) catch return list.items;
    const extra = [_]std.http.Header{
        .{ .name = "authorization", .value = bearer },
        .{ .name = "Accept", .value = "application/json" },
    };
    const res = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = &extra,
    }) catch return list.items;
    if (@intFromEnum(res.status) != 200) return list.items;
    const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return list.items;
    if (v != .object) return list.items;
    const data = v.object.get("data") orelse return list.items;
    if (data != .array) return list.items;
    for (data.array.items) |item| {
        if (item != .object) continue;
        if (strFieldObj(item.object, "id")) |id| if (id.len > 0)
            list.append(arena, arena.dupe(u8, id) catch continue) catch {};
    }
    return list.toOwnedSlice(arena) catch list.items;
}

test "openAiModelsUrl derives /v1/models from the chat URL; isLocalUrl flags loopback" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/models", openAiModelsUrl(a.allocator(), "http://127.0.0.1:1234/v1/chat/completions"));
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/v1/models", openAiModelsUrl(a.allocator(), "http://127.0.0.1:8080/v1/chat/completions"));
    try std.testing.expect(isLocalUrl("http://127.0.0.1:1234/v1/chat/completions"));
    try std.testing.expect(isLocalUrl("http://localhost:1234/v1/chat/completions"));
    try std.testing.expect(!isLocalUrl("https://api.openai.com/v1/chat/completions"));
}

const keychain_service = "simple-harness";
const keys_file = ".simple-harness-keys.json";

/// User home directory env value: $HOME, or %USERPROFILE% on Windows (which has
/// no HOME). Key storage, sessions, history, login credentials, and saved model
/// all hang off this, so the Windows fallback is what makes them work there.
pub fn homeEnv(env: anytype) ?[]const u8 {
    if (env.get("HOME")) |h| return h;
    if (builtin.os.tag == .windows) {
        if (env.get("USERPROFILE")) |h| return h;
    }
    return null;
}

pub fn storeKey(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, provider: []const u8, key: []const u8) bool {
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "security", "add-generic-password", "-U", "-s", keychain_service, "-a", provider, "-w", key },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return false;
        const term = child.wait(io) catch return false;
        return term == .exited and term.exited == 0;
    }
    // Linux/other: merge into a 0600 JSON file.
    _ = gpa;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, keys_file }) catch return false;
    var obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024))) |data| {
        if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) obj = v.object;
        } else |_| {}
    } else |_| {}
    obj.put(arena, provider, .{ .string = key }) catch return false;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.flush() catch return false;
    return true;
}

pub fn loadStoredKey(io: Io, arena: Allocator, home: []const u8, provider: []const u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        var child = std.process.spawn(io, .{
            .argv = &.{ "security", "find-generic-password", "-s", keychain_service, "-a", provider, "-w" },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch return null;
        defer _ = child.wait(io) catch {};
        const f = child.stdout orelse return null;
        var rbuf: [8 * 1024]u8 = undefined;
        var fr = f.readerStreaming(io, &rbuf);
        const out = fr.interface.allocRemaining(arena, .limited(64 * 1024)) catch return null;
        const key = std.mem.trim(u8, out, " \t\r\n");
        return if (key.len > 0) key else null;
    }
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, keys_file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    if (v.object.get(provider)) |k| if (k == .string and k.string.len > 0) return k.string;
    return null;
}

pub const StoredKeyScope = union(enum) {
    all,
    provider: []const u8,
    mask: [provider_specs.len]bool,

    pub fn includes(scope: StoredKeyScope, index: usize, provider_id: []const u8) bool {
        return switch (scope) {
            .all => true,
            .provider => |id| std.mem.eql(u8, id, provider_id),
            .mask => |mask| mask[index],
        };
    }
};

test "StoredKeyScope selects all, one provider, or an exact mask" {
    const all: StoredKeyScope = .all;
    try std.testing.expect(all.includes(0, provider_specs[0].id));
    const one: StoredKeyScope = .{ .provider = "deepseek" };
    try std.testing.expect(one.includes(2, "deepseek"));
    try std.testing.expect(!one.includes(1, "codegraff"));
    var mask = [_]bool{false} ** provider_specs.len;
    mask[1] = true;
    const selected: StoredKeyScope = .{ .mask = mask };
    try std.testing.expect(selected.includes(1, "codegraff"));
    try std.testing.expect(!selected.includes(2, "deepseek"));
}

fn loadStoredKeyTask(io: Io, gpa: Allocator, home: []const u8, provider_id: []const u8) ?[]u8 {
    var task_arena = std.heap.ArenaAllocator.init(gpa);
    defer task_arena.deinit();
    const key = loadStoredKey(io, task_arena.allocator(), home, provider_id) orelse return null;
    return gpa.dupe(u8, key) catch null;
}

/// Fill selected missing credential slots. macOS stores one Keychain item per
/// provider, so its independent `security` processes run concurrently with
/// task-local arenas. Other platforms keep all keys in one JSON file: read and
/// parse it once, then fill every selected slot from that single object.
pub fn loadMissingStoredKeys(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, keys: *provider_mod.Keys, scope: StoredKeyScope) void {
    if (builtin.os.tag == .macos) {
        var futures = [_]?Io.Future(?[]u8){null} ** provider_specs.len;
        for (provider_specs, keys.values, 0..) |spec, value, i| {
            if (value != null or !scope.includes(i, spec.id)) continue;
            const task_args = .{ io, gpa, home, spec.id };
            futures[i] = io.concurrent(loadStoredKeyTask, task_args) catch
                io.async(loadStoredKeyTask, task_args);
        }
        for (&futures, &keys.values, &keys.sources) |*maybe_future, *value, *source| {
            const owned = if (maybe_future.*) |*future| future.await(io) orelse continue else continue;
            value.* = arena.dupe(u8, owned) catch null;
            gpa.free(owned);
            if (value.* != null) source.* = .stored;
        }
        return;
    }

    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, keys_file }) catch return;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    for (provider_specs, &keys.values, &keys.sources, 0..) |spec, *value, *source, i| {
        if (value.* != null or !scope.includes(i, spec.id)) continue;
        const stored = parsed.object.get(spec.id) orelse continue;
        if (stored != .string or stored.string.len == 0) continue;
        value.* = stored.string;
        source.* = .stored;
    }
}

/// `harness key set <provider> <key>` / `harness key list` — manage the safe
/// key store. Validates the provider id against provider_specs.
pub fn keyCommand(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        var stored_keys: provider_mod.Keys = .{ .values = [_]?[]const u8{null} ** provider_specs.len };
        loadMissingStoredKeys(io, gpa, arena, home, &stored_keys, .all);
        try out.writeAll("provider        env var               stored\n");
        for (provider_specs) |spec| {
            const stored = stored_keys.get(spec.id) != null;
            try out.print("  {s:<14}{s:<22}{s}\n", .{ spec.id, spec.env_key, if (stored) "yes" else "—" });
        }
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len < 3) {
            try out.writeAll("usage: graff key set <provider> <key>\n");
            try out.flush();
            return;
        }
        const provider = args[1];
        const key = args[2];
        var known = false;
        for (provider_specs) |spec| {
            if (std.mem.eql(u8, spec.id, provider)) known = true;
        }
        if (!known) {
            try out.print("unknown provider '{s}' — see /models for valid ids\n", .{provider});
            try out.flush();
            return;
        }
        if (storeKey(io, gpa, arena, home, provider, key)) {
            const where = if (builtin.os.tag == .macos) "macOS Keychain" else "~/" ++ keys_file;
            try out.print("✓ stored {s} key in the {s}\n", .{ provider, where });
        } else {
            try out.writeAll("✗ failed to store key\n");
        }
        try out.flush();
        return;
    }
    try out.writeAll("usage: graff key set <provider> <key>  |  graff key list\n");
    try out.flush();
}

/// Load (or create on first run) a 32-hex-char anonymous id at ~/<fname>.
/// All-zero id when HOME is missing or the file can't be created.
pub fn loadOrCreateId(io: Io, gpa: Allocator, home: []const u8, fname: []const u8) [32]u8 {
    var id: [32]u8 = @splat('0');
    if (home.len == 0) return id;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ home, fname }) catch return id;
    existing: {
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch break :existing;
        defer gpa.free(data);
        const trimmed = std.mem.trim(u8, data, " \t\r\n");
        if (trimmed.len != 32) break :existing;
        for (trimmed) |c| switch (c) { // lowercase hex only, like the writer
            '0'...'9', 'a'...'f' => {},
            else => break :existing,
        };
        @memcpy(&id, trimmed);
        return id;
    }
    var raw: [16]u8 = undefined;
    io.random(&raw);
    id = std.fmt.bytesToHex(raw, .lower);
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return id;
    defer f.close(io);
    var wbuf: [64]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.print("{s}\n", .{&id}) catch return id;
    fw.interface.flush() catch return id;
    return id;
}
