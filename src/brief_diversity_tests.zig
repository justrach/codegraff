//! #382 fixtures + tests for the brief-diversity gate.
//!
//! Split out of brief_diversity.zig so the fixtures can be full-length real
//! briefs rather than toy strings — the threshold is only defensible if the
//! text it was tuned on is the text the harness actually sees. Every fixture
//! below is either transcribed from the production post-mortem (the reskin
//! fleet that shipped the same design seven times, and the five-thesis fleet
//! that did not) or written straight off this repo's own shape catalog, so a
//! future threshold change has to answer to real orchestration patterns.
//!
//! Reached from brief_diversity.zig's `test {}` block, which workflow.zig
//! imports — so these run without a test_hooks.zig entry.

const std = @import("std");
const bd = @import("brief_diversity.zig");

// ── The failure (post-mortem run A) ─────────────────────────────────────────
// Ten "variant" subagents over one session, all reusing one six-slide
// template and varying only decoration: spark motif, ambient hue, particle
// field, skin, font pairing, blob saturation. Three consecutive briefs.
const reskin_fleet = [_][]const u8{
    "Build variant 4 of the launch deck. Keep the same six-slide scroll structure: hero, problem, product, metrics, testimonial, call to action. Every slide is full-bleed with a centered headline and one supporting line beneath it. For this variant: swap the accent motif to a spark field, warm the blob saturation, and pair Instrument Serif with Inter.",
    "Build variant 5 of the launch deck. Keep the same six-slide scroll structure: hero, problem, product, metrics, testimonial, call to action. Every slide is full-bleed with a centered headline and one supporting line beneath it. For this variant: swap the accent motif to an ambient hue wash, cool the blob saturation, and pair Playfair Display with Satoshi.",
    "Build variant 6 of the launch deck. Keep the same six-slide scroll structure: hero, problem, product, metrics, testimonial, call to action. Every slide is full-bleed with a centered headline and one supporting line beneath it. For this variant: swap the accent motif to a drifting particle layer, deepen the blob saturation, and pair Fraunces with General Sans.",
};

// The degenerate end of the same failure: one brief, route index swapped.
const near_copies = [_][]const u8{
    "Build a six-slide scroll deck for the launch page at route /v1 with hero, problem, product, metrics, testimonial and CTA slides.",
    "Build a six-slide scroll deck for the launch page at route /v2 with hero, problem, product, metrics, testimonial and CTA slides.",
    "Build a six-slide scroll deck for the launch page at route /v3 with hero, problem, product, metrics, testimonial and CTA slides.",
};

// ── The success (post-mortem run B) ─────────────────────────────────────────
// Five parallel briefs, each with a DISTINCT compositional thesis, one
// signature motion system, and its own route. Same model, same harness.
const thesis_fleet = [_][]const u8{
    "Variant 1 - editorial parallax. Thesis: the page reads like a print magazine spread whose plates drift at different depths as the reader scrolls. Signature system: multi-depth parallax on the image plates, nothing else moves. Build it at /v1; the shared components directory is off limits.",
    "Variant 2 - sticky crossfades. Thesis: the whole surface is one pinned frame in which each section dissolves into the next rather than travelling past it. Signature system: scroll-pinned opacity crossfade between sections. Build it at /v2; the shared components directory is off limits.",
    "Variant 3 - kinetic typography. Thesis: the words carry the argument by themselves, set enormous and relaid out on every beat, with imagery demoted to texture. Signature system: per-glyph type animation on entry. Build it at /v3; the shared components directory is off limits.",
    "Variant 4 - scroll-scrubbed chapters. Thesis: the story behaves like a film reel the reader scrubs through, one chapter per segment of the scrollbar. Signature system: a scroll-linked timeline that scrubs a single continuous sequence. Build it at /v4; the shared components directory is off limits.",
    "Variant 5 - horizontal rail. Thesis: content advances sideways along one continuous rail, so progress through the argument is spatial instead of vertical. Signature system: horizontal translation with snap points at each stop. Build it at /v5; the shared components directory is off limits.",
};

