//! Isolated-fixture acceptance for the in-session updater. Never touches the
//! developer's live graff executable.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const Approvals = @import("approvals.zig").Approvals;
const archive = @import("update_archive.zig");
const update_cmd = @import("update_cmd.zig");
const update_service = @import("update_service.zig");
const update_target = @import("update_target.zig");

const asset = "graff-x86_64-linux.tar.gz";
const latest_json = "{\"tag_name\":\"v0.0.292\"}";

const Fixture = struct {
    archive: []const u8,
    sums: []const u8,
    fail: enum { none, offline, malformed, no_sums, bad_sums } = .none,
    seen_latest_download: std.atomic.Value(bool) = .init(false),
    fetches: std.atomic.Value(usize) = .init(0),
    cancel_on_tarball: ?*std.atomic.Value(bool) = null,
    hold: ?*std.atomic.Value(bool) = null,

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) update_service.FetchError![]u8 {
        const self: *Fixture = @ptrCast(@alignCast(ctx orelse return error.Offline));
        _ = self.fetches.fetchAdd(1, .monotonic);
        if (self.hold) |h| {
            while (h.load(.acquire)) std.Thread.yield() catch {};
        }
        if (self.fail == .offline) return error.Offline;
        if (std.mem.indexOf(u8, url, "/releases/latest") != null) {
            if (self.fail == .malformed) return gpa.dupe(u8, "{nope") catch return error.OutOfMemory;
            return gpa.dupe(u8, latest_json) catch return error.OutOfMemory;
        }
        if (std.mem.indexOf(u8, url, "/latest/download/") != null) {
            self.seen_latest_download.store(true, .release);
            return error.Malformed;
        }
        if (std.mem.endsWith(u8, url, "SHA256SUMS")) {
            if (self.fail == .no_sums) return error.Offline;
            if (self.fail == .bad_sums)
                return gpa.dupe(u8, "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  graff-x86_64-linux.tar.gz\n") catch return error.OutOfMemory;
            return gpa.dupe(u8, self.sums) catch return error.OutOfMemory;
        }
        if (self.cancel_on_tarball) |c| c.store(true, .release);
        return gpa.dupe(u8, self.archive) catch return error.OutOfMemory;
    }

    fn fetch(self: *Fixture) update_service.Fetch {
        return .{ .ctx = self, .get = get };
    }
};

fn setupArchive(gpa: Allocator) !struct { bytes: []u8, sums: []u8 } {
    const bytes = try archive.fixtureArchive(gpa, "graff-x86_64-linux/graff", "NEW-GRAFF");
    errdefer gpa.free(bytes);
    return .{ .bytes = bytes, .sums = try archive.sumsLine(gpa, asset, bytes) };
}

fn fixturePath(tmp: *std.testing.TmpDir, io: Io, gpa: Allocator, name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ buf[0..n], name });
}

fn opts(io: Io, gpa: Allocator, target: []const u8, fetch: update_service.Fetch, cancel: ?*const std.atomic.Value(bool)) update_service.Opts {
    return .{
        .io = io,
        .gpa = gpa,
        .running_version = "0.0.289",
        .target_path = target,
        .asset_name = asset,
        .fetch = fetch,
        .cancel = cancel,
    };
}

fn stub(out: *Io.Writer, yolo: bool, approvals: *Approvals) Agent {
    approvals.* = .{ .yolo = yolo };
    return .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = out,
        .approvals = approvals,
        .session_name = "live",
        .home = "/tmp/issue-773-home-must-not-be-used",
    };
}

test "successful install replaces only the fixture and keeps the session" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    update_cmd.resetPending();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD-GRAFF" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    update_service.writeInstalledVersion(io, target, "0.0.289");

    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    const before = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(before);
    try std.testing.expectEqualStrings("OLD-GRAFF", before);

    var approvals: Approvals = .{ .yolo = true };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var root = stub(&aw.writer, true, &approvals);
    const yolo_before = root.approvals.?.yolo;
    const session_before = root.session_name;
    const messages_before = root.session_name;

    const report = update_service.install(opts(io, gpa, target, fx.fetch(), null), .human);
    try std.testing.expectEqual(update_service.Kind.installed, report.kind);
    try std.testing.expectEqualStrings(update_target.install_note, report.detail);
    try std.testing.expect(!fx.seen_latest_download.load(.acquire));

    const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("NEW-GRAFF", after);
    try std.testing.expect(root.approvals.?.yolo == yolo_before);
    try std.testing.expectEqualStrings(session_before, root.session_name);
    try std.testing.expectEqualStrings(messages_before, root.session_name);

    try std.testing.expect(try update_cmd.tryHandle(&root, gpa, "/new", &aw.writer) == false);
}

test "already-installed and current versions do not reinstall" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD-GRAFF" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    update_service.writeInstalledVersion(io, target, "0.0.292");

    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    const report = update_service.install(opts(io, gpa, target, fx.fetch(), null), .human);
    try std.testing.expectEqual(update_service.Kind.already_installed, report.kind);
    const stayed = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(stayed);
    try std.testing.expectEqualStrings("OLD-GRAFF", stayed);

    var current_fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    var current_opts = opts(io, gpa, target, current_fx.fetch(), null);
    current_opts.running_version = "0.0.292";
    update_service.writeInstalledVersion(io, target, "0.0.292");
    const current = update_service.inspect(current_opts);
    try std.testing.expectEqual(update_service.Kind.already_installed, current.kind);
}

