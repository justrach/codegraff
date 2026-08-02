//! MCP JSON-RPC transport plumbing, split out of mcp.zig to keep it under
//! the repo's 600-line cap: the per-server transport union/state, the
//! legacy `initialize` handshake, era detection, and raw request/notify
//! framing over either stdio or Streamable HTTP. mcp.zig keeps the
//! higher-level `Registry` (server lifecycle, tool discovery, tool
//! dispatch) and aliases `Server`/`Transport` from here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_http = @import("mcp_http.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const mcp_teardown = @import("mcp_teardown.zig");

const legacy_protocol = mcp_protocol.legacy_protocol;
const modern_protocol = mcp_protocol.modern_protocol;

pub const StdioTransport = struct {
    child: std.process.Child,
    stdin_writer: Io.File.Writer,
    stdout_reader: Io.File.Reader,
};

pub const Transport = union(enum) {
    stdio: StdioTransport,
    http: mcp_http.HttpTransport,
};

/// A property of the server, not the request (versioning § Backward
/// Compatibility): determined once at connect and cached for the process
/// lifetime, never re-probed per tool call.
pub const Era = enum { unknown, modern, legacy };

pub const Server = struct {
    name: []const u8,
    transport: Transport,
    next_id: i64 = 1,
    initialized: bool = true,
    era: Era = .unknown,
    /// Revision the server negotiated (legacy) or `modern_protocol` (modern),
    /// shown in `/mcp` so version skew is visible.
    protocol_version: []const u8 = "?",
    /// Set when the modern probe ran and the connection landed on the legacy
    /// protocol anyway: WHY it did. Rendered on the connect line and in
    /// `/mcp` — a downgrade the user cannot see is the whole of #327. Null
    /// when no probe ran (probe disabled, HTTP) or when it found modern.
    probe_fallback: ?LegacyReason = null,
};

pub fn deinitServer(server: *Server, io: Io, budget: mcp_teardown.Budget) void {
    switch (server.transport) {
        .stdio => |*stdio| mcp_stdio.stopChild(io, &stdio.child),
        .http => |*http| { // never waits on a peer: bounded by `budget` (#305)
            if (http.session_id) |session_id| http.client.allocator.free(session_id);
            http.session_id = null;
            mcp_teardown.deinitHttpClient(&http.client, io, budget);
        },
    }
}

/// A stdio server is a local process, so a handshake reply is a pipe write
/// away - but `request`'s stdio branch loops on takeDelimiter with NO deadline.
/// That is fine for a live tool call (the turn is interruptible) and wrong at
/// STARTUP: a server that holds stdout open and never answers `initialize`
/// hangs graff before the REPL exists, with no way out (#275). Generous, since
/// a cold `npx` server can be slow to first byte; overridable for the truly odd
/// one via GRAFF_MCP_HANDSHAKE_SECS (parsed in session_run.zig).
pub var stdio_handshake_timeout_ms: i64 = 15_000;

/// GRAFF_MCP_HANDSHAKE_SECS raises/lowers the bound above (default 15s). A cold
/// `npx` server can be slow to first byte and the bound only has to be shorter
/// than "forever", so this is a safety valve, not a tuning knob. Seconds;
/// ignored if unparseable or 0; clamped to <=1 day. Lives here rather than in
/// session_run.zig, which is at the 600-line cap.
pub fn applyHandshakeTimeoutEnv(environ_map: anytype) void {
    applyProbeTimeoutEnv(environ_map);
    const v = environ_map.get("GRAFF_MCP_HANDSHAKE_SECS") orelse return;
    const secs = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch return;
    if (secs > 0) stdio_handshake_timeout_ms = @intCast(@min(secs, 86_400) * 1000);
}

/// GRAFF_MCP_PROBE_MS overrides `stdio_probe_timeout_ms` (default 5000, see
/// there for how that number is derived). Raise it for a server slower to its
/// first answer than the default allows — the connect line names the
/// probe-deadline fallback when that happens — or lower it to skip the
/// startup wait a server that answers `server/discover` with silence rather
/// than an error costs. Milliseconds; ignored if unparseable or 0; clamped to
/// <=60s.
pub fn applyProbeTimeoutEnv(environ_map: anytype) void {
    const v = environ_map.get("GRAFF_MCP_PROBE_MS") orelse return;
    const ms = std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10) catch return;
    if (ms > 0) stdio_probe_timeout_ms = @intCast(@min(ms, 60_000));
}

