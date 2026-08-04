//! Tests for the MAP-Elites slot axis (#290) — the third cell coordinate.
//!
//! Split into its own file because scoring.zig and subagent.zig are both at or
//! near the 600-line cap. Pulled into the test root via src/main.zig's `test {}`
//! hook: without that reference these tests compile to nothing and the suite
//! still reports green (the exact trap that made #291's 9 new tests dead).

const std = @import("std");
const scoring = @import("scoring.zig");
const shapes = @import("shapes.zig");

test "telemetrySlot: canonical vocabulary passes through, case-insensitively" {
    for (shapes.canonical_slots) |slot|
        try std.testing.expectEqualStrings(slot, scoring.telemetrySlot(slot));
    try std.testing.expectEqualStrings("verify", scoring.telemetrySlot("VERIFY"));
    try std.testing.expectEqualStrings("synthesize", scoring.telemetrySlot("Synthesize"));
}

test "telemetrySlot: anything off-vocabulary is uncelled, never hashed, never echoed" {
    // This is the privacy property the whole slot design rests on. telemetryNiche
    // hashes free-form input to custom-<hex>; a slot must do NEITHER that nor echo
    // the input, because a per-title hash mints a private cell nothing can join
    // against, and echoing would put user task labels on the wire in cleartext.
    const leaky = [_][]const u8{
        "Migrate Acme billing schema",
        "/Users/someone/secret-project",
        "find", // NB: canonical only as a bare word; see the compound cases below
        "code review",
        "",
        "custom-deadbeefdeadbeef",
    };
    for (leaky) |v| {
        const got = scoring.telemetrySlot(v);
        if (got.len == 0) continue; // uncelled: the safe outcome
        // Whatever came back must be a member of the closed vocabulary — never a
        // fingerprint, never a substring of the caller's text.
        var member = false;
        for (shapes.canonical_slots) |slot| if (std.mem.eql(u8, slot, got)) {
            member = true;
        };
        try std.testing.expect(member);
        try std.testing.expect(!std.mem.startsWith(u8, got, "custom-"));
    }
    // Free-form titles specifically must be dropped, not projected.
    try std.testing.expectEqualStrings("", scoring.telemetrySlot("Migrate Acme billing schema"));
    try std.testing.expectEqualStrings("", scoring.telemetrySlot("/Users/someone/secret-project"));
}

test "canonicalSlot + telemetrySlot compose: a real phase title reaches a cell or nothing" {
    // The production path is telemetrySlot(canonicalSlot(title)).
    const compose = struct {
        fn f(title: []const u8) []const u8 {
            return scoring.telemetrySlot(shapes.canonicalSlot(title));
        }
    }.f;
    // Titles the shape catalog tells the model to use land in their cell.
    try std.testing.expectEqualStrings("find", compose("find security bugs"));
    try std.testing.expectEqualStrings("verify", compose("verify each finding"));
    try std.testing.expectEqualStrings("synthesize", compose("Synthesize the results"));
    // #296 — `transform` is a PIPELINE stage label. It was dropped while no
    // stage could be scored, and rejoined the vocabulary with the stage-level
    // capture (pipeline_score.zig): a transform stage now reaches its cell
    // like any phase slot; see the D-shape comment in shapes.zig.
    try std.testing.expectEqualStrings("transform", compose("transform each file"));
    // A customer name in a phase title reaches no cell and leaves no plaintext.
    try std.testing.expectEqualStrings("", compose("Migrate Acme billing schema"));
    // And the composed result is always vocabulary-or-empty, never caller text.
    for ([_][]const u8{ "Migrate Acme billing", "ponder deeply", "", "x" }) |t| {
        const got = compose(t);
        if (got.len > 0) {
            var member = false;
            for (shapes.canonical_slots) |slot| if (std.mem.eql(u8, slot, got)) {
                member = true;
            };
            try std.testing.expect(member);
        }
    }
}

test "slot never widens the niche: the signed niche stays exactly the agent name" {
    // Regression guard for the design error that sank the first #290 attempt:
    // the composite "agent/tier/slot" string was fed to signScore AND to the
    // fleet niche, where telemetryNiche hashed it to custom-<hex> — so the score
    // record and the fleet record named two different cells and stopped joining.
    // The slot must therefore never be concatenated into a niche.
    var buf: [23]u8 = undefined;
    try std.testing.expectEqualStrings("reviewer", scoring.telemetryNiche(&buf, "reviewer"));
    // If anyone reintroduces a composite, this is what it would do:
    try std.testing.expect(std.mem.startsWith(u8, scoring.telemetryNiche(&buf, "reviewer/frontier/verify"), "custom-"));
}