// ── Legitimate fleets that MUST stay quiet ──────────────────────────────────
// Shape A's verify slot: one skeptic per finding. Shares a skeleton on
// purpose — this is the hardest true negative, and the constraint that
// actually sets the threshold's ceiling.
const verify_fleet = [_][]const u8{
    "Refute finding 1: unchecked error union at src/http.zig:212. Build the strongest case that this is NOT a real bug - read the callers, the tests that cover it, and the git history of the line. Answer REFUTED or STANDS with evidence.",
    "Refute finding 2: path traversal in the tool-result writer at src/agent_tools.zig:74. Build the strongest case that this is NOT a real bug - read the callers, the tests that cover it, and the git history of the line. Answer REFUTED or STANDS with evidence.",
    "Refute finding 3: the retry loop in src/workflow.zig can double-charge a failed task. Build the strongest case that this is NOT a real bug - read the callers, the tests that cover it, and the git history of the line. Answer REFUTED or STANDS with evidence.",
};

// Shape B's sweep slot: same target, deliberately different search axes.
const sweep_fleet = [_][]const u8{
    "Map how compaction is triggered, searching by SYMBOL: start from every function whose name mentions compact or token, and follow the call graph outward. Do not read the git history - another researcher has that.",
    "Map how compaction is triggered, searching by GIT HISTORY: find the commits that introduced and later changed the threshold, and summarise what each one was fixing. Do not search by symbol - another researcher has that.",
    "Map how compaction is triggered, searching by TESTS: find every test that exercises a compaction path and describe what behaviour each one pins. Do not read the git history - another researcher has that.",
};

// The genuinely ambiguous middle: one six-slide skeleton, but each variant
// RE-PLANS the sections instead of restyling them. Composition differs, so
// this is a real fleet and must stay quiet.
const partial_fleet = [_][]const u8{
    "Build variant A of the launch deck as a six-slide scroll. Open on an oversized product shot, then a single-sentence problem slide, then three proof slides built from customer numbers, then a quiet closing CTA. Typography is the loudest element; motion is limited to slide entry.",
    "Build variant B of the launch deck as a six-slide scroll. Open on a full-screen quote from a customer, then the product shot, then a comparison slide against the status quo, then two objection-handling slides, then the CTA. Colour blocking carries the hierarchy; motion is limited to slide entry.",
    "Build variant C of the launch deck as a six-slide scroll. Open on the problem stated as a statistic, then a narrative build across three slides that each add one product capability, then a pricing slide, then the CTA. Layout density increases as the reader descends; motion is limited to slide entry.",
};

// Three unrelated audits — the easy true negative.
const audit_fleet = [_][]const u8{
    "Audit src/http.zig for correctness bugs: off-by-one indexing, unchecked error unions, and any path that can return a dangling slice into a freed buffer. Report each finding with a file:line and a one-line repro.",
    "Audit the same tree for security problems: command injection through exec.zig argv assembly, path traversal in the tool-result writer, and any secret that reaches a log line or a trace record.",
    "Audit the test suite for coverage holes: which public functions in src/ have no test at all, and which tests assert only that a call returns without checking what it returned.",
};

// Shape C: N implementers, the SAME task, a different system_prompt each.
const shape_c_prompt = "Implement the retry budget for workflow phases described in issue #382.";
const shape_c_prompts = [_][]const u8{ shape_c_prompt, shape_c_prompt, shape_c_prompt };
const shape_c_genomes = [_]?[]const u8{
    "You are an MVP-first implementer. Ship the smallest change that makes the feature real; refuse scope you were not asked for; prefer one function over an abstraction.",
    "You are a risk-first implementer. Before writing code, enumerate the ways this change can break an existing caller, then implement so that each of those ways is impossible or tested.",
    "You are a performance-first implementer. Assume this path runs on every turn; count allocations and syscalls, and justify each one you add in a comment.",
};

fn meanOf(a: std.mem.Allocator, briefs: []const []const u8) f64 {
    return bd.analyze(a, briefs).mean;
}

test "#382: a reskin fleet trips the gate; the five-thesis fleet does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // (a) The production failure. Three briefs off one six-slide template,
    // differing only in decoration words, must warn — and must warn LOUDLY,
    // not by a hair, or the threshold is riding on fixture noise.
    const reskin = bd.analyze(a, &reskin_fleet);
    try std.testing.expect(reskin.warn);
    try std.testing.expectEqual(@as(usize, 3), reskin.n);
    try std.testing.expect(reskin.mean > 0.60 and reskin.mean < 0.68);

    // The degenerate case scores higher still.
    const copies = bd.analyze(a, &near_copies);
    try std.testing.expect(copies.warn);
    try std.testing.expect(copies.mean > reskin.mean);

    // (b) The successful run: five briefs, five compositional theses. This is
    // the fleet the gate must never touch, and it is nowhere near the line.
    const thesis = bd.analyze(a, &thesis_fleet);
    try std.testing.expect(!thesis.warn);
    try std.testing.expectEqual(@as(usize, 5), thesis.n);
    try std.testing.expect(thesis.mean < 0.15);

    // The gap between the two production runs is the whole point: it is not a
    // rounding difference, it is most of the scale.
    try std.testing.expect(reskin.mean - thesis.mean > 0.4);
}

