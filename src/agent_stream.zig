//! The live streaming path: postStream — the root agent's streaming POST,
//! racing send/receive/read against stall watchdogs — and printDelta, which
//! turns SSE lines into the semantic deltas a frontend renders. The highest-
//! entanglement piece of the Agent struct (#123, 600-line goal); extracted
//! last, after agent_request/agent_steps/agent_argstream/agent_render/
//! agent_interrupt so it can sibling-import them directly.
//!
//! #422: this file draws nothing. The spinner and the live "Thinking" block
//! live in agent_stream_render.zig (reached through Agent member aliases);
//! term.zig/agent_render.zig/ansi.zig/anim.zig must never be imported here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

const engine_sink = @import("engine_sink.zig"); // #422: every emission goes through the sink

const reasoningDelta = @import("title.zig").reasoningDelta;
const stream_tests = @import("agent_stream_tests.zig");

const http = @import("http.zig");
const http_headers = @import("http_headers.zig");
const providerUserAgent = http.providerUserAgent;
const capture5xxBodyStream = http.capture5xxBodyStream;
const WatchdogFired = http.WatchdogFired;
const sendHeadTask = http.sendHeadTask;
const headStallTask = http.headStallTask;
const streamLineTask = http.streamLineTask;
const streamStallWatch = http.streamStallWatch;
const watchdogError = http.watchdogError;

// escPressed/drainSteerStdin/rawNonblockStdin/restoreStdin/ssePayload live in
// agent_interrupt.zig; reached through the Agent struct's member aliases.
const escPressed = Agent.escPressed;
const drainSteerStdin = Agent.drainSteerStdin;
const rawNonblockStdin = Agent.rawNonblockStdin;
const restoreStdin = Agent.restoreStdin;
const ssePayload = Agent.ssePayload;

pub fn postStream(self: *Agent, body: []const u8) ![]u8 {
    return postStreamWithClient(self, self.client, body);
}

