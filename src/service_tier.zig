//! Codex / ChatGPT plan service-tier selection (`default` | `fast` | `ultrafast`).
//!
//! Maps session speed preferences to the Responses `service_tier` field on the
//! ChatGPT subscription routes (`codex` and `chatgpt-new`) without ever leaking
//! `service_tier` onto direct API or third-party providers.
//!
//! Wire values:
//!   - `standard` (`default`): omit `service_tier`
//!   - `fast`: `"priority"` (all `codex` and `chatgpt-new` models)
//!   - `ultrafast`: `"ultrafast"` on `gpt-6.2-sol`, `gpt-6.2-astra`, and any
//!     live catalog row advertising `"ultrafast"` in `service_tiers` /
//!     `additional_speed_tiers`; degrades to `"priority"` on older ChatGPT models.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const Approvals = @import("approvals.zig").Approvals;
const pricing = @import("pricing.zig");

pub const Tier = enum {
    standard,
    fast,
    ultrafast,

    pub fn label(self: Tier) []const u8 {
        return switch (self) {
            .standard => "default",
            .fast => "fast",
            .ultrafast => "ultrafast",
        };
    }

    pub fn displayLabel(self: Tier) []const u8 {
        return switch (self) {
            .standard => "Standard",
            .fast => "Fast",
            .ultrafast => "Ultrafast",
        };
    }
};

pub fn parse(raw: []const u8) ?Tier {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(s, "default") or std.ascii.eqlIgnoreCase(s, "standard") or
        std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "false") or
        std.ascii.eqlIgnoreCase(s, "none")) return .standard;
    if (std.ascii.eqlIgnoreCase(s, "fast") or std.ascii.eqlIgnoreCase(s, "priority") or
        std.ascii.eqlIgnoreCase(s, "on") or std.ascii.eqlIgnoreCase(s, "true")) return .fast;
    if (std.ascii.eqlIgnoreCase(s, "ultrafast") or std.ascii.eqlIgnoreCase(s, "ultra-fast") or
        std.ascii.eqlIgnoreCase(s, "ultra_fast")) return .ultrafast;
    return null;
}

pub fn supportsFast(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "codex") or std.mem.eql(u8, provider_id, "chatgpt-new");
}

pub fn supportsUltrafast(provider_id: []const u8, model: []const u8) bool {
    if (!supportsFast(provider_id)) return false;
    if (pricing.modelInfoFor(provider_id, model)) |info| if (info.supports_ultrafast) return true;
    return pricing.modelAliasEquals(model, "gpt-6.2-sol") or pricing.modelAliasEquals(model, "gpt-6.2-astra");
}

pub fn effective(self: *const Agent) Tier {
    if (self.service_tier != .standard) return self.service_tier;
    return if (self.fast) .fast else .standard;
}

pub fn apply(self: *Agent, tier: Tier) void {
    self.service_tier = tier;
    self.fast = tier != .standard;
}

/// Wire `service_tier` value for a Responses request, or null when omitted.
pub fn wireValue(provider_id: []const u8, model: []const u8, tier: Tier) ?[]const u8 {
    if (!supportsFast(provider_id)) return null;
    return switch (tier) {
        .standard => null,
        .fast => "priority",
        .ultrafast => if (supportsUltrafast(provider_id, model)) "ultrafast" else "priority",
    };
}

/// Effective tier clamped to what `(provider_id, model)` supports.
pub fn normalizedForModel(provider_id: []const u8, model: []const u8, tier: Tier) Tier {
    if (!supportsFast(provider_id)) return .standard;
    if (tier == .ultrafast and !supportsUltrafast(provider_id, model)) return .fast;
    return tier;
}

/// Offered non-default speed tiers for `graff/models`.
pub fn tiersFor(provider_id: []const u8, model: []const u8) []const []const u8 {
    if (!supportsFast(provider_id)) return &.{};
    if (supportsUltrafast(provider_id, model)) return &.{ "fast", "ultrafast" };
    return &.{"fast"};
}

