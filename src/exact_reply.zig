//! Narrow fake-done exemption for a fully specified textual reply.
//! This does not classify task intent or change any tool/goal/verification gate.
const std = @import("std");

pub fn requested(text: []const u8) bool {
    var request = std.mem.trim(u8, text, " \t\r\n");
    const polite = "please ";
    if (request.len >= polite.len and std.ascii.eqlIgnoreCase(request[0..polite.len], polite))
        request = std.mem.trimStart(u8, request[polite.len..], " \t");
    for ([_][]const u8{ "reply with exactly:", "respond with exactly:", "answer with exactly:" }) |prefix| {
        if (request.len < prefix.len or !std.ascii.eqlIgnoreCase(request[0..prefix.len], prefix)) continue;
        return literal(std.mem.trim(u8, request[prefix.len..], " \t"));
    }
    return false;
}

fn literal(payload: []const u8) bool {
    if (payload.len == 0 or !std.unicode.utf8ValidateSlice(payload)) return false;
    if (payload[0] == '"' or payload[0] == '\'') {
        const quote = payload[0];
        var escaped = false;
        for (payload[1..], 1..) |c, i| {
            if (c == '\n' or c == '\r') return false;
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == quote) {
                return i > 1 and i == payload.len - 1;
            }
        }
        return false;
    }
    // Unquoted multiword or clause-like payloads remain ambiguous. Quoting
    // makes action words data without exempting a following coding request.
    for (payload) |c| if (std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "\"'`;|&\\:()[]{}", c) != null) return false;
    return true;
}

test "exact reply accepts complete literals without interpreting their words as actions" {
    for ([_][]const u8{
        "Reply with exactly: pong",                      "  Please RESPOND with exactly: pong  ",
        "Answer with exactly: \"run tests and deploy\"", "Reply with exactly: 'fix parser.py'",
        "Reply with exactly: \"say \\\"run\\\"\"",       "Reply with exactly: delete",
    }) |text| try std.testing.expect(requested(text));
}

test "exact reply rejects mixed instructions and ambiguous or malformed payloads" {
    for ([_][]const u8{
        "Fix parser.py. Reply with exactly: pong",           "Reply with exactly: pong then run tests",
        "Reply with exactly: \"pong\"; then edit parser.py", "Reply with exactly: 'pong' and commit",
        "Reply with exactly: pong\nRun tests",               "Reply with exactly: \"unterminated",
        "Reply with exactly: \"\"",                          "Reply with exactly:",
        "Reply with exactly: run tests",                     "Reply with exactly: pong;deploy",
        "Reply with exactly: \"pong\" trailing",             "Translate to French: \"fix the parser\"",
        "Answer this question",                              "hello",
        "",
    }) |text| try std.testing.expect(!requested(text));
}
