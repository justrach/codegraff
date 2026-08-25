//! (#401) "Is VISIBLE PROSE flowing?" for the codex WebSocket reader — the WS
//! side of the signal the SSE reader takes straight from `partial_text`.
//!
//! Both feed the same http_stall.budgetMs, so this must mean EXACTLY what the
//! SSE signal means: too loose and a silently-reasoning turn is killed as a
//! stall (the round-2 regression), too tight and a mid-answer server death
//! waits four times as long as it does on SSE (the round-4 finding).
//!
//! SSE passes `self.partial_text.items.len != 0`, and on the `.responses` path
//! partial_text has TWO producers, both reached from agent_stream.streamSseLine:
//!
//!   1. the `response.output_text.delta` arm, whose `if (text.len == 0) return;`
//!      gate is why an EMPTY delta does not count. Reasoning deltas are handled
//!      above the append and `response.output_item.done` never reaches it, so a
//!      silent reasoning phase keeps the FULL pre-first-token budget on SSE —
//!      deliberately, since it legitimately runs minutes. → frameHasOutputText.
//!   2. `argLiveDelta` (called on EVERY line, before the text extraction) →
//!      ArgLive.feed → agent_argstream.emitArgText, which appends the streamed
//!      tool-ARGUMENT prose of a whitelisted call. Not an exotic path:
//!      attempt_completion is graff's ordinary final-answer tool, so a codex
//!      turn whose entire visible output is that prose streams only
//!      `response.function_call_arguments.delta` and never one output_text
//!      delta. → TokenSignal.
//!
//! The whitelist is NOT duplicated here: `argToolFor` is the same function
//! ArgLive.open classifies with, so the SSE and WS signals cannot drift.
//!
//! Lives beside agent_ws.zig (which is near the 600-line cap) the way
//! http_stall.zig lives beside http.zig, and is aliased back into agent_ws.

const std = @import("std");

const argstream = @import("agent_argstream.zig");
const argToolFor = argstream.argToolFor;
const outputIndex = argstream.outputIndex;

/// Producer 1: does this ws frame carry VISIBLE OUTPUT TEXT?
///
/// Frame ARRIVAL is not the signal: response.created / response.in_progress /
/// response.output_item.added land within milliseconds of the send, long before
/// the model has thought (and ping/pong never surfaces from readMessage at
/// all). Keying the budget on "a frame landed" tightens every WS turn to a
/// quarter budget from ~100ms in, so a high-effort turn reasoning silently past
/// that is killed as a stall, re-sent as a full re-anchor, stalled again, and
/// latched off WS for the session — while the identical turn survives on SSE.
///
/// Shape mirrors isStreamEnd: a cheap substring candidate, then an
/// authoritative parse, so a reasoning delta that merely QUOTES the event name
/// is not mistaken for one.
pub fn frameHasOutputText(gpa: std.mem.Allocator, frame: []const u8) bool {
    const ev = "response.output_text.delta";
    if (std.mem.indexOf(u8, frame, ev) == null) return false;
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), frame, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const ty = v.object.get("type") orelse return false;
    if (ty != .string or !std.mem.eql(u8, ty.string, ev)) return false;
    const d = v.object.get("delta") orelse return false;
    return d == .string and d.string.len != 0;
}

