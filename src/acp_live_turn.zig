const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const main_mod = @import("main.zig");
const providers = @import("providers.zig");
const telemetry = @import("telemetry.zig");
const session = @import("session.zig");
const stream = @import("acp_stream.zig");
const review = @import("review.zig");
const messages = @import("messages.zig");
const cancel_source = @import("cancel_source.zig");
const trace = @import("trace.zig");
const turn_trace = @import("mainloop_trace.zig");
const proto = @import("acp_protocol.zig");

pub const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    session_id: []const u8 = "",
    saw_text: bool = false,
    local_catalog_loaded: bool = false,
    prev_turn_id: u64 = 0,
    prev_prompt_fp: [16]u8 = @splat(0),
    inbox: ?*@import("acp_inbox.zig").Inbox = null,
    dispatch: ?*@import("acp_engine.zig").Dispatch = null,
    /// Launch `--model`: outranks a loaded session's saved model, as on CLI resume.
    model_override: ?provider_mod.Provider = null,

    pub fn errorMessage(ctx: *anyopaque, err: anyerror) []const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        return if (err == error.ApiError) self.root.last_api_error orelse "Provider request failed" else @errorName(err);
    }

    pub fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        var output_lock: Io.Mutex = .init;
        if (self.inbox) |inbox| if (inbox.permission) |bridge| bridge.setOutputLock(&output_lock);
        defer if (self.inbox) |inbox| if (inbox.permission) |bridge| bridge.setOutputLock(null);
        // Receipt marker before any dedup/turn work: a worker that logged its
        // recipe but never this line never received its prompt — the stall is
        // upstream (client dispatch / bootstrap / transport), not in the turn.
        if (self.root.tracer) |tr| tr.note("acp_prompt", self.session_id);
        agent_mod.Agent.prepareRootTurn(); // #753: a prior stream cancel must not steal the continuation
        if (self.inbox) |inbox| {
            if (inbox.permission) |bridge| bridge.begin(self.session_id);
            inbox.begin();
        }
        defer if (self.inbox) |inbox| {
            if (inbox.permission) |bridge| bridge.cancel();
            inbox.end();
        };
        const review_prompt = review.promptFromLine(text);
        const parent_override = self.root.sys_override;
        const parent_review_mode = self.root.review_mode;
        self.root.review_mode = review_prompt != null;
        defer {
            self.root.review_mode = parent_review_mode;
            self.root.sys_override = parent_override;
        }
        if (review_prompt != null)
            self.root.sys_override = try review.systemPrompt(arena, self.root.sys_normal);
        var context = review.Context.begin(arena, self.root, review_prompt != null);
        defer if (context.restore(self.root)) self.root.rebaseContextMeter();
        if (@import("side_steer.zig").isSideRequest(text))
            return @import("side_steer.zig").spawnSide(self.root, arena, null, text);
        switch (try @import("turn_dedup.zig").enqueue(self.root, arena, self.out, review_prompt orelse text)) {
            .started => {},
            .skipped => return "",
            .stuck => return @import("turn_dedup.zig").stuck_text,
        }
        if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(text.len, std.math.maxInt(u32))), self.root.provider.model);
        self.saw_text = false;
        var sink: stream.EventSink = undefined;
        sink.init(self.root.gpa, self.out, &self.session_id, &self.saw_text);
        sink.output_lock = &output_lock;
        sink.output_io = self.root.io;
        const subagents = self.dispatch != null and self.dispatch.?.subagents and self.dispatch.?.draft_subagents_enabled;
        defer sink.deinit();
        var child_state: @import("acp_subagent_live.zig").State = .{ .out = self.out, .parent = self.session_id, .output_lock = &output_lock };
        if (subagents) @import("acp_subagent_live.zig").install(self.root.io, &child_state);
        defer if (subagents) @import("acp_subagent_live.zig").uninstall(self.root.io);
        self.root.out = &sink.writer;
        main_mod.g_out = &sink.writer;
        defer {
            sink.writer.flush() catch {};
            self.root.out = null;
            main_mod.g_out = null;
        }
        const turn_id: u64 = if (trace.g_traj) |trajectory| blk: {
            const id = trajectory.nextId();
            trajectory.setTurn(id);
            break :blk id;
        } else 0;
        self.root.tools_used.clear(self.root.io);
        self.root.tool_calls_this_turn = 0;
        self.root.model_calls_this_turn = 0;
        const before = turn_trace.begin(self.root, self.root.io);
        turn_trace.recordLive(self.root, text, turn_id, self.prev_turn_id);
        const started = Io.Timestamp.now(self.root.io, .awake);
        const result = providers.runTurnWithFallback(self.root, self.keys, arena, null);
        // Supplemental metadata must not replace the turn outcome or prevent
        // trace/session persistence if the client disconnects. Emit on exit,
        // after the durable work below, while retaining whole-message locking.
        defer {
            sink.writer.flush() catch {};
            main_mod.g_gui_mu.lockUncancelable(self.root.io);
            defer main_mod.g_gui_mu.unlock(self.root.io);
            output_lock.lockUncancelable(self.root.io);
            defer output_lock.unlock(self.root.io);
            @import("acp_usage.zig").writeBestEffort(self.out, self.session_id, &@import("pricing.zig").g_cost, self.root.io);
        }
        turn_trace.record(self.root, self.root.io, arena, text, turn_id, started, result, self.root.effectiveContextTokens(), before, &self.prev_turn_id, &self.prev_prompt_fp);
        const isolated = context.restore(self.root);
        if (isolated) {
            self.root.review_mode = parent_review_mode;
            self.root.sys_override = parent_override;
            try self.root.messages.append(try messages.textMessage(arena, "user", text));
            self.root.rebaseContextMeter();
        }
        const final = result catch |err| {
            if (isolated) {
                const marker = if (err == error.Interrupted or err == error.Canceled)
                    cancel_source.marker(cancel_source.take(self.root.tracer))
                else
                    try std.fmt.allocPrint(arena, "[review ended early: {s}; findings are incomplete]", .{@errorName(err)});
                const partial = std.mem.trim(u8, self.root.partial_text.items, " \t\r\n");
                const report = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ partial, marker });
                try self.root.messages.append(try messages.textMessage(arena, "assistant", report));
                try sink.writer.flush();
                output_lock.lockUncancelable(self.root.io);
                defer output_lock.unlock(self.root.io);
                try proto.writeSessionUpdate(self.out, self.session_id, marker);
            }
            // #753: an API interruption is a failed turn, not a dead ACP
            // process. Save so the next prompt (and a respawn --resume) still
            // sees the tool results and the background-agent ledger.
            session.saveSession(self.root, self.root.arena, self.root.session_name) catch {};
            return err;
        };
        // The REPL checkpoints after every turn (mainloop); an ACP host's
        // conversation deserves the same durability. Without this a text-only
        // turn reached .graff/sessions only at stdin EOF, and a tab the host
        // killed never did. The root arena, not this turn's: the queued write
        // outlives the turn.
        if (isolated)
            try self.root.messages.append(try messages.textMessage(arena, "assistant", final));
        session.saveSessionAsync(self.root, self.root.arena, self.root.session_name) catch {};
        // saw_text is "the LAST streamed event was answer text" (tool events
        // reset it in the sink): a turn that ended mid-text already delivered
        // the answer; one that ended on tools (attempt_completion flows) has
        // its answer only in `final`, so that must still go on the wire.
        if (self.saw_text) return "";
        // A streamed preamble and the final answer are separate paragraphs;
        // without the break the client renders "…answering.The three files…".
        if (final.len > 0 and sink.streamed_any)
            return try std.fmt.allocPrint(arena, "\n\n{s}", .{final});
        return final;
    }
};

test "session/prompt receipt is traced even when dedup skips the turn" {
    const dedup = @import("turn_dedup.zig");
    dedup.resetForTest();
    defer dedup.resetForTest();
    @import("side_steer.zig").resetForTest();
    defer @import("side_steer.zig").resetForTest();
    const interactive = @import("subagent_interactive.zig");
    const was_notice = interactive.line_notice;
    interactive.line_notice = false;
    defer interactive.line_notice = was_notice;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var tracer: trace.Tracer = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .out = &aw.writer,
        .start = Io.Timestamp.now(std.testing.io, .awake),
    };
    var root: agent_mod.Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 100_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = null,
        .tracer = &tracer,
    };
    try root.messages.append(try messages.textMessage(a, "user", "hi"));
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    var out_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = &out, .session_id = "s1" };
    // A back-to-back duplicate skips the model turn entirely — the receipt
    // marker must already be in the trace, or a skipped prompt is
    // indistinguishable from one the worker never received.
    try std.testing.expectEqualStrings("", try LiveTurn.run(&live, a, "hi"));
    const logged = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, logged, "\"acp_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "s1") != null);
}
