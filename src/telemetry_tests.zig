//! Payload-format tests for telemetry.zig (dupDetail UTF-8 safety, OTLP
//! record emission). Split out of telemetry.zig (600-line goal); reached
//! through the `test { _ = ... }` hook there, mirroring the mcp.zig pattern.

const std = @import("std");
const Io = std.Io;
const telemetry = @import("telemetry.zig");
const Telemetry = telemetry.Telemetry;
const Event = Telemetry.Event;

test "telemetry dupDetail never yields invalid UTF-8" {
    var t: Telemetry = .{
        .io = undefined, // dupDetail only touches gpa
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    // The 200-byte cap lands mid-codepoint: 199 ASCII bytes + 2-byte 'é'.
    var buf: [201]u8 = undefined;
    @memset(buf[0..199], 'a');
    buf[199] = 0xC3;
    buf[200] = 0xA9;
    const cut = t.dupDetail(&buf);
    defer std.testing.allocator.free(cut);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
    try std.testing.expectEqual(@as(usize, 199), cut.len); // split lead byte dropped
    // Raw invalid bytes mid-string (unparseable provider response) degrade
    // to ASCII instead of corrupting the OTLP payload.
    const garbage = t.dupDetail("ok\xff\xfe more text here");
    defer std.testing.allocator.free(garbage);
    try std.testing.expect(std.unicode.utf8ValidateSlice(garbage));
    try std.testing.expect(std.mem.startsWith(u8, garbage, "ok??"));
}
test "telemetry writeOtlp emits a fleet record with kind + split prov attrs" {
    var t: Telemetry = .{
        .io = undefined, // writeOtlp(.., include_summary=false) never touches io
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    const events = [_]Telemetry.Event{.{
        .t_ms = 0,
        .body = "fleet",
        .kind = "propose",
        .detail = "abcd1234", // prompt_sha
        .extra = "reviewer", // niche
        .run_id = "deadbeef", // parent_sha
        .prov = "frontier\ta9134381", // provider_class \t eval_set_hash
    }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try t.writeOtlp(&aw.writer, &events, false);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stringValue\":\"fleet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"propose\"") != null); // kind
    try std.testing.expect(std.mem.indexOf(u8, out, "\"reviewer\"") != null); // niche
    try std.testing.expect(std.mem.indexOf(u8, out, "parent_sha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"frontier\"") != null); // provider_class (split from prov)
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a9134381\"") != null); // eval_set_hash (split from prov)
}
test "telemetry writeOtlp stamps run records with run_id (issue #168 Gap 6)" {
    var t: Telemetry = .{
        .io = undefined, // writeOtlp(.., include_summary=false) never touches io
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = undefined,
        .start_unix_ms = 0,
    };
    const events = [_]Telemetry.Event{.{
        .t_ms = 0,
        .body = "run",
        .kind = "default",
        .detail = "abcd1234", // prompt_sha
        .extra = "read,edit", // tools
        .run_id = "cafef00dcafef00d",
        .ms = 42,
        .flag = true,
    }};
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try t.writeOtlp(&aw.writer, &events, false);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stringValue\":\"run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "run_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cafef00dcafef00d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"read,edit\"") != null); // tools
}
