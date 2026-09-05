//! Fold headers for tool runs — grok-build's disclosure row.
//!
//! A collapsed run of `.tool` rows used to render a bare "Called N". This
//! derives a VERB and an object phrase from the run's typed tool events
//! instead: present-progressive with the live count while calls are still
//! landing ("Reading 2 files…"), past tense once the run settles ("Read 3
//! files").
//!
//! Nothing here parses a rendered line. Every fact comes off `Entry.tool` —
//! the engine's own ToolInvocation/ToolOutcome payload (#551) — so the header
//! is rebuilt from Model data on every frame and the count simply follows the
//! events in. A run whose calls disagree about what they are ("mixed") falls
//! back to the old "Called N tools" wording, which is the honest thing to say.

const std = @import("std");

const app = @import("app.zig");
const glyphs = @import("glyphs.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// How long the accent tint sits on a header after its last call returns.
/// Two ticks of the same 500ms clock the pending blink runs on (glyphs.zig),
/// so the settle flash and the blink share one timebase rather than inventing
/// a second one.
pub const flash_ms: u64 = 1000;

/// The gutter an OPEN run's cards hang under, in columns. `│ ` — the same
/// light rail a tool card already uses for its result body.
pub const gutter = "\u{2502} ";
pub const gutter_cols: usize = 2;

// ── families ────────────────────────────────────────────────────────────────

pub const Family = enum { read, write, edit, bash, search, web, task, todo, mcp, lookup, other, mixed };

const Verb = struct {
    /// In flight.
    present: []const u8,
    /// Settled.
    past: []const u8,
    /// Countable object, singular. Pluralised with a bare "s".
    noun: []const u8,
    /// A run of exactly ONE call names the tool instead of counting a noun:
    /// "Running bash" reads the way grok-build's does; "Running 1 command"
    /// does not.
    solo_tool: bool = false,
};

fn verbOf(f: Family) Verb {
    return switch (f) {
        .read => .{ .present = "Reading", .past = "Read", .noun = "file" },
        .write => .{ .present = "Writing", .past = "Wrote", .noun = "file" },
        .edit => .{ .present = "Editing", .past = "Edited", .noun = "file" },
        .bash => .{ .present = "Running", .past = "Ran", .noun = "command", .solo_tool = true },
        .search => .{ .present = "Searching", .past = "Searched", .noun = "pattern" },
        .lookup => .{ .present = "Looking up", .past = "Looked up", .noun = "item" },
        .web => .{ .present = "Fetching", .past = "Fetched", .noun = "page" },
        .task => .{ .present = "Scouting", .past = "Scouted", .noun = "scout" },
        .todo => .{ .present = "Updating", .past = "Updated", .noun = "todo" },
        .mcp => .{ .present = "Calling", .past = "Called", .noun = "MCP tool" },
        .other => .{ .present = "Calling", .past = "Called", .noun = "tool", .solo_tool = true },
        .mixed => .{ .present = "Calling", .past = "Called", .noun = "tool" },
    };
}

fn eqAny(name: []const u8, set: []const []const u8) bool {
    for (set) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn has(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn isMcp(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp__");
}

/// The leaf of an MCP tool name (`mcp__server__leaf` → `leaf`), or the name
/// itself. Classification runs on the leaf so a server's `faster_search` is a
/// search and its `read` is a read, exactly as a first-party tool would be.
pub fn leafOf(name: []const u8) []const u8 {
    if (!isMcp(name)) return name;
    if (std.mem.lastIndexOf(u8, name, "__")) |u| {
        if (u + 2 < name.len) return name[u + 2 ..];
    }
    return name;
}

/// The display form of a tool NAME: the harness's internal names shortened,
/// an MCP tool shown by its leaf. Operates on the name alone.
pub fn displayName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "read_file")) return "read";
    if (std.mem.eql(u8, name, "write_file")) return "write";
    if (std.mem.eql(u8, name, "read_tool_result")) return "inspect";
    const leaf = leafOf(name);
    if (std.mem.eql(u8, leaf, "batch")) return "inspect";
    if (std.mem.eql(u8, name, "subagent") or std.mem.eql(u8, name, "workflow")) return "scout";
    return leaf;
}

