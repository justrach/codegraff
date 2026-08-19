//! ACP (Agent Client Protocol) AGENT mode — `graff acp` (#375, ADR 0012).
//!
//! ACP is Zed's editor↔agent protocol: JSON-RPC 2.0 over stdio, one message
//! per line. The editor is the CLIENT, graff is the AGENT. This file is the
//! process command: it arms stdout discipline and runs one live root turn per
//! `session/prompt` on the SAME `root.messages`. The JSON-RPC table lives in
//! `acp_protocol.zig`; token projection lives in `acp_usage.zig`.
//!
//! v0 + usage (deliberate, see deviations):
//!   initialize     → protocolVersion + agentCapabilities + agentInfo.
//!   session/new    → mints one session id. ONE live session per process.
//!   session/prompt → flatten ContentBlocks, run ONE full root turn (same
//!                    loop `-p` uses), emit `agent_message_chunk` + optional
//!                    `usage_update`, then `{stopReason, usage?}`.
//!   session/cancel → empty result if it was a request; no interrupt yet.
//!   anything else  → -32601. Notifications (no `id`) are NEVER answered.
//!
//! Why the conversation persists: unlike `-p`, every session/prompt appends to
//! the SAME `root.messages`, so turn N sees turns 1..N-1. That is the entire
//! point of a session protocol, and it is why the unattended setup below runs
//! exactly once, outside the loop — and why ACP stays warmer than `grok -c`.
//!
//! stdout discipline — the load-bearing invariant. Only protocol JSON may ever
//! reach stdout, so three separate producers are shut off:
//!   1. `isAcpSubcommand` (called from args.zig's positional-subcommand test)
//!      flips `main_mod.json_mode`, which is what silences every startup banner
//!      — those print long before this function runs, so the switch has to be
//!      thrown during flag parsing, not here.
//!   2. `root.out = null` kills the root agent's own say()/emit() (say falls
//!      back to stderr; emit no-ops on a null writer).
//!   3. `main_mod.g_out = null` kills guiEmit — the pool-thread subagent and
//!      workflow-progress emitters write --json events straight to that global
//!      stdout alias, and json_mode is now on, so leaving it set would let a
//!      subagent interleave JSONL into the ACP stream.
//!
//! Deviations from the spec, made knowingly for v0:
//!   * No client callbacks at all (no fs/read_text_file, no
//!     session/request_permission). graff reads and writes files itself and
//!     the gate runs unattended, exactly as in `-p`.
//!   * `sessionId` on session/prompt is accepted as given rather than checked
//!     against the live session, and it is echoed back on the update. One
//!     process holds one session, so there is nothing to disambiguate, and a
//!     scripted client can prompt without first parsing session/new's reply.
//!   * loadSession is advertised false; session/load is therefore -32601.
//!   * One update per turn (the final text), not streaming chunks or tool_call.
//!   * `session/new` `cwd` is accepted and ignored: process-wide chdir would
//!     fight the workspace tool (ADR 0006).
//!   * `session/cancel` does not abort an in-flight turn (the read loop is
//!     blocked inside it). A later multiplex can flip this without a new loop.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const providers = @import("providers.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const pricing = @import("pricing.zig");
const proto = @import("acp_protocol.zig");
const acp_usage = @import("acp_usage.zig");

pub const protocol_version = proto.protocol_version;
pub const err_method_not_found = proto.err_method_not_found;
pub const err_internal = proto.err_internal;
pub const parseRequest = proto.parseRequest;
pub const negotiateVersion = proto.negotiateVersion;
pub const flattenPrompt = proto.flattenPrompt;
pub const handleLine = proto.handleLine;

/// True when this positional selects `graff acp`.
///
/// SIDE EFFECT, and the reason this predicate lives here instead of inline in
/// args.zig: it also arms ACP's stdout discipline by turning on `json_mode`.
/// stdout stops being human text and becomes a strict machine protocol for the
/// rest of the process — which is exactly what `json_mode` already means, and
/// what every startup banner is already gated on. Those banners print between
/// flag parsing and `runAcpCommand`, so the flag has to be set during the
/// parse; there is no later hook that would still be early enough.
pub fn isAcpSubcommand(positional: []const u8) bool {
    if (!std.mem.eql(u8, positional, "acp")) return false;
    main_mod.json_mode = true;
    return true;
}

