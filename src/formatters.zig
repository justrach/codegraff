//! Opt-in, trusted startup formatter registry. No prompt/catalog additions.
//! Only init reads settings; the disabled mutation path is an empty-slice check.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const policy = @import("harness_policy.zig");
pub const runner = @import("formatter_run.zig");

pub const default_timeout_ms: u64 = 2_000;
pub const max_timeout_ms: u64 = 10_000;
pub const output_cap: usize = 4096;
pub const file_cap: usize = 16 * 1024 * 1024;
pub const Formatter = struct {
    name: []const u8,
    command: []const []const u8,
    extensions: []const []const u8,
    /// Any one marker enables the formatter; searches stop at the tool root.
    detect: []const []const u8 = &.{},
    timeout_ms: u64 = default_timeout_ms,
    disabled: bool = false,
    custom: bool = false,
    /// JS built-ins run only an already installed project-local executable.
    local_binary: bool = false,
};
pub const Registry = struct { entries: []const Formatter = &.{}, path_env: []const u8 = "" };

pub var active: Registry = .{};

/// Call once at trusted startup, after tool_env.init, with the session arena.
/// Worktrees inherit policy; neither tool calls nor newly created config reload it.
pub fn init(io: Io, arena: Allocator) void {
    active = .{};
    if (!policy.noSymlinkEscape(io, policy.settings_path, null)) return;
    const data = Io.Dir.cwd().readFileAlloc(io, policy.settings_path, arena, .limited(1 << 20)) catch return;
    const settings = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (settings != .object) return;
    const path_env = if (@import("tool_env.zig").get()) |env| env.get("PATH") orelse "" else @import("main.zig").g_path_env;
    active = parse(arena, settings.object.get("formatters"), path_env) catch .{};
}

