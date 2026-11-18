//! OpenAI hosted `tool_search` on Codex Responses (gpt-5.4+).
//!
//! Folded native tools and MCP names ship with `defer_loading: true` plus a
//! `{"type":"tool_search"}` entry so the model loads schemas at the end of
//! the window (cache-preserving) instead of paying every parameter block up
//! front. Always-on loop tools (bash, files, codedb, …) stay eager.
//! `tool_search_call` / `tool_search_output` are server-executed — never
//! dispatched locally.
//!
//! Hosted `web_search` is spliced onto the same Codex tools array (probed live
//! on chatgpt.com/backend-api/codex/responses). `GRAFF_CODEX_WEB_SEARCH=0` opts out.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const Provider = @import("provider.zig").Provider;
const native_fold = @import("native_fold.zig");
const mcp = @import("mcp.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const named_work = @import("named_work.zig");
const session_wake = @import("session_wake.zig");
const compaction_window = @import("compaction_window.zig");
const additional_tools = @import("additional_tools.zig");

pub fn modelSupports(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gpt-5.4") or
        std.mem.startsWith(u8, model, "gpt-5.5") or
        std.mem.startsWith(u8, model, "gpt-5.6") or
        std.mem.startsWith(u8, model, "gpt-6");
}

pub fn active(provider_id: []const u8, kind: Provider.Kind, model: []const u8) bool {
    return kind == .responses and std.mem.eql(u8, provider_id, "codex") and modelSupports(model);
}

pub var web_search: bool = true;

pub fn isHostedSearchItem(m: Value) bool {
    if (m != .object) return false;
    const t = m.object.get("type") orelse return false;
    if (t != .string) return false;
    return std.mem.eql(u8, t.string, "tool_search_call") or
        std.mem.eql(u8, t.string, "tool_search_output");
}

pub fn isServerSideItem(itype: []const u8) bool {
    return std.mem.eql(u8, itype, "tool_search_call") or
        std.mem.eql(u8, itype, "tool_search_output") or
        std.mem.eql(u8, itype, "web_search_call");
}

fn toolName(tool: Value) []const u8 {
    if (tool != .object) return "";
    if (tool.object.get("function")) |fn_v| if (fn_v == .object) {
        if (fn_v.object.get("name")) |n| if (n == .string) return n.string;
    };
    if (tool.object.get("name")) |n| if (n == .string) return n.string;
    return "";
}

fn shouldDefer(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "mcp__")) return !@import("mcp_schema_gate.zig").isLoaded(name);
    if (std.mem.startsWith(u8, name, "mcp_")) return true;
    return native_fold.blocked(name);
}

fn hasType(tools: []const Value, typ: []const u8) bool {
    for (tools) |tool| {
        if (tool != .object) continue;
        const t = if (tool.object.get("type")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, t, typ)) return true;
    }
    return false;
}

/// Mark deferred functions and append hosted `tool_search` once.
pub fn splice(arena: Allocator, tools_json: []const u8) ![]const u8 {
    var value = std.json.parseFromSliceLeaky(Value, arena, tools_json, .{ .allocate = .alloc_always }) catch return tools_json;
    if (value != .array) return tools_json;
    var changed = false;
    var deferred = false;
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        if (shouldDefer(toolName(tool.*)) and !tool.object.contains("defer_loading")) {
            try tool.object.put(arena, "defer_loading", .{ .bool = true });
            changed = true;
        }
        if (tool.object.get("defer_loading")) |flag| {
            if (flag == .bool and flag.bool) deferred = true;
        }
    }
    // Hosted search is invalid without a genuinely deferred tool (#746).
    // Also remove an orphan carried by a previously processed catalog.
    if (!deferred) {
        var i: usize = 0;
        while (i < value.array.items.len) {
            if (hasType(value.array.items[i .. i + 1], "tool_search")) {
                _ = value.array.orderedRemove(i);
                changed = true;
            } else i += 1;
        }
    } else if (!hasType(value.array.items, "tool_search")) {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "type", .{ .string = "tool_search" });
        try value.array.append(.{ .object = obj });
        changed = true;
    }
    if (!changed) return tools_json;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.toOwnedSlice();
}

/// Append hosted `web_search` once. Codex accepted this live on gpt-5.6-sol.
pub fn spliceWebSearch(arena: Allocator, tools_json: []const u8) ![]const u8 {
    if (!web_search) return tools_json;
    var value = std.json.parseFromSliceLeaky(Value, arena, tools_json, .{ .allocate = .alloc_always }) catch return tools_json;
    if (value != .array) return tools_json;
    if (hasType(value.array.items, "web_search")) return tools_json;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = "web_search" });
    try value.array.append(.{ .object = obj });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(value);
    return aw.toOwnedSlice();
}

