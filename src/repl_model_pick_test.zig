//! Provider-aware model switching (#560).
//!
//! The reported bug: the TUI picker showed bare model names, so a model served
//! by codex (a ChatGPT plan), codegraff (gateway credits) and openai (a metered
//! key) drew three identical rows — and picking one sent only the NAME to the
//! engine, which re-resolved the provider by router preference. Choosing the
//! openai row could land on codex. These tests pin the engine half of the fix.

const std = @import("std");
const provider_mod = @import("provider.zig");
const repl_glue = @import("repl_glue.zig");
const Keys = provider_mod.Keys;

/// A ReplCtx with nothing wired but the credentials — enough for a model
/// switch, which touches keys and provider and nothing else. `home` is empty,
/// which `serde.saveModel` documents as a no-op, so no test writes to disk.
fn switchCtx(client: *std.http.Client, keys: Keys) repl_glue.ReplCtx {
    return .{
        .io = std.testing.io,
        .client = client,
        .keys = keys,
        .home = "",
        .provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "start", .context = 0 },
        .fallback_allow = &.{},
        .fallback_active = true,
        .fallback_blocked = true,
        .registry = null,
        .tracer = null,
        .run_budget = null,
        .sys_normal = "",
        .tools_anthropic = "",
        .tools_openai = "",
        .tools_responses = "",
    };
}

fn keyedFor(ids: []const []const u8) Keys {
    var keys: Keys = .{ .values = @splat(null) };
    for (ids) |id| _ = keys.set(id, "test-key", .stored);
    return keys;
}

test "replModelPick honours the provider the row named (#560)" {
    // gpt-5.5 really is served by codex, openai AND codegraff, which is the
    // shape the user hit: three identical-looking rows, wildly different bills.
    var client: std.http.Client = undefined;
    var keys = keyedFor(&.{ "codex", "openai", "codegraff" });
    keys.codex_account = "acct";
    var ctx = switchCtx(&client, keys);
    const picked = repl_glue.replModelPick(&ctx, std.testing.allocator, "openai", "gpt-5.5") orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(picked.model);
    try std.testing.expectEqualStrings("openai", picked.provider);
    try std.testing.expectEqualStrings("openai", ctx.provider.id);
    try std.testing.expectEqualStrings("gpt-5.5", ctx.provider.model);
    // An explicit choice also clears a temporary failover.
    try std.testing.expect(!ctx.fallback_active);
    try std.testing.expect(!ctx.fallback_blocked);

    // The SAME name asked for on codex lands on codex — routed, not rewritten.
    var ctx2 = switchCtx(&client, keys);
    const codex = repl_glue.replModelPick(&ctx2, std.testing.allocator, "codex", "gpt-5.5") orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(codex.model);
    try std.testing.expectEqualStrings("codex", codex.provider);
    try std.testing.expectEqualStrings("codex", ctx2.provider.id);
}

test "a name with no provider still routes by name, as /model always did" {
    var client: std.http.Client = undefined;
    const keys = keyedFor(&.{"openai"});
    var ctx = switchCtx(&client, keys);
    const picked = repl_glue.replModelPick(&ctx, std.testing.allocator, "", "gpt-5.5") orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(picked.model);
    try std.testing.expectEqualStrings("openai", picked.provider);

    // A named provider with no credential FAILS the switch rather than quietly
    // sending the turn somewhere the user did not choose.
    var ctx2 = switchCtx(&client, keys);
    try std.testing.expect(repl_glue.replModelPick(&ctx2, std.testing.allocator, "anthropic", "claude-opus-4-8") == null);
    try std.testing.expectEqualStrings("codegraff", ctx2.provider.id);
    try std.testing.expectEqualStrings("start", ctx2.provider.model);
}

test "an off-catalog model on a named provider is copied, not borrowed" {
    // LM Studio serves whatever is loaded, so those ids are in no table. The
    // switch must still work and the copy must be the caller's to free.
    var client: std.http.Client = undefined;
    const keys = keyedFor(&.{"lmstudio"});
    var ctx = switchCtx(&client, keys);
    var name_buf: [16]u8 = undefined;
    const name = name_buf[0.."local/thing".len];
    @memcpy(name, "local/thing");
    const picked = repl_glue.replModelPick(&ctx, std.testing.allocator, "lmstudio", name) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(picked.model);
    try std.testing.expectEqualStrings("lmstudio", ctx.provider.id);
    try std.testing.expectEqualStrings("local/thing", ctx.provider.model);
    // It is a COPY: scribbling on the caller's buffer must not move the seat.
    @memcpy(name, "scribbled!!");
    try std.testing.expectEqualStrings("local/thing", ctx.provider.model);
    std.testing.allocator.free(ctx.provider.model);
}
