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
pub fn personaAxis(arena: Allocator, briefs: []const []const u8, genomes: []const ?[]const u8) ?[]const []const u8 {
    if (genomes.len != briefs.len) return null;
    for (genomes) |g| if (g == null or g.?.len == 0) return null;
    const out = arena.alloc([]const u8, genomes.len) catch return null;
    for (genomes, out) |g, *o| o.* = g.?;
    return out;
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
    std.debug.print("  [diversity] {s}\n", .{text});
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