/// True when a raw Codex/ChatGPT catalog row or compact cache advertises ultrafast.
pub fn jsonAdvertisesUltrafast(obj: std.json.ObjectMap) bool {
    if (obj.get("supports_ultrafast")) |v| if (v == .bool and v.bool) return true;
    for ([_][]const u8{ "additional_speed_tiers", "additionalSpeedTiers" }) |key| {
        if (obj.get(key)) |arr| if (arr == .array) {
            for (arr.array.items) |item| {
                if (item == .string and std.ascii.eqlIgnoreCase(item.string, "ultrafast")) return true;
            }
        };
    }
    for ([_][]const u8{ "service_tiers", "serviceTiers" }) |key| {
        if (obj.get(key)) |arr| if (arr == .array) {
            for (arr.array.items) |item| {
                if (item != .object) continue;
                if (item.object.get("id")) |id| if (id == .string and std.ascii.eqlIgnoreCase(id.string, "ultrafast")) return true;
            }
        };
    }
    return false;
}

/// Test seam: unit tests disable disk writes to `.harness/settings.json`.
pub var persist_settings: bool = true;

/// Persist `"service_tier"` into `.harness/settings.json` alongside `saveThinkingSettings`.
pub fn persist(io: Io, gpa: Allocator, tier: Tier) bool {
    return persistAt(io, Io.Dir.cwd(), gpa, tier);
}

