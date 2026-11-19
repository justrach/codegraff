//! Opt-in single-tool Python REPL mode (`--unharnessed`, `GRAFF_UNHARNESSED`,
//! `.harness/settings.json` `"unharnessed"`, `/unharnessed`, ACP config).
//! Exposes ONLY the persistent stateful `python` tool alongside a compact
//! single-tool system prompt while reusing graff's provider transports, auth,
//! approvals, hard policies, and trace/session machinery.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const python_repl = @import("python_repl.zig");

pub const settings_path = ".harness/settings.json";
pub const settings_field = "unharnessed";

pub var g_enabled: bool = false;
pub var cli_set: bool = false;
pub var env_set: bool = false;
pub var g_saved_normal_base: []const u8 = "";
pub var g_saved_system_flag: ?[]const u8 = null;
pub var g_saved_append_flag: ?[]const u8 = null;
pub var test_settings_dir: ?Io.Dir = null;

pub const specs = [_]schema.ToolSpec{
    .{
        .name = python_repl.unharnessed_tool_name,
        .desc = "Execute Python 3 code in a persistent stateful REPL rooted at the workspace directory. All globals, imports, helper functions, classes, in-memory data structures, and working-directory changes persist across calls for the entire session. stdout/stderr are returned, and if the final statement is an expression, its repr() is returned and bound to `_`.",
        .schema = python_repl.input_schema,
    },
};

pub const system_prompt =
    \\You are an autonomous problem-solving agent operating in a single-tool Python environment.
    \\Your ONLY tool is `python`, a persistent stateful Python 3 REPL running directly in the workspace root.
    \\
    \\Key properties of your persistent Python REPL:
    \\- Variables, imports, functions, classes, parsed datasets/ASTs, and `os.chdir` persist across every `python` call in this session.
    \\- If the last statement in a call is an expression, its `repr()` is displayed automatically and bound to `_`.
    \\- Use standard Python (`pathlib`, `json`, `csv`, `sqlite3`, `ast`, `re`, `numpy`, `scipy`, `pandas`, `subprocess`, etc.) directly to inspect files, search, edit or generate files, run computations, and execute tests or build tools (`subprocess.run(..., capture_output=True, text=True)`).
    \\- Inspect slices, schemas, summaries, and targeted sections rather than printing entire huge files or arrays to stdout; keep full objects in Python variables across turns.
    \\- When solving coding tasks, do not edit existing locked test files unless explicitly asked.
    \\- Always verify your changes and generated outputs before finishing, then respond directly in plain text with no tool calls summarizing what you verified.
;

pub fn enabled() bool {
    return g_enabled and !no_local_tools.enabled;
}

pub fn label() []const u8 {
    return if (enabled()) "on" else "off";
}

pub fn parse(raw: []const u8) ?bool {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(s, "on") or std.mem.eql(u8, s, "1") or
        std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "off") or std.mem.eql(u8, s, "0") or
        std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no")) return false;
    return null;
}

pub fn setFromCli(on: bool) void {
    g_enabled = on;
    cli_set = true;
}

pub fn applyEnv(raw: ?[]const u8) void {
    if (cli_set) return;
    const v = raw orelse return;
    if (parse(v)) |on| {
        g_enabled = on;
        env_set = true;
    }
}

pub fn loadSettings(io: Io, arena: Allocator) void {
    loadSettingsFrom(io, test_settings_dir orelse Io.Dir.cwd(), arena);
}

pub fn loadSettingsFrom(io: Io, dir: Io.Dir, arena: Allocator) void {
    if (cli_set or env_set) return;
    const text = dir.readFileAlloc(io, settings_path, arena, .limited(1024 * 1024)) catch return;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return;
    if (v != .object) return;
    const raw = v.object.get(settings_field) orelse return;
    switch (raw) {
        .bool => |b| g_enabled = b,
        .string => |s| if (parse(s)) |b| {
            g_enabled = b;
        },
        else => {},
    }
}

pub fn saveSettings(io: Io, arena: Allocator, on: bool) !void {
    try saveSettingsAt(io, test_settings_dir orelse Io.Dir.cwd(), arena, on);
}

