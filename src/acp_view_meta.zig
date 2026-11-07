//! A tool result that saved a view carries it as structured ACP metadata.
//!
//! `render_html` and MCP Apps results each write one private HTML snapshot
//! (html_view.zig, mcp_apps.zig) and start their result text with a link to
//! it. A client that shows views should not have to parse that text, so the
//! completed `tool_call_update` also carries
//! `_meta["graff/view"] = {"kind": "html" | "mcp_app", "path": …, "id": …}`.
//! The text link stays for every other client.
//!
//! Only graff's own snapshot shape is recognized: the link opens the result,
//! and its path ends in `/.graff/views/<32 hex>.html` or
//! `/.graff/mcp-apps/<32 hex>.html`. A client must still refuse anything
//! outside those two directories; this is a hint, not an authorization.

const std = @import("std");
const Io = std.Io;
const proto = @import("acp_protocol.zig");

pub const View = struct {
    kind: []const u8,
    path: []const u8,
    id: []const u8,
};

const shapes = [_]struct { prefix: []const u8, kind: []const u8, dir: []const u8 }{
    .{ .prefix = "[Rendered view](", .kind = "html", .dir = "/.graff/views/" },
    .{ .prefix = "[MCP app](", .kind = "mcp_app", .dir = "/.graff/mcp-apps/" },
};

pub fn detect(text: []const u8) ?View {
    for (shapes) |s| {
        if (!std.mem.startsWith(u8, text, s.prefix)) continue;
        const rest = text[s.prefix.len..];
        const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
        const path = rest[0..close];
        const tail_len = s.dir.len + 32 + ".html".len;
        if (path.len <= tail_len) return null;
        const tail = path[path.len - tail_len ..];
        if (!std.mem.startsWith(u8, tail, s.dir) or !std.mem.endsWith(u8, tail, ".html")) return null;
        const id = tail[s.dir.len .. s.dir.len + 32];
        for (id) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
        return .{ .kind = s.kind, .path = path, .id = id };
    }
    return null;
}

/// The completed `tool_call_update` for a result with text, plus the metadata
/// a client needs to render it without parsing prose: the view snapshot when
/// the text opens with one, and the delegated task's context/usage facts when
/// it carried them. The two coexist under one `_meta` object.
pub fn writeDone(w: *Io.Writer, session_id: []const u8, id: []const u8, status: []const u8, text: []const u8, run_task: ?@import("engine_events.zig").RunTaskMeta) !void {
    const content = .{.{ .type = "content", .content = .{ .type = "text", .text = text } }};
    const base = .{
        .sessionUpdate = "tool_call_update",
        .toolCallId = id,
        .status = status,
        .content = content,
    };
    const view = detect(text);
    const m = run_task;
    if (view == null and m == null) {
        return proto.writeNotification(w, "session/update", .{ .sessionId = session_id, .update = base });
    }
    if (view != null and m == null) {
        return proto.writeNotification(w, "session/update", .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = id,
                .status = status,
                .content = content,
                ._meta = .{ .@"graff/view" = view.? },
            },
        });
    }
    if (view == null) {
        return proto.writeNotification(w, "session/update", .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = "tool_call_update",
                .toolCallId = id,
                .status = status,
                .content = content,
                ._meta = .{ .@"codegraff/runTask" = m.? },
            },
        });
    }
    return proto.writeNotification(w, "session/update", .{
        .sessionId = session_id,
        .update = .{
            .sessionUpdate = "tool_call_update",
            .toolCallId = id,
            .status = status,
            .content = content,
            ._meta = .{ .@"graff/view" = view.?, .@"codegraff/runTask" = m.? },
        },
    });
}

const testing = std.testing;
const hex = "0123456789abcdef0123456789abcdef";

test "detect: graff's own view and MCP app snapshots" {
    const html = detect("[Rendered view](/home/u/.graff/views/" ++ hex ++ ".html) — shown").?;
    try testing.expectEqualStrings("html", html.kind);
    try testing.expectEqualStrings("/home/u/.graff/views/" ++ hex ++ ".html", html.path);
    try testing.expectEqualStrings(hex, html.id);
    const app = detect("[MCP app](C:\\Users\\u/.graff/mcp-apps/" ++ hex ++ ".html) — saved\nrest").?;
    try testing.expectEqualStrings("mcp_app", app.kind);
    try testing.expectEqualStrings(hex, app.id);
}

test "detect: anything else is plain text" {
    try testing.expect(detect("done") == null);
    try testing.expect(detect("see [Rendered view](/home/u/.graff/views/" ++ hex ++ ".html)") == null); // not at the start
    try testing.expect(detect("[Rendered view](/etc/passwd)") == null);
    try testing.expect(detect("[Rendered view](/home/u/.graff/mcp-apps/" ++ hex ++ ".html)") == null); // wrong dir for the kind
    try testing.expect(detect("[MCP app](/home/u/.graff/mcp-apps/" ++ "0123456789ABCDEF0123456789abcdef" ++ ".html)") == null);
    try testing.expect(detect("[MCP app](/home/u/.graff/mcp-apps/short.html)") == null);
    try testing.expect(detect("[Rendered view](/home/u/.graff/views/" ++ hex ++ ".html") == null); // unclosed
}

test "writeDone: a view result carries _meta graff/view; other results do not" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDone(&w, "s1", "call-1", "completed", "[Rendered view](/h/.graff/views/" ++ hex ++ ".html) — shown", null);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"graff/view\":{\"kind\":\"html\",\"path\":\"/h/.graff/views/" ++ hex ++ ".html\",\"id\":\"" ++ hex ++ "\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[Rendered view]") != null); // the text link stays
    var buf2: [1024]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    try writeDone(&w2, "s1", "call-2", "completed", "plain", null);
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "graff/view") == null);
}

const task_meta: @import("engine_events.zig").RunTaskMeta = .{
    .context_chars = 40,
    .context_used_chars = 7,
    .context_summarized = true,
    .usage_reported = false,
    .usage_unavailable_reason = "no settlement",
};

test "writeDone: a delegated task's facts ride _meta alongside a view, and alone" {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDone(&w, "s1", "call-1", "completed", "plain answer", task_meta);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"codegraff/runTask\":{\"context_chars\":40,\"context_used_chars\":7,\"context_summarized\":true,\"usage_reported\":false,\"usage_unavailable_reason\":\"no settlement\"}") != null);
    try testing.expect(std.mem.indexOf(u8, out, "graff/view") == null);
    // Neither the answer nor the caller's context travels with the facts.
    try testing.expect(std.mem.indexOf(u8, out, "plain answer") != null); // still the tool content
    try testing.expect(std.mem.count(u8, out, "plain answer") == 1);
    // A view and the facts coexist in one _meta object.
    var buf2: [4096]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    try writeDone(&w2, "s1", "call-2", "completed", "[MCP app](/h/.graff/mcp-apps/" ++ hex ++ ".html)", task_meta);
    const both = w2.buffered();
    try testing.expect(std.mem.indexOf(u8, both, "\"graff/view\":") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"codegraff/runTask\":") != null);
    try testing.expect(std.mem.indexOf(u8, both, "\"_meta\":{\"graff/view\":") != null);
}
