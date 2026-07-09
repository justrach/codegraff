//! Provider-switch core: resolve a /model or set_model request to a
//! Provider, apply it to the running Agent (translating or clearing history
//! across a wire-format change), and print the switch confirmation. Split
//! out of main.zig (600-line goal). The interactive pickers + ultracode
//! steering + login-auth flow that build on top of this live in
//! pickers.zig, which back-imports switchProvider from here. Back-imports
//! main (as main_mod, since several params are named `root`) for Agent,
//! Keys, Provider, provider_specs, and extractText.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const pricing = @import("pricing.zig");
const resolveModelName = pricing.resolveModelName;

const serde = @import("serde.zig");
const saveModel = serde.saveModel;

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const Provider = provider_mod.Provider;
const provider_specs = provider_mod.provider_specs;
/// Pull plain text out of a message's content (string, or the text blocks of a
/// content array — anthropic "text", openai "text", responses "input/output_text").
pub fn extractText(arena: Allocator, m: Value) []const u8 {
    if (m != .object) return "";
    const c = m.object.get("content") orelse return "";
    if (c == .string) return c.string;
    if (c != .array) return "";
    var b: std.ArrayList(u8) = .empty;
    for (c.array.items) |blk| {
        if (blk != .object) continue;
        if (blk.object.get("text")) |t| if (t == .string) {
            if (b.items.len > 0) b.append(arena, '\n') catch {};
            b.appendSlice(arena, t.string) catch {};
        };
    }
    return b.items;
}

/// Rebuild the history as text-only user/assistant turns in `to_kind`'s format
/// — used to carry the conversation across a wire-format switch. Tool-call
/// structure is dropped (the dialogue is what matters for continuity).
fn translateHistory(arena: Allocator, msgs: *std.json.Array, to_kind: Provider.Kind) void {
    _ = to_kind; // textMessage's {role,content:string} shape is valid in all 3 formats
    var out = std.json.Array.init(arena);
    for (msgs.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;
        const text = std.mem.trim(u8, extractText(arena, m), " \t\r\n");
        if (text.len == 0) continue;
        out.append(textMessage(arena, role, text) catch continue) catch {};
    }
    msgs.* = out;
}

pub fn applyProvider(root: *Agent, arena: Allocator, p: Provider) []const u8 {
    const same_format = root.provider.kind == p.kind;
    var note: []const u8 = "context kept";
    if (!same_format) {
        if (root.keep_context) {
            translateHistory(arena, &root.messages, p.kind);
            note = "context translated & kept";
        } else {
            root.messages = std.json.Array.init(arena);
            root.last_context_tokens = 0;
            note = "history cleared — /keepcontext on to carry it across formats";
        }
    }
    root.cap_new = false; // per-provider token-cap quirk; relearn on rejection
    root.effort_rejected = false; // new model may accept reasoning_effort; relearn
    root.provider = p;
    saveModel(root.io, root.home, p.id, p.model); // remember for next launch
    return note;
}

pub fn resolveProviderControlRequest(
    keys: *Keys,
    arena: Allocator,
    provider_query: []const u8,
    model_query: []const u8,
    legacy_name: []const u8,
) !Provider {
    const provider_id = std.mem.trim(u8, provider_query, " \t");
    const model = std.mem.trim(u8, model_query, " \t");

    if (provider_id.len != 0) {
        for (provider_specs) |spec| {
            if (!std.mem.eql(u8, spec.id, provider_id)) continue;
            const selected_model = if (model.len == 0) spec.default_model else try arena.dupe(u8, model);
            return keys.providerById(spec.id, selected_model);
        }
        return error.InvalidProvider;
    }

    if (model.len != 0) {
        const resolved = resolveModelName(keys.*, model);
        const name = try arena.dupe(u8, resolved orelse model);
        return keys.providerFor(name);
    }

    return resolveProviderRequest(keys, arena, legacy_name);
}

