//! User-defined route sets: named lanes of seats the user curates across
//! providers — "our own sets". A set answers two questions at a glance: what
//! would THIS crew cost per lane, and which seat wins each lane RIGHT NOW
//! (flat-rate login first, then the cheapest keyed price; unkeyed seats are
//! shown but never picked). Prices come from the same table + models.dev
//! overlay the cost tally uses, so the set tracks reality as catalogs and
//! prices refresh — fireworks' live-discovered rows included.
//!
//! File: ~/.codegraff/routes.json (per user, next to the keys and model
//! caches). /routes views; /routes add appends an entry, creating the set on
//! first use. Editing the JSON directly is equally valid — it is data, not
//! machinery.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");

const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;

pub const Lane = enum { frontier, mid, small };

pub const Entry = struct {
    lane: Lane = .mid,
    provider: []const u8 = "",
    model: []const u8 = "",
};

pub const Set = struct {
    name: []const u8 = "",
    entries: []Entry = &.{},
};

const SetJson = struct {
    lane: []const u8 = "mid",
    provider: []const u8 = "",
    model: []const u8 = "",
};
const NamedJson = struct {
    name: []const u8 = "",
    entries: []SetJson = &.{},
};
const Doc = struct {
    sets: []NamedJson = &.{},
};

pub fn path(arena: Allocator, home: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/.codegraff/routes.json", .{home}) catch "";
}

fn laneFor(name: []const u8) Lane {
    if (std.mem.eql(u8, name, "frontier")) return .frontier;
    if (std.mem.eql(u8, name, "small")) return .small;
    return .mid;
}

pub fn laneName(lane: Lane) []const u8 {
    return switch (lane) {
        .frontier => "frontier",
        .mid => "mid",
        .small => "small",
    };
}

/// Split "provider/model" on the FIRST slash only — fireworks model ids are
/// resource paths ("accounts/fireworks/models/x") and carry slashes of their
/// own, so the provider is always the first component.
pub fn splitSeat(spec: []const u8) ?struct { provider: []const u8, model: []const u8 } {
    const i = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    if (i == 0 or i + 1 >= spec.len) return null;
    return .{ .provider = spec[0..i], .model = spec[i + 1 ..] };
}

pub fn load(io: Io, arena: Allocator, home: []const u8) []Set {
    const text = Io.Dir.cwd().readFileAlloc(io, path(arena, home), arena, .limited(256 * 1024)) catch return &.{};
    const doc = std.json.parseFromSliceLeaky(Doc, arena, text, .{ .ignore_unknown_fields = true }) catch return &.{};
    var sets: std.ArrayList(Set) = .empty;
    for (doc.sets) |s| {
        var entries: std.ArrayList(Entry) = .empty;
        for (s.entries) |e| {
            if (e.provider.len == 0 or e.model.len == 0) continue;
            entries.append(arena, .{ .lane = laneFor(e.lane), .provider = e.provider, .model = e.model }) catch break;
        }
        sets.append(arena, .{ .name = s.name, .entries = entries.items }) catch break;
    }
    return sets.items;
}

/// Append an entry to a set (creating it on first use) and persist. Dedupes
/// on provider+model+lane so a repeated add is a no-op, not a second row.
pub fn addEntry(io: Io, arena: Allocator, home: []const u8, set_name: []const u8, lane: Lane, provider_id: []const u8, model: []const u8) !void {
    var named: std.ArrayList(NamedJson) = .empty;
    const existing = load(io, arena, home);
    var found_set = false;
    var found_entry = false;
    for (existing) |s| {
        var entries: std.ArrayList(SetJson) = .empty;
        for (s.entries) |e| {
            try entries.append(arena, .{ .lane = laneName(e.lane), .provider = e.provider, .model = e.model });
            if (std.mem.eql(u8, s.name, set_name) and e.lane == lane and
                std.mem.eql(u8, e.provider, provider_id) and std.mem.eql(u8, e.model, model)) found_entry = true;
        }
        if (std.mem.eql(u8, s.name, set_name)) {
            found_set = true;
            if (!found_entry) try entries.append(arena, .{ .lane = laneName(lane), .provider = provider_id, .model = model });
        }
        try named.append(arena, .{ .name = s.name, .entries = entries.items });
    }
    if (!found_set) {
        const entries = try arena.alloc(SetJson, 1);
        entries[0] = .{ .lane = laneName(lane), .provider = provider_id, .model = model };
        try named.append(arena, .{ .name = set_name, .entries = entries });
    }
    if (found_set and found_entry) return; // nothing to write
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.write(Doc{ .sets = named.items });
    if (std.fs.path.dirname(path(arena, home))) |parent| Io.Dir.cwd().createDirPath(io, parent) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path(arena, home), .data = aw.writer.buffered() });
}

/// The seat that wins a lane right now: a keyed flat-rate login beats every
/// metered seat (it is free at the margin, billing.zig's rule), then the
/// cheapest keyed seat by list price, then keyed-but-unpriced. Unkeyed seats
/// are display-only — the report shows them, the pick never lands on them.
pub fn winner(entries: []const Entry, keys: Keys) ?Entry {
    var best: ?Entry = null;
    var best_score: f64 = std.math.inf(f64);
    for (entries) |e| {
        const key = keys.get(e.provider) orelse continue;
        _ = key;
        const source = keys.source(e.provider);
        const score: f64 = switch (billing.forSeat(e.provider, e.model, source)) {
            .sub => -1,
            .priced => blk: {
                const p = pricing.priceFor(e.model) orelse break :blk std.math.inf(f64);
                break :blk p.in + p.out;
            },
            .unpriced => std.math.inf(f64) - 1,
        };
        if (best == null or score < best_score) {
            best = e;
            best_score = score;
        }
    }
    return best;
}