fn stdioHandshakeTimeoutTask(io: Io) void {
    io.sleep(.fromMilliseconds(stdio_handshake_timeout_ms), .awake) catch {};
}

/// One legacy-handshake round trip over stdio, bounded. Same Select+deadline
/// shape as probeStdio, including its guarantee: `Select.cancel` blocks until
/// the read task has actually stopped, so nothing is still touching the reader
/// when this returns.
fn stdioRequestBounded(server: *Server, a: Allocator, io: Io, params: []const u8, method: []const u8) !Value {
    const id = server.next_id;
    server.next_id += 1;
    {
        const stdio = &server.transport.stdio;
        const w = &stdio.stdin_writer.interface;
        try w.writeAll(try mcp_protocol.buildRequest(a, id, method, params, false));
        try w.writeByte('\n');
        try w.flush();
    }
    var done_buf: [2]StdioProbeDone = undefined;
    var select: Io.Select(StdioProbeDone) = .init(io, &done_buf);
    select.concurrent(.replied, stdioProbeReadTask, .{ server, a, id }) catch return error.McpHandshakeTimeout;
    select.concurrent(.timeout, stdioHandshakeTimeoutTask, .{io}) catch {
        const only = select.await() catch return error.McpHandshakeTimeout;
        select.cancelDiscard();
        return only.replied;
    };
    const first = select.await() catch return error.McpHandshakeTimeout;
    switch (first) {
        .replied => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => {
            _ = select.cancel(); // blocks until the read task has actually stopped
            return error.McpHandshakeTimeout;
        },
    }
}

/// A handshake round trip, bounded when the caller supplied an Io and the
/// transport is stdio. HTTP is already bounded by the client's own timeouts.
fn handshakeRequest(server: *Server, a: Allocator, bound_io: ?Io, params: []const u8, method: []const u8) !Value {
    if (bound_io) |io| if (server.transport == .stdio) return stdioRequestBounded(server, a, io, params, method);
    return request(server, a, params, method, null);
}

pub fn initializeServer(server: *Server, response_alloc: Allocator, session_alloc: Allocator, bound_io: ?Io) !void {
    const init_resp = try handshakeRequest(server, response_alloc, bound_io,
        \\{"protocolVersion":"
    ++ legacy_protocol ++
        \\","capabilities":{},"clientInfo":{"name":"simple-harness","version":"0.1"}}
    , "initialize");
    const protocol_transport: mcp_protocol.Transport = switch (server.transport) {
        .stdio => .stdio,
        .http => .streamable_http,
    };
    const protocol_version = try mcp_protocol.negotiatedProtocol(init_resp, protocol_transport);
    server.protocol_version = try session_alloc.dupe(u8, protocol_version);
    try notify(server, response_alloc, "notifications/initialized");
    server.initialized = true;
    server.era = .legacy;
}

/// JSON-RPC request/response over either transport. `params` is a raw JSON
/// object string; `name` is the tool name for a `tools/call` (rendered as
/// `Mcp-Name` on a modern request) and null for everything else. Result
/// Values use `response_alloc`.
///
/// LOAD-BEARING: when `server.era != .modern`, `mcp_protocol.buildRequest`'s
/// `modern=false` path reproduces the exact pre-migration bytes — no `_meta`,
/// nothing added — so this is byte-identical to the client graff shipped
/// before 2026-07-28 for every server that has not been probed into the
/// modern era (today, that is every server).
pub fn request(server: *Server, response_alloc: Allocator, params: []const u8, method: []const u8, name: ?[]const u8) !Value {
    const id = server.next_id;
    server.next_id += 1;
    const modern = server.era == .modern;
    const body = try mcp_protocol.buildRequest(response_alloc, id, method, params, modern);

    switch (server.transport) {
        .stdio => |*stdio| {
            const w = &stdio.stdin_writer.interface;
            try w.writeAll(body);
            try w.writeByte('\n');
            try w.flush();

            const r = &stdio.stdout_reader.interface;
            while (true) {
                const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
                if (mcp_http.matchingResponse(response_alloc, line, id)) |parsed| return parsed;
            }
        },
        .http => |*http| {
            const protocol_version = if (modern) modern_protocol else if (std.mem.eql(u8, method, "initialize")) legacy_protocol else server.protocol_version;
            const response_body = (try mcp_http.post(http, body, .{
                .protocol_version = protocol_version,
                .method = method,
                .name = name,
                .modern = modern,
            }, id)) orelse return error.BadMcpResponse;
            defer http.client.allocator.free(response_body);
            return mcp_http.parseHttpResponse(response_alloc, response_body, id) orelse error.BadMcpResponse;
        },
    }
}

/// Fire-and-forget JSON-RPC notification (no id, no response). Only ever
/// sent on the legacy `initialize` handshake — the modern wire format has no
/// notifications/initialized to send.
pub fn notify(server: *Server, response_alloc: Allocator, method: []const u8) !void {
    switch (server.transport) {
        .stdio => |*stdio| {
            const w = &stdio.stdin_writer.interface;
            try w.print(
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
            ++ "\n", .{method});
            try w.flush();
        },
        .http => |*http| {
            const body = try std.fmt.allocPrint(response_alloc,
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{}}}}
            , .{method});
            if (try mcp_http.post(http, body, .{
                .protocol_version = server.protocol_version,
                .method = method,
                .modern = false,
            }, null)) |response_body| {
                http.client.allocator.free(response_body);
            }
        },
    }
}

