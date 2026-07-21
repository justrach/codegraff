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
const kimi_catalog = @import("kimi_catalog.zig");

const serde = @import("serde.zig");
const saveModel = serde.saveModel;

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const ansi = @import("ansi.zig");
const fallback_config = @import("fallback_config.zig");
const util = @import("util.zig");
const trace = @import("trace.zig");

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

fn applyProviderInner(root: *Agent, arena: Allocator, p: Provider, persist: bool) ![]const u8 {
    const same_format = root.provider.kind == p.kind;
    const same_selection = same_format and
        root.provider.context == p.context and
        std.mem.eql(u8, root.provider.id, p.id) and
        std.mem.eql(u8, root.provider.model, p.model) and
        std.mem.eql(u8, root.provider.url, p.url);
    var note: []const u8 = "context kept";
    if (!same_format) {
        if (root.keep_context) {
            translateHistory(arena, &root.messages, p.kind);
            note = "context translated & kept";
        } else {
            root.messages = std.json.Array.init(arena);
            root.last_context_tokens = 0;
            root.context_local_tokens = 0;
            note = "history cleared — /keepcontext on to carry it across formats";
        }
    }
    root.provider = p;
    // Keep the context estimate and first request exact without eagerly
    // materializing formats this session has never used.
    try root.ensureRootTools(p.kind);
    // #204: an actual provider/model switch changes the window and tokenizer, so
    // re-estimate until the next response returns real usage. A no-op set_model is
    // common in the GUI prompt-settings path; preserve its authoritative server
    // meter instead of replacing it with the structurally-low local estimate.
    if (!same_selection) {
        root.cap_new = false; // per-provider token-cap quirk; relearn on rejection
        root.effort_rejected = false; // new model may accept reasoning_effort; relearn
        root.ws_off = false; // a previous Codex WS fallback must not leak across switches
        root.ws_transport_failures = 0;
        root.compact_transport_failures = 0;
        root.last_context_tokens = root.fullRequestEstimateTokens();
        root.context_local_tokens = root.last_context_tokens;
        root.last_cache_read = 0;
    }
    root.fallback_active = !persist;
    root.fallback_blocked = false;
    if (persist) saveModel(root.io, root.home, p.id, p.model);
    return note;
}

/// An explicit /model or set_model selection becomes the next-launch default.
pub fn applyProvider(root: *Agent, arena: Allocator, p: Provider) ![]const u8 {
    return applyProviderInner(root, arena, p, true);
}

/// Automatic failover is session-local: preserve the user's saved preference
/// so a repaired credential/model is tried again on the next fresh launch.
pub fn applyFallbackProvider(root: *Agent, arena: Allocator, p: Provider) ![]const u8 {
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
    for (needles) |needle| if (util.indexOfIgnoreCase(detail, needle) != null) return true;
    return false;
}

