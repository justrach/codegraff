const std = @import("std");
const Value = std.json.Value;

const providers = @import("providers.zig");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const Keys = provider_mod.Keys;
const Provider = provider_mod.Provider;

const applyProviderInner = providers.applyProviderInner;
const resolveProviderControlRequest = providers.resolveProviderControlRequest;
const modelQueryMayUseCodex = providers.modelQueryMayUseCodex;
const modelQueryMayUseKimi = providers.modelQueryMayUseKimi;
const controlRequestMayUseCodex = providers.controlRequestMayUseCodex;
const extractText = providers.extractText;

test "applyProviderInner preserves the server meter on an exact model re-selection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    var root: Agent = undefined;
    root.io = std.testing.io;
    root.jev_effort_pending = .{};
    root.provider = p;
    root.subagent_provider = null;
    root.subagent_provider_explicit = true; // this test is about the meter, not #371 re-derivation
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
    root.sox_json_object = true;
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
    try std.testing.expect(root.sox_json_object);
    try std.testing.expect(root.effort_rejected);
    try std.testing.expect(root.ws_off);

    var changed = p;
    changed.model = "gpt-5.1";
    _ = try applyProviderInner(&root, a, changed, false);
    try std.testing.expectEqual(root.fullRequestEstimateTokens(), root.last_context_tokens);
    try std.testing.expectEqual(root.last_context_tokens, root.context_local_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);
    try std.testing.expect(!root.cap_new);
    try std.testing.expect(!root.sox_json_object); // #543: relearned per provider
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
