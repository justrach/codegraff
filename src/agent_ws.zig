//! Codex Responses turns over WebSocket. OpenAI's codex prefers ws and
//! falls back to SSE; graff mirrors that. The ws frames carry the SAME event
//! `type`s as the Responses SSE stream (response.output_text.delta,
//! response.completed, …), so each frame is wrapped as a `data: {json}` line
//! and handed to the existing parseResponses/isStreamEnd — the reassembly and
//! completion logic are shared with the SSE path.
//!
//! postLive() is the transport selector called by request(): codex root turns
//! try ws (postResponsesWs), retry one failed WS with a clean full-history
//! re-anchor, then latch onto the launch-scoped prewarmed HTTP client for SSE.
//!
//! Observability (issue #134's ask): every ws lifecycle step is routed to the
//! tracer ("ws" notes: connecting/connected/reuse (delta)/sent Nb/first frame/
//! completed/send stall/stall/esc/fallback/errors), which lands in the run's
//! file under .graff/traces so an agent can debug a ws turn after the fact;
//! GRAFF_WS_DEBUG=1 additionally dumps the handshake + frames to stderr. The
//! `sent`/`first frame` pair is what makes a hang diagnosable: which of the
//! turn's two halves went quiet is otherwise unrecoverable from the trace
//! (#401).

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ws = @import("ws.zig");
const http_headers = @import("http_headers.zig");

const term = @import("term.zig");
const tty = term.tty;

const http = @import("http.zig");
const WatchdogFired = http.WatchdogFired;
const streamStallWatch = http.streamStallWatch;
const deadlineStallTask = http.deadlineStallTask;
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

/// (#codex-ws) Client-side idle limit on the held codex WS, opencode's
/// OpenAIWebSocketPool design: never reuse a socket the server may already
/// have killed. A real trace showed the backend closing ours somewhere
/// within 8.5 min idle (user parked on an ask_user prompt) — 4 min stays
/// comfortably under (opencode uses 5). Overridable via
/// GRAFF_CODEX_WS_IDLE_SECS (parsed in session_run.zig beside the other
/// codex transport knobs).
pub var codex_ws_idle_ms: i64 = 4 * std.time.ms_per_min;

/// (#codex-ws) The idle-reanchor decision, pure so the regression test can
/// exercise it without a socket: has the held WS sat unused past the limit?
pub fn codexWsIdleExpired(now_ms: i64, used_ms: i64) bool {
    return now_ms - used_ms > codex_ws_idle_ms;
}

/// The .awake monotonic clock in ms — same time source as request()'s
/// latency measurement, so codex_ws_used_ms compares consistently.
fn nowAwakeMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

const ws_failures_before_fallback: u8 = 2;

pub fn wsShouldFallback(consecutive_failures: u8) bool {
    return consecutive_failures >= ws_failures_before_fallback;
}

