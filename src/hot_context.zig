//! Hot context (#1333): ambient values that change during a live session
//! reach the model without rewriting the cached system prefix.
//!
//! The root system prompt is composed once at startup (startup.zig) and the
//! provider caches it as a prefix. Rewriting it when an instruction file
//! changes, or the date rolls over, would throw that cache away. Instead each
//! ambient value is a keyed source. Before a model request, a changed key is
//! delivered as one `<context key="...">` message (a notice, not a human turn)
//! placed just before the pending user prompt, so everything already sent
//! stays byte-identical. Compaction already discards the cached prefix, so
//! there the synthetic messages are dropped and the latest values are folded
//! into a fresh system prompt.
//!
//! Keys:
//! - `core/instructions`: the first of AGENTS.md / HARNESS.md / CLAUDE.md in
//!   the working directory, capped like the startup copy. It follows the
//!   directory, so a `workspace use` into another worktree delivers that
//!   tree's file; the update names its directory so two worktrees' copies
//!   of the same file can be told apart (#1676).
//! - `core/date`: the UTC date. Not in the startup prompt; announced only when
//!   it changes during the session.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const instruction_names = [_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" };
pub const origin = "hot_context";

pub const Key = enum {
    instructions,
    date,
    pub fn label(k: Key) []const u8 {
        return switch (k) {
            .instructions => "core/instructions",
            .date => "core/date",
        };
    }
};

const State = struct {
    armed: bool = false,
    /// The exact section startup put in the system prompt (header + body),
    /// so a later fold can replace it. Empty when no file was found.
    baked_section: []const u8 = "",
    /// What the model currently believes: hash of the latest delivered body.
    believed_hash: u64 = 0,
    /// Hash of the body inside the system prompt (0 = none baked).
    baked_hash: u64 = 0,
    stat_size: u64 = 0,
    stat_mtime: i128 = 0,
    stat_name: []const u8 = "",
    /// The directory the probe last looked in: a `workspace use` into
    /// another tree is a change even when its file's size and mtime match.
    stat_dir_hash: u64 = 0,
    date: [10]u8 = undefined,
    date_len: u8 = 0,
    /// The date the model believes, when it differs from the session start.
    date_announced: bool = false,
};

var g: State = .{};
var g_gpa: Allocator = std.heap.page_allocator;

pub fn resetForTest() void {
    g = .{};
}

fn section(a: Allocator, name: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "# Project instructions (from {s})\n{s}", .{ name, body });
}

/// The instructions section the prefix holds now (startup's, or the one the
/// last compaction folded in); ADR 0243 lifts it out on Responses wires.
pub fn bakedSection() []const u8 {
    return g.baked_section;
}

/// startup.buildSystemPrompt: the instructions it baked into the prefix.
pub fn noteBaked(name: []const u8, body: []const u8) void {
    g.baked_section = section(g_gpa, name, body) catch "";
    g.believed_hash = std.hash.Wyhash.hash(0, body);
    g.baked_hash = g.believed_hash;
    g.armed = true;
}

/// The current instruction body (capped), or null when no file exists.
fn currentInstructions(io: Io, a: Allocator) ?struct { name: []const u8, body: []const u8 } {
    for (instruction_names) |name| {
        const raw = Io.Dir.cwd().readFileAlloc(io, name, a, .limited(64 * 1024)) catch continue;
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        const limits = @import("context_limits.zig");
        return .{ .name = name, .body = limits.applyAlloc(a, trimmed, limits.agents_md_bytes) };
    }
    return null;
}

/// Cheap change probe: size + mtime of whichever instruction file exists,
/// and the directory it was found in.
fn instructionsTouched(io: Io) bool {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.currentPath(io, &dir_buf) catch 0;
    const dir_hash = std.hash.Wyhash.hash(0, dir_buf[0..dir_len]);
    const moved = dir_hash != g.stat_dir_hash;
    g.stat_dir_hash = dir_hash;
    for (instruction_names) |name| {
        const st = Io.Dir.cwd().statFile(io, name, .{}) catch continue;
        const mtime: i128 = st.mtime.nanoseconds;
        const touched = moved or st.size != g.stat_size or mtime != g.stat_mtime or !std.mem.eql(u8, name, g.stat_name);
        g.stat_size = st.size;
        g.stat_mtime = mtime;
        g.stat_name = name;
        return touched;
    }
    const had = g.stat_name.len > 0;
    g.stat_name = "";
    g.stat_size = 0;
    return had;
}