fn connectLegacy(server: *Server, a: Allocator, session_alloc: Allocator, bound_io: ?Io) !Value {
    try initializeServer(server, a, session_alloc, bound_io); // sets server.era = .legacy
    return handshakeRequest(server, a, bound_io, "{}", "tools/list");
}

/// How long the `server/discover` probe waits before calling a stdio server
/// legacy (stdio spec: fall back on "no response within a reasonable
/// timeout", never keyed to a specific error code).
///
/// This bound is NOT pipe latency. The probe is the first thing written to a
/// child graff spawned microseconds ago, so what it has to cover is that
/// child's COLD START — interpreter boot, module load, index warm-up — under
/// whatever load the machine already carries. 600ms was sized for the pipe
/// write and was wrong for the process behind it: a second concurrent
/// codedb-pro answers its first request in ~1.5s where the first takes 2ms,
/// and an npx-launched server routinely needs longer, so the most common real
/// setup (a workspace server plus the auto-connected companion) missed the
/// deadline on EVERY run and spent the whole session on legacy. That was #327.
///
/// The costs are asymmetric, which is what sets the value: missing the
/// deadline degrades the connection for its entire life, while overshooting
/// costs a one-time startup wait — and only for a server that answers nothing
/// at all, since one that replies with a JSON-RPC error (what every SDK-built
/// legacy server does for an unknown method) is classified the instant that
/// error lands, however large this is. 5s covers the measured slow starts with
/// room to spare and stays well under the 15s `stdio_handshake_timeout_ms`
/// graff already spends on the same child's `initialize`. `GRAFF_MCP_PROBE_MS`
/// moves it either way.
pub var stdio_probe_timeout_ms: i64 = 5_000;

fn stdioProbeReadTask(server: *Server, response_alloc: Allocator, id: i64) anyerror!Value {
    const stdio = &server.transport.stdio;
    const r = &stdio.stdout_reader.interface;
    while (true) {
        const line = (try r.takeDelimiter('\n')) orelse return error.McpClosed;
        if (mcp_http.matchingResponse(response_alloc, line, id)) |parsed| return parsed;
    }
}

fn stdioProbeTimeoutTask(io: Io) void {
    io.sleep(.fromMilliseconds(stdio_probe_timeout_ms), .awake) catch {};
}

const StdioProbeDone = union(enum) {
    replied: anyerror!Value,
    timeout,
};

/// Why a probe concluded a stdio server is legacy. Every value is a CLEAN
/// negotiation outcome — the server answered (or deliberately did not answer)
/// in a way the spec says to downgrade on — except `probe_unavailable`, which
/// is graff's own limitation and is labelled as such. A transport or decode
/// failure is deliberately NOT in this set: it propagates as an error instead
/// of silently degrading the connection for the rest of the session (#327).
pub const LegacyReason = enum {
    /// The server answered `server/discover` with a JSON-RPC error object.
    rejected,
    /// It answered, but `result.supportedVersions` does not list
    /// `modern_protocol` (or is missing/malformed — an answer, just not a
    /// modern one).
    no_modern_version,
    /// No answer inside `stdio_probe_timeout_ms`. The stdio spec's own fallback
    /// trigger: "no response within a reasonable timeout".
    timeout,
    /// graff could not run the bounded probe at all (no concurrency for the
    /// reader/deadline pair, twice). Says nothing about the server, so it is
    /// reported distinctly rather than passed off as a negotiated result.
    probe_unavailable,
    /// The child exited or closed stdout during the probe; the caller
    /// respawned it and connected legacy on the fresh process.
    server_exited,

    /// Suffix for the connect line / `/mcp`, empty-safe to concatenate. A
    /// legacy landing is never invisible: #327 was exactly a fallback nobody
    /// could see.
    pub fn note(reason: LegacyReason) []const u8 {
        return switch (reason) {
            .rejected => " [legacy: server rejected server/discover]",
            .no_modern_version => " [legacy: server does not list " ++ modern_protocol ++ "]",
            .timeout => " [legacy: no server/discover answer before the probe deadline; raise GRAFF_MCP_PROBE_MS]",
            .probe_unavailable => " [legacy: graff could not run the modern probe]",
            .server_exited => " [legacy: server exited during the probe, respawned]",
        };
    }
};

