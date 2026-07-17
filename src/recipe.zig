//! Versioned run-recipe identity and Pareto comparison primitives. This is the
//! local data-plane foundation for later task-aware model/effort selection;
//! it records observations without changing routing behavior.

const std = @import("std");
const trace = @import("trace.zig");
const util = @import("util.zig");

pub const Snapshot = struct {
    recipe_sha: [16]u8,
    prompt_sha: [16]u8,
    toolset_sha: [16]u8,
};

fn shortHash(text: []const u8) [16]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest[0..8].*, .lower);
}

pub fn toolsetFingerprint(tools: []const u8) [16]u8 {
    return shortHash(tools);
}

/// Coarse, observational task class for per-class recipe comparison. It never
/// changes routing by itself; misclassification can only affect analytics.
pub fn classifyTask(text: []const u8) []const u8 {
    const groups = [_]struct { label: []const u8, needles: []const []const u8 }{
        .{ .label = "debug", .needles = &.{ " debug", "bug", " failing", " failure", "crash", " error" } },
        .{ .label = "review", .needles = &.{ "review", "audit", "security", "defect" } },
        .{ .label = "research", .needles = &.{ "research", "investigate", "compare", "explain", "look up" } },
        .{ .label = "implement", .needles = &.{ "implement", " build", " create", " add", " edit", "refactor", "fix" } },
    };
    for (groups) |group| for (group.needles) |needle|
        if (util.indexOfIgnoreCase(text, needle) != null) return group.label;
    return "general";
}

fn hashField(hasher: *std.crypto.hash.sha2.Sha256, field: []const u8) void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, field.len, .little);
    hasher.update(&len);
    hasher.update(field);
}

pub fn snapshot(
    provider: []const u8,
    model: []const u8,
    effort: []const u8,
    prompt: []const u8,
    tools: []const u8,
    task_class: []const u8,
) Snapshot {
    const prompt_sha = shortHash(prompt);
    return snapshotForPromptHash(provider, model, effort, &prompt_sha, shortHash(tools), task_class);
}

pub fn snapshotForPromptHash(
    provider: []const u8,
    model: []const u8,
    effort: []const u8,
    prompt_sha: []const u8,
    toolset_sha: [16]u8,
    task_class: []const u8,
) Snapshot {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hasher, "recipe-v1");
    hashField(&hasher, @import("build_options").version);
    hashField(&hasher, provider);
    hashField(&hasher, model);
    hashField(&hasher, effort);
    hashField(&hasher, prompt_sha);
    hashField(&hasher, &toolset_sha);
    hashField(&hasher, task_class);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{
        .recipe_sha = std.fmt.bytesToHex(digest[0..8].*, .lower),
        .prompt_sha = if (prompt_sha.len == 16) prompt_sha[0..16].* else shortHash(prompt_sha),
        .toolset_sha = toolset_sha,
    };
}

pub fn record(
    tracer: *trace.Tracer,
    trajectory: ?*trace.Trajectory,
    provider: []const u8,
    model: []const u8,
    effort: []const u8,
    prompt: []const u8,
    tools: []const u8,
    task_class: []const u8,
) Snapshot {
    const value = snapshot(provider, model, effort, prompt, tools, task_class);
    tracer.write(.{
        .t = tracer.elapsedMs(),
        .ev = "recipe",
        .recipe_sha = &value.recipe_sha,
        .provider = provider,
        .model = model,
        .effort = effort,
        .prompt_sha = &value.prompt_sha,
        .toolset_sha = &value.toolset_sha,
        .task_class = task_class,
        .harness_version = @import("build_options").version,
    });
    if (trajectory) |traj| traj.node(.{
        .kind = "recipe",
        .recipe_sha = &value.recipe_sha,
        .provider = provider,
        .model = model,
        .effort = effort,
        .prompt_sha = &value.prompt_sha,
        .toolset_sha = &value.toolset_sha,
        .task_class = task_class,
        .harness_version = @import("build_options").version,
        .t = traj.elapsedMs(),
    });
    return value;
}