/// SSE stream using an explicit HTTP client. Normal traffic uses the Agent's
/// shared pool; a WebSocket failure supplies a fresh client so a stale pooled
/// keep-alive cannot poison the WS→SSE handoff and every fallback retry dials
/// from a clean pool.
pub fn postStreamWithClient(self: *Agent, client: *std.http.Client, body: []const u8) ![]u8 {
    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .stream_begin);
    // Every exit path — success, interrupt, transport error — tears down the
    // live-stream presentation (spinner, a reasoning-only turn's open block).
    defer sink.emit(self.io, .stream_finished);
    // Per-stream frontend bookkeeping still lives on the Agent in #422 slice 1
    // (TuiSink wraps it); the resets are state hygiene, not emissions, and run
    // for every mode exactly as before — emitArgText can dirty the markdown
    // state even when this stream's deltas go to the wire.
    self.thinking_open = false; // fresh "Thinking" block state per request
    main_mod.g_thinking_open = false;
    self.thinking_rows = 0;
    self.thinking_col = 0;
    self.thinking_folded = false;
    self.thinking_text.clearRetainingCapacity();
    self.thinking_overflow = false;
    const gpa = self.gpa;
    const provider = self.provider;
    const bearer = switch (provider.auth) {
        .x_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);
    var headers_buf: [12]std.http.Header = undefined;
    var conv_buf: [96]u8 = undefined;
    const conv = http_headers.promptCacheKey(self.io, self.label, self, &conv_buf);
    const extra = http_headers.providerHeadersWithConv(self.io, provider, bearer, &headers_buf, conv);

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

    // Esc-interrupt: while the root's request is on a TTY, stdin sits in raw
    // non-blocking no-echo mode — from *before* the connect, so Esc pressed
    // during a slow time-to-first-token wait neither echoes ^[ nor leaks into
    // the next prompt. Polled between SSE lines; leftover bytes are drained
    // before canonical mode returns, so gate prompts and the line editor see a
    // clean tty. SGR mouse reporting is deliberately NOT enabled: grabbing the
    // mouse (\x1b[?1000;1006h) forwards wheel events to us instead of letting
    // the terminal scroll its own scrollback — native scroll wins, and Ctrl-T
    // still folds the live Thinking block (escPressed).
    const watch_esc = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio = if (watch_esc) rawNonblockStdin() else null;
    defer if (orig_tio) |o| {
        _ = drainSteerStdin(true);
        restoreStdin(o);
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
        http.captureRetryAfter(&response); // #retry-after: honor the provider's requested backoff
        // Drain a snippet of the error body so the retry message surfaces the
        // gateway's diagnostic instead of a bare "server error (5xx)".
        capture5xxBodyStream(self.gpa, &response);
        if (req.connection) |conn| conn.closing = true;
        return if (status_code == 429) error.RateLimited else error.ServerError;
    }
    // #opencode-parity: OpenAI proper spuriously 404s available models — retry a
    // 404 from an openai-* provider like a 5xx instead of hard-failing the turn.
    if (status_code == 404 and std.mem.startsWith(u8, self.provider.id, "openai")) {
        capture5xxBodyStream(self.gpa, &response);
        if (req.connection) |conn| conn.closing = true;
        return error.OpenAiFlaky404;
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
        // Race the line read against an idle-stall watchdog so a dead stream can't
        // hang the turn (the Esc escape below is TTY-only, so --json/GUI sessions
        // would otherwise wait forever). #56: a non-empty partial_text (cleared per
        // stream above) means tokens already flowed, so the silence trips sooner.
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
                sink.emit(self.io, .{ .stream_aborted = .stalled });
                if (req.connection) |conn| conn.closing = true;
                return error.StreamStalled;
            };
            rsel.concurrent(.stall, streamStallWatch, .{ self.io, orig_tio != null, self.partial_text.items.len != 0 }) catch {
                const r = rsel.await() catch |e| {
                    rsel.cancelDiscard();
                    return e;
                };
                rsel.cancelDiscard();
                _ = r.line catch |e| {
                    if (saw_done and readErrIsClose(e)) break :stream;
                    if (got_body and readErrIsClose(e)) {
                        sink.emit(self.io, .{ .stream_aborted = .dropped });
                        return error.StreamDropped;
                    } // #133
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
                    if (got_body and readErrIsClose(e)) {
                        sink.emit(self.io, .{ .stream_aborted = .dropped });
                        return error.StreamDropped;
                    } // #133: closed before the terminal event
                    return e;
                },
                .stall => |w| {
                    // A user Esc is a deliberate cancel; a `.deadline` is a dead or
                    // idle stream (silent past this read's budget) — end the turn as
                    // error.StreamStalled so it is never recorded as "[response
                    // interrupted by user]" (#134). Only the deadline gets a notice.
                    sink.emit(self.io, .{ .stream_aborted = if (w == .deadline) .stalled else .interrupted });
                    if (req.connection) |conn| conn.closing = true;
                    return watchdogError(w, error.StreamStalled);
                },
            }
        }
        // End of stream leaves the reader empty; otherwise the '\n' is
        // still buffered (and consumed below, after the line is handled).
        const more = if (reader.peekByte()) |_| true else |_| false;
        try full.writer.writeAll(line.writer.buffered());
        try full.writer.writeByte('\n');
        got_body = true; // #134: response bytes are in `full`; a later read error is a clean close
        self.printDelta(line.writer.buffered());
        if (main_mod.g_thinking_fold_request) {
            main_mod.g_thinking_fold_request = false;
            sink.emit(self.io, .thinking_fold_toggle);
        }
        // Logical stream terminator: once the provider's final event ([DONE] /
        // response.completed / message_stop) lands in `full` the response is
        // complete — stop instead of waiting for a socket some gateways hold
        // open (or reset), which otherwise trips the 120s idle-stall watchdog or
        // a spurious retry on an already-complete response (#134/#135). #133: a
        // finish_reason chunk completes the response even without [DONE] — note
        // it so a later close is clean, but keep reading for a usage chunk.
        if (self.provider.kind == .openai and openaiComplete(line.writer.buffered())) saw_done = true;
        if (isStreamEnd(self.scratchAlloc(), self.provider.kind, line.writer.buffered())) { // #124: parse tree is a transient bool check
            saw_done = true; // #133: the provider's terminal event landed — a later close is clean
            if (req.connection) |conn| conn.closing = true;
            break :stream;
        }
        line.clearRetainingCapacity();
        if ((orig_tio != null and escPressed(true)) or (self.sub and Agent.esc_cancel.load(.acquire))) {
            sink.emit(self.io, .{ .stream_aborted = .interrupted });
            // Mark the connection closing so req.deinit() tears it down
            // instead of draining the rest of the stream (which would
            // block until the model finished generating anyway). Subs get
            // here via Agent.esc_cancel: the root saw Esc during a tool join.
            if (req.connection) |conn| conn.closing = true;
            return error.Interrupted;
        }
        if (!more) break;
        reader.toss(1);
    }
    sink.emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
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
    try stream_tests.streamEnd(isStreamEnd);
}

test "openaiComplete (#133): finish_reason marks completion, deltas do not" {
    try stream_tests.openaiCompletion(openaiComplete);
}

/// Extract the user-visible content from one SSE line and dispatch it as
/// typed events through the sink. Best-effort: parse failures are ignored
/// (the buffered body is parsed afterwards).
pub fn printDelta(self: *Agent, raw_line: []const u8) void {
    if (self.out == null and self.sink == null) return; // pool-thread subagents have no frontend: skip (ACP installs a sink with out=null)
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
    // a thinking_delta, codex a summary delta. Presentation is the sink's call:
    // the wire's `reasoning` event, or the live "Thinking" block / spinner.
    const sink = engine_sink.forAgent(self);
    const reasoning = reasoningDelta(self.provider.kind, obj);
    if (reasoning.len != 0) sink.emit(self.io, .{ .reasoning_delta = .{ .text = reasoning } });
    if (text.len == 0) return;
    self.streamed_text = true;
    self.partial_text.appendSlice(self.arena, text) catch {}; // Esc-interrupt capture
    sink.emit(self.io, .{ .text_delta = .{ .text = text } });
}