/// Transport selector: try ws for eligible codex turns, else persistent SSE.
/// The first WS transport/handshake failure rebuilds full input and retries a
/// fresh socket. The second latches SSE for the session. Esc/stall propagates.
pub fn postLive(self: *Agent, body: []const u8) ![]u8 {
    // #134/#132 test seam: force a one-shot stall/drop on a live turn so the
    // end-to-end "[response ended early: …]" path (never "[response interrupted
    // by user]") can be exercised without a real provider. Consumed after one use.
    // #56 test seam: a stall/drop on EVERY live attempt (not consumed), so the
    // reconnect budget in agent_request exhausts and the turn ends — exercises the
    // give-up path offline, no network/key needed.
    if (main_mod.g_force_stall_always) {
        if (!main_mod.json_mode) if (self.out) |o| {
            o.writeAll("\n⚠ stream stalled\n") catch {};
            o.flush() catch {};
        };
        return error.StreamStalled;
    }
    if (main_mod.g_force_drop_always) {
        if (!main_mod.json_mode) if (self.out) |o| {
            o.writeAll("\n⚠ connection dropped\n") catch {};
            o.flush() catch {};
        };
        return error.StreamDropped;
    }
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
    if (!wsEligible(self)) return self.postStream(body);
    const response = postResponsesWs(self, body) catch |e| {
        if (e == error.Interrupted or e == error.StreamStalled) return e;
        // Preemptive idle expiry is not a failed transport attempt; it only asks
        // request() to rebuild the already-created delta as full input.
        if (e == error.CodexWsReanchor) return e;
        self.closeCodexWs();
        self.ws_transport_failures +|= 1;
        const fallback = wsShouldFallback(self.ws_transport_failures);
        // (#codex-ws) A delta body carries previous_response_id + only the new
        // messages, anchored to the WS session that just died — the codex HTTP
        // endpoint rejects previous_response_id outright ("Unsupported
        // parameter"), and even if it didn't, the referenced response died with
        // the socket. Never replay it over SSE. closeCodexWs's errdefer inside
        // postResponsesWs already reset codex_ws/codex_prev_id/codex_sent_upto by
        // the time we get here; call it again defensively (idempotent) so a
        // rebuilt body definitely carries full input with no prior-id, and ask
        // request() to rebuild + retry (a fresh WS re-anchors with full history)
        // instead of falling back to a stale SSE replay.
        if (std.mem.indexOf(u8, body, "\"previous_response_id\"") != null) {
            if (fallback) self.ws_off = true;
            if (self.tracer) |tr| tr.note("ws", if (fallback)
                "reuse failed twice — rebuilding full input for persistent SSE"
            else
                "reuse failed — retrying a fresh WS with full input");
            return error.CodexWsReanchor;
        }
        if (!fallback) {
            if (self.tracer) |tr| tr.note("ws", "transport error — retrying one fresh WS");
            return error.CodexWsReanchor;
        }
        self.ws_off = true;
        if (self.tracer) |tr| tr.note("ws", "transport failed twice — using persistent prewarmed SSE for this session");
        return self.postStream(body);
    };
    self.ws_transport_failures = 0;
    return response;
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

fn wsSendTask(client: *ws.WsClient, frame: []const u8) ws.Error!void {
    return client.sendText(frame);
}

fn wsConnectTask(gpa: std.mem.Allocator, io: Io, url: []const u8, headers: []const ws.Header) ws.Error!*ws.WsClient {
    return ws.WsClient.connect(gpa, io, url, false, headers);
}

/// The deadline for writing a frame of `frame_len` bytes.
///
/// NOT a flat head-sized budget, because the frame most likely to sit under
/// this guard is the LARGEST one: every recovery re-anchors with the full
/// conversation (closeCodexWs nulls codex_prev_id), so the retried frame is the
/// whole history where the delta was a few KB. A flat 30s over a ~1MB re-anchor
/// on a slow uplink is a false positive that costs a transport failure — and
/// two of those latch SSE for the session.
///
/// Policy: start at the head budget (a small frame really must be on the wire in
/// head time) and add one second per 64KB — a ~512 kbit/s floor, far below any
/// link that can carry a codex session — clamped to the read budget so the send
/// guard can never outlast the watchdog that covers the reply.
pub fn sendDeadlineMs(frame_len: usize, head_ms: u64, stream_ms: u64) u64 {
    const grow: u64 = @as(u64, @intCast(frame_len / (64 * 1024))) *| 1000;
    return @min(head_ms +| grow, @max(head_ms, stream_ms));
}

/// Bound the outbound half of a ws turn. `sendText` is a blocking socket write
/// with no deadline: if the peer stops draining, it parks in the syscall until
/// TCP gives up (minutes to never), and nothing polls Esc there either.
///
/// SCOPE — this is NOT the diagnosis for #401. A frame only parks once it
/// exceeds SO_SNDBUF plus the peer's receive window (>=256KB in practice on a
/// TLS WAN socket), and a delta frame at #401's reported scale (~70KB of total
/// conversation, one tool result under the 256KB per-output cap) copies into the
/// socket buffer and returns. What this closes is the rarer, larger case: a
/// full-history re-anchor on a wedged or blackholed socket, where the write
/// genuinely can block forever. #401's own signature is a READ-side stall — see
/// the frames-flowing budget in postResponsesWs.
///
/// A deadline is error.HungRequest, matching the SSE send+head guard it mirrors
/// (agent_stream.zig): postLive counts it as a transport failure, so it retries
/// a fresh socket and latches SSE on the second — WITHOUT spending the read
/// loop's 2-slot stall budget, which StreamStalled would. An Esc is
/// error.Interrupted, which request() never retries.
pub fn sendFrameWatched(io: Io, client: *ws.WsClient, frame: []const u8, poll_stdin: bool) !void {
    const budget = sendDeadlineMs(frame.len, http.head_stall_ms, http.stream_stall_ms);
    const SendDone = union(enum) { sent: ws.Error!void, stall: WatchdogFired };
    var sd_buf: [2]SendDone = undefined;
    var ssel: Io.Select(SendDone) = .init(io, &sd_buf);
    // #56 Fix-B: pool exhausted — never degrade to a bare blocking sendText,
    // which IS the hang this guard exists for. Fail retryable instead.
    ssel.concurrent(.sent, wsSendTask, .{ client, frame }) catch return error.HungRequest;
    ssel.concurrent(.stall, deadlineStallTask, .{ io, poll_stdin, budget }) catch {
        const r = ssel.await() catch |e| {
            ssel.cancelDiscard();
            return e;
        };
        ssel.cancelDiscard();
        return r.sent;
    };
    const first = ssel.await() catch |e| {
        ssel.cancelDiscard();
        return e;
    };
    // cancelDiscard (not cancel): the send arm returns void, and the
    // synchronous join is what keeps the borrowed `frame`/`client` alive.
    ssel.cancelDiscard();
    switch (first) {
        .sent => |s| try s,
        .stall => |w| return watchdogError(w, error.HungRequest),
    }
}

/// Cancel the remaining dial arms, closing a socket that finished connecting
/// after the watchdog fired — cancelDiscard would leak the client and its fd.
fn drainDialSelect(gpa: std.mem.Allocator, sel: anytype) void {
    while (sel.cancel()) |late| switch (late) {
        .dialed => |d| if (d) |c| {
            c.dead = true; // the peer just proved it is wedged; don't block on a close frame
            c.deinit(gpa);
        } else |_| {},
        .stall => {},
    };
}

/// Dial under a deadline. DNS + TCP + the TLS handshake + the blocking read of
/// the 101 status line are all unbounded, so a host that accepts the connection
/// but never upgrades would swallow the very retry the other guards trigger —
/// hanging at the "connecting" note instead.
///
/// Budget: the flat head budget, not sendDeadlineMs — a dial carries no payload,
/// so there is nothing to scale by. The one slow step inside is ca_bundle.rescan
/// (a local CA-store scan, tens of ms warm); a machine where that genuinely
/// needs >30s is already failing every HTTPS request in the process.
///
/// error.HungRequest, like the send guard: a failed dial is a transport failure
/// (postLive's ws_transport_failures ladder → one fresh retry, then SSE), never
/// a spend against the read loop's stall budget.
pub fn connectWatched(gpa: std.mem.Allocator, io: Io, url: []const u8, headers: []const ws.Header, poll_stdin: bool) !*ws.WsClient {
    const Dialed = union(enum) { dialed: ws.Error!*ws.WsClient, stall: WatchdogFired };
    var dl_buf: [2]Dialed = undefined;
    var dsel: Io.Select(Dialed) = .init(io, &dl_buf);
    dsel.concurrent(.dialed, wsConnectTask, .{ gpa, io, url, headers }) catch return error.HungRequest;
    dsel.concurrent(.stall, deadlineStallTask, .{ io, poll_stdin, http.head_stall_ms }) catch {
        const r = dsel.await() catch |e| {
            drainDialSelect(gpa, &dsel);
            return e;
        };
        drainDialSelect(gpa, &dsel);
        return r.dialed;
    };
    const first = dsel.await() catch |e| {
        drainDialSelect(gpa, &dsel);
        return e;
    };
    drainDialSelect(gpa, &dsel);
    switch (first) {
        .dialed => |d| return d,
        .stall => |w| return watchdogError(w, error.HungRequest),
    }
}

/// (reference parity, openai/codex) A cached socket must be liveness-checked
/// before it is reused: codex-rs asks the pooled connection `is_closed()` and
/// dials fresh when its read pump already saw the stream end, rather than
/// sending a turn into a socket it has decided is gone. graff's client is
/// synchronous — there is no background pump to set a "closed" bit — so the
/// equivalent signal is `dead`, which every teardown that touches a SUSPECT
/// socket sets (the send/read errdefer in postResponsesWs, the idle-expiry
/// close, the late-dial drain). A wall-clock idle window alone is not this
/// check: it cannot see a socket the peer or an LB blackholed 30s into a tool
/// call, which is well inside the window.
pub fn wsReusable(client: *const ws.WsClient) bool {
    return !client.dead;
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
    // The SAME per-process session id the HTTP path sends, not a fresh one per
    // connect: this is what the backend partitions its prompt cache on, so a
    // new id per socket handed every re-anchor a cold partition.
    const sid = http_headers.sessionId(self.io);
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
    // (#codex-ws) Preemptive idle re-anchor: don't reuse a WS the server has
    // likely already killed (it closes idle sockets well before our reuse in a
    // real trace) — that costs a failed round trip before the reactive
    // CodexWsReanchor path kicks in. Close it up front instead. Subtlety: the
    // body was already built while codex_ws was non-null, so a DELTA body
    // (previous_response_id + partial input) is useless on a fresh connection —
    // return error.CodexWsReanchor so request()'s rebuild: loop rebuilds full
    // input. A non-delta body is self-contained: just fall through and dial.
    //
    // …and the liveness half of the same decision (wsReusable): a socket some
    // earlier path already condemned is never reused, whatever the clock says.
    if (self.codex_ws) |held| {
        const idle = codexWsIdleExpired(nowAwakeMs(self.io), self.codex_ws_used_ms);
        if (idle or !wsReusable(held)) {
            // Both branches hold a SUSPECT socket, so neither may spend a
            // blocking courtesy close frame on it (ws.WsClient.deinit).
            held.dead = true;
            self.closeCodexWs();
            if (self.tracer) |tr| {
                var nbuf: [64]u8 = undefined;
                tr.note("ws", if (idle)
                    std.fmt.bufPrint(&nbuf, "idle > {d}s — re-anchoring with fresh connection", .{@divTrunc(codex_ws_idle_ms, std.time.ms_per_s)}) catch "idle — re-anchoring with fresh connection"
                else
                    "held socket marked dead — re-anchoring with fresh connection");
            }
            if (std.mem.indexOf(u8, body, "\"previous_response_id\"") != null) return error.CodexWsReanchor;
        }
    }
    // Hold ONE WS across the turn's tool loop (codex-style): the first request
    // dials; subsequent requests reuse it and send previous_response_id + delta.
    // The open connection IS the sticky context (no x-codex-turn-state to echo).
    if (self.codex_ws == null) {
        self.codex_ws = connectWatched(gpa, self.io, url, &headers, orig_tio != null) catch |e| {
            if (self.tracer) |tr| tr.note("ws", switch (e) {
                error.StreamStalled => "connect stall",
                error.Interrupted => "esc",
                else => @errorName(e),
            });
            return e;
        };
        self.codex_ws_used_ms = nowAwakeMs(self.io); // fresh socket = fresh idle window (#codex-ws)
        if (self.tracer) |tr| tr.note("ws", "connected");
    } else if (self.tracer) |tr| tr.note("ws", "reuse (delta)");
    const client = self.codex_ws.?;
    // Any error → close + reset the session so the next request re-anchors (fresh
    // WS full history, or SSE fallback via postLive's ws_off path). Never leaks.
    // (#401) …and mark it dead first: deinit's courtesy close frame is another
    // blocking write on a socket that may be exactly what wedged us.
    errdefer {
        if (self.codex_ws) |c| c.dead = true;
        self.closeCodexWs();
    }
    sendFrameWatched(self.io, client, frame, orig_tio != null) catch |e| {
        // No user-facing "stream stalled — ending turn" line here: a send
        // failure is a TRANSPORT failure (HungRequest), which postLive retries
        // on a fresh socket — the turn is not over.
        if (self.tracer) |tr| tr.note("ws", switch (e) {
            error.HungRequest => "send stall",
            error.Interrupted => "esc",
            else => @errorName(e),
        });
        return e;
    };
    // (#401) The note the reported trace was missing. It splits the turn's two
    // halves in the trace: with it, silence after "reuse (delta)" means the
    // FRAME never went out, and silence after this one means the SERVER went
    // quiet — the distinction that made #401 undiagnosable from its trace.
    if (self.tracer) |tr| {
        var nbuf: [48]u8 = undefined;
        tr.note("ws", std.fmt.bufPrint(&nbuf, "sent {d}b — awaiting frames", .{frame.len}) catch "sent — awaiting frames");
    }

    var full: Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    var fbuf: std.ArrayList(u8) = .empty;
    defer fbuf.deinit(gpa);
    // (#401) Frames received for THIS response. The read watchdog's budget is a
    // function of it: before the first frame the model may legitimately reason
    // in silence for minutes (the full stream_stall_ms), but once frames have
    // arrived and stopped, that is a dead socket and http_stall.budgetMs
    // tightens to a quarter (#56). The WS reader used to hardcode "no tokens
    // yet", so it re-armed the FULL 120s budget on every frame and never
    // tightened — the SSE reader has always passed a real signal
    // (agent_stream.zig, partial_text.items.len != 0). That is why #401's
    // mid-stream silence sat for 120s per attempt, ~4 minutes before the SSE
    // latch, against successful turns of 3.6-11.6s.
    var frames_seen: usize = 0;

    stream: while (true) {
        // Race the frame read against the shared idle-stall watchdog so a dead
        // ws can't hang the turn — a deadline surfaces as error.StreamStalled
        // (never a user Esc), handled identically to the SSE path (#134). The
        // budget is re-decided every iteration from frames_seen, so silence
        // AFTER frames tightens to a quarter the way SSE's always has (#401).
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
            rsel.concurrent(.stall, streamStallWatch, .{ self.io, orig_tio != null, frames_seen != 0 }) catch {
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
        // A frame landed: bytes are flowing, so from here silence is a dead
        // socket rather than a thinking model. Counted before the empty-frame
        // skip below — an empty frame is still evidence the peer is alive.
        frames_seen += 1;
        if (frames_seen == 1) if (self.tracer) |tr| tr.note("ws", "first frame");
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
    self.codex_ws_used_ms = nowAwakeMs(self.io); // completed turn — restart the idle window (#codex-ws)
    return full.toOwnedSlice();
}

test "wssUrl: https->wss, http->ws" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("wss://chatgpt.com/backend-api/codex/responses", try wssUrl(a.allocator(), "https://chatgpt.com/backend-api/codex/responses"));
    try std.testing.expectEqualStrings("ws://localhost:1234/x", try wssUrl(a.allocator(), "http://localhost:1234/x"));
}