const builtins = [_]Formatter{
    .{ .name = "zig", .command = &.{ "zig", "fmt", "{file}" }, .extensions = &.{ ".zig", ".zon" } },
    .{ .name = "gofmt", .command = &.{ "gofmt", "-w", "{file}" }, .extensions = &.{".go"} },
    .{ .name = "rustfmt", .command = &.{ "rustfmt", "--config", "skip_children=true", "{file}" }, .extensions = &.{".rs"}, .detect = &.{"Cargo.toml"} },
    .{ .name = "ruff", .command = &.{ "ruff", "format", "{file}" }, .extensions = &.{ ".py", ".pyi" }, .detect = &.{ "pyproject.toml", "ruff.toml", ".ruff.toml" } },
    .{ .name = "prettier", .command = &.{ "node_modules/.bin/prettier", "--write", "{file}" }, .extensions = &.{ ".js", ".jsx", ".ts", ".tsx", ".json", ".css", ".scss", ".html", ".md", ".mdx", ".yaml", ".yml", ".vue", ".svelte" }, .detect = &.{ ".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.cjs", "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "package.json" }, .local_binary = true },
    .{ .name = "biome", .command = &.{ "node_modules/.bin/biome", "format", "--write", "{file}" }, .extensions = &.{ ".js", ".jsx", ".ts", ".tsx", ".json", ".css" }, .detect = &.{ "biome.json", "biome.jsonc" }, .local_binary = true },
};

/// false/missing/malformed is off; true enables built-ins; an object enables
/// built-ins with per-name overrides. Custom extension matches take precedence.
/// Returned entries borrow strings from the arena-owned parsed JSON.
pub fn parse(arena: Allocator, value: ?Value, path_env: []const u8) !Registry {
    const v = value orelse return .{};
    if (v != .object and (v != .bool or !v.bool)) return .{};
    var entries: std.ArrayList(Formatter) = .empty;
    try entries.appendSlice(arena, &builtins);
    if (v == .object) {
        var it = v.object.iterator();
        while (it.next()) |kv| {
            var idx: ?usize = null;
            for (entries.items, 0..) |f, i| if (std.mem.eql(u8, f.name, kv.key_ptr.*)) {
                idx = i;
                break;
            };
            const setting = kv.value_ptr.*;
            if (idx) |i| {
                if (setting == .bool) {
                    entries.items[i].disabled = !setting.bool;
                    continue;
                }
            }
            if (setting != .object) continue;
            var f: Formatter = if (idx) |i| entries.items[i] else .{ .name = kv.key_ptr.*, .command = &.{}, .extensions = &.{}, .custom = true };
            if (setting.object.get("disabled")) |d| {
                if (d == .bool) f.disabled = d.bool;
            }
            if (setting.object.get("command")) |cmd| {
                // An invalid explicit override disables rather than silently
                // falling back to some other command under the same name.
                f.command = try strings(arena, cmd, false);
                f.custom = true;
                f.local_binary = false;
                f.detect = &.{};
            }
            if (setting.object.get("extensions")) |ext| f.extensions = try strings(arena, ext, true);
            if (setting.object.get("detect")) |detect| f.detect = try strings(arena, detect, false);
            if (setting.object.get("timeout_ms")) |t| {
                if (t == .integer and t.integer > 0) f.timeout_ms = @min(@as(u64, @intCast(t.integer)), max_timeout_ms);
            }
            if (f.command.len == 0 or f.extensions.len == 0 or !safeCommand(f.command)) f.disabled = true;
            if (idx) |i| entries.items[i] = f else try entries.append(arena, f);
        }
    }
    return .{ .entries = entries.items, .path_env = path_env };
}

fn strings(arena: Allocator, v: Value, extensions: bool) ![]const []const u8 {
    if (v != .array or v.array.items.len == 0 or v.array.items.len > 64) return &.{};
    const out = try arena.alloc([]const u8, v.array.items.len);
    for (v.array.items, out) |item, *dest| {
        if (item != .string or item.string.len == 0 or item.string.len > 4096 or std.mem.indexOfScalar(u8, item.string, 0) != null) return &.{};
        if (extensions and (item.string[0] != '.' or std.mem.indexOfAny(u8, item.string, "/\\") != null)) return &.{};
        dest.* = item.string;
    }
    return out;
}

fn safeCommand(argv: []const []const u8) bool {
    var exe = std.fs.path.basename(argv[0]);
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".com" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(exe, ext)) {
            exe = exe[0 .. exe.len - ext.len];
            break;
        }
    }
    // Never implicitly download a formatter or interpret a command string.
    for ([_][]const u8{ "npx", "bunx", "uvx", "npm", "pnpm", "yarn", "corepack", "bun", "uv", "pipx", "sh", "bash", "zsh", "cmd", "powershell", "pwsh" }) |denied| {
        if (std.ascii.eqlIgnoreCase(exe, denied)) return false;
    }
    return true;
}

pub fn matches(f: Formatter, path: []const u8) bool {
    if (f.disabled) return false;
    for (f.extensions) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

/// Every successful edit route calls this AFTER verification, while holding
/// the existing same-file lock. Null bytes means the companion normalized the
/// splice, so even with formatting off its syntax note must read actual bytes.
pub fn finishEdit(ctx: @import("tools.zig").ToolCtx, path: []const u8, resolved: []const u8, base: []u8, bytes: ?[]const u8) !@import("tools.zig").ToolOutput {
    return finishEditWith(active, ctx, path, resolved, base, bytes);
}

pub fn finishEditWith(reg: Registry, ctx: @import("tools.zig").ToolCtx, path: []const u8, resolved: []const u8, base: []u8, bytes: ?[]const u8) !@import("tools.zig").ToolOutput {
    var owned = base;
    errdefer ctx.gpa.free(owned);
    var result = try runner.run(reg, ctx.gpa, ctx.io, ctx.agent_cwd, path, resolved);
    defer result.deinit(ctx.gpa);
    owned = try result.appendNote(ctx.gpa, owned);
    if (result.failed_restore) return .{ .text = owned, .is_error = true };
    const reread = if (bytes == null and result.bytes == null) try Io.Dir.cwd().readFileAlloc(ctx.io, resolved, ctx.gpa, .limited(file_cap)) else null;
    defer if (reread) |b| ctx.gpa.free(b);
    const final = result.bytes orelse reread orelse bytes orelse "";
    return .{ .text = try @import("syntax_note.zig").appendToOwned(ctx.gpa, ctx.io, owned, path, resolved, final) };
}

test {
    _ = @import("formatter_tests.zig");
}
