const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("extension_runtime.zig");
const Value = std.json.Value;

fn value(a: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}
test "native extensions require explicit trust and reject unknown versions/events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try runtime.parse(a, "{}")).len);
    try std.testing.expectEqual(@as(usize, 0), (try runtime.parse(a,
        \\{"runtime_plugins":[{"id":"ignored","command":["never-run"],"events":["ui"]}]}
    )).len);
    try std.testing.expectEqual(@as(usize, 0), (try runtime.parse(a,
        \\{"runtime_plugins":[{"id":"off","trusted":true,"enabled":false,"command":["never-run"],"events":["ui"]}]}
    )).len);
    const entries = try runtime.parse(a,
        \\{"runtime_plugins":[{"id":"example","trusted":true,"command":["example"],"events":["ui","before_request"]}]}
    );
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(runtime.handles(entries[0], "ui"));
    try std.testing.expect(!runtime.handles(entries[0], "action"));
    try std.testing.expectError(error.InvalidExtensionEvent, runtime.parse(a,
        \\{"runtime_plugins":[{"id":"example","trusted":true,"command":["example"],"events":["shell"]}]}
    ));
    try std.testing.expectError(error.InvalidExtensionConfig, runtime.parse(a,
        \\{"runtime_plugins":[{"id":"example","trusted":true,"command":[],"events":["ui"]}]}
    ));
}
test "native extension request transforms preserve identity and signed history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body = try value(a,
        \\{"model":"fixture","messages":[{"role":"assistant","content":"signed evidence"}],"max_tokens":1024,"tools":[{"name":"read_file"}]}
    );
    const evidence = try std.json.Stringify.valueAlloc(a, body.object.get("messages").?, .{});
    try std.testing.expect(try runtime.applyOptions(a, &body, try value(a, "{\"max_tokens\":128,\"temperature\":0.2}")));
    try std.testing.expectEqual(@as(i64, 128), body.object.get("max_tokens").?.integer);
    try std.testing.expectEqualStrings("fixture", body.object.get("model").?.string);
    try std.testing.expectEqualStrings(evidence, try std.json.Stringify.valueAlloc(a, body.object.get("messages").?, .{}));
    try std.testing.expectError(error.UnsupportedExtensionOption, runtime.applyOptions(a, &body, try value(a, "{\"model\":\"other\"}")));
    try std.testing.expectError(error.InvalidExtensionOptions, runtime.applyOptions(a, &body, try value(a, "{\"max_tokens\":2048}")));
    try std.testing.expectError(error.InvalidExtensionOptions, runtime.applyOptions(a, &body, try value(a, "{\"temperature\":99}")));
    try std.testing.expectError(error.UnsupportedExtensionOption, runtime.applyOptions(a, &body, try value(a, "{\"messages\":[]}")));
}
test "native extension panels accept bounded native controls and reject executable content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try runtime.validatePanel(try value(a,
        \\{"title":"Synthetic status","root":{"kind":"column","children":[{"kind":"stat","label":"Checks","value":"3"},{"kind":"button","label":"Refresh","action":"refresh"}]}}
    ));
    try std.testing.expectError(error.InvalidExtensionPanel, runtime.validatePanel(try value(a,
        \\{"title":"No scripts","root":{"kind":"html","text":"<script>run()</script>"}}
    )));
    try std.testing.expectError(error.InvalidExtensionPanel, runtime.validatePanel(try value(a,
        \\{"title":"No shell actions","root":{"kind":"button","label":"Bad","action":"sh -c unsafe"}}
    )));
}
test "native extension engine and Harness share panel validation vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vectors = try value(arena.allocator(), @embedFile("extension_panel_vectors.json"));
    for (vectors.object.get("cases").?.array.items) |case| {
        const expected = case.object.get("valid").?.bool;
        const actual = if (runtime.validateList(case.object.get("input").?)) |_| true else |_| false;
        try std.testing.expectEqual(expected, actual);
    }
}

test "native extension subprocess ABI is versioned and bounded" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plugin: runtime.Plugin = .{ .id = "fixture", .events = &.{"ui"}, .command = &.{
        "/usr/bin/python3",                                                                                                                                                                               "-c",
        "import json,sys; r=json.loads(sys.argv[-1]); assert r['version']==1 and r['event']=='ui'; print(json.dumps({'version':1,'panel':{'title':'Synthetic','root':{'kind':'text','text':'ready'}}}))",
    } };
    const response = try runtime.invoke(std.testing.io, a, plugin, "ui", .null);
    try runtime.validatePanel(response.object.get("panel").?);
    var malformed = plugin;
    malformed.command = &.{ "/usr/bin/python3", "-c", "print('{\"version\":2}')" };
    try std.testing.expectError(error.UnsupportedExtensionVersion, runtime.invoke(std.testing.io, a, malformed, "ui", .null));
    var slow = plugin;
    slow.timeout_ms = 20;
    slow.command = &.{ "/usr/bin/python3", "-c", "import time; time.sleep(5)" };
    try std.testing.expectError(error.ExtensionExecutionFailed, runtime.invoke(std.testing.io, a, slow, "ui", .null));
}
