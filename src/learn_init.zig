//! `graff learn init`, both shapes: the hand-written parent/config pair and the
//! zero-configuration bootstrap that generates that pair from this binary.
//! Split out of learn_cli.zig (600-line goal).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const store_mod = @import("learn_store.zig");
const learn_run = @import("learn_run.zig");
const bootstrap = @import("learn_bootstrap.zig");
const credentials = @import("learn_credentials.zig");
const util = @import("util.zig");

pub const Args = struct {
    parent: ?[]const u8 = null,
    config: ?[]const u8 = null,
    candidates: ?usize = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Default arms per trial. Two is the smallest count that is still a
/// tournament, and every extra arm costs a full suite of paired evaluations.
const default_candidates: usize = 2;

/// Generate the whole pinned setup from this binary, then initialize the store
/// from it exactly as a hand-written pair would.
pub fn zeroConfig(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    args: Args,
    out: *Io.Writer,
) !void {
    const detected = credentials.resolveTarget(io, arena, environ);
    const provider = args.provider orelse detected.provider;
    const model = args.model orelse if (args.provider) |id| credentials.defaultModelFor(id) else detected.model;
    const pass_env = try credentials.passEnvFor(arena, provider);
    const prepared = try bootstrap.prepare(gpa, arena, io, .{
        .provider = provider,
        .model = model,
        .pin_effort = credentials.pinsEffort(provider, model),
        .candidates = args.candidates orelse default_candidates,
    }, pass_env, out);
    try fromPaths(gpa, arena, io, .{ .parent = prepared.parent, .config = prepared.config }, out);
    try out.print(
        \\learning target {s}/{s} with {d} candidate arm(s)
        \\kit {s}
        \\next: graff learn run --auto   (or let the automatic trigger start it)
        \\
    , .{ prepared.provider, prepared.model, prepared.candidates, prepared.kit });
}

/// Every configured pin is re-verified here and at every later promotion
/// boundary, so a changed or deleted adapter/suite fails closed.
pub fn verifyPins(io: Io, arena: Allocator, config: store_mod.Config) !void {
    try store_mod.verifyProgram(io, config.mutator);
    try store_mod.verifyProgram(io, config.evaluator);
    const primary_suite = try store_mod.loadSuite(io, arena, config.evaluation_suite);
    try store_mod.validateSuitePower(primary_suite.manifest, config.gate);
    if (config.holdout_suite) |suite| {
        const holdout_suite = try store_mod.loadSuite(io, arena, suite);
        try store_mod.validateHoldoutIndependence(
            config.evaluation_suite.sha256,
            primary_suite.manifest,
            suite.sha256,
            holdout_suite.manifest,
        );
        try store_mod.validateSuitePower(holdout_suite.manifest, config.gate);
    }
}

pub fn fromPaths(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    args: Args,
    out: *Io.Writer,
) !void {
    const config_bytes = try store_mod.readFileNoFollow(io, Io.Dir.cwd(), args.config.?, arena, store_mod.max_config_bytes);
    const config = try std.json.parseFromSliceLeaky(store_mod.Config, arena, config_bytes, .{});
    try store_mod.validateConfig(config);
    try verifyPins(io, arena, config);
    try learn_run.verifyTrialPower(io, arena, config, config.gate.default_candidates);
    const parent = try store_mod.readFileNoFollow(io, Io.Dir.cwd(), args.parent.?, arena, config.limits.genome_bytes);
    // Validate the genome BEFORE creating the store tree: a rejected parent
    // must not leave a half-initialized .graff/learn behind (which used to
    // wedge every later init with AlreadyInitialized).
    if (!std.unicode.utf8ValidateSlice(parent) or
        std.mem.indexOfScalar(u8, parent, 0) != null or
        std.mem.trim(u8, parent, " \t\r\n").len == 0) return error.InvalidParentGenome;

    var store = try store_mod.Store.initAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(0);
    defer lock.deinit();
    const genome_id = try store.bootstrap(gpa, arena, config_bytes, parent, util.unixMs(io));
    try out.print("initialized learned agent '{s}'\nactive genome {s}\n", .{ config.agent_name, genome_id });
}

test {
    // build.zig's test root is main.zig, which reaches learn_cli and therefore
    // this module; the automatic-loop modules hang off here so their tests run.
    _ = @import("learn_assets.zig");
    _ = @import("learn_bootstrap.zig");
    _ = @import("learn_credentials.zig");
    _ = @import("learn_auto.zig");
}
