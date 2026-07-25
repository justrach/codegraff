//! Files the zero-configuration learning bootstrap writes into a workspace.
//!
//! `graff learn init` (no flags) has to produce a *pinned* setup: every adapter
//! and suite is content-addressed in the immutable configuration, so the bytes
//! must come from somewhere stable. Embedding the shipped adapters means a
//! workspace never needs a repository checkout, and the pin matches whatever
//! binary wrote the kit.

const std = @import("std");

pub const Asset = struct {
    /// File name inside the materialized kit directory. Adapters keep their
    /// module names: the evaluator imports learn_graff_case/learn_behavior_metrics
    /// by path, and the suite generator imports learn_graff_suites by name.
    name: []const u8,
    bytes: []const u8,
};

pub const mutator_name = "learn_graff_mutator.py";
pub const evaluator_name = "learn_graff_evaluator.py";
pub const case_name = "learn_graff_case.py";
pub const behavior_name = "learn_behavior_metrics.py";
pub const suites_name = "learn_graff_suites.py";
pub const generate_name = "learn_generate_suites.py";
pub const scorer_name = "score_run.py";

pub const kit = [_]Asset{
    .{ .name = mutator_name, .bytes = @embedFile("learn_kit_mutator") },
    .{ .name = evaluator_name, .bytes = @embedFile("learn_kit_evaluator") },
    .{ .name = case_name, .bytes = @embedFile("learn_kit_case") },
    .{ .name = behavior_name, .bytes = @embedFile("learn_kit_behavior") },
    .{ .name = suites_name, .bytes = @embedFile("learn_kit_suites") },
    .{ .name = generate_name, .bytes = @embedFile("learn_kit_generate") },
    .{ .name = scorer_name, .bytes = @embedFile("learn_kit_scorer") },
};

test "every embedded learning asset is a non-empty executable Python script" {
    var seen: usize = 0;
    for (kit) |asset| {
        try std.testing.expect(asset.bytes.len > 128);
        try std.testing.expect(std.mem.startsWith(u8, asset.bytes, "#!/usr/bin/env python3"));
        try std.testing.expect(std.mem.endsWith(u8, asset.name, ".py"));
        for (kit[0..seen]) |prior| try std.testing.expect(!std.mem.eql(u8, prior.name, asset.name));
        seen += 1;
    }
    try std.testing.expectEqual(kit.len, seen);
}
