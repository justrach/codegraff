//! The environment tool children run in: the `shell` tool's foreground and
//! background jobs, local tools, lifecycle hooks, and the eval-loop command.
//! Built once at startup from graff's own environment (startup.zig, before
//! any subcommand can spawn one) and read-only afterwards.
//!
//! #1267: those children used to inherit everything, provider keys included,
//! so one `env` in a tool call copied OPENAI_API_KEY into the transcript and
//! the traces. The credential variables graff itself reads are removed.
//! GRAFF_TOOL_ENV_PASS (comma-separated names) keeps any of them for the rare
//! command that really needs one.
//!
//! Children graff launches as graff (learning runs) and MCP servers do not
//! come through here: they keep the full environment, because they are the
//! ones that legitimately read those keys. Subagents run in-process.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Map = std.process.Environ.Map;
const provider = @import("provider.zig");

pub const pass_env = "GRAFF_TOOL_ENV_PASS";

/// Secrets graff reads that are not a provider_specs `env_key`.
const extra_secrets = [_][]const u8{
    "CODEGRAFF_API_KEY", // also a provider env_key; listed so it can never drift out
    "GRAFF_TELEMETRY_KEY",
    "GRAFF_MCP_TOKEN",
    "GRAFF_SERVE_TOKEN",
    "HARNESS_SERVE_TOKEN",
};

var g_map: ?Map = null;

/// The map to hand `environ_map` when spawning a tool child. Null before
/// `init` (unit tests, the in-process library) or if building it ran out of
/// memory; the child then inherits graff's environment as it always did.
pub fn get() ?*const Map {
    if (g_map) |*m| return m;
    return null;
}

/// Build the tool environment from graff's own. `arena` must outlive every
/// spawn (the process arena). Called after router_config.load so a project
/// router's key is scrubbed too.
pub fn init(arena: Allocator, parent: *const Map) void {
    g_map = build(arena, parent) catch null;
}

pub fn build(gpa: Allocator, parent: *const Map) Allocator.Error!Map {
    var m = try parent.clone(gpa);
    errdefer m.deinit();
    const pass = parent.get(pass_env) orelse "";
    for (provider.provider_specs) |spec| scrub(&m, spec.env_key, pass);
    if (provider.additional_router) |spec| scrub(&m, spec.env_key, pass);
    for (extra_secrets) |name| scrub(&m, name, pass);
    return m;
}

fn scrub(m: *Map, name: []const u8, pass: []const u8) void {
    if (!passed(pass, name)) _ = m.swapRemove(name);
}

/// Whether `name` is on the comma-separated pass-through list. Windows
/// variable names are case-insensitive, like the Map itself there.
fn passed(pass: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, pass, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        const same = if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(entry, name) else std.mem.eql(u8, entry, name);
        if (same) return true;
    }
    return false;
}

fn fakeParent(gpa: Allocator) !Map {
    var parent = Map.init(gpa);
    errdefer parent.deinit();
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("HOME", "/tmp");
    try parent.put("OPENAI_API_KEY", "sk-fake-openai");
    try parent.put("XAI_API_KEY", "xai-fake");
    try parent.put("CODEGRAFF_API_KEY", "cg_sk_fake");
    try parent.put("GRAFF_TELEMETRY_KEY", "telemetry-fake");
    return parent;
}

test "#1267: tool env drops the provider keys graff reads and keeps the rest" {
    const gpa = std.testing.allocator;
    var parent = try fakeParent(gpa);
    defer parent.deinit();
    try parent.put("MYROUTER_API_KEY", "router-fake");
    const saved_router = provider.additional_router;
    defer provider.additional_router = saved_router;
    provider.additional_router = .{ .id = "myrouter", .display_name = "My Router", .kind = .openai, .auth = .bearer, .url = "http://127.0.0.1:9/v1/chat/completions", .env_key = "MYROUTER_API_KEY", .default_model = "m" };

    var m = try build(gpa, &parent);
    defer m.deinit();
    for ([_][]const u8{ "OPENAI_API_KEY", "XAI_API_KEY", "CODEGRAFF_API_KEY", "GRAFF_TELEMETRY_KEY", "MYROUTER_API_KEY" }) |name|
        try std.testing.expect(m.get(name) == null);
    try std.testing.expectEqualStrings("/usr/bin:/bin", m.get("PATH").?);
    try std.testing.expectEqualStrings("/tmp", m.get("HOME").?);
    try std.testing.expectEqualStrings("sk-fake-openai", parent.get("OPENAI_API_KEY").?); // graff keeps its own
}

test "#1267: GRAFF_TOOL_ENV_PASS keeps the named keys only" {
    const gpa = std.testing.allocator;
    var parent = try fakeParent(gpa);
    defer parent.deinit();
    try parent.put(pass_env, " XAI_API_KEY ,NOT_SET");
    var m = try build(gpa, &parent);
    defer m.deinit();
    try std.testing.expectEqualStrings("xai-fake", m.get("XAI_API_KEY").?);
    try std.testing.expect(m.get("OPENAI_API_KEY") == null);
    try std.testing.expect(m.get("NOT_SET") == null);
}

/// Install `build(fake parent)` as the tool environment for one test and
/// return what it replaced.
fn installFake(gpa: Allocator) !?Map {
    var parent = try fakeParent(gpa);
    defer parent.deinit();
    const saved = g_map;
    g_map = try build(gpa, &parent);
    return saved;
}

test "#1267: a real tool child (both shell paths) cannot see the key" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const jobs = @import("jobs.zig");
    const saved = try installFake(gpa);
    defer {
        g_map.?.deinit();
        g_map = saved;
    }

    // Subagent foreground path: runCapped with the tool run options.
    const sh = jobs.shellArgv("env");
    const run = try jobs.runCappedWithOptions(gpa, io, &sh, 64 * 1024, 4096, 10_000, jobs.toolRunOptions(null));
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "PATH=/usr/bin:/bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "sk-fake-openai") == null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "OPENAI_API_KEY") == null);

    // Root path: a job-registry shell, as `shell` action=run spawns it.
    jobs.g_jobs = .{};
    defer jobs.jobsReap(gpa, io);
    const id = (try jobs.spawnJob(gpa, io, "env")).id;
    const waited = try jobs.waitForeground(gpa, io, id, 10_000);
    defer switch (waited) {
        .running => |r| gpa.free(r.output),
        .done => |d| gpa.free(d.output),
        .cancelled => |c| gpa.free(c.output),
    };
    try std.testing.expect(waited == .done);
    try std.testing.expect(std.mem.indexOf(u8, waited.done.output, "PATH=/usr/bin:/bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, waited.done.output, "xai-fake") == null);
    try std.testing.expect(std.mem.indexOf(u8, waited.done.output, "OPENAI_API_KEY") == null);
}
