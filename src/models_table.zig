//! Column layout of the line-REPL `/models` table (#560).
//!
//! One place, so the header and the rows cannot drift apart and so the
//! 80-column budget is something a test can hold us to. The `cost` column is
//! the point: `/models` used to say WHICH provider serves a model but not what
//! that seat costs, and the TUI picker did not even say the provider — the two
//! surfaces now print the same provider and the same badge. Row order is the
//! shared election (`models_rank.zig`): signed-in plan, then local, then
//! credits, then api.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const billing = @import("billing.zig");
const models_rank = @import("models_rank");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");

pub const header = "model                    ctx      compact@ provider   cost     key vision\n";
const row_fmt = "{s:<24} {d:>5}k   {d:>5}k   {s:<10} {s:<7}  {s}   {s}{s}\n";

pub const Row = struct {
    name: []const u8,
    /// Context window in tokens; the table prints it, and 80% of it, in k.
    context: u64,
    provider: []const u8,
    /// `billing.CostClass.badge()` — plan / credits / api / local.
    cost: []const u8,
    has_key: bool = false,
    vision: bool = false,
    current: bool = false,
};

/// Catalog rows in election order. The TUI overlay ranks the same way
/// through `models_rank.electionRank`; this is the dump that has to agree.
pub fn writeRows(
    out: *Io.Writer,
    alloc: Allocator,
    models: []const pricing.ModelInfo,
    keys: provider_mod.Keys,
    current_model: []const u8,
    current_provider: []const u8,
    is_vision: *const fn ([]const u8) bool,
) !void {
    const ranked = try alloc.alloc(models_rank.Scored, models.len);
    defer alloc.free(ranked);
    for (models, 0..) |m, i| {
        ranked[i] = .{
            .idx = i,
            .score = models_rank.electionRank(
                keys.get(m.provider) != null,
                billing.costFor(m.provider, keys.source(m.provider)),
            ),
        };
    }
    std.mem.sort(models_rank.Scored, ranked, {}, models_rank.scoredLess);
    for (ranked) |r| {
        const m = models[r.idx];
        try writeRow(out, .{
            .name = m.name,
            .context = pricing.contextFor(m.provider, m.name),
            .provider = m.provider,
            .cost = billing.costFor(m.provider, keys.source(m.provider)).badge(),
            .has_key = keys.get(m.provider) != null,
            .vision = is_vision(m.name),
            .current = std.mem.eql(u8, m.name, current_model) and std.mem.eql(u8, m.provider, current_provider),
        });
    }
}

pub fn writeRow(out: *Io.Writer, r: Row) !void {
    try out.print(row_fmt, .{
        r.name,
        r.context / 1000,
        r.context / 10 * 8 / 1000,
        r.provider,
        r.cost,
        if (r.has_key) "✓" else "—",
        if (r.vision) "✓" else "—",
        if (r.current) "  ← current" else "",
    });
}

/// Terminal cells, not bytes: ✓ and — are three bytes and one column each, so
/// a byte count would report this table as far wider than it prints.
fn cells(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Cell column at which `needle` starts in `line`, or null.
fn columnOf(line: []const u8, needle: []const u8) ?usize {
    const at = std.mem.indexOf(u8, line, needle) orelse return null;
    return cells(line[0..at]);
}

fn sample(buf: []u8, r: Row) ![]const u8 {
    var w: Io.Writer = .fixed(buf);
    try writeRow(&w, r);
    const out = w.buffered();
    return if (std.mem.endsWith(u8, out, "\n")) out[0 .. out.len - 1] else out;
}

test "header labels sit over the columns their values land in" {
    // The regression this blocks is silent: change one width and the table
    // still prints, just with `cost` sitting over the provider ids.
    var buf: [256]u8 = undefined;
    const line = try sample(&buf, .{
        .name = "claude-opus-4-8",
        .context = 200_000,
        .provider = "anthropic",
        .cost = "api",
        .has_key = true,
        .vision = true,
    });
    for ([_][]const u8{ "provider", "cost" }) |label| {
        const want = columnOf(header, label) orelse return error.MissingLabel;
        const got = switch (label[0]) {
            'p' => columnOf(line, "anthropic"),
            else => columnOf(line, "api"),
        } orelse return error.MissingValue;
        try std.testing.expectEqual(want, got);
    }
    // key and vision are single glyphs; they must land inside their labels.
    const key_at = cells(line[0..std.mem.indexOf(u8, line, "✓").?]);
    try std.testing.expectEqual(columnOf(header, "key").?, key_at);
}

test "a row with the current marker still fits 80 columns" {
    var buf: [256]u8 = undefined;
    const line = try sample(&buf, .{
        .name = "gpt-5.6-sol",
        .context = 272_000,
        .provider = "codegraff",
        .cost = "credits",
        .has_key = true,
        .vision = true,
        .current = true,
    });
    try std.testing.expect(cells(line) <= 80);
    try std.testing.expect(cells(header) <= 80);
    try std.testing.expect(std.mem.endsWith(u8, line, "← current"));
    try std.testing.expect(std.mem.indexOf(u8, line, "credits") != null);
}

test "the compact@ column is 80% of the context window" {
    var buf: [256]u8 = undefined;
    const line = try sample(&buf, .{ .name = "m", .context = 200_000, .provider = "p", .cost = "api" });
    try std.testing.expect(std.mem.indexOf(u8, line, "200k") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "160k") != null);
}

test "a keyless row is marked, not dropped" {
    var buf: [256]u8 = undefined;
    const line = try sample(&buf, .{ .name = "m", .context = 1000, .provider = "fugu", .cost = "api" });
    try std.testing.expect(std.mem.indexOf(u8, line, "fugu") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "—") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "✓") == null);
}

test "electionRank: a signed-in plan outranks credits and a metered key" {
    const rank = models_rank.electionRank;
    try std.testing.expect(rank(true, .plan) > rank(true, .local));
    try std.testing.expect(rank(true, .local) > rank(true, .credits));
    try std.testing.expect(rank(true, .credits) > rank(true, .api));
    // Unsigned Codex is a map entry; keyed Codegraff is a seat.
    try std.testing.expect(rank(true, .credits) > rank(false, .plan));
}

test "writeRows puts a signed-in Codex plan above Codegraff credits" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    _ = keys.set("codex", "tok", .login);
    _ = keys.set("codegraff", "cg", .login);
    const models = [_]pricing.ModelInfo{
        .{ .provider = "codegraff", .name = "gpt-5.6", .context = 200_000 },
        .{ .provider = "codex", .name = "gpt-5.6", .context = 200_000 },
    };
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeRows(&w, std.testing.allocator, &models, keys, "", "", struct {
        fn v(_: []const u8) bool {
            return false;
        }
    }.v);
    const out = w.buffered();
    const plan = std.mem.indexOf(u8, out, "codex") orelse return error.MissingPlan;
    const credits = std.mem.indexOf(u8, out, "codegraff") orelse return error.MissingCredits;
    try std.testing.expect(plan < credits);
}