test "#382: legitimate skeleton-sharing fleets stay quiet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The tightest true negative in the suite: shape A's verify slot repeats
    // its instructions verbatim across tasks BY DESIGN and only the finding
    // changes. It sits below the threshold, and the reskin fleet sits above
    // it — that ordering is what makes the gate usable at all.
    const verify = bd.analyze(a, &verify_fleet);
    try std.testing.expect(!verify.warn);
    try std.testing.expect(verify.mean > 0.45); // genuinely close to the line
    try std.testing.expect(verify.mean < bd.warn_threshold);
    try std.testing.expect(meanOf(a, &reskin_fleet) > verify.mean);

    // Everything else a real workflow fans out is far from the line.
    try std.testing.expect(!bd.analyze(a, &sweep_fleet).warn);
    try std.testing.expect(!bd.analyze(a, &partial_fleet).warn);
    try std.testing.expect(!bd.analyze(a, &audit_fleet).warn);
    try std.testing.expect(meanOf(a, &audit_fleet) < 0.05);
}

test "#382: a fleet whose variation lives in system_prompt is judged on that axis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Shape C's prompts are identical by construction — judged on prompts
    // alone this fleet is a perfect 1.0 and would warn every single time the
    // catalog's own design/solve shape is used.
    const on_prompts = bd.analyze(a, &shape_c_prompts);
    try std.testing.expect(on_prompts.warn);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), on_prompts.mean, 1e-9);

    // With the personas supplied, the axis moves to them and the fleet is
    // correctly read as three different implementers of one task.
    const quiet = bd.check(a, null, "variants", &shape_c_prompts, &shape_c_genomes);
    try std.testing.expectEqualStrings("", quiet);

    // The axis only moves when EVERY task has a genome; a partial fleet is
    // still judged on its briefs (there is no shared axis to move to).
    const partial_genomes = [_]?[]const u8{ shape_c_genomes[0], null, shape_c_genomes[2] };
    try std.testing.expect(bd.personaAxis(a, &shape_c_prompts, &partial_genomes) == null);
    try std.testing.expect(bd.check(a, null, "variants", &shape_c_prompts, &partial_genomes).len > 0);

    // Personas that DIFFER but only slightly still warn, on the persona text —
    // that fleet really is one concept wearing three hats.
    const near = [_]?[]const u8{
        "You are an implementer. Favour the MVP: ship the smallest thing that works.",
        "You are an implementer. Favour the MVP: ship the smallest thing that works today.",
        "You are an implementer. Favour the MVP: ship the smallest thing that can work.",
    };
    try std.testing.expect(bd.personaAxis(a, &shape_c_prompts, &near) != null);
    try std.testing.expect(bd.check(a, null, "variants", &shape_c_prompts, &near).len > 0);
}

