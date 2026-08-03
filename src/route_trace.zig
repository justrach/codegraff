//! #372 — the observability half of learned orchestration: emitting one
//! worker's routing decision, and capturing a scored one back into the local
//! DGM archive so the policy in route_policy.zig has something to learn from.
//!
//! Split from route_policy.zig (which owns the decision TYPES and the policy
//! itself) both to stay under the 600-line cap and because the two halves
//! have opposite dependency shapes: the policy is a leaf over shapes/bench,
//! while emission reaches the tracer, the trajectory archive, and the --json
//! protocol stream.
//!
//! Three sinks, one call:
//!
//!   tracer     `{"ev":"route","detail":"shape=… role=… source=…"}` in
//!              .graff/traces/<run>.jsonl — the diagnostics path a user
//!              greps to answer "why did this worker get that model".
//!   trajectory `{"kind":"route", …}` in .graff/trajectories/<run>.jsonl —
//!              the same fact as structured columns, so an offline reader can
//!              reconstruct which policy ran without parsing the line.
//!   --json     an additive `agent_route` event on the shared stdout stream,
//!              carrying the worker's label so a UI can pair it with the
//!              `workflow_progress` task row it belongs to.
//!
//! Best-effort everywhere: a routing trace must never be able to fail a
//! spawn, so every error path is a silent return.

const std = @import("std");
const Io = std.Io;

const policy = @import("route_policy.zig");
const Cell = policy.Cell;
const Decision = policy.Decision;
const Shape = policy.Shape;
const Source = policy.Source;

const trace = @import("trace.zig");
const util = @import("util.zig");
const main_mod = @import("main.zig");
const protocol_seq = @import("protocol_seq.zig");
const scoring = @import("scoring.zig");
const selection = @import("subagent_selection.zig");
const Provider = @import("provider.zig").Provider;

/// Model-authored labels are capped so one absurd description cannot turn a
/// route line into a megabyte of JSONL (workflow_progress.label_cap's rule).
const field_cap = 64;
const line_cap = 320;

pub const RouteEvent = struct {
    type: []const u8 = "agent_route",
    /// The worker's own description/label, so a UI can pair this with the
    /// workflow_progress task row it belongs to.
    task: []const u8,
    shape: []const u8,
    role: []const u8,
    tier: []const u8,
    resolved_model: []const u8,
    provider: []const u8,
    source: []const u8,
    policy_or_genome_id: []const u8,
};

/// Test seam, mirroring workflow_progress.g_test_sink: when set, the --json
/// event renders here instead of stdout.
pub var g_test_sink: ?*Io.Writer.Allocating = null;

