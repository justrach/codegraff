//! OpenAI follow-up delivery mode (direct, Codex/ChatGPT, and Codegraff).
//!
//! A prompt sent while one of these turns is live is steered into that turn
//! immediately by default. `/followups queue` restores the older behavior of
//! holding it for the next turn. The choice persists in the harness's own
//! `.harness/settings.json`; other models and providers are unaffected.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Provider = @import("provider.zig").Provider;

pub const path = ".harness/settings.json";
pub const field = "followups";
pub const immediate_value = "immediate";
pub const queue_value = "queue";

/// True only when the persisted setting asks for the old queueing behavior.
pub var queue: bool = false;

pub fn applies(p: Provider) bool {
    if (std.mem.eql(u8, p.id, "codex") or std.mem.eql(u8, p.id, "chatgpt-new") or std.mem.eql(u8, p.id, "openai")) return true;
    // The gateway serves several labs on the same wire. Match the model's
    // maker, not `.responses` (Grok uses it too) or `.openai` (chat format).
    if (!std.mem.eql(u8, p.id, "codegraff")) return false;
    const maker = @import("model_maker.zig").of(p.id, p.model) orelse return false;
    return std.mem.eql(u8, maker, "openai");
}

/// Should a plain follow-up sent during this provider's live turn be steered
/// into it now instead of waiting for the next turn?
pub fn steersNow(p: Provider) bool {
    return applies(p) and !queue;
}

fn modeFromObject(obj: std.json.ObjectMap) bool {
    const v = obj.get(field) orelse return false;
    return v == .string and std.mem.eql(u8, v.string, queue_value);
}

pub fn load(io: Io, arena: Allocator) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch return;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return;
    if (v != .object) return;
    queue = modeFromObject(v.object);
}

/// Merge the one preference into the existing settings object and replace the
/// file atomically. Unknown fields, including approvals, are preserved.
pub fn save(io: Io, arena: Allocator, queue_mode: bool) !void {
    const existing = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch "{}";
    var obj: std.json.ObjectMap = .empty;
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{})) |v| {
        if (v == .object) obj = v.object;
    } else |_| {}
    try obj.put(arena, field, .{ .string = if (queue_mode) queue_value else immediate_value });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(std.json.Value{ .object = obj });
    aw.writer.writeByte('\n') catch {};
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try @import("credential_store.zig").replaceFile(io, Io.Dir.cwd(), path, aw.writer.buffered(), .default_file);
    queue = queue_mode;
}

fn testProvider(id: []const u8, model: []const u8) Provider {
    const providers = @import("provider.zig");
    const keys: providers.Keys = .{ .values = @splat(null) };
    return keys.build(providers.specFor(id).?, "fixture", model);
}

test "follow-up mode is immediate for direct OpenAI and Codex ChatGPT" {
    const saved = queue;
    defer queue = saved;
    queue = false;
    for ([_][]const u8{ "openai", "codex", "chatgpt-new" }) |id| {
        try std.testing.expect(steersNow(testProvider(id, "gpt-6-astra")));
        try std.testing.expect(steersNow(testProvider(id, "o3-mini")));
    }
}

test "follow-up mode recognizes OpenAI models on Codegraff independent of wire" {
    const saved = queue;
    defer queue = saved;
    queue = false;
    for ([_][]const u8{ "gpt-6-astra", "gpt-6.1-sol", "gpt-5.6-sol", "gpt-4o", "o1", "o3-mini", "o4-mini", "codex-mini", "openai/gpt-6-sol" }) |model|
        try std.testing.expect(steersNow(testProvider("codegraff", model)));
    try std.testing.expectEqual(Provider.Kind.openai, testProvider("codegraff", "gpt-4o").kind);
}

test "follow-up mode leaves other Codegraff models unchanged including Responses Grok" {
    const saved = queue;
    defer queue = saved;
    queue = false;
    for ([_][]const u8{ "claude-opus-5-5", "grok-4.6", "gemini-3.8-flash", "mimo-v2.6-pro", "deepseek-v4-pro", "kimi-k3", "glm-5.3", "unknown-model", "anthropic/claude-sonnet-5", "someco/o30x" }) |model|
        try std.testing.expect(!steersNow(testProvider("codegraff", model)));
    try std.testing.expectEqual(Provider.Kind.responses, testProvider("codegraff", "grok-4.6").kind);
}

test "follow-up mode does not opt other routes into immediate delivery" {
    const saved = queue;
    defer queue = saved;
    queue = false;
    for ([_][]const u8{ "anthropic", "xai", "openrouter", "groq", "lmstudio" }) |id|
        try std.testing.expect(!steersNow(testProvider(id, "gpt-6-sol")));
}

test "follow-up mode queue rollback covers every OpenAI route and is reversible" {
    const saved = queue;
    defer queue = saved;
    for ([_][]const u8{ "openai", "codex", "chatgpt-new", "codegraff" }) |id| {
        const p = testProvider(id, "gpt-6-sol");
        queue = false;
        try std.testing.expect(steersNow(p));
        queue = true;
        try std.testing.expect(applies(p));
        try std.testing.expect(!steersNow(p));
        queue = false;
        try std.testing.expect(steersNow(p));
    }
}

test "follow-up mode follows Codegraff model switches without leaking to other labs" {
    const saved = queue;
    defer queue = saved;
    queue = false;
    var p = testProvider("codegraff", "gpt-6-astra");
    try std.testing.expect(steersNow(p));
    p = p.withModel("claude-opus-5-5");
    try std.testing.expect(!steersNow(p));
    p = p.withModel("grok-4.6");
    try std.testing.expect(!steersNow(p));
    p = p.withModel("gpt-6.1-sol");
    try std.testing.expect(steersNow(p));
}

test "settings mode parses explicit queue and defaults to immediate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const queued = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"followups\":\"queue\"}", .{});
    const immediate = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"followups\":\"immediate\"}", .{});
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try std.testing.expect(modeFromObject(queued.object));
    try std.testing.expect(!modeFromObject(immediate.object));
    try std.testing.expect(!modeFromObject(missing.object));
}
