//! Ultracode orchestration shapes (#293): the fixed catalog of default
//! multi-agent workflow shapes, the canonical slot vocabulary those shapes
//! name their phases with, and the steering text appended to an ultracode
//! turn.
//!
//! Lives outside pickers.zig (which owns the steering call site) for two
//! reasons: pickers.zig is at the 600-line cap, and the slot vocabulary is
//! not a picker concern — it is the third component of the MAP-Elites cell
//! key (#290). Keeping this a std-only leaf module, prompts.zig-style, lets
//! both the steering path and the fleet scoring path import it with no cycle.
//!
//! Why a fixed catalog at all: left to itself the model authors a different
//! workflow shape every run, so two scores for the same persona are not
//! comparable — the structure varied underneath them. A closed catalog with
//! named slots makes "reviewer prompt, mid tier, verify slot" a cell that
//! accrues real fitness across runs.

const std = @import("std");

/// Canonical phase/stage labels an ultracode workflow names its slots with.
///
/// This is the closed vocabulary behind the third component of the composite
/// niche key (#290). A prompt variant's fitness is only comparable to another
/// variant scored in the SAME slot, so the set has to be stable — free-text
/// phase titles would mint a fresh cell per run and nothing would ever
/// accumulate enough samples to promote.
pub const canonical_slots = [_][]const u8{
    // A — review/audit
    "find",
    "verify",
    "synthesize",
    // B — research/understand
    "sweep",
    // C — design/solve
    "variants",
    "build",
    // D — migration/mechanical.
    // KNOWN GAP: pipeline stages call runSub directly and never reach the
    // variant-scoring path, so a spec-compliant `transform` stage cannot fill
    // its cell today — it is scoreable only via an off-catalog phase of the same
    // name. Kept in the vocabulary because it is the right name and becomes
    // reachable the moment pipeline stages are scored; see the pipeline-scoring
    // issue. Migration execution is unaffected — only learning/promotion is.
    "transform",
    // E — feature
    "scope",
    "implement",
    "review",
};

/// The first alphanumeric token of `label`, lowercased into `buf`.
/// Returns an empty slice when the label has no leading ASCII word.
///
/// A byte >= 0x80 during the leading skip aborts the scan. Without that, the
/// bytes of a non-ASCII leading word are each individually non-alphanumeric and
/// get skipped as if they were punctuation, so a LATER word becomes the apparent
/// first word: `canonicalSlot("安全 review")` returned `review`, filing that
/// phase's fitness into a cell it does not belong to. Non-ASCII text is not a
/// canonical slot, so refusing to look past it is both correct and conservative
/// — the label is simply uncelled.
fn firstWord(buf: []u8, label: []const u8) []const u8 {
    var start: usize = 0;
    while (start < label.len and !std.ascii.isAlphanumeric(label[start])) : (start += 1) {
        if (label[start] >= 0x80) return buf[0..0];
    }
    var n: usize = 0;
    var i = start;
    while (i < label.len and std.ascii.isAlphanumeric(label[i]) and n < buf.len) : (i += 1) {
        buf[n] = std.ascii.toLower(label[i]);
        n += 1;
    }
    return buf[0..n];
}

/// Normalize a free-text phase title / pipeline stage label to a canonical
/// slot, or "" when it matches none.
///
/// Matching is on the label's FIRST WORD only, case-insensitively. That is
/// deliberately narrow: a substring rule would make "review the findings"
/// ambiguous between `review` and `find`, and which one won would depend on
/// array order rather than on what the phase actually does. First-word
/// matching keeps natural titles working ("find security bugs" -> `find`,
/// "synthesize the results" -> `synthesize`) with no ordering hazard.
///
/// An unrecognized label maps to "" (uncelled) rather than minting a new cell
/// — an off-vocabulary phase still runs, it just does not accrue fitness.
pub fn canonicalSlot(label: []const u8) []const u8 {
    var buf: [32]u8 = undefined;
    const word = firstWord(&buf, label);
    if (word.len == 0) return "";
    for (canonical_slots) |slot| {
        if (std.mem.eql(u8, slot, word)) return slot;
    }
    return "";
}

