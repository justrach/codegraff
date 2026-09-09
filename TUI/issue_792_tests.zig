//! #792: pasted items need separators and paste-origin file paths need identity.

const std = @import("std");
const Term = @import("sim.zig").Term;

fn paste(term: *Term, text: []const u8) void {
    _ = term.feed("\x1b[200~");
    _ = term.feed(text);
    _ = term.feed("\x1b[201~");
}

fn writeTmp(tmp: anytype, name: []const u8, buf: []u8) ![]const u8 {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "file" });
    const n = try tmp.dir.realPath(io, buf);
    if (n + 1 + name.len > buf.len) return error.NameTooLong;
    buf[n] = '/';
    @memcpy(buf[n + 1 ..][0..name.len], name);
    return buf[0 .. n + 1 + name.len];
}

test "#792 bracketed text paste leaves one trailing separator" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, "hello");
    try std.testing.expectEqualStrings("hello ", term.model.input.getValue());
}

test "#792 existing trailing whitespace is not duplicated" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, "hello ");
    try std.testing.expectEqualStrings("hello ", term.model.input.getValue());
}

test "#792 consecutive pasted or dropped file paths stay separated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var one_buf: [std.fs.max_path_bytes]u8 = undefined;
    var two_buf: [std.fs.max_path_bytes]u8 = undefined;
    const one = try writeTmp(&tmp, "one file.txt", &one_buf);
    const two = try writeTmp(&tmp, "two file.txt", &two_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, one);
    paste(&term, two);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} {s} ", .{ one, two });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, term.model.input.getValue());
}

test "#792 backspace removes a paste-origin file path as one item" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "one file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, path);
    _ = term.feed("\x7f"); // remove the separator
    _ = term.feed("\x7f"); // remove the pasted path as one item
    try std.testing.expectEqualStrings("", term.model.input.getValue());
}

test "#792 delete removes a paste-origin file path at its leading edge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "one file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, path);
    _ = term.feed("\x1b[H"); // home
    _ = term.feed("\x1b[3~"); // delete at the span's leading edge
    try std.testing.expectEqualStrings(" ", term.model.input.getValue());
}

test "#792 word movement skips a paste-origin file path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "one file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, path);
    _ = term.feed("\x1bb"); // word-left from after the separator
    try std.testing.expectEqual(@as(usize, 0), term.model.input.cursor);
}

test "#792 manually typed path remains ordinary character-editable text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "one file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    _ = term.typeText(path);
    _ = term.feed("\x1bb"); // word-left stops at the path's internal space
    const boundary = std.mem.indexOfScalar(u8, path, ' ').? + 1;
    try std.testing.expectEqual(boundary, term.model.input.cursor);
    _ = term.feed("\x7f");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}file.txt", .{path[0 .. boundary - 1]});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, term.model.input.getValue());
}

test "#792 typing after a paste uses the removable separator" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, "hello");
    _ = term.typeText("world");
    try std.testing.expectEqualStrings("hello world", term.model.input.getValue());
}

test "#792 existing whitespace to the right is not duplicated" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    try term.model.input.setValue(" right");
    _ = term.press(.home);
    paste(&term, "hello");
    try std.testing.expectEqualStrings("hello right", term.model.input.getValue());
}

test "#792 file URL paste normalizes and highlights only the semantic span" {
    const theme = @import("theme.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "one file.txt", &path_buf);
    const space = std.mem.indexOfScalar(u8, path, ' ').?;
    const url = try std.fmt.allocPrint(std.testing.allocator, "file://{s}%20{s}", .{ path[0..space], path[space + 1 ..] });
    defer std.testing.allocator.free(url);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, url);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} ", .{path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), term.model.input.semanticSpans().len);
    const styled = try term.model.input.viewStyled(std.testing.allocator, theme.of(.night).accent, theme.of(.night).text);
    defer std.testing.allocator.free(styled);
    try std.testing.expect(std.mem.indexOf(u8, styled, theme.of(.night).accent) != null);

    try term.model.input.setValue(path);
    const plain = try term.model.input.viewStyled(std.testing.allocator, theme.of(.night).accent, theme.of(.night).text);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, theme.of(.night).accent) == null);
}

test "#792 undo restores file span identity after atomic deletion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "undo file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    paste(&term, path);
    _ = term.press(.backspace); // separator
    _ = term.press(.backspace); // span
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    _ = term.press(.undo);
    try std.testing.expectEqualStrings(path, term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), term.model.input.semanticSpans().len);
    _ = term.press(.backspace);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
}

test "#792 prompt history round trip preserves an unsent file span" {
    const history = @import("prompt_history.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try writeTmp(&tmp, "draft file.txt", &path_buf);
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    try term.model.prompt_hist.append(try std.testing.allocator.dupe(u8, "older"));
    try term.model.prompt_hist_images.append(&.{});

    paste(&term, path);
    history.recallPrev(&term.model);
    try std.testing.expectEqualStrings("older", term.model.input.getValue());
    history.recallNext(&term.model);
    try std.testing.expectEqual(@as(usize, 1), term.model.input.semanticSpans().len);
    _ = term.press(.backspace);
    _ = term.press(.backspace);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
}

test "#792 image paste consumes only its inserted range" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("keep me");

    paste(&term, "/tmp/pic.png");
    try std.testing.expectEqualStrings("keep me", term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
    try std.testing.expectEqualStrings("/tmp/pic.png", term.model.images.items[0]);
}

test "#792 mid-buffer image paste does not edit surrounding text" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("keepme");
    _ = term.press(.home);
    for (0..4) |_| _ = term.press(.right);

    paste(&term, "/tmp/pic.png");
    try std.testing.expectEqualStrings("keepme", term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
}

test "#792 empty paste does not consume an undo step" {
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("x");

    paste(&term, "");
    _ = term.press(.undo);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
}
