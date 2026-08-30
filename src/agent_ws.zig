//! Codex Responses turns over WebSocket. OpenAI's codex prefers ws and
//! falls back to SSE; graff mirrors that. The ws frames carry the SAME event
//! `type`s as the Responses SSE stream (response.output_text.delta,
//! response.completed, …), so each frame is wrapped as a `data: {json}` line
//! and handed to the existing parseResponses/isStreamEnd — the reassembly and
//! completion logic are shared with the SSE path.
//!
//! postLive() is the transport selector called by request(): codex root turns
//! try ws (postResponsesWs), retry one failed WS with a clean full-history
//! re-anchor (a 426 skips it), then latch the prewarmed HTTP client for SSE.
//!
//! Observability (issue #134's ask): every ws lifecycle step is routed to the
//! tracer ("ws" notes: connecting/connected/reuse (delta)/sent Nb/first frame/
//! first output text/completed/send stall/stall/esc/fallback/errors), which
//! lands in the run's file under .graff/traces so an agent can debug a ws turn
//! after the fact; GRAFF_WS_DEBUG=1 additionally dumps the handshake + frames to
//! stderr. The `sent`/`first frame` pair is what makes a hang diagnosable: which
//! of the turn's two halves went quiet is otherwise unrecoverable (#401).

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ws = @import("ws.zig");
const http_headers = @import("http_headers.zig");
const transport_gate = @import("transport_gate.zig");

// #422 slice 1b: this file draws nothing. Wait/cut moments are typed events
// through the sink; the spinner and the ⚠ notices are TuiSink's rendering.
const engine_sink = @import("engine_sink.zig");
const engine_events = @import("engine_events.zig");

const term = @import("term.zig");
const tty = term.tty;

const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const WatchdogFired = http.WatchdogFired;
const deadlineStallTask = http.deadlineStallTask;
const watchdogError = http.watchdogError;

/// (#401) The tokens-flowing classifier: its own module (this file is at the
/// 600-line cap), aliased back so call sites and tests keep naming agent_ws.
const signal = @import("agent_ws_signal.zig");
pub const frameHasOutputText = signal.frameHasOutputText;
pub const TokenSignal = signal.TokenSignal;
const isStreamEnd = @import("agent_stream.zig").isStreamEnd;
const escPressed = Agent.escPressed;
const rawNonblockStdin = Agent.rawNonblockStdin;
const drainSteerStdin = Agent.drainSteerStdin;

/// WS: root Responses turns when enabled and not fallen back this session
/// (codex + xai + Codegraff gateway; Platform OpenAI has no WS endpoint).
pub fn wsEligible(self: *Agent) bool {
    // Provider id is a production filter on top of the spec'd kind/flag
    // algebra: only these providers actually serve a WS endpoint.
    const has_ws = std.mem.eql(u8, self.provider.id, "codex") or std.mem.eql(u8, self.provider.id, "xai") or std.mem.eql(u8, self.provider.id, "codegraff");
    return has_ws and transport_gate.eligible(.{ .kind = self.provider.kind, .is_sub = self.sub, .codex_ws = main_mod.g_codex_ws, .ws_off = self.ws_off, .has_out = self.out != null, .quiet = self.stream_quiet });
}

/// (#codex-ws) Idle limit on the held WS (never reuse a socket the server
/// may have killed; 4 min stays under the observed ~8.5-min server close).
/// GRAFF_CODEX_WS_IDLE_SECS overrides (session_run.zig).
pub var codex_ws_idle_ms: i64 = 4 * std.time.ms_per_min;

/// (#codex-ws) The idle-reanchor decision, pure so the regression test can
/// exercise it without a socket: has the held WS sat unused past the limit?
pub fn codexWsIdleExpired(now_ms: i64, used_ms: i64) bool {
    return now_ms - used_ms > codex_ws_idle_ms;
}

/// Official Responses WS hard cap: one connection stays open ≤ 25 minutes.
pub const ws_lifetime_ms: i64 = 25 * std.time.ms_per_min;
/// Retire a minute early so a turn never STARTS on a socket the server is
/// about to kill mid-response (per-agent clock: codex_ws_opened_ms).
pub const ws_retire_ms: i64 = ws_lifetime_ms - std.time.ms_per_min;

