//! Payload-format tests for telemetry.zig (dupDetail UTF-8 safety, OTLP
//! record emission). Split out of telemetry.zig (600-line goal); reached
//! through the `test { _ = ... }` hook there, mirroring the mcp.zig pattern.

const std = @import("std");
const Io = std.Io;
const telemetry = @import("telemetry.zig");
const Telemetry = telemetry.Telemetry;
const Event = Telemetry.Event;
const learning_privacy = @import("learning_privacy.zig");
const main_mod = @import("main.zig");
const scoring = @import("scoring.zig");

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

test "learning privacy gates fleet metadata, scores, and exact template text" {
    const io = std.testing.io;
    main_mod.g_fleet = true;
    var t: Telemetry = .{
        .io = io,
        .gpa = std.testing.allocator,
        .endpoint = "https://collector.invalid/v1/logs",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = 0,
    };
    defer t.deinit();
    defer learning_privacy.setMode(io, .local);
    const prompt = "You are an exact private reviewer template.";
    const prompt_fp = scoring.promptFingerprint(prompt);

    learning_privacy.setMode(io, .local);
    t.fleetEvent("propose", "reviewer", &prompt_fp, "", "frontier", "", 0, prompt);
    t.scoreEvent("abcd", "", 1.0, "run", "sig", "");
    t.runEvent(&prompt_fp, true, true, 1, "read_file");
    t.countVariant();
    try std.testing.expectEqual(@as(usize, 0), t.events.items.len);
    try std.testing.expectEqual(@as(u64, 0), t.prompt_variants);

    learning_privacy.setMode(io, .aggregate);
    t.fleetEvent("propose", "reviewer", &prompt_fp, "", "frontier", "", 0, prompt);
    t.scoreEvent("abcd", "", 1.0, "run", "sig", "");
    t.runEvent(&prompt_fp, true, true, 1, "read_file");
    t.countVariant();
    try std.testing.expectEqual(@as(usize, 3), t.events.items.len);
    try std.testing.expectEqual(@as(u64, 1), t.prompt_variants);
    try std.testing.expectEqualStrings("", t.events.items[0].text);

    learning_privacy.setMode(io, .templates);
    t.fleetEvent("propose", "reviewer", &prompt_fp, "", "frontier", "", 0, prompt);
    try std.testing.expectEqualStrings("", t.events.items[3].text);
    try std.testing.expect(learning_privacy.approveTemplate(io, prompt));
    t.fleetEvent("propose", "reviewer", &prompt_fp, "", "frontier", "", 0, prompt);
    try std.testing.expectEqualStrings(prompt, t.events.items[4].text);

    const canary = "OPENAI_API_KEY=sk-proj-test-only";
    const canary_fp = scoring.promptFingerprint(canary);
    try std.testing.expect(!learning_privacy.approveTemplate(io, canary));
    t.fleetEvent("propose", "reviewer", &canary_fp, "", "frontier", "", 0, canary);
    try std.testing.expectEqualStrings("", t.events.items[5].text);
}
