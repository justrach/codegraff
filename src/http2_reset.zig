//! Sanitized HTTP/2 RST_STREAM and GOAWAY classification (RFC 9113 §7, §8.7).
//! Observes wire frame headers + error codes on a leased Conn without buffering
//! ahead of `http_zig` or copying peer debug payloads.

const std = @import("std");
const Io = std.Io;
const http_zig = @import("http_zig");

pub const err_no_error: u32 = 0x0;
pub const err_protocol_error: u32 = 0x1;
pub const err_internal_error: u32 = 0x2;
pub const err_flow_control_error: u32 = 0x3;
pub const err_settings_timeout: u32 = 0x4;
pub const err_stream_closed: u32 = 0x5;
pub const err_frame_size_error: u32 = 0x6;
pub const err_refused_stream: u32 = 0x7;
pub const err_cancel: u32 = 0x8;
pub const err_compression_error: u32 = 0x9;
pub const err_connect_error: u32 = 0xa;
pub const err_enhance_your_calm: u32 = 0xb;
pub const err_inadequate_security: u32 = 0xc;
pub const err_http_1_1_required: u32 = 0xd;

pub const Stage = enum {
    send,
    wait,
    body,

    pub fn label(self: Stage) []const u8 {
        return switch (self) {
            .send => "request_send",
            .wait => "headers_wait",
            .body => "response_body",
        };
    }
};

pub fn codeName(code: u32) []const u8 {
    return switch (code) {
        err_no_error => "NO_ERROR",
        err_protocol_error => "PROTOCOL_ERROR",
        err_internal_error => "INTERNAL_ERROR",
        err_flow_control_error => "FLOW_CONTROL_ERROR",
        err_settings_timeout => "SETTINGS_TIMEOUT",
        err_stream_closed => "STREAM_CLOSED",
        err_frame_size_error => "FRAME_SIZE_ERROR",
        err_refused_stream => "REFUSED_STREAM",
        err_cancel => "CANCEL",
        err_compression_error => "COMPRESSION_ERROR",
        err_connect_error => "CONNECT_ERROR",
        err_enhance_your_calm => "ENHANCE_YOUR_CALM",
        err_inadequate_security => "INADEQUATE_SECURITY",
        err_http_1_1_required => "HTTP_1_1_REQUIRED",
        else => "UNKNOWN_ERROR",
    };
}

fn formatCode(code: u32, buf: []u8) []const u8 {
    if (code <= 0xff) {
        return std.fmt.bufPrint(buf, "{s}/0x{x}", .{ codeName(code), code }) catch codeName(code);
    }
    return codeName(code);
}

fn isH2ResetError(err: anyerror) bool {
    return err == error.RstStream or err == error.StreamRefused or err == error.GoAway or err == error.InvalidGoAway;
}

pub const Diag = struct {
    active: bool = false,
    stage: Stage = .wait,
    reused: bool = false,
    rst_code: ?u32 = null,
    goaway_code: ?u32 = null,

    pub fn clear(self: *Diag) void {
        self.* = .{};
    }

    pub fn formatSummary(self: Diag, buf: []u8) ?[]const u8 {
        if (!self.active) return null;
        const conn_kind: []const u8 = if (self.reused) "reused" else "fresh";
        var rst_buf: [40]u8 = undefined;
        var go_buf: [40]u8 = undefined;
        if (self.rst_code) |rc| {
            const rst = formatCode(rc, &rst_buf);
            if (self.goaway_code) |gc| {
                const go = formatCode(gc, &go_buf);
                return std.fmt.bufPrint(buf, "remote h2 reset: {s} during {s} on {s} connection, goaway {s}", .{
                    rst, self.stage.label(), conn_kind, go,
                }) catch null;
            }
            return std.fmt.bufPrint(buf, "remote h2 reset: {s} during {s} on {s} connection", .{
                rst, self.stage.label(), conn_kind,
            }) catch null;
        }
        if (self.goaway_code) |gc| {
            const go = formatCode(gc, &go_buf);
            return std.fmt.bufPrint(buf, "remote h2 goaway: {s} during {s} on {s} connection", .{
                go, self.stage.label(), conn_kind,
            }) catch null;
        }
        return std.fmt.bufPrint(buf, "during {s} on {s} connection", .{
            self.stage.label(), conn_kind,
        }) catch null;
    }

    pub fn errorLabel(self: Diag, err: anyerror, buf: []u8) []const u8 {
        if (isH2ResetError(err)) {
            var sum_buf: [144]u8 = undefined;
            if (self.formatSummary(&sum_buf)) |summary| {
                return std.fmt.bufPrint(buf, "{t} ({s})", .{ err, summary }) catch @errorName(err);
            }
        }
        return @errorName(err);
    }

    pub fn giveUpLabel(self: Diag, err: anyerror, down: []const u8, buf: []u8) []const u8 {
        if (down.len > 0) {
            return std.fmt.bufPrint(buf, "{t} at {s}", .{ err, down }) catch @errorName(err);
        }
        return self.errorLabel(err, buf);
    }

    pub fn giveUpApiError(
        self: Diag,
        arena: std.mem.Allocator,
        failure_kind: []const u8,
        err: anyerror,
        down: []const u8,
        max_attempts: usize,
    ) ?[]const u8 {
        if (down.len == 0 and isH2ResetError(err)) {
            var sum_buf: [144]u8 = undefined;
            if (self.formatSummary(&sum_buf)) |summary| {
                return std.fmt.allocPrint(arena, "{s}: {s} ({s}; gave up after {d} attempts)", .{
                    failure_kind, @errorName(err), summary, max_attempts,
                }) catch null;
            }
        }
        return std.fmt.allocPrint(arena, "{s}: {s}{s}{s} (gave up after {d} attempts)", .{
            failure_kind,
            @errorName(err),
            if (down.len > 0) " at " else "",
            down,
            max_attempts,
        }) catch null;
    }
};