/// Which verb family a tool name belongs to. Exact names first — they are what
/// this harness actually emits — then the looser substring tests the old
/// `isSearch` used, so an unfamiliar `*_search` / `*_grep` leaf still reads as
/// a search rather than falling all the way to "Called N tools".
pub fn familyOf(name: []const u8) Family {
    const leaf = leafOf(name);
    if (eqAny(leaf, &.{ "read_file", "read", "view", "cat", "open" })) return .read;
    if (eqAny(leaf, &.{ "write_file", "write", "create" })) return .write;
    if (eqAny(leaf, &.{ "edit_file", "edit", "patch", "replace", "apply_patch", "multiedit" })) return .edit;
    if (eqAny(leaf, &.{ "bash", "shell", "exec", "run_command", "bash_output", "bash_kill" })) return .bash;
    // Before the generic search test below: `web_search` is a fetch, not a
    // codebase search, and it would otherwise be swallowed by "search".
    if (eqAny(leaf, &.{ "webfetch", "web_fetch", "web_search", "fetch", "browse" })) return .web;
    if (eqAny(leaf, &.{ "task", "subagent", "workflow", "agent_output", "dispatch_agent" })) return .task;
    if (std.mem.startsWith(u8, leaf, "todo")) return .todo;
    if (eqAny(leaf, &.{ "codedb" })) return .lookup;
    if (eqAny(leaf, &.{ "grep", "glob", "search", "find", "ls", "list_dir" })) return .search;
    if (has(leaf, "search") or has(leaf, "grep") or has(leaf, "glob") or has(leaf, "find")) return .search;
    if (has(leaf, "web")) return .web;
    if (isMcp(name)) return .mcp;
    return .other;
}

// ── run walk ────────────────────────────────────────────────────────────────

/// A tool row's start/done phase, straight off its typed payload. A legacy row
/// (tool == null) is neither: it has no phase to read, so it renders alone.
pub fn isStartTool(e: app.Entry) bool {
    const t = e.tool orelse return false;
    return !t.done;
}

pub fn isDoneTool(e: app.Entry) bool {
    const t = e.tool orelse return false;
    return t.done;
}

/// The index after the logical call at `t`: an announce and the outcome that
/// answers it are ONE call, so the header counts them once.
pub fn nextTool(self: *const Model, t: usize, end: usize) usize {
    if (t + 1 < end and isStartTool(self.history.items[t]) and isDoneTool(self.history.items[t + 1]))
        return t + 2;
    return t + 1;
}

/// Everything a header says, counted off the run's typed events.
pub const Run = struct {
    /// Logical calls: an announce plus its outcome is ONE.
    calls: usize = 0,
    family: Family = .other,
    /// Display name of the only call, when there is exactly one.
    solo: []const u8 = "",
    /// A call has been announced and has not come back yet.
    live: bool = false,
    /// `at_ms` of the last outcome in the run — when it settled.
    settled_ms: u64 = 0,
};

pub fn scan(self: *const Model, start: usize, end: usize) Run {
    var r: Run = .{};
    if (start >= end or end > self.history.items.len) return r;
    var fam: ?Family = null;
    var all_mcp = true;
    var t = start;
    while (t < end) {
        const e = self.history.items[t];
        const name = if (e.tool) |ti| ti.name else "";
        const f = if (name.len == 0) Family.other else familyOf(name);
        if (!isMcp(name)) all_mcp = false;
        if (fam) |prev| {
            if (prev != .mixed and prev != f) fam = .mixed;
        } else fam = f;
        r.calls += 1;
        if (r.calls == 1) r.solo = displayName(name);
        const nxt = nextTool(self, t, end);
        var k = t;
        while (k < nxt) : (k += 1) {
            if (isDoneTool(self.history.items[k])) r.settled_ms = @max(r.settled_ms, self.history.items[k].at_ms);
        }
        t = nxt;
    }
    r.family = fam orelse .other;
    // A run of MCP calls that disagree about their shape is still an MCP run —
    // "Called 2 MCP tools" beats the flat "Called 2 tools" it would otherwise
    // fall back to.
    if (r.family == .mixed and all_mcp) r.family = .mcp;
    if (r.calls != 1) r.solo = "";
    // The run is in flight exactly when its LAST row is an unanswered announce.
    r.live = isStartTool(self.history.items[end - 1]);
    return r;
}

// ── words ───────────────────────────────────────────────────────────────────