pub const StdioProbeOutcome = union(enum) {
    modern,
    legacy: LegacyReason,
    closed,
};

/// Classify one `server/discover` reply. Errors that are not `McpClosed` are
/// PROPAGATED, not swallowed into `.legacy`: a broken pipe, a cancelled read
/// or an I/O failure is a transport problem, and pinning the era to legacy on
/// one would leave the connection degraded for its whole life with nothing to
/// see (#327). Only an actual answer downgrades.
pub fn classifyStdioProbe(result: anyerror!Value) anyerror!StdioProbeOutcome {
    const response = result catch |err| switch (err) {
        error.McpClosed => return .closed,
        else => return err,
    };
    if (response != .object) return .{ .legacy = .no_modern_version };
    // A recognized modern *error* here (-32020/-32021/-32022) still reads as
    // legacy for stdio specifically: unlike the HTTP probe, graff has no
    // real modern stdio server to validate a "fail loudly" path against
    // (population ~0 today), so the conservative choice is the one that
    // degrades to the handshake graff already knows works.
    if (response.object.get("error") != null) return .{ .legacy = .rejected };
    const supported = mcp_protocol.discoverSupportedVersions(response) catch return .{ .legacy = .no_modern_version };
    for (supported) |v| if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) return .modern;
    return .{ .legacy = .no_modern_version };
}

/// Attempt the `server/discover` probe, bounded to `stdio_probe_timeout_ms` so
/// a legacy server that silently ignores an unrecognized pre-`initialize`
/// method can never hang graff at startup (stdio § Backward Compatibility:
/// fall back "on any error that is not a recognized modern error, or no
/// response within a reasonable timeout"). `Select.cancel` blocks until the
/// read task has actually stopped before returning, so by the time this
/// function returns on a timeout, nothing is still touching the reader —
/// the caller's subsequent (unbounded, as today) legacy `request()` reads
/// pick up cleanly on the same stream.
///
/// `.closed` (the child exited or closed stdout) is reported distinctly
/// from `.legacy` (a reply arrived, or the wait simply timed out) because
/// only `.closed` needs the caller to respawn: some legacy SDK servers
/// exit on an unrecognized pre-initialize message, and writing the
/// `initialize` request to a dead child's closed stdin would just error.
pub fn probeStdio(server: *Server, a: Allocator, io: Io) !StdioProbeOutcome {
    const id = server.next_id;
    server.next_id += 1;
    {
        const stdio = &server.transport.stdio;
        const w = &stdio.stdin_writer.interface;
        // The probe is itself a modern request, so it MUST carry the `_meta`
        // envelope. Sending bare `params:{}` made a conforming server answer
        // -32602 "missing params._meta", which classifies as an error and so
        // as LEGACY: graff fell back on exactly the servers the probe exists
        // to find. Proven against codedb-pro 0.2.16, which speaks 2026-07-28.
        const body = try mcp_protocol.buildRequest(a, id, "server/discover", "{}", true);
        try w.writeAll(body);
        try w.writeAll("\n");
        try w.flush();
    }

    var done_buf: [2]StdioProbeDone = undefined;
    var select: Io.Select(StdioProbeDone) = .init(io, &done_buf);
    // #327: failing to SPAWN the probe tasks says nothing about the server's
    // protocol. These two arms used to `catch return .legacy`, which pinned
    // the era to legacy for the process lifetime with no way for anyone to
    // tell — deterministically so for the second stdio server in a session
    // (the auto-connected companion, i.e. the server most users have).
    // `error.McpProbeUnavailable` hands the decision back to the caller.
    select.concurrent(.replied, stdioProbeReadTask, .{ server, a, id }) catch return error.McpProbeUnavailable;
    select.concurrent(.timeout, stdioProbeTimeoutTask, .{io}) catch {
        // The reader is already running with no deadline behind it. Reap it
        // (cancel blocks until it has actually stopped) rather than wait on
        // it unbounded at startup, which is the #275 hang in another form.
        select.cancelDiscard();
        return error.McpProbeUnavailable;
    };

    const first = select.await() catch |err| {
        select.cancelDiscard();
        return err;
    };
    switch (first) {
        .replied => |result| {
            select.cancelDiscard();
            return classifyStdioProbe(result);
        },
        .timeout => {
            _ = select.cancel(); // blocks until the read task has actually stopped
            return .{ .legacy = .timeout };
        },
    }
}

