//! Codex Responses turns over WebSocket. OpenAI's codex prefers ws and
//! falls back to SSE; graff mirrors that. The ws frames carry the SAME event
//! `type`s as the Responses SSE stream (response.output_text.delta,
//! response.completed, …), so each frame is wrapped as a `data: {json}` line
//! and handed to the existing parseResponses/isStreamEnd — the reassembly and
//! completion logic are shared with the SSE path.
//!
//! postLive() is the transport selector called by request(): codex root turns
//! try ws (postResponsesWs); a handshake/transport failure disables ws for the
//! session and falls back to postStream (SSE) — a genuine Esc/stall propagates.
//!
//! Observability (issue #134's ask): every ws lifecycle step is routed to the
//! tracer ("ws" notes: connecting/connected/completed/stall/fallback/errors),
//! which lands in harness.trace.jsonl so an agent can debug a ws turn after the
//! fact; GRAFF_WS_DEBUG=1 additionally dumps the handshake + frames to stderr.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ws = @import("ws.zig");

const term = @import("term.zig");
const tty = term.tty;

const http = @import("http.zig");
const WatchdogFired = http.WatchdogFired;
const streamStallTask = http.streamStallTask;
const watchdogError = http.watchdogError;

const isStreamEnd = @import("agent_stream.zig").isStreamEnd;

const escPressed = Agent.escPressed;
const rawNonblockStdin = Agent.rawNonblockStdin;
const drainSteerStdin = Agent.drainSteerStdin;

/// Codex ws applies to root Responses turns when enabled and not already fallen
/// back this session. Subagents/quiet turns keep the non-streaming SSE path.
pub fn wsEligible(self: *Agent) bool {
    return main_mod.g_codex_ws and !self.ws_off and !self.sub and
        self.provider.kind == .responses and self.out != null and !self.stream_quiet;
}

/// Transport selector: try ws for eligible codex turns, else SSE (postStream).
/// A ws transport/handshake failure disables ws for the session and falls back
/// to SSE; a deliberate Esc/stall propagates unchanged.
pub fn postLive(self: *Agent, body: []const u8) ![]u8 {
    // #134/#132 test seam: force a one-shot stall/drop on a live turn so the
    // end-to-end "[response ended early: …]" path (never "[response interrupted
    // by user]") can be exercised without a real provider. Consumed after one use.
    if (main_mod.g_force_stall_once) {
        main_mod.g_force_stall_once = false;
        if (!main_mod.json_mode) if (self.out) |o| {
            o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
            o.flush() catch {};
        };
        return error.StreamStalled;
    }
    if (main_mod.g_force_drop_once) {
        main_mod.g_force_drop_once = false;
        if (!main_mod.json_mode) if (self.out) |o| {
            o.writeAll("\n⚠ connection dropped — response ended early\n") catch {};
            o.flush() catch {};
        };
        return error.StreamDropped;
    }
    if (!wsEligible(self)) return if (self.ws_off) postStreamFresh(self, body) else self.postStream(body);
    return postResponsesWs(self, body) catch |e| {
        if (e == error.Interrupted or e == error.StreamStalled) return e;
        self.ws_off = true;
        if (self.tracer) |tr| tr.note("ws", "transport error — falling back to fresh-client SSE for this session");
        return postStreamFresh(self, body);
    };
}

fn postStreamFresh(self: *Agent, body: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
    defer client.deinit();
    if (self.tracer) |tr| tr.note("sse_fallback", "fresh HTTP client");
    return self.postStreamWithClient(&client, body);
}

fn wssUrl(arena: std.mem.Allocator, https_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, https_url, "https://"))
        return std.fmt.allocPrint(arena, "wss://{s}", .{https_url["https://".len..]});
    if (std.mem.startsWith(u8, https_url, "http://"))
        return std.fmt.allocPrint(arena, "ws://{s}", .{https_url["http://".len..]});
    return arena.dupe(u8, https_url);
}

fn wsReadTask(client: *ws.WsClient, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) ws.Error!ws.Opcode {
    return client.readMessage(gpa, out);
}

