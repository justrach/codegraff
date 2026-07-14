//! The live streaming path: the thinking spinner (spinnerTask/Start/Stop,
//! an animated indicator while the model is silent), the live dimmed
//! "Thinking" reasoning block (streamThinking/closeThinkingBlock/
//! toggleThinkingFold), and postStream itself — the root agent's
//! streaming POST, racing send/receive/read against stall watchdogs,
//! printing text deltas (printDelta) as they arrive. The highest-
//! entanglement piece of the Agent struct (#123, 600-line goal); extracted
//! last, after agent_request/agent_steps/agent_argstream/agent_render/
//! agent_interrupt so it can sibling-import them directly.
//!
//! Agent.g_spin_stop/Agent.g_spin_future are struct-level `pub var`s that stay
//! declared directly inside the Agent struct in main.zig (never alias a
//! `var`) — reached here as `Agent.Agent.g_spin_stop`/`Agent.Agent.g_spin_future`.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const anim = @import("anim.zig");

const terminal = @import("term.zig");
const tty = terminal.tty;
const termCols = terminal.termCols;
const termRows = terminal.termRows;
const advanceThinkingRows = terminal.advanceThinkingRows;

const title_mod = @import("title.zig");
const reasoningDelta = title_mod.reasoningDelta;

const http = @import("http.zig");
const providerUserAgent = http.providerUserAgent;
const providerHeaders = http.providerHeaders;
const capture5xxBodyStream = http.capture5xxBodyStream;
const WatchdogFired = http.WatchdogFired;
const sendHeadTask = http.sendHeadTask;
const headStallTask = http.headStallTask;
const streamLineTask = http.streamLineTask;
const streamStallTask = http.streamStallTask;
const watchdogError = http.watchdogError;

// escPressed/drainSteerStdin/rawNonblockStdin/ssePayload live in
// agent_interrupt.zig; reached through the Agent struct's member aliases.
const escPressed = Agent.escPressed;
const drainSteerStdin = Agent.drainSteerStdin;
const rawNonblockStdin = Agent.rawNonblockStdin;
const ssePayload = Agent.ssePayload;

pub fn spinnerTask(io: Io) void {
    var i: usize = 0;
    var buf: [512]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    while (!Agent.g_spin_stop.load(.acquire)) {
        if (main_mod.g_steer_visible.load(.acquire)) {
            io.sleep(.fromMilliseconds(20), .awake) catch break;
            continue;
        }
        // Clear-then-draw each frame: animations may vary in width.
        w.interface.writeAll("\r\x1b[2K\x1b[?7l") catch return; // ?7l: autowrap off so a wide spinner truncates instead of wrapping in a narrow window (the "goes on and on" bug)
        anim.anims[anim.g_anim_current].frame(&w.interface, i) catch return;
        w.interface.writeAll("\x1b[?7h") catch return; // restore autowrap
        w.interface.flush() catch return;
        i += 1;
        var t: usize = 0;
        while (t < 4 and !Agent.g_spin_stop.load(.acquire)) : (t += 1) {
            if (main_mod.g_steer_visible.load(.acquire)) break;
            io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
    }
    if (!main_mod.g_steer_visible.load(.acquire)) {
        w.interface.writeAll("\x1b[?7h\r\x1b[2K") catch return; // restore autowrap + clear
        w.interface.flush() catch {};
    }
}

pub fn spinnerStart(self: *Agent) void {
    if (self.sub or main_mod.json_mode or !main_mod.use_color or self.out == null) return;
    if (anim.g_anim_off) return;
    if (Agent.g_spin_future != null) return;
    anim.selectSpinner(self.io);
    Agent.g_spin_stop.store(false, .release);
    Agent.g_spin_future = self.io.concurrent(spinnerTask, .{self.io}) catch blk: {
        Agent.g_spin_stop.store(true, .release); // no spare concurrency: skip quietly
        break :blk null;
    };
}

pub fn spinnerStop(self: *Agent) void {
    if (self.sub) return; // root-only state — subs run on pool threads
    if (Agent.g_spin_future) |*f| {
        Agent.g_spin_stop.store(true, .release);
        f.await(self.io);
        Agent.g_spin_future = null;
    }
}

/// Stream a chunk of the model's reasoning into a live, dimmed "Thinking"
/// block in the terminal, opening the block (and handing the line off from
/// the spinner) on the first chunk. Gated by /thinking; when off the block is
/// never opened and the spinner stands in for it. We track the block's
/// on-screen height as it streams so closeThinkingBlock can collapse it to a
/// one-line summary when the answer starts (#75).
pub fn streamThinking(self: *Agent, chunk: []const u8) void {
    const w = self.out orelse return;
    if (!self.thinking_open) {
        self.spinnerStop();
        w.print("{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
        self.thinking_open = true;
        main_mod.g_thinking_open = true;
        self.thinking_rows = 1; // the header newline already moved us down one line
        self.thinking_col = 0;
        self.thinking_overflow = false;
    }
    self.thinking_text.appendSlice(self.gpa, chunk) catch {};
    if (self.thinking_folded) return; // folded: buffer only, don't draw the live block
    w.writeAll(chunk) catch return;
    w.flush() catch return;
    advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), chunk);
    if (self.thinking_rows + 1 >= termRows()) self.thinking_overflow = true;
}

