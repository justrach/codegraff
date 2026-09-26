//! `graff peer`: the device's agent rooms for any agent with a shell (Claude
//! Code, Codex, scripts), not only graff sessions. The rooms are the same
//! JSONL logs graff sessions use (ADR 0004, 0134); Accord wakes a recipient.
//!
//!   graff peer list [--json]                live agents on this device
//!   graff peer send [--to NAME] [TEXT]      worktree room, or a DM (stdin if no TEXT)
//!   graff peer inbox [--peek] [--json]      new messages since the last read
//!   graff peer inbox --wake                 one line when there is mail (for hooks)
//!
//! Identity: `--as NAME`, else `$GRAFF_PEER_NAME`, else `<agent>@<folder>`.
//! The presence record is owned by the nearest non-shell ancestor, so it lives
//! as long as the agent process and is reaped with it. A send to someone who
//! wrote to you after your last read is held until you read it (`--anyway`
//! sends regardless) — a reply should answer the latest message, not an
//! earlier one.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const accord = @import("accord");
const presence = @import("presence.zig");
const presence_chan = @import("presence_chan.zig");
const presence_record = @import("presence_record.zig");
const presence_accord = @import("presence_accord.zig");
const peer_target = @import("peer_target.zig");
const proc_identity = @import("proc_identity.zig");
const worktree_lease = @import("worktree_lease.zig");
const util = @import("util.zig");

const Message = presence_chan.Message;
const Owner = worktree_lease.Owner;

pub const usage =
    \\usage: graff peer <list|send|inbox> [options]
    \\  list [--json]                      live agents on this device
    \\  send [--to NAME] [--anyway] TEXT   post to this worktree's room, or DM NAME (TEXT or stdin)
    \\  inbox [--peek] [--json] [--wake]   messages since your last read
    \\  --as NAME                          your name (default $GRAFF_PEER_NAME or agent@folder)
    \\
;

pub const Opts = struct {
    action: []const u8 = "",
    as: ?[]const u8 = null,
    to: ?[]const u8 = null,
    text: []const u8 = "",
    json: bool = false,
    peek: bool = false,
    wake: bool = false,
    anyway: bool = false,
};

pub fn parseOpts(arena: Allocator, args: []const []const u8) error{ Usage, OutOfMemory }!Opts {
    var o: Opts = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--as") or std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (a[2] == 'a') o.as = args[i] else o.to = args[i];
        } else if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--peek")) {
            o.peek = true;
        } else if (std.mem.eql(u8, a, "--wake")) {
            o.wake = true;
        } else if (std.mem.eql(u8, a, "--anyway")) {
            o.anyway = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.Usage;
        } else if (o.action.len == 0) {
            o.action = a;
        } else {
            try words.append(arena, a);
        }
    }
    if (o.action.len == 0) return error.Usage;
    o.text = try std.mem.join(arena, " ", words.items);
    return o;
}

/// Everything a room operation needs, so tests can point it at a tmp dir.
pub const Ctx = struct {
    dir: Io.Dir,
    name: []const u8,
    owner: proc_identity.Record,
    identity: []const u8,
};

pub const Room = enum { tree, device };
pub const Heard = struct { room: Room, m: Message };

/// Per-agent read position, beside the records in ~/.graff/live.
pub const Cursor = struct {
    tree_room: []const u8 = "",
    tree: u64 = 0,
    device: u64 = 0,
};

const shells = [_][]const u8{ "sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh", "env", "nohup", "timeout", "xargs", "sudo" };

pub fn isShell(comm: []const u8) bool {
    const c = std.mem.trimStart(u8, comm, "-");
    for (shells) |s| if (std.mem.eql(u8, c, s)) return true;
    return false;
}

pub const Ancestor = struct {
    rec: proc_identity.Record,
    info: proc_identity.Parent,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    /// A readable agent name. Versioned installs run a binary named like
    /// `2.1.282`, so fall back to the executable path's nearest real folder.
    pub fn comm(a: *const Ancestor) []const u8 {
        const c = std.mem.trimStart(u8, a.info.comm(), "-");
        if (c.len > 0 and std.ascii.isAlphabetic(c[0])) return c;
        return labelFromPath(a.path_buf[0..a.path_len]) orelse "agent";
    }
};