pub fn utcDate(buf: *[10]u8, unix_ms: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, @divFloor(unix_ms, 1000))) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch buf[0..0];
}

pub const Update = struct { key: Key, text: []const u8 };

/// Changed keys since the model last saw them, as ready-to-send text.
/// `now_ms` is injected so tests can roll the date.
pub fn collect(io: Io, a: Allocator, now_ms: i64, out: *std.ArrayList(Update)) !void {
    var buf: [10]u8 = undefined;
    const today = utcDate(&buf, now_ms);
    if (g.date_len == 0) {
        @memcpy(g.date[0..today.len], today);
        g.date_len = @intCast(today.len);
    } else if (!std.mem.eql(u8, g.date[0..g.date_len], today)) {
        @memcpy(g.date[0..today.len], today);
        g.date_len = @intCast(today.len);
        g.date_announced = true;
        try out.append(a, .{ .key = .date, .text = try std.fmt.allocPrint(a, "<context key=\"core/date\">\nThe date is now {s} (UTC).\n</context>", .{today}) });
    }
    if (!g.armed) {
        // Startup found no instruction file (or ran without the funnel):
        // track from here so a file created later is still delivered.
        g.armed = true;
        _ = instructionsTouched(io);
        if (currentInstructions(io, a)) |cur| g.believed_hash = std.hash.Wyhash.hash(0, cur.body);
        g.baked_hash = g.believed_hash;
        return;
    }
    if (!instructionsTouched(io)) return;
    const cur = currentInstructions(io, a);
    const hash: u64 = if (cur) |c| std.hash.Wyhash.hash(0, c.body) else 0;
    if (hash == g.believed_hash) return;
    g.believed_hash = hash;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.currentPath(io, &dir_buf) catch 0;
    const dir = dir_buf[0..dir_len];
    const text = if (cur) |c|
        try std.fmt.allocPrint(a, "<context key=\"core/instructions\" source=\"{s}{s}{s}\">\nThe project instructions for the working directory changed during this session (the file was edited, or the session moved to another tree). This version replaces the one in the system prompt.\n\n{s}\n</context>", .{ dir, if (dir.len > 0) "/" else "", c.name, c.body })
    else
        try a.dupe(u8, "<context key=\"core/instructions\">\nThe project instructions file was removed during this session. The version in the system prompt no longer applies.\n</context>");
    try out.append(a, .{ .key = .instructions, .text = text });
}

pub fn isHotContext(m: Value) bool {
    if (m != .object) return false;
    const v = m.object.get(@import("session_wake.zig").origin_key) orelse return false;
    return v == .string and std.mem.eql(u8, v.string, origin);
}

fn isHumanPrompt(m: Value) bool {
    if (m != .object) return false;
    if (@import("session_wake.zig").isNotice(m)) return false;
    return @import("messages.zig").userPromptText(m) != null;
}

/// The role an update needs to be obeyed over the startup system prompt.
/// A user-role message ranks below system/developer instructions (a live
/// gpt-6-sol run kept following the old AGENTS.md rule), so wires that
/// accept a mid-conversation instruction message get one: Responses takes
/// `developer`, Chat Completions `system`. Anthropic and Interactions have
/// no mid-thread system role; the update rides as user text there.
pub fn roleFor(kind: @import("provider.zig").Provider.Kind) []const u8 {
    return switch (kind) {
        .responses => "developer",
        .openai => "system",
        .anthropic, .interactions => "user",
    };
}