/// Close an open "Thinking" block. If it still fits on screen, collapse it in
/// place to a one-line "Thought" summary (#75); if it has scrolled off
/// (overflow) leave the reasoning and just append the summary, so we never
/// erase the user's earlier output. Runs on the reasoning->answer transition
/// and at stream end.
pub fn closeThinkingBlock(self: *Agent) void {
    if (!self.thinking_open) return;
    self.thinking_open = false;
    main_mod.g_thinking_open = false;
    self.thinking_folded = false;
    const w = self.out orelse return;
    if (!self.thinking_overflow and self.thinking_rows >= 1 and main_mod.use_color) {
        w.print("\x1b[{d}F\x1b[0J{s}✓ Thought{s}\n\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
    } else {
        w.print("{s}\n{s}✓ Thought{s}\n\n", .{ style.reset, style.dim, style.reset }) catch return;
    }
    w.flush() catch return;
}

/// Ctrl-T: fold/unfold the live "Thinking" block in place (#92/#85). Only
/// acts on an open, on-screen block; folding erases it to a one-line marker,
/// unfolding re-streams the buffered reasoning. Cursor math mirrors
/// closeThinkingBlock (erase `thinking_rows` lines up, clear to end).
pub fn toggleThinkingFold(self: *Agent) void {
    if (!self.thinking_open or self.thinking_overflow or !main_mod.use_color) return;
    const w = self.out orelse return;
    if (!self.thinking_folded) {
        w.print("\x1b[{d}F\x1b[0J{s}▶ Thinking (folded · ^T){s}\n", .{ self.thinking_rows, style.dim, style.reset }) catch return;
        self.thinking_folded = true;
        self.thinking_rows = 1;
        self.thinking_col = 0;
    } else {
        w.print("\x1b[1F\x1b[0J{s}▼ Thinking{s}\n{s}", .{ style.dim, style.reset, style.dim }) catch return;
        self.thinking_folded = false;
        self.thinking_rows = 1;
        self.thinking_col = 0;
        w.writeAll(self.thinking_text.items) catch return;
        advanceThinkingRows(&self.thinking_rows, &self.thinking_col, termCols(), self.thinking_text.items);
    }
    w.flush() catch return;
}

pub fn postStream(self: *Agent, body: []const u8) ![]u8 {
    return postStreamWithClient(self, self.client, body);
}

/// SSE stream using an explicit HTTP client. Normal traffic uses the Agent's
/// shared pool; a WebSocket failure supplies a fresh client so a stale pooled
/// keep-alive cannot poison the WS→SSE handoff and every fallback retry dials
/// from a clean pool.
pub fn postStreamWithClient(self: *Agent, client: *std.http.Client, body: []const u8) ![]u8 {
    self.spinnerStart();
    defer self.spinnerStop();
    self.thinking_open = false; // fresh "Thinking" block state per request
    main_mod.g_thinking_open = false;
    self.thinking_rows = 0;
    self.thinking_col = 0;
    self.thinking_folded = false;
    self.thinking_text.clearRetainingCapacity();
    self.thinking_overflow = false;
    defer self.closeThinkingBlock(); // close a reasoning-only turn's block
    const gpa = self.gpa;
    const provider = self.provider;
    const bearer = switch (provider.auth) {
        .x_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);
    var headers_buf: [6]std.http.Header = undefined;
    const extra = providerHeaders(provider, bearer, &headers_buf);

    self.md_buf.clearRetainingCapacity(); // fresh markdown state per stream
    self.arg_live = .{}; // fresh tool-argument extractor per stream
    self.md_fence = false;
    self.md_kind = .classify;
    self.md_span = .normal;
    self.md_word.clearRetainingCapacity();
    self.md_word_vis = 0;
    self.md_col = 0;
    self.md_indent = 0;
    self.md_width = 0; // re-read the terminal width (resizes)
    for (self.md_table.items) |r| gpa.free(r); // an errored stream can leave rows behind
    self.md_table.clearRetainingCapacity();
    self.partial_text.clearRetainingCapacity(); // fresh Esc-interrupt capture

    // Esc-interrupt: while the root's request is on a TTY, stdin sits in
    // raw non-blocking no-echo mode — from *before* the connect, so Esc
    // pressed during a slow time-to-first-token wait neither echoes ^[
    // nor leaks into the next prompt. Polled between SSE lines; leftover
    // bytes are drained before canonical mode returns, so gate prompts
    // and the line editor see a clean tty.
    const watch_esc = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    var orig_tio: ?tty.RawState = null;
    if (watch_esc) {
        orig_tio = rawNonblockStdin();
        // SGR mouse reporting is intentionally NOT enabled. Grabbing the mouse
        // (\x1b[?1000;1006h) makes the terminal forward wheel events to us instead
        // of scrolling its own scrollback, so scrolling up mid-stream got captured
        // as input. Leaving the mouse to the terminal keeps native scroll — parity
        // with Claude Code. The live Thinking block still folds via Ctrl-T (see
        // escPressed); its SGR click-to-fold path stays wired but dormant.
    }
    defer if (orig_tio) |o| {
        _ = drainSteerStdin(true);
        tty.restore(o);
    };
    var req = try client.request(.POST, try std.Uri.parse(provider.url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .user_agent = providerUserAgent(provider),
        },
        .extra_headers = extra,
    });
    defer req.deinit();
    // A failed SEND leaves reader.state == .ready, which Request.deinit
    // reads as "connection still clean" and returns it to the keep-alive
    // pool — every retry (and every later turn) then pulls the same dead
    // connection back out: HttpConnectionClosing once, WriteFailed
    // forever after (observed in the wild). Poison it on any error so
    // deinit discards it and the retry dials fresh.
    errdefer if (req.connection) |conn| {
        conn.closing = true;
    };
    // Race the send + head receive against a stall watchdog so a
    // freshly-redialed connection that the server accepts but never
    // answers can't hang the turn (issue #54: "retrying (1/3)" then
    // "thinking… forever"). Mirrors the SSE line-loop and postWatched
    // patterns. Falls back to a bare send+receiveHead (the old behavior)
    // when no spare concurrency exists.
    var response: std.http.Client.Response = undefined;
    head: {
        const HeadDone = union(enum) { sent: anyerror!void, stall: WatchdogFired };
        var hd_buf: [2]HeadDone = undefined;
        var hsel: Io.Select(HeadDone) = .init(self.io, &hd_buf);
        hsel.concurrent(.sent, sendHeadTask, .{ &req, body, &response }) catch {
            // #56 Fix-B: Io pool exhausted (deep subagent fan-out saturated the
            // thread pool) — we can't spawn the head-stall watchdog. A bare
            // send+receiveHead here could hang forever on a half-open socket with
            // nothing to trip it. Nothing has streamed yet, so fail safe: poison the
            // connection and return a retryable HungRequest so request() backs off
            // and redials once a pool slot frees, instead of blocking the turn.
            if (req.connection) |conn| conn.closing = true;
            return error.HungRequest;
        };
        hsel.concurrent(.stall, headStallTask, .{ self.io, orig_tio != null }) catch {
            const r = hsel.await() catch |e| {
                hsel.cancelDiscard();
                return e;
            };
            hsel.cancelDiscard();
            r.sent catch |e| {
                return e;
            };
            break :head;
        };
        const first = hsel.await() catch |e| {
            hsel.cancelDiscard();
            return e;
        };
        hsel.cancelDiscard();
        switch (first) {
            .sent => |s| s catch |e| {
                return e;
            },
            .stall => |w| {
                if (req.connection) |conn| conn.closing = true;
                return watchdogError(w, error.HungRequest);
            },
        }
    }

    // 429/5xx before any body: a retryable throttle — request() backs
    // off and retries (surfaced in the trace as a "retry" note).
    const status_code = @intFromEnum(response.head.status);
    if (status_code == 429 or status_code >= 500) {
        // Drain a snippet of the error body so the retry message can
        // surface the gateway's diagnostic (e.g. "upstream timeout")
        // instead of a bare "server error (5xx)".
        capture5xxBodyStream(self.gpa, &response);
        if (req.connection) |conn| conn.closing = true;
        return if (status_code == 429) error.RateLimited else error.ServerError;
    }
    // Esc pressed while connecting / waiting for headers? Stop before
    // reading any of the body.
    if (orig_tio != null and escPressed(true)) {
        if (req.connection) |conn| conn.closing = true;
        return error.Interrupted;
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len > 0) gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var full: Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    var line: Io.Writer.Allocating = .init(gpa);
    var got_body = false; // #134: true once response bytes have been received (gates the post-completion read-error handling)
    var saw_done = false; // #133: true only once the provider's terminal event landed — a close before this is a drop, not a clean end
    defer line.deinit();

    stream: while (true) {
        // Race the line read against an idle-stall watchdog so a dead
        // stream can't hang the turn (the Esc escape below is TTY-only, so
        // --json/GUI sessions would otherwise wait forever).
        read: {
            const ReadDone = union(enum) { line: anyerror!usize, stall: WatchdogFired };
            var rd_buf: [2]ReadDone = undefined;
            var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
            rsel.concurrent(.line, streamLineTask, .{ reader, &line.writer }) catch {
                // #56 Fix-B: pool exhausted — no idle-stall watchdog for this read.
                // A bare blocking streamDelimiterEnding here is the last forever-hang:
                // on a half-open socket it never returns and nothing can trip it. Fail
                // safe with the SAME outcome as a watchdog deadline — if the terminal
                // event already landed the response is complete (clean end); otherwise
                // flush the partial, poison, and end the turn as StreamStalled (never a
                // hang, never a mislabeled StreamDropped or user Esc).
                if (saw_done) break :stream;
                self.flushStreamTail();
                if (!main_mod.json_mode) if (self.out) |o| {
                    o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
                    o.flush() catch {};
                };
                if (req.connection) |conn| conn.closing = true;
                return error.StreamStalled;
            };
            rsel.concurrent(.stall, streamStallTask, .{ self.io, orig_tio != null }) catch {
                const r = rsel.await() catch |e| {
                    rsel.cancelDiscard();
                    return e;
                };
                rsel.cancelDiscard();
                _ = r.line catch |e| {
                    if (saw_done and readErrIsClose(e)) break :stream;
                    if (got_body and readErrIsClose(e)) { noteDropped(self); return error.StreamDropped; } // #133
                    return e;
                };
                break :read;
            };
            const first = rsel.await() catch |e| {
                rsel.cancelDiscard();
                return e;
            };
            rsel.cancelDiscard();
            switch (first) {
                .line => |r| _ = r catch |e| {
                    if (saw_done and readErrIsClose(e)) break :stream; // #134/#135: post-completion close/reset is success, not a retryable flake
                    if (got_body and readErrIsClose(e)) { noteDropped(self); return error.StreamDropped; } // #133: closed before the terminal event
                    return e;
                },
                .stall => |w| {
                    self.flushStreamTail();
                    if (req.connection) |conn| conn.closing = true;
                    // A user Esc is a deliberate cancel; a `.deadline` is a dead
                    // or idle stream (no SSE bytes for stream_stall_ms) — end the
                    // turn, but as error.StreamStalled so it is never recorded as
                    // "[response interrupted by user]" (#134). The notice below is
                    // for the deadline case only (Esc has its own message path).
                    if (w == .deadline and !main_mod.json_mode) if (self.out) |o| {
                        o.writeAll("\n⚠ stream stalled — ending turn\n") catch {};
                        o.flush() catch {};
                    };
                    return watchdogError(w, error.StreamStalled);
                },
            }
        }
        try full.writer.writeAll(line.writer.buffered());
        try full.writer.writeByte('\n');
        got_body = true; // #134: response bytes are in `full`; a later read error is a clean close
        self.printDelta(line.writer.buffered());
        if (main_mod.g_thinking_fold_request) {
            main_mod.g_thinking_fold_request = false;
            self.toggleThinkingFold();
        }
        // Logical stream terminator: once the provider's final event
        // ([DONE] / response.completed / message_stop) has landed in `full`,
        // the response is complete — stop instead of waiting for the socket to
        // close. Some gateways hold the connection open (or reset it) after the
        // last event, which otherwise trips the 120s idle-stall watchdog or a
        // spurious retry on an already-complete response (#134/#135).
        // #133: a finish_reason chunk means the response is complete even if the
        // provider never sends [DONE] — record it so a subsequent close counts
        // as a clean end, but keep reading so a trailing usage chunk still lands.
        if (self.provider.kind == .openai and openaiComplete(line.writer.buffered())) saw_done = true;
        if (isStreamEnd(self.scratchAlloc(), self.provider.kind, line.writer.buffered())) { // #124: parse tree is a transient bool check
            saw_done = true; // #133: the provider's terminal event landed — a later close is clean
            if (req.connection) |conn| conn.closing = true;
            break :stream;
        }
        line.clearRetainingCapacity();
        if ((orig_tio != null and escPressed(true)) or (self.sub and Agent.esc_cancel.load(.acquire))) {
            self.flushStreamTail();
            // Mark the connection closing so req.deinit() tears it down
            // instead of draining the rest of the stream (which would
            // block until the model finished generating anyway). Subs get
            // here via Agent.esc_cancel: the root saw Esc during a tool join.
            if (req.connection) |conn| conn.closing = true;
            return error.Interrupted;
        }
        // "Is there more?" — peek the next byte, then consume the buffered '\n'.
        // Deliberately AFTER the terminal-event break above (#56): once
        // [DONE]/response.completed has landed the turn is complete and we break
        // there, so this peek never runs on a finished response. Peeking then would
        // fill-block forever on a half-open socket (server gone, no FIN) and hang
        // the completed turn — the exact wedge the idle-stall watchdog can't see.
        const more = if (reader.peekByte()) |_| true else |_| false;
        if (!more) break;
        reader.toss(1);
    }
    self.flushStreamTail(); // render any held partial markdown line
    if (!main_mod.json_mode and self.streamed_text) if (self.out) |w| {
        w.writeAll("\n") catch {};
        w.flush() catch {};
    };
    return full.toOwnedSlice();
}