test "personaAxis: identical genomes are a CONSTANT, not an axis — measure the briefs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // THE false positive, transcribed from eval run 01-bugfix-B. Three finders
    // carrying ONE resolved system_prompt and three genuinely different briefs.
    // The old rule ("every task has SOME override") moved the axis to the
    // personas, measured them at 1.000, and fired the warning — while the text
    // that actually varied was never looked at. A gate reporting "100% similar"
    // for a fleet whose briefs are ~17% similar is worse than no gate.
    const one_genome = "You are a code reviewer. Report concrete defects with file:line evidence.";
    const genomes = [_]?[]const u8{ one_genome, one_genome, one_genome };
    const briefs = [_][]const u8{
        "Review implementation correctness in stats.py: check each function against its docstring and the behaviour the tests assert.",
        "Analyze boundary cases: empty input, single element, even-length input, and ties between equally frequent values.",
        "Trace tests to functions: map every assertion in test_stats.py back to the function it exercises and note which are unmet.",
    };

    // The axis does NOT move: with one genome there is nothing to measure on it.
    try std.testing.expect(bd.personaAxis(a, &briefs, &genomes) == null);
    // So the gate measures the briefs — and the briefs are varied, so it is
    // silent. This is the exact run that used to warn at 1.00.
    const r = bd.analyze(a, &briefs);
    try std.testing.expect(!r.warn);
    try std.testing.expect(r.mean < bd.warn_threshold);
    try std.testing.expectEqualStrings("", bd.check(a, null, "find", &briefs, &genomes));

    // The same one-genome fleet with COPIED briefs still warns — the fix moves
    // the measurement, it does not silence it.
    const copies = [_][]const u8{ briefs[0], briefs[0], briefs[0] };
    try std.testing.expect(bd.check(a, null, "find", &copies, &genomes).len > 0);

    // genomeSha is content equality over the RESOLVED genome, which is what a
    // prompt_sha comparison means here.
    try std.testing.expectEqual(bd.genomeSha(one_genome), bd.genomeSha("You are a code reviewer. Report concrete defects with file:line evidence."));
    try std.testing.expect(bd.genomeSha(one_genome) != bd.genomeSha("You are a security reviewer."));
}

test "collapse: same genome + same brief spawns once, and the survivor takes the fan-in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = "reviewer persona";
    const genomes = [_]?[]const u8{ g, g, g };

    // Three byte-identical briefs under one genome: one worker, asked thrice.
    const same = [_][]const u8{ near_copies[0], near_copies[0], near_copies[0] };
    const c = bd.collapse(a, &same, &genomes, false);
    try std.testing.expectEqual(@as(usize, 1), c.survivors.len);
    try std.testing.expectEqual(@as(usize, 2), c.collapsed());
    // Every duplicate points at the SURVIVOR, so the fan-in has one source and
    // the next phase's {{prev}} reads exactly what it would have read.
    for (c.rep) |r| try std.testing.expectEqual(@as(usize, 0), r);
    try std.testing.expectEqual(@as(usize, 0), c.survivors[0]);
    // And the manifest says so, rather than the run silently narrowing.
    try std.testing.expect(std.mem.indexOf(u8, bd.collapseNote(a, c), "collapsed 2 duplicate") != null);
}

test "collapse: both halves are required — genome alone or brief alone is not a duplicate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Same genome, DIFFERENT briefs: a legitimate fan-out (three reviewers,
    // one persona, three dimensions). This is the study's find phase.
    const g = "reviewer persona";
    const one_genome = [_]?[]const u8{ g, g, g };
    const varied = bd.collapse(a, &thesis_fleet[0..3].*, &one_genome, false);
    try std.testing.expectEqual(@as(usize, 3), varied.survivors.len);
    try std.testing.expectEqual(@as(usize, 0), varied.collapsed());

    // Same brief, DIFFERENT genomes: shape C's whole point — N implementers,
    // one task, a different system_prompt each. Nothing may collapse.
    const c = bd.collapse(a, &shape_c_prompts, &shape_c_genomes, true);
    try std.testing.expectEqual(@as(usize, 3), c.survivors.len);

    // Near-copies (one brief, /vN swapped) sit at ~0.74 — BELOW the 0.85
    // collapse threshold, so they survive even under one genome. The warn gate
    // can afford to be wrong; a gate that deletes a worker cannot.
    const near = bd.collapse(a, &near_copies, &one_genome, false);
    try std.testing.expectEqual(@as(usize, 3), near.survivors.len);
    try std.testing.expect(bd.analyze(a, &near_copies).warn); // it still WARNS
}

test "collapse: floors — a variants phase keeps a tournament, everywhere else keeps one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const g = "one persona";
    const genomes = [_]?[]const u8{ g, g, g, g };
    const same = [_][]const u8{ near_copies[0], near_copies[0], near_copies[0], near_copies[0] };

    // "Run the same brief N times and judge the spread" is a legitimate ask,
    // and a tournament of one is not a tournament.
    const variants = bd.collapse(a, &same, &genomes, true);
    try std.testing.expectEqual(@as(usize, 2), variants.survivors.len);
    // Elsewhere there is nothing to rank, so one survivor is the whole answer.
    const ordinary = bd.collapse(a, &same, &genomes, false);
    try std.testing.expectEqual(@as(usize, 1), ordinary.survivors.len);

    // Degenerate inputs pass through as identity rather than guessing.
    const single = [_][]const u8{same[0]};
    const one_g = [_]?[]const u8{g};
    const id = bd.collapse(a, &single, &one_g, false);
    try std.testing.expectEqual(@as(usize, 1), id.survivors.len);
    try std.testing.expectEqual(@as(usize, 0), id.collapsed());
    try std.testing.expectEqualStrings("", bd.collapseNote(a, id));
}