/// The turn's tokens-flowing signal: both producers, and the little bit of
/// state producer 2 needs (which output item is the open whitelisted call).
///
/// Producer 2 is keyed on the item, not the tool-argument bytes: SSE's ArgLive
/// starts appending a fraction of a frame later (once its scanner reaches the
/// `result`/`question` VALUE), so keying on the first non-empty argument delta
/// of a whitelisted call tightens at most one frame early on the same stream.
/// That direction is the safe one — the alternative is running a second copy of
/// the ArgLive scanner here, i.e. the drift this module exists to prevent.
pub const TokenSignal = struct {
    /// `output_index` of the open whitelisted (attempt_completion / ask_user)
    /// function call; -1 for none. The mirror of ArgLive.index, opened and
    /// closed by the same events argLiveDelta uses.
    arg_ix: i64 = -1,

    /// True the first time a frame proves visible prose is flowing. Called only
    /// until it returns true — the budget never un-tightens.
    pub fn flowing(self: *TokenSignal, gpa: std.mem.Allocator, frame: []const u8) bool {
        if (frameHasOutputText(gpa, frame)) return true;
        return self.argProse(gpa, frame);
    }

    /// Producer 2. Tracks response.output_item.added/done to know WHICH item is
    /// a whitelisted call, then fires on that item's first non-empty argument
    /// delta. An ordinary tool's argument stream (edit_file, bash) prints
    /// nothing on SSE and so must leave the pre-first-token budget standing.
    fn argProse(self: *TokenSignal, gpa: std.mem.Allocator, frame: []const u8) bool {
        const arg_delta = "response.function_call_arguments.delta";
        // Cheap candidate filter, same shape as frameHasOutputText's: the two
        // item lifecycle events share the `response.output_item.` prefix.
        if (std.mem.indexOf(u8, frame, "response.output_item.") == null and
            std.mem.indexOf(u8, frame, arg_delta) == null) return false;
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        const v = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), frame, .{ .allocate = .alloc_always }) catch return false;
        if (v != .object) return false;
        const ty = v.object.get("type") orelse return false;
        if (ty != .string) return false;
        if (std.mem.eql(u8, ty.string, "response.output_item.added")) {
            const ix = outputIndex(v.object) orelse return false;
            const item = v.object.get("item") orelse return false;
            if (item != .object) return false;
            const it = item.object.get("type") orelse return false;
            if (it != .string or !std.mem.eql(u8, it.string, "function_call")) return false;
            const name = item.object.get("name") orelse return false;
            // Exactly ArgLive.open's gate: a non-whitelisted name opens nothing
            // (and cannot clobber an open index — output indices are unique).
            if (name == .string) {
                const t = argToolFor(name.string);
                // Visible prose only — rlm's `code` is speculated, not printed.
                if (t == .attempt_completion or t == .ask_user) self.arg_ix = ix;
            }
            return false;
        }
        if (std.mem.eql(u8, ty.string, "response.output_item.done")) {
            const ix = outputIndex(v.object) orelse return false;
            if (ix == self.arg_ix) self.arg_ix = -1; // ArgLive.close
            return false;
        }
        if (!std.mem.eql(u8, ty.string, arg_delta)) return false;
        const ix = outputIndex(v.object) orelse return false;
        if (ix != self.arg_ix) return false;
        const d = v.object.get("delta") orelse return false;
        return d == .string and d.string.len != 0;
    }
};

/// xAI WS error frames ({"type":"error"}) are terminal for the turn but not in
/// isStreamEnd's completed/failed set, so without classification they burn the
/// whole stall budget on a doomed socket.
pub const ErrorFrameAction = enum { none, retire, chain_lost };

pub fn errorFrameAction(frame: []const u8) ErrorFrameAction {
    if (std.mem.indexOf(u8, frame, "\"type\":\"error\"") == null) return .none;
    // The server sends this right before closing a 25-minute-old socket.
    if (std.mem.indexOf(u8, frame, "websocket_connection_limit_reached") != null) return .retire;
    // Our chain anchor is gone (evicted / never cached under store:false).
    if (std.mem.indexOf(u8, frame, "previous_response_not_found") != null) return .chain_lost;
    return .none;
}

/// The deadline for writing a frame of `frame_len` bytes.
///
/// NOT a flat head-sized budget: the frame most likely to sit under this guard
/// is the LARGEST one, because every recovery re-anchors with the full
/// conversation (closeCodexWs nulls codex_prev_id). A flat 30s over a ~1MB
/// re-anchor on a slow uplink is a false positive costing a transport failure,
/// and two of those latch SSE for the session. Policy: the head budget plus one
/// second per 64KB (a ~512 kbit/s floor, far below any link that can carry a
/// codex session), clamped to the read budget so the send guard can never
/// outlast the watchdog covering the reply.
pub fn sendDeadlineMs(frame_len: usize, head_ms: u64, stream_ms: u64) u64 {
    const grow: u64 = @as(u64, @intCast(frame_len / (64 * 1024))) *| 1000;
    return @min(head_ms +| grow, @max(head_ms, stream_ms));
}

test "errorFrameAction classifies the two xAI ws error codes, ignores prose" {
    try std.testing.expectEqual(ErrorFrameAction.retire, errorFrameAction("{\"type\":\"error\",\"error\":{\"code\":\"websocket_connection_limit_reached\"}}"));
    try std.testing.expectEqual(ErrorFrameAction.chain_lost, errorFrameAction("{\"type\":\"error\",\"error\":{\"code\":\"previous_response_not_found\"}}"));
    try std.testing.expectEqual(ErrorFrameAction.none, errorFrameAction("{\"type\":\"response.output_text.delta\",\"delta\":\"websocket_connection_limit_reached\"}"));
    try std.testing.expectEqual(ErrorFrameAction.none, errorFrameAction("{\"type\":\"error\",\"error\":{\"code\":\"other\"}}"));
}
