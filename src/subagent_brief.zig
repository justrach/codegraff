//! Structured child briefs: optional parent fields render as headed sections
//! around `prompt`, and `runSub` prepends a harness-stated environment
//! header on every path except the judge. Shared engine path — REPL, TUI,
//! and GUI compose the same first user message.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

const json_args = @import("json_args.zig");
const no_local_tools = @import("no_local_tools.zig");

pub const context_header = "## Context";
pub const environment_header = "## Environment";
pub const facts_header = "## Established facts";
pub const scope_header = "## Scope";
pub const deliverable_header = "## Deliverable";

pub const Fields = struct {
    prompt: []const u8,
    context: []const u8 = "",
    established_facts: []const u8 = "",
    scope: []const u8 = "",
    deliverable: []const u8 = "",
};

pub const Env = struct {
    cwd: []const u8 = "",
    instructions: []const u8 = "",
    disabled: []const u8 = "",
    hooks: []const u8 = "",
};

pub const Owned = struct {
    text: []const u8,
    owned: bool = false,
};

pub fn release(gpa: Allocator, o: Owned) void {
    if (o.owned) gpa.free(o.text);
}

fn trimmed(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

pub fn hasExtras(f: Fields) bool {
    return trimmed(f.context).len > 0 or trimmed(f.established_facts).len > 0 or
        trimmed(f.scope).len > 0 or trimmed(f.deliverable).len > 0;
}

/// Headed sections around `prompt`. Empties omitted. A bare prompt is the
/// same bytes — no headings, no trailing newline.
pub fn render(arena: Allocator, f: Fields) ![]const u8 {
    if (trimmed(f.prompt).len == 0 or !hasExtras(f)) return f.prompt;
    var aw: Io.Writer.Allocating = .init(arena);
    errdefer aw.deinit();
    const w = &aw.writer;
    if (trimmed(f.context).len > 0) try w.print("{s}\n{s}\n\n", .{ context_header, trimmed(f.context) });
    try w.writeAll(f.prompt);
    if (trimmed(f.established_facts).len > 0) try w.print("\n\n{s}\n{s}", .{ facts_header, trimmed(f.established_facts) });
    if (trimmed(f.scope).len > 0) try w.print("\n\n{s}\n{s}", .{ scope_header, trimmed(f.scope) });
    if (trimmed(f.deliverable).len > 0) try w.print("\n\n{s}\n{s}", .{ deliverable_header, trimmed(f.deliverable) });
    return aw.toOwnedSlice();
}

pub fn fromInput(gpa: Allocator, obj: ObjectMap) Owned {
    const f = Fields{
        .prompt = json_args.str(obj, "prompt") orelse "",
        .context = json_args.str(obj, "context") orelse "",
        .established_facts = json_args.str(obj, "established_facts") orelse "",
        .scope = json_args.str(obj, "scope") orelse "",
        .deliverable = json_args.str(obj, "deliverable") orelse "",
    };
    if (trimmed(f.prompt).len == 0 or !hasExtras(f)) return .{ .text = f.prompt };
    const text = render(gpa, f) catch return .{ .text = f.prompt };
    return .{ .text = text, .owned = true };
}

fn writeEnvironment(w: *Io.Writer, env: Env) !usize {
    try w.writeAll(environment_header);
    var lines: usize = 0;
    if (trimmed(env.cwd).len > 0) {
        try w.print("\n- working directory: {s}", .{trimmed(env.cwd)});
        lines += 1;
    }
    if (trimmed(env.instructions).len > 0) {
        try w.print("\n- project instructions: {s}", .{trimmed(env.instructions)});
        lines += 1;
    }
    if (trimmed(env.disabled).len > 0) {
        try w.print("\n- disabled tools: {s}", .{trimmed(env.disabled)});
        lines += 1;
    }
    if (trimmed(env.hooks).len > 0) {
        try w.print("\n- pre_tool hooks: {s}", .{trimmed(env.hooks)});
        lines += 1;
    }
    return lines;
}

pub fn environmentHeader(arena: Allocator, env: Env) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    errdefer aw.deinit();
    if (try writeEnvironment(&aw.writer, env) == 0) {
        aw.deinit();
        return "";
    }
    return aw.toOwnedSlice();
}