pub const FrameTap = struct {
    inner: ?*Io.Reader = null,
    target_sid: u31 = 0,
    reused: bool = false,
    rst_code: ?u32 = null,
    goaway_code: ?u32 = null,
    goaway_last_sid: ?u31 = null,
    hdr: [9]u8 = undefined,
    hdr_len: u8 = 0,
    rem_payload: usize = 0,
    cur_typ: u8 = 0,
    cur_sid: u31 = 0,
    pay: [8]u8 = undefined,
    pay_len: u8 = 0,
    interface: Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },

    pub fn attach(self: *FrameTap, conn: *http_zig.Conn, reused: bool) void {
        self.* = .{
            .inner = conn.reader,
            .target_sid = conn.next_stream,
            .reused = reused,
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
        };
        conn.reader = &self.interface;
    }

    pub fn detach(self: *FrameTap, conn: *http_zig.Conn, conn_live: bool) void {
        if (self.inner) |orig| {
            if (conn_live and conn.reader == &self.interface) conn.reader = orig;
            self.inner = null;
        }
    }

    pub fn refineError(self: *const FrameTap, err: anyerror) anyerror {
        if (err == error.RstStream and self.rst_code == err_http_1_1_required) return error.Http11Required;
        if (err == error.GoAway and self.goaway_code == err_http_1_1_required) return error.Http11Required;
        return err;
    }

    pub fn diag(self: *const FrameTap, stage: Stage) Diag {
        return .{
            .active = true,
            .stage = stage,
            .reused = self.reused,
            .rst_code = self.rst_code,
            .goaway_code = self.goaway_code,
        };
    }

    pub fn observe(self: *FrameTap, chunk: []const u8) void {
        var rest = chunk;
        while (rest.len > 0) {
            if (self.hdr_len < 9) {
                const need: usize = 9 - self.hdr_len;
                const take = @min(need, rest.len);
                @memcpy(self.hdr[self.hdr_len..][0..take], rest[0..take]);
                self.hdr_len += @intCast(take);
                rest = rest[take..];
                if (self.hdr_len < 9) return;
                self.rem_payload = (@as(usize, self.hdr[0]) << 16) | (@as(usize, self.hdr[1]) << 8) | self.hdr[2];
                self.cur_typ = self.hdr[3];
                self.cur_sid = @truncate(((@as(u32, self.hdr[5]) << 24) | (@as(u32, self.hdr[6]) << 16) | (@as(u32, self.hdr[7]) << 8) | self.hdr[8]) & 0x7fff_ffff);
                self.pay_len = 0;
                if (self.rem_payload == 0) {
                    self.hdr_len = 0;
                    continue;
                }
            }
            const take = @min(self.rem_payload, rest.len);
            if (self.pay_len < 8) {
                const cap = @min(@as(usize, 8 - self.pay_len), take);
                @memcpy(self.pay[self.pay_len..][0..cap], rest[0..cap]);
                self.pay_len += @intCast(cap);
            }
            self.rem_payload -= take;
            rest = rest[take..];
            if (self.rem_payload == 0) {
                self.finishFrame();
                self.hdr_len = 0;
            }
        }
    }

    fn finishFrame(self: *FrameTap) void {
        if (self.cur_typ == 3 and self.pay_len >= 4) {
            if (self.target_sid == 0 or self.cur_sid == self.target_sid) {
                self.rst_code = std.mem.readInt(u32, self.pay[0..4], .big);
            }
        } else if (self.cur_typ == 7 and self.pay_len >= 8) {
            self.goaway_last_sid = @truncate(std.mem.readInt(u32, self.pay[0..4], .big) & 0x7fff_ffff);
            self.goaway_code = std.mem.readInt(u32, self.pay[4..8], .big);
        }
    }

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *FrameTap = @alignCast(@fieldParentPtr("interface", r));
        const inner = self.inner orelse return error.ReadFailed;
        var scratch: [4096]u8 = undefined;
        const max_n = limit.minInt(scratch.len);
        if (max_n == 0) return 0;
        const n = inner.readSliceShort(scratch[0..max_n]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        self.observe(scratch[0..n]);
        try w.writeAll(scratch[0..n]);
        return n;
    }
};