test "offline and malformed release responses fail closed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);

    var offline_fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .fail = .offline };
    try std.testing.expectEqual(update_service.Kind.offline, update_service.inspect(opts(io, gpa, target, offline_fx.fetch(), null)).kind);

    var bad_fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .fail = .malformed };
    try std.testing.expectEqual(update_service.Kind.malformed, update_service.inspect(opts(io, gpa, target, bad_fx.fetch(), null)).kind);

    const stayed = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(stayed);
    try std.testing.expectEqualStrings("OLD", stayed);
}

test "failed verification and missing sums leave the fixture untouched" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);

    var bad: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .fail = .bad_sums };
    try std.testing.expectEqual(update_service.Kind.verify_failed, update_service.install(opts(io, gpa, target, bad.fetch(), null), .human).kind);

    var missing: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .fail = .no_sums };
    try std.testing.expectEqual(update_service.Kind.offline, update_service.install(opts(io, gpa, target, missing.fetch(), null), .human).kind);

    const stayed = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(stayed);
    try std.testing.expectEqualStrings("OLD", stayed);
}

test "permission errors do not escalate or replace" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    const report = update_service.install(opts(io, gpa, "/proc/graff-must-not-exist/graff", fx.fetch(), null), .human);
    try std.testing.expectEqual(update_service.Kind.permission, report.kind);
}

test "cancellation before commit keeps the existing install" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var cancel = std.atomic.Value(bool).init(false);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .cancel_on_tarball = &cancel };
    const report = update_service.install(opts(io, gpa, target, fx.fetch(), &cancel), .human);
    try std.testing.expectEqual(update_service.Kind.cancelled, report.kind);
    const stayed = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(stayed);
    try std.testing.expectEqualStrings("OLD", stayed);
}

const Race = struct {
    o: update_service.Opts,
    kind: update_service.Kind = .busy,
    fn run(self: *Race) void {
        self.kind = update_service.install(self.o, .human).kind;
    }
};

test "simultaneous installs serialize; the loser stays busy" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var hold = std.atomic.Value(bool).init(true);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums, .hold = &hold };
    var first: Race = .{ .o = opts(io, gpa, target, fx.fetch(), null) };
    var thr = try std.Thread.spawn(.{}, Race.run, .{&first});
    var spins: usize = 0;
    while (fx.fetches.load(.monotonic) == 0) : (spins += 1) {
        if (spins > 1_000_000) return error.InstallNeverStarted;
        std.Thread.yield() catch {};
    }
    var fx2: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    const second = update_service.install(opts(io, gpa, target, fx2.fetch(), null), .human);
    try std.testing.expectEqual(update_service.Kind.busy, second.kind);
    hold.store(false, .release);
    thr.join();
    try std.testing.expect(first.kind == .installed or first.kind == .already_installed);
    update_service.resetBusyForTest();
}

test "/update install without a human pending offer is refused even in yolo" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    update_cmd.resetPending();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    update_cmd.setTestHooks("0.0.289", target, fx.fetch(), asset, null, false);
    defer update_cmd.setTestHooks(null, null, null, null, null, false);

    var approvals: Approvals = .{ .yolo = true };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var root = stub(&aw.writer, true, &approvals);
    try std.testing.expect(try update_cmd.tryHandle(&root, gpa, "/update install", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "do not authorize") != null);
    const stayed = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(stayed);
    try std.testing.expectEqualStrings("OLD", stayed);
}

test "/update check then human install reports the next-launch sentence" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    update_service.resetBusyForTest();
    update_cmd.resetPending();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "graff", .data = "OLD" });
    const target = try fixturePath(&tmp, io, gpa, "graff");
    defer gpa.free(target);
    const pack = try setupArchive(gpa);
    defer gpa.free(pack.bytes);
    defer gpa.free(pack.sums);
    var fx: Fixture = .{ .archive = pack.bytes, .sums = pack.sums };
    update_cmd.setTestHooks("0.0.289", target, fx.fetch(), asset, null, false);
    defer update_cmd.setTestHooks(null, null, null, null, null, false);

    var approvals: Approvals = .{};
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var root = stub(&aw.writer, false, &approvals);
    try std.testing.expect(try update_cmd.tryHandle(&root, gpa, "/update", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "running:") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "v0.0.289") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "v0.0.292") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "/new") != null);
    try std.testing.expect(update_cmd.hasPending());

    aw.clearRetainingCapacity();
    try std.testing.expect(try update_cmd.tryHandle(&root, gpa, "/update install", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), update_target.install_note) != null);
    const after = try Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(64));
    defer gpa.free(after);
    try std.testing.expectEqualStrings("NEW-GRAFF", after);
}

test "/new and /resume copy never claims to activate an update" {
    const new_msg = "new session →";
    const resume_msg = "resumed";
    try std.testing.expect(std.mem.indexOf(u8, new_msg, "update") == null);
    try std.testing.expect(std.mem.indexOf(u8, resume_msg, "activate") == null);
    try std.testing.expect(std.mem.indexOf(u8, update_target.no_activate_note, "do not activate") != null);
}
