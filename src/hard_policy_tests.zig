const std = @import("std");
const policy = @import("hard_policy.zig");
const io = std.testing.io;

const deny_shell =
    \\{"policies":[{"action":"tool.use","resource":"shell","effect":"deny"}]}
;

fn save(dir: std.Io.Dir, text: []const u8) !void {
    try dir.createDirPath(io, ".harness");
    try dir.writeFile(io, .{ .sub_path = policy.settings_path, .data = text });
}

test "hard policy ordered allow and deny use last full wildcard match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = policy.parse(a,
        \\{"policies":[{"action":"tool.use","resource":"*","effect":"deny"},{"action":"tool.use","resource":"read_*","effect":"allow"},{"action":"tool.use","resource":"read_secret","effect":"deny"},{"action":"provider.use","resource":"fixture*","effect":"deny"}]}
    );
    try std.testing.expect(doc.problem == null);
    try std.testing.expect(doc.allows("tool.use", "read_file"));
    try std.testing.expect(!doc.allows("tool.use", "read_secret"));
    try std.testing.expect(!doc.allows("tool.use", "shell"));
    try std.testing.expect(!doc.allows("provider.use", "fixture-fallback"));
    try std.testing.expect(doc.allows("skill.use", "anything"));
    const reason = doc.denial(a, "tool.use", "read_secret").?;
    try std.testing.expect(std.mem.indexOf(u8, reason, "policies[2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, reason, "operator") != null);
    try std.testing.expect(policy.matches("a*b*c", "abzzzbc"));
    try std.testing.expect(policy.matches("*", ""));
    try std.testing.expect(policy.matches("abc**", "abc"));
    try std.testing.expect(!policy.matches("abc", "abcdef"));
    try std.testing.expect(!policy.matches("a?c", "abc"));
    try std.testing.expect(!policy.matches("*read", "read_file"));
}

test "hard policy malformed configured rules fail closed even after an allow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{",                                                                                                                                                            "[]",                                                                                              "null",                                                                             "{\"policies\":null}",                                                           "{\"policies\":{}}",
        "{\"policies\":[1]}",                                                                                                                                           "{\"policies\":[{\"action\":\"tools.use\",\"resource\":\"*\",\"effect\":\"deny\"}]}",              "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"\",\"effect\":\"deny\"}]}", "{\"policies\":[{\"action\":\"tool.use\",\"resource\":5,\"effect\":\"deny\"}]}", "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"*\",\"effect\":\"ask\"}]}",
        "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"*\",\"effect\":\"allow\"},{\"action\":\"provider.use\",\"resource\":\"unrelated\",\"effect\":false}]}", "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"*\",\"effect\":\"deny\",\"typo\":true}]}", "{\"policies\":[],\"policies\":[{}]}",
    }) |text| {
        const doc = policy.parse(a, text);
        try std.testing.expect(doc.problem != null);
        try std.testing.expect(!doc.allows("tool.use", "read_file"));
        try std.testing.expect(!doc.allows("provider.use", "fixture"));
        try std.testing.expect(std.mem.indexOf(u8, doc.denial(a, "provider.use", "fixture").?, ".harness/settings.json") != null);
    }
}

test "hard policy missing and empty config preserve defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(policy.checkAt(io, a, tmp.dir, "tool.use", "shell") == null);
    for ([_][]const u8{ "{}", "{\"policies\":[]}", "{\"skills\":{\"fixture\":false}}" }) |text| {
        try save(tmp.dir, text);
        try std.testing.expect(policy.checkAt(io, a, tmp.dir, "provider.use", "fixture") == null);
        try std.testing.expect(policy.checkAt(io, a, tmp.dir, "tool.use", "shell") == null);
    }
}

test "hard policy workspace identity edits replacement and removal never reuse trust" {
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try save(first.dir, deny_shell);
    try save(second.dir, "{\"policies\":[]}");
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "shell") != null);
    try std.testing.expect(policy.checkAt(io, a, second.dir, "tool.use", "shell") == null);
    // Same-size content change, then atomic replacement: no timestamp/size cache.
    try save(first.dir, "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"shell\",\"effect\":\"allow\"}]}");
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "shell") == null);
    try first.dir.writeFile(io, .{ .sub_path = ".harness/new.json", .data = deny_shell });
    try first.dir.rename(".harness/new.json", first.dir, policy.settings_path, io);
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "shell") != null);
    try save(first.dir, "{\"policies\":[");
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "read_file") != null);
    try first.dir.deleteFile(io, policy.settings_path);
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "shell") == null);
}

test "hard policy unreadable settings are not treated as absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, policy.settings_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reason = policy.checkAt(io, arena.allocator(), tmp.dir, "provider.use", "fixture").?;
    try std.testing.expect(std.mem.indexOf(u8, reason, "cannot read") != null);
}
