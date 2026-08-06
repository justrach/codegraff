//! #382 — the brief-diversity gate for variant fleets.
//!
//! The failure this exists for: a root agent spawned ten "variant" subagents
//! over one session that all reused a single six-slide template and varied
//! only decoration — spark motif, ambient hue, particle field, skin, font
//! pairing, blob saturation. The user was shown the same design seven times.
//! A contrasting run of the SAME model on the SAME harness fanned out five
//! briefs each carrying a distinct compositional thesis (editorial parallax /
//! sticky crossfades / kinetic typography / scroll-scrubbed chapters /
//! horizontal rail) and produced five genuinely different pages. The whole
//! gap was orchestration quality, and the harness already holds every brief
//! in memory before it spawns anything — it just never looked at them.
//!
//! So look. Model-free, allocation-bounded, and WARN-ONLY: a fleet that is
//! deliberately near-identical (N runs of one prompt to sample variance) is a
//! legitimate thing to ask for, and a harness that refused it would be wrong.
//! The note names the number and the similarity and lets the root decide.
//!
//! Metric — mean pairwise Jaccard over deduped word 3-grams (shingles):
//!
//!   * 3-grams rather than bare word sets because the signal IS phrasing.
//!     Two briefs in one domain share most of their vocabulary whatever they
//!     ask for ("page", "section", "scroll", "route", "component", plus every
//!     function word), so unigram overlap reads high for fleets that are
//!     genuinely different — a false positive, and a warn-only gate that
//!     cries wolf gets ignored. A shingle is only shared when a RUN of words
//!     is shared, which is exactly what copy-pasting one template does.
//!   * Jaccard rather than the overlap coefficient (|A∩B| / min) because
//!     overlap saturates to 1.0 whenever one brief is short, and short is not
//!     the same as derivative.
//!   * MEAN rather than max: one duplicated pair inside an otherwise varied
//!     fleet is not the failure — the failure is a whole fleet cut from one
//!     pattern, and the mean is what separates those two.
//!
//! Cost is O(N²·W) comparisons over sorted u64 arrays with a hard cap on both
//! N and the words read per brief, so a pathological fleet cannot make this
//! expensive. No model call, no network, no I/O beyond the trace note.
//!
//! Two call sites, both BEFORE anything spawns:
//!
//!   workflow.zig      a phase fanning out N≥3 tasks; its note rides the run
//!                     manifest, which is the part of a workflow result the
//!                     root reliably reads.
//!   agent_tools.zig   N≥3 sibling `subagent` spawns in ONE tool batch — the
//!                     same fleet, just never named as one; its note is
//!                     prepended to the first sibling's result.
//!
//! Both measure the RAW briefs, before workflow `context` is prepended and
//! before {{prev}} is substituted. That matters: those two mechanically
//! inject identical text into every prompt in a phase, so measuring the
//! composed prompts would score every wide phase as a near-duplicate fleet
//! and the gate would be noise by construction.

const std = @import("std");
const Allocator = std.mem.Allocator;
const trace = @import("trace.zig");
const util = @import("util.zig");
const fleet = @import("fleet.zig"); // resolveOverride: the shared system_prompt/agent resolution
const tick_gate = @import("tick_gate.zig"); // #tui-tick/#444: activity lines land at a line boundary, and never in a test binary

/// Shingle width. 3 is the standard near-duplicate-detection default and it
/// is what the fixtures below were tuned against; 2 drifts toward unigram
/// behaviour (too many false positives), 4+ misses reskins that reword a
/// clause while keeping the structure.
pub const gram_n = 3;

/// A fleet needs at least this many briefs before "they all look alike" is
/// even a meaningful statement. Two tasks in a phase are a pair, not a fleet.
pub const min_fleet = 3;

/// Hard bounds. max_briefs is above workflow.max_workflow_tasks (8) on
/// purpose so the sibling-spawn path can share this without a second cap;
/// max_words bounds the per-brief scratch, and truncating to the first ~512
/// words is safe because a brief's thesis is at its head, never its tail.
pub const max_briefs = 16;
pub const max_words = 512;

