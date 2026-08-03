//! #376 — rung-stratified fitness folding over the local DGM archive.
//!
//! `/agents promote` (fleet.promoteAgents) is the one CROSS-RUN comparison of
//! prompt genomes the harness makes locally: for each MAP-Elites niche it
//! pools every `kind:"score"` row filed under a genome's fingerprint, means
//! them, and crowns the highest. Until #376 that pooling ignored WHICH model
//! produced each score, which was safe only because #290 froze the model
//! inside a scored phase — a genome could not have been measured on a
//! different rung than its rival.
//!
//! #376 lifts that freeze one level up (route_phase.zig seats a whole phase
//! at once), so two genomes in the same niche CAN come from runs that sat on
//! different rungs. Pooling them would credit the cheaper/stronger model's
//! advantage to the prompt — the exact attribution error #290 exists to
//! prevent. This module is the other half of that trade: it ranks genomes
//! only against genomes measured in the SAME stratum, i.e. on the same
//! resolved model (route_policy.stratumOf).
//!
//! WHICH STRATUM SPEAKS FOR A NICHE. The one that is actually a comparison:
//! most distinct genomes ranked, then most observations behind the winner,
//! then first seen. A stratum with a single genome is not evidence that its
//! prompt is better than anything, so it only wins a niche nobody else
//! measured.
//!
//! PRE-#376 ROWS. A score row that names no model — everything written
//! before #372's self-describing rows, and mainloop /score's, which never
//! recorded one — folds into the `unknown` stratum and is ranked only against
//! other unknowns. It is never merged into a measured stratum: an unrecorded
//! model is missing information, not agreement.

const std = @import("std");
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const policy = @import("route_policy.zig");

/// One niche's promotable winner: the best genome inside the best-evidenced
/// stratum, plus the stratum it was measured in (so the persona file can say
/// what its score actually means).
pub const Champion = struct {
    niche: []const u8,
    stratum: []const u8,
    sha: []const u8,
    text: []const u8,
    mean: f64 = 0,
    /// Observations behind THIS genome in that stratum.
    n: u32 = 0,
    /// Distinct genomes ranked in that stratum — 1 means "no comparison was
    /// available", which is why the stratum tie-break prefers a bigger field.
    rivals: u32 = 0,
};

/// What the archive knows about one prompt fingerprint, independent of the
/// model it ran on: its captured text and its MAP-Elites niche.
const Genome = struct { sha: []const u8, text: []const u8 = "", niche: []const u8 = "" };

/// Pooled score for one (genome, stratum) pair — the unit that may be meaned.
const Obs = struct { sha: []const u8, stratum: []const u8, sum: f64 = 0, n: u32 = 0 };

/// Per-(niche, stratum) leader, built in one pass over `Obs`.
const Group = struct {
    niche: []const u8,
    stratum: []const u8,
    sha: []const u8 = "",
    text: []const u8 = "",
    mean: f64 = 0,
    n: u32 = 0,
    rivals: u32 = 0,
};

fn genomeAt(a: Allocator, list: *std.ArrayList(Genome), sha: []const u8) *Genome {
    for (list.items) |*g| if (std.mem.eql(u8, g.sha, sha)) return g;
    list.append(a, .{ .sha = a.dupe(u8, sha) catch sha }) catch {};
    return &list.items[list.items.len - 1];
}

fn obsAt(a: Allocator, list: *std.ArrayList(Obs), sha: []const u8, stratum: []const u8) *Obs {
    for (list.items) |*o| {
        if (std.mem.eql(u8, o.sha, sha) and std.mem.eql(u8, o.stratum, stratum)) return o;
    }
    list.append(a, .{ .sha = a.dupe(u8, sha) catch sha, .stratum = a.dupe(u8, stratum) catch stratum }) catch {};
    return &list.items[list.items.len - 1];
}

fn groupAt(a: Allocator, list: *std.ArrayList(Group), niche: []const u8, stratum: []const u8) *Group {
    for (list.items) |*g| {
        if (std.mem.eql(u8, g.niche, niche) and std.mem.eql(u8, g.stratum, stratum)) return g;
    }
    list.append(a, .{ .niche = niche, .stratum = stratum }) catch {};
    return &list.items[list.items.len - 1];
}