/// A read error once the response body is already flowing is the socket
/// closing or resetting AFTER the model finished — treat it as end-of-stream,
/// not a retryable transport flake (mirrors the non-streaming `post` drain's
/// `catch break`). Before any body arrives it is a real connection failure.
fn readErrIsClose(e: anyerror) bool {
    return e == error.ReadFailed or e == error.EndOfStream;
}

/// #133: a non-null string finish_reason marks an OpenAI-compatible response
/// semantically complete, even when the provider omits the [DONE] sentinel.
/// Content deltas escape their quotes, so this raw substring can only match the
/// real key, never text. Used to set saw_done WITHOUT stopping the read (so a
/// trailing usage-only chunk and [DONE] are still consumed).
fn openaiComplete(raw_line: []const u8) bool {
    const payload = ssePayload(raw_line) orelse return false;
    return std.mem.indexOf(u8, payload, "\"finish_reason\":\"") != null;
}

/// The provider closed/reset the stream before its terminal event landed — the
/// harness is ending the turn, not the user (#133). Flush the partial and tell
/// the user (TTY/plain), so a Moonshot-style mid-reasoning drop can never pass
/// silently as a completed answer.
fn noteDropped(self: *Agent) void {
    self.flushStreamTail();
    if (!main_mod.json_mode) if (self.out) |o| {
        o.writeAll("\n⚠ connection dropped — response ended early\n") catch {};
        o.flush() catch {};
    };
}

