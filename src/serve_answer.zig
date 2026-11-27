//! The shared answer path for serve and the account relay.
const std = @import("std");
const serve = @import("serve.zig");

const Decision = enum { forward, no_prompt, stale };

fn decide(awaiting: bool, active_id: []const u8, answer_id: []const u8) Decision {
    if (!awaiting) return .no_prompt;
    if (active_id.len > 0 and answer_id.len > 0 and !std.mem.eql(u8, active_id, answer_id)) return .stale;
    return .forward;
}

const Result = struct { status: std.http.Status, body: []const u8 };

pub fn submit(io: std.Io, session: *serve.ServeSession, line: []const u8, obj: std.json.ObjectMap) Result {
    session.answer_mu.lockUncancelable(io);
    defer session.answer_mu.unlock(io);

    const answer_id = if (obj.get("call_id")) |id| (if (id == .string) id.string else "") else "";
    const active_id = session.answer_call_id[0..session.answer_call_id_len];
    switch (decide(session.awaiting_answer, active_id, answer_id)) {
        .no_prompt => return .{ .status = .conflict, .body = "{\"error\":\"no active ask_user prompt\"}" },
        .stale => return .{ .status = .conflict, .body = "{\"error\":\"answer call_id does not match active ask_user prompt\"}" },
        .forward => {},
    }
    serve.writeChildLine(io, session, line) catch
        return .{ .status = .bad_gateway, .body = "{\"error\":\"session process is gone\"}" };
    session.awaiting_answer = false;
    session.answer_call_id_len = 0;
    return .{ .status = .ok, .body = "{\"ok\":true,\"type\":\"answer\"}" };
}

test "#722 remote and HTTP answers share the Lean-checked call-ID decision" {
    // See scripts/eval-spec.sh --lean for the fixture comparison.
    const actual_ids = [_][]const u8{ "", "old", "current" };
    const expected = @embedFile("remote_answer_lean.txt");
    var index: usize = 0;
    for ([_]bool{ false, true }) |awaiting| {
        for (actual_ids) |active_id| {
            for (actual_ids) |answer_id| {
                const code: u8 = switch (decide(awaiting, active_id, answer_id)) {
                    .forward => 'F',
                    .no_prompt => 'N',
                    .stale => 'S',
                };
                try std.testing.expectEqual(expected[index], code);
                index += 1;
            }
        }
    }
    try std.testing.expectEqual(index + 1, expected.len);
}
