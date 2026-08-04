//! The session's memory of what actually FAILED, and the closed list of
//! verifiers that make a deep solo retry admissible.
//!
//! Weng's revision rule, encoded: sequential self-correction pays only when
//! external feedback exists to catch the second miss — without a verifier a
//! "think harder" retry converts right answers into wrong ones as often as
//! the reverse. So the R0d rung (escalation.zig) is gated on `verifierFor`
//! returning something checkable, and the retry brief carries the concrete
//! failure the harness itself observed (an all-failed fleet abort, a RED
//! eval verdict) — never a worker's self-report, per the edit-contract
//! doctrine that verification reads real signals, not claims.
//!
//! A leaf module on purpose: escalation.zig re-exports it, but edit_contract
//! and agent_eval also write here, and escalation already imports
//! edit_contract — the ledger has to sit below all three to stay off the
//! import cycle.

const std = @import("std");

const shapes = @import("shapes.zig");
const util = @import("util.zig");

const TaskClass = shapes.TaskClass;
const n_classes = std.enums.values(TaskClass).len;

/// Bytes of evidence kept per task class. One failure's head is worth more
/// than three failures' tails: the ledger keeps the LATEST note whole rather
/// than concatenating, because the retry acts on one concrete signal, not a
/// history.
pub const evidence_cap = 320;

var g_evidence: [n_classes][evidence_cap]u8 = undefined;
var g_len: [n_classes]usize = @splat(0);

/// Record harness-observed failure evidence for `tc`, flattened to one line
/// (the advisory embeds it under a header; a newline would break brief
/// layout) and capped at a UTF-8 boundary. Latest note wins whole.
pub fn note(tc: TaskClass, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const head = util.utf8Prefix(trimmed, evidence_cap);
    const slot = &g_evidence[@intFromEnum(tc)];
    for (slot[0..head.len], head) |*d, s| d.* = if (s == '\n' or s == '\r' or s == '\t') ' ' else s;
    g_len[@intFromEnum(tc)] = head.len;
}

pub fn evidence(tc: TaskClass) []const u8 {
    return g_evidence[@intFromEnum(tc)][0..g_len[@intFromEnum(tc)]];
}

/// Session reset — escalation.resetSession forwards here so one call clears
/// every piece of cross-invocation ladder state.
pub fn reset() void {
    g_len = @splat(0);
}

/// What could catch a second miss on this class of ask. `diff` is the edit
/// contract's porcelain probe: bugfix/refactor/feature work is contracted to
/// mutate, so "did the tree move, and do the checks pass on it" is checkable
/// without a model. review/research/other have no free signal — for those the
/// R3 judges ARE the external feedback, so a solo revision loop is refused.
pub const Verifier = enum { none, diff, eval };

pub fn verifierFor(tc: TaskClass, has_eval: bool) Verifier {
    if (has_eval) return .eval;
    return switch (tc) {
        .bugfix, .refactor, .feature => .diff,
        .review, .research, .other => .none,
    };
}

test "note/evidence: flattened, capped on a UTF-8 boundary, latest wins whole" {
    reset();
    defer reset();
    note(.bugfix, "  line one\nline\ttwo\r\n");
    try std.testing.expectEqualStrings("line one line two", evidence(.bugfix));
    // Per class: a bugfix note says nothing about research.
    try std.testing.expectEqualStrings("", evidence(.research));
    // Latest wins whole — no concatenation.
    note(.bugfix, "second failure");
    try std.testing.expectEqualStrings("second failure", evidence(.bugfix));
    // Capped, and never mid-codepoint: a multi-byte char straddling the cap
    // is dropped entirely rather than split into invalid UTF-8.
    var big: [evidence_cap + 8]u8 = @splat('a');
    big[evidence_cap - 1] = 0xE2; // first byte of a 3-byte sequence
    big[evidence_cap] = 0x86;
    big[evidence_cap + 1] = 0x92;
    note(.feature, &big);
    try std.testing.expect(evidence(.feature).len < evidence_cap);
    try std.testing.expect(std.unicode.utf8ValidateSlice(evidence(.feature)));
}

test "verifierFor: diff-checkable classes gate open, report-only classes stay shut" {
    try std.testing.expectEqual(Verifier.diff, verifierFor(.bugfix, false));
    try std.testing.expectEqual(Verifier.diff, verifierFor(.refactor, false));
    try std.testing.expectEqual(Verifier.diff, verifierFor(.feature, false));
    try std.testing.expectEqual(Verifier.none, verifierFor(.review, false));
    try std.testing.expectEqual(Verifier.none, verifierFor(.research, false));
    try std.testing.expectEqual(Verifier.none, verifierFor(.other, false));
    // A configured eval loop is the strongest verifier and covers any class.
    try std.testing.expectEqual(Verifier.eval, verifierFor(.research, true));
}
