//! Explicitly trusted native extensions. Foreign plugin imports never execute.
//! ABI v1 passes one bounded JSON envelope as the final argv; stdout is JSON.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const runner = @import("process_runner.zig");

pub const Plugin = struct {
    id: []const u8,
    command: []const []const u8,
    events: []const []const u8,
    timeout_ms: u64 = 1000,
};
pub const output_cap = 64 * 1024;
pub const settings_path = ".harness/settings.json";

pub fn identifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 64 or s[0] == '-') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}
fn string(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}
fn strings(a: Allocator, v: ?Value) ![]const []const u8 {
    const x = v orelse return error.InvalidExtensionConfig;
    if (x != .array or x.array.items.len == 0 or x.array.items.len > 32) return error.InvalidExtensionConfig;
    var list: std.ArrayList([]const u8) = .empty;
    for (x.array.items) |item| {
        if (item != .string or item.string.len == 0 or item.string.len > 4096 or std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidExtensionConfig;
        try list.append(a, item.string);
    }
    return list.toOwnedSlice(a);
}
pub fn parse(a: Allocator, data: []const u8) ![]const Plugin {
    const root = try std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always });
    if (root != .object) return error.InvalidExtensionConfig;
    const entries = root.object.get("runtime_plugins") orelse return &.{};
    if (entries != .array or entries.array.items.len > 16) return error.InvalidExtensionConfig;
    var list: std.ArrayList(Plugin) = .empty;
    for (entries.array.items) |entry| {
        if (entry != .object) return error.InvalidExtensionConfig;
        const trusted = entry.object.get("trusted") orelse continue;
        if (trusted != .bool) return error.InvalidExtensionConfig;
        if (!trusted.bool) continue;
        if (entry.object.get("enabled")) |enabled| {
            if (enabled != .bool) return error.InvalidExtensionConfig;
            if (!enabled.bool) continue;
        }
        const id = string(entry.object.get("id")) orelse return error.InvalidExtensionConfig;
        if (!identifier(id)) return error.InvalidExtensionConfig;
        for (list.items) |p| if (std.mem.eql(u8, p.id, id)) return error.DuplicateExtension;
        const events = try strings(a, entry.object.get("events"));
        for (events) |event| {
            if (!std.mem.eql(u8, event, "before_request") and !std.mem.eql(u8, event, "after_response") and !std.mem.eql(u8, event, "ui") and !std.mem.eql(u8, event, "action")) return error.InvalidExtensionEvent;
        }
        const timeout = entry.object.get("timeout_ms") orelse Value{ .integer = 1000 };
        if (timeout != .integer or timeout.integer < 1 or timeout.integer > 10_000) return error.InvalidExtensionConfig;
        try list.append(a, .{ .id = id, .events = events, .command = try strings(a, entry.object.get("command")), .timeout_ms = @intCast(timeout.integer) });
    }
    return list.toOwnedSlice(a);
}
pub fn load(io: Io, a: Allocator) ![]const Plugin {
    if (@import("plugins.zig").disabled) return &.{};
    const data = Io.Dir.cwd().readFileAlloc(io, settings_path, a, .limited(1024 * 1024)) catch |err| return switch (err) {
        error.FileNotFound => &.{},
        else => error.ExtensionSettingsUnavailable,
    };
    const entries = try parse(a, data);
    if (entries.len == 0) return entries;
    const management = try @import("plugin_management.zig").load(io, a, Io.Dir.cwd());
    var enabled: std.ArrayList(Plugin) = .empty;
    for (entries) |p| if (management.enabled(p.id)) try enabled.append(a, p);
    return enabled.toOwnedSlice(a);
}
pub fn handles(p: Plugin, event: []const u8) bool {
    for (p.events) |e| if (std.mem.eql(u8, event, e)) return true;
    return false;
}
pub fn invoke(io: Io, a: Allocator, p: Plugin, event: []const u8, data: Value) !Value {
    if (!handles(p, event)) return error.UnsupportedExtensionEvent;
    if (@import("hard_policy.zig").check(io, a, "plugin.use", p.id) != null) return error.ExtensionDenied;
    const payload = try std.json.Stringify.valueAlloc(a, .{ .version = 1, .event = event, .plugin = p.id, .data = data }, .{});
    if (payload.len > 16 * 1024) return error.ExtensionInputTooLarge;
    const argv = try a.alloc([]const u8, p.command.len + 1);
    @memcpy(argv[0..p.command.len], p.command);
    argv[p.command.len] = payload;
    // No implicit credential inheritance in library/tests before startup.
    var empty = std.process.Environ.Map.init(a);
    defer empty.deinit();
    const result = try runner.runCappedWithOptions(a, io, argv, output_cap, 1024, p.timeout_ms, .{
        .environ_map = @import("tool_env.zig").get() orelse &empty,
        .kill_process_tree = true,
    });
    if (!runner.ranOk(result) or result.stdout_truncated) return error.ExtensionExecutionFailed;
    const response = try std.json.parseFromSliceLeaky(Value, a, result.stdout, .{ .allocate = .alloc_always });
    if (response != .object) return error.InvalidExtensionResponse;
    const version = response.object.get("version") orelse return error.InvalidExtensionResponse;
    if (version != .integer or version.integer != 1) return error.UnsupportedExtensionVersion;
    return response;
}

