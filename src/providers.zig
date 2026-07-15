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
const ansi = @import("ansi.zig");
const fallback_config = @import("fallback_config.zig");

fn localProviderUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://127.0.0.1") or std.mem.startsWith(u8, url, "http://localhost") or std.mem.startsWith(u8, url, "http://[::1]");
}

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

fn applyProviderInner(root: *Agent, arena: Allocator, p: Provider, persist: bool) []const u8 {
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
    root.ws_off = false; // a previous Codex WS fallback must not leak across switches
    root.provider = p;
    // #204: a provider switch changes the window; don't carry the previous model's
    // absolute token count against it. Re-estimate from the (kept or translated)
    // history so the meter + compaction gate stay consistent until the next response
    // returns real usage. (The cross-format history-clear above already set 0;
    // fullInputEstimateTokens over an empty history is 0.)
    root.last_context_tokens = root.fullInputEstimateTokens();
    root.fallback_active = !persist;
    root.fallback_blocked = false;
    if (persist) saveModel(root.io, root.home, p.id, p.model);
    return note;
}

/// An explicit /model or set_model selection becomes the next-launch default.
pub fn applyProvider(root: *Agent, arena: Allocator, p: Provider) []const u8 {
    return applyProviderInner(root, arena, p, true);
}

/// Automatic failover is session-local: preserve the user's saved preference
/// so a repaired credential/model is tried again on the next fresh launch.
pub fn applyFallbackProvider(root: *Agent, arena: Allocator, p: Provider) []const u8 {
    return applyProviderInner(root, arena, p, false);
}

fn triedProvider(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

/// Walk configured providers in stable priority order, beginning after the
/// failed provider and wrapping once. Providers without credentials and ids
/// already attempted during this turn are skipped.
pub fn nextFallbackProvider(keys: Keys, after_id: []const u8, tried: []const []const u8, allow: []const []const u8) ?Provider {
    var start: usize = 0;
    for (provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, after_id)) {
        start = (i + 1) % provider_specs.len;
        break;
    };
    for (0..provider_specs.len) |offset| {
        const i = (start + offset) % provider_specs.len;
        const spec = provider_specs[i];
        const key = keys.values[i] orelse continue;
        if (triedProvider(tried, spec.id)) continue;
        if (!fallback_config.contains(allow, spec.id)) continue;
        return keys.build(spec, key, pricing.providerDefaultModel(spec.id, spec.default_model));
    }
    return null;
}

/// Only failures that clearly mean "this credential/model cannot serve the
/// request" are safe to fail over. Network flakes, rate limits, malformed
/// replies, context overflow, and interrupts stay on the selected provider.
pub fn failoverEligible(detail: []const u8) bool {
    const needles = [_][]const u8{
        "unauthorized",
        "authentication_error",
        "authentication token",
        "authentication failed",
        "invalid api key",
        "invalid_api_key",
        "invalid x-api-key",
        "incorrect api key",
        "api key not valid",
        "invalid token",
        "token expired",
        "expired token",
        "access token has expired",
        "401",
        "403",
        "forbidden",
        "access denied",
        "permission denied",
        "permission_denied",
        "model_not_found",
        "model not found",
        "model is not available",
        "model unavailable",
        "model does not exist",
        "does not exist or you do not have access",
        "you do not have access to model",
        "you do not have access to this model",
        "insufficient_quota",
        "quota exceeded",
        "credits exhausted",
        "insufficient credits",
        "credit balance",
        "no credits",
        "billing limit",
    };
    for (needles) |needle| if (std.ascii.indexOfIgnoreCase(detail, needle) != null) return true;
    return false;
}