fn billingLabel(entry: Entry, keys: Keys) []const u8 {
    if (keys.get(entry.provider) == null) return "no key";
    return switch (billing.forSeat(entry.provider, entry.model, keys.source(entry.provider))) {
        .sub => "flat-rate",
        .priced => "metered",
        .unpriced => "unpriced",
    };
}

fn renderSet(root: *Agent, keys: Keys, arena: Allocator, out: *Io.Writer, set: Set) !void {
    try out.print("{s}\n", .{set.name});
    const lanes = [_]Lane{ .frontier, .mid, .small };
    for (lanes) |lane| {
        var lane_entries: std.ArrayList(Entry) = .empty;
        for (set.entries) |e| {
            if (e.lane == lane) lane_entries.append(arena, e) catch {};
        }
        if (lane_entries.items.len == 0) continue;
        const win = winner(lane_entries.items, keys);
        try out.print("  {s}:\n", .{laneName(lane)});
        for (lane_entries.items) |e| {
            const is_win = if (win) |w| std.mem.eql(u8, w.provider, e.provider) and std.mem.eql(u8, w.model, e.model) else false;
            const price = pricing.priceFor(e.model);
            const ctx = pricing.contextFor(e.provider, e.model);
            _ = root;
            try out.print("    {s} {s}/{s} · {s} · {d}k ctx", .{
                if (is_win) "★" else " ",
                e.provider,
                e.model,
                billingLabel(e, keys),
                ctx / 1000,
            });
            if (price) |p| try out.print(" · ${d:.2}/${d:.2} per MTok", .{ p.in, p.out });
            try out.writeAll("\n");
        }
    }
}

/// /routes [<set>] — view · /routes add <set> <lane> <provider/model> — add.
pub fn command(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/routes".len..], " \t");
    if (std.mem.startsWith(u8, rest, "add ")) {
        var it = std.mem.tokenizeAny(u8, rest[4..], " \t");
        const set_name = it.next() orelse "";
        const lane_name = it.next() orelse "";
        const seat = if (it.index < rest.len - 4) std.mem.trim(u8, rest[4 + it.index ..], " \t") else "";
        const seat_parts = splitSeat(std.mem.trim(u8, seat, " \t")) orelse {
            try out.writeAll("usage: /routes add <set> <frontier|mid|small> <provider/model>\n");
            try out.flush();
            return true;
        };
        if (set_name.len == 0 or lane_name.len == 0) {
            try out.writeAll("usage: /routes add <set> <frontier|mid|small> <provider/model>\n");
            try out.flush();
            return true;
        }
        addEntry(root.io, arena, root.home, set_name, laneFor(lane_name), seat_parts.provider, seat_parts.model) catch |err| {
            try out.print("could not save the set: {t}\n", .{err});
            try out.flush();
            return true;
        };
        try out.print("added {s}/{s} to {s} ({s}) — /routes {s} to see it\n", .{ seat_parts.provider, seat_parts.model, set_name, laneName(laneFor(lane_name)), set_name });
        try out.flush();
        return true;
    }
    const sets = load(root.io, arena, root.home);
    if (sets.len == 0) {
        try out.writeAll("no route sets yet — /routes add <set> <frontier|mid|small> <provider/model> (file: ~/.codegraff/routes.json)\n");
        try out.flush();
        return true;
    }
    var shown: usize = 0;
    for (sets) |s| {
        if (rest.len > 0 and !std.mem.eql(u8, s.name, rest)) continue;
        try renderSet(root, keys.*, arena, out, s);
        shown += 1;
    }
    if (shown == 0) try out.print("no set named \"{s}\" — /routes lists them all\n", .{rest});
    try out.flush();
    return true;
}

test "splitSeat keeps fireworks resource-path model ids intact" {
    const plain = splitSeat("kimi/k3").?;
    try std.testing.expectEqualStrings("kimi", plain.provider);
    try std.testing.expectEqualStrings("k3", plain.model);
    const fw = splitSeat("fireworks/accounts/fireworks/models/deepseek-v4-flash").?;
    try std.testing.expectEqualStrings("fireworks", fw.provider);
    try std.testing.expectEqualStrings("accounts/fireworks/models/deepseek-v4-flash", fw.model);
    try std.testing.expect(splitSeat("noseparator") == null);
}

test "winner: flat-rate keyed beats priced keyed; unkeyed never picked" {
    var keys: Keys = .{ .values = @splat(null) };
    _ = keys.set("kimi", "tok", .login);
    _ = keys.set("deepseek", "tok", .environment);
    const entries = [_]Entry{
        .{ .provider = "deepseek", .model = "deepseek-v4-flash" }, // priced keyed
        .{ .provider = "anthropic", .model = "claude-opus-5" }, // unkeyed: display-only
        .{ .provider = "kimi", .model = "k3" }, // flat-rate keyed
    };
    const win = winner(&entries, keys).?;
    try std.testing.expectEqualStrings("kimi", win.provider);
    // With the flat-rate seat removed, the priced keyed seat takes the lane.
    const win2 = winner(entries[0..2], keys).?;
    try std.testing.expectEqualStrings("deepseek-v4-flash", win2.model);
}

test "winner picks the cheaper of two keyed priced seats" {
    var keys: Keys = .{ .values = @splat(null) };
    _ = keys.set("deepseek", "tok", .environment);
    const cheap = Entry{ .provider = "deepseek", .model = "deepseek-v4-flash" };
    const entries = [_]Entry{ cheap, .{ .provider = "deepseek", .model = "deepseek-v4-pro" } };
    const win = winner(&entries, keys).?;
    try std.testing.expectEqualStrings(cheap.model, win.model);
}