pub fn persistAt(io: Io, dir: Io.Dir, gpa: Allocator, tier: Tier) bool {
    dir.createDir(io, Approvals.settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (dir.readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (tier == .ultrafast) {
        root_obj.put(a, "service_tier", .{ .string = "ultrafast" }) catch return false;
    } else {
        _ = root_obj.orderedRemove("service_tier");
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = dir.createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

pub fn loadFromObject(root: *Agent, obj: std.json.ObjectMap) void {
    if (obj.get("service_tier")) |sv| if (sv == .string) if (parse(sv.string)) |tier| {
        apply(root, tier);
        return;
    };
    if (obj.get("fast")) |fv| if (fv == .bool) {
        apply(root, if (fv.bool) .fast else .standard);
    };
}

pub fn save(root: *Agent) void {
    if (!persist_settings) return;
    _ = @import("repl_glue.zig").saveThinkingSettings(root.io, root.gpa, root.reasoning, root.fast, root.ultracode_mode, root.show_thinking, root.ai_title);
    _ = persist(root.io, root.gpa, effective(root));
}

pub fn tryHandleCommand(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    const is_fast = std.mem.eql(u8, line, "/fast") or std.mem.startsWith(u8, line, "/fast ");
    const is_ultra = std.mem.eql(u8, line, "/ultrafast") or std.mem.startsWith(u8, line, "/ultrafast ");
    if (!is_fast and !is_ultra) return false;

    const cur = effective(root);
    const next: Tier = if (is_ultra) blk: {
        const arg = std.mem.trim(u8, line["/ultrafast".len..], " \t");
        if (arg.len == 0) break :blk if (cur == .ultrafast) .standard else .ultrafast;
        if (std.ascii.eqlIgnoreCase(arg, "on") or std.ascii.eqlIgnoreCase(arg, "true")) break :blk .ultrafast;
        if (std.ascii.eqlIgnoreCase(arg, "off") or std.ascii.eqlIgnoreCase(arg, "false") or std.ascii.eqlIgnoreCase(arg, "default")) break :blk .standard;
        try out.writeAll("usage: /ultrafast [on|off]\n");
        try out.flush();
        return true;
    } else blk: {
        const arg = std.mem.trim(u8, line["/fast".len..], " \t");
        if (arg.len == 0) break :blk if (cur == .standard) .fast else .standard;
        break :blk parse(arg) orelse {
            try out.writeAll("usage: /fast [on|off|fast|ultrafast|default]\n");
            try out.flush();
            return true;
        };
    };

    apply(root, next);
    save(root);
    const note: []const u8 = if (!supportsFast(root.provider.id))
        " (codex/chatgpt-new only — current model ignores it)"
    else if (next == .ultrafast and !supportsUltrafast(root.provider.id, root.provider.model))
        " (ultrafast applies on gpt-6.2-sol / gpt-6.2-astra; current model uses priority fast)"
    else
        "";
    if (next == .ultrafast) {
        try out.print("service tier: ultrafast{s}\n", .{note});
    } else {
        try out.print("fast mode: {s}{s}\n", .{ if (next == .fast) "on" else "off", note });
    }
    try out.flush();
    return true;
}

pub fn appliesTo(root: *const Agent, tier: Tier) bool {
    return supportsFast(root.provider.id) and (tier != .ultrafast or supportsUltrafast(root.provider.id, root.provider.model));
}

pub fn applyJson(root: *Agent, obj: std.json.ObjectMap) ?Tier {
    const next: Tier = if (obj.get("tier")) |tv|
        (if (tv == .string) (parse(tv.string) orelse return null) else .standard)
    else blk: {
        const on = if (obj.get("on")) |v| (if (v == .bool) v.bool else false) else false;
        break :blk if (on) .fast else .standard;
    };
    apply(root, next);
    save(root);
    return next;
}

test "service_tier wire values cover codex and chatgpt-new fast/ultrafast without leaking off-route" {
    try std.testing.expectEqualStrings("ultrafast", wireValue("codex", "gpt-6.2-sol", .ultrafast).?);
    try std.testing.expectEqualStrings("ultrafast", wireValue("codex", "gpt-6.2-astra", .ultrafast).?);
    try std.testing.expectEqualStrings("ultrafast", wireValue("chatgpt-new", "gpt-6.2-sol", .ultrafast).?);
    try std.testing.expectEqualStrings("ultrafast", wireValue("chatgpt-new", "gpt-6.2-astra", .ultrafast).?);
    try std.testing.expectEqualStrings("priority", wireValue("codex", "gpt-6.1-sol", .ultrafast).?);
    try std.testing.expectEqualStrings("priority", wireValue("chatgpt-new", "gpt-6.1-sol", .fast).?);
    try std.testing.expect(wireValue("codex", "gpt-6.2-sol", .standard) == null);
    try std.testing.expect(wireValue("openai", "gpt-6.2-sol", .ultrafast) == null);
    try std.testing.expect(wireValue("xai", "grok-4.7", .fast) == null);
    try std.testing.expect(wireValue("codegraff", "gpt-6.2-sol", .ultrafast) == null);
}

test "jsonAdvertisesUltrafast detects Codex service_tiers and additional_speed_tiers" {
    const a = std.testing.allocator;
    const with_tiers = try std.json.parseFromSlice(Value, a,
        \\{"slug":"gpt-6.2-sol","additional_speed_tiers":["fast","ultrafast"],"service_tiers":[{"id":"priority"},{"id":"ultrafast"}]}
    , .{});
    defer with_tiers.deinit();
    try std.testing.expect(jsonAdvertisesUltrafast(with_tiers.value.object));

    const fast_only = try std.json.parseFromSlice(Value, a,
        \\{"slug":"gpt-6.1-sol","additional_speed_tiers":["fast"],"service_tiers":[{"id":"priority"}]}
    , .{});
    defer fast_only.deinit();
    try std.testing.expect(!jsonAdvertisesUltrafast(fast_only.value.object));
}

test "Responses request body sends service_tier ultrafast on 6.2 sol/astra across codex and chatgpt-new" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{ "codex", "chatgpt-new" }) |pid| {
        for ([_][]const u8{ "gpt-6.2-sol", "gpt-6.2-astra" }) |mdl| {
            var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, pid, .responses, mdl);
            apply(&agent, .ultrafast);
            const body = try agent.buildBody(null, false, true, true);
            defer std.testing.allocator.free(body);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"service_tier\":\"ultrafast\"") != null);
        }
    }
    var older = try @import("agent_request_body_responses.zig").testAgentFor(a, "chatgpt-new", .responses, "gpt-6.1-sol");
    apply(&older, .ultrafast);
    const older_body = try older.buildBody(null, false, true, true);
    defer std.testing.allocator.free(older_body);
    try std.testing.expect(std.mem.indexOf(u8, older_body, "\"service_tier\":\"priority\"") != null);

    var api = try @import("agent_request_body_responses.zig").testAgentFor(a, "openai", .responses, "gpt-6.2-sol");
    apply(&api, .ultrafast);
    const api_body = try api.buildBody(null, false, true, true);
    defer std.testing.allocator.free(api_body);
    try std.testing.expect(std.mem.indexOf(u8, api_body, "service_tier") == null);
}