/// True if this SSE line is the provider's terminal event — after it no more
/// content comes, so postStream can stop instead of waiting for the socket to
/// close (#134/#135). Precise: matches the `[DONE]` sentinel, a structural
/// `event:` terminator, or a `data:` payload whose PARSED top-level `type` is
/// terminal — never a substring inside a content delta (deltas escape quotes).
pub fn isStreamEnd(arena: std.mem.Allocator, kind: anytype, raw_line: []const u8) bool {
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (std.mem.eql(u8, line, "data: [DONE]") or std.mem.eql(u8, line, "data:[DONE]")) return true;
    if (std.mem.startsWith(u8, line, "event:")) return switch (kind) {
        .anthropic => std.mem.indexOf(u8, line, "message_stop") != null,
        .responses => std.mem.indexOf(u8, line, "response.completed") != null or
            std.mem.indexOf(u8, line, "response.incomplete") != null or
            std.mem.indexOf(u8, line, "response.failed") != null,
        .openai => false,
    };
    const payload = ssePayload(raw_line) orelse return false;
    const candidate = switch (kind) {
        .anthropic => std.mem.indexOf(u8, payload, "message_stop") != null,
        .responses => std.mem.indexOf(u8, payload, "response.completed") != null or
            std.mem.indexOf(u8, payload, "response.incomplete") != null or
            std.mem.indexOf(u8, payload, "response.failed") != null,
        .openai => false,
    };
    if (!candidate) return false;
    const v = std.json.parseFromSliceLeaky(Value, arena, payload, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const ty = v.object.get("type") orelse return false;
    if (ty != .string) return false;
    return switch (kind) {
        .anthropic => std.mem.eql(u8, ty.string, "message_stop"),
        .responses => std.mem.eql(u8, ty.string, "response.completed") or
            std.mem.eql(u8, ty.string, "response.incomplete") or
            std.mem.eql(u8, ty.string, "response.failed"),
        .openai => false,
    };
}

test "isStreamEnd (#134): terminal events detected, content deltas never false-match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Kind = @import("provider.zig").Provider.Kind;
    // OpenAI/Responses [DONE] sentinel; a content delta merely CONTAINING it must not end the stream.
    try std.testing.expect(isStreamEnd(a, Kind.openai, "data: [DONE]"));
    try std.testing.expect(!isStreamEnd(a, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"[DONE]\"}}]}"));
    // Anthropic: event: line and data payload both terminate; a delta with the word does not.
    try std.testing.expect(isStreamEnd(a, Kind.anthropic, "event: message_stop"));
    try std.testing.expect(isStreamEnd(a, Kind.anthropic, "data: {\"type\":\"message_stop\"}"));
    try std.testing.expect(!isStreamEnd(a, Kind.anthropic, "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"message_stop\"}}"));
    // Responses (codex/gpt-5.5): completed/incomplete terminate; an output-text delta does not.
    try std.testing.expect(isStreamEnd(a, Kind.responses, "event: response.completed"));
    try std.testing.expect(isStreamEnd(a, Kind.responses, "data: {\"type\":\"response.completed\"}"));
    try std.testing.expect(isStreamEnd(a, Kind.responses, "data: {\"type\":\"response.incomplete\"}"));
    try std.testing.expect(!isStreamEnd(a, Kind.responses, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"));
    // #133 (openai/kimi): a non-null string finish_reason chunk is terminal (some
    // gateways omit [DONE]); a null finish_reason or a bare reasoning/content
    // delta is NOT — a connection drop after one of those is a StreamDropped, not
    // a clean end.
    try std.testing.expect(!isStreamEnd(a, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!isStreamEnd(a, Kind.openai, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
}

test "openaiComplete (#133): finish_reason marks completion, deltas do not" {
    // non-null finish_reason => complete (even without [DONE]).
    try std.testing.expect(openaiComplete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"));
    try std.testing.expect(openaiComplete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"));
    // mid-stream: null finish_reason or a bare reasoning delta is NOT complete —
    // a connection drop after one of these is the #133 StreamDropped case.
    try std.testing.expect(!openaiComplete("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!openaiComplete("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
    // the substring must not false-match a finish_reason that appears in escaped content.
    try std.testing.expect(!openaiComplete("data: {\"choices\":[{\"delta\":{\"content\":\"\\\"finish_reason\\\":\\\"x\"}}]}"));
}

/// Print the user-visible text from one SSE line, if any. Best-effort:
/// parse failures are ignored (the buffered body is parsed afterwards).
pub fn printDelta(self: *Agent, raw_line: []const u8) void {
    const w = self.out orelse return;
    const payload = ssePayload(raw_line) orelse return;
    const parsed = std.json.parseFromSlice(Value, self.gpa, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    self.argLiveDelta(obj);
    const text: []const u8 = switch (self.provider.kind) {
        .anthropic => blk: {
            const t = obj.get("type") orelse break :blk "";
            if (t != .string or !std.mem.eql(u8, t.string, "content_block_delta")) break :blk "";
            const d = obj.get("delta") orelse break :blk "";
            if (d != .object) break :blk "";
            const dt = d.object.get("type") orelse break :blk "";
            if (dt != .string or !std.mem.eql(u8, dt.string, "text_delta")) break :blk "";
            const x = d.object.get("text") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
        .openai => blk: {
            const choices = obj.get("choices") orelse break :blk "";
            if (choices != .array or choices.array.items.len == 0) break :blk "";
            const c0 = choices.array.items[0];
            if (c0 != .object) break :blk "";
            const d = c0.object.get("delta") orelse break :blk "";
            if (d != .object) break :blk "";
            const x = d.object.get("content") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
        .responses => blk: {
            const t = obj.get("type") orelse break :blk "";
            if (t != .string or !std.mem.eql(u8, t.string, "response.output_text.delta")) break :blk "";
            const x = obj.get("delta") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
    };
    // Reasoning/thinking deltas: deepseek streams reasoning_content, anthropic
    // a thinking_delta, codex a summary delta. JSON clients get a `reasoning`
    // event; on a TTY we stream it into a live, dimmed "Thinking" block when
    // /thinking is enabled, otherwise the spinner stands in for it.
    const reasoning = reasoningDelta(self.provider.kind, obj);
    if (reasoning.len != 0) {
        if (main_mod.json_mode) {
            self.emit(.{ .type = "reasoning", .text = reasoning });
        } else if (self.show_thinking and !self.sub and !self.stream_quiet and main_mod.use_color) {
            self.streamThinking(reasoning);
        }
    }
    if (text.len == 0) return;
    if (self.thinking_open) self.closeThinkingBlock(); // reasoning → answer transition
    self.spinnerStop(); // first visible byte: clear the thinking line
    self.streamed_text = true;
    self.partial_text.appendSlice(self.arena, text) catch {}; // Esc-interrupt capture
    if (main_mod.json_mode) {
        self.emit(.{ .type = "text", .text = text });
    } else if (main_mod.use_color) {
        self.streamMarkdown(text);
    } else {
        w.writeAll(text) catch return;
        w.flush() catch return;
    }
}