fn typedUpdate(a: Allocator, kind: @import("provider.zig").Provider.Kind, text: []const u8) !Value {
    if (kind == .interactions) return @import("session_wake.zig").typedMessage(a, kind, text);
    return @import("messages.zig").textMessage(a, roleFor(kind), text);
}

/// An update message for `kind`, tagged as hot context. Also used when a
/// /model switch changes wire format (providers.translateHistory).
pub fn retyped(a: Allocator, kind: @import("provider.zig").Provider.Kind, text: []const u8) !Value {
    var msg = try typedUpdate(a, kind, text);
    try msg.object.put(a, @import("session_wake.zig").origin_key, .{ .string = origin });
    return msg;
}

/// Before a model request (turn_inbox.deliver): send changed keys. Root only.
pub fn deliver(self: anytype) void {
    if (self.sub) return;
    var updates: std.ArrayList(Update) = .empty;
    collect(self.io, self.arena, @import("util.zig").unixMs(self.io), &updates) catch return;
    for (updates.items) |u| {
        const msg = retyped(self.arena, self.provider.kind, u.text) catch continue;
        // Just before the pending human prompt, so it reads as current;
        // everything already sent keeps its bytes either way.
        const items = self.messages.items;
        if (items.len > 0 and isHumanPrompt(items[items.len - 1]))
            self.messages.insert(items.len - 1, msg) catch continue
        else
            self.messages.append(msg) catch continue;
        @import("prompt_cache_hud.zig").noteHot(u.key.label());
        @import("engine_sink.zig").forAgent(self).emit(self.io, .{ .session_notice = .{ .text = u.key.label(), .tone = .dim } });
    }
}

/// The system base with the latest keyed values folded in.
pub fn foldedBase(a: Allocator, base: []const u8, latest: ?[]const u8, date: ?[]const u8) ![]const u8 {
    var out = base;
    if (latest) |section_now| {
        if (g.baked_section.len > 0 and std.mem.indexOf(u8, out, g.baked_section) != null)
            out = try std.mem.replaceOwned(u8, a, out, g.baked_section, section_now)
        else if (section_now.len > 0)
            out = try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ out, section_now });
    } else if (g.baked_section.len > 0) {
        out = try std.mem.replaceOwned(u8, a, out, g.baked_section, "");
    }
    if (date) |d| {
        const marker = "\n\n# Current date (UTC)\n";
        if (std.mem.indexOf(u8, out, marker)) |at| {
            out = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ out[0..at], marker, d });
        } else out = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ out, marker, d });
    }
    return out;
}

/// After compaction: the cached prefix is gone, so drop the synthetic
/// messages and bake the latest values into the system prompt.
/// The update messages are not a reliable signal: the summary's working set
/// usually drops them already, so the fold compares the file against what
/// the prompt holds.
pub fn afterCompact(self: anytype) void {
    if (self.sub) return;
    var i: usize = 0;
    while (i < self.messages.items.len) {
        if (isHotContext(self.messages.items[i])) _ = self.messages.orderedRemove(i) else i += 1;
    }
    if (self.sys_base.len == 0) return; // never went through the prompt funnel
    const cur = currentInstructions(self.io, self.arena);
    const hash: u64 = if (cur) |c| std.hash.Wyhash.hash(0, c.body) else 0;
    if (hash == g.baked_hash and !g.date_announced) return;
    const section_now: ?[]const u8 = if (cur) |c| section(self.arena, c.name, c.body) catch return else null;
    const date: ?[]const u8 = if (g.date_announced) g.date[0..g.date_len] else null;
    const base = foldedBase(self.arena, self.sys_base, section_now, date) catch return;
    @import("prompts.zig").setSystemPrompts(self, base, self.arena) catch return;
    g.baked_section = if (section_now) |s| g_gpa.dupe(u8, s) catch "" else "";
    g.baked_hash = hash;
    g.believed_hash = hash;
    // Rehydrate the stat probe so the fold is not re-announced next turn.
    _ = instructionsTouched(self.io);
}

const testing = std.testing;

test "utcDate formats the UTC calendar day" {
    var buf: [10]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01", utcDate(&buf, 0));
    try testing.expectEqualStrings("2026-09-27", utcDate(&buf, 1_790_500_000_000));
}

