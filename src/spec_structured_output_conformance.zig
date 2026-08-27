//! Impl half of StructuredOutput (#543): the fixture's 24 cells drive the REAL
//! buildBody, and the carrier is classified from the produced request bytes —
//! wire format × schema × sox × tools. The never-silent invariant is thereby
//! checked against what actually goes on the wire, not a mirrored function.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;

const fixtures_json = @embedFile("spec_structured_output");

const test_schema = "{\"type\":\"object\",\"properties\":{\"answer\":{\"type\":\"string\"}},\"required\":[\"answer\"]}";

fn agentFor(arena: std.mem.Allocator, wire: []const u8) !Agent {
    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "hello" });
    try messages.append(.{ .object = user });
    const kind: @import("provider.zig").Provider.Kind =
        if (std.mem.eql(u8, wire, "anthropic")) .anthropic else if (std.mem.eql(u8, wire, "openai")) .openai else .responses;
    const id: []const u8 = switch (kind) {
        .anthropic => "anthropic",
        .openai => "deepseek",
        .responses => "xai",
    };
    const model: []const u8 = switch (kind) {
        .anthropic => "claude-sonnet-5",
        .openai => "deepseek-v4-flash",
        .responses => "grok-4.6",
    };
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = id, .kind = kind, .auth = .bearer, .url = "", .api_key = "k", .model = model, .context = 500_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .sys_normal = "system",
    };
}

fn toolsFor(wire: []const u8) []const u8 {
    if (std.mem.eql(u8, wire, "anthropic"))
        return "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";
    if (std.mem.eql(u8, wire, "openai"))
        return "[{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"\",\"parameters\":{\"type\":\"object\"}}}]";
    return "[{\"type\":\"function\",\"name\":\"bash\",\"description\":\"\",\"parameters\":{},\"strict\":false}]";
}

fn classify(body: []const u8, wire: []const u8) []const u8 {
    if (std.mem.indexOf(u8, body, "\"text\":{\"format\":{\"type\":\"json_schema\"") != null) return "textFormat";
    if (std.mem.indexOf(u8, body, "\"format\":{\"type\":\"json_schema\"") != null and
        std.mem.indexOf(u8, body, "\"output_config\"") != null) return "outputConfig";
    if (std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"json_schema\"") != null) return "jsonSchema";
    if (std.mem.indexOf(u8, body, "\"response_format\":{\"type\":\"json_object\"}") != null) return "jsonObject";
    if (std.mem.indexOf(u8, body, "\"name\":\"structured_output\"") != null)
        return if (std.mem.eql(u8, wire, "anthropic")) "toolAnthropic" else "toolOpenai";
    return "none";
}

test "spec/structured_output: buildBody's carrier matches the model on every cell" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cells = parsed.value.object.get("cells").?.array.items;
    try std.testing.expectEqual(@as(usize, 24), cells.len);
    for (cells) |cell_v| {
        const cell = cell_v.object;
        const wire = cell.get("wire").?.string;
        const schema = cell.get("schema").?.bool;
        const sox = cell.get("sox").?.bool;
        const tools = cell.get("tools").?.bool;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var agent = try agentFor(arena_state.allocator(), wire);
        if (schema) agent.output_schema = test_schema;
        agent.sox_json_object = sox;
        const body = try agent.buildBody(if (tools) toolsFor(wire) else null, false, true, true);
        defer gpa.free(body);
        const got = classify(body, wire);
        const want = cell.get("carrier").?.string;
        const prompt_want = cell.get("prompt_schema").?.bool;
        const prompt_got = std.mem.indexOf(u8, body, "cannot enforce the schema server-side") != null;
        if (!std.mem.eql(u8, got, want) or prompt_got != prompt_want) {
            std.debug.print(
                "\ncounterexample wire={s} schema={} sox={} tools={}: carrier {s}/{s} prompt {}/{}\n",
                .{ wire, schema, sox, tools, want, got, prompt_want, prompt_got },
            );
            return error.CatalogMismatch;
        }
        // never_silent: a set schema reaches the wire, except an anthropic
        // tools turn (ADR 0001 — the two-phase split holds it for formatting).
        if (schema and std.mem.eql(u8, got, "none") and !prompt_got) {
            if (!(std.mem.eql(u8, wire, "anthropic") and tools)) return error.SchemaSilentlyDropped;
        }
    }
}
