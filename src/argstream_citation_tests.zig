//! Regression at the live argument-to-terminal boundary, not only dupe().
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main = @import("main.zig");

test "#819 completion citations survive no stream boundary into displayed or captured text" {
    const saved_json = main.json_mode;
    const saved_color = main.use_color;
    main.json_mode = false;
    main.use_color = false;
    defer {
        main.json_mode = saved_json;
        main.use_color = saved_color;
    }
    const fixtures = [_][]const u8{
        "{\"result\":\"See \\ue200cite\\ue202turn0search0\\ue202turn1search2\\ue201docs café.\"}",
        "{\"result\":\"See \u{E200}cite\u{E202}turn0search0\u{E202}turn1search2\u{E201}docs café.\"}",
    };
    for (fixtures) |json| {
        // Exercise every split, including the two bytes inside a UTF-8 marker.
        for (0..json.len + 1) |split| {
            var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            var a: Agent = .{ .gpa = std.testing.allocator, .arena = std.testing.allocator, .io = std.testing.io, .client = undefined, .provider = undefined, .messages = undefined, .sub = false, .label = "test", .out = &aw.writer };
            defer a.partial_text.deinit(std.testing.allocator);
            a.arg_live.open("attempt_completion", 0);
            a.arg_live.feed(&a, 0, json[0..split]);
            a.arg_live.feed(&a, 0, json[split..]);
            try std.testing.expectEqualStrings("See docs café.", aw.writer.buffered());
            try std.testing.expectEqualStrings("See docs café.", a.partial_text.items);
            const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
            defer parsed.deinit();
            try std.testing.expect(a.argStreamedFully(.{ .id = "1", .name = "attempt_completion", .input = parsed.value }));
        }
    }
}