test "collapse: two tasks with no genome at all still collapse on identical text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Both null is "same genome" — an inline fan-out with no persona is still
    // one configuration, and two identical briefs under it are one worker.
    const none = [_]?[]const u8{ null, null, null };
    const same = [_][]const u8{ near_copies[0], near_copies[0], near_copies[2] };
    const c = bd.collapse(a, &same, &none, false);
    try std.testing.expectEqual(@as(usize, 2), c.survivors.len); // 0 and 2 survive, 1 folds into 0
    try std.testing.expectEqual(@as(usize, 0), c.rep[1]);
    try std.testing.expectEqual(@as(usize, 2), c.rep[2]);
}

test "#382: a fleet smaller than min_fleet is never judged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // (c) Two byte-identical briefs are a pair, not a fleet: "they all look
    // alike" is not a statement about two things, and a phase of two is the
    // most common shape there is. Nothing is measured and nothing is said.
    const two = [_][]const u8{ reskin_fleet[0], reskin_fleet[0] };
    const r2 = bd.analyze(a, &two);
    try std.testing.expect(!r2.warn);
    try std.testing.expectEqual(@as(f64, 0), r2.mean);
    try std.testing.expectEqualStrings("", bd.check(a, null, "variants", &two, &.{}));

    const one = [_][]const u8{reskin_fleet[0]};
    try std.testing.expect(!bd.analyze(a, &one).warn);
    try std.testing.expectEqualStrings("", bd.check(a, null, "variants", &one, &.{}));
    try std.testing.expect(!bd.analyze(a, &.{}).warn);

    // Three identical briefs is the smallest fleet that CAN warn, and does.
    const three = [_][]const u8{ reskin_fleet[0], reskin_fleet[0], reskin_fleet[0] };
    try std.testing.expect(bd.analyze(a, &three).warn);
}

test "#382: the threshold is a mean over pairs, compared inclusively" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // (d) Boundary, pinned deterministically. Single-word briefs have no
    // trigram, so each pair scores exactly 1.0 or 0.0 and the mean is an
    // exact rational: 3 identical of 4 briefs is 3/6 = 0.500 (quiet), 4
    // identical of 5 is 6/10 = 0.600 (warn). The threshold therefore lives in
    // (0.50, 0.60] no matter what the prose fixtures do.
    const four = [_][]const u8{ "alpha", "alpha", "alpha", "beta" };
    const r4 = bd.analyze(a, &four);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), r4.mean, 1e-9);
    try std.testing.expect(!r4.warn);

    const five = [_][]const u8{ "alpha", "alpha", "alpha", "alpha", "beta" };
    const r5 = bd.analyze(a, &five);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), r5.mean, 1e-9);
    try std.testing.expect(r5.warn);

    try std.testing.expect(bd.warn_threshold > 0.5 and bd.warn_threshold <= 0.6);

    // Mean, not max: one duplicated pair inside an otherwise varied fleet is
    // not the failure mode this gate is for.
    const one_dupe = [_][]const u8{ thesis_fleet[0], thesis_fleet[0], thesis_fleet[1], thesis_fleet[2], thesis_fleet[3] };
    try std.testing.expect(!bd.analyze(a, &one_dupe).warn);
}

test "#382: the warning names the count and the measurement, and never blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const text = bd.check(a, null, "variants", &reskin_fleet, &.{});
    try std.testing.expect(std.mem.startsWith(u8, text, "diversity warning: 3 variant briefs are ~6"));
    try std.testing.expect(std.mem.indexOf(u8, text, "% similar") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cosmetic variants of one concept") != null);
    // The actionable half: what to change, not just that something is wrong.
    try std.testing.expect(std.mem.indexOf(u8, text, "Differentiate composition, narrative, or interaction architecture") != null);
    // Warn-only. The escape hatch is part of the contract: a deliberately
    // uniform fleet (N samples of one prompt) is a legitimate ask.
    try std.testing.expect(std.mem.indexOf(u8, text, "proceed if intentional") != null);

    // A quiet fleet produces no text at all — no "all good" noise in the
    // root's transcript.
    try std.testing.expectEqualStrings("", bd.check(a, null, "sweep", &thesis_fleet, &.{}));
}

