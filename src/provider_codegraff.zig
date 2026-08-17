//! Model-specific wire contract for the Codegraff gateway.

const std = @import("std");

pub const responses_url = "https://gateway.codegraff.com/v1/responses";

/// The gateway exposes every alias on Chat Completions, but only native OpenAI
/// and xAI aliases on Responses. Keep this allowlist aligned with the public
/// gateway contract so Claude and Gemini never reach their rejected route.
pub fn usesResponses(provider_id: []const u8, model: []const u8) bool {
    if (!std.mem.eql(u8, provider_id, "codegraff")) return false;
    return std.mem.eql(u8, model, "gpt-5.6") or
        std.mem.eql(u8, model, "gpt-5.6-sol") or
        std.mem.eql(u8, model, "gpt-5.6-terra") or
        std.mem.eql(u8, model, "gpt-5.6-luna") or
        std.mem.eql(u8, model, "grok-4.6");
}

test "Codegraff Responses allowlist matches the public gateway contract" {
    for ([_][]const u8{ "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "grok-4.6" }) |model|
        try std.testing.expect(usesResponses("codegraff", model));

    for ([_][]const u8{ "gpt-5.5", "grok-4.3", "claude-opus-4.8", "gemini-3.7-flash" }) |model|
        try std.testing.expect(!usesResponses("codegraff", model));
    try std.testing.expect(!usesResponses("openai", "gpt-5.6"));
}