pub fn saveSettingsAt(io: Io, dir: Io.Dir, arena: Allocator, on: bool) !void {
    const existing = dir.readFileAlloc(io, settings_path, arena, .limited(1024 * 1024)) catch "{}";
    var obj: std.json.ObjectMap = .empty;
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{})) |v| {
        if (v == .object) obj = v.object;
    } else |_| {}
    try obj.put(arena, settings_field, .{ .bool = on });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(std.json.Value{ .object = obj });
    aw.writer.writeByte('\n') catch {};
    if (std.fs.path.dirname(settings_path)) |sub| dir.createDirPath(io, sub) catch {};
    try @import("credential_store.zig").replaceFile(io, dir, settings_path, aw.writer.buffered(), .default_file);
    g_enabled = on;
}

pub fn buildPrompt(io: Io, arena: Allocator, system_prompt_flag: ?[]const u8, append_flag: ?[]const u8) ![]const u8 {
    var out_prompt: []const u8 = system_prompt_flag orelse system_prompt;
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |fname| {
        const body = Io.Dir.cwd().readFileAlloc(io, fname, arena, .limited(64 * 1024)) catch continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) continue;
        const capped = @import("context_limits.zig").applyFileAlloc(arena, fname, trimmed, @import("context_limits.zig").agents_md_bytes);
        out_prompt = try std.fmt.allocPrint(arena, "{s}\n\n# Project instructions (from {s})\n{s}", .{ out_prompt, fname, capped });
        @import("hot_context.zig").noteBaked(fname, capped);
        break;
    }
    if (append_flag) |extra| {
        if (extra.len > 0) out_prompt = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ out_prompt, extra });
    }
    return out_prompt;
}

pub fn applyStartupPrompt(io: Io, arena: Allocator, normal_prompt: []const u8, system_prompt_flag: ?[]const u8, append_flag: ?[]const u8) ![]const u8 {
    g_saved_normal_base = normal_prompt;
    g_saved_system_flag = system_prompt_flag;
    g_saved_append_flag = append_flag;
    if (!enabled()) return normal_prompt;
    return buildPrompt(io, arena, system_prompt_flag, append_flag);
}

pub fn applyLive(root: *Agent, arena: Allocator, on: bool, persist: bool) !bool {
    if (on and no_local_tools.enabled) return error.LocalToolsDisabled;
    const saved = if (persist) blk: {
        saveSettings(root.io, arena, on) catch {
            g_enabled = on;
            break :blk false;
        };
        break :blk true;
    } else blk: {
        g_enabled = on;
        break :blk false;
    };
    const next_base = if (enabled())
        try buildPrompt(root.io, root.arena, g_saved_system_flag, g_saved_append_flag)
    else if (g_saved_normal_base.len > 0)
        g_saved_normal_base
    else if (g_saved_system_flag) |sp|
        try root.arena.dupe(u8, sp)
    else
        try @import("prompts.zig").baseForSession(root.arena);
    @import("prompt_cache_hud.zig").noteBust(.mode);
    try @import("prompts.zig").setSystemPrompts(root, next_base, root.arena);
    root.invalidateRootTools();
    try root.ensureRootTools(root.provider.kind);
    return saved;
}

pub fn resetForTest() void {
    g_enabled = false;
    cli_set = false;
    env_set = false;
    g_saved_normal_base = "";
    g_saved_system_flag = null;
    g_saved_append_flag = null;
    test_settings_dir = null;
}

pub const SavedState = struct {
    enabled: bool,
    cli_set: bool,
    env_set: bool,
    normal_base: []const u8,
    system_flag: ?[]const u8,
    append_flag: ?[]const u8,
    settings_dir: ?Io.Dir,

    pub fn save() SavedState {
        return .{
            .enabled = g_enabled,
            .cli_set = cli_set,
            .env_set = env_set,
            .normal_base = g_saved_normal_base,
            .system_flag = g_saved_system_flag,
            .append_flag = g_saved_append_flag,
            .settings_dir = test_settings_dir,
        };
    }

    pub fn restore(self: SavedState) void {
        g_enabled = self.enabled;
        cli_set = self.cli_set;
        env_set = self.env_set;
        g_saved_normal_base = self.normal_base;
        g_saved_system_flag = self.system_flag;
        g_saved_append_flag = self.append_flag;
        test_settings_dir = self.settings_dir;
    }
};
