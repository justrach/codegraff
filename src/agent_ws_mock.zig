//! (#401) The loopback WebSocket peer the codex-WS transport tests drive, and
//! the root-shaped Agent pointed at it. Harness only — no tests live here; they
//! live in agent_ws_stall_test.zig (the budgets and the guards) and
//! agent_ws_reuse_test.zig (reuse vs fresh connect). Split out because both
//! files would otherwise carry a copy, and a second copy of a mock server is
//! exactly how two suites start testing different things.
//!
//! Same spirit as the GRAFF_CODEX_URL/lmstudio HTTP mocks: `provider.url` points
//! at 127.0.0.1, and no network, key or provider is used.

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;

pub fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

pub const delta_event = "{\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}";
pub const completed_event = "{\"type\":\"response.completed\"}";

/// What the backend actually puts on the socket in the first milliseconds after
/// a send, before the model has produced anything: the two protocol events, then
/// a reasoning delta. None of these grows partial_text on the SSE path, so none
/// may tighten the WS read budget either.
pub const protocol_events = [_][]const u8{
    "{\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}",
    "{\"type\":\"response.in_progress\",\"response\":{\"id\":\"r1\"}}",
    "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"thinking\"}",
};

/// A codex turn whose whole visible answer is attempt_completion's `result`
/// prose: the model opens the meta call and streams its ARGUMENTS. Not one
/// output_text delta in the turn — on SSE this prints (argLiveDelta →
/// emitArgText → partial_text), so it is tokens-flowing there and must be here.
pub const arg_prose_events = [_][]const u8{
    "{\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}",
    "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"name\":\"attempt_completion\",\"id\":\"fc1\"}}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{\\\"result\\\":\\\"the ans\"}",
    "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"wer is 42\"}",
};

/// How long `slow_first_frame` thinks before its first frame: past a shrunken
/// head budget, inside the pre-first-token budget.
pub var slow_first_frame_ms: i64 = 700;

/// A loopback WebSocket peer with a scripted failure mode.
pub const Mock = struct {
    pub const Mode = enum {
        /// Accept the TCP connection and never answer the upgrade — the dial
        /// that hangs before the 101 status line.
        no_upgrade,
        /// Upgrade, then never read again: the client's frame fills the socket
        /// buffers and its write parks in the kernel.
        never_drain,
        /// Upgrade, take the client's frame, answer with ONE delta frame and
        /// then go permanently silent. This is #401's reported signature: the
        /// turn is under way, data flowed, and the server stopped.
        frame_then_silence,
        /// The healthy control: delta, then response.completed.
        frame_then_complete,
        /// Upgrade, take the client's frame, answer with `protocol_events` and
        /// then go quiet while the model "thinks". Frames flow, none of them is
        /// output text — so the budget must stay at the pre-first-token value.
        protocol_then_silence,
        /// Upgrade, take the client's frame, answer NOTHING — ever. On a REUSED
        /// socket that is the dead-socket signature: the backend acks a send
        /// with response.created within milliseconds, so zero frames means the
        /// peer is gone, not thinking.
        read_then_silence,
        /// Upgrade, take the client's frame, think past the head budget, then
        /// answer normally. A FRESH connect must survive this.
        slow_first_frame,
        /// Upgrade, take the client's frame, stream a whitelisted meta call's
        /// arguments (`arg_prose_events`) and then go silent.
        arg_prose_then_silence,
    };

    pub fn run(io: Io, server: *std.Io.net.Server, mode: Mode, done: *std.atomic.Value(bool)) void {
        const c = server.accept(io) catch return;
        defer c.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
        var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
        if (mode == .no_upgrade) return idle(io, done);

        while (true) {
            const line = sr.interface.takeDelimiterInclusive('\n') catch return idle(io, done);
            if (line.len <= 2) break; // the blank line ends the upgrade request
        }
        sw.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch return idle(io, done);
        sw.interface.flush() catch return idle(io, done);

        switch (mode) {
            .no_upgrade, .never_drain => {},
            .frame_then_silence, .frame_then_complete => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                writeTextFrame(&sw.interface, delta_event) catch return idle(io, done);
                if (mode == .frame_then_complete)
                    writeTextFrame(&sw.interface, completed_event) catch return idle(io, done);
            },
            .protocol_then_silence => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                for (protocol_events) |ev|
                    writeTextFrame(&sw.interface, ev) catch return idle(io, done);
            },
            .read_then_silence => readClientFrame(&sr.interface) catch return idle(io, done),
            .slow_first_frame => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                io.sleep(.fromMilliseconds(slow_first_frame_ms), .awake) catch return idle(io, done);
                writeTextFrame(&sw.interface, delta_event) catch return idle(io, done);
                writeTextFrame(&sw.interface, completed_event) catch return idle(io, done);
            },
            .arg_prose_then_silence => {
                readClientFrame(&sr.interface) catch return idle(io, done);
                for (arg_prose_events) |ev|
                    writeTextFrame(&sw.interface, ev) catch return idle(io, done);
            },
        }
        idle(io, done);
    }

    /// Hold the connection open (and, for never_drain, undrained) until the test
    /// releases it. Closing early hands the client a clean EOF, a different
    /// failure than the silence being reproduced.
    pub fn idle(io: Io, done: *std.atomic.Value(bool)) void {
        while (!done.load(.acquire)) io.sleep(.fromMilliseconds(20), .awake) catch break;
    }

    /// Consume one masked client frame (RFC 6455 §5.2); the payload is ignored.
    pub fn readClientFrame(r: *Io.Reader) !void {
        const h = try r.takeArray(2);
        var len: u64 = h[1] & 0x7f;
        if (len == 126) {
            len = std.mem.readInt(u16, try r.takeArray(2), .big);
        } else if (len == 127) {
            len = std.mem.readInt(u64, try r.takeArray(8), .big);
        }
        if ((h[1] & 0x80) != 0) _ = try r.takeArray(4); // mask key
        try r.discardAll(@intCast(len));
    }

    /// One unmasked server->client text frame (payloads here are all < 126 B).
    pub fn writeTextFrame(w: *Io.Writer, payload: []const u8) !void {
        try w.writeAll(&[_]u8{ 0x81, @intCast(payload.len) });
        try w.writeAll(payload);
        try w.flush();
    }
};