/// The header's words: verb, count, object. Present-progressive with a
/// trailing ellipsis while the run is live, past tense once it settles.
pub fn phrase(a: std.mem.Allocator, r: Run) ![]const u8 {
    if (r.calls == 0) return "";
    const v = verbOf(r.family);
    const verb = if (r.live) v.present else v.past;
    const tail: []const u8 = if (r.live) "\u{2026}" else "";
    if (r.calls == 1 and v.solo_tool and r.solo.len > 0)
        return std.fmt.allocPrint(a, "{s} {s}{s}", .{ verb, r.solo, tail });
    return std.fmt.allocPrint(a, "{s} {d} {s}{s}{s}", .{
        verb,
        r.calls,
        v.noun,
        if (r.calls == 1) "" else "s",
        tail,
    });
}

/// The disclosure mark: the accent chevron when the run is folded shut, a
/// down-pointing arrowhead when it is open. Both are ONE column in every
/// terminal — see glyphs.zig, which pins the pair.
pub fn chevron(open: bool) []const u8 {
    return if (open) glyphs.chev_open else glyphs.chev_closed;
}

/// Is this run inside its settle flash? False while it is live and false once
/// the window has passed, so the header row changes exactly twice per run.
///
/// A run restored from a session was pushed before the loop ever set
/// `now_ms`, so its rows carry `at_ms == 0` against a boot-monotonic clock —
/// far outside the window, and the transcript comes up quiet.
pub fn flashing(r: Run, now_ms: u64) bool {
    if (r.calls == 0 or r.live) return false;
    return now_ms -| r.settled_ms < flash_ms;
}

/// The settle tint. Accent-derived and deliberately shallow: a wash the eye
/// catches in passing, never a highlight that competes with the selection.
pub fn flashBg(th: theme_mod.Theme) []const u8 {
    return if (th.id == .day) "\x1b[48;2;231;227;246m" else "\x1b[48;2;42;36;58m";
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn oneRun(m: *Model) Run {
    return scan(m, 0, m.history.items.len);
}

test "a homogeneous run reads present-progressive live and past tense settled" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try m.pushTool(.{ .name = "read_file", .detail = "a.zig" });
    try testing.expectEqualStrings("Reading 1 file\u{2026}", try phrase(a, oneRun(&m)));
    try m.pushTool(.{ .name = "read_file", .detail = "…", .done = true });
    try testing.expectEqualStrings("Read 1 file", try phrase(a, oneRun(&m)));

    // The count follows the events in, one logical call at a time.
    try m.pushTool(.{ .name = "read_file", .detail = "b.zig" });
    try testing.expectEqualStrings("Reading 2 files\u{2026}", try phrase(a, oneRun(&m)));
    try m.pushTool(.{ .name = "read_file", .detail = "…", .done = true });
    try m.pushTool(.{ .name = "read_file", .detail = "c.zig" });
    try m.pushTool(.{ .name = "read_file", .detail = "…", .done = true });
    try testing.expectEqualStrings("Read 3 files", try phrase(a, oneRun(&m)));
}

test "codedb is a lookup, not a search-for-patterns" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try m.pushTool(.{ .name = "codedb", .detail = "context how auth works" });
    try testing.expectEqualStrings("Looking up 1 item\u{2026}", try phrase(a, oneRun(&m)));
    try m.pushTool(.{ .name = "codedb", .detail = "ok", .done = true });
    try m.pushTool(.{ .name = "codedb", .detail = "around Agent" });
    try m.pushTool(.{ .name = "codedb", .detail = "ok", .done = true });
    try testing.expectEqualStrings("Looked up 2 items", try phrase(a, oneRun(&m)));
}

test "a single call names its tool where that is how it reads" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try m.pushTool(.{ .name = "bash", .detail = "ls" });
    try testing.expectEqualStrings("Running bash\u{2026}", try phrase(a, oneRun(&m)));
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    try testing.expectEqualStrings("Ran bash", try phrase(a, oneRun(&m)));
    // ...but a run of them counts commands rather than repeating the name.
    try m.pushTool(.{ .name = "bash", .detail = "pwd" });
    try m.pushTool(.{ .name = "bash", .detail = "/", .done = true });
    try testing.expectEqualStrings("Ran 2 commands", try phrase(a, oneRun(&m)));
}

test "each family gets its own verb and object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { f: Family, n: usize, want: []const u8 }{
        .{ .f = .write, .n = 2, .want = "Wrote 2 files" },
        .{ .f = .edit, .n = 3, .want = "Edited 3 files" },
        .{ .f = .search, .n = 2, .want = "Searched 2 patterns" },
        .{ .f = .web, .n = 1, .want = "Fetched 1 page" },
        .{ .f = .task, .n = 2, .want = "Scouted 2 scouts" },
        .{ .f = .todo, .n = 1, .want = "Updated 1 todo" },
        .{ .f = .mcp, .n = 2, .want = "Called 2 MCP tools" },
        .{ .f = .mixed, .n = 3, .want = "Called 3 tools" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c.want, try phrase(a, .{ .calls = c.n, .family = c.f }));
    }
}

