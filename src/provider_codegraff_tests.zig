const std = @import("std");
const provider = @import("provider.zig");

fn build(model: []const u8) provider.Provider {
    const keys: provider.Keys = .{ .values = @splat(null) };
    return keys.build(provider.specFor("codegraff").?, "key", model);
}

test "Codegraff selects the gateway wire and endpoint per model" {
    for ([_][]const u8{ "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "grok-4.6" }) |model| {
        const got = build(model);
        try std.testing.expectEqual(provider.Provider.Kind.responses, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", got.url);
    }

    for ([_][]const u8{ "deepseek-v4-pro", "claude-opus-4.8", "gemini-3.7-flash" }) |model| {
        const got = build(model);
        try std.testing.expectEqual(provider.Provider.Kind.openai, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/chat/completions", got.url);
    }
}

test "Codegraff-only credentials route native aliases without live discovery" {
    var keys: provider.Keys = .{ .values = @splat(null) };
    try std.testing.expect(keys.set("codegraff", "key", .environment));
    for ([_][]const u8{ "gpt-5.6", "grok-4.6" }) |model| {
        const got = try keys.providerFor(model);
        try std.testing.expectEqualStrings("codegraff", got.id);
        try std.testing.expectEqual(provider.Provider.Kind.responses, got.kind);
        try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", got.url);
    }
}

test "Codegraff model switches rebuild both wire and endpoint" {
    const chat = build("gemini-3.7-flash");
    const responses = chat.withModel("grok-4.6");
    try std.testing.expectEqual(provider.Provider.Kind.responses, responses.kind);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/responses", responses.url);

    const back_to_chat = responses.withModel("claude-opus-4.8");
    try std.testing.expectEqual(provider.Provider.Kind.openai, back_to_chat.kind);
    try std.testing.expectEqualStrings("https://gateway.codegraff.com/v1/chat/completions", back_to_chat.url);
}