/// The shape catalog appended to every ultracode turn. Kept tight on purpose:
/// this rides along on each turn of an opt-in mode, so it should buy structure
/// per token rather than restate what the workflow tool's schema already says.
pub const shape_catalog_note =
    \\Pick ONE shape below and instantiate it with the workflow tool. Title each
    \\phase with its slot word exactly — the fleet keys a variant's fitness on
    \\that slot, and an off-vocabulary title makes the round unscoreable.
    \\
    \\A review/audit — there is a diff, or the ask is review/audit/find bugs:
    \\  find       one reviewer per dimension (correctness, security, perf, tests), parallel
    \\  verify     one skeptic per finding, told to REFUTE it; gate with when:"FINDING"
    \\  synthesize one task; findings ranked most-severe first
    \\B research/understand — the ask is a question about how something works:
    \\  sweep      researchers each searching a DIFFERENT way (by symbol, by callers,
    \\             by git history, by tests); tell them not to duplicate each other
    \\  synthesize one map
    \\C design/solve — open-ended "how should we…":
    \\  variants   N implementers, same task, a DIFFERENT system_prompt each
    \\             (MVP-first / risk-first / perf-first); 2+ variants are auto-judged
    \\  build      synthesize from the winner, grafting the runners-up's best ideas
    \\D migration/mechanical — the same edit across many files:
    \\  use pipeline, NOT phases: {"pipeline":{"items":[…],"stages":[transform, verify]}}
    \\  each item flows independently, so no item waits on any other
    \\E feature — build something new:
    \\  scope → implement → review
    \\
    \\Scale to the ask: "find bugs" is 3 finders + 1 verify; "thoroughly audit" is
    \\6 finders + 3-vote adversarial verify + synthesize. Use phases only when a
    \\phase genuinely needs ALL of the previous one; per-item work belongs in
    \\pipeline.
    \\
    \\isolation:"worktree" ONLY for tasks that edit files IN PARALLEL within one
    \\phase and whose edits nothing downstream has to read. Every task gets its
    \\OWN worktree branched from HEAD, so a later stage cannot see an earlier
    \\stage's edits. Never set it on a dependent chain (transform then verify,
    \\implement then review) — those stages must share the working tree or the
    \\reviewer inspects the original file and the edits are stranded.
;

test "canonicalSlot: exact, first-word, and miss" {
    // Bare slot words map to themselves.
    for (canonical_slots) |slot| try std.testing.expectEqualStrings(slot, canonicalSlot(slot));
    // Natural titles match on their first word.
    try std.testing.expectEqualStrings("find", canonicalSlot("find security bugs"));
    try std.testing.expectEqualStrings("synthesize", canonicalSlot("Synthesize the results"));
    try std.testing.expectEqualStrings("verify", canonicalSlot("VERIFY each finding"));
    // Leading punctuation/whitespace is skipped.
    try std.testing.expectEqualStrings("sweep", canonicalSlot("  - sweep the repo"));
    // The ordering hazard a substring rule would have: this is `review`, not `find`.
    try std.testing.expectEqualStrings("review", canonicalSlot("review the findings"));
    // A leading NON-ASCII word must not be skipped past. Each of its bytes is
    // individually non-alphanumeric, so the old scan treated them as punctuation
    // and promoted a later word to "first", filing the phase into a cell it does
    // not belong to. Uncelled is the correct answer.
    try std.testing.expectEqualStrings("", canonicalSlot("安全 review"));
    try std.testing.expectEqualStrings("", canonicalSlot("修复 implement billing"));
    try std.testing.expectEqualStrings("", canonicalSlot("→ verify"));
    // Non-ASCII AFTER a valid leading ASCII word is harmless.
    try std.testing.expectEqualStrings("review", canonicalSlot("review 安全"));
    try std.testing.expectEqualStrings("find", canonicalSlot("find — bugs"));
    // Off-vocabulary titles are uncelled rather than minting a new cell.
    try std.testing.expectEqualStrings("", canonicalSlot("code review"));
    try std.testing.expectEqualStrings("", canonicalSlot("ponder"));
    try std.testing.expectEqualStrings("", canonicalSlot(""));
    try std.testing.expectEqualStrings("", canonicalSlot("---"));
}

test "canonicalSlot: a word longer than the scratch buffer cannot match or overflow" {
    const long = "a" ** 200;
    try std.testing.expectEqualStrings("", canonicalSlot(long));
    // A canonical slot followed by a very long tail still matches on word one.
    try std.testing.expectEqualStrings("find", canonicalSlot("find " ++ long));
}

test "shape catalog names every canonical slot it depends on" {
    // Guards the seam with #290: if a slot is added to the vocabulary but the
    // catalog never tells the model to use it, that cell can never be filled.
    for (canonical_slots) |slot| {
        try std.testing.expect(std.mem.indexOf(u8, shape_catalog_note, slot) != null);
    }
}

test "shape catalog covers all five shapes and stays within a sane token budget" {
    for ([_][]const u8{ "A review/audit", "B research/understand", "C design/solve", "D migration/mechanical", "E feature" }) |shape| {
        try std.testing.expect(std.mem.indexOf(u8, shape_catalog_note, shape) != null);
    }
    // It rides on every ultracode turn; keep it from silently ballooning.
    try std.testing.expect(shape_catalog_note.len < 2048);
}

test "shape catalog never tells a dependent chain to isolate into worktrees" {
    // Regression guard for the worst bug the catalog's own first review found.
    // It used to say "give file-editing tasks isolation:worktree so they cannot
    // collide". Every task gets its OWN worktree branched from HEAD, so on a
    // dependent chain (transform -> verify, implement -> review) the later stage
    // read the ORIGINAL file: a workflow could report a successful implement +
    // review while the edits never reached the caller's tree at all.
    try std.testing.expect(std.mem.indexOf(u8, shape_catalog_note, "IN PARALLEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, shape_catalog_note, "Never set it on a dependent chain") != null);
    // The old unconditional phrasing must not come back.
    try std.testing.expect(std.mem.indexOf(u8, shape_catalog_note, "Give file-editing tasks isolation") == null);
}
