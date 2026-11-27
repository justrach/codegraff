//! The line a parent model reads when a `subagent` model or tier pin was not
//! honoured.
//!
//! subagent_pin keeps an ignored pin SOFT: the spawn still runs, and
//! Outcome.describe names the reason for the trace. The trace is not what the
//! parent model or the user reads, though. A parent that asked for a stronger
//! worker and got the cheapest ladder rung had nothing in its tool result to
//! say so, and spent calls finding out. This module renders one bracketed line
//! for the top of the tool result: what was ignored and why, the model that
//! actually ran, and how to get what was asked for (for a name that did not
//! resolve, the exact catalogue ids it could have meant).
//!
//! It is rendered once, when the seat is chosen, into a fixed buffer carried
//! by value on vision_ask.Ask: a background job's report and its spawn receipt
//! read the same text with no allocation or lifetime to manage.

const std = @import("std");

const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const pin_mod = @import("subagent_pin.zig");
const Outcome = pin_mod.Outcome;
const route_trace = @import("route_trace.zig");
const selection = @import("subagent_selection.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const util = @import("util.zig");

pub const max_candidates = 6;
const query_cap = 64;
const name_cap = 64;
const cap = 1024;

pub const Note = struct {
    buf: [cap]u8 = undefined,
    len: u16 = 0,

    pub fn text(self: *const Note) []const u8 {
        return self.buf[0..self.len];
    }
};

/// The outcomes where a caller asked for a model or tier and did not get it.
pub fn ignored(o: Outcome) bool {
    return switch (o) {
        .unknown_model, .unknown_tier, .no_ladder, .no_rung, .rung_pricier, .cross_provider_unconsented, .no_login => true,
        .none, .pinned, .same, .sub_routed, .model_sub_routed => false,
    };
}

/// Where a candidate list came from: names the pin matched (it was
/// ambiguous), names sharing a word with it, or the provider's catalogue.
pub const Kind = enum { matched, related, catalogue };

pub const Candidates = struct {
    names: [max_candidates][]const u8 = undefined,
    n: usize = 0,
    total: usize = 0,
    kind: Kind = .catalogue,

    fn add(self: *Candidates, name: []const u8) void {
        if (self.n < max_candidates) {
            self.names[self.n] = name;
            self.n += 1;
        }
        self.total += 1;
    }
};

/// Catalogue ids on `provider_id` a parent could re-spawn with instead of
/// `query`, at most `max_candidates` of them, in catalogue order.
pub fn candidates(provider_id: []const u8, query: []const u8) Candidates {
    var out: Candidates = .{ .kind = .matched };
    for (pricing.models()) |m| {
        if (!std.mem.eql(u8, m.provider, provider_id)) continue;
        if (pricing.looseModelMatch(m.provider, m.name, query) != .none) out.add(m.name);
    }
    if (out.total > 0) return out;
    var word_buf: [32]u8 = undefined;
    if (relatedWord(provider_id, query, &word_buf)) |word| {
        out = .{ .kind = .related };
        for (pricing.models()) |m| {
            if (std.mem.eql(u8, m.provider, provider_id) and containsWord(m.name, word)) out.add(m.name);
        }
        return out;
    }
    out = .{ .kind = .catalogue };
    for (pricing.models()) |m| if (std.mem.eql(u8, m.provider, provider_id)) out.add(m.name);
    return out;
}

fn containsWord(name: []const u8, word: []const u8) bool {
    var nb: [128]u8 = undefined;
    return std.mem.indexOf(u8, pricing.looseModelKey(&nb, name), word) != null;
}

/// The word of `query` (three or more letters, not the provider's own id)
/// that the fewest rows on `provider_id` contain, but at least one: for
/// "opus 9.9" that is "opus", so the opus generations are offered rather than
/// the whole catalogue.
fn relatedWord(provider_id: []const u8, query: []const u8, buf: *[32]u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = std.math.maxInt(usize);
    var it = std.mem.tokenizeAny(u8, query, " -_./");
    while (it.next()) |tok| {
        if (tok.len < 3 or tok.len > 32 or std.ascii.eqlIgnoreCase(tok, provider_id)) continue;
        var letters: usize = 0;
        for (tok) |c| {
            if (std.ascii.isAlphabetic(c)) letters += 1;
        }
        if (letters < 3) continue;
        var count: usize = 0;
        var lower: [32]u8 = undefined;
        const word = std.ascii.lowerString(&lower, tok);
        for (pricing.models()) |m| {
            if (std.mem.eql(u8, m.provider, provider_id) and containsWord(m.name, word)) count += 1;
        }
        if (count == 0 or count >= best_count) continue;
        best_count = count;
        best = tok;
    }
    const tok = best orelse return null;
    return std.ascii.lowerString(buf[0..tok.len], tok);
}

/// The provider a model pin is resolved against: the one its
/// `<provider>/` prefix names, else the child's own.
fn pinProvider(base: Provider, query: []const u8) struct { id: []const u8, name: []const u8 } {
    if (std.mem.indexOfScalar(u8, query, '/')) |slash| {
        if (provider_mod.specFor(query[0..slash])) |spec| return .{ .id = spec.id, .name = query[slash + 1 ..] };
    }
    return .{ .id = base.id, .name = query };
}

/// One line, no control bytes: a model-authored name must not be able to
/// break the note into several lines or smuggle a terminal escape.
fn clean(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
}

fn writeList(w: *std.Io.Writer, c: Candidates) !void {
    for (c.names[0..c.n], 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(util.utf8Prefix(name, name_cap));
    }
    if (c.total > c.n) try w.print(" (+{d} more; /models lists them)", .{c.total - c.n});
}

/// What the spawn asked for, read back off the call the way subagent_pin
/// read it (a persona's pin counts as asked).
pub const Request = struct {
    model: ?[]const u8 = null,
    tier: ?[]const u8 = null,
};

pub fn requestOf(args: std.json.ObjectMap) Request {
    const pin = pin_mod.requested(args);
    var out: Request = .{ .model = pin.model };
    if (pin.tier) |t| out.tier = t.label();
    if (pin.bad_tier) if (args.get("tier")) |v| if (v == .string) {
        out.tier = std.mem.trim(u8, v.string, " \t\r\n");
    };
    return out;
}

/// The route trace's record of the same request, bounded for one JSONL line.
pub fn traced(args: std.json.ObjectMap, outcome: Outcome) route_trace.Requested {
    const req = requestOf(args);
    return .{
        .model = util.utf8Prefix(req.model orelse "", query_cap),
        .tier = util.utf8Prefix(req.tier orelse "", query_cap),
        .outcome = if (outcome == .none) "" else @tagName(outcome),
    };
}

/// The note for one spawn, or an empty Note when the pin was honoured or
/// none was asked for. `actual` is the seat the child really runs on.
pub fn build(args: std.json.ObjectMap, outcome: Outcome, base: Provider, actual: Provider) Note {
    var note: Note = .{};
    if (!ignored(outcome)) return note;
    var w: std.Io.Writer = .fixed(&note.buf);
    render(&w, requestOf(args), outcome, base, actual) catch {
        // Bounded inputs make this unreachable in practice; never lose the
        // fact that the pin was ignored.
        w = .fixed(&note.buf);
        w.print("[{s}; this agent ran on {s} ({s})]", .{ outcome.describe(), util.utf8Prefix(actual.model, name_cap), util.utf8Prefix(actual.id, name_cap) }) catch return note;
    };
    note.len = @intCast(w.buffered().len);
    return note;
}

fn render(w: *std.Io.Writer, req: Request, outcome: Outcome, base: Provider, actual: Provider) !void {
    const ran = .{ util.utf8Prefix(actual.model, name_cap), util.utf8Prefix(actual.id, name_cap) };
    if (req.model) |query| {
        const target = pinProvider(base, query);
        try w.writeAll("[model pin \"");
        try clean(w, util.utf8Prefix(query, query_cap));
        try w.writeAll("\" ignored: ");
        switch (outcome) {
            .cross_provider_unconsented => {
                try w.print("it names another provider and this session has not allowed workers there; this agent ran on {s} ({s}) instead. Start graff with --allow-cross-provider-subagents to let workers send prompts and code there.]", ran);
                return;
            },
            .no_login => {
                try w.print("there is no key or login for {s}; this agent ran on {s} ({s}) instead. Log in to {s} or set its API key, then re-spawn.]", .{ target.id, ran[0], ran[1], target.id });
                return;
            },
            else => {},
        }
        const c = candidates(target.id, target.name);
        if (c.kind == .matched and c.total > 1)
            try w.print("it matches {d} models on {s}, so it names none of them", .{ c.total, target.id })
        else
            try w.print("{s} serves no model by that name", .{target.id});
        try w.print("; this agent ran on {s} ({s}) instead. ", ran);
        if (c.n == 0) {
            try w.print("{s} has no catalogued models; run `graff models refresh`, then re-spawn with an exact id.]", .{target.id});
            return;
        }
        try w.writeAll(if (c.kind == .catalogue) "Re-spawn with model set to an exact id, e.g. " else "Re-spawn with model set to one of: ");
        try writeList(w, c);
        try w.writeAll(".]");
        return;
    }
    try w.writeAll("[tier pin \"");
    try clean(w, util.utf8Prefix(req.tier orelse "", query_cap));
    try w.writeAll("\" ignored: ");
    const tier = if (req.tier) |t| tier_ladder.Tier.parse(t) else null;
    switch (outcome) {
        .unknown_tier => try w.print("tiers are frontier, mid or small; this agent ran on {s} ({s}) instead. Re-spawn with tier frontier, mid or small, or name a model.]", ran),
        .no_ladder, .no_rung, .unknown_model => {
            if (outcome == .no_ladder)
                try w.print("{s} has no tier ladder", .{base.id})
            else if (outcome == .no_rung)
                try w.print("{s}'s ladder has no {s} model", .{ base.id, if (tier) |t| t.label() else "such" })
            else
                try w.print("that rung is not in {s}'s live catalogue", .{base.id});
            try w.print("; this agent ran on {s} ({s}) instead. ", ran);
            const c = candidates(base.id, "");
            if (c.n == 0) {
                try w.writeAll("Name a model by its exact id instead.]");
                return;
            }
            try w.writeAll("Name a model instead, e.g. ");
            try writeList(w, c);
            try w.writeAll(".]");
        },
        .rung_pricier => {
            const rung = rungModel(base, tier) orelse "that model";
            try w.print("the {s} model {s} costs more than this agent's model, and a tier never raises cost; this agent ran on {s} ({s}) instead. To escalate, re-spawn with model \"{s}\".]", .{ if (tier) |t| t.label() else "requested", rung, ran[0], ran[1], rung });
        },
        else => try w.print("{s}; this agent ran on {s} ({s}) instead.]", .{ outcome.describe(), ran[0], ran[1] }),
    }
}

fn rungModel(base: Provider, tier: ?tier_ladder.Tier) ?[]const u8 {
    const t = tier orelse return null;
    const ladder = tier_ladder.forModel(base.id, base.model) orelse return null;
    const rung = ladder.modelFor(t) orelse return null;
    return selection.liveLadderModel(base.id, rung) orelse rung;
}