/// Run a root turn and, before any text/tools have escaped, rotate through
/// credential-backed providers on a clear auth/model/quota failure. Successful
/// fallback becomes active for this session but does not replace the saved
/// model preference.
pub fn runTurnWithFallback(root: *Agent, keys: *Keys, arena: Allocator, out: ?*Io.Writer) anyerror![]const u8 {
    const behavior_turn = trace.beginRootTurn(root.tracer);
    defer trace.endRootTurn(root.tracer, behavior_turn);
    if (root.fallback_blocked) return error.FallbackConsentRequired;
    var attempted: [provider_specs.len][]const u8 = undefined;
    var attempted_len: usize = 1;
    attempted[0] = root.provider.id;
    while (true) {
        root.last_api_error = null;
        const result = root.runTurn();
        if (result) |text| {
            // #255: no clean per-segment choke point exists across the
            // provider streaming paths, so the root turn's final text is
            // recorded once here (opt-in rich capture only; no-op otherwise).
            if (root.tracer) |tr| tr.textDelta(text);
            return text;
        } else |err| {
            if (err != error.ApiError or root.partial_text.items.len != 0 or root.tool_calls_this_turn != 0)
                return err;
            const detail = root.last_api_error orelse return err;
            if (!failoverEligible(detail)) return err;
            const failed_id = root.provider.id;
            const failed_model = root.provider.model;
            root.ensureStoredKeys(keys);
            // The failure path is already paying for exhaustive credentials;
            // hydrate deferred account catalogs before choosing a fallback.
            ensureModelQueryCatalogs(root, keys.*, "");
            const fallback = nextFallbackProvider(keys.*, failed_id, attempted[0..attempted_len], root.fallback_allow) orelse return err;
            attempted[attempted_len] = fallback.id;
            attempted_len += 1;
            const note = try applyFallbackProvider(root, arena, fallback);
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

/// Whether a human `/model` query can observe account-scoped Codex rows.
/// Explicit non-Codex providers never need the dynamic catalog; bare/fuzzy
/// model queries do because they may name a new account rollout.
pub fn modelQueryMayUseCodex(query: []const u8) bool {
    const arg = std.mem.trim(u8, query, " \t");
    if (arg.len == 0) return true;
    const provider_end = std.mem.indexOfAny(u8, arg, " /\t") orelse arg.len;
    const provider_id = arg[0..provider_end];
    for (provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        return std.mem.eql(u8, spec.id, "codex");
    }
    return true;
}

fn modelQueryMayUseKimi(query: []const u8) bool {
    const arg = std.mem.trim(u8, query, " \t");
    if (arg.len == 0) return true;
    const provider_end = std.mem.indexOfAny(u8, arg, " /\t") orelse arg.len;
    const provider_id = arg[0..provider_end];
    for (provider_specs) |spec| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        return std.mem.eql(u8, spec.id, "kimi");
    }
    if (pricing.modelInTable(arg)) return pricing.providerModelInTable("kimi", arg);
    return true;
}

pub fn ensureModelQueryCatalogs(root: *Agent, keys: Keys, query: []const u8) void {
    if (modelQueryMayUseCodex(query)) root.ensureModelCatalog(keys);
    if (modelQueryMayUseKimi(query))
        kimi_catalog.ensure(root.io, root.gpa, root.arena, root.home, keys.get("kimi") orelse "");
}

/// Structured set_model has separate provider/model fields. An explicit
/// provider fully determines routing; a model-only request remains fuzzy.
pub fn controlRequestMayUseCodex(provider_query: []const u8, model_query: []const u8, legacy_name: []const u8) bool {
    const provider_id = std.mem.trim(u8, provider_query, " \t");
    if (provider_id.len != 0) return std.mem.eql(u8, provider_id, "codex");
    if (std.mem.trim(u8, model_query, " \t").len != 0) return true;
    return modelQueryMayUseCodex(legacy_name);
}

pub fn ensureControlRequestCatalogs(root: *Agent, keys: Keys, provider_query: []const u8, model_query: []const u8, legacy_name: []const u8) void {
    if (controlRequestMayUseCodex(provider_query, model_query, legacy_name)) root.ensureModelCatalog(keys);
    const query = if (std.mem.trim(u8, provider_query, " \t").len != 0)
        provider_query
    else if (std.mem.trim(u8, model_query, " \t").len != 0)
        model_query
    else
        legacy_name;
    if (modelQueryMayUseKimi(query))
        kimi_catalog.ensure(root.io, root.gpa, root.arena, root.home, keys.get("kimi") orelse "");
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
    const note = try applyProvider(root, arena, p);
    try out.print("switched to {s} via {s} ({t} format, {d}k ctx) — {s} · saved for next session\n", .{
        p.model, p.id, p.kind, p.context / 1000, note,
    });
    try out.flush();
}

// Tests moved from main.zig alongside the functions they cover (#123 split).

test "runTurnWithFallback: blocked return closes behavioral root scope" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var events: Io.Writer.Allocating = .init(gpa);
    defer events.deinit();
    var behavior: trace.BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &events.writer,
        .run_id = "blocked-fallback-run",
    };
    behavior.start("test", 1);
    var tracer: trace.Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = trace.g_traj;
    trace.g_traj = null;
    defer trace.g_traj = previous_trajectory;

    var root: Agent = undefined;
    root.tracer = &tracer;
    root.fallback_blocked = true;
    const keys: Keys = .{ .values = @splat(null) };
    try std.testing.expectError(
        error.FallbackConsentRequired,
        runTurnWithFallback(&root, @constCast(&keys), gpa, null),
    );

    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(
        @as(u64, 0),
        behavior.recordApiMetric(false, 1, 2, 3, 4, 5, false),
    );

    var turn_starts: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, events.writer.buffered(), "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(Value, gpa, line, .{});
        defer parsed.deinit();
        const kind = parsed.value.object.get("kind") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "turn_started")) turn_starts += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), turn_starts);
}

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
    const all = Keys{ .values = @splat("k") };
    const tried_codex = [_][]const u8{"codex"};
    const allow_all = blk: {
        var ids: [provider_specs.len][]const u8 = undefined;
        for (provider_specs, 0..) |spec, i| ids[i] = spec.id;
        break :blk ids;
    };
    const wrapped = nextFallbackProvider(all, "codex", &tried_codex, &allow_all).?;
    try std.testing.expectEqualStrings("anthropic", wrapped.id);

    var values: [provider_specs.len]?[]const u8 = @splat(null);
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