/// `probeStdio` plus the recovery policy for the one failure that is graff's
/// own and not the server's: a probe that could not be spawned is retried
/// once, and only then downgraded — visibly, via `.probe_unavailable`, so a
/// degraded connect is legible in the connect line and `/mcp` instead of
/// looking exactly like a server that genuinely speaks only the legacy
/// protocol (#327). Transport errors still propagate: those mean the pipe is
/// broken, and a legacy handshake over a broken pipe should fail loudly.
pub fn probeStdioResilient(server: *Server, a: Allocator, io: Io) !StdioProbeOutcome {
    return probeStdio(server, a, io) catch |err| switch (err) {
        error.McpProbeUnavailable => probeStdio(server, a, io) catch |retry_err| switch (retry_err) {
            error.McpProbeUnavailable => .{ .legacy = .probe_unavailable },
            else => retry_err,
        },
        else => err,
    };
}

/// Connect a stdio server. Always legacy — the `server/discover` probe
/// (on unless `GRAFF_MCP_PROBE=0`) is orchestrated by mcp.zig's
/// `startServer` instead of here: only it has the argv/env needed to
/// respawn a server whose process closes during the probe. This is
/// byte-identical to graff's pre-migration behavior either way.
pub fn connectStdio(server: *Server, a: Allocator, session_alloc: Allocator, io: Io) !Value {
    return connectLegacy(server, a, session_alloc, io);
}

/// Finish connecting a stdio server that `probeStdio` found modern: no
/// handshake, just the modern-enveloped `tools/list` (era is set first so
/// `request` picks the modern wire format).
pub fn finishModernStdio(server: *Server, a: Allocator, session_alloc: Allocator, io: Io) !Value {
    server.era = .modern;
    server.protocol_version = try session_alloc.dupe(u8, modern_protocol);
    server.initialized = true;
    // Bounded like the legacy handshake: a modern server that answered the probe
    // and then goes silent must not hang startup either (#275).
    return stdioRequestBounded(server, a, io, "{}", "tools/list");
}

/// Connect a Streamable HTTP server: attempt a modern (2026-07-28)
/// `tools/list` first — it doubles as the discovery call graff needs
/// anyway, so a modern server costs one POST where the legacy handshake
/// costs three. Falls back to the legacy `initialize` ->
/// `notifications/initialized` -> `tools/list` handshake on anything that
/// is not a recognized modern error (versioning § Backward Compatibility).
/// See mcp_protocol.classifyProbe for the exact classification rules.
pub fn connectHttp(server: *Server, a: Allocator, session_alloc: Allocator) !Value {
    return connectHttpAttempt(server, a, session_alloc, false);
}