test "#382: degenerate and adversarial inputs cannot crash or mislead the gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Empty briefs have no grams: no evidence is 0, not perfect agreement.
    const empties = [_][]const u8{ "", "", "" };
    try std.testing.expect(!bd.analyze(a, &empties).warn);
    const punct = [_][]const u8{ "!!!", "???", "---" };
    try std.testing.expect(!bd.analyze(a, &punct).warn);

    // Case and punctuation are not differences.
    const cased = [_][]const u8{ "Build the deck.", "BUILD THE DECK!", "build   the   deck" };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bd.analyze(a, &cased).mean, 1e-9);

    // Non-ASCII words stay whole rather than shattering into shared UTF-8
    // continuation bytes, which would make any two non-Latin briefs look
    // alike. Three different Japanese briefs must not warn.
    const jp = [_][]const u8{
        "ヒーロー セクション を 作る 大きな 見出し と 写真",
        "価格 表 を 作る 三 つ の プラン と 比較 表",
        "問い合わせ フォーム を 作る 名前 メール 本文 の 欄",
    };
    try std.testing.expect(!bd.analyze(a, &jp).warn);
    // …while three copies of one of them does warn.
    const jp_same = [_][]const u8{ jp[0], jp[0], jp[0] };
    try std.testing.expect(bd.analyze(a, &jp_same).warn);

    // A fleet wider than the cap is truncated, never unbounded.
    var wide: [bd.max_briefs + 6][]const u8 = undefined;
    for (&wide, 0..) |*w, i| w.* = if (i % 2 == 0) thesis_fleet[0] else thesis_fleet[1];
    const r = bd.analyze(a, &wide);
    try std.testing.expectEqual(@as(usize, bd.max_briefs), r.n);

    // A very long brief is read to max_words and no further.
    const long = try a.alloc(u8, 64 * 1024);
    for (long, 0..) |*c, i| c.* = if (i % 6 == 5) ' ' else @as(u8, 'a') + @as(u8, @intCast(i % 26));
    const longs = [_][]const u8{ long, long, long };
    try std.testing.expect(bd.analyze(a, &longs).warn);
}

// ── the sibling-spawn batch path ────────────────────────────────────────────
const tools = @import("tools.zig");

/// Build a runTools-shaped batch from raw JSON argument objects.
fn batch(a: std.mem.Allocator, names: []const []const u8, args: []const []const u8) ![]tools.ToolCall {
    const calls = try a.alloc(tools.ToolCall, names.len);
    for (calls, names, args) |*c, name, arg| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, arg, .{});
        c.* = .{ .id = "t", .name = name, .input = parsed.value };
    }
    return calls;
}

/// One JSON-encoded string (a fresh Stringify per value: one instance is
/// good for exactly one top-level value).
fn jsonStr(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var st: std.json.Stringify = .{ .writer = &aw.writer };
    try st.write(s);
    return aw.writer.buffered();
}

fn spawnArgs(a: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"description\":\"v\",\"prompt\":{s}}}", .{try jsonStr(a, prompt)});
}

fn personaArgs(a: std.mem.Allocator, prompt: []const u8, genome: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"prompt\":{s},\"system_prompt\":{s}}}", .{ try jsonStr(a, prompt), try jsonStr(a, genome) });
}

test "#382: three sibling subagent spawns in one batch are a fleet too" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const args = [_][]const u8{
        try spawnArgs(a, reskin_fleet[0]),
        try spawnArgs(a, reskin_fleet[1]),
        try spawnArgs(a, reskin_fleet[2]),
    };
    const names = [_][]const u8{ "subagent", "subagent", "subagent" };
    const calls = try batch(a, &names, &args);
    var results = [_]tools.ExecResult{
        .{ .text = "first result", .is_error = false },
        .{ .text = "second result", .is_error = false },
        .{ .text = "third result", .is_error = false },
    };
    const ext = [_]usize{ 0, 1, 2 };
    bd.noteSiblingBatch(a, null, calls, &ext, &results);

    // The note rides on the FIRST sibling's result — the only channel a tool
    // batch has back to the root — and never replaces what that spawn said.
    try std.testing.expect(std.mem.startsWith(u8, results[0].text, "diversity warning: 3 variant briefs"));
    try std.testing.expect(std.mem.endsWith(u8, results[0].text, "first result"));
    // Siblings are untouched: one note per batch, not one per spawn.
    try std.testing.expectEqualStrings("second result", results[1].text);
    try std.testing.expectEqualStrings("third result", results[2].text);
    // Warn-only here as well: nothing is marked failed.
    for (results) |r| try std.testing.expect(!r.is_error);
}