test "service_tier slash commands, persistence, and graff/models metadata" {
    const saved_persist = persist_settings;
    persist_settings = false;
    defer persist_settings = saved_persist;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, "codex", .responses, "gpt-6.2-astra");
    var out: Io.Writer.Allocating = .init(a);

    try std.testing.expect(try tryHandleCommand(&agent, "/ultrafast", &out.writer));
    try std.testing.expectEqual(Tier.ultrafast, effective(&agent));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "service tier: ultrafast") != null);

    out.clearRetainingCapacity();
    try std.testing.expect(try tryHandleCommand(&agent, "/ultrafast off", &out.writer));
    try std.testing.expectEqual(Tier.standard, effective(&agent));

    out.clearRetainingCapacity();
    try std.testing.expect(try tryHandleCommand(&agent, "/fast ultrafast", &out.writer));
    try std.testing.expectEqual(Tier.ultrafast, effective(&agent));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(persistAt(std.testing.io, tmp.dir, std.testing.allocator, .ultrafast));
    const saved = try tmp.dir.readFileAlloc(std.testing.io, Approvals.settings_path, a, .limited(64 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(Value, a, saved, .{});
    apply(&agent, .standard);
    loadFromObject(&agent, parsed.object);
    try std.testing.expectEqual(Tier.ultrafast, effective(&agent));

    // Verify graff/models exposes serviceTiers + ultrafastSupported on 6.2 sol/astra.
    var keys: @import("provider.zig").Keys = .{ .values = @splat(null) };
    var rpc_out: Io.Writer.Allocating = .init(a);
    var live: @import("acp_live_turn.zig").LiveTurn = .{ .root = &agent, .keys = &keys, .out = &rpc_out.writer };
    var d: @import("acp_engine.zig").Dispatch = .{
        .turn = undefined,
        .ctx = &live,
        .extra = @import("acp_models_rpc.zig").liveModels,
    };
    try @import("acp_engine.zig").handleLine(&d, a, &rpc_out.writer, "{\"id\":1,\"method\":\"graff/models\"}");
    const resp = try std.json.parseFromSliceLeaky(Value, a, rpc_out.written(), .{});
    const cur = resp.object.get("result").?.object.get("current").?.object;
    try std.testing.expectEqualStrings("ultrafast", cur.get("serviceTier").?.string);
    try std.testing.expect(cur.get("ultrafastSupported").?.bool);
    var saw_codex_sol = false;
    var saw_chatgpt_astra = false;
    for (resp.object.get("result").?.object.get("models").?.array.items) |row| {
        const obj = row.object;
        const p = obj.get("provider").?.string;
        const n = obj.get("name").?.string;
        if (std.mem.eql(u8, p, "codex") and std.mem.eql(u8, n, "gpt-6.2-sol")) {
            saw_codex_sol = true;
            try std.testing.expect(obj.get("ultrafastSupported").?.bool);
            try std.testing.expectEqual(@as(usize, 2), obj.get("serviceTiers").?.array.items.len);
        }
        if (std.mem.eql(u8, p, "chatgpt-new") and std.mem.eql(u8, n, "gpt-6.2-astra")) {
            saw_chatgpt_astra = true;
            try std.testing.expect(obj.get("ultrafastSupported").?.bool);
            try std.testing.expectEqual(@as(usize, 2), obj.get("serviceTiers").?.array.items.len);
        }
    }
    try std.testing.expect(saw_codex_sol and saw_chatgpt_astra);
}
