//! Regression for same-wire and cross-wire provider switches changing Jev visibility.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const providers = @import("providers.zig");
const jev_tool = @import("jev_tool.zig");

test "native Jev catalog refreshes on eligible and ineligible model switches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };

    var root: Agent = undefined;
    root.provider = p;
    root.subagent_provider = null;
    root.subagent_provider_explicit = true;
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

    const mock = struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "JEV_BACKEND")) "mock" else null;
        }
    }{};
    jev_tool.configure(mock);
    defer jev_tool.configure(struct {
        pub fn get(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    }{});
    _ = jev_tool.setCodegraffLogin(true);

    var gpt6 = p;
    gpt6.model = "gpt-6-sol";
    _ = try providers.applyProviderInner(&root, a, gpt6, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_responses, jev_tool.name) != null);
    _ = try providers.applyProviderInner(&root, a, p, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_responses, jev_tool.name) == null);

    var mimo = p;
    mimo.id = "codegraff";
    mimo.kind = .openai;
    mimo.model = "mimo-v2.6-pro";
    _ = try providers.applyProviderInner(&root, a, mimo, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, jev_tool.name) != null);
    var deepseek = mimo;
    deepseek.id = "deepseek";
    deepseek.model = "deepseek-chat";
    _ = try providers.applyProviderInner(&root, a, deepseek, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, jev_tool.name) == null);
    _ = try providers.applyProviderInner(&root, a, gpt6, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_responses, jev_tool.name) != null);
    // The OpenAI-format slot was cached above without Jev. Switching from
    // one eligible provider to another must rebuild that older slot.
    const eligible_openai = mimo;
    _ = try providers.applyProviderInner(&root, a, eligible_openai, false);
    try std.testing.expect(std.mem.indexOf(u8, root.tools_openai, jev_tool.name) != null);

    jev_tool.configure(struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "JEV_BACKEND")) "mock-fail" else null;
        }
    }{});
    _ = jev_tool.setCodegraffLogin(true);
    const old_catalog = root.toolsJson();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"state\":\"10 tests passed\",\"question\":\"Did CI pass?\",\"type\":\"noul\"}", .{});
    var client: std.http.Client = undefined;
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = &client, .provider = eligible_openai, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const failed = try jev_tool.execute(ctx, input);
    defer std.testing.allocator.free(failed.text);
    const next_catalog = (try jev_tool.refreshCatalogForRequest(&root, old_catalog)).?;
    try std.testing.expect(std.mem.indexOf(u8, next_catalog, jev_tool.name) == null);
    try std.testing.expect(std.mem.indexOf(u8, old_catalog, jev_tool.name) != null);
}