test "FrameTap captures RST_STREAM and GOAWAY codes across split byte chunks without buffering ahead" {
    const gpa = std.testing.allocator;
    var wire: Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    try http_zig.frame.write(&wire.writer, .{ .typ = .settings, .flags = 0, .stream_id = 0, .payload = &.{} });
    // RST_STREAM on another stream must be ignored.
    var other_rst: [4]u8 = undefined;
    std.mem.writeInt(u32, &other_rst, err_cancel, .big);
    try http_zig.frame.write(&wire.writer, .{ .typ = .rst_stream, .flags = 0, .stream_id = 3, .payload = &other_rst });
    // GOAWAY carrying debug text: only the RFC code is kept, never raw peer text.
    var goaway: [20]u8 = undefined;
    std.mem.writeInt(u32, goaway[0..4], 1, .big);
    std.mem.writeInt(u32, goaway[4..8], err_enhance_your_calm, .big);
    @memcpy(goaway[8..20], "secret-debug");
    try http_zig.frame.write(&wire.writer, .{ .typ = .goaway, .flags = 0, .stream_id = 0, .payload = &goaway });
    var our_rst: [4]u8 = undefined;
    std.mem.writeInt(u32, &our_rst, err_protocol_error, .big);
    try http_zig.frame.write(&wire.writer, .{ .typ = .rst_stream, .flags = 0, .stream_id = 1, .payload = &our_rst });

    var tap: FrameTap = .{ .target_sid = 1, .reused = false };
    for (wire.written()) |b| tap.observe(&.{b});
    try std.testing.expectEqual(@as(?u32, err_protocol_error), tap.rst_code);
    try std.testing.expectEqual(@as(?u32, err_enhance_your_calm), tap.goaway_code);
    try std.testing.expectEqual(@as(?u31, 1), tap.goaway_last_sid);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const d = tap.diag(.wait);
    const msg = d.giveUpApiError(arena_state.allocator(), "network error", error.RstStream, "", 6).?;
    try std.testing.expectEqualStrings(
        "network error: RstStream (remote h2 reset: PROTOCOL_ERROR/0x1 during headers_wait on fresh connection, goaway ENHANCE_YOUR_CALM/0xb; gave up after 6 attempts)",
        msg,
    );
    try std.testing.expect(std.mem.indexOf(u8, msg, "secret-debug") == null);
    try std.testing.expect(@import("headless_result.zig").classify(error.ApiError, msg).retryable);
    try std.testing.expectEqual(@as(u8, 75), @import("headless_result.zig").classify(error.ApiError, msg).exit_code);
    try std.testing.expectEqual(@import("subagent_run.zig").FailKind.transport, @import("subagent_run.zig").classifyFailure(error.ApiError, msg));
    try std.testing.expect(!@import("providers.zig").failoverEligible("kimi", msg));
}

test "Diag leaves non-H2 errors untouched and sanitizes out-of-range vendor codes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inactive: Diag = .{};
    try std.testing.expectEqualStrings(
        "network error: EndOfStream (gave up after 6 attempts)",
        inactive.giveUpApiError(arena, "network error", error.EndOfStream, "", 6).?,
    );

    const vendor: Diag = .{ .active = true, .stage = .send, .reused = true, .rst_code = 0x401 };
    const msg = vendor.giveUpApiError(arena, "network error", error.RstStream, "", 6).?;
    try std.testing.expectEqualStrings(
        "network error: RstStream (remote h2 reset: UNKNOWN_ERROR during request_send on reused connection; gave up after 6 attempts)",
        msg,
    );
    try std.testing.expect(!@import("providers.zig").failoverEligible("kimi", msg));
}
