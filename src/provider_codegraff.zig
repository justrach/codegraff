//! Model-specific wire contract for the Codegraff gateway.

const std = @import("std");

pub const responses_url = "https://gateway.codegraff.com/v1/responses";

/// The gateway exposes every alias on Chat Completions, but only native OpenAI
/// and xAI aliases on Responses. Claude and Gemini return 400 there — keep
/// those on Chat Completions. OpenAI GPT-5.6+ (including Codex `gpt-5.6-*`
/// and GPT-6 `gpt-6-astra`) and grok-4.6 are the native set.
pub fn usesResponses(provider_id: []const u8, model: []const u8) bool {
    if (!std.mem.eql(u8, provider_id, "codegraff")) return false;
    if (openaiGptFamily(model)) return true;
    return std.mem.eql(u8, model, "grok-4.6");
}

/// GPT-5.6 and every later GPT generation, including Codex suffixes
/// (`gpt-5.6-sol`) and GPT-6 names (`gpt-6-astra`). Earlier GPT aliases
/// (`gpt-5.5`, `gpt-4o`, `gpt-oss-*`) stay on Chat Completions.
pub fn openaiGptFamily(model: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, model, "gpt-")) model["gpt-".len..] else return false;
    if (rest.len == 0) return false;
    if (std.mem.startsWith(u8, rest, "5.")) {
        const after = rest["5.".len..];
        var i: usize = 0;
        while (i < after.len and after[i] >= '0' and after[i] <= '9') i += 1;
        if (i == 0) return false;
        const minor = std.fmt.parseInt(u32, after[0..i], 10) catch return false;
        return minor >= 6;
    }
    var i: usize = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') i += 1;
    if (i == 0) return false;
    const major = std.fmt.parseInt(u32, rest[0..i], 10) catch return false;
    return major >= 6;
}

test "Codegraff Responses allowlist matches the public gateway contract" {
    for ([_][]const u8{ "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra", "gpt-6.5", "grok-4.6" }) |model|
        try std.testing.expect(usesResponses("codegraff", model));

    for ([_][]const u8{ "gpt-5.5", "gpt-4o", "gpt-oss-120b", "grok-4.3", "claude-opus-4.8", "gemini-3.7-flash", "glm-5.3-flash" }) |model|
        try std.testing.expect(!usesResponses("codegraff", model));
    try std.testing.expect(!usesResponses("openai", "gpt-5.6"));
    try std.testing.expect(!usesResponses("openai", "gpt-6-astra"));
}
