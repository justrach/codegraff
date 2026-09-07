//! `/update` for the line REPL: check a release, ask a human, install for
//! the next launch. Yolo, tools, model text, and saved conversations never
//! authorize an install. ACP / pipes have no TTY picker, so they only check.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const pickers = @import("pickers.zig");
const version_status = @import("version_status.zig");
const update_target = @import("update_target.zig");
const update_service = @import("update_service.zig");

pub const installed_for_next_launch = update_target.install_note;
pub const no_activate_note = update_target.no_activate_note;

var pending_tag: [64]u8 = undefined;
var pending_tag_len: usize = 0;
var pending_target: [std.fs.max_path_bytes]u8 = undefined;
var pending_target_len: usize = 0;
var test_running: ?[]const u8 = null;
var test_target: ?[]const u8 = null;
var test_fetch: ?update_service.Fetch = null;
var test_asset: ?[]const u8 = null;
var test_cancel: ?*const std.atomic.Value(bool) = null;
var test_auto_consent: bool = false;
var suppress_picker: bool = false;

pub fn resetPending() void {
    pending_tag_len = 0;
    pending_target_len = 0;
}

pub fn setTestHooks(
    running: ?[]const u8,
    target: ?[]const u8,
    fetch: ?update_service.Fetch,
    asset: ?[]const u8,
    cancel: ?*const std.atomic.Value(bool),
    auto_consent: bool,
) void {
    test_running = running;
    test_target = target;
    test_fetch = fetch;
    test_asset = asset;
    test_cancel = cancel;
    test_auto_consent = auto_consent;
    if (target == null) resetPending();
}

fn rememberOffer(tag: []const u8, target: []const u8) void {
    pending_tag_len = @min(tag.len, pending_tag.len);
    @memcpy(pending_tag[0..pending_tag_len], tag[0..pending_tag_len]);
    pending_target_len = @min(target.len, pending_target.len);
    @memcpy(pending_target[0..pending_target_len], target[0..pending_target_len]);
}

/// Human `/update install` after a prior `/update` check in this process.
pub fn consumePending() ?update_service.Consent {
    if (pending_tag_len == 0) return null;
    pending_tag_len = 0;
    pending_target_len = 0;
    return .human;
}

pub fn hasPending() bool {
    return pending_tag_len != 0;
}

pub fn renderReport(out: *Io.Writer, report: update_service.Report) !void {
    try out.print("running:   v{s} (this process)\n", .{report.running()});
    if (report.installed()) |inst|
        try out.print("installed: v{s} ({s})\n", .{ inst, report.target })
    else if (report.target.len > 0)
        try out.print("installed: unknown ({s})\n", .{report.target});
    if (report.latest()) |latest|
        try out.print("latest:    v{s}\n", .{latest})
    else
        try out.writeAll("latest:    unable to check\n");
    switch (report.kind) {
        .available => {
            try out.print("An update is available. Install v{s} for the next launch? This session stays on v{s}.\n", .{
                report.latest() orelse "?",
                report.running(),
            });
            try out.writeAll("Type /update install after reviewing, or confirm the picker. ");
            try out.writeAll(no_activate_note);
            try out.writeByte('\n');
        },
        .already_installed => {
            try out.writeAll("That release is already installed for the next launch. This session is still running its original version.\n");
            try out.writeAll(no_activate_note);
            try out.writeByte('\n');
        },
        .current => try out.print("graff is up to date (v{s})\n", .{report.running()}),
        .newer => try out.print("running v{s} is newer than latest v{s} — not downgrading\n", .{
            report.running(),
            report.latest() orelse "?",
        }),
        .installed => {
            try out.writeAll(installed_for_next_launch);
            try out.writeByte('\n');
            try out.writeAll(no_activate_note);
            try out.writeByte('\n');
        },
        .offline => try out.writeAll("update check failed — offline or the release feed did not respond\n"),
        .malformed => try out.writeAll("update check failed — malformed release response (not guessing)\n"),
        .verify_failed => try out.writeAll("update refused — the artifact did not match the release SHA256SUMS\n"),
        .permission => try out.writeAll("update refused — the install target is not writable (not escalating privileges)\n"),
        .cancelled => try out.writeAll("update cancelled — the existing install is unchanged\n"),
        .busy => try out.writeAll("an update is already installing — this session is unchanged\n"),
        .unsupported, .package_managed, .development => {
            try out.writeAll(report.detail);
            try out.writeByte('\n');
        },
        .no_consent => try out.writeAll("update not installed — a human has to confirm in this terminal\n"),
    }
}

pub fn renderText(gpa: Allocator, report: update_service.Report) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    renderReport(&aw.writer, report) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn makeOpts(root: *Agent, target: []const u8, fetch: update_service.Fetch, asset: []const u8) update_service.Opts {
    return .{
        .io = root.io,
        .gpa = root.gpa,
        .running_version = test_running orelse @import("main.zig").harness_version,
        .target_path = target,
        .asset_name = asset,
        .fetch = fetch,
        .cancel = test_cancel,
    };
}