pub fn wsLifetimeExpired(now_ms: i64, opened_ms: i64) bool {
    return opened_ms != 0 and now_ms - opened_ms >= ws_retire_ms;
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
/// fresh socket; the second — or any 426 — latches SSE. Esc/stall propagates.
pub fn postLive(self: *Agent, body: []const u8) ![]u8 {
    // #134/#132 test seam: force a one-shot stall/drop on a live turn so the
    // end-to-end "[response ended early: …]" path (never "[response interrupted
    // by user]") can be exercised without a real provider. Consumed after one use.
    // #56 test seam: a stall/drop on EVERY live attempt (not consumed), so the
    // reconnect budget in agent_request exhausts and the turn ends — exercises the
    // give-up path offline, no network/key needed.
    if (main_mod.g_force_stall_always) {
        emitAbort(self, .stalled, false);
        return error.StreamStalled;
    }
    if (main_mod.g_force_drop_always) {
        emitAbort(self, .dropped, false);
        return error.StreamDropped;
    }
    if (main_mod.g_force_stall_once) {
        main_mod.g_force_stall_once = false;
        emitAbort(self, .stalled, true);
        return error.StreamStalled;
    }
    if (main_mod.g_force_drop_once) {
        main_mod.g_force_drop_once = false;
        emitAbort(self, .dropped, true);
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
        // (#427) A 426 is the server answering authoritatively — it will not
        // upgrade this endpoint — so the ladder's free retry would only redial
        // the same refusal. Latch now (openai/codex: FallbackToHttp).
        const declined = e == error.UpgradeRequired;
        const fallback = declined or wsShouldFallback(self.ws_transport_failures);
        // (#codex-ws) A delta body is anchored to the WS session that just
        // died (HTTP rejects previous_response_id; the response died with the
        // socket) — never replay it over SSE. closeCodexWs's errdefer already
        // reset codex_ws/codex_prev_id/codex_sent_upto by
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
        if (self.tracer) |tr| tr.note("ws", if (declined) "426 upgrade required — using persistent prewarmed SSE for this session" else "transport failed twice — using persistent prewarmed SSE for this session");
        return self.postStream(body);
    };
    self.ws_transport_failures = 0;
    return response;
}

/// (#422 slice 1b) A transport cut becomes a typed event; the sink decides
/// what shows. Ending-turn only (ADR 0021); mid-turn reconnect is silent.
fn emitAbort(self: *Agent, reason: engine_events.StreamAbort, turn_ending: bool) void {
    const cut: engine_events.TransportAbort = .{ .reason = reason, .turn_ending = turn_ending };
    engine_sink.forAgent(self).emit(self.io, .{ .transport_aborted = cut });
}

pub fn wssUrl(arena: std.mem.Allocator, https_url: []const u8) ![]u8 {
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

// The frame-write deadline policy lives in agent_ws_signal.zig (600-line
// cap); aliased back so call sites and tests keep naming agent_ws.
pub const sendDeadlineMs = signal.sendDeadlineMs;

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
/// the output-text budget in postResponsesWs.
///
/// A deadline is error.HungRequest, matching the SSE send+head guard it mirrors
/// (agent_stream.zig): postLive counts it as a transport failure, so it retries
/// a fresh socket and latches SSE on the second — WITHOUT spending the read
/// loop's 2-slot stall budget, which StreamStalled would. Esc is Interrupted.
pub fn sendFrameWatched(io: Io, client: *ws.WsClient, frame: []const u8, poll_stdin: bool) !void {
    const budget = sendDeadlineMs(frame.len, http.head_stall_ms, http.stream_stall_ms);
    const SendDone = union(enum) { sent: ws.Error!void, stall: WatchdogFired };
    var sd_buf: [2]SendDone = undefined;
    var ssel: Io.Select(SendDone) = .init(io, &sd_buf);
    // #56 Fix-B, mirroring the SSE head guard's ASYMMETRY exactly
    // (agent_stream.zig:263-283) rather than hard-failing both arms:
    //   * PAYLOAD spawn failed → fail retryable (HungRequest). Nothing is in
    //     flight, and a bare blocking sendText IS the hang this guard exists
    //     for, so there is nothing to degrade to.
    //   * WATCHDOG spawn failed → DEGRADE: the write is already in flight and
    //     the only exit is to join it. Failing here instead would turn a
    //     momentary Io-pool shortage (a deep subagent fan-out) into two
    //     transport failures and a session-wide SSE latch — where SSE, in the
    //     same situation, simply proceeds.
    ssel.concurrent(.sent, wsSendTask, .{ client, frame }) catch return error.HungRequest;
    ssel.concurrent(.stall, deadlineStallTask, .{ io, poll_stdin, budget }) catch {
        const r = ssel.await() catch |e| { // the send is the only arm running
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
/// Budget: the flat head budget, not sendDeadlineMs — a dial carries no payload
/// to scale by. error.HungRequest, like the send guard: a failed dial is a
/// transport failure (postLive's ws_transport_failures ladder → one fresh retry,
/// then SSE), never a spend against the read loop's stall budget.
pub fn connectWatched(gpa: std.mem.Allocator, io: Io, url: []const u8, headers: []const ws.Header, poll_stdin: bool) !*ws.WsClient {
    const Dialed = union(enum) { dialed: ws.Error!*ws.WsClient, stall: WatchdogFired };
    var dl_buf: [2]Dialed = undefined;
    var dsel: Io.Select(Dialed) = .init(io, &dl_buf);
    // Same #56 Fix-B asymmetry as sendFrameWatched (and the SSE head guard it
    // copies): a failed DIAL spawn is retryable HungRequest with nothing in
    // flight; a failed WATCHDOG spawn degrades to the unwatched dial, because
    // that dial is already running and a pool shortage must not cost a turn.
    dsel.concurrent(.dialed, wsConnectTask, .{ gpa, io, url, headers }) catch return error.HungRequest;
    dsel.concurrent(.stall, deadlineStallTask, .{ io, poll_stdin, http.head_stall_ms }) catch {
        const r = dsel.await() catch |e| { // the dial is the only arm running
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

// (reference parity, openai/codex) A pre-reuse LIVENESS CHECK is deliberately
// NOT implemented; this is the record of why, since the gap is real.
//
// codex-rs asks a pooled connection `is_closed()` before reusing it. That bit
// exists because a BACKGROUND READ PUMP is already draining the socket, so the
// stream end has been observed by the time the next turn asks. graff's ws
// client is synchronous — nothing has touched the socket since the last turn
// ended — so there is no observation to consult, and every substitute is worse
// than the gap:
//
//   * A `dead` flag on the held client is unreachable by construction: every
//     path that sets it destroys the client on the next statement
//     (drainDialSelect, the idle-expiry close, postResponsesWs's errdefer, all
//     funnelling through closeCodexWs, which deinits it and nulls
//     agent.codex_ws). A still-referenced held client can never carry it, so
//     the branch would be dead code claiming to be a check. An earlier round of
//     this fix shipped exactly that; it is deleted rather than left to read
//     like coverage. `dead` keeps its real job: suppressing deinit's blocking
//     courtesy close frame on a socket that already wedged us.
//   * A zero-timeout poll for readability cannot see the case that matters — a
//     peer or LB that BLACKHOLES the socket sends nothing, so the fd looks
//     exactly like a healthy idle one. What it WOULD see is a routine
//     between-turns server ping or a partial TLS record, and read them as
//     "closed", trading a healthy session's prompt-cache anchor for a
//     full-history re-anchor. A false positive here is expensive.
//   * A blocking peek is #401's hang, moved earlier in the turn.
//
// So the held socket is written into on faith and DETECTION is the three
// deadlines this file adds. Stated as the bound it actually is, since an
// earlier round of this note claimed more than it bought:
//
//   * sendFrameWatched bounds the WRITE into a wedged socket (sendDeadlineMs).
//   * On a REUSED socket the read loop's FIRST frame is bounded by
//     head_stall_ms (30s), not the 120s pre-first-token budget, and surfaces as
//     error.HungRequest — the transport ladder (one fresh re-dial with full
//     history, SSE on the second), never a spend against request()'s 2-slot
//     stall budget. The WS analog of the SSE head guard, safe for the same
//     reason frame arrival is a BAD tokens-flowing signal: created/in_progress
//     land within milliseconds of a send, so ZERO frames from a socket we have
//     no handshake for is a dead socket, not a thinking model.
//   * After that first frame the inter-frame budget takes over (full while the
//     model reasons in silence, a quarter once prose has flowed).
//
// So a dead reused socket costs up to 30s of dead air plus a re-anchor, where
// `is_closed()` costs a syscall. Bounded and off the stall budget, not free:
// reference parity on the pre-reuse check itself stays NOT MET.

/// One Responses turn over ws. Returns the reassembled body as SSE-format
/// `data:` lines (parseResponses consumes it unchanged). Connect/transport
/// failures return the ws error so postLive can fall back to SSE.
pub fn postResponsesWs(self: *Agent, body: []const u8) ![]u8 {
    const gpa = self.gpa;
    const arena = self.arena;
    const provider = self.provider;

    const frame = try std.fmt.allocPrint(gpa, "{{\"type\":\"response.create\",{s}", .{body[1..]});
    defer gpa.free(frame);

    const bearer = try std.fmt.allocPrint(arena, "Bearer {s}", .{provider.api_key});
    // ChatGPT tail is codex-only (#502); xAI takes grok-build's affinity
    // pair: x-grok-session-id (durable project) + x-grok-conv-id (root/sub
    // partition, same value as the Responses body's prompt_cache_key).
    var conv_buf: [96]u8 = undefined;
    const conv = http_headers.requestCacheKey(self.io, self.label, self, provider.id, &conv_buf);
    var hdrs: [7]ws.Header = undefined;
    var hn: usize = 1;
    hdrs[0] = .{ .name = "Authorization", .value = bearer };
    if (std.mem.eql(u8, provider.id, "codex")) {
        hdrs[1] = .{ .name = "session_id", .value = conv };
        hdrs[2] = .{ .name = "chatgpt-account-id", .value = provider.account };
        hdrs[3] = .{ .name = "OpenAI-Beta", .value = "responses_websockets=2026-02-06" };
        hdrs[4] = .{ .name = "originator", .value = "codex_cli_rs" };
        hdrs[5] = .{ .name = "User-Agent", .value = "codex_cli_rs/0.1 (graff)" };
        hn = 6;
    } else if (http_headers.wantsGrokConvId(provider.id)) {
        hdrs[1] = .{ .name = "x-grok-session-id", .value = http_headers.projectRootId(self.io) };
        hdrs[2] = .{ .name = "x-grok-conv-id", .value = conv };
        hn = 3;
    }
    const headers: []const ws.Header = hdrs[0..hn];
    const url = try wssUrl(arena, provider.url);

    // Esc watching (root TTY), same gate as postStream.
    const watch_esc = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio: ?tty.RawState = if (watch_esc) rawNonblockStdin() else null;
    defer if (orig_tio) |o| {
        _ = drainSteerStdin(true);
        tty.restore(o);
    };

    // One wait spans the whole ws turn (frames reassemble, never stream live):
    // the same bracket events postStream uses; the wire has no shape for them.
    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .stream_begin);
    defer sink.emit(self.io, .stream_finished);

    if (self.tracer) |tr| tr.note("ws", "connecting");
    // (#codex-ws) Preemptive re-anchor: don't reuse a WS the server likely
    // already killed (idle) or is about to (the 25-min cap) — that costs a
    // failed round trip before the reactive path. A DELTA body is useless on
    // a fresh connection, so return CodexWsReanchor for request()'s rebuild;
    // a full body falls through and dials. This clock is the only pre-send
    // gate (no is_closed() equivalent; the deadlines cover the rest).
    if (self.codex_ws) |held| {
        const now = nowAwakeMs(self.io);
        if (codexWsIdleExpired(now, self.codex_ws_used_ms) or wsLifetimeExpired(now, self.codex_ws_opened_ms)) {
            // The premise of this branch is that the server has likely already
            // killed this socket, so it is SUSPECT: it must not spend a blocking
            // courtesy close frame on it (ws.WsClient.deinit).
            held.dead = true;
            self.closeCodexWs();
            if (self.tracer) |tr| {
                var nbuf: [64]u8 = undefined;
                tr.note("ws", std.fmt.bufPrint(&nbuf, "idle > {d}s — re-anchoring with fresh connection", .{@divTrunc(codex_ws_idle_ms, std.time.ms_per_s)}) catch "idle — re-anchoring with fresh connection");
            }
            if (std.mem.indexOf(u8, body, "\"previous_response_id\"") != null) return error.CodexWsReanchor;
        }
    }
    // Hold ONE WS across the turn's tool loop (codex-style): the first request
    // dials; subsequent requests reuse it and send previous_response_id + delta.
    // session_id matches prompt_cache_key (openai/codex ModelClient default).
    //
    // (#401) …and which of the two it is decides the FIRST-frame budget below: a
    // socket dialed just now finished a TLS + upgrade handshake milliseconds
    // ago, so the peer is known live and a long silence is the model thinking. A
    // socket held since the last request has proved nothing since.
    const reused = self.codex_ws != null;
    if (self.codex_ws == null) {
        self.codex_ws = connectWatched(gpa, self.io, url, headers, orig_tio != null) catch |e| {
            // HungRequest, matching connectWatched's deadline error — NOT
            // StreamStalled, which the guard stopped returning when it moved to
            // the SSE guard's transport-flake semantics. An arm naming the wrong
            // error is unreachable, and a stalled dial then traces a bare
            // "HungRequest" instead of saying the dial is where it stalled (the
            // observability #401 was filed about).
            if (self.tracer) |tr| tr.note("ws", switch (e) {
                error.HungRequest => "connect stall",
                error.Interrupted => "esc",
                else => @errorName(e),
            });
            return e;
        };
        self.codex_ws_opened_ms = nowAwakeMs(self.io); // 25-min server cap starts now
        self.codex_ws_used_ms = self.codex_ws_opened_ms; // fresh socket = fresh idle window (#codex-ws)
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
    // (#401) Frames received for THIS response: the "first frame" trace note
    // that splits a hung turn into its two halves, and the head-budget gate
    // below. It is NOT the tokens-flowing signal — see TokenSignal.
    var frames_seen: usize = 0;
    // (#401) …and, separately, whether VISIBLE PROSE has arrived — THIS is what
    // the read watchdog's budget keys on. Before the first token the model may
    // reason in silence for minutes (the full stream_stall_ms); once prose has
    // flowed and stopped, that is a dead socket and http_stall.budgetMs tightens
    // to a quarter (#56). The WS reader used to hardcode "no tokens yet", re-arming
    // the FULL 120s budget on every frame — why #401's mid-stream silence sat for
    // 120s per attempt, ~4 minutes before the SSE latch, against successful turns
    // of 3.6-11.6s. TokenSignal mirrors BOTH of the SSE reader's producers.
    var sig: TokenSignal = .{};
    var text_seen = false;

    stream: while (true) {
        // Race the frame read against a stall watchdog so a dead ws can't hang
        // the turn (#134), on a budget re-decided every iteration:
        //
        //   * REUSED socket, no frame yet → the head budget, as HungRequest.
        //     Nothing has proved this peer alive since the last turn, and the
        //     backend answers a send with response.created / in_progress within
        //     milliseconds, so zero frames is a dead socket, not a thinking
        //     model. HungRequest keeps it on postLive's transport ladder (one
        //     fresh re-dial, then SSE) instead of spending a slot of request()'s
        //     2-slot stall budget — the SSE head guard's contract for "sent,
        //     nothing came back". A FRESH connect skips this: its handshake just
        //     proved liveness, so it keeps the full pre-first-token budget.
        //   * otherwise → the inter-frame budget: full stream_stall_ms after
        //     protocol frames (encrypted thinking), a quarter once prose flowed.
        //     http_stall.budgetMs is what streamStallWatch asks the SSE reader's
        //     budget of on every tick; it cannot change mid-wait, so deciding it
        //     here is equivalent and lets both regimes share one watchdog arm.
        read: {
            const head_wait = reused and frames_seen == 0;
            const budget = if (head_wait) http.head_stall_ms else http_stall.interFrameBudgetMs(http.stream_stall_ms, frames_seen > 0, text_seen, self.stall.widen);
            const ReadDone = union(enum) { msg: ws.Error!ws.Opcode, stall: WatchdogFired };
            var rd_buf: [2]ReadDone = undefined;
            var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
            rsel.concurrent(.msg, wsReadTask, .{ client, gpa, &fbuf }) catch {
                // #56 Fix-B: pool exhausted — mirror the SSE line-read fail-safe. A bare
                // blocking readMessage can hang forever on a half-open ws with no
                // watchdog; end the turn as StreamStalled (never a hang, never a user
                // Esc), exactly as the .deadline arm below does.
                emitAbort(self, .stalled, false);
                if (self.tracer) |tr| tr.note("ws", "stall");
                return error.StreamStalled;
            };
            rsel.concurrent(.stall, deadlineStallTask, .{ self.io, orig_tio != null, budget }) catch {
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
                .stall => |w| if (head_wait) {
                    // A reused socket that answered NOTHING is a transport
                    // failure, not the end of the turn: no user-facing "ending
                    // turn" line (postLive retries a fresh socket, as for a send
                    // stall), and HungRequest so the ladder pays, not the budget.
                    if (self.tracer) |tr| tr.note("ws", if (w == .esc) "esc" else "reuse dead — no first frame");
                    return watchdogError(w, error.HungRequest);
                } else {
                    // Only the deadline gets a notice; a user Esc stays silent.
                    if (w == .deadline) self.stall.tripped_ms = budget; // #680: the turn-ending message reports THIS wait
                    if (w == .deadline) emitAbort(self, .stalled, false);
                    if (self.tracer) |tr| tr.note("ws", if (w == .esc) "esc" else "stall");
                    return watchdogError(w, error.StreamStalled);
                },
            }
        }
        // A frame landed: the peer is alive, which retires the head budget — but
        // it is NOT the tokens-flowing signal (the first frames of a turn are
        // protocol events that arrive before the model has thought). Counted
        // before the empty-frame skip: an empty frame is still evidence too.
        frames_seen += 1;
        if (frames_seen == 1) if (self.tracer) |tr| tr.note("ws", "first frame");
        if (fbuf.items.len == 0) continue :stream;
        // …and THIS is the budget signal: visible prose, from EITHER event that
        // grows partial_text on SSE — an output-text delta, or the streamed
        // arguments of a whitelisted meta call (attempt_completion / ask_user),
        // which is all a final-answer turn emits. Fed every frame until it
        // fires (output_item.added/done open and close the tracked call).
        if (!text_seen and sig.flowing(gpa, fbuf.items)) {
            text_seen = true;
            self.traceFirstToken();
            if (self.tracer) |tr| tr.note("ws", "first output text — tightening stall budget");
        }

        // Wrap the ws frame as an SSE data: line so parseResponses/isStreamEnd
        // (shared with the SSE path) handle reassembly + completion.
        try full.writer.writeAll("data: ");
        try full.writer.writeAll(fbuf.items);
        try full.writer.writeByte('\n');
        const line = try std.fmt.allocPrint(arena, "data: {s}", .{fbuf.items});
        // xAI error frames are terminal but not in isStreamEnd's set. Both
        // arms route through postLive's close + redial (resets chain state).
        switch (signal.errorFrameAction(fbuf.items)) {
            .none => {},
            .retire, .chain_lost => |act| {
                if (self.tracer) |tr| tr.note("ws", if (act == .retire) "server connection limit — retiring socket" else "chain anchor gone — re-anchoring full");
                return error.ConnectionResetByPeer;
            },
        }
        if (isStreamEnd(arena, self.provider.kind, line)) {
            if (self.tracer) |tr| tr.note("ws", "completed");
            break :stream;
        }
        if (orig_tio != null and escPressed(true)) return error.Interrupted;
    }
    self.traceFirstToken(); // tool-only responses fall back to completion time
    self.codex_ws_used_ms = nowAwakeMs(self.io); // completed turn — restart the idle window (#codex-ws)
    return full.toOwnedSlice();
}