/// Last path component that names a program: starts with a letter and is not
/// packaging (`versions`, `bin`, app bundle folders).
pub fn labelFromPath(path: []const u8) ?[]const u8 {
    const skip = [_][]const u8{ "versions", "bin", "libexec", "Resources", "MacOS", "Contents", "current" };
    var it = std.mem.splitBackwardsScalar(u8, path, '/');
    outer: while (it.next()) |part| {
        if (part.len == 0 or !std.ascii.isAlphabetic(part[0])) continue;
        for (skip) |s| if (std.mem.eql(u8, part, s)) continue :outer;
        return part;
    }
    return null;
}

extern "c" fn proc_pidpath(pid: c_int, buf: [*]u8, size: u32) c_int;

fn exePath(pid: i32, buf: []u8) usize {
    switch (builtin.os.tag) {
        .macos => {
            const n = proc_pidpath(pid, buf.ptr, @intCast(buf.len));
            return if (n > 0) @intCast(n) else 0;
        },
        .linux => {
            // Raw syscall, like proc_identity: Io.Dir reads under /proc can
            // panic on the io_uring backend.
            var lb: [64]u8 = undefined;
            const link = std.fmt.bufPrintZ(&lb, "/proc/{d}/exe", .{pid}) catch return 0;
            const rc = std.os.linux.readlink(link, buf.ptr, buf.len);
            return if (@as(isize, @bitCast(rc)) < 0) 0 else rc;
        },
        else => return 0,
    }
}

/// The long-lived agent behind this command: the nearest ancestor that is not
/// a shell. Falls back to the direct parent.
pub fn agentAncestor(io: Io) ?Ancestor {
    const self = proc_identity.parentOf(proc_identity.selfPid()) orelse return null;
    var pid = self.ppid;
    var depth: usize = 0;
    while (depth < 8 and pid > 1) : (depth += 1) {
        const p = proc_identity.parentOf(pid) orelse break;
        if (!isShell(p.comm())) {
            const start: u64 = switch (proc_identity.probe(io, pid)) {
                .id => |v| v,
                else => 0,
            };
            var a: Ancestor = .{ .rec = .{ .pid = pid, .start_id = start }, .info = p };
            a.path_len = exePath(pid, &a.path_buf);
            return a;
        }
        pid = p.ppid;
    }
    return .{ .rec = .{ .pid = self.ppid, .start_id = 0 }, .info = .{ .ppid = 0 } };
}

/// "zigrepper" for /x/zigrepper/.git; "zigrepper:wt" for a linked worktree.
pub fn folderLabel(identity: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOf(u8, identity, "/.git/worktrees/")) |at| {
        const repo = std.fs.path.basename(identity[0..at]);
        const wt = std.fs.path.basename(identity);
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ repo, wt }) catch repo;
    }
    const trimmed = if (std.mem.endsWith(u8, identity, "/.git")) identity[0 .. identity.len - 5] else identity;
    return std.fs.path.basename(trimmed);
}

/// One record per (owner process, name): a harness may run several named
/// agents under one process.
fn recordName(buf: []u8, owner: proc_identity.Record, name: []const u8) []const u8 {
    var slug_buf: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{d}-{x}-{s}.ext.json", .{ owner.pid, owner.start_id, peer_target.slugify(name, &slug_buf) }) catch "";
}

fn cursorName(buf: []u8, name: []const u8) []const u8 {
    var slug_buf: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "ext-{s}.cursor", .{peer_target.slugify(name, &slug_buf)}) catch "ext.cursor";
}

fn treeRoomName(buf: *[presence_chan.chan_name_max]u8, identity: []const u8) []const u8 {
    return if (identity.len == 0) "" else presence_chan.chanName(buf, identity);
}

/// Write (or refresh) this agent's presence record so graff sessions can list
/// and address it.
pub fn join(io: Io, arena: Allocator, ctx: Ctx) void {
    var buf: [160]u8 = undefined;
    const text = presence_record.formatRecord(arena, .{
        .pid = ctx.owner.pid,
        .start_id = ctx.owner.start_id,
        .session_id = ctx.name,
        .identity = ctx.identity,
        .last_seen_ms = util.unixMs(io),
        .activity = "external",
        .title = ctx.name,
        .session_base = ctx.name,
    }) catch return;
    ctx.dir.writeFile(io, .{ .sub_path = recordName(&buf, ctx.owner, ctx.name), .data = text }) catch {};
}

