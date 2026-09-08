//! Codex WS prewarm (openai/codex's `generate:false` prewarm_websocket, #codex-ws).
//!
//! Before the session's FIRST stream request on a fresh codex socket, send a
//! `response.create` with `generate:false` and no input items: the server
//! prepares the instructions+tools request state and returns a response id.
//! Turn 1 then chains onto it (`previous_response_id` + the user message), so
//! the big fixed prefix is ingested before the user's prompt instead of during
//! their wait. DeepWiki (openai/codex, `ModelClientSession.prewarm_websocket`):
//! best-effort connection setup — any failure falls through to a normal cold
//! turn; it is not an inference request and must not touch the meters.
//!
//! Kept out of agent_ws.zig (600-line cap). Own module so the frame shape and
//! the gate are testable without a socket.

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const ws = @import("ws.zig");
const http = @import("http.zig");
const body_responses = @import("agent_request_body_responses.zig");
const codex_chain = @import("codex_chain.zig");
const serde = @import("serde.zig");

const WatchdogFired = http.WatchdogFired;

/// Should this fresh connection prewarm? Codex brand, session start (nothing
/// sent, no chain anchor), and not under the full-resend experiment (seeding
/// the chain would fight the flag's premise).
pub fn eligible(self: *const Agent) bool {
    if (!std.mem.eql(u8, self.provider.id, "codex")) return false;
    if (codex_chain.g_force_full_resend) return false;
    return self.codex_ws != null and self.codex_prev_id == null and self.codex_sent_upto == 0;
}

/// Build the `{"type":"response.create",...generate:false}` frame. Same
/// properties (instructions, tools, reasoning effort) as the real turn, so the
/// chain fingerprint codex_chain.propsFor matches and turn 1 can chain.
pub fn buildFrame(self: *Agent, arena: std.mem.Allocator) ![]u8 {
    self.ws_prewarm = true;
    defer self.ws_prewarm = false;
    var out: std.Io.Writer.Allocating = .init(arena);
    var st: std.json.Stringify = .{ .writer = &out.writer };
    try st.beginObject();
    try st.objectField("type");
    try st.write("response.create");
    try body_responses.write(self, &st, self.toolsJson(), false);
    try st.endObject();
    return out.toOwnedSlice();
}

/// Best-effort prewarm on a freshly dialed codex socket. Never fails the turn:
/// every failure path just leaves the chain state untouched so the real request
/// proceeds cold. On success the prewarm response id becomes the turn-1 chain
/// anchor (gpa-owned, same lifetime rule as codex_prev_id everywhere else).
/// xAI Responses WS spec: the response.create body must omit transport-only
/// fields (stream, background) — responses always stream back as socket
/// events. buildBody always writes `stream:true` (the SSE path requires it),
/// so the WS frame strips the trailing field. Codex's backend tolerates the
/// field; xAI's documents its omission.
pub fn stripTransportFields(frame: []u8) []u8 {
    const marker = ",\"stream\":true";
    if (std.mem.endsWith(u8, frame, marker ++ "}")) {
        // ...true,"stream":true}  →  ...true}  (move the closing brace over the marker)
        const cut = frame.len - marker.len - 1;
        frame[cut] = frame[frame.len - 1];
        return frame[0 .. cut + 1];
    }
    return frame;
}

/// Best-effort prewarm on a freshly dialed codex socket. Returns the frame to
/// send: the original, or the same frame with `previous_response_id` set to
/// the prewarm response id (all arena-owned — NOTHING here touches gpa-owned
/// chain state, so a turn whose response carries no id simply re-anchors on
/// turn 2, exactly as before). Every failure returns the original frame.
pub fn warm(self: *Agent, arena: std.mem.Allocator, client: *ws.WsClient, frame: []const u8) []const u8 {
    if (!eligible(self)) return frame;
    const tracer = self.tracer;
    const prewarm_frame = buildFrame(self, arena) catch return frame;
    // The frame is far under the 256KB SO_SNDBUF threshold agent_ws_signal
    // documents, so a blocking sendText copies into the socket buffer and
    // returns; the read half below is the bounded half.
    client.sendText(prewarm_frame) catch {
        if (tracer) |tr| tr.note("ws", "prewarm send failed — cold turn");
        return frame;
    };
    if (tracer) |tr| tr.note("ws", "prewarm sent");
    const id = awaitPrewarmId(self, arena, client) catch |e| {
        if (tracer) |tr| tr.note("ws", if (e == error.PrewarmRejected) "prewarm rejected — cold turn" else "prewarm no terminal — cold turn");
        return frame;
    };
    if (tracer) |tr| {
        var nbuf: [80]u8 = undefined;
        tr.note("ws", std.fmt.bufPrint(&nbuf, "prewarm ok — turn 1 chains onto {s}…", .{id[0..@min(id.len, 12)]}) catch "prewarm ok");
    }
    // Inject the chain seed into the real frame after the type field:
    // {"type":"response.create" ,"previous_response_id":"…", …}. Arena-owned;
    // a not-found rejection on turn 1 re-anchors through the existing ladder.
    const cut = std.mem.indexOf(u8, frame, ",\"") orelse return frame;
    return std.mem.concat(arena, u8, &.{
        frame[0..cut], ",\"previous_response_id\":\"", id, "\"", frame[cut..],
    }) catch frame;
}