/// Prepend the environment header unless this is the judge (text-only ranker).
pub fn withEnvironment(arena: Allocator, kind: []const u8, prompt: []const u8, env: Env) ![]const u8 {
    if (std.mem.eql(u8, kind, "judge_task")) return prompt;
    var aw: Io.Writer.Allocating = .init(arena);
    errdefer aw.deinit();
    if (try writeEnvironment(&aw.writer, env) == 0) {
        aw.deinit();
        return prompt;
    }
    try aw.writer.print("\n\n{s}", .{prompt});
    return aw.toOwnedSlice();
}

fn instructionName(io: Io) []const u8 {
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |name| {
        _ = Io.Dir.cwd().statFile(io, name, .{}) catch continue;
        return name;
    }
    return "";
}

fn disabledLine(arena: Allocator) []const u8 {
    const child = "child cannot spawn children; no parent transcript";
    if (no_local_tools.enabled)
        return std.fmt.allocPrint(arena, "{s}; --no-local-tools", .{child}) catch child;
    if (no_local_tools.lean)
        return std.fmt.allocPrint(arena, "{s}; --lean catalog", .{child}) catch child;
    return child;
}

fn hookSummary(arena: Allocator, pre_tool: anytype) []const u8 {
    if (pre_tool.len == 0) return "";
    var aw: Io.Writer.Allocating = .init(arena);
    for (pre_tool, 0..) |h, i| {
        if (i > 0) aw.writer.writeAll("; ") catch return "";
        aw.writer.print("{s} -> {s}", .{ h.match, h.command }) catch return "";
    }
    return aw.toOwnedSlice() catch "";
}

/// `runSub` seam: environment header + parent brief. Judge is identity.
pub fn prepare(arena: Allocator, io: Io, kind: []const u8, prompt: []const u8, agent_cwd: ?[]const u8, pre_tool: anytype) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = agent_cwd orelse blk: {
        const n = Io.Dir.cwd().realPath(io, &buf) catch break :blk "";
        break :blk buf[0..n];
    };
    const env = Env{
        .cwd = cwd,
        .instructions = instructionName(io),
        .disabled = disabledLine(arena),
        .hooks = hookSummary(arena, pre_tool),
    };
    return withEnvironment(arena, kind, prompt, env);
}

test "render: a bare prompt is unchanged; empty extras do not add headings" {
    const gpa = std.testing.allocator;
    const prompt = "1. grep for seat()\n2. report the callers";
    try std.testing.expectEqualStrings(prompt, try render(gpa, .{ .prompt = prompt }));
    try std.testing.expectEqualStrings(prompt, try render(gpa, .{
        .prompt = prompt,
        .context = "  \n",
        .established_facts = "",
        .scope = "   ",
        .deliverable = "",
    }));
}

test "render: optional fields become headed sections in fixed order around prompt" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, .{
        .context = "repo is /workspace; do not invent paths",
        .prompt = "1. open src/subagent.zig",
        .established_facts = "runSub already injects the playbook block",
        .scope = "do not retouch workflow task fields",
        .deliverable = "files changed, verified, skipped, open questions",
    });
    defer gpa.free(out);
    const ctx_at = std.mem.indexOf(u8, out, context_header) orelse return error.TestExpectedEqual;
    const prompt_at = std.mem.indexOf(u8, out, "1. open src/subagent.zig") orelse return error.TestExpectedEqual;
    const facts_at = std.mem.indexOf(u8, out, facts_header) orelse return error.TestExpectedEqual;
    const scope_at = std.mem.indexOf(u8, out, scope_header) orelse return error.TestExpectedEqual;
    const del_at = std.mem.indexOf(u8, out, deliverable_header) orelse return error.TestExpectedEqual;
    try std.testing.expect(ctx_at < prompt_at);
    try std.testing.expect(prompt_at < facts_at);
    try std.testing.expect(facts_at < scope_at);
    try std.testing.expect(scope_at < del_at);
    try std.testing.expect(std.mem.indexOf(u8, out, environment_header) == null);
}