fn connectHttpAttempt(server: *Server, a: Allocator, session_alloc: Allocator, retried: bool) !Value {
    const http = &server.transport.http;
    const probe_id = server.next_id;
    server.next_id += 1;
    const probe_body = try mcp_protocol.buildRequest(a, probe_id, "tools/list", "{}", true);
    const reply = try mcp_http.probe(http, probe_body, .{
        .protocol_version = modern_protocol,
        .method = "tools/list",
        .modern = true,
    });
    defer if (reply.body) |b| http.client.allocator.free(b);

    // A 2xx alone does NOT mean modern. JSON-RPC carries application errors in
    // a 200 body, and a legacy server that enforces "initialize first" answers
    // this probe with exactly that: 200 plus an error object. Treating it as
    // modern skipped the fallback and broke every such server. Only a real
    // `result` proves the server understood a request sent with no handshake.
    if (reply.status >= 200 and reply.status < 300) modern: {
        const body = reply.body orelse break :modern;
        const parsed = mcp_http.parseHttpResponse(a, body, probe_id) orelse break :modern;
        if (parsed != .object or parsed.object.get("result") == null) break :modern;
        server.era = .modern;
        server.protocol_version = try session_alloc.dupe(u8, modern_protocol);
        server.initialized = true;
        return parsed;
    }

    switch (mcp_protocol.classifyProbe(a, reply.body orelse &.{})) {
        .legacy => return connectLegacy(server, a, session_alloc, null),
        // -32020/-32021: graff's own request was malformed. That is a graff
        // bug, not a version mismatch — surface it loudly rather than
        // falling back and hiding it behind a legacy handshake that will
        // just fail differently.
        .modern => return error.McpModernRequestRejected,
        .incompatible => return error.McpIncompatibleProtocolVersion,
        .unsupported_version => |supported| {
            var has_modern = false;
            for (supported) |v| if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) {
                has_modern = true;
            };
            if (has_modern) {
                // We asked for modern_protocol and the server both rejected
                // it AND claims to support it — contradictory, but retry
                // once (single-shot: this is idempotent, so a second
                // identical answer means give up, not loop).
                if (!retried) return connectHttpAttempt(server, a, session_alloc, true);
                return error.McpIncompatibleProtocolVersion;
            }
            // No overlap with modern_protocol, but classifyProbe only
            // returns this variant when `supported` overlaps something we
            // speak — so it must be a legacy revision: dual-era server.
            return connectLegacy(server, a, session_alloc, null); // HTTP: bounded by the client's own timeouts
        },
    }
}

test { // #327 probe-classification/fallback coverage (this file is at the 600-line cap)
    _ = @import("mcp_rpc_tests.zig");
}

// #275: a stdio server that accepts the connection and then never answers must
// not hang startup. The child here holds stdout open and writes nothing, which
// is precisely the reported repro. Before the bound, connectStdio's initialize
// read looped on takeDelimiter forever - so reverting the fix does not turn this
// test RED, it makes it HANG, which is the same signal in a slower form.
test "connectStdio (#275): a silent stdio server times out instead of hanging startup" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = stdio_handshake_timeout_ms;
    stdio_handshake_timeout_ms = 250; // keep the suite fast; the bound is what matters
    defer stdio_handshake_timeout_ms = saved;

    // Reads stdin so our write cannot fail, and never writes a line back.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "cat > /dev/null" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer mcp_stdio.stopChild(io, &child);

    const in_buf = try a.alloc(u8, 4096);
    const out_buf = try a.alloc(u8, 4096);
    var server: Server = .{
        .name = "silent",
        .transport = .{ .stdio = .{
            .child = child,
            .stdin_writer = child.stdin.?.writerStreaming(io, in_buf),
            .stdout_reader = child.stdout.?.readerStreaming(io, out_buf),
        } },
    };

    const before = Io.Timestamp.now(io, .awake).nanoseconds;
    try std.testing.expectError(error.McpHandshakeTimeout, connectStdio(&server, a, a, io));
    const elapsed_ms = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - before, std.time.ns_per_ms);
    // Bounded, not merely "eventually": assert it gave up near the deadline
    // rather than after some unrelated timeout far above it.
    try std.testing.expect(elapsed_ms < 5_000);
    // The child is still alive - the timeout is the CLIENT giving up, so the
    // caller (startServer) stays in charge of tearing the server down.
    server.transport.stdio.child = child;
}

test "a late reply for a stale id cannot be mistaken for the id actually awaited" {
    // The exact loop body `request`'s stdio branch and `stdioProbeReadTask`
    // both use: takeDelimiter, then filter by id via
    // mcp_http.matchingResponse, skipping any line whose id doesn't match.
    // Proves that if a `server/discover` probe times out but its reply
    // arrives later, it cannot be mistaken for the `initialize` response
    // that follows it on the same stream — the ids differ (discover used
    // an earlier next_id).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var reader: Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":1,"result":{}}
        \\{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
        \\
    );
    var found: ?Value = null;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse break;
        if (mcp_http.matchingResponse(a, line, 2)) |parsed| {
            found = parsed;
            break;
        }
    }
    const result = found orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i64, 2), result.object.get("id").?.integer);
    try std.testing.expect(result.object.get("result").?.object.get("tools") != null);
}
