//! Native Jev judgments are limited to GPT-6 on Codex/OpenAI and Xiaomi
//! MiMo, including those model ids served through the Codegraff gateway.
const std = @import("std");
const Provider = @import("provider.zig").Provider;

fn gptSix(model: []const u8) bool {
    return std.mem.eql(u8, model, "gpt-6") or
        std.mem.startsWith(u8, model, "gpt-6-") or
        std.mem.startsWith(u8, model, "gpt-6.");
}

pub fn eligible(provider: Provider) bool {
    const id = provider.id;
    if (std.mem.eql(u8, id, "codex") or std.mem.eql(u8, id, "openai")) return gptSix(provider.model);
    const mimo = std.mem.startsWith(u8, provider.model, "mimo-");
    if (std.mem.eql(u8, id, "xiaomi")) return mimo;
    return std.mem.eql(u8, id, "codegraff") and (mimo or gptSix(provider.model));
}

test "native Jev eligibility requires GPT-6 on Codex/OpenAI or Xiaomi MiMo" {
    const base: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    var p = base;
    for ([_][]const u8{ "codex", "openai" }) |id| {
        p.id = id;
        for ([_][]const u8{ "gpt-6", "gpt-6-sol", "gpt-6.1", "gpt-6.1-mini" }) |model| {
            p.model = model;
            try std.testing.expect(eligible(p));
        }
        for ([_][]const u8{ "gpt-5.6", "gpt-60", "gpt-6x", "o3", "mimo-v2.6-pro" }) |model| {
            p.model = model;
            try std.testing.expect(!eligible(p));
        }
    }
    p.id = "xiaomi";
    p.model = "mimo-v2.6-pro";
    try std.testing.expect(eligible(p));
    p.model = "not-mimo";
    try std.testing.expect(!eligible(p));
    p.id = "codegraff";
    for ([_][]const u8{ "mimo-v2.6-flash", "gpt-6-sol" }) |model| {
        p.model = model;
        try std.testing.expect(eligible(p));
    }
    for ([_][]const u8{ "gpt-5.6", "gpt-60", "o3", "claude-opus-4.8", "gemini-3.8-flash" }) |model| {
        p.model = model;
        try std.testing.expect(!eligible(p));
    }
    p.id = "openrouter";
    p.model = "openai/gpt-6-sol";
    try std.testing.expect(!eligible(p));
}
