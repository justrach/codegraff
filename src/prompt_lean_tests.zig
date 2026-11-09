//! Lean / unattended prompt composition tests, split out of
//! prompt_snapshot_tests.zig for the 600-line ceiling (ADR 0061 grew the
//! golden). Reached from prompts.zig's `test {}` block like the snapshots.

const std = @import("std");
const prompts = @import("prompts.zig");
const imagegen = @import("imagegen.zig");
const no_local_tools = @import("no_local_tools.zig");

test "lean drops the todo/constraint capabilities from the prompt, never the local tools" {
    const saved = no_local_tools.lean;
    defer no_local_tools.lean = saved;
    no_local_tools.lean = false;
    const full = prompts.detectCaps();
    try std.testing.expect(full.todos and full.constraints and full.local_tools);
    no_local_tools.lean = true;
    const lean = prompts.detectCaps();
    try std.testing.expect(!lean.todos and !lean.constraints);
    try std.testing.expect(lean.local_tools and !lean.subagents); // one-shot: no fan-out essay
    // …and the composition carries it: the dropped segments' bytes are gone.
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const lean_prompt = try prompts.composeBase(a, lean);
    try std.testing.expect(lean_prompt.len < prompts.main_system_prompt.len);
    try std.testing.expect(std.mem.indexOf(u8, lean_prompt, "described in prose is not done") != null);
}

test "unattended one-shots are told the REAL approval map up front; attended sessions hear nothing" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const startup = @import("startup.zig");
    const saved_img = imagegen.available;
    defer imagegen.available = saved_img;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const Io = std.Io;
    var aw: Io.Writer.Allocating = .init(a);
    const attended = try startup.buildSystemPrompt(std.testing.io, a, &aw.writer, null, null, true, false, &.{}, false, null, env);
    try std.testing.expect(std.mem.indexOf(u8, attended, "AUTO-DENIED") == null);
    var aw2: Io.Writer.Allocating = .init(a);
    const unattended = try startup.buildSystemPrompt(std.testing.io, a, &aw2.writer, null, null, true, true, &.{}, false, null, env);
    try std.testing.expect(std.mem.indexOf(u8, unattended, "AUTO-DENIED") != null);
    // The map the denial text alone could not teach: the root is gated,
    // subagents are the ungated path, and --yolo/settings are the user's.
    try std.testing.expect(std.mem.indexOf(u8, unattended, "Subagents are NOT approval-gated") != null);
    try std.testing.expect(std.mem.indexOf(u8, unattended, "--yolo") != null);
    try std.testing.expect(std.mem.indexOf(u8, unattended, ".harness/settings.json") != null);
}

test "lean prefix hash is stable and does not name a sandbox path" {
    // Second bust vector: even with a shared cache key, a prefix that
    // interpolates the cwd is a miss on every eval sandbox. Offline.
    const saved = no_local_tools.lean;
    defer no_local_tools.lean = saved;
    no_local_tools.lean = true;
    const hud = @import("prompt_cache_hud.zig");
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const lean = prompts.detectCaps();
    const first = try prompts.composeBase(a, lean);
    const second = try prompts.composeBase(a, lean);
    try std.testing.expectEqual(hud.prefixHash(first, ""), hud.prefixHash(second, ""));
    try std.testing.expect(std.mem.indexOf(u8, first, ".sandboxes") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "/tmp/") == null);
}

test "buildSystemPrompt places static skill catalog ahead of workspace instructions and repo_map" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const startup = @import("startup.zig");
    const skill_docs = @import("skill_docs.zig");
    const saved_img = imagegen.available;
    defer imagegen.available = saved_img;
    const saved_lean = no_local_tools.lean;
    defer no_local_tools.lean = saved_lean;
    no_local_tools.lean = false;

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var aw: std.Io.Writer.Allocating = .init(a);
    const sys = try startup.buildSystemPrompt(std.testing.io, a, &aw.writer, null, "APPEND-MARKER", true, true, &.{}, false, null, env);
    const skills_at = std.mem.indexOf(u8, sys, "# Skills\n") orelse return error.TestUnexpectedResult;
    const unattended_at = std.mem.indexOf(u8, sys, "AUTO-DENIED") orelse return error.TestUnexpectedResult;
    const append_at = std.mem.indexOf(u8, sys, "APPEND-MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(unattended_at < skills_at);
    try std.testing.expect(skills_at < append_at);
    if (std.mem.indexOf(u8, sys, "# Project instructions")) |agents_at| try std.testing.expect(skills_at < agents_at);
    if (std.mem.indexOf(u8, sys, "# Project layout")) |map_at| try std.testing.expect(skills_at < map_at);

    // Non-project skills sort ahead of project skills so a workspace skill
    // only touches the tail of # Skills.
    const mixed = [_]skill_docs.Skill{
        .{ .name = "aaa-local", .desc = "project skill", .body = "", .source = .project },
        .{ .name = "zzz-global", .desc = "personal skill", .body = "", .source = .personal },
    };
    const cat = skill_docs.promptCatalog(a, &mixed);
    const global_at = std.mem.indexOf(u8, cat, "zzz-global (personal)") orelse return error.TestUnexpectedResult;
    const local_at = std.mem.indexOf(u8, cat, "aaa-local (project)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(global_at < local_at);
}
