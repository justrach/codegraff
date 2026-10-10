//! The `model` config option for T3 Code's model picker (acp_t3.zig): the
//! models this install can reach, in the `graff/models` election order.
//! Values are `<provider>/<model>`; choosing one runs `/model <provider> <model>`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const models_rank = @import("models_rank");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;

/// T3 shows at most 64 choices per option.
const max_choices = 48;

/// Local catalog state only: stored keys, cached provider lists. No network.
pub fn hydrate(live: *LiveTurn) void {
    const root = live.root;
    root.ensureStoredKeys(live.keys);
    if (root.model_catalog) |*cached|
        cached.ensureCached(root.io, root.gpa, root.arena, root.home, live.keys.get("codex") orelse "", live.keys.codex_account);
    if (!live.local_catalog_loaded) {
        if (root.home.len > 0) @import("router_catalog.zig").loadCachedAll(root.io, root.arena, root.home);
        live.local_catalog_loaded = true;
    }
}

pub const Choice = struct { provider: []const u8, model: []const u8 };

/// Reachable models, best first, with the current one always present.
pub fn choices(arena: Allocator, catalog: []const pricing.ModelInfo, keys: anytype, current: Choice) ![]const Choice {
    const ranked = try arena.alloc(models_rank.Scored, catalog.len);
    for (catalog, 0..) |m, i| ranked[i] = .{
        .idx = i,
        .score = models_rank.electionRank(keys.get(m.provider) != null, billing.costFor(m.provider, keys.source(m.provider))),
    };
    std.mem.sort(models_rank.Scored, ranked, {}, models_rank.scoredLess);
    var out: std.ArrayList(Choice) = .empty;
    try out.append(arena, current);
    for (ranked) |r| {
        if (out.items.len == max_choices) break;
        const m = catalog[r.idx];
        if (keys.get(m.provider) == null) continue;
        if (std.mem.eql(u8, m.provider, current.provider) and std.mem.eql(u8, m.name, current.model)) continue;
        try out.append(arena, .{ .provider = m.provider, .model = m.name });
    }
    return out.items;
}

pub fn option(ctx: *anyopaque, arena: Allocator) anyerror!?engine.ConfigOption {
    if (!@import("acp_t3.zig").active()) return null;
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    hydrate(live);
    const root = live.root;
    const list = try choices(arena, pricing.models(), live.keys, .{ .provider = root.provider.id, .model = root.provider.model });
    const values = try arena.alloc(engine.ConfigValue, list.len);
    for (list, values) |c, *v| v.* = .{
        .value = try std.fmt.allocPrint(arena, "{s}/{s}", .{ c.provider, c.model }),
        .name = try std.fmt.allocPrint(arena, "{s} · {s}", .{ c.model, c.provider }),
    };
    return .{ .id = "model", .name = "Model", .category = "model", .currentValue = values[0].value, .options = values };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    if (!@import("acp_t3.zig").active()) return false;
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    const cut = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const provider = value[0..cut];
    const model = value[cut + 1 ..];
    if (provider.len == 0 or model.len == 0 or std.mem.indexOfAny(u8, value, " \t\r\n") != null) return false;
    if (std.mem.eql(u8, provider, root.provider.id) and std.mem.eql(u8, model, root.provider.model)) return true;
    // The switched provider keeps slices of this line: allocate where the agent lives.
    const arena = root.arena;
    var sink: Io.Writer.Allocating = .init(root.gpa);
    defer sink.deinit();
    const line = try std.fmt.allocPrint(arena, "/model {s} {s}", .{ provider, model });
    try @import("main.zig").handleCommand(root, live.keys, arena, line, &sink.writer);
    return std.mem.eql(u8, root.provider.id, provider) and std.mem.eql(u8, root.provider.model, model);
}

test "model choices: reachable models only, current first, capped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Keys = struct {
        fn get(_: @This(), provider: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, provider, "codex") or std.mem.eql(u8, provider, "codegraff")) "k" else null;
        }
        fn source(_: @This(), _: []const u8) @import("provider.zig").Keys.CredentialSource {
            return .login;
        }
    };
    const catalog = [_]pricing.ModelInfo{
        .{ .provider = "anthropic", .name = "opus", .context = 1 },
        .{ .provider = "codex", .name = "gpt-a", .context = 1 },
        .{ .provider = "codegraff", .name = "kimi", .context = 1 },
        .{ .provider = "codex", .name = "gpt-b", .context = 1 },
    };
    const list = try choices(a, &catalog, Keys{}, .{ .provider = "codex", .model = "gpt-b" });
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("gpt-b", list[0].model);
    for (list) |c| try std.testing.expect(!std.mem.eql(u8, c.provider, "anthropic"));
}
