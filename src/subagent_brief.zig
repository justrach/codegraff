//! The delegation brief a child receives. Two halves, one fixed order:
//!
//!   1. The ENVIRONMENT header the harness already knows and no parent should
//!      have to type: working directory, the project-instructions file to read
//!      first, tools this session disabled, pre-tool hooks that may refuse a
//!      call. `withEnvironment` prepends it on every spawn path that runs
//!      through subagent_run.runSub (subagent, workflow task, workflow retry) —
//!      the judge ranks handed excerpts and is left alone.
//!   2. The PARENT's structured sections from the `subagent` tool call —
//!      context, task, established facts, scope, deliverable — rendered by
//!      `render` with one heading each, empty ones omitted. A call that passes
//!      only `prompt` renders byte-identically to that prompt, so the plain
//!      string path is unchanged.
//!
//! Composed in the child's first USER message, not its system prompt: the
//! sections vary per spawn, and the system prompt stays a stable cache prefix.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const json_args = @import("json_args.zig");
const no_local_tools = @import("no_local_tools.zig");
const hooks_mod = @import("hooks.zig");

/// The structured fields of one `subagent` call, in render order. `task` is
/// the required `prompt`; the rest are optional and trimmed before use.
pub const Sections = struct {
    context: ?[]const u8 = null,
    task: []const u8,
    established_facts: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    deliverable: ?[]const u8 = null,

    /// Read the optional sections off the tool-call object; `task` is the
    /// already-validated prompt the caller extracted.
    pub fn fromArgs(obj: std.json.ObjectMap, task: []const u8) Sections {
        return .{
            .context = json_args.str(obj, "context"),
            .task = task,
            .established_facts = json_args.str(obj, "established_facts"),
            .scope = json_args.str(obj, "scope"),
            .deliverable = json_args.str(obj, "deliverable"),
        };
    }

    /// Did the parent fill any section beyond the task itself?
    pub fn structured(self: Sections) bool {
        return present(self.context) or present(self.established_facts) or present(self.scope) or present(self.deliverable);
    }
};

fn present(s: ?[]const u8) bool {
    const v = s orelse return false;
    return std.mem.trim(u8, v, &std.ascii.whitespace).len > 0;
}

pub const heading_context = "## Context";
pub const heading_task = "## Task";
pub const heading_established = "## Established (do not re-derive)";
pub const heading_scope = "## Scope";
pub const heading_deliverable = "## Deliverable";

fn section(w: *Io.Writer, heading: []const u8, body: ?[]const u8, first: *bool) !void {
    const v = body orelse return;
    const t = std.mem.trim(u8, v, &std.ascii.whitespace);
    if (t.len == 0) return;
    if (!first.*) try w.writeAll("\n\n");
    first.* = false;
    try w.print("{s}\n{s}", .{ heading, t });
}

/// The parent's brief as one string. Always an owned copy (the caller frees):
/// a plain task comes back byte-identical, a structured one as headed
/// sections in the fixed order, empties skipped.
pub fn render(alloc: Allocator, s: Sections) ![]u8 {
    if (!s.structured()) return alloc.dupe(u8, s.task);
    var aw: Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    var first = true;
    try section(&aw.writer, heading_context, s.context, &first);
    try section(&aw.writer, heading_task, s.task, &first);
    try section(&aw.writer, heading_established, s.established_facts, &first);
    try section(&aw.writer, heading_scope, s.scope, &first);
    try section(&aw.writer, heading_deliverable, s.deliverable, &first);
    return aw.toOwnedSlice();
}

/// execSubagent's one call: the structured fields of `obj` around `task`.
pub fn compose(alloc: Allocator, obj: std.json.ObjectMap, task: []const u8) ![]u8 {
    return render(alloc, Sections.fromArgs(obj, task));
}

/// Appended to the child's system prompt: the report shape a parent gets when
/// its brief named no deliverable, so every child answers in the same frame.
pub const report_shape_note =
    \\ When the brief names no deliverable, report in this order: files changed
    \\(one line each, with why), verified (what you ran and saw), skipped (and
    \\why), open questions. State what the brief asked for and nothing else.
;

/// One pre-tool hook the child's calls will pass through.
pub const Guard = struct {
    match: []const u8,
    suggest: []const u8 = "",
};

