//! Provider/model selection and credential plumbing for zero-configuration
//! learning.
//!
//! Learning adapters run with a scrubbed environment and a scratch HOME, so a
//! `graff login` credential on disk is invisible to them: only the names a
//! configuration explicitly declares in `pass_env` cross that boundary, and
//! only if the parent process has them. Requiring every user to re-export a
//! secret before the loop can run is exactly the friction that kept it from
//! running at all, so `learn run` resolves the declared names from the same
//! local key store the session itself uses and hands them to the pinned
//! adapters. Nothing else is added, and an undeclared name is never resolved.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const oauth = @import("oauth.zig");
const pricing = @import("pricing.zig");
const schema = @import("schema.zig");
const serde = @import("serde.zig");
const store_mod = @import("learn_store.zig");

pub const Target = struct {
    provider: []const u8,
    model: []const u8,
};

/// Free tier first: a workspace with no configured key still gets a working
/// loop after `graff login`.
const fallback_provider = "codegraff";

/// Pick the provider/model the learning adapters should drive. The session's
/// own saved model wins, then any provider with a usable credential, then the
/// hosted default.
pub fn resolveTarget(io: Io, arena: Allocator, environ: *const std.process.Environ.Map) Target {
    const home = keys_cli.homeEnv(environ) orelse "";
    if (serde.loadModel(io, arena, home)) |saved| {
        if (provider_mod.specFor(saved.pid)) |spec| {
            if (saved.model.len > 0) return .{ .provider = spec.id, .model = saved.model };
        }
    }
    for (provider_mod.provider_specs) |spec| {
        if (!hasCredential(io, arena, environ, home, spec)) continue;
        return .{ .provider = spec.id, .model = pricing.providerDefaultModel(spec.id, spec.default_model) };
    }
    const spec = provider_mod.specFor(fallback_provider).?;
    return .{ .provider = spec.id, .model = pricing.providerDefaultModel(spec.id, spec.default_model) };
}

fn hasCredential(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, home: []const u8, spec: provider_mod.ProviderSpec) bool {
    if (std.mem.eql(u8, spec.id, "codex")) return codexHome(io, arena, environ, home) != null;
    if (environ.get(spec.env_key) != null) return true;
    if (home.len == 0) return false;
    if (std.mem.eql(u8, spec.id, "codegraff")) {
        if (oauth.loadCodegraffKey(io, arena, home)) |_| return true;
    }
    return keys_cli.loadStoredKey(io, arena, home, spec.id) != null;
}

/// Whether this provider/model honors a reasoning-effort pin. The learning
/// adapters verify a pin they send, so a configuration must only declare one
/// the provider can actually apply.
pub fn pinsEffort(provider_id: []const u8, model: []const u8) bool {
    const spec = provider_mod.specFor(provider_id) orelse return false;
    return schema.providerTakesEffort(spec.kind, spec.id, model);
}

/// The model an explicitly named provider learns with when none is given.
pub fn defaultModelFor(provider_id: []const u8) []const u8 {
    const spec = provider_mod.specFor(provider_id) orelse return provider_id;
    return pricing.providerDefaultModel(spec.id, spec.default_model);
}

/// The environment names a configuration must declare for this provider. Codex
/// authenticates from a directory rather than a key variable.
pub fn passEnvFor(arena: Allocator, provider_id: []const u8) ![]const []const u8 {
    if (std.mem.eql(u8, provider_id, "codex")) return arena.dupe([]const u8, &.{"CODEX_HOME"});
    const spec = provider_mod.specFor(provider_id) orelse return arena.dupe([]const u8, &.{});
    return arena.dupe([]const u8, &.{spec.env_key});
}

fn codexHome(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, home: []const u8) ?[]const u8 {
    if (environ.get("CODEX_HOME")) |v| oauth.initCodexHome(arena, v, home);
    const path = oauth.codexHomeDir(arena, home) orelse return null;
    _ = oauth.loadCodexAuthFrom(io, arena, path) orelse return null;
    return path;
}

/// Resolve one declared `pass_env` name from local credentials. Returns null
/// when the name is not a known provider credential or nothing is stored.
fn resolveName(io: Io, arena: Allocator, environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const home = keys_cli.homeEnv(environ) orelse "";
    if (std.mem.eql(u8, name, "CODEX_HOME")) return codexHome(io, arena, environ, home);
    if (home.len == 0) return null;
    for (provider_mod.provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.env_key, name)) continue;
        if (std.mem.eql(u8, spec.id, "codegraff")) {
            if (oauth.loadCodegraffKey(io, arena, home)) |key| return key;
        }
        return keys_cli.loadStoredKey(io, arena, home, spec.id);
    }
    return null;
}

fn declares(config: store_mod.Config, name: []const u8) bool {
    for (config.mutator.pass_env) |declared| if (std.mem.eql(u8, declared, name)) return true;
    for (config.evaluator.pass_env) |declared| if (std.mem.eql(u8, declared, name)) return true;
    return false;
}

/// A copy of the parent environment plus any credential the configuration
/// declares and the parent lacks. The caller owns the returned map.
pub fn withResolvedCredentials(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    parent: *const std.process.Environ.Map,
    config: store_mod.Config,
) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    for (parent.keys(), parent.values()) |key, value| try env.put(key, value);
    for ([_][]const []const u8{ config.mutator.pass_env, config.evaluator.pass_env }) |declared| {
        for (declared) |name| {
            if (env.get(name) != null) continue;
            if (resolveName(io, arena, parent, name)) |value| try env.put(name, value);
        }
    }
    return env;
}

test "pass_env names follow the provider's credential shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const codex = try passEnvFor(arena, "codex");
    try std.testing.expectEqual(@as(usize, 1), codex.len);
    try std.testing.expectEqualStrings("CODEX_HOME", codex[0]);
    const codegraff = try passEnvFor(arena, "codegraff");
    try std.testing.expectEqualStrings("CODEGRAFF_API_KEY", codegraff[0]);
    const unknown = try passEnvFor(arena, "not-a-provider");
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}

test "only configuration-declared names are eligible for credential resolution" {
    // Written out rather than repeated with `**`: the CI compiler rejects that
    // operator's spacing here, and a pinned digest is a literal anyway.
    const a_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const b_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const c_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "graff-root",
        .mutation_instruction = "improve",
        .mutator = .{ .program = "/x", .sha256 = a_id, .pass_env = &.{"CODEGRAFF_API_KEY"} },
        .evaluator = .{ .program = "/y", .sha256 = b_id, .pass_env = &.{"CODEX_HOME"} },
        .evaluation_suite = .{ .path = "/z", .sha256 = c_id },
        .cohort = .{ .provider = "codegraff", .model = "m", .task_family = "f", .adapter_version = "v", .verifier_version = "v" },
    };
    try std.testing.expect(declares(config, "CODEGRAFF_API_KEY"));
    try std.testing.expect(declares(config, "CODEX_HOME"));
    try std.testing.expect(!declares(config, "ANTHROPIC_API_KEY"));
    try std.testing.expect(!declares(config, "PATH"));
}
