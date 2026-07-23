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

test "telemetry error events never retain or serialize raw detail" {
    var t: Telemetry = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(std.testing.io, .awake),
        .start_unix_ms = 0,
    };
    defer t.deinit();
    t.errorEvent("api", "provider echoed sk-proj-private-canary and /private/source.zig");
    try std.testing.expectEqual(@as(usize, 1), t.events.items.len);
    try std.testing.expectEqualStrings("", t.events.items[0].detail);
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try t.writeOtlp(&aw.writer, t.events.items, false);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sk-proj-private-canary") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/private/source.zig") == null);
}
test "telemetry writeOtlp emits a fleet record with kind + split prov attrs" {
    const io = std.testing.io;
    const previous_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    learning_privacy.setMode(io, .aggregate);
    defer main_mod.g_fleet = previous_fleet;
    defer learning_privacy.setMode(io, .local);
    var t: Telemetry = .{
        .io = io,
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
    const io = std.testing.io;
    const previous_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    learning_privacy.setMode(io, .aggregate);
    defer main_mod.g_fleet = previous_fleet;
    defer learning_privacy.setMode(io, .local);
    var t: Telemetry = .{
        .io = io,
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

test "send-time privacy and fleet state revoke buffered learning egress" {
    const io = std.testing.io;
    const previous_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    defer main_mod.g_fleet = previous_fleet;
    defer learning_privacy.setMode(io, .local);
    var t: Telemetry = .{
        .io = io,
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = 0,
    };
    defer t.deinit();
    const prompt = "private approved template bytes";
    const prompt_fp = scoring.promptFingerprint(prompt);
    learning_privacy.setMode(io, .templates);
    try std.testing.expect(learning_privacy.approveTemplate(io, prompt));
    t.fleetEvent("propose", "reviewer", &prompt_fp, "", "frontier", "", 0, prompt);
    try std.testing.expectEqualStrings(prompt, t.events.items[0].text);

    learning_privacy.setMode(io, .local);
    var local_payload: Io.Writer.Allocating = .init(std.testing.allocator);
    defer local_payload.deinit();
    try t.writeOtlp(&local_payload.writer, t.events.items, false);
    try std.testing.expect(std.mem.indexOf(u8, local_payload.written(), prompt) == null);
    try std.testing.expect(std.mem.indexOf(u8, local_payload.written(), "\"stringValue\":\"fleet\"") == null);

    learning_privacy.setMode(io, .templates); // mode change cleared exact approval
    var revoked_payload: Io.Writer.Allocating = .init(std.testing.allocator);
    defer revoked_payload.deinit();
    try t.writeOtlp(&revoked_payload.writer, t.events.items, false);
    try std.testing.expect(std.mem.indexOf(u8, revoked_payload.written(), "\"stringValue\":\"fleet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, revoked_payload.written(), prompt) == null);

    try std.testing.expect(learning_privacy.approveTemplate(io, prompt));
    main_mod.g_fleet = false;
    var fleet_off_payload: Io.Writer.Allocating = .init(std.testing.allocator);
    defer fleet_off_payload.deinit();
    try t.writeOtlp(&fleet_off_payload.writer, t.events.items, false);
    try std.testing.expect(std.mem.indexOf(u8, fleet_off_payload.written(), prompt) == null);
    try std.testing.expect(std.mem.indexOf(u8, fleet_off_payload.written(), "\"stringValue\":\"fleet\"") == null);
}

test "fleet egress projects free-form metadata and rejects unknown records" {
    const io = std.testing.io;
    const previous_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    learning_privacy.setMode(io, .aggregate);
    defer main_mod.g_fleet = previous_fleet;
    defer learning_privacy.setMode(io, .local);
    var t: Telemetry = .{
        .io = io,
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('0'),
        .client_name = "harness",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = 0,
    };
    defer t.deinit();
    t.fleetEvent("submit", "client-secret-project", "private-prompt-label", "/private/parent", "private-provider", "/private/evals/customer-a.json", 0, "");
    t.fleetEvent("private-event-kind", "reviewer", "0123456789abcdef", "", "frontier", "", 0, "");
    var payload: Io.Writer.Allocating = .init(std.testing.allocator);
    defer payload.deinit();
    try t.writeOtlp(&payload.writer, t.events.items, false);
    const out = payload.written();
    for ([_][]const u8{
        "client-secret-project",
        "private-prompt-label",
        "/private/parent",
        "private-provider",
        "/private/evals/customer-a.json",
        "private-event-kind",
    }) |canary| try std.testing.expect(std.mem.indexOf(u8, out, canary) == null);
    const prompt_fp = scoring.promptFingerprint("private-prompt-label");
    const eval_fp = scoring.promptFingerprint("/private/evals/customer-a.json");
    try std.testing.expect(std.mem.indexOf(u8, out, &prompt_fp) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, &eval_fp) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "custom-") != null);
}

test "explicit learning resource omits stable and platform identifiers" {
    const io = std.testing.io;
    const previous_fleet = main_mod.g_fleet;
    main_mod.g_fleet = true;
    learning_privacy.setMode(io, .aggregate);
    defer main_mod.g_fleet = previous_fleet;
    defer learning_privacy.setMode(io, .local);
    var t: Telemetry = .{
        .io = io,
        .gpa = std.testing.allocator,
        .endpoint = "x",
        .install_id = @splat('z'),
        .client_name = "harness-learn",
        .sdk_install_id = "private-stable-sdk-id",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = 0,
    };
    defer t.deinit();
    t.scoreEvent("abcd", "", 1.0, "run", "sig", "");
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try t.writeOtlp(&aw.writer, t.events.items, false);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"client.name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"harness-learn\"") != null);
    for ([_][]const u8{ "install.id", "sdk.install.id", "service.version", "os.type", "host.arch", "private-stable-sdk-id" }) |excluded|
        try std.testing.expect(std.mem.indexOf(u8, out, excluded) == null);
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