fn resolveProviderRequest(keys: *Keys, arena: Allocator, query: []const u8) !Provider {
    const arg = std.mem.trim(u8, query, " \t");
    if (arg.len == 0) return error.InvalidModelRequest;

    if (std.mem.indexOfAny(u8, arg, " /\t")) |i| {
        const pid = arg[0..i];
        const mdl = std.mem.trim(u8, arg[i + 1 ..], " \t");
        for (provider_specs) |spec| {
            if (!std.mem.eql(u8, spec.id, pid) or mdl.len == 0) continue;
            const m = try arena.dupe(u8, mdl);
            return keys.providerById(pid, m);
        }
    }

    for (provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.id, arg)) continue;
        return keys.providerById(spec.id, spec.default_model);
    }

    const resolved = resolveModelName(keys.*, arg);
    const name = try arena.dupe(u8, resolved orelse arg);
    return keys.providerFor(name);
}

/// Switch the active provider/model. Within the same wire format
/// (provider.kind) the conversation is kept verbatim. Across formats
/// (OpenAI↔Anthropic↔Responses) the stored messages don't fit the new shape:
/// with keep_context on (default) the dialogue is translated to a text-only
/// history and carried over; off clears it.
pub fn setModelRequestLabel(arena: Allocator, provider_query: []const u8, model_query: []const u8, legacy_name: []const u8) ![]const u8 {
    const provider_id = std.mem.trim(u8, provider_query, " \t");
    const model = std.mem.trim(u8, model_query, " \t");
    if (provider_id.len != 0 and model.len != 0) return std.fmt.allocPrint(arena, "{s} {s}", .{ provider_id, model });
    if (provider_id.len != 0) return arena.dupe(u8, provider_id);
    if (model.len != 0) return arena.dupe(u8, model);
    return arena.dupe(u8, std.mem.trim(u8, legacy_name, " \t"));
}

pub fn switchProvider(root: *Agent, arena: Allocator, p: Provider, out: *Io.Writer) !void {
    const note = applyProvider(root, arena, p);
    try out.print("switched to {s} via {s} ({t} format, {d}k ctx) — {s}\n", .{
        p.model, p.id, p.kind, p.context / 1000, note,
    });
    try out.flush();
}

// Tests moved from main.zig alongside the functions they cover (#123 split).

test "translateHistory: flattens to {role,content:string}, keeps user/assistant, drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    var msgs = std.json.Array.init(a);
    try msgs.append(mk(a, "{\"role\":\"system\",\"content\":\"sys\"}")); // dropped
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"hello\"}")); // kept
    try msgs.append(mk(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")); // flattened
    try msgs.append(mk(a, "{\"role\":\"tool\",\"content\":\"result\"}")); // dropped
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"   \"}")); // whitespace-only -> dropped
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("hi", msgs.items[1].object.get("content").?.string);
}

test "set_model control resolves explicit provider/model fields" {
    var all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const codex = try resolveProviderControlRequest(&all, arena, "codex", "gpt-5.5", "");
    try std.testing.expectEqualStrings("codex", codex.id);
    try std.testing.expectEqualStrings("gpt-5.5", codex.model);

    const legacy = try resolveProviderControlRequest(&all, arena, "", "", "codegraff gpt-5.5");
    try std.testing.expectEqualStrings("codegraff", legacy.id);
    try std.testing.expectEqualStrings("gpt-5.5", legacy.model);
}

test "extractText: string content, joined text blocks, and empties" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const plain = std.json.parseFromSliceLeaky(Value, a, "{\"content\":\"plain\"}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("plain", extractText(a, plain));
    const blocks = std.json.parseFromSliceLeaky(Value, a, "{\"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"text\",\"text\":\"b\"}]}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("a\nb", extractText(a, blocks));
    const empty = std.json.parseFromSliceLeaky(Value, a, "{}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("", extractText(a, empty));
    try std.testing.expectEqualStrings("", extractText(a, Value{ .null = {} }));
}
