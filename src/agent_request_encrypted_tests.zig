//! Backtest: latest Responses models use the existing encrypted-reasoning
//! path. Astra is not a special store — same `include` + `store:false` +
//! verbatim replay Codex uses. A new GPT-6 slug must not fall off this wire.

const std = @import("std");
const Kind = @import("provider.zig").Provider.Kind;
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;
const codegraff = @import("provider_codegraff.zig");

const Case = struct {
    id: []const u8,
    kind: Kind,
    model: []const u8,
};

const latest_responses = [_]Case{
    .{ .id = "codex", .kind = .responses, .model = "gpt-6-astra" },
    .{ .id = "codex", .kind = .responses, .model = "gpt-5.6-sol" },
    .{ .id = "codex", .kind = .responses, .model = "gpt-5.6-luna" },
    .{ .id = "openai", .kind = .responses, .model = "gpt-6-astra" },
    .{ .id = "openai", .kind = .responses, .model = "gpt-5.6-luna" },
    .{ .id = "codegraff", .kind = .responses, .model = "gpt-6-astra" },
    .{ .id = "codegraff", .kind = .responses, .model = "gpt-5.6-sol" },
};

fn withEncryptedHistory(arena: std.mem.Allocator, agent: anytype) !void {
    var item: std.json.ObjectMap = .empty;
    try item.put(arena, "type", .{ .string = "reasoning" });
    try item.put(arena, "id", .{ .string = "rs_astra" });
    try item.put(arena, "encrypted_content", .{ .string = "ENCBLOB" });
    try agent.messages.append(.{ .object = item });
}

test "latest Responses models request and replay encrypted reasoning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for (latest_responses) |case| {
        if (std.mem.eql(u8, case.id, "codegraff")) {
            try std.testing.expect(codegraff.usesResponses(case.id, case.model));
        }
        var agent = try testAgentFor(a, case.id, case.kind, case.model);
        try withEncryptedHistory(a, &agent);
        const body = try agent.buildBody(null, false, true, true);
        defer std.testing.allocator.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"include\":[\"reasoning.encrypted_content\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"encrypted_content\":\"ENCBLOB\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "previous_response_id") == null);
    }
}