/// Metrics stay objective and separately inspectable. Selection can keep a
/// Pareto frontier instead of hiding quality/latency/cost tradeoffs inside one
/// scalar that a recipe might game.
pub const Outcome = struct {
    success: bool,
    latency_ms: u64,
    model_calls: u64,
    tool_errors: u64,
    uncached_tokens: u64,
    cache_read_tokens: u64,
    cost_microusd: u64,

    pub fn cachePermille(self: Outcome) u16 {
        const total = self.uncached_tokens +| self.cache_read_tokens;
        if (total == 0) return 0;
        return @intCast(@min(@as(u64, 1000), self.cache_read_tokens *| 1000 / total));
    }
};

/// True only when `candidate` is no worse on every objective and strictly
/// better on at least one. Success is mandatory against a successful baseline.
pub fn dominates(candidate: Outcome, baseline: Outcome) bool {
    if (!candidate.success and baseline.success) return false;
    const no_worse = @intFromBool(candidate.success) >= @intFromBool(baseline.success) and
        candidate.latency_ms <= baseline.latency_ms and
        candidate.model_calls <= baseline.model_calls and
        candidate.tool_errors <= baseline.tool_errors and
        candidate.uncached_tokens <= baseline.uncached_tokens and
        candidate.cost_microusd <= baseline.cost_microusd and
        candidate.cachePermille() >= baseline.cachePermille();
    if (!no_worse) return false;
    return candidate.success != baseline.success or
        candidate.latency_ms < baseline.latency_ms or
        candidate.model_calls < baseline.model_calls or
        candidate.tool_errors < baseline.tool_errors or
        candidate.uncached_tokens < baseline.uncached_tokens or
        candidate.cost_microusd < baseline.cost_microusd or
        candidate.cachePermille() > baseline.cachePermille();
}

test "recipe identity changes with model effort tools and task class" {
    const base = snapshot("codegraff", "deepseek-v4-pro", "medium", "prompt", "tools-a", "implementer");
    try std.testing.expectEqual(base.recipe_sha, snapshot("codegraff", "deepseek-v4-pro", "medium", "prompt", "tools-a", "implementer").recipe_sha);
    try std.testing.expect(!std.mem.eql(u8, &base.recipe_sha, &snapshot("codegraff", "deepseek-v4-pro", "high", "prompt", "tools-a", "implementer").recipe_sha));
    try std.testing.expect(!std.mem.eql(u8, &base.recipe_sha, &snapshot("codegraff", "deepseek-v4-pro", "medium", "prompt", "tools-b", "implementer").recipe_sha));
    try std.testing.expect(!std.mem.eql(u8, &base.recipe_sha, &snapshot("codegraff", "deepseek-v4-pro", "medium", "prompt", "tools-a", "reviewer").recipe_sha));
}

test "Pareto dominance never trades success for speed" {
    const base: Outcome = .{ .success = true, .latency_ms = 1000, .model_calls = 2, .tool_errors = 0, .uncached_tokens = 1000, .cache_read_tokens = 500, .cost_microusd = 2000 };
    var faster = base;
    faster.latency_ms = 800;
    try std.testing.expect(dominates(faster, base));
    var failed = faster;
    failed.success = false;
    try std.testing.expect(!dominates(failed, base));
    var tradeoff = faster;
    tradeoff.cost_microusd = 3000;
    try std.testing.expect(!dominates(tradeoff, base));
}

test "task classification is observational and coarse" {
    try std.testing.expectEqualStrings("debug", classifyTask("please debug the failing request"));
    try std.testing.expectEqualStrings("review", classifyTask("security review this diff"));
    try std.testing.expectEqualStrings("implement", classifyTask("can we implement the patch"));
    try std.testing.expectEqualStrings("general", classifyTask("hello there"));
}