test "applyProviderInner preserves the server meter on an exact model re-selection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };

    var root: Agent = undefined;
    root.provider = p;
    root.arena = a;
    root.registry = null;
    root.messages = std.json.Array.init(a);
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_anthropic = "";
    root.tools_openai = "";
    root.tools_responses = "";
    root.keep_context = true;
    root.last_context_tokens = 220_000;
    root.context_local_tokens = root.fullRequestEstimateTokens();
    root.last_cache_read = 12_345;
    root.cap_new = true;
    root.effort_rejected = true;
    root.ws_off = true;
    root.ws_transport_failures = 2;
    _ = try applyProviderInner(&root, a, p, false);
    try std.testing.expect(root.tools_responses.len > 0);
    try std.testing.expectEqual(@as(usize, 0), root.tools_anthropic.len);
    try std.testing.expectEqual(@as(usize, 0), root.tools_openai.len);
    try std.testing.expectEqual(@as(u64, 220_000), root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 12_345), root.last_cache_read);
    try std.testing.expect(root.cap_new);
    try std.testing.expect(root.effort_rejected);
    try std.testing.expect(root.ws_off);

    var changed = p;
    changed.model = "gpt-5.1";
    _ = try applyProviderInner(&root, a, changed, false);
    try std.testing.expectEqual(root.fullRequestEstimateTokens(), root.last_context_tokens);
    try std.testing.expectEqual(root.last_context_tokens, root.context_local_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);
    try std.testing.expect(!root.cap_new);
    try std.testing.expect(!root.effort_rejected);
    try std.testing.expect(!root.ws_off);
    try std.testing.expectEqual(@as(u8, 0), root.ws_transport_failures);

    var changed_format = changed;
    changed_format.id = "deepseek";
    changed_format.kind = .openai;
    changed_format.model = "deepseek-chat";
    _ = try applyProviderInner(&root, a, changed_format, false);
    try std.testing.expect(root.tools_openai.len > 0);
    try std.testing.expect(root.tools_responses.len > 0); // already paid for, remains cached
    try std.testing.expectEqual(@as(usize, 0), root.tools_anthropic.len);
}

test "set_model control resolves explicit provider/model fields" {
    var all = Keys{ .values = @splat("k") };
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

test "Codex catalog demand follows model request routing" {
    try std.testing.expect(modelQueryMayUseCodex(""));
    try std.testing.expect(!modelQueryMayUseCodex("deepseek"));
    try std.testing.expect(!modelQueryMayUseCodex("deepseek/deepseek-chat"));
    try std.testing.expect(modelQueryMayUseCodex("codex"));
    try std.testing.expect(modelQueryMayUseCodex("codex future-sol"));
    try std.testing.expect(modelQueryMayUseCodex("future-account-rollout"));
    try std.testing.expect(modelQueryMayUseKimi(""));
    try std.testing.expect(!modelQueryMayUseKimi("codegraff"));
    try std.testing.expect(modelQueryMayUseKimi("kimi"));
    try std.testing.expect(modelQueryMayUseKimi("k3"));
    try std.testing.expect(!controlRequestMayUseCodex("codegraff", "deepseek-v4-pro", ""));
    try std.testing.expect(controlRequestMayUseCodex("codex", "", ""));
    try std.testing.expect(controlRequestMayUseCodex("", "future-account-rollout", ""));
    try std.testing.expect(!controlRequestMayUseCodex("", "", "openai"));
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