fn dateUpdates(list: []const Update) usize {
    var n: usize = 0;
    for (list) |u| if (u.key == .date) {
        n += 1;
    };
    return n;
}

test "collect announces a date rollover once and nothing on the first day" {
    resetForTest();
    defer resetForTest();
    g.armed = true;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Update) = .empty;
    const day: i64 = 86_400_000;
    try collect(testing.io, a, 20_000 * day, &out);
    try testing.expectEqual(@as(usize, 0), dateUpdates(out.items));
    try collect(testing.io, a, 20_000 * day + 5000, &out);
    try testing.expectEqual(@as(usize, 0), dateUpdates(out.items));
    try collect(testing.io, a, 20_001 * day, &out);
    try testing.expectEqual(@as(usize, 1), dateUpdates(out.items));
    for (out.items) |u| if (u.key == .date) try testing.expect(std.mem.indexOf(u8, u.text, "key=\"core/date\"") != null);
    try collect(testing.io, a, 20_001 * day + 1, &out);
    try testing.expectEqual(@as(usize, 1), dateUpdates(out.items));
}

test "foldedBase replaces the baked instructions and adds the date" {
    resetForTest();
    defer resetForTest();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    g_gpa = a;
    defer g_gpa = std.heap.page_allocator;
    noteBaked("AGENTS.md", "use tabs");
    const base = "You are graff.\n\n# Project instructions (from AGENTS.md)\nuse tabs\n\nskills";
    const folded = try foldedBase(a, base, "# Project instructions (from AGENTS.md)\nuse spaces", "2026-09-28");
    try testing.expect(std.mem.indexOf(u8, folded, "use spaces") != null);
    try testing.expect(std.mem.indexOf(u8, folded, "use tabs") == null);
    try testing.expect(std.mem.endsWith(u8, folded, "\n\n# Current date (UTC)\n2026-09-28"));
    try testing.expect(std.mem.indexOf(u8, folded, "skills") != null);
    const again = try foldedBase(a, folded, null, "2026-09-29");
    try testing.expect(std.mem.endsWith(u8, again, "# Current date (UTC)\n2026-09-29"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, again, "# Current date"));
}

test "a hot context message is a notice with its own origin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg = try @import("session_wake.zig").typedMessage(a, .openai, "<context key=\"core/date\">x</context>");
    try msg.object.put(a, @import("session_wake.zig").origin_key, .{ .string = origin });
    try testing.expect(isHotContext(msg));
    try testing.expect(@import("session_wake.zig").isNotice(msg));
    try testing.expect(!isHumanPrompt(msg));
}

test "#1676: switching to a tree with other instructions delivers that tree's file" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    resetForTest();
    defer resetForTest();
    const io = testing.io;
    var tree_a = testing.tmpDir(.{});
    defer tree_a.cleanup();
    var tree_b = testing.tmpDir(.{});
    defer tree_b.cleanup();
    try tree_a.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "use tabs!" });
    try tree_b.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "use space" });
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Update) = .empty;
    const now: i64 = 20_000 * 86_400_000;
    if (std.posix.system.fchdir(tree_a.dir.handle) != 0) return error.ChdirFailed;
    try collect(io, a, now, &out); // arms on tree A's file
    try collect(io, a, now, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    if (std.posix.system.fchdir(tree_b.dir.handle) != 0) return error.ChdirFailed;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tree_b_path = buf[0 .. std.process.currentPath(io, &buf) catch return error.SkipZigTest];
    try collect(io, a, now, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const text = out.items[0].text;
    try testing.expectEqual(Key.instructions, out.items[0].key);
    try testing.expect(std.mem.indexOf(u8, text, "use space") != null);
    const source = try std.fmt.allocPrint(a, "source=\"{s}/AGENTS.md\"", .{tree_b_path});
    try testing.expect(std.mem.indexOf(u8, text, source) != null);
    // Settled: nothing more until the file or the tree changes again.
    try collect(io, a, now, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}