/// Only sampling and output limits are mutable. Identity, tools, signed
/// history, system instructions and authentication are never plugin output.
pub fn applyOptions(a: Allocator, body: *Value, options: Value) !bool {
    if (body.* != .object or options != .object) return error.InvalidExtensionOptions;
    var changed = false;
    var it = options.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "temperature") or std.mem.eql(u8, key, "top_p")) {
            const number: f64 = switch (value) {
                .integer => @floatFromInt(value.integer),
                .float => value.float,
                else => return error.InvalidExtensionOptions,
            };
            const max: f64 = if (std.mem.eql(u8, key, "temperature")) 2 else 1;
            if (!std.math.isFinite(number) or number < 0 or number > max) return error.InvalidExtensionOptions;
        } else if (std.mem.eql(u8, key, "max_tokens") or std.mem.eql(u8, key, "max_output_tokens") or std.mem.eql(u8, key, "max_completion_tokens")) {
            const existing = body.object.get(key) orelse return error.UnsupportedExtensionOption;
            if (value != .integer or existing != .integer or value.integer < 1 or value.integer > existing.integer) return error.InvalidExtensionOptions;
        } else return error.UnsupportedExtensionOption;
        if (body.object.get(key)) |old| {
            if (std.meta.activeTag(old) == std.meta.activeTag(value)) {
                if (value == .integer and old.integer == value.integer) continue;
                if (value == .float and old.float == value.float) continue;
            }
        }
        try body.object.put(a, key, value);
        changed = true;
    }
    return changed;
}
pub const RequestState = struct { initialized: bool = false, updates: ?Value = null };
pub fn prepare(self: *@import("agent.zig").Agent, raw: []u8, state: *RequestState) ![]u8 {
    errdefer self.gpa.free(raw);
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var body: ?Value = null;
    var changed = false;
    if (state.initialized) {
        if (state.updates) |updates| {
            body = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
            changed = try applyOptions(a, &body.?, updates);
        }
    } else {
        state.initialized = true;
        var saved: std.json.ObjectMap = .empty;
        for (try load(self.io, a)) |p| {
            if (!handles(p, "before_request")) continue;
            if (@import("hard_policy_context.zig").checkAgent(self, a, "plugin.use", p.id) != null) continue;
            if (body == null) body = try std.json.parseFromSliceLeaky(Value, a, raw, .{});
            var metadata: std.json.ObjectMap = .empty;
            try metadata.put(a, "provider", .{ .string = self.provider.id });
            try metadata.put(a, "model", .{ .string = self.provider.model });
            var options: std.json.ObjectMap = .empty;
            for ([_][]const u8{ "temperature", "top_p", "max_tokens", "max_output_tokens", "max_completion_tokens" }) |key| {
                if (body.?.object.get(key)) |value| try options.put(a, key, value);
            }
            try metadata.put(a, "request_options", .{ .object = options });
            const result = try invoke(self.io, a, p, "before_request", .{ .object = metadata });
            if (result.object.get("request_options")) |updates| {
                changed = (try applyOptions(a, &body.?, updates)) or changed;
                var entries = updates.object.iterator();
                while (entries.next()) |entry| try saved.put(a, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        if (saved.count() > 0) {
            const encoded = try std.json.Stringify.valueAlloc(a, Value{ .object = saved }, .{});
            state.updates = try std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), encoded, .{ .allocate = .alloc_always });
        }
    }
    if (!changed) return raw;
    const out = try std.json.Stringify.valueAlloc(self.gpa, body.?, .{});
    self.gpa.free(raw);
    return out;
}
/// Lifecycle observers receive accounting metadata, never transcripts/keys.
/// Observer failures cannot discard an already successful model response.
pub fn observed(self: *@import("agent.zig").Agent) void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const plugins = load(self.io, a) catch return;
    for (plugins) |p| {
        if (!handles(p, "after_response")) continue;
        if (@import("hard_policy_context.zig").checkAgent(self, a, "plugin.use", p.id) != null) continue;
        var data: std.json.ObjectMap = .empty;
        data.put(a, "model", .{ .string = self.provider.model }) catch return;
        data.put(a, "context_tokens", .{ .integer = @intCast(@min(self.last_context_tokens, std.math.maxInt(i64))) }) catch return;
        _ = invoke(self.io, a, p, "after_response", .{ .object = data }) catch {
            if (self.tracer) |tr| tr.note("extension_observer_failed", "an extension observer failed; the successful model response was retained");
            continue;
        };
    }
}

