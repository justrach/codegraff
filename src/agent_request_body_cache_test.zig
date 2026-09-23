const std = @import("std");
const bodies = @import("agent_request_body_responses.zig");

test "GPT-5.6 and later Platform marks the stable prefix; Codex and older routes do not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var oai = try bodies.testAgentFor(a, "openai", .responses, "gpt-5.6");
    const ob = try oai.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ob);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_key\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"role\":\"developer\",\"content\":[{\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ob, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);

    var astra = try bodies.testAgentFor(a, "openai", .responses, "gpt-6-astra");
    const ast = try astra.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ast);
    try std.testing.expect(std.mem.indexOf(u8, ast, "\"prompt_cache_options\":{\"mode\":\"implicit\",\"ttl\":\"30m\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, ast, "\"prompt_cache_breakpoint\":{\"mode\":\"explicit\"}") != null);

    var worker = try bodies.testAgentFor(a, "openai", .responses, "gpt-5.6-luna");
    worker.sub = true;
    worker.label = "implement";
    const wb = try worker.buildBody(null, false, true, true);
    defer std.testing.allocator.free(wb);
    try std.testing.expect(std.mem.indexOf(u8, wb, "\"prompt_cache_options\":{\"mode\":\"explicit\",\"ttl\":\"30m\"}") != null);

    var codex = try bodies.testAgentFor(a, "codex", .responses, "gpt-5.6-sol");
    const cb = try codex.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, cb, "prompt_cache_breakpoint") == null);

    var astra_codex = try bodies.testAgentFor(a, "codex", .responses, "gpt-6-astra");
    const ac = try astra_codex.buildBody(null, false, true, true);
    defer std.testing.allocator.free(ac);
    try std.testing.expect(std.mem.indexOf(u8, ac, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, ac, "prompt_cache_breakpoint") == null);

    var older = try bodies.testAgentFor(a, "openai", .responses, "gpt-5.5");
    const old = try older.buildBody(null, false, true, true);
    defer std.testing.allocator.free(old);
    try std.testing.expect(std.mem.indexOf(u8, old, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, old, "prompt_cache_options") == null);
}
