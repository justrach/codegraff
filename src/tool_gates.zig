//! #352: optional built-in tools — catalog entries that exist only when a
//! runtime availability check passes.
//!
//! `no_local_tools.zig` is the SUBTRACTIVE gate (a flag removes tools that
//! would otherwise always be there). This is the ADDITIVE one: a tool whose
//! backing capability lives outside the binary is absent from every catalog
//! until startup proves the capability is installed, so a provider is never
//! told about a tool that cannot possibly succeed on this machine — and the
//! model cannot burn a turn discovering that for itself.
//!
//! Same shape as the subtractive gate, deliberately:
//!   * a name test (`isOptional`) independent of any flag, so the comptime
//!     catalogs and the runtime assembly share one list;
//!   * a process-global boolean per tool, set once at startup and never
//!     flipped mid-session, so subagents/workflow workers/judges inherit it
//!     with no per-agent plumbing to forget.
//!
//! Adding a second optional tool is one row in `gates` plus its ToolSpec in
//! schema.zig's `optional_specs` — no new branching anywhere.

const std = @import("std");
const Allocator = std.mem.Allocator;

const imagegen = @import("imagegen.zig");

/// One optional built-in and the flag that decides whether it is advertised.
pub const Gate = struct {
    name: []const u8,
    /// Read at catalog-assembly time; owned by the tool's own module.
    flag: *const bool,
};

pub const gates = [_]Gate{
    // #352: needs the Codex imagegen skill on disk (its bundled CLI is the
    // only engine that actually renders an image — the hosted `image_gen`
    // tool is server-side and never fires outside the Codex app).
    .{ .name = imagegen.tool_name, .flag = &imagegen.available },
};

/// A name test only, independent of whether the tool is currently available.
pub fn isOptional(name: []const u8) bool {
    for (gates) |gate| {
        if (std.mem.eql(u8, name, gate.name)) return true;
    }
    return false;
}

/// Whether this tool may be advertised right now. Non-optional names are
/// always advertised, so callers can ask about any tool name.
pub fn advertised(name: []const u8) bool {
    for (gates) |gate| {
        if (std.mem.eql(u8, name, gate.name)) return gate.flag.*;
    }
    return true;
}

/// True when at least one optional tool is available — the selector the
/// comptime subagent catalogs switch on.
pub fn anyAvailable() bool {
    for (gates) |gate| {
        if (gate.flag.*) return true;
    }
    return false;
}

/// Layer 2's predicate: a call to an optional tool that is NOT available must
/// be refused before anything runs, even though it was never advertised — a
/// provider can hallucinate a tool name it saw in a previous session or in
/// this document.
pub fn blocks(name: []const u8) bool {
    return isOptional(name) and !advertised(name);
}

/// `base` plus every currently-available optional spec, in `gates` order.
/// Returns `base` untouched when none are available, so the common path
/// allocates nothing (mirrors no_local_tools.filterRootSpecs).
pub fn withAvailable(comptime Spec: type, arena: Allocator, base: []const Spec, optional: []const Spec) ![]const Spec {
    var extra: usize = 0;
    for (optional) |spec| {
        if (advertised(spec.name)) extra += 1;
    }
    if (extra == 0) return base;
    const buf = try arena.alloc(Spec, base.len + extra);
    @memcpy(buf[0..base.len], base);
    var i = base.len;
    for (optional) |spec| {
        if (!advertised(spec.name)) continue;
        buf[i] = spec;
        i += 1;
    }
    return buf[0..i];
}

test { // the served catalogs' wire-compatibility guard (an unreferenced module's tests never run)
    _ = @import("tool_schema_tests.zig");
    _ = @import("spec_catalog_conformance.zig");
    _ = @import("spec_transport_conformance.zig");
    _ = @import("spec_provider_conformance.zig");
    _ = @import("spec_goal_loop_conformance.zig");
    _ = @import("spec_path_confine_conformance.zig");
    _ = @import("spec_shape_conformance.zig");
    _ = @import("spec_score_conformance.zig");
    _ = @import("spec_bash_policy_conformance.zig");
    _ = @import("grok_spec_conformance.zig");
}

test "#352: an optional tool is advertised only while its flag is set; other names are unaffected" {
    const saved = imagegen.available;
    defer imagegen.available = saved;

    try std.testing.expect(isOptional("imagegen"));
    try std.testing.expect(!isOptional("bash"));
    try std.testing.expect(!isOptional("skill"));

    imagegen.available = false;
    try std.testing.expect(!advertised("imagegen"));
    try std.testing.expect(!anyAvailable());
    try std.testing.expect(blocks("imagegen"));
    try std.testing.expect(advertised("bash")); // never optional -> always advertised
    try std.testing.expect(!blocks("bash"));

    imagegen.available = true;
    try std.testing.expect(advertised("imagegen"));
    try std.testing.expect(anyAvailable());
    try std.testing.expect(!blocks("imagegen"));
}