test "#746 eager and empty catalogs never acquire hosted tool_search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "[]",
        "[{\"type\":\"function\",\"name\":\"bash\"}]",
        "[{\"type\":\"function\",\"name\":\"webfetch\",\"defer_loading\":false}]",
        "[{\"type\":\"function\",\"name\":\"webfetch\",\"defer_loading\":\"true\"}]",
    }) |catalog| try std.testing.expectEqualStrings(catalog, try splice(arena.allocator(), catalog));
}

test "#746 existing deferred flags enable hosted search and orphan search is removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalog = "[{\"type\":\"function\",\"name\":\"custom\",\"defer_loading\":true}]";
    const out = try splice(a, catalog);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"type\":\"tool_search\""));
    try std.testing.expectEqualStrings(out, try splice(a, out));
    try std.testing.expectEqualStrings("[]", try splice(a, "[{\"type\":\"tool_search\"}]"));
    const eager = try splice(a, "[{\"type\":\"function\",\"name\":\"bash\"},{\"type\":\"tool_search\"}]");
    try std.testing.expect(std.mem.indexOf(u8, eager, "tool_search") == null);
    try std.testing.expect(std.mem.indexOf(u8, eager, "bash") != null);
}

test "modelSupports is gpt-5.4+ / gpt-6, not gpt-5.3" {
    try std.testing.expect(modelSupports("gpt-5.4"));
    try std.testing.expect(modelSupports("gpt-5.6-sol"));
    try std.testing.expect(modelSupports("gpt-6-astra"));
    try std.testing.expect(!modelSupports("gpt-5.3-codex"));
    try std.testing.expect(!active("codex", .openai, "gpt-5.6-sol"));
    try std.testing.expect(active("codex", .responses, "gpt-5.6-sol"));
    try std.testing.expect(!active("openai", .responses, "gpt-5.6-sol"));
}

test "splice defers folded tools and appends tool_search once" {
    const saved_enabled = native_fold.enabled;
    const was_loaded = native_fold.isLoaded("webfetch");
    defer {
        native_fold.enabled = saved_enabled;
        if (was_loaded) native_fold.markLoaded("webfetch") else native_fold.unloadForTest("webfetch");
    }
    native_fold.enabled = true;
    native_fold.unloadForTest("webfetch");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tools =
        \\[{"type":"function","name":"bash","description":"run"},{"type":"function","name":"webfetch","description":"web"}]
    ;
    const out = try splice(a, tools);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"tool_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"webfetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"defer_loading\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"bash\"") != null);
    // bash is eager — the only defer_loading is on webfetch.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"defer_loading\":true"));
    const again = try splice(a, out);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, "\"type\":\"tool_search\""));
    // Once unfolded (#492), a loaded native must stay eager instead of re-deferring.
    native_fold.markLoaded("webfetch");
    const loaded_out = try splice(a, tools);
    try std.testing.expect(std.mem.indexOf(u8, loaded_out, "\"defer_loading\":true") == null);
    try std.testing.expect(std.mem.indexOf(u8, loaded_out, "\"type\":\"tool_search\"") == null);
}

test "isServerSideItem covers hosted search items" {
    try std.testing.expect(isServerSideItem("tool_search_call"));
    try std.testing.expect(isServerSideItem("tool_search_output"));
    try std.testing.expect(isServerSideItem("web_search_call"));
    try std.testing.expect(!isServerSideItem("function_call"));
}

test "spliceWebSearch appends hosted web_search once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try spliceWebSearch(a, "[{\"type\":\"function\",\"name\":\"bash\"}]");
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"web_search\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, try spliceWebSearch(a, out), "\"type\":\"web_search\""));
    const saved = web_search;
    defer web_search = saved;
    web_search = false;
    try std.testing.expectEqualStrings("[{\"type\":\"function\",\"name\":\"bash\"}]", try spliceWebSearch(a, "[{\"type\":\"function\",\"name\":\"bash\"}]"));
}

fn hasConnectedMcp(connected: []const mcp.Tool, name: []const u8) bool {
    for (connected) |t| if (std.mem.eql(u8, t.qualified_name, name)) return true;
    return false;
}

fn appendUniqueName(alloc: Allocator, list: *std.ArrayList([]const u8), name: []const u8) void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    list.append(alloc, name) catch {};
}

fn formatUnmatchedContext(alloc: Allocator, names: []const []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(alloc);
    try aw.writer.writeAll("[tool search context: matched tools: ");
    for (names, 0..) |name, idx| {
        if (idx > 0) try aw.writer.writeAll(", ");
        try aw.writer.writeAll(name);
    }
    try aw.writer.writeByte(']');
    return aw.writer.buffered();
}

