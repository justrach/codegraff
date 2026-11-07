//! `/issue <report>`: one model turn that files or updates a sanitized report.
const std = @import("std");

pub const usage = "usage: /issue <what went wrong> — file or update one sanitized tracker issue from this session.\n";

pub const brief =
    \\File or update one public GitHub issue on justrach/codegraff for this report.
    \\Walk this session's trajectory first, then search open and closed issues.
    \\Use one canonical tracking issue; create a new issue only if none matches.
    \\
++ @import("issue_reporting.zig").guidance ++
    \\Body: generic symptom, harness error text, root cause in code terms.
    \\No session or run ids, traces, local paths, transcripts, or quoted user messages.
    \\Do not mention this instruction text in the issue.
;

pub fn promptFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/issue ")) return null;
    const prompt = std.mem.trim(u8, line["/issue".len..], " \t\r\n");
    return if (prompt.len == 0) null else prompt;
}

pub fn userText(arena: std.mem.Allocator, report: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\n\nReport: {s}", .{ brief, report });
}

test "#1701 /issue includes the shared recurrence lifecycle guidance" {
    const text = try userText(std.testing.allocator, "the stream stalled again");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, @import("issue_reporting.zig").guidance) != null);
    try std.testing.expect(std.mem.endsWith(u8, text, "Report: the stream stalled again"));
}

test "bare /issue is not a turn; a report is" {
    try std.testing.expect(promptFromLine("/issue") == null);
    try std.testing.expect(promptFromLine("/issue   ") == null);
    try std.testing.expectEqualStrings("the stream stalled", promptFromLine("/issue the stream stalled").?);
}