test "a heterogeneous run falls back to Called N tools" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try m.pushTool(.{ .name = "bash", .detail = "ls" });
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    try m.pushTool(.{ .name = "read_file", .detail = "a.zig" });
    try m.pushTool(.{ .name = "read_file", .detail = "…", .done = true });
    const r = oneRun(&m);
    try testing.expectEqual(Family.mixed, r.family);
    try testing.expectEqualStrings("Called 2 tools", try phrase(arena.allocator(), r));
}

test "an all-MCP run keeps the MCP wording even when its leaves disagree" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try m.pushTool(.{ .name = "mcp__codedbpro__memo", .detail = "note" });
    try m.pushTool(.{ .name = "mcp__codedbpro__memo", .detail = "saved", .done = true });
    try m.pushTool(.{ .name = "mcp__codedbpro__faster_search", .detail = "needle" });
    try m.pushTool(.{ .name = "mcp__codedbpro__faster_search", .detail = "3 hits", .done = true });
    const r = oneRun(&m);
    try testing.expectEqual(Family.mcp, r.family);
    try testing.expectEqualStrings("Called 2 MCP tools", try phrase(arena.allocator(), r));
}

test "familyOf reads the name, and an MCP leaf classifies like a first-party tool" {
    try testing.expectEqual(Family.read, familyOf("read_file"));
    try testing.expectEqual(Family.write, familyOf("write_file"));
    try testing.expectEqual(Family.edit, familyOf("edit_file"));
    try testing.expectEqual(Family.bash, familyOf("bash"));
    try testing.expectEqual(Family.search, familyOf("grep"));
    try testing.expectEqual(Family.search, familyOf("glob"));
    try testing.expectEqual(Family.lookup, familyOf("codedb"));
    try testing.expectEqual(Family.search, familyOf("mcp__codedbpro__faster_search"));
    try testing.expectEqual(Family.read, familyOf("mcp__codedbpro__read"));
    try testing.expectEqual(Family.web, familyOf("webfetch"));
    // web_search is a fetch, not a codebase search — the ordering that pins it.
    try testing.expectEqual(Family.web, familyOf("web_search"));
    try testing.expectEqual(Family.task, familyOf("subagent"));
    try testing.expectEqual(Family.todo, familyOf("todo_write"));
    try testing.expectEqual(Family.mcp, familyOf("mcp__github__create_issue"));
    try testing.expectEqual(Family.other, familyOf("imagegen"));
}

test "the settle flash opens when the last call lands and closes on its own" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    m.now_ms = 5_000;
    try m.pushTool(.{ .name = "bash", .detail = "ls" });
    // Live: never flashing, however long it runs.
    try testing.expect(!flashing(oneRun(&m), 5_000));
    try testing.expect(!flashing(oneRun(&m), 9_000));
    m.now_ms = 6_000;
    try m.pushTool(.{ .name = "bash", .detail = "ok", .done = true });
    const r = oneRun(&m);
    try testing.expectEqual(@as(u64, 6_000), r.settled_ms);
    try testing.expect(flashing(r, 6_000));
    try testing.expect(flashing(r, 6_999));
    try testing.expect(!flashing(r, 7_000));
    try testing.expect(!flashing(r, 30_000));
}

test "a legacy row with no typed payload still counts and never flashes" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    m.now_ms = 5_000;
    try m.push(.tool, "bash | ok");
    const r = oneRun(&m);
    try testing.expectEqual(@as(usize, 1), r.calls);
    try testing.expect(!r.live);
    try testing.expectEqualStrings("Called 1 tool", try phrase(arena.allocator(), r));
    // Nothing ever reported an outcome, so there is no settle to tint.
    try testing.expectEqual(@as(u64, 0), r.settled_ms);
    try testing.expect(!flashing(r, 5_000));
}

test "displayName shortens an mcp tool to its leaf, reading the NAME" {
    try testing.expectEqualStrings("memo", displayName("mcp__codedbpro__memo"));
    try testing.expectEqualStrings("faster_search", displayName("mcp__codedbpro__faster_search"));
    try testing.expectEqualStrings("bash", displayName("bash"));
    try testing.expectEqualStrings("read", displayName("read_file"));
}