test "fromInput: JSON extras compose; missing prompt stays empty even with context" {
    const gpa = std.testing.allocator;
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":\"do it\",\"context\":\"cwd is /tmp\"}", .{});
        defer parsed.deinit();
        const owned = fromInput(gpa, parsed.value.object);
        defer release(gpa, owned);
        try std.testing.expect(owned.owned);
        try std.testing.expect(std.mem.indexOf(u8, owned.text, context_header) != null);
        try std.testing.expect(std.mem.indexOf(u8, owned.text, "do it") != null);
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"prompt\":\"do it\"}", .{});
        defer parsed.deinit();
        const owned = fromInput(gpa, parsed.value.object);
        defer release(gpa, owned);
        try std.testing.expect(!owned.owned);
        try std.testing.expectEqualStrings("do it", owned.text);
    }
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"context\":\"repo\",\"prompt\":\"\"}", .{});
        defer parsed.deinit();
        const owned = fromInput(gpa, parsed.value.object);
        defer release(gpa, owned);
        try std.testing.expectEqualStrings("", owned.text);
    }
}

test "withEnvironment: workers get the harness header; the judge does not" {
    const gpa = std.testing.allocator;
    const env = Env{
        .cwd = "/tmp/tree",
        .instructions = "AGENTS.md",
        .disabled = "child cannot spawn children; no parent transcript",
        .hooks = "bash -> ./guard.sh",
    };
    const task = "1. list callers of seat()";
    const child = try withEnvironment(gpa, "subagent", task, env);
    defer gpa.free(child);
    try std.testing.expect(std.mem.startsWith(u8, child, environment_header));
    try std.testing.expect(std.mem.indexOf(u8, child, "working directory: /tmp/tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "project instructions: AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "disabled tools:") != null);
    try std.testing.expect(std.mem.indexOf(u8, child, "pre_tool hooks: bash -> ./guard.sh") != null);
    try std.testing.expect(std.mem.endsWith(u8, child, task));

    const wf = try withEnvironment(gpa, "workflow_task", task, env);
    defer gpa.free(wf);
    try std.testing.expect(std.mem.indexOf(u8, wf, environment_header) != null);

    const retry = try withEnvironment(gpa, "workflow_retry", task, env);
    defer gpa.free(retry);
    try std.testing.expect(std.mem.indexOf(u8, retry, environment_header) != null);

    try std.testing.expectEqualStrings(task, try withEnvironment(gpa, "judge_task", task, env));
}

test "subagent schema and description ask for one brief in section order" {
    const spec = @import("schema_agents.zig").subagent_spec;
    for ([_][]const u8{ "\"context\"", "\"established_facts\"", "\"scope\"", "\"deliverable\"" }) |field| {
        try std.testing.expect(std.mem.indexOf(u8, spec.schema, field) != null);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, spec.schema, .{});
    defer parsed.deinit();
    const required = parsed.value.object.get("required").?.array.items;
    for (required) |r| {
        try std.testing.expect(!std.mem.eql(u8, r.string, "context"));
        try std.testing.expect(!std.mem.eql(u8, r.string, "established_facts"));
        try std.testing.expect(!std.mem.eql(u8, r.string, "scope"));
        try std.testing.expect(!std.mem.eql(u8, r.string, "deliverable"));
    }
    try std.testing.expect(std.mem.indexOf(u8, spec.desc, "established_facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec.desc, "Brief once") != null);
}

test "child system prompt asks for a default report shape" {
    const prompt = @import("prompts.zig").sub_system_prompt;
    for ([_][]const u8{ "Files changed", "Verified", "Skipped", "Open questions" }) |h| {
        try std.testing.expect(std.mem.indexOf(u8, prompt, h) != null);
    }
}