fn guiEmit(io: Io, ev: RouteEvent) void {
    if (g_test_sink) |sink| {
        var s: std.json.Stringify = .{ .writer = &sink.writer };
        s.write(ev) catch return;
        sink.writer.writeByte('\n') catch return;
        return;
    }
    if (!main_mod.json_mode) return;
    const w = main_mod.g_out orelse return;
    // The same lock guiEmit/printDelta take: workers emit from pool threads,
    // and a half-written line would corrupt the SDK's JSONL parse.
    main_mod.g_gui_mu.lockUncancelable(io);
    defer main_mod.g_gui_mu.unlock(io);
    protocol_seq.writeEvent(w, ev) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

fn tierName(t: ?policy.Tier) []const u8 {
    return if (t) |x| x.label() else "";
}

/// Emit one worker's routing decision on all three paths at once.
pub fn emit(io: Io, tracer: ?*trace.Tracer, label: []const u8, provider_id: []const u8, d: Decision) void {
    var buf: [line_cap]u8 = undefined;
    if (tracer) |tr| tr.note("route", policy.formatDecision(&buf, d));
    if (trace.g_traj) |tj| tj.node(.{
        .kind = "route",
        .label = util.utf8Prefix(label, field_cap),
        .shape = d.shape.label(),
        .role = d.role,
        .tier = tierName(d.tier),
        .model = d.resolved_model,
        .provider = provider_id,
        .source = d.source.label(),
        .policy_or_genome_id = d.policy_id,
        .t = tj.elapsedMs(),
    });
    guiEmit(io, .{
        .task = util.utf8Prefix(label, field_cap),
        .shape = d.shape.label(),
        .role = d.role,
        .tier = tierName(d.tier),
        .resolved_model = d.resolved_model,
        .provider = provider_id,
        .source = d.source.label(),
        .policy_or_genome_id = d.policy_id,
    });
}

/// Build and emit the decision for one spawned worker. `genome` is what
/// `policy_or_genome_id` reports for a decision fleet fitness did NOT make:
/// the root-authored system-prompt fingerprint, the persona niche, or "" for
/// a plain inherit. The tier is read BACK off the resolved model, so a worker
/// that stated no tier still reports the rung it actually landed on — which
/// is the whole point: an inherited route was previously invisible.
pub fn emitSpawn(
    io: Io,
    tracer: ?*trace.Tracer,
    label: []const u8,
    provider_id: []const u8,
    model: []const u8,
    cell: Cell,
    source: Source,
    genome: []const u8,
) void {
    var pbuf: [128]u8 = undefined;
    const tier = policy.tierOf(provider_id, model);
    const policy_id = switch (source) {
        .learned_policy => if (tier) |t| policy.cellId(&pbuf, cell, t) else "",
        .ladder => std.fmt.bufPrint(&pbuf, "ladder:{s}", .{provider_id}) catch "",
        else => util.utf8Prefix(genome, field_cap),
    };
    emit(io, tracer, label, provider_id, .{
        .shape = cell.shape,
        .role = cell.role,
        .tier = tier,
        .resolved_model = model,
        .source = source,
        .policy_id = policy_id,
    });
}

/// What an UNPINNED worker inherited. A session whose worker route came from
/// the #291 ladder descent reports `ladder`; an explicit --subagent-model (or
/// a plain inherit-the-root) reports `session-default`. Conflating the two is
/// exactly the blindness #372 is about.
pub fn sessionSource(session_pinned: bool) Source {
    return if (session_pinned and selection.g_default_from_ladder) .ladder else .session_default;
}

/// emitSpawn for an already-resolved child Provider — the spawn-site
/// convenience. Fingerprints an inline root-authored genome for
/// `policy_or_genome_id`, else names the persona niche the worker ran under.
pub fn emitSpawnProvider(
    io: Io,
    tracer: ?*trace.Tracer,
    label: []const u8,
    child: Provider,
    cell: Cell,
    source: Source,
    sys_override: ?[]const u8,
    niche: []const u8,
) void {
    var fp: [16]u8 = undefined;
    if (sys_override) |so| fp = scoring.promptFingerprint(so);
    emitSpawn(io, tracer, label, child.id, child.model, cell, source, if (sys_override != null) &fp else niche);
}

/// Local DGM capture of one SCORED worker configuration (#372 part 2): the
/// same `kind:"score"` row the eval loop already writes, plus the cell
/// coordinates route_policy.foldCells partitions on. Deliberately OUTSIDE the
/// telemetry gate — a default-local-privacy session must accumulate its own
/// policy evidence with zero egress, exactly like agent_eval's local capture.
pub fn captureScore(prompt_sha: []const u8, niche: []const u8, provider_id: []const u8, d: Decision, score: f64) void {
    const tj = trace.g_traj orelse return;
    tj.node(.{
        .kind = "score",
        .prompt_sha = prompt_sha,
        .score = score,
        .niche = niche,
        .shape = d.shape.label(),
        .role = d.role,
        .tier = tierName(d.tier),
        .model = d.resolved_model,
        .provider = provider_id,
        .t = tj.elapsedMs(),
    });
}

/// One scored variant's policy observation. Role and tier are derived here so
/// the call site (subagent.zig, at the 600-line cap) spends one line on it.
pub fn captureVariant(child: Provider, shape: Shape, title: []const u8, niche: []const u8, genome: []const u8, s01: f64) void {
    captureScore(genome, niche, child.id, .{
        .shape = shape,
        .role = policy.roleOf(title, niche),
        .tier = policy.tierOf(child.id, child.model),
        .resolved_model = child.model,
    }, s01);
}
