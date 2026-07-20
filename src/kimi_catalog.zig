//! Authenticated Kimi Code model discovery. Kimi's coding endpoint publishes
//! account-visible ids at /coding/v1/models; keep routing current without
//! baking each K2/K3 rollout into the OAuth client.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const pricing = @import("pricing.zig");
const util = @import("util.zig");

pub const models_url = "https://api.kimi.com/coding/v1/models";
pub const user_agent = "graff/" ++ @import("build_options").version;
pub const platform = "kimi_code_cli";
pub const version = @import("build_options").version;
pub const device_model = @tagName(builtin.os.tag) ++ " " ++ @tagName(builtin.cpu.arch);
pub const os_version = @tagName(builtin.os.tag);
pub var device_id: []const u8 = "unknown";
pub var catalog_source: []const u8 = "baked offline fallback";
var catalog_attempted = false;

const private_file_permissions: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o600) else .default_file;
const private_dir_permissions: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o700) else .default_dir;

fn secureDir(io: Io, path: []const u8) void {
    // iterate=true: a default openDir can yield an O_PATH handle on Linux, and
    // fchmod on O_PATH fails EBADF — which std.Io treats as a programmer-bug
    // panic, not a catchable error. A readable handle chmods fine everywhere.
    const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    dir.setPermissions(io, private_dir_permissions) catch {};
}

fn validDeviceId(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Kimi Code sends a stable random device id with its X-Msh identity headers.
/// Graff owns a separate ~/.kimi/device_id so it never mutates another CLI's
/// credential store or impersonates that installation.
pub fn initIdentity(io: Io, arena: Allocator, home: []const u8) void {
    if (!std.mem.eql(u8, device_id, "unknown") or home.len == 0) return;
    const dir = std.fmt.allocPrint(arena, "{s}/.kimi", .{home}) catch return;
    const path = std.fmt.allocPrint(arena, "{s}/device_id", .{dir}) catch return;
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(128))) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (validDeviceId(value)) {
            device_id = arena.dupe(u8, value) catch "unknown";
            secureDir(io, dir);
            const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            defer file.close(io);
            file.setPermissions(io, private_file_permissions) catch {};
            return;
        }
    } else |_| {}
    var random: [16]u8 = undefined;
    io.random(&random);
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(random, .lower);
    const id = arena.alloc(u8, 36) catch return;
    @memcpy(id[0..8], hex[0..8]);
    id[8] = '-';
    @memcpy(id[9..13], hex[8..12]);
    id[13] = '-';
    @memcpy(id[14..18], hex[12..16]);
    id[18] = '-';
    @memcpy(id[19..23], hex[16..20]);
    id[23] = '-';
    @memcpy(id[24..36], hex[20..32]);
    device_id = id;
    Io.Dir.cwd().createDir(io, dir, private_dir_permissions) catch {};
    secureDir(io, dir);
    const file = Io.Dir.cwd().createFile(io, path, .{ .permissions = private_file_permissions }) catch return;
    defer file.close(io);
    file.setPermissions(io, private_file_permissions) catch {};
    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.print("{s}\n", .{id}) catch return;
    writer.interface.flush() catch {};
}

pub fn identityHeaders(buf: []std.http.Header) []std.http.Header {
    if (buf.len < 6) return buf[0..0];
    buf[0] = .{ .name = "X-Msh-Platform", .value = platform };
    buf[1] = .{ .name = "X-Msh-Version", .value = version };
    buf[2] = .{ .name = "X-Msh-Device-Name", .value = "graff" };
    buf[3] = .{ .name = "X-Msh-Device-Model", .value = device_model };
    buf[4] = .{ .name = "X-Msh-Os-Version", .value = os_version };
    buf[5] = .{ .name = "X-Msh-Device-Id", .value = device_id };
    return buf[0..6];
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return true;
}