/// One Responses turn over ws. Returns the reassembled body as SSE-format
/// `data:` lines (parseResponses consumes it unchanged). Connect/transport
/// failures return the ws error so postLive can fall back to SSE.
pub fn postResponsesWs(self: *Agent, body: []const u8) ![]u8 {
    const gpa = self.gpa;
    const arena = self.arena;
    const provider = self.provider;

    // Wrap graff's Responses body ({"model":…}) with the ws envelope.
    const frame = try std.fmt.allocPrint(gpa, "{{\"type\":\"response.create\",{s}", .{body[1..]});
    defer gpa.free(frame);

    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{provider.api_key});
    var rnd: [16]u8 = undefined;
    self.io.random(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const sid = try std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });
    const headers = [_]ws.Header{
        .{ .name = "Authorization", .value = bearer },
        .{ .name = "chatgpt-account-id", .value = provider.account },
        .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" },
        .{ .name = "originator", .value = "codex_cli_rs" },
        .{ .name = "session_id", .value = sid },
        .{ .name = "User-Agent", .value = "codex_cli_rs/0.1 (graff)" },
    };
    const url = try wssUrl(arena, provider.url);

    // Esc watching (root TTY), same gate as postStream.
    const watch_esc = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio: ?tty.RawState = if (watch_esc) rawNonblockStdin() else null;
    defer if (orig_tio) |o| {
        _ = drainSteerStdin(true);
        tty.restore(o);
    };

    self.spinnerStart();
    defer self.spinnerStop();

    if (self.tracer) |tr| tr.note("ws", "connecting");
    // Hold ONE WS across the turn's tool loop (codex-style): the first request
    // dials; subsequent requests reuse it and send previous_response_id + delta.
    // The open connection IS the sticky context (no x-codex-turn-state to echo).
    if (self.codex_ws == null) {
        self.codex_ws = ws.WsClient.connect(gpa, self.io, url, false, &headers) catch |e| {
            if (self.tracer) |tr| tr.note("ws", @errorName(e));
            return e;
        };
        if (self.tracer) |tr| tr.note("ws", "connected");
    } else if (self.tracer) |tr| tr.note("ws", "reuse (delta)");
    const client = self.codex_ws.?;
    // Any error → close + reset the session so the next request re-anchors (fresh
    // WS full history, or SSE fallback via postLive's ws_off path). Never leaks.
    errdefer self.closeCodexWs();
    try client.sendText(frame);

    var full: Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    var fbuf: std.ArrayList(u8) = .empty;
    defer fbuf.deinit(gpa);

    stream: while (true) {
        // Race the frame read against the shared idle-stall watchdog so a dead
        // ws can't hang the turn — a deadline surfaces as error.StreamStalled
        // (never a user Esc), handled identically to the SSE path (#134).
        read: {
            const ReadDone = union(enum) { msg: ws.Error!ws.Opcode, stall: WatchdogFired };
            var rd_buf: [2]ReadDone = undefined;
            var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
            rsel.concurrent(.msg, wsReadTask, .{ client, gpa, &fbuf }) catch {
                // #56 Fix-B: pool exhausted — mirror the SSE line-read fail-safe. A bare
                // blocking readMessage can hang forever on a half-open ws with no
                // watchdog; end the turn as StreamStalled (never a hang, never a user
                // Esc), exactly as the .deadline arm below does.
                if (!main_mod.json_mode) if (self.out) |o| {
                    o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
                    o.flush() catch {};
                };
                if (self.tracer) |tr| tr.note("ws", "stall");
                return error.StreamStalled;
            };
            rsel.concurrent(.stall, streamStallTask, .{ self.io, orig_tio != null }) catch {
                const r = rsel.await() catch |e| {
                    rsel.cancelDiscard();
                    return e;
                };
                rsel.cancelDiscard();
                _ = r.msg catch |e| return e;
                break :read;
            };
            const first = rsel.await() catch |e| {
                rsel.cancelDiscard();
                return e;
            };
            rsel.cancelDiscard();
            switch (first) {
                .msg => |m| _ = m catch |e| return e,
                .stall => |w| {
                    if (w == .deadline and !main_mod.json_mode) if (self.out) |o| {
                        o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
                        o.flush() catch {};
                    };
                    if (self.tracer) |tr| tr.note("ws", if (w == .esc) "esc" else "stall");
                    return watchdogError(w, error.StreamStalled);
                },
            }
        }
        if (fbuf.items.len == 0) continue :stream;

        // Wrap the ws frame as an SSE data: line so parseResponses/isStreamEnd
        // (shared with the SSE path) handle reassembly + completion.
        try full.writer.writeAll("data: ");
        try full.writer.writeAll(fbuf.items);
        try full.writer.writeByte('\n');
        const line = try std.fmt.allocPrint(arena, "data: {s}", .{fbuf.items});
        if (isStreamEnd(arena, self.provider.kind, line)) {
            if (self.tracer) |tr| tr.note("ws", "completed");
            break :stream;
        }
        if (orig_tio != null and escPressed(true)) return error.Interrupted;
    }
    return full.toOwnedSlice();
}

test "wssUrl: https->wss, http->ws" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", try wssUrl(a.allocator(), "https://chatgpt.com/backend-api/codex/responses"));
    try std.testing.expectEqualStrings("ws://localhost:1234/x", try wssUrl(a.allocator(), "http://localhost:1234/x"));
}
