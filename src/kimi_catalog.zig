//! Authenticated Kimi Code model discovery. Kimi's coding endpoint publishes
//! account-visible ids at /coding/v1/models; keep routing current without
//! baking each K2/K3 rollout into the OAuth client.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const pricing = @import("pricing.zig");
const util = @import("util.zig");

pub const models_url = "https://api.kimi.com/coding/v1/models";
pub const user_agent = "claude-code/1.0.0";
pub var catalog_source: []const u8 = "baked offline fallback";

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
        rows.append(arena, .{
            .provider = "kimi",
            .name = arena.dupe(u8, id) catch continue,
            .context = context,
        }) catch continue;
    }
    const owned = rows.toOwnedSlice(arena) catch return null;
    return if (owned.len > 0) owned else null;
}

/// Fetch and activate the authenticated catalog. Any failure leaves the baked
/// K3 rows intact, so offline runs and temporary Kimi outages still start.
pub fn load(io: Io, gpa: Allocator, arena: Allocator, access: []const u8) bool {
    if (access.len == 0) {
        catalog_source = "baked fallback — no Kimi login";
        return false;
    }
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const bearer = std.fmt.allocPrint(arena, "Bearer {s}", .{access}) catch return false;
    const extra = [_]std.http.Header{
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "Accept", .value = "application/json" },
    };
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

test "parseModels accepts Kimi aliases and K3 context windows" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const rows = parseModels(state.allocator(),
        \\{"object":"list","data":[
        \\ {"id":"kimi-for-coding","context_length":262144},
        \\ {"id":"k3","context_length":1048576},
        \\ {"id":"k3","context_length":1},
        \\ {"id":"bad id","context_length":42}]}
    ).?;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("kimi-for-coding", rows[0].name);
    try std.testing.expectEqualStrings("k3", rows[1].name);
    try std.testing.expectEqual(@as(u64, 1_048_576), rows[1].context);
}