/// What the harness knows about the child's environment. Every field empty
/// renders to "" — a bare session adds nothing to the brief.
pub const Env = struct {
    cwd: []const u8 = "",
    instructions_file: ?[]const u8 = null,
    disabled_tools: []const []const u8 = &.{},
    pre_tool_hooks: []const Guard = &.{},

    pub fn empty(self: Env) bool {
        return self.cwd.len == 0 and self.instructions_file == null and self.disabled_tools.len == 0 and self.pre_tool_hooks.len == 0;
    }
};

pub const env_heading = "[environment — stated by the harness, not the parent]";

/// The environment header, or "" when there is nothing to say.
pub fn renderEnv(alloc: Allocator, env: Env) ![]u8 {
    if (env.empty()) return alloc.dupe(u8, "");
    var aw: Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(env_heading);
    if (env.cwd.len > 0) try w.print("\nworking directory: {s}", .{env.cwd});
    if (env.instructions_file) |f| try w.print("\nproject instructions: {s} in the working directory — read it first; its rules bind you too", .{f});
    if (env.disabled_tools.len > 0) {
        try w.writeAll("\ndisabled tools this session (do not call them): ");
        for (env.disabled_tools, 0..) |name, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(name);
        }
    }
    for (env.pre_tool_hooks) |g| {
        if (std.mem.eql(u8, g.match, "*"))
            try w.writeAll("\npre-tool hook: every tool call may be refused; a refusal returns the hook's message — follow it")
        else
            try w.print("\npre-tool hook may refuse: {s}", .{g.match});
        if (g.suggest.len > 0) try w.print(" (use instead: {s})", .{g.suggest});
    }
    return aw.toOwnedSlice();
}

/// The instructions file the ROOT loaded at startup, if any — same list and
/// order as startup.buildSystemPrompt. `dir` null means the process cwd.
pub fn instructionsFile(io: Io, dir: ?[]const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |fname| {
        const path = if (dir) |d| (std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, fname }) catch continue) else fname;
        if (Io.Dir.cwd().access(io, path, .{})) |_| return fname else |_| {}
    }
    return null;
}

/// Gather the header's facts from the live gates. `cwd_override` is the
/// child's isolated worktree when it has one (Agent.agent_cwd).
pub fn detectEnv(io: Io, arena: Allocator, cwd_override: ?[]const u8) Env {
    var env: Env = .{};
    if (cwd_override) |c| {
        env.cwd = c;
    } else {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.currentPath(io, &buf)) |n| {
            env.cwd = arena.dupe(u8, buf[0..n]) catch "";
        } else |_| {}
    }
    env.instructions_file = instructionsFile(io, cwd_override);
    if (no_local_tools.enabled) {
        var list: std.ArrayList([]const u8) = .empty;
        for (no_local_tools.gated_tools ++ no_local_tools.gated_aliases) |name| {
            if (no_local_tools.blocks(name)) list.append(arena, name) catch break;
        }
        env.disabled_tools = list.items;
    }
    env.pre_tool_hooks = guardsFrom(arena, @import("main.zig").g_hooks.pre_tool);
    return env;
}

pub fn guardsFrom(arena: Allocator, pre_tool: []const hooks_mod.Hook) []const Guard {
    if (pre_tool.len == 0) return &.{};
    const out = arena.alloc(Guard, pre_tool.len) catch return &.{};
    for (pre_tool, out) |h, *g| g.* = .{ .match = h.match, .suggest = h.suggest };
    return out;
}

/// Prepend the environment header to a child's brief. The judge is text-only
/// and ranks handed excerpts, so it gets the prompt untouched; so does any
/// child when the header has nothing to say.
pub fn withEnvironment(io: Io, arena: Allocator, kind: []const u8, cwd_override: ?[]const u8, prompt: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "judge_task")) return prompt;
    const header = renderEnv(arena, detectEnv(io, arena, cwd_override)) catch return prompt;
    if (header.len == 0) return prompt;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ header, prompt }) catch prompt;
}

// ── tests ──────────────────────────────────────────────────────────────────

fn parseArgs(arena: Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return v.object;
}

test "render: a plain prompt passes through byte-identically" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const obj = try parseArgs(arena_state.allocator(), "{\"description\":\"scan\",\"prompt\":\"find the caller of foo\"}");
    const out = try compose(gpa, obj, "find the caller of foo");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("find the caller of foo", out);
    // Whitespace-only optional fields count as absent, not as structure.
    const blank = try parseArgs(arena_state.allocator(), "{\"prompt\":\"x\",\"scope\":\"  \",\"deliverable\":\"\"}");
    const out2 = try compose(gpa, blank, "x");
    defer gpa.free(out2);
    try std.testing.expectEqualStrings("x", out2);
}