/// The longest word prefix that participates in a word's hash. Beyond this
/// two words collide, which can only ever RAISE measured similarity for
/// absurd inputs — and absurd inputs are not the case this protects.
const word_cap = 48;

/// Mean pairwise similarity at or above which the fleet gets a note.
///
/// MEASURED, not guessed. Every fixture in brief_diversity_tests.zig is
/// transcribed from the two runs in the post-mortem or from this repo's own
/// shape catalog, and this is where they land on the trigram scale:
///
///   near-copies (one brief, /vN swapped)          0.739  must warn
///   reskin fleet (template + decoration deltas)   0.619  must warn
///   ── warn_threshold 0.55 ─────────────────────────────────────────
///   shape-A verify (one skeptic per finding)      0.512  must stay quiet
///   shape-B sweep (same target, 3 search axes)    0.168  must stay quiet
///   partial redesign (same skeleton, re-planned)  0.167  must stay quiet
///   five-thesis fleet (the successful run)        0.075  must stay quiet
///   three unrelated audits                        0.000  must stay quiet
///
/// The tightest constraint is the gap between the reskin fleet and a
/// legitimate verify phase — both share a skeleton on purpose, and only one
/// of them is a failure. 0.55 sits in that 0.512-0.619 band. Trigrams were
/// kept over unigrams partly because that band is WIDER here (0.107) than on
/// unigrams (0.078), where the same two fixtures sit at 0.647 and 0.724.
///
/// Which also explains the number: the issue proposed ~0.7, and ~0.7 is
/// exactly where a reskin lands on the UNIGRAM scale. Shingles run
/// structurally lower — one changed word kills gram_n grams instead of one
/// token — so 0.55 is that same operating point re-expressed in the metric
/// actually in use, with margin measured on both sides rather than assumed.
///
/// Bias is deliberately toward silence: a false warning on a legitimate
/// phase teaches the root to ignore the line, which costs more than the
/// missed reskin it was meant to catch.
pub const warn_threshold: f64 = 0.55;

/// Which text actually carried the fleet's intended variation — see
/// `personaAxis`.
pub const Axis = enum { brief, system_prompt };

pub const Report = struct {
    /// Briefs actually compared (capped at max_briefs).
    n: usize = 0,
    /// Mean pairwise Jaccard, 0..1. Zero for a fleet below min_fleet.
    mean: f64 = 0,
    warn: bool = false,
    axis: Axis = .brief,

    /// Mean as whole percent, for the human-facing line.
    pub fn percent(self: Report) u64 {
        const p = @round(self.mean * 100);
        return if (p <= 0) 0 else @intFromFloat(p);
    }
};

/// Word bytes: ASCII alphanumerics plus every non-ASCII byte, so a UTF-8 word
/// stays ONE token instead of shattering into per-byte tokens (which would
/// make any two non-Latin briefs look similar through their shared
/// continuation bytes).
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// Hash `text`'s words into `out` in order, returning the used prefix.
/// Lowercased so casing never registers as a difference.
fn wordHashes(out: []u64, text: []const u8) []u64 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        while (i < text.len and !isWordByte(text[i])) : (i += 1) {}
        if (i >= text.len) break;
        const start = i;
        while (i < text.len and isWordByte(text[i])) : (i += 1) {}
        var buf: [word_cap]u8 = undefined;
        const word = text[start..i];
        const m = @min(word.len, buf.len);
        for (buf[0..m], word[0..m]) |*d, s| d.* = std.ascii.toLower(s);
        out[n] = std.hash.Wyhash.hash(0, buf[0..m]);
        n += 1;
    }
    return out[0..n];
}