/// Read frames until the prewarm's terminal event; returns response.id.
/// Bounded by the watchdog so a server that accepts the prewarm and goes
/// silent cannot park the user's turn behind it.
fn awaitPrewarmId(self: *Agent, arena: std.mem.Allocator, client: *ws.WsClient) ![]const u8 {
    var fbuf: std.ArrayList(u8) = .empty;
    defer fbuf.deinit(self.gpa);
    while (true) {
        const ReadDone = union(enum) { msg: ws.Error!ws.Opcode, stall: WatchdogFired };
        var rd_buf: [2]ReadDone = undefined;
        var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
        rsel.concurrent(.msg, readTask, .{ client, self.gpa, &fbuf }) catch return error.Watchdog;
        rsel.concurrent(.stall, @import("http.zig").deadlineStallTask, .{ self.io, false, @import("http.zig").head_stall_ms }) catch {
            const r = rsel.await() catch return error.Watchdog;
            rsel.cancelDiscard();
            _ = r.msg catch return error.Watchdog;
            continue;
        };
        const first = rsel.await() catch return error.Watchdog;
        rsel.cancelDiscard();
        switch (first) {
            .msg => |m| _ = m catch return error.Watchdog,
            .stall => return error.Watchdog,
        }
        if (fbuf.items.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, fbuf.items, .{}) catch {
            fbuf.clearRetainingCapacity();
            continue;
        };
        const typv = v.object.get("type") orelse return error.NoId;
        if (typv != .string) return error.NoId;
        const t = typv.string;
        if (std.mem.eql(u8, t, "response.completed")) {
            const resp = v.object.get("response") orelse return error.NoId;
            const idv = resp.object.get("id") orelse return error.NoId;
            if (idv != .string or idv.string.len == 0) return error.NoId;
            return idv.string;
        }
        if (std.mem.eql(u8, t, "response.failed") or std.mem.eql(u8, t, "error")) return error.PrewarmRejected;
        fbuf.clearRetainingCapacity();
    }
}

fn readTask(client: *ws.WsClient, gpa: std.mem.Allocator, fbuf: *std.ArrayList(u8)) ws.Error!ws.Opcode {
    fbuf.clearRetainingCapacity();
    return client.readMessage(gpa, fbuf);
}

test "buildFrame: prewarm body has generate:false, empty input, no previous_response_id" {
    const stdt = std;
    var arena_state = stdt.heap.ArenaAllocator.init(stdt.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = stdt.json.Array.init(arena);
    try messages.append(try @import("messages.zig").textMessage(arena, "user", "hello"));
    var agent = Agent{
        .io = stdt.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://chatgpt.com/backend-api/codex/responses", .api_key = "k", .model = "gpt-5.6", .context = 272_000 },
        .messages = messages,
        .sub = false,
        .label = "main",
        .out = null,
        .arena = arena,
        .gpa = stdt.testing.allocator,
    };
    const frame = try buildFrame(&agent, arena);
    try stdt.testing.expect(std.mem.indexOf(u8, frame, "\"generate\":false") != null);
    try stdt.testing.expect(std.mem.indexOf(u8, frame, "\"input\":[]") != null);
    try stdt.testing.expect(std.mem.indexOf(u8, frame, "previous_response_id") == null);
    try stdt.testing.expect(std.mem.indexOf(u8, frame, "\"stream\":true") == null);
    try stdt.testing.expect(std.mem.indexOf(u8, frame, "\"instructions\"") != null);
    // The flag must not leak past the builder.
    try stdt.testing.expect(!agent.ws_prewarm);
}

test "stripTransportFields: WS frames omit the SSE-only stream field" {
    const stdt = std;
    const gpa = stdt.testing.allocator;
    const with_stream = try gpa.dupe(u8, "{\"type\":\"response.create\",\"model\":\"m\",\"input\":[],\"stream\":true}");
    defer gpa.free(with_stream);
    const stripped = stripTransportFields(with_stream);
    try stdt.testing.expect(std.mem.indexOf(u8, stripped, "stream") == null);
    try stdt.testing.expect(std.mem.endsWith(u8, stripped, "}"));
    try stdt.testing.expect(std.mem.indexOf(u8, stripped, "\"input\":[]") != null);
    // A frame without the field passes through unchanged.
    const clean = try gpa.dupe(u8, "{\"type\":\"response.create\",\"model\":\"m\"}");
    defer gpa.free(clean);
    try stdt.testing.expectEqualStrings(clean, stripTransportFields(clean));
}

test "eligible: codex session start only" {
    const stdt = std;
    var arena_state = stdt.heap.ArenaAllocator.init(stdt.testing.allocator);
    defer arena_state.deinit();
    var agent = Agent{
        .io = stdt.testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://chatgpt.com/backend-api/codex/responses", .api_key = "k", .model = "gpt-5.6", .context = 272_000 },
        .messages = stdt.json.Array.init(arena_state.allocator()),
        .sub = false,
        .label = "main",
        .out = null,
        .arena = arena_state.allocator(),
        .gpa = stdt.testing.allocator,
    };
    try stdt.testing.expect(!eligible(&agent)); // no socket yet
    var held: ws.WsClient = undefined;
    agent.codex_ws = &held;
    try stdt.testing.expect(eligible(&agent)); // fresh session start
    agent.codex_prev_id = "resp_1";
    try stdt.testing.expect(!eligible(&agent)); // chain already anchored
    agent.codex_prev_id = null;
    agent.codex_sent_upto = 2;
    try stdt.testing.expect(!eligible(&agent)); // mid-session re-anchor
}
