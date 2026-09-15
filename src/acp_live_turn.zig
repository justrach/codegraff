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
const proto = @import("acp_protocol.zig");

pub const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    session_id: []const u8 = "",
    saw_text: bool = false,
    inbox: ?*@import("acp_inbox.zig").Inbox = null,

    pub fn errorMessage(ctx: *anyopaque, err: anyerror) []const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        return if (err == error.ApiError) self.root.last_api_error orelse "Provider request failed" else @errorName(err);
    }

    pub fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        agent_mod.Agent.prepareRootTurn(); // #753: a prior stream cancel must not steal the continuation
        if (self.inbox) |inbox| inbox.begin();
        defer if (self.inbox) |inbox| inbox.end();
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
        switch (try @import("turn_dedup.zig").enqueue(self.root, arena, self.out, review_prompt orelse text)) {
            .started => {},
            .skipped => return "",
            .stuck => return @import("turn_dedup.zig").stuck_text,
        }
        if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(text.len, std.math.maxInt(u32))), self.root.provider.model);
        self.saw_text = false;
        var sink: stream.EventSink = undefined;
        sink.init(self.root.gpa, self.out, &self.session_id, &self.saw_text);
        defer sink.deinit();
        self.root.out = &sink.writer;
        main_mod.g_out = &sink.writer;
        defer {
            sink.writer.flush() catch {};
            self.root.out = null;
            main_mod.g_out = null;
        }
        const result = providers.runTurnWithFallback(self.root, self.keys, arena, null);
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