/// The sorted, deduplicated shingle set for one brief's word hashes, written
/// into `out` (which must hold at least `words.len` entries).
///
/// A brief with fewer than gram_n words has no shingle, so it collapses to a
/// single gram over its whole word list: two such briefs then compare 1.0 iff
/// they are the same words, 0.0 otherwise. That is the honest answer for
/// "build /v1" vs "build /v2" — there is no phrasing to measure.
fn gramSet(out: []u64, words: []const u64) []const u64 {
    var n: usize = 0;
    if (words.len == 0) return out[0..0];
    if (words.len < gram_n) {
        out[0] = std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(words));
        n = 1;
    } else {
        for (0..words.len - gram_n + 1) |i| {
            out[n] = std.hash.Wyhash.hash(1, std.mem.sliceAsBytes(words[i .. i + gram_n]));
            n += 1;
        }
    }
    const filled = out[0..n];
    std.mem.sort(u64, filled, {}, std.sort.asc(u64));
    var w: usize = 0;
    for (filled, 0..) |v, k| {
        if (k == 0 or v != filled[w - 1]) {
            filled[w] = v;
            w += 1;
        }
    }
    return filled[0..w];
}

/// Jaccard over two sorted, deduplicated sets: one linear merge, no
/// allocation. An empty set yields 0 — no evidence, not perfect agreement.
fn jaccard(a: []const u64, b: []const u64) f64 {
    if (a.len == 0 or b.len == 0) return 0;
    var i: usize = 0;
    var j: usize = 0;
    var inter: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] == b[j]) {
            inter += 1;
            i += 1;
            j += 1;
        } else if (a[i] < b[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    const uni = a.len + b.len - inter;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
}

/// Measure a fleet. Below min_fleet (or on any allocation failure) the report
/// is inert: `warn` false, `mean` zero — this is a diagnostic, so it degrades
/// to silence rather than to a guess.
pub fn analyze(arena: Allocator, briefs: []const []const u8) Report {
    // Explicitly usize: @min narrows its result type to the smallest int that
    // can hold max_briefs (u5), and n scales a buffer length below.
    const n: usize = @min(briefs.len, max_briefs);
    if (n < min_fleet) return .{ .n = briefs.len };
    const words = arena.alloc(u64, max_words) catch return .{ .n = n };
    const grams = arena.alloc(u64, n * max_words) catch return .{ .n = n };
    const sets = arena.alloc([]const u64, n) catch return .{ .n = n };
    for (briefs[0..n], sets, 0..) |brief, *set, k| {
        const w = wordHashes(words, brief);
        set.* = gramSet(grams[k * max_words ..][0..max_words], w);
    }
    var total: f64 = 0;
    var pairs: usize = 0;
    for (0..n) |i| {
        for (i + 1..n) |j| {
            total += jaccard(sets[i], sets[j]);
            pairs += 1;
        }
    }
    const mean = total / @as(f64, @floatFromInt(pairs));
    return .{ .n = n, .mean = mean, .warn = mean >= warn_threshold };
}

/// The root-facing line, or null when the fleet is fine. Warn-only by
/// construction: it names the measurement, says what to change, and ends by
/// granting permission to ignore it — a gate that blocked here would break
/// the legitimate "run the same brief N times" fleet.
pub fn warningText(arena: Allocator, r: Report) ?[]const u8 {
    if (!r.warn) return null;
    return std.fmt.allocPrint(
        arena,
        "diversity warning: {d} variant briefs are ~{d}% similar — these read as " ++
            "cosmetic variants of one concept. Differentiate composition, narrative, " ++
            "or interaction architecture, or proceed if intentional.",
        .{ r.n, r.percent() },
    ) catch null;
}

/// When EVERY task in the fleet carries its own `system_prompt`, that genome
/// is the axis the fleet varies on and the prompts are not — so measure the
/// genomes instead. Returns null (measure the briefs) otherwise.
///
/// This is not a nicety, it is required for the gate to be believable. Shape
/// C in this repo's own catalog reads "N implementers, same task, a DIFFERENT
/// system_prompt each (MVP-first / risk-first / perf-first)": its task
/// prompts are IDENTICAL by design and measure 1.000, while its personas
/// measure 0.006. Judging that fleet on its prompts would fire the warning
/// every single time the harness's own recommended pattern is used, and a
/// warning that fires on correct usage is a warning nobody reads.
///
/// A fleet whose personas ARE near-identical still warns, on the persona
/// text — which is the right answer, since that fleet really is one concept.
///
/// THE SHA GATE. The original test was "every task carries SOME override",
/// which is presence, not variation — and presence is not what makes the
/// persona the axis. The eval study caught the difference in the worst
/// possible place: three finders that all carried the SAME resolved
/// system_prompt and three genuinely different briefs measured 1.000 on the
/// persona axis and fired the warning, while the text that actually varied
/// was never looked at. A gate that reports 100% similar for a fleet whose
/// briefs are 17% similar is worse than no gate: it is a number that means
/// the opposite of what it says.
///
/// So: all resolved genomes IDENTICAL means the genome is a constant, not an
/// axis, and the answer is null — measure the briefs, which is where the
/// variation has to be if there is any. Shape C (N implementers, one task, a
/// DIFFERENT system_prompt each) is unaffected, because its genomes really do
/// differ and that is exactly the case this function exists for.
pub fn personaAxis(arena: Allocator, briefs: []const []const u8, genomes: []const ?[]const u8) ?[]const []const u8 {
    if (genomes.len != briefs.len) return null;
    for (genomes) |g| if (g == null or g.?.len == 0) return null;
    // Content equality over the RESOLVED genome (fleet.resolveOverride has
    // already turned `agent:"reviewer"` into that persona's text), which is
    // what a prompt_sha comparison means here.
    const first = genomeSha(genomes[0].?);
    var varied = false;
    for (genomes[1..]) |g| if (genomeSha(g.?) != first) {
        varied = true;
    };
    if (!varied) return null;
    const out = arena.alloc([]const u8, genomes.len) catch return null;
    for (genomes, out) |g, *o| o.* = g.?;
    return out;
}

/// The resolved genome's content fingerprint. A 64-bit content hash rather
/// than the 128-bit scoring.promptFingerprint: this is only ever used for
/// EQUALITY between genomes held in one process at one instant, never
/// persisted, never joined against an archive — so importing the signing
/// fingerprint here would buy nothing and add a dependency.
pub fn genomeSha(genome: []const u8) u64 {
    return std.hash.Wyhash.hash(0xf1ee7, genome);
}

// ── collapse ───────────────────────────────────────────────────────────────
// The gate above measures and warns. This DOES something about the one case
// where the measurement is unambiguous: two tasks that carry the same genome
// AND essentially the same brief are the same worker, spawned twice, and the
// second one costs a full model call to produce text the first already
// produced. The study has both halves of the proof — a research phase that
// spawned three sweepers over three small files whose briefs measured 1.000
// similar to each other, and the same task answered identically by one.
//
// Collapsing is safe in a way warning is not, because the duplicate's output
// is not lost: the survivor's result is fanned into every collapsed task's
// {{prev}} slot, so the next phase reads exactly what it would have read.
// What disappears is the redundant CALL.

/// Jaccard at or above which two same-genome briefs are one brief. Higher
/// than warn_threshold (0.55) by a wide margin, and deliberately so: the warn
/// gate is advisory and can afford to be wrong, while this one silently
/// removes a worker, so it fires only on near-copies. On the fixture scale in
/// this file, 0.85 sits ABOVE the near-copies fixture (0.739) — meaning even
/// "one brief with /vN swapped" survives, and only briefs that are the same
/// modulo whitespace and a word collapse.
pub const collapse_threshold: f64 = 0.85;

pub const Collapse = struct {
    /// For each input task, the index of the task that will actually run for
    /// it — itself when it survives, the survivor's index when it collapsed.
    rep: []const usize,
    /// Surviving indices, ascending.
    survivors: []const usize,

    pub fn collapsed(self: Collapse) usize {
        return self.rep.len - self.survivors.len;
    }
};

fn identity(arena: Allocator, n: usize) Collapse {
    const rep = arena.alloc(usize, n) catch return .{ .rep = &.{}, .survivors = &.{} };
    for (rep, 0..) |*r, i| r.* = i;
    return .{ .rep = rep, .survivors = rep };
}

/// Which tasks actually need to be spawned.
///
/// Two tasks are duplicates iff their resolved genomes are byte-identical AND
/// their briefs measure `collapse_threshold` or more similar. Both halves are
/// required: same genome + different brief is a legitimate fan-out (three
/// reviewers, one persona, three dimensions), and same brief + different
/// genome is shape C's whole point.
///
/// FLOORS. A `variants` phase keeps at least 2 tasks even when every brief is
/// identical, because "run the same brief N times and judge the spread" is a
/// legitimate thing to ask for and a tournament of one is not a tournament.
/// Everywhere else the floor is 1.
pub fn collapse(arena: Allocator, briefs: []const []const u8, genomes: []const ?[]const u8, variants_phase: bool) Collapse {
    const n = briefs.len;
    if (n < 2 or n > max_briefs) return identity(arena, n);
    const floor: usize = if (variants_phase) 2 else 1;
    const rep = arena.alloc(usize, n) catch return identity(arena, n);
    const words = arena.alloc(u64, max_words) catch return identity(arena, n);
    const grams = arena.alloc(u64, n * max_words) catch return identity(arena, n);
    const sets = arena.alloc([]const u64, n) catch return identity(arena, n);
    for (briefs, sets, 0..) |brief, *set, k| {
        set.* = gramSet(grams[k * max_words ..][0..max_words], wordHashes(words, brief));
    }
    var alive: usize = n;
    for (rep, 0..) |*r, i| r.* = i;
    for (0..n) |i| {
        if (rep[i] != i) continue; // already collapsed into someone else
        for (i + 1..n) |j| {
            if (rep[j] != j or alive <= floor) continue;
            const gi = genomes[i];
            const gj = genomes[j];
            const same_genome = (gi == null and gj == null) or
                (gi != null and gj != null and genomeSha(gi.?) == genomeSha(gj.?));
            if (!same_genome) continue;
            // An exact brief match always collapses, whatever the shingle
            // metric says — a brief too short to shingle (gramSet folds it to
            // one gram) would otherwise depend on hash luck.
            const exact = std.mem.eql(u8, briefs[i], briefs[j]);
            if (!exact and jaccard(sets[i], sets[j]) < collapse_threshold) continue;
            rep[j] = i;
            alive -= 1;
        }
    }
    const survivors = arena.alloc(usize, alive) catch return identity(arena, n);
    var s: usize = 0;
    for (rep, 0..) |r, i| if (r == i) {
        survivors[s] = i;
        s += 1;
    };
    return .{ .rep = rep, .survivors = survivors[0..s] };
}

/// The manifest line a collapsed phase carries, or "" when nothing collapsed.
/// The root reads the manifest, so this is where "you asked for five workers
/// and got three because two were copies" becomes visible instead of silent.
pub fn collapseNote(arena: Allocator, c: Collapse) []const u8 {
    if (c.collapsed() == 0) return "";
    return std.fmt.allocPrint(
        arena,
        "collapsed {d} duplicate brief(s): same system_prompt and >={d:.0}% identical text, so they " ++
            "spawned once and the survivor's result was fanned into every duplicate's slot.",
        .{ c.collapsed(), collapse_threshold * 100 },
    ) catch "";
}

/// Cap on the phase label copied into the trace line, matching
/// route_trace.field_cap: a model-authored title must not be able to turn one
/// trace record into a megabyte.
const label_cap = 64;

/// The whole gate as one call, because both call sites are files at (or one
/// line from) the 600-line cap and can afford exactly one statement each.
/// Measures, records, prints, and returns the root-facing line — "" when the
/// fleet is fine or too small to judge. `genomes` is the parallel per-task
/// `system_prompt` slice (pass `&.{}` when the call site has none).
///
/// The measurement is traced for EVERY fleet, not only the ones that warn: a
/// run that stayed quiet is the evidence that the gate was actually looking,
/// and the numbers are what a future threshold re-tune reads.
pub fn check(arena: Allocator, tracer: ?*trace.Tracer, phase: []const u8, briefs: []const []const u8, genomes: []const ?[]const u8) []const u8 {
    const persona = personaAxis(arena, briefs, genomes);
    var r = analyze(arena, persona orelse briefs);
    if (persona != null) r.axis = .system_prompt;
    if (r.n < min_fleet) return "";
    var buf: [160]u8 = undefined;
    const detail = std.fmt.bufPrint(&buf, "n={d} mean={d:.3} threshold={d:.2} axis={s} warn={}", .{ r.n, r.mean, warn_threshold, @tagName(r.axis), r.warn }) catch "";
    if (tracer) |tr| tr.note("diversity", detail);
    // #382 increment 3, done additively: a NEW `kind:"diversity"` row rather
    // than an extra column on the #372 `kind:"score"` rows, so an offline
    // reader can join brief diversity to that run's judge outcomes without a
    // single existing row shape changing underneath it.
    if (trace.g_traj) |tj| tj.node(.{
        .kind = "diversity",
        .phase = util.utf8Prefix(phase, label_cap),
        .n = r.n,
        .mean = r.mean,
        .threshold = warn_threshold,
        .axis = @tagName(r.axis),
        .warn = r.warn,
        .t = tj.elapsedMs(),
    });
    const text = warningText(arena, r) orelse return "";
    // Its own prefix rather than the caller's: this fires from the workflow
    // phase loop AND from a bare sibling-spawn batch, where "[workflow]"
    // would name a workflow that never ran.
    tick_gate.workerPrint("  [diversity] {s}\n", .{text});
    return text;
}

/// The OTHER fan-out: N sibling `subagent` spawns arriving in ONE tool batch,
/// which is a fleet the harness never named as one. `calls`/`results` are the
/// runTools batch (taken as anytype so this stays off tools.zig's import
/// graph); `ext` indexes the external calls actually dispatched.
///
/// The note is prepended to the FIRST sibling's result rather than emitted on
/// its own, because a tool result is the only channel a batch has back to the
/// root — and prepending puts it above text that toolPreviewText may have
/// truncated. Best-effort throughout: this must never be able to fail a spawn
/// that already succeeded, so every unhappy path is a bare return.
pub fn noteSiblingBatch(arena: Allocator, tracer: ?*trace.Tracer, calls: anytype, ext: []const usize, results: anytype) void {
    var briefs: [max_briefs][]const u8 = undefined;
    var genomes: [max_briefs]?[]const u8 = undefined;
    var first: usize = 0;
    var n: usize = 0;
    for (ext) |i| {
        if (n == max_briefs) break;
        const call = calls[i];
        if (!std.mem.eql(u8, call.name, "subagent") or call.input != .object) continue;
        const p = call.input.object.get("prompt") orelse continue;
        if (p != .string or p.string.len == 0) continue;
        if (n == 0) first = i;
        briefs[n] = p.string;
        // Same resolution the workflow path uses, so an `agent:"reviewer"`
        // fleet is read on its personas there and here alike.
        genomes[n] = fleet.resolveOverride(call.input.object);
        n += 1;
    }
    if (n < min_fleet) return;
    const text = check(arena, tracer, "subagent batch", briefs[0..n], genomes[0..n]);
    if (text.len == 0) return;
    results[first].text = std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ text, results[first].text }) catch return;
}

test {
    _ = @import("brief_diversity_tests.zig");
}