/// A stratum outranks another for the same niche when it ranked more distinct
/// genomes (a real tournament beats a walkover), then on the evidence behind
/// its winner. Deliberately NOT on the winning mean: a lucky single run on a
/// stronger model must not outrank a measured field on a weaker one — that is
/// the confound this module exists to keep out.
fn betterStratum(a: Group, b: Group) bool {
    if (a.rivals != b.rivals) return a.rivals > b.rivals;
    return a.n > b.n;
}

/// Fold `archive` (concatenated .graff/trajectories JSONL) into one champion
/// per niche. Genome text comes from `kind:"prompt"` rows, scores from
/// `kind:"score"` rows stratified by their `model` column, and the niche from
/// any other row that names one — the same three sources fleet.promoteAgents
/// read before #376, with the score axis split by stratum.
pub fn champions(arena: Allocator, archive: []const u8) []Champion {
    var genomes: std.ArrayList(Genome) = .empty;
    var obs: std.ArrayList(Obs) = .empty;
    var it = std.mem.splitScalar(u8, archive, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t\r");
        if (t.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, t, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const o = v.object;
        const kind = strFieldObj(o, "kind") orelse continue;
        const sha = strFieldObj(o, "prompt_sha") orelse "";
        if (sha.len == 0) continue;
        if (std.mem.eql(u8, kind, "prompt")) {
            if (strFieldObj(o, "text")) |txt| genomeAt(arena, &genomes, sha).text = arena.dupe(u8, txt) catch "";
        } else if (std.mem.eql(u8, kind, "score")) {
            const sv = o.get("score") orelse continue;
            const val: f64 = switch (sv) {
                .float => sv.float,
                .integer => @floatFromInt(sv.integer),
                else => continue,
            };
            const slot = obsAt(arena, &obs, sha, policy.stratumOf(strFieldObj(o, "model") orelse ""));
            slot.sum += val;
            slot.n += 1;
        } else if (strFieldObj(o, "niche")) |nz| {
            if (nz.len > 0) genomeAt(arena, &genomes, sha).niche = arena.dupe(u8, nz) catch "";
        }
    }

    // Pass A — the leader of every (niche, stratum) pair. A genome with no
    // captured text is unpromotable (nothing to write into the persona file)
    // and an uncelled one has no niche to promote into, exactly as before.
    var groups: std.ArrayList(Group) = .empty;
    for (obs.items) |ob| {
        if (ob.n == 0) continue;
        const g = for (genomes.items) |*x| {
            if (std.mem.eql(u8, x.sha, ob.sha)) break x;
        } else continue;
        if (g.text.len == 0 or g.niche.len == 0) continue;
        const mean = ob.sum / @as(f64, @floatFromInt(ob.n));
        const slot = groupAt(arena, &groups, g.niche, ob.stratum);
        slot.rivals += 1;
        if (slot.sha.len == 0 or mean > slot.mean) {
            slot.sha = ob.sha;
            slot.text = g.text;
            slot.mean = mean;
            slot.n = ob.n;
        }
    }

    // Pass B — one stratum per niche, and with it one champion.
    var out: std.ArrayList(Champion) = .empty;
    for (groups.items) |seed| {
        if (seed.sha.len == 0) continue;
        var done = false;
        for (out.items) |c| if (std.mem.eql(u8, c.niche, seed.niche)) {
            done = true;
        };
        if (done) continue;
        var win = seed;
        for (groups.items) |other| {
            if (other.sha.len == 0 or !std.mem.eql(u8, other.niche, seed.niche)) continue;
            if (betterStratum(other, win)) win = other;
        }
        out.append(arena, .{
            .niche = win.niche,
            .stratum = win.stratum,
            .sha = win.sha,
            .text = win.text,
            .mean = win.mean,
            .n = win.n,
            .rivals = win.rivals,
        }) catch return out.items;
    }
    return out.items;
}

test {
    _ = @import("fitness_strata_tests.zig");
}