test "#382: a sibling batch that is not a variant fleet is left alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ext3 = [_]usize{ 0, 1, 2 };

    // Distinct theses — quiet.
    const varied = [_][]const u8{
        try spawnArgs(a, thesis_fleet[0]),
        try spawnArgs(a, thesis_fleet[1]),
        try spawnArgs(a, thesis_fleet[2]),
    };
    const sub3 = [_][]const u8{ "subagent", "subagent", "subagent" };
    var r1 = [_]tools.ExecResult{ .{ .text = "a", .is_error = false }, .{ .text = "b", .is_error = false }, .{ .text = "c", .is_error = false } };
    bd.noteSiblingBatch(a, null, try batch(a, &sub3, &varied), &ext3, &r1);
    try std.testing.expectEqualStrings("a", r1[0].text);

    // Two near-identical spawns alongside a bash call: only TWO spawns, so
    // there is no fleet — a batch is not made a fleet by its size.
    const mixed_args = [_][]const u8{
        try spawnArgs(a, reskin_fleet[0]),
        try spawnArgs(a, reskin_fleet[1]),
        "{\"command\":\"ls\"}",
    };
    const mixed_names = [_][]const u8{ "subagent", "subagent", "bash" };
    var r2 = [_]tools.ExecResult{ .{ .text = "a", .is_error = false }, .{ .text = "b", .is_error = false }, .{ .text = "c", .is_error = false } };
    bd.noteSiblingBatch(a, null, try batch(a, &mixed_names, &mixed_args), &ext3, &r2);
    try std.testing.expectEqualStrings("a", r2[0].text);

    // A spawn with no prompt is not counted, and the note lands on the first
    // spawn that IS counted rather than on index 0 blindly.
    const gappy_args = [_][]const u8{
        "{\"command\":\"ls\"}",
        try spawnArgs(a, reskin_fleet[0]),
        try spawnArgs(a, reskin_fleet[1]),
        try spawnArgs(a, reskin_fleet[2]),
    };
    const gappy_names = [_][]const u8{ "bash", "subagent", "subagent", "subagent" };
    var r3 = [_]tools.ExecResult{ .{ .text = "ls out", .is_error = false }, .{ .text = "a", .is_error = false }, .{ .text = "b", .is_error = false }, .{ .text = "c", .is_error = false } };
    const ext4 = [_]usize{ 0, 1, 2, 3 };
    bd.noteSiblingBatch(a, null, try batch(a, &gappy_names, &gappy_args), &ext4, &r3);
    try std.testing.expectEqualStrings("ls out", r3[0].text);
    try std.testing.expect(std.mem.startsWith(u8, r3[1].text, "diversity warning:"));

    // Same task, three personas: judged on the personas, so quiet (the
    // sibling path resolves `system_prompt`/`agent` exactly as workflow does).
    var persona_args: [3][]const u8 = undefined;
    for (&persona_args, shape_c_genomes) |*pa, genome| pa.* = try personaArgs(a, shape_c_prompt, genome.?);
    var r4 = [_]tools.ExecResult{ .{ .text = "a", .is_error = false }, .{ .text = "b", .is_error = false }, .{ .text = "c", .is_error = false } };
    bd.noteSiblingBatch(a, null, try batch(a, &sub3, &persona_args), &ext3, &r4);
    try std.testing.expectEqualStrings("a", r4[0].text);
}

test "#382: percent rounds the mean for the human-facing line" {
    try std.testing.expectEqual(@as(u64, 0), (bd.Report{ .mean = 0 }).percent());
    try std.testing.expectEqual(@as(u64, 62), (bd.Report{ .mean = 0.6191 }).percent());
    try std.testing.expectEqual(@as(u64, 100), (bd.Report{ .mean = 1.0 }).percent());
}
