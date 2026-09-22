//! HTTPS SSE over http-zig. Returns null to keep the std.http/1.1 path.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const http = @import("http.zig");
const http_headers = @import("http_headers.zig");
const http_stall = @import("http_stall.zig");
const http2_pool = @import("http2_pool.zig");
const engine_sink = @import("engine_sink.zig");
const http_zig = @import("http_zig");
const WatchdogFired = http.WatchdogFired;
const watchdogError = http.watchdogError;
const deadlineStallTask = @import("http.zig").deadlineStallTask;

const ssePayload = Agent.ssePayload;
const openaiComplete = @import("agent_stream.zig").openaiComplete;
const isStreamEnd = @import("agent_stream.zig").isStreamEnd;

pub fn postStream(self: *Agent, body: []const u8) !?[]u8 {
    if (!http2_pool.want(self.provider.url)) return null;
    const origin = http2_pool.parseOrigin(self.provider.url) catch return null;
    const gpa = self.gpa;
    const provider = self.provider;
    const bearer = switch (provider.auth) {
        .x_api_key, .goog_api_key => "",
        .bearer => try std.fmt.allocPrint(gpa, "Bearer {s}", .{provider.api_key}),
    };
    defer if (bearer.len > 0) gpa.free(bearer);
    var headers_buf: [12]std.http.Header = undefined;
    var conv_buf: [96]u8 = undefined;
    const conv = http_headers.requestCacheKey(self.io, self.label, self, provider.id, &conv_buf);
    const extra = http_headers.providerHeadersWithConv(self.io, provider, bearer, &headers_buf, conv);

    var name_store: [16][64]u8 = undefined;
    var extras: [20]http_zig.Header = undefined;
    var n: usize = 0;
    extras[n] = .{ .name = "content-type", .value = "application/json" };
    n += 1;
    if (std.mem.eql(u8, provider.id, "kimi")) {
        extras[n] = .{ .name = "user-agent", .value = main_mod.kimi_user_agent };
        n += 1;
    }
    for (extra, 0..) |h, i| {
        if (i >= name_store.len or n >= extras.len) break;
        extras[n] = .{ .name = std.ascii.lowerString(&name_store[i], h.name), .value = h.value };
        n += 1;
    }

    const lease = http2_pool.acquire(gpa, self.io, origin.host, origin.port) catch return null;
    const sess = lease.session;
    var keep = false;
    defer lease.release(keep);
    var lines = sess.startLines(.{
        .method = "POST",
        .scheme = "https",
        .authority = origin.host,
        .path = origin.path,
        .extra = extras[0..n],
        .body = body,
    }) catch return null;
    defer lines.deinit();

    const status = lines.waitStatus() catch return null;
    if (status == 429) return error.RateLimited;
    if (status >= 500) return error.ServerError;
    if (status == 404 and std.mem.startsWith(u8, provider.id, "openai")) return error.OpenAiFlaky404;
    if (status < 200 or status >= 300) return null;

    const sink = engine_sink.forAgent(self);
    var full: Io.Writer.Allocating = .init(gpa);
    errdefer full.deinit();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    var loop_guard: @import("agent_model_loop.zig").Stream = .{};
    var got_body = false;
    var saw_done = false;

    stream: while (true) {
        const stall_budget = http_stall.interFrameBudgetMs(http.stream_stall_ms, got_body, self.partial_text.items.len != 0, self.stall.widen);
        read: {
            const ReadDone = union(enum) { line: anyerror!bool, stall: WatchdogFired };
            var rd_buf: [2]ReadDone = undefined;
            var rsel: Io.Select(ReadDone) = .init(self.io, &rd_buf);
            rsel.concurrent(.line, lineTask, .{ &lines, &line, gpa }) catch {
                if (saw_done) break;
                self.stall.tripped_ms = stall_budget;
                sink.emit(self.io, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = false } });
                return error.StreamStalled;
            };
            rsel.concurrent(.stall, deadlineStallTask, .{ self.io, false, stall_budget }) catch {
                const r = rsel.await() catch |e| {
                    rsel.cancelDiscard();
                    return e;
                };
                rsel.cancelDiscard();
                const more = r.line catch |e| {
                    if (saw_done) break;
                    if (got_body) {
                        sink.emit(self.io, .{ .stream_aborted = .dropped });
                        return error.StreamDropped;
                    }
                    return e;
                };
                if (!more) {
                    keep = http2_pool.keepAfter(lines.ended);
                    break;
                }
                break :read;
            };
            const first = rsel.await() catch |e| {
                rsel.cancelDiscard();
                return e;
            };
            rsel.cancelDiscard();
            switch (first) {
                .line => |r| {
                    const more = r catch |e| {
                        if (saw_done) break;
                        if (got_body) {
                            sink.emit(self.io, .{ .stream_aborted = .dropped });
                            return error.StreamDropped;
                        }
                        return e;
                    };
                    if (!more) {
                        keep = http2_pool.keepAfter(lines.ended);
                        break;
                    }
                },
                .stall => |w| {
                    if (w == .deadline and saw_done) break :stream;
                    if (w == .deadline) self.stall.tripped_ms = stall_budget;
                    if (w == .deadline) sink.emit(self.io, .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = false } }) else sink.emit(self.io, .{ .stream_aborted = .interrupted });
                    return watchdogError(w, error.StreamStalled);
                },
            }
        }
        if (ssePayload(line.items)) |payload|
            try loop_guard.event(self, payload, true);
        try full.writer.writeAll(line.items);
        try full.writer.writeByte('\n');
        got_body = true;
        self.printDelta(line.items);
        if (main_mod.g_thinking_fold_request) {
            main_mod.g_thinking_fold_request = false;
            sink.emit(self.io, .thinking_fold_toggle);
        }
        if (self.provider.kind == .openai and openaiComplete(line.items)) saw_done = true;
        if (isStreamEnd(self.scratchAlloc(), self.provider.kind, line.items)) {
            saw_done = true;
            if (lines.ended) {
                var junk: std.ArrayList(u8) = .empty;
                defer junk.deinit(gpa);
                while (lines.readLine(&junk) catch false) {}
                keep = true;
            }
            break;
        }
        if (self.sub and Agent.esc_cancel.load(.acquire)) {
            sink.emit(self.io, .{ .stream_aborted = .interrupted });
            return error.Interrupted;
        }
    }
    sink.emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
    return try full.toOwnedSlice();
}

fn lineTask(ls: *http_zig.conn.LineStream, dest: *std.ArrayList(u8), gpa: std.mem.Allocator) !bool {
    _ = gpa;
    return ls.readLine(dest);
}