fn productionFetch(root: *Agent, store: *update_service.HttpFetch) update_service.Fetch {
    store.* = .{
        .io = root.io,
        .gpa = root.gpa,
        .user_agent = "simple-harness/" ++ @import("main.zig").harness_version,
    };
    return store.fetch();
}

fn resolveTarget(root: *Agent, buf: []u8) update_target.Target {
    if (test_target) |t| return .{ .kind = .supported, .path = t, .detail = "test fixture" };
    const exe = std.process.executablePathAlloc(root.io, root.gpa) catch
        return .{ .kind = .unsupported, .path = "", .detail = update_target.explain(.unsupported) };
    defer root.gpa.free(exe);
    const resolved = update_target.resolve(exe, root.home, buf);
    if (resolved.path.ptr == buf.ptr) return resolved;
    const n = @min(resolved.path.len, buf.len);
    @memcpy(buf[0..n], resolved.path[0..n]);
    return .{ .kind = resolved.kind, .path = buf[0..n], .detail = resolved.detail };
}

fn offerChoices() []const pickers.PickItem {
    return &.{
        .{ .name = "Install for the next launch", .desc = "keep this session on the original version" },
        .{ .name = "Not now", .desc = "leave the install unchanged" },
    };
}

fn confirmInstall(root: *Agent, out: *Io.Writer) bool {
    if (suppress_picker) return false;
    if (test_auto_consent) return true;
    const yolo = if (root.approvals) |a| a.yolo else false;
    _ = yolo; // yolo is not authorization
    const idx = pickers.listPicker(root, root.arena, out, "Update ›", offerChoices()) orelse return false;
    return idx == 0;
}

pub fn tryHandle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    _ = arena;
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.eql(u8, t, "/update") and !std.mem.startsWith(u8, t, "/update ")) return false;
    const arg = std.mem.trim(u8, t["/update".len..], " \t");

    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = resolveTarget(root, &target_buf);
    if (target.kind != .supported) {
        var r: update_service.Report = .{
            .kind = switch (target.kind) {
                .package_managed => .package_managed,
                .development => .development,
                else => .unsupported,
            },
            .target = target.path,
            .detail = target.detail,
        };
        const run = version_status.stripV(test_running orelse @import("main.zig").harness_version);
        const n = @min(run.len, r.running_buf.len);
        @memcpy(r.running_buf[0..n], run[0..n]);
        r.running_len = n;
        try renderReport(out, r);
        try out.flush();
        return true;
    }
    if (update_target.assetName() == null and test_asset == null) {
        try out.writeAll(update_target.explain(.unsupported));
        try out.writeByte('\n');
        try out.flush();
        return true;
    }

    var http_store: update_service.HttpFetch = undefined;
    const fetch = test_fetch orelse productionFetch(root, &http_store);
    const asset = test_asset orelse update_target.assetName().?;
    const opts = makeOpts(root, target.path, fetch, asset);

    if (std.mem.eql(u8, arg, "install")) {
        const consent = consumePending() orelse {
            try out.writeAll("Run /update first and confirm the release. Model output, tools, and yolo do not authorize an install.\n");
            try out.flush();
            return true;
        };
        const report = update_service.install(opts, consent);
        try renderReport(out, report);
        try out.flush();
        return true;
    }

    const report = update_service.inspect(opts);
    if (report.kind == .available) {
        if (report.latest_tag()) |tag| rememberOffer(tag, target.path);
        if (confirmInstall(root, out)) {
            _ = consumePending();
            const installed = update_service.install(opts, .human);
            try renderReport(out, installed);
            try out.flush();
            return true;
        }
    }
    try renderReport(out, report);
    try out.flush();
    return true;
}

/// Host callback for the TUI / zigzag repl: `check` or `install`.
pub fn hostAction(io: Io, gpa: Allocator, home: []const u8, action: []const u8) ?[]const u8 {
    suppress_picker = true;
    defer suppress_picker = false;
    var dummy: Agent = .{
        .gpa = gpa,
        .arena = gpa,
        .io = io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "update",
        .out = null,
        .home = home,
    };
    var aw: Io.Writer.Allocating = .init(gpa);
    const line: []const u8 = if (std.mem.eql(u8, action, "install")) "/update install" else "/update";
    _ = tryHandle(&dummy, gpa, line, &aw.writer) catch {
        aw.deinit();
        return null;
    };
    return aw.toOwnedSlice() catch {
        aw.deinit();
        return null;
    };
}

test "yolo and a missing pending offer are not authorization" {
    resetPending();
    try std.testing.expect(consumePending() == null);
    rememberOffer("v0.0.292", "/tmp/fixture/graff");
    try std.testing.expect(hasPending());
    try std.testing.expect(consumePending() == .human);
    try std.testing.expect(!hasPending());
}

test "success copy names the next launch and refuses /new activation" {
    try std.testing.expectEqualStrings(
        "Update installed for the next launch. This session is still running its original version; you can keep working.",
        installed_for_next_launch,
    );
    try std.testing.expect(std.mem.indexOf(u8, no_activate_note, "/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_activate_note, "/resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_activate_note, "do not activate") != null);
}