/// Sanitize Codex-hosted `tool_search_call` / `tool_search_output` items before
/// sending Responses history to any non-`codex` route such as `chatgpt-new`.
/// Folded native tools and connected MCP tools are unfolded locally so later
/// `additional_tools` / catalog serialization preserves access; unmatched names
/// become a plain user notification so context survives without hosted items (#1907).
pub fn sanitizeForProvider(self: *@import("agent.zig").Agent) bool {
    if (self.provider.kind != .responses or std.mem.eql(u8, self.provider.id, "codex")) return false;
    const min_idx: usize = if (compaction_window.latestBlob(self.messages.items)) |b| b + 1 else 0;
    var has_hosted = false;
    for (self.messages.items[min_idx..]) |m| {
        if (isHostedSearchItem(m)) {
            has_hosted = true;
            break;
        }
    }
    if (!has_hosted) return false;

    const alloc = self.historyAlloc();
    const connected: []const mcp.Tool = if (self.registry) |reg| (reg.snapshotTools(alloc) catch &.{}) else &.{};
    var changed = false;
    var loaded_any = false;
    var i: usize = min_idx;
    while (i < self.messages.items.len) {
        const m = self.messages.items[i];
        if (!isHostedSearchItem(m)) {
            i += 1;
            continue;
        }
        const itype = m.object.get("type").?.string;
        if (std.mem.eql(u8, itype, "tool_search_call")) {
            _ = self.messages.orderedRemove(i);
            changed = true;
            continue;
        }
        var unmatched: std.ArrayList([]const u8) = .empty;
        if (m.object.get("tools")) |tools_v| if (tools_v == .array) {
            for (tools_v.array.items) |entry| {
                const name = if (entry == .string) entry.string else toolName(entry);
                if (name.len == 0) continue;
                if (!self.sub and native_fold.isFolded(name)) {
                    native_fold.markLoaded(name);
                    loaded_any = true;
                } else if (!self.sub and std.mem.startsWith(u8, name, "mcp__") and hasConnectedMcp(connected, name)) {
                    mcp_schema_gate.autoLoad(alloc, connected, name);
                    loaded_any = true;
                } else {
                    appendUniqueName(alloc, &unmatched, name);
                }
            }
        };
        if (unmatched.items.len > 0) {
            const note = formatUnmatchedContext(alloc, unmatched.items) catch {
                _ = self.messages.orderedRemove(i);
                changed = true;
                continue;
            };
            const msg = session_wake.mark(alloc, named_work.responsesUserMessage(alloc, note) catch {
                _ = self.messages.orderedRemove(i);
                changed = true;
                continue;
            }) catch {
                _ = self.messages.orderedRemove(i);
                changed = true;
                continue;
            };
            self.messages.items[i] = msg;
            i += 1;
        } else {
            _ = self.messages.orderedRemove(i);
        }
        changed = true;
    }
    if (loaded_any) self.invalidateRootTools();
    if (changed) self.history_rewrites +%= 1;
    return changed;
}

test "sanitizeForProvider strips Codex tool_search_* on chatgpt-new, unfolds tools, and preserves codex replay (#1907)" {
    native_fold.clearLoadedSession();
    defer native_fold.clearLoadedSession();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const call_item = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"tool_search_call\",\"id\":\"tsc_1\",\"call_id\":\"c_1\",\"arguments\":{\"paths\":[\"webfetch\"]}}", .{});
    const out_item = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"tool_search_output\",\"id\":\"tso_1\",\"call_id\":\"c_1\",\"tools\":[{\"type\":\"function\",\"name\":\"webfetch\"},{\"type\":\"function\",\"name\":\"mcp__offline__search\"}]}", .{});
    try agent.messages.append(call_item);
    try agent.messages.append(out_item);

    // On codex, hosted tool_search_* items remain replayable on the wire.
    const codex_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(codex_body);
    try std.testing.expect(std.mem.indexOf(u8, codex_body, "\"type\":\"tool_search_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_body, "\"type\":\"tool_search_output\"") != null);

    // Switching onto chatgpt-new sanitizes hosted search items and unfolds matches locally.
    agent.provider.id = "chatgpt-new";
    agent.provider.model = "gpt-5.4";
    try std.testing.expect(sanitizeForProvider(&agent));
    try std.testing.expect(native_fold.isLoaded("webfetch"));
    additional_tools.sync(&agent);

    const chatgpt_body = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(chatgpt_body);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "tool_search_call") == null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "tool_search_output") == null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "tsc_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "tso_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "\"type\":\"additional_tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "\"name\":\"webfetch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, chatgpt_body, "[tool search context: matched tools: mcp__offline__search]") != null);
}