/// Null when this agent never read before: the caller joins at the tail.
pub fn loadCursor(io: Io, arena: Allocator, ctx: Ctx) ?Cursor {
    var buf: [96]u8 = undefined;
    const text = ctx.dir.readFileAlloc(io, cursorName(&buf, ctx.name), arena, .limited(4096)) catch return null;
    return std.json.parseFromSliceLeaky(Cursor, arena, text, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn saveCursor(io: Io, arena: Allocator, ctx: Ctx, cur: Cursor) void {
    var buf: [96]u8 = undefined;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(cur) catch return;
    ctx.dir.writeFile(io, .{ .sub_path = cursorName(&buf, ctx.name), .data = aw.writer.buffered() }) catch {};
}

pub fn tailCursor(io: Io, arena: Allocator, ctx: Ctx) Cursor {
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = treeRoomName(&tb, ctx.identity);
    return .{
        .tree_room = arena.dupe(u8, tree) catch "",
        .tree = if (tree.len > 0) presence_chan.roomSize(io, ctx.dir, tree) else 0,
        .device = presence_chan.roomSize(io, ctx.dir, presence.device_room),
    };
}

/// New messages for this agent since `cur`, advancing it. The working-set
/// rules are graff's own (peer_target): every unaddressed worktree line, and
/// only lines addressed to us (or the user's /tell all) from the device room.
pub fn collect(io: Io, arena: Allocator, ctx: Ctx, cur: *Cursor) []const Heard {
    var out: std.ArrayList(Heard) = .empty;
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const tree = treeRoomName(&tb, ctx.identity);
    if (tree.len > 0) {
        // Moved to another folder: start that room at its tail.
        if (!std.mem.eql(u8, cur.tree_room, tree)) {
            cur.tree_room = arena.dupe(u8, tree) catch tree;
            cur.tree = presence_chan.roomSize(io, ctx.dir, tree);
        }
        for (presence_chan.readNewMessages(io, arena, ctx.dir, tree, &cur.tree)) |m| {
            if (isOwn(m, ctx.name) or !peer_target.treeHears(m, ctx.name)) continue;
            out.append(arena, .{ .room = .tree, .m = m }) catch break;
        }
    }
    for (presence_chan.readNewMessages(io, arena, ctx.dir, presence.device_room, &cur.device)) |m| {
        if (isOwn(m, ctx.name) or !peer_target.deviceHears(m, ctx.name)) continue;
        out.append(arena, .{ .room = .device, .m = m }) catch break;
    }
    return out.items;
}

fn isOwn(m: Message, name: []const u8) bool {
    return std.mem.eql(u8, m.from_session, name);
}

/// Unread messages from the agent we are about to send to. Non-empty means
/// the send is held: they said something after our last read.
pub fn unreadFrom(heard: []const Heard, target: Owner) usize {
    var n: usize = 0;
    for (heard) |h| {
        if (std.mem.eql(u8, h.m.from_session, target.session_id) or h.m.from_pid == target.pid) n += 1;
    }
    return n;
}

pub fn livePeers(io: Io, arena: Allocator, ctx: Ctx) []const Owner {
    const peers = presence.listPeersBounded(io, arena, ctx.dir, 64);
    var out: std.ArrayList(Owner) = .empty;
    for (peers.records) |rec| {
        if (rec.pid == ctx.owner.pid and std.mem.eql(u8, rec.session_id, ctx.name)) continue;
        out.append(arena, rec) catch break;
    }
    return out.items;
}

pub fn writeHeard(w: *Io.Writer, h: Heard) !void {
    const secs: u64 = @intCast(@divFloor(@max(h.m.ts_ms, 0), 1000));
    const day = secs % 86400;
    const to = if (h.m.to.len == 0) "all" else h.m.to;
    try w.print("[{s} from=@{s} to={s} {d:0>2}:{d:0>2}:{d:0>2}Z] {s}\n", .{
        @tagName(h.room), h.m.from_session, to, day / 3600, (day / 60) % 60, day % 60, h.m.text,
    });
}

/// Wake a live graff session over its Accord socket. The receiver only needs
/// the frame kind to start draining, so an oversize line is replaced by a
/// small marker instead of being dropped.
pub fn wake(io: Io, gpa: Allocator, dir_path: []const u8, rec: Owner, line: []const u8) void {
    if (!presence_accord.enabled()) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}-{x}.accord.sock", .{ dir_path, rec.pid, rec.start_id }) catch return;
    if (!presence_accord.fitsUnixSocketPath(path)) return;
    const addr = Io.net.UnixAddress.init(path) catch return;
    const stream = addr.connect(io) catch return;
    const sess = gpa.create(accord.Session) catch {
        stream.close(io);
        return;
    };
    defer gpa.destroy(sess);
    sess.* = .{ .io = io, .gpa = gpa, .role = .client, .stream = stream };
    sess.start() catch {
        sess.shutdown();
        return;
    };
    defer sess.shutdown();
    const payload = if (line.len <= accord.max_payload) line else "{\"kind\":\"wake\"}";
    sess.send(1, .msg, .{}, payload) catch {};
}

pub const SendResult = union(enum) {
    posted: struct { room: Room, target: ?Owner, woke: usize },
    held: []const Heard,
    no_target,
    ambiguous: []const Owner,
    no_room,
};

pub fn send(io: Io, gpa: Allocator, arena: Allocator, dir_path: []const u8, ctx: Ctx, cur: *Cursor, to: ?[]const u8, text: []const u8, anyway: bool) SendResult {
    const peers = livePeers(io, arena, ctx);
    var target: ?Owner = null;
    if (to) |want| switch (peer_target.resolvePeer(peers, want)) {
        .one => |p| target = p,
        .none => return .no_target,
        .ambiguous => return .{ .ambiguous = peers },
    };
    if (target) |t| if (!anyway) {
        const heard = collect(io, arena, ctx, cur);
        if (unreadFrom(heard, t) > 0) return .{ .held = heard };
    };
    const room: Room = if (target) |t|
        (if (ctx.identity.len > 0 and std.mem.eql(u8, t.identity, ctx.identity)) .tree else .device)
    else
        .tree;
    var tb: [presence_chan.chan_name_max]u8 = undefined;
    const room_name = if (room == .tree) treeRoomName(&tb, ctx.identity) else presence.device_room;
    if (room_name.len == 0) return .no_room;
    const msg: Message = .{
        .from_pid = ctx.owner.pid,
        .from_start = ctx.owner.start_id,
        .from_session = ctx.name,
        .to = if (target) |t| t.session_id else "",
        .ts_ms = util.unixMs(io),
        .text = text,
    };
    if (!presence_chan.postMessage(io, arena, ctx.dir, room_name, msg)) return .no_room;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(msg) catch {};
    var woke: usize = 0;
    // Wake only who hears it: the DM target, or this worktree's agents.
    for (peers) |p| {
        const hears = if (target) |t| p.pid == t.pid and p.start_id == t.start_id else std.mem.eql(u8, p.identity, ctx.identity);
        if (!hears or std.mem.eql(u8, p.activity, "external")) continue;
        wake(io, gpa, dir_path, p, aw.writer.buffered());
        woke += 1;
    }
    return .{ .posted = .{ .room = room, .target = target, .woke = woke } };
}

fn readStdin(io: Io, arena: Allocator) []const u8 {
    if (Io.File.stdin().isTty(io) catch true) return "";
    var buf: [4096]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    const all = r.interface.allocRemaining(arena, .limited(64 * 1024)) catch return "";
    return std.mem.trim(u8, all, " \t\r\n");
}

pub fn command(gpa: Allocator, io: Io, arena: Allocator, home: []const u8, env_name: ?[]const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    // Streaming, not positional: agents often capture stdout to a file, and a
    // positional writer would overwrite it from offset 0.
    var w = Io.File.stdout().writerStreaming(io, &obuf);
    const out = &w.interface;
    defer out.flush() catch {};
    const opts = parseOpts(arena, args) catch {
        try out.writeAll(usage);
        return;
    };
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) std.process.fatal("graff peer: macOS and Linux only for now", .{});
    if (home.len == 0) std.process.fatal("graff peer: no HOME", .{});
    const dir_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, presence.registry_subdir });
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    const anc = agentAncestor(io) orelse std.process.fatal("graff peer: cannot identify the calling agent process", .{});
    const identity = worktree_lease.currentIdentity(gpa, io, arena).id;
    var fb: [256]u8 = undefined;
    const name = opts.as orelse env_name orelse
        try std.fmt.allocPrint(arena, "{s}@{s}", .{ anc.comm(), if (identity.len > 0) folderLabel(identity, &fb) else "device" });
    const ctx: Ctx = .{ .dir = dir, .name = name, .owner = anc.rec, .identity = identity };
    join(io, arena, ctx);
    var cur = loadCursor(io, arena, ctx) orelse blk: {
        const t = tailCursor(io, arena, ctx);
        saveCursor(io, arena, ctx, t);
        break :blk t;
    };

    if (std.mem.eql(u8, opts.action, "list") or std.mem.eql(u8, opts.action, "ls")) {
        const peers = livePeers(io, arena, ctx);
        if (opts.json) {
            var s: std.json.Stringify = .{ .writer = out };
            try s.write(peers);
            try out.writeAll("\n");
            return;
        }
        try out.print("you: {s}\n", .{name});
        if (peers.len == 0) try out.writeAll("no other agents on this device\n");
        for (peers) |p| {
            var lb: [256]u8 = undefined;
            const label = if (p.title.len > 0) p.title else p.session_id;
            try out.print("  {s:<40} pid {d:<7} {s:<9} {s}\n", .{ util.utf8Prefix(label, 40), @as(u32, @intCast(@max(p.pid, 0))), p.activity, folderLabel(p.identity, &lb) });
        }
    } else if (std.mem.eql(u8, opts.action, "inbox")) {
        var peek = cur;
        const heard = collect(io, arena, ctx, if (opts.peek or opts.wake) &peek else &cur);
        if (opts.wake) {
            if (heard.len == 0) return;
            try out.print("[peer] {d} new message{s} for {s} — read them with: graff peer inbox --as \"{s}\"\n", .{ heard.len, if (heard.len == 1) "" else "s", name, name });
            return;
        }
        if (!opts.peek) saveCursor(io, arena, ctx, cur);
        if (heard.len == 0 and !opts.json) try out.writeAll("no new messages\n");
        for (heard) |h| {
            if (opts.json) {
                var s: std.json.Stringify = .{ .writer = out };
                try s.write(.{ .room = @tagName(h.room), .from = h.m.from_session, .to = h.m.to, .ts_ms = h.m.ts_ms, .text = h.m.text });
                try out.writeAll("\n");
            } else try writeHeard(out, h);
        }
    } else if (std.mem.eql(u8, opts.action, "send")) {
        const text = if (opts.text.len > 0) opts.text else readStdin(io, arena);
        if (text.len == 0) std.process.fatal("graff peer send: no message (pass TEXT or pipe it on stdin)", .{});
        switch (send(io, gpa, arena, dir_path, ctx, &cur, opts.to, text, opts.anyway)) {
            .posted => |p| if (p.target) |t|
                try out.print("sent to {s} ({s} room, {d} woken)\n", .{ if (t.title.len > 0) t.title else t.session_id, @tagName(p.room), p.woke })
            else
                try out.print("posted to this worktree's room ({d} woken)\n", .{p.woke}),
            .held => |heard| {
                saveCursor(io, arena, ctx, cur);
                try out.writeAll("NOT SENT: they wrote to you after your last read. Read this, then resend (or pass --anyway):\n");
                for (heard) |h| try writeHeard(out, h);
                out.flush() catch {};
                std.process.exit(3);
            },
            .no_target => std.process.fatal("graff peer send: no live agent matches '{s}' — see graff peer list", .{opts.to.?}),
            .ambiguous => std.process.fatal("graff peer send: '{s}' matches several agents — use the exact name from graff peer list", .{opts.to.?}),
            .no_room => std.process.fatal("graff peer send: not in a git worktree — pass --to NAME to DM someone", .{}),
        }
    } else {
        try out.writeAll(usage);
    }
}

test {
    _ = @import("peer_cli_tests.zig");
}