/// Run a root turn and, before any text/tools have escaped, rotate through
/// credential-backed providers on a clear auth/model/quota failure. Successful
/// fallback becomes active for this session but does not replace the saved
/// model preference.
pub fn runTurnWithFallback(root: *Agent, keys: Keys, arena: Allocator, out: ?*Io.Writer) anyerror![]const u8 {
    if (root.fallback_blocked) return error.FallbackConsentRequired;
    var attempted: [provider_specs.len][]const u8 = undefined;
    var attempted_len: usize = 1;
    attempted[0] = root.provider.id;
    while (true) {
        root.last_api_error = null;
        const result = root.runTurn();
        if (result) |text| return text else |err| {
            if (err != error.ApiError or root.partial_text.items.len != 0 or root.tool_calls_this_turn != 0)
                return err;
            const detail = root.last_api_error orelse return err;
            if (!failoverEligible(detail)) return err;
            const failed_id = root.provider.id;
            const failed_model = root.provider.model;
            const fallback = nextFallbackProvider(keys, failed_id, attempted[0..attempted_len], root.fallback_allow) orelse return err;
            attempted[attempted_len] = fallback.id;
            attempted_len += 1;
            const note = applyFallbackProvider(root, arena, fallback);
            if (main_mod.json_mode) {
                root.emit(.{ .type = "model", .ok = true, .provider = fallback.id, .model = fallback.model, .context = fallback.context, .note = "automatic session fallback; saved model preference kept" });
            } else if (out) |w| {
                try w.print("{s}⚠ {s} via {s} is unavailable; trying {s} via {s} for this session ({s}) — saved default kept{s}\n", .{
                    ansi.style.yellow,
                    failed_model,
                    failed_id,
                    fallback.model,
                    fallback.id,
                    note,
                    ansi.style.reset,
                });
                try w.flush();
            } else {
                std.debug.print("⚠ {s} via {s} is unavailable; trying {s} via {s} for this session ({s}) — saved default kept\n", .{ failed_model, failed_id, fallback.model, fallback.id, note });
            }
            if (root.tracer) |tr| {
                const trace_note = std.fmt.allocPrint(arena, "{s}/{s} -> {s}/{s}", .{ failed_id, failed_model, fallback.id, fallback.model }) catch "automatic provider fallback";
                tr.note("model_fallback", trace_note);
            }
        }
    }
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
            const selected_model = if (model.len == 0) pricing.providerDefaultModel(spec.id, spec.default_model) else try arena.dupe(u8, model);
            if (model.len != 0 and !localProviderUrl(spec.url) and !pricing.providerModelInTable(spec.id, selected_model)) return error.InvalidModel;
            return keys.providerById(spec.id, selected_model);
        }
        return error.InvalidProvider;
    }

    if (model.len != 0) {
        const resolved = resolveModelName(keys.*, model) orelse return error.InvalidModel;
        const name = try arena.dupe(u8, resolved);
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
            if (!localProviderUrl(spec.url) and !pricing.providerModelInTable(pid, mdl)) return error.InvalidModel;
            const m = try arena.dupe(u8, mdl);
            return keys.providerById(pid, m);
        }
    }

    for (provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.id, arg)) continue;
        return keys.providerById(spec.id, pricing.providerDefaultModel(spec.id, spec.default_model));
    }

    const resolved = resolveModelName(keys.*, arg) orelse return error.InvalidModel;
    const name = try arena.dupe(u8, resolved);
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
    try out.print("switched to {s} via {s} ({t} format, {d}k ctx) — {s} · saved for next session\n", .{
        p.model, p.id, p.kind, p.context / 1000, note,
    });
    try out.flush();
}

// Tests moved from main.zig alongside the functions they cover (#123 split).

test "failoverEligible: accepts unavailable credentials/models, rejects transient or prompt errors" {
    try std.testing.expect(failoverEligible("codex api error: Unauthorized"));
    try std.testing.expect(failoverEligible("access token has expired"));
    try std.testing.expect(failoverEligible("model_not_found: rollout ended"));
    try std.testing.expect(failoverEligible("insufficient_quota"));
    try std.testing.expect(!failoverEligible("network error: HttpConnectionClosing"));
    try std.testing.expect(!failoverEligible("rate limited (429)"));
    try std.testing.expect(!failoverEligible("maximum context length exceeded"));
    try std.testing.expect(!failoverEligible("unparseable response"));
}

test "nextFallbackProvider: rotates after the failed provider and skips missing or tried credentials" {
    const all = Keys{ .values = [_]?[]const u8{"k"} ** provider_specs.len };
    const tried_codex = [_][]const u8{"codex"};
    const allow_all = blk: {
        var ids: [provider_specs.len][]const u8 = undefined;
        for (provider_specs, 0..) |spec, i| ids[i] = spec.id;
        break :blk ids;
    };
    const wrapped = nextFallbackProvider(all, "codex", &tried_codex, &allow_all).?;
    try std.testing.expectEqualStrings("anthropic", wrapped.id);

    var values = [_]?[]const u8{null} ** provider_specs.len;
    for (provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "codegraff") or std.mem.eql(u8, spec.id, "openai")) values[i] = "k";
    }
    const sparse = Keys{ .values = values };
    const tried = [_][]const u8{ "codex", "codegraff" };
    const next = nextFallbackProvider(sparse, "codex", &tried, &allow_all).?;
    try std.testing.expectEqualStrings("openai", next.id);
    const exhausted = [_][]const u8{ "codex", "codegraff", "openai" };
    try std.testing.expect(nextFallbackProvider(sparse, "openai", &exhausted, &allow_all) == null);
    const allow_codegraff = [_][]const u8{"codegraff"};
    try std.testing.expectEqualStrings("codegraff", nextFallbackProvider(sparse, "codex", &tried_codex, &allow_codegraff).?.id);
}

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
    try std.testing.expectError(error.InvalidModel, resolveProviderControlRequest(&all, arena, "", "definitely-not-a-model", ""));
    try std.testing.expectError(error.InvalidModel, resolveProviderControlRequest(&all, arena, "openai", "definitely-not-a-model", ""));

    const local = try resolveProviderControlRequest(&all, arena, "lmstudio", "user-loaded/model", "");
    try std.testing.expectEqualStrings("user-loaded/model", local.model);
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