/// A root-shaped Agent pointed at the mock. `out`/`in` stay null: no TTY means no
/// spinner, no Esc poll and no user-facing stall line — the transport alone.
pub fn mockAgent(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, url: []const u8) Agent {
    return .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = undefined, // the WS path never touches the HTTP client
        .provider = .{
            .id = "codex",
            .kind = .responses,
            .auth = .bearer,
            .url = url,
            .api_key = "k",
            .model = "gpt-5",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
    };
}

pub fn traced(tw: *Io.Writer.Allocating, needle: []const u8) bool {
    return std.mem.indexOf(u8, tw.written(), needle) != null;
}

/// How the client ended the connection, as seen from the other side.
pub const saw_nothing: u8 = 0;
pub const saw_close_frame: u8 = 1;
pub const saw_fin: u8 = 2;

/// Complete the upgrade, then classify the next thing the client does: a ws close
/// frame (opcode 0x8) or EOF. `deinit` normally writes a courtesy close frame —
/// one more BLOCKING write on a socket that may be what wedged us.
pub fn closeObserver(io: Io, server: *std.Io.net.Server, seen: *std.atomic.Value(u8), done: *std.atomic.Value(bool)) void {
    const c = server.accept(io) catch return;
    defer c.close(io);
    var rbuf: [8192]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sr = std.Io.net.Stream.Reader.init(c, io, &rbuf);
    var sw = std.Io.net.Stream.Writer.init(c, io, &wbuf);
    while (true) {
        const line = sr.interface.takeDelimiterInclusive('\n') catch return Mock.idle(io, done);
        if (line.len <= 2) break;
    }
    sw.interface.writeAll("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n") catch return Mock.idle(io, done);
    sw.interface.flush() catch return Mock.idle(io, done);
    const h = sr.interface.takeArray(2) catch {
        seen.store(saw_fin, .release); // stream ended: a plain TCP FIN
        return Mock.idle(io, done);
    };
    seen.store(if ((h[0] & 0x0f) == 0x8) saw_close_frame else saw_nothing, .release);
    Mock.idle(io, done);
}