test "#352: withAvailable appends only available optionals, and does not allocate when none are" {
    const Spec = struct { name: []const u8 };
    const base = [_]Spec{ .{ .name = "bash" }, .{ .name = "webfetch" } };
    const optional = [_]Spec{.{ .name = "imagegen" }};

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = imagegen.available;
    defer imagegen.available = saved;

    imagegen.available = false;
    const without = try withAvailable(Spec, arena, &base, &optional);
    try std.testing.expectEqual(base.len, without.len);
    try std.testing.expectEqual(@as(usize, 0), arena_state.queryCapacity());

    imagegen.available = true;
    const with = try withAvailable(Spec, arena, &base, &optional);
    try std.testing.expectEqual(base.len + 1, with.len);
    try std.testing.expectEqualStrings("bash", with[0].name);
    try std.testing.expectEqualStrings("imagegen", with[2].name); // appended last, base order preserved
}

test "#352: neither the root nor the SUBAGENT catalog mentions imagegen until it is available" {
    // Imported inside the test, like no_local_tools does: schema.zig imports
    // this module at the top level, so the pair is a cycle at file scope.
    const schema = @import("schema.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = imagegen.available;
    defer imagegen.available = saved;

    const kinds = [_]@import("provider.zig").Provider.Kind{ .anthropic, .openai, .responses };

    imagegen.available = false;
    const closed = try schema.effectiveRootSpecs(arena);
    for (closed) |spec| try std.testing.expect(!std.mem.eql(u8, spec.name, "imagegen"));
    // The subagent fan-out is the documented way to make several images, so a
    // child must see exactly the same gate the root does — in every wire format.
    for (kinds) |kind| for ([_]bool{ false, true }) |gated| {
        try std.testing.expect(std.mem.indexOf(u8, schema.subToolsJson(kind, gated), "\"imagegen\"") == null);
    };

    imagegen.available = true;
    const open = try schema.effectiveRootSpecs(arena);
    try std.testing.expectEqual(closed.len + 1, open.len);
    var root_has = false;
    for (open) |spec| {
        if (std.mem.eql(u8, spec.name, "imagegen")) root_has = true;
    }
    try std.testing.expect(root_has);
    for (kinds) |kind| for ([_]bool{ false, true }) |gated| {
        const catalog = schema.subToolsJson(kind, gated);
        // #352 + #330: available AND not hard-gated. imagegen spawns a child
        // and writes a file, so --no-local-tools must remove it even when the
        // skill gate says yes — the two gates compose, and the subtractive one
        // always wins.
        try std.testing.expectEqual(!gated, std.mem.indexOf(u8, catalog, "\"imagegen\"") != null);
        try std.testing.expectEqual(!gated, std.mem.indexOf(u8, catalog, "\"name\":\"bash\"") != null);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, catalog, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value.array.items.len > 1);
    };
    // Subagents still cannot spawn subagents, optional tools or not.
    try std.testing.expect(std.mem.indexOf(u8, schema.subToolsJson(.anthropic, false), "\"name\":\"subagent\"") == null);
}

test "#352 + #330: an AVAILABLE imagegen is still removed by --no-local-tools, in every catalog and at dispatch" {
    const schema = @import("schema.zig");
    const exec = @import("exec.zig");
    const tools = @import("tools.zig");
    const no_local_tools = @import("no_local_tools.zig");
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved_gate = no_local_tools.enabled;
    const saved_available = imagegen.available;
    defer {
        no_local_tools.enabled = saved_gate;
        imagegen.available = saved_available;
    }
    imagegen.available = true; // the skill IS installed: only #330 may remove it

    no_local_tools.enabled = true;
    for (try schema.effectiveRootSpecs(arena)) |spec|
        try std.testing.expect(!std.mem.eql(u8, spec.name, "imagegen"));
    for ([_]@import("provider.zig").Provider.Kind{ .anthropic, .openai, .responses }) |kind|
        try std.testing.expect(std.mem.indexOf(u8, schema.subToolsJson(kind, true), "\"imagegen\"") == null);

    // Layer 2: a hallucinated call is refused before anything is spawned.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":\"a red circle\"}", .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    var ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
    for ([_]bool{ false, true }) |from_sub| {
        ctx.from_sub = from_sub;
        const out = exec.execTool(ctx, .{ .id = "c1", .name = "imagegen", .input = parsed.value });
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "--no-local-tools") != null);
    }
}