/// The real turn: appends to the SAME root history every time, which is what
/// makes an ACP session a conversation rather than N independent one-shots.
/// Usage is the CostTally delta for this turn (ADR 0012).
const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,

    fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!acp_usage.TurnOutcome {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        const before = pricing.g_cost.snap(self.root.io);
        try self.root.messages.append(try messages_mod.textMessage(arena, "user", text));
        if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(text.len, std.math.maxInt(u32))), self.root.provider.model);
        const final = try providers.runTurnWithFallback(self.root, self.keys, arena, null);
        const after = pricing.g_cost.snap(self.root.io);
        const window = if (self.root.provider.context > 0) self.root.provider.context else @max(self.root.last_context_tokens, 1);
        return .{
            .text = final,
            .usage = acp_usage.fromTallyDelta(before, after),
            .session = .{
                .used = self.root.last_context_tokens,
                .size = window,
                .cost_usd = after.usd,
            },
        };
    }
};

/// `graff acp`: serve the Agent Client Protocol on stdio until the client
/// closes stdin. Mirrors `runReplCommand`'s contract — returns false (having
/// done nothing) when this invocation is not `acp`, true once it has run the
/// whole session, at which point main() returns immediately.
///
/// `root` is already a stable, fully-constructed main()-owned Agent (keys,
/// provider, tools, MCP) by the time this is called, so taking its address is
/// ordinary pointer-passing. `arena` is the process-lifetime session arena:
/// the minted session id, every parsed request and every turn's history all
/// live there for the life of the connection, which is what lets turn N see
/// turns 1..N-1.
pub fn runAcpCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "acp"))) return false;
    _ = environ_map;
    _ = client;
    // Unattended setup, ONCE (see the header): the gate denies instead of
    // prompting, tool progress goes to stderr, and stdout is protocol-only.
    main_mod.unattended = true;
    root.in = null;
    root.out = null;
    root.stream_quiet = true;
    main_mod.g_out = null; // no guiEmit into the ACP stream
    var live: LiveTurn = .{ .root = root, .keys = keys };
    var d: proto.Dispatch = .{ .turn = LiveTurn.run, .ctx = &live, .seed = @bitCast(util.unixMs(io)) };
    while (true) {
        // A read failure (including a line longer than stdin's buffer, which
        // takeDelimiter leaves unconsumed) ends the session rather than
        // spinning on bytes we can never make progress past.
        const line = (in.takeDelimiter('\n') catch break) orelse break;
        proto.handleLine(&d, arena, out, line) catch |err| {
            std.debug.print("acp: dispatch failed: {t}\n", .{err});
            break;
        };
        out.flush() catch break;
    }
    session.saveSession(root, arena, root.session_name) catch {};
    // This path returns before main() registers its REPL cleanup defer, so the
    // root's gpa-backed buffers are freed here (same as the one-shot path).
    root.md_buf.deinit(gpa);
    root.md_word.deinit(gpa);
    for (root.md_table.items) |r| gpa.free(r);
    root.md_table.deinit(gpa);
    root.tools_used.deinit(gpa);
    return true;
}

const testing = std.testing;

test "isAcpSubcommand claims only `acp`, and arms the stdout discipline" {
    const saved = main_mod.json_mode;
    defer main_mod.json_mode = saved;
    main_mod.json_mode = false;
    try testing.expect(!isAcpSubcommand("repl"));
    try testing.expect(!isAcpSubcommand("acpx"));
    try testing.expect(!isAcpSubcommand(""));
    try testing.expect(!main_mod.json_mode); // no side effect on a miss
    try testing.expect(isAcpSubcommand("acp"));
    try testing.expect(main_mod.json_mode); // stdout is protocol-only from here
}