test "render: sections come out in the fixed order, each under its heading" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, .{
        .deliverable = "files changed; verified; skipped",
        .scope = "do not touch unrelated work",
        .established_facts = "runSub composes the prompt at one call site",
        .task = "1. read it\n2. change it",
        .context = "Zig harness; read AGENTS.md; 600 LOC ceiling",
    });
    defer gpa.free(out);
    const expected =
        "## Context\nZig harness; read AGENTS.md; 600 LOC ceiling\n\n" ++
        "## Task\n1. read it\n2. change it\n\n" ++
        "## Established (do not re-derive)\nrunSub composes the prompt at one call site\n\n" ++
        "## Scope\ndo not touch unrelated work\n\n" ++
        "## Deliverable\nfiles changed; verified; skipped";
    try std.testing.expectEqualStrings(expected, out);
}

test "render: empty sections are omitted and values are trimmed" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const obj = try parseArgs(arena_state.allocator(), "{\"prompt\":\"  do X  \",\"established_facts\":\"\\n  A is at line 12\\n\",\"context\":\"\"}");
    const out = try compose(gpa, obj, "  do X  ");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("## Task\ndo X\n\n## Established (do not re-derive)\nA is at line 12", out);
    try std.testing.expect(std.mem.indexOf(u8, out, heading_context) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, heading_scope) == null);
    try std.testing.expect(std.mem.indexOf(u8, out, heading_deliverable) == null);
}

test "renderEnv: an empty environment adds nothing" {
    const gpa = std.testing.allocator;
    const out = try renderEnv(gpa, .{});
    defer gpa.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "renderEnv: cwd, instructions file, disabled tools and hooks, in that order" {
    const gpa = std.testing.allocator;
    const out = try renderEnv(gpa, .{
        .cwd = "/work/repo",
        .instructions_file = "AGENTS.md",
        .disabled_tools = &.{ "shell", "edit_file" },
        .pre_tool_hooks = &.{ .{ .match = "bash|read_file", .suggest = "zigrep" }, .{ .match = "*" } },
    });
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, env_heading));
    const cwd = std.mem.indexOf(u8, out, "working directory: /work/repo").?;
    const instr = std.mem.indexOf(u8, out, "project instructions: AGENTS.md").?;
    const disabled = std.mem.indexOf(u8, out, "disabled tools this session (do not call them): shell, edit_file").?;
    const hook = std.mem.indexOf(u8, out, "pre-tool hook may refuse: bash|read_file (use instead: zigrep)").?;
    const star = std.mem.indexOf(u8, out, "every tool call may be refused").?;
    try std.testing.expect(cwd < instr and instr < disabled and disabled < hook and hook < star);
}

test "withEnvironment: header precedes the brief for workers, never for the judge" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    // The judge ranks handed excerpts: no header, the prompt untouched.
    try std.testing.expectEqualStrings("score this", withEnvironment(io, arena, "judge_task", null, "score this"));
    // A worker with an explicit cwd gets the header first, then a blank line, then its brief.
    const out = withEnvironment(io, arena, "subagent", "/tmp", "## Task\ndo X");
    try std.testing.expect(std.mem.startsWith(u8, out, env_heading));
    try std.testing.expect(std.mem.indexOf(u8, out, "working directory: /tmp") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\n\n## Task\ndo X"));
}

test "guardsFrom mirrors the loaded pre-tool hooks; report_shape_note names the four report parts" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const hooks = [_]hooks_mod.Hook{.{ .match = "bash", .command = "./guard.sh", .timeout_ms = 1, .suggest = "shell" }};
    const guards = guardsFrom(arena_state.allocator(), &hooks);
    try std.testing.expectEqual(@as(usize, 1), guards.len);
    try std.testing.expectEqualStrings("bash", guards[0].match);
    try std.testing.expectEqualStrings("shell", guards[0].suggest);
    try std.testing.expectEqual(@as(usize, 0), guardsFrom(arena_state.allocator(), &.{}).len);
    for ([_][]const u8{ "files changed", "verified", "skipped", "open questions" }) |part|
        try std.testing.expect(std.mem.indexOf(u8, report_shape_note, part) != null);
}