fn positiveInt(obj: std.json.ObjectMap, name: []const u8) u64 {
    const value = obj.get(name) orelse return 0;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(i) else 0,
        .float => |f| if (f > 0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn boolField(obj: std.json.ObjectMap, name: []const u8) bool {
    const value = obj.get(name) orelse return false;
    return value == .bool and value.bool;
}

fn thinkingSupport(obj: std.json.ObjectMap) pricing.ThinkingSupport {
    const raw = util.strFieldObj(obj, "supports_thinking_type") orelse return .unknown;
    if (std.mem.eql(u8, raw, "no")) return .no;
    if (std.mem.eql(u8, raw, "both")) return .both;
    if (std.mem.eql(u8, raw, "only")) return .only;
    return .unknown;
}

fn parseEfforts(arena: Allocator, obj: std.json.ObjectMap) struct { values: []const []const u8, default: ?[]const u8 } {
    const raw = obj.get("think_efforts") orelse return .{ .values = &.{}, .default = null };
    if (raw != .object or !boolField(raw.object, "support")) return .{ .values = &.{}, .default = null };
    var values: std.ArrayList([]const u8) = .empty;
    if (raw.object.get("valid_efforts")) |list| if (list == .array) {
        for (list.array.items) |value| {
            if (value != .string or value.string.len == 0 or value.string.len > 32) continue;
            values.append(arena, arena.dupe(u8, value.string) catch continue) catch continue;
        }
    };
    return .{
        .values = values.toOwnedSlice(arena) catch &.{},
        .default = if (util.strFieldObj(raw.object, "default_effort")) |value| arena.dupe(u8, value) catch null else null,
    };
}

/// Parse the OpenAI-style model list Kimi exposes. Preserve server ordering for
/// the picker, while pricing.providerDefaultModel independently selects the
/// newest pure `kN` generation rather than the first compatibility alias.
pub fn parseModels(arena: Allocator, data: []const u8) ?[]const pricing.ModelInfo {
    const value = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (value != .object) return null;
    const items = value.object.get("data") orelse return null;
    if (items != .array) return null;
    var rows: std.ArrayList(pricing.ModelInfo) = .empty;
    for (items.array.items) |item| {
        if (item != .object) continue;
        const id = util.strFieldObj(item.object, "id") orelse continue;
        if (!validModelId(id)) continue;
        var duplicate = false;
        for (rows.items) |row| if (std.mem.eql(u8, row.name, id)) {
            duplicate = true;
        };
        if (duplicate) continue;
        var context = positiveInt(item.object, "context_length");
        if (context == 0) context = positiveInt(item.object, "context_window");
        if (context == 0) context = pricing.default_context;
        const effort = parseEfforts(arena, item.object);
        const protocol: pricing.ModelProtocol = if (util.strFieldObj(item.object, "protocol")) |protocol_name|
            (if (std.mem.eql(u8, protocol_name, "anthropic")) .anthropic else .kimi)
        else
            .kimi;
        rows.append(arena, .{
            .provider = "kimi",
            .name = arena.dupe(u8, id) catch continue,
            .context = context,
            .protocol = protocol,
            .supports_reasoning = boolField(item.object, "supports_reasoning"),
            .thinking_support = thinkingSupport(item.object),
            .support_efforts = effort.values,
            .default_effort = effort.default,
        }) catch continue;
    }
    const owned = rows.toOwnedSlice(arena) catch return null;
    return if (owned.len > 0) owned else null;
}

/// Fetch and activate the authenticated catalog. Any failure leaves the baked
/// K3 rows intact, so offline runs and temporary Kimi outages still start.
pub fn load(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, access: []const u8) bool {
    initIdentity(io, arena, home);
    if (access.len == 0) {
        catalog_source = "baked fallback — no Kimi login";
        return false;
    }
    catalog_attempted = true;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{access}) catch return false;
    var extra: [8]std.http.Header = undefined;
    extra[0] = .{ .name = "Authorization", .value = bearer };
    extra[1] = .{ .name = "Accept", .value = "application/json" };
    _ = identityHeaders(extra[2..]);
    const response = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &extra,
    }) catch {
        catalog_source = "baked fallback — live refresh unavailable";
        return false;
    };
    if (@intFromEnum(response.status) != 200) {
        catalog_source = "baked fallback — live refresh unavailable";
        return false;
    }
    const rows = parseModels(arena, aw.writer.buffered()) orelse {
        catalog_source = "baked fallback — invalid live catalog";
        return false;
    };
    if (!pricing.activateKimiModels(arena, rows)) return false;
    catalog_source = "live account catalog";
    return true;
}

/// Demand-load the account catalog at most once per process. Startup calls
/// this only when Kimi can actually win model selection; `/model` and
/// `/models` call it when their catalog surfaces become visible.
pub fn ensure(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, access: []const u8) void {
    if (catalog_attempted) return;
    _ = load(io, gpa, arena, home, access);
}

test "parseModels accepts Kimi aliases and K3 context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const rows = parseModels(state.allocator(),
        \\{"object":"list","data":[
        \\ {"id":"kimi-for-coding","context_length":262144,"supports_reasoning":true},
        \\ {"id":"k3","context_length":1048576,"protocol":"anthropic","supports_reasoning":true,"supports_thinking_type":"only","think_efforts":{"support":true,"valid_efforts":["max"],"default_effort":"max"}},
        \\ {"id":"k3","context_length":1},
        \\ {"id":"bad id","context_length":42}]}
    ).?;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("kimi-for-coding", rows[0].name);
    try std.testing.expectEqualStrings("k3", rows[1].name);
    try std.testing.expectEqual(@as(u64, 1_048_576), rows[1].context);
    try std.testing.expectEqual(pricing.ModelProtocol.anthropic, rows[1].protocol);
    try std.testing.expectEqual(pricing.ThinkingSupport.only, rows[1].thinking_support);
    try std.testing.expectEqualStrings("max", rows[1].support_efforts[0]);
    try std.testing.expectEqualStrings("max", rows[1].default_effort.?);
}