pub fn validateList(list: Value) !void {
    if (list != .object) return error.InvalidExtensionPanel;
    const version = list.object.get("version") orelse return error.InvalidExtensionPanel;
    const panels = list.object.get("panels") orelse return error.InvalidExtensionPanel;
    if (version != .integer or version.integer != 1 or panels != .array or panels.array.items.len > 16) return error.InvalidExtensionPanel;
    for (panels.array.items) |panel| {
        if (panel != .object) return error.InvalidExtensionPanel;
        if (!identifier(string(panel.object.get("plugin")) orelse return error.InvalidExtensionPanel)) return error.InvalidExtensionPanel;
        try validatePanel(panel);
    }
}

pub fn validatePanel(panel: Value) !void {
    if (panel != .object) return error.InvalidExtensionPanel;
    const title = string(panel.object.get("title")) orelse return error.InvalidExtensionPanel;
    if (title.len == 0 or title.len > 120) return error.InvalidExtensionPanel;
    const root = panel.object.get("root") orelse return error.InvalidExtensionPanel;
    var count: usize = 0;
    var bytes: usize = title.len;
    try validateNode(root, 0, &count, &bytes);
}
fn validateNode(node: Value, depth: usize, count: *usize, bytes: *usize) !void {
    count.* += 1;
    if (node != .object or depth > 8 or count.* > 64) return error.InvalidExtensionPanel;
    const kind = string(node.object.get("kind")) orelse return error.InvalidExtensionPanel;
    if (std.mem.eql(u8, kind, "column") or std.mem.eql(u8, kind, "row")) {
        const children = node.object.get("children") orelse return error.InvalidExtensionPanel;
        if (children != .array) return error.InvalidExtensionPanel;
        for (children.array.items) |child| try validateNode(child, depth + 1, count, bytes);
    } else if (std.mem.eql(u8, kind, "text")) {
        const text = string(node.object.get("text")) orelse return error.InvalidExtensionPanel;
        bytes.* += text.len;
    } else if (std.mem.eql(u8, kind, "stat")) {
        const label = string(node.object.get("label")) orelse return error.InvalidExtensionPanel;
        const value = string(node.object.get("value")) orelse return error.InvalidExtensionPanel;
        bytes.* += label.len + value.len;
    } else if (std.mem.eql(u8, kind, "button")) {
        const label = string(node.object.get("label")) orelse return error.InvalidExtensionPanel;
        const action = string(node.object.get("action")) orelse return error.InvalidExtensionPanel;
        if (!identifier(action)) return error.InvalidExtensionPanel;
        bytes.* += label.len;
    } else return error.InvalidExtensionPanel;
    if (bytes.* > 8192) return error.InvalidExtensionPanel;
}

test {
    _ = @import("extension_runtime_tests.zig");
}
