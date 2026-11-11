//! Session-wide tool-CLASS tally: how the model's reads/searches actually
//! split across the licensed codedb-pro tools, zigrep, and the native
//! fallbacks — plus how often the licensed gate had to refuse a native call.
//! The per-turn ToolSink (trace.zig) already logs names for the trajectory,
//! but nothing aggregated by class, so "the model hammered faster_search 40
//! times and never opened a file outline" was invisible. This is the
//! aggregate: /tools renders it, and the skew line names a dominant class.
//!
//! Counting hooks: exec.zig's central post-call point (every tool call) and
//! codedbpro_report.nativeRefusal (gate refusals, which never reach a call).
//! Counters are plain u64s touched through @atomicRmw/@atomicLoad — tool
//! calls run on pool threads, and a mutex here would invite cancellation
//! deadlock for a three-instruction critical section.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");

pub const Class = enum {
    pro_read, // mcp__codedbpro__read
    pro_search, // faster_search / meta_search
    pro_batch, // batch
    pro_other, // any other mcp__codedbpro__*
    zigrep, // leading `zigrep` via bash
    native_search, // leading grep/rg/find via bash — only runs unlicensed or post-fallback
    native_read, // read_file / codedb — same
    other,

    fn label(self: Class) []const u8 {
        return switch (self) {
            .pro_read => "read",
            .pro_search => "search",
            .pro_batch => "batch",
            .pro_other => "other",
            .zigrep => "zigrep",
            .native_search => "grep/rg/find",
            .native_read => "read_file/codedb",
            .other => "other",
        };
    }
};

const class_count = @as(usize, @backingInt(Class.other)) + 1; // `other` must stay LAST (std.meta.fields is deprecated in this std)
var g_counts: [class_count]u64 = @splat(0);
var g_refused: u64 = 0;
var g_errors: u64 = 0;

fn bump(counter: *u64) void {
    _ = @atomicRmw(u64, counter, .Add, 1, .monotonic);
}

fn load(counter: *const u64) u64 {
    return @atomicLoad(u64, counter, .monotonic);
}

fn firstToken(cmd: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

/// The class one tool call belongs to. Bash is inspected by LEADING command
/// only — a piped `| grep` filters output and stays `other`.
pub fn classOf(call: tools.ToolCall) Class {
    const name = call.name;
    if (std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "codedb")) return .native_read;
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "shell")) {
        const cmd = tools.strField(call.input, "command") orelse return .other;
        const first = firstToken(cmd);
        if (std.mem.eql(u8, first, "zigrep")) return .zigrep;
        if (std.mem.eql(u8, first, "grep") or std.mem.eql(u8, first, "rg") or std.mem.eql(u8, first, "find")) return .native_search;
        return .other;
    }
    if (std.mem.eql(u8, name, "mcp__codedbpro__read")) return .pro_read;
    if (std.mem.eql(u8, name, "mcp__codedbpro__faster_search") or std.mem.eql(u8, name, "mcp__codedbpro__meta_search")) return .pro_search;
    if (std.mem.eql(u8, name, "mcp__codedbpro__batch")) return .pro_batch;
    if (std.mem.startsWith(u8, name, "mcp__codedbpro__")) return .pro_other;
    return .other;
}

/// Edge-trigger state for the steering nudge: 0 = none/balanced, else the
/// dominant Class + 1 already nudged this session. The nudge fires once per
/// dominant class — a model that keeps hammering after being told gets no
/// repeats, and a shift to a DIFFERENT dominant class re-arms it.
var g_last_skew: std.atomic.Value(u8) = .init(0);
pub const read_streak_threshold: u64 = 16;
var g_read_streak: u64 = 0;
var g_read_streak_nudged: std.atomic.Value(u8) = .init(0);

const ToolActivity = enum { read_explore, write_or_exec, neutral };

fn hasOutputFileRedirect(seg: []const u8) bool {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < seg.len) : (i += 1) {
        const c = seg[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"' and i + 1 < seg.len) {
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '`' or (c == '$' and i + 1 < seg.len and seg[i + 1] == '(')) return true;
        if (c == '>') {
            var next = i + 1;
            if (next < seg.len and (seg[next] == '>' or seg[next] == '|')) next += 1;
            if (next < seg.len and seg[next] == '&') continue; // fd dup (2>&1)
            return true;
        }
    }
    return false;
}

fn findHasMutatingFlag(seg: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, seg, " \t");
    _ = it.next();
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "-exec") or std.mem.eql(u8, tok, "-execdir") or
            std.mem.eql(u8, tok, "-ok") or std.mem.eql(u8, tok, "-okdir") or
            std.mem.eql(u8, tok, "-delete") or std.mem.eql(u8, tok, "-fprint") or
            std.mem.eql(u8, tok, "-fprintf")) return true;
    }
    return false;
}

fn classifyShellSegment(raw_seg: []const u8) ToolActivity {
    const policy = @import("harness_policy.zig");
    const guard_scope = @import("codedb_guard_scope.zig");
    var seg = std.mem.trim(u8, raw_seg, " \t\r\n");
    if (seg.len == 0) return .neutral;
    if (hasOutputFileRedirect(seg)) return .write_or_exec;
    // Strip leading VAR=val env assignments before inspecting the verb.
    while (true) {
        const tok = firstToken(seg);
        if (tok.len == 0 or std.mem.indexOfScalar(u8, tok, '=') == null or tok[0] == '=' or tok[0] == '-') break;
        seg = std.mem.trimStart(u8, seg[tok.len..], " \t");
    }
    if (seg.len == 0) return .neutral;
    const verb = firstToken(seg);
    if (std.mem.eql(u8, verb, "sed")) {
        return if (guard_scope.inPlaceEdit("sed", seg)) .write_or_exec else .read_explore;
    }
    if (std.mem.eql(u8, verb, "find")) {
        return if (findHasMutatingFlag(seg)) .write_or_exec else .read_explore;
    }
    const read_prefixes = [_][]const u8{
        "ls",         "cat",           "head",     "tail",     "wc",        "grep",
        "egrep",      "fgrep",         "rg",       "zigrep",   "pwd",       "which",
        "file",       "stat",          "nl",       "less",     "more",      "sort",
        "uniq",       "cut",           "tr",       "tree",     "fd",        "git status",
        "git diff",   "git log",       "git show", "git grep", "git blame", "git ls-files",
        "git branch", "git rev-parse",
    };
    for (read_prefixes) |p| if (policy.matchesPrefix(seg, p)) return .read_explore;

    const write_exec_prefixes = [_][]const u8{
        "pytest",       "py.test",         "go test",   "go build",  "go run",    "cargo test",
        "cargo check",  "cargo build",     "cargo run", "zig build", "zig test",  "npm test",
        "npm run",      "pnpm",            "yarn",      "bun test",  "make",      "cmake",
        "ninja",        "ctest",           "mvn",       "gradle",    "tox",       "nox",
        "ruff",         "mypy",            "flake8",    "eslint",    "tsc",       "git commit",
        "git checkout", "git switch",      "git apply", "git stash", "git merge", "git rebase",
        "git reset",    "git cherry-pick", "rm",        "mv",        "cp",        "mkdir",
        "touch",        "chmod",           "patch",     "tee",
    };
    for (write_exec_prefixes) |p| if (policy.matchesPrefix(seg, p)) return .write_or_exec;
    if (policy.isInterpreter(verb)) return .write_or_exec;
    return .neutral;
}

fn classifyShellCommand(cmd: []const u8) ToolActivity {
    var saw_read = false;
    var quote: u8 = 0;
    var seg_start: usize = 0;
    var i: usize = 0;
    while (i <= cmd.len) : (i += 1) {
        const at_end = i == cmd.len;
        const c: u8 = if (at_end) 0 else cmd[i];
        if (!at_end and quote != 0) {
            if (c == '\\' and quote == '"' and i + 1 < cmd.len) {
                i += 1;
                continue;
            }
            if (c == quote) quote = 0;
            continue;
        }
        if (!at_end and (c == '\'' or c == '"')) {
            quote = c;
            continue;
        }
        const is_sep = at_end or c == ';' or c == '\n' or c == '|' or
            (c == '&' and (i == 0 or cmd[i - 1] != '>') and (i + 1 >= cmd.len or cmd[i + 1] != '>'));
        if (!is_sep) continue;
        switch (classifyShellSegment(cmd[seg_start..i])) {
            .write_or_exec => return .write_or_exec,
            .read_explore => saw_read = true,
            .neutral => {},
        }
        if (!at_end and (c == '|' or c == '&') and i + 1 < cmd.len and cmd[i + 1] == c) i += 1;
        seg_start = i + 1;
    }
    return if (saw_read) .read_explore else .neutral;
}

fn classifyActivity(call: tools.ToolCall, class: Class) ToolActivity {
    const name = call.name;
    if (std.mem.eql(u8, name, "edit_file") or
        std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "apply_patch")) return .write_or_exec;
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "shell")) {
        const cmd = tools.strField(call.input, "command") orelse return .neutral;
        return classifyShellCommand(cmd);
    }
    if (class != .other) return .read_explore;
    if (std.mem.eql(u8, name, "list_dir") or
        std.mem.eql(u8, name, "glob") or
        std.mem.eql(u8, name, "web_search") or
        std.mem.eql(u8, name, "fetch_url")) return .read_explore;
    return .neutral;
}

fn isSuite(class: Class) bool {
    return switch (class) {
        .pro_read, .pro_search, .pro_batch, .pro_other, .zigrep => true,
        else => false,
    };
}

/// The dominant suite class when usage is skewed (8+ suite calls, one class
/// at 80%+), null when balanced or too thin to judge. Alloc-free; record()
/// only formats a message when this edge-triggers.
pub fn skewClass(snap: *const Snapshot) ?Class {
    const total = snap.suiteTotal();
    if (total < 8) return null;
    const classes = [_]Class{ .pro_read, .pro_search, .pro_batch, .zigrep };
    var top: Class = .pro_read;
    for (classes) |c| if (snap.get(c) > snap.get(top)) {
        top = c;
    };
    if (snap.get(top) * 5 < total * 4) return null;
    return top;
}

/// exec.zig's post-call hook. Errors counted apart: a failing dominant tool
/// is a different story than a preferred one. Returns a gpa-owned steering
/// nudge when suite usage NEWLY skews (the caller appends it to the tool
/// result so the model hears it, not just /tools) — null otherwise.
pub fn record(gpa: Allocator, call: tools.ToolCall, is_error: bool) ?[]u8 {
    return recordWithMode(gpa, call, is_error, false);
}

pub fn recordWithMode(gpa: Allocator, call: tools.ToolCall, is_error: bool, allow_write_nudge: bool) ?[]u8 {
    const class = classOf(call);
    bump(&g_counts[@backingInt(class)]);
    if (is_error) bump(&g_errors);

    const activity = classifyActivity(call, class);
    var streak_now: u64 = 0;
    switch (activity) {
        .read_explore => streak_now = @atomicRmw(u64, &g_read_streak, .Add, 1, .monotonic) + 1,
        .write_or_exec => {
            @atomicStore(u64, &g_read_streak, 0, .monotonic);
            g_read_streak_nudged.store(0, .release);
        },
        .neutral => {},
    }

    if (isSuite(class)) {
        var snap = snapshot();
        if (skewClass(&snap)) |top| {
            const marker: u8 = @intCast(@backingInt(top) + 1);
            if (g_last_skew.swap(marker, .acq_rel) != marker) {
                return std.fmt.allocPrint(gpa, "tool balance: {d}/{d} suite calls were {s} — read (outline-first), search and batch are all available; balance them", .{ snap.get(top), snap.suiteTotal(), top.label() }) catch null;
            }
        } else {
            g_last_skew.store(0, .release);
        }
    }

    if (allow_write_nudge and activity == .read_explore and streak_now >= read_streak_threshold) {
        if (g_read_streak_nudged.swap(1, .acq_rel) == 0) {
            return std.fmt.allocPrint(
                gpa,
                "exploration balance: {d} consecutive read/search calls without an edit or test run — if this task requires a code change, form a concrete hypothesis and run a targeted test or apply an edit now",
                .{streak_now},
            ) catch null;
        }
    }
    return null;
}

/// codedbpro_report.nativeRefusal's hook: a native call the licensed gate
/// turned away. High counts are the gate working, not a failure — but they
/// also say the model needed steering.
pub fn recordRefusal() void {
    bump(&g_refused);
}

pub const Snapshot = struct {
    counts: [class_count]u64 = @splat(0),
    refused: u64 = 0,
    errors: u64 = 0,

    pub fn get(self: *const Snapshot, class: Class) u64 {
        return self.counts[@backingInt(class)];
    }

    /// Every read/search the licensed suite owns: pro tools plus zigrep.
    pub fn suiteTotal(self: *const Snapshot) u64 {
        return self.get(.pro_read) + self.get(.pro_search) + self.get(.pro_batch) + self.get(.pro_other) + self.get(.zigrep);
    }
};

pub fn snapshot() Snapshot {
    var snap: Snapshot = .{};
    inline for (0..class_count) |i| snap.counts[i] = load(&g_counts[i]);
    snap.refused = load(&g_refused);
    snap.errors = load(&g_errors);
    return snap;
}

/// Test seam: a fresh tally.
pub fn reset() void {
    inline for (0..class_count) |i| @atomicStore(u64, &g_counts[i], 0, .monotonic);
    @atomicStore(u64, &g_refused, 0, .monotonic);
    @atomicStore(u64, &g_errors, 0, .monotonic);
    @atomicStore(u64, &g_read_streak, 0, .monotonic);
    g_last_skew.store(0, .monotonic);
    g_read_streak_nudged.store(0, .monotonic);
}

/// The "not overleveraging just one" check for /tools: same rule record()
/// edge-triggers on, formatted for the report. null when balanced or thin.
pub fn skewWarning(alloc: Allocator, snap: *const Snapshot) ?[]const u8 {
    const top = skewClass(snap) orelse return null;
    return std.fmt.allocPrint(alloc, "skew: {d}/{d} suite calls were {s} — read (outline-first), search and batch are all available; balance them", .{ snap.get(top), snap.suiteTotal(), top.label() }) catch null;
}

/// The /tools body. `licensed`/`fallback_open` come from codedbpro_report's
/// gate state so the reader can tell "natives unused because blocked" from
/// "natives unused because chosen".
pub fn render(alloc: Allocator, snap: *const Snapshot, licensed: bool, fallback_open: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("tool balance this session:\n");
    try w.print("  codedb-pro:  read {d} · search {d} · batch {d} · other {d}\n", .{ snap.get(.pro_read), snap.get(.pro_search), snap.get(.pro_batch), snap.get(.pro_other) });
    try w.print("  zigrep:      {d}\n", .{snap.get(.zigrep)});
    try w.print("  native:      read_file/codedb {d} · grep/rg/find {d}\n", .{ snap.get(.native_read), snap.get(.native_search) });
    if (licensed) try w.print("  gate:        {d} blocked native attempt(s) · fallback {s}\n", .{ snap.refused, if (fallback_open) "OPEN (a codedb-pro call failed)" else "closed" });
    if (snap.errors > 0) try w.print("  errors:      {d} failed tool call(s)\n", .{snap.errors});
    if (skewWarning(alloc, snap)) |warn| try w.print("  {s}\n", .{warn});
    return alloc.dupe(u8, w.buffered());
}

test "classOf sorts pro tools, zigrep, shell search and natives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bash = struct {
        fn call(alloc: Allocator, cmd: []const u8) tools.ToolCall {
            const src = std.fmt.allocPrint(alloc, "{{\"command\":\"{s}\"}}", .{cmd}) catch unreachable;
            const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, src, .{}) catch unreachable;
            return .{ .id = "t", .name = "bash", .input = v };
        }
    };
    try std.testing.expectEqual(Class.pro_read, classOf(.{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }));
    try std.testing.expectEqual(Class.pro_search, classOf(.{ .id = "t", .name = "mcp__codedbpro__meta_search", .input = .null }));
    try std.testing.expectEqual(Class.pro_batch, classOf(.{ .id = "t", .name = "mcp__codedbpro__batch", .input = .null }));
    try std.testing.expectEqual(Class.zigrep, classOf(bash.call(a, "zigrep TODO src")));
    try std.testing.expectEqual(Class.native_search, classOf(bash.call(a, "find . -name '*.zig'")));
    try std.testing.expectEqual(Class.other, classOf(bash.call(a, "curl -s x | grep err"))); // piped: output filtering
    try std.testing.expectEqual(Class.native_read, classOf(.{ .id = "t", .name = "read_file", .input = .null }));
    try std.testing.expectEqual(Class.other, classOf(.{ .id = "t", .name = "edit_file", .input = .null }));
}

test "record/snapshot/skew: a dominant class is named, balanced usage is quiet" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const search: tools.ToolCall = .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null };
    for (0..9) |_| _ = record(a, search, false);
    _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }, false);
    recordRefusal();
    var snap = snapshot();
    try std.testing.expectEqual(@as(u64, 10), snap.suiteTotal());
    try std.testing.expectEqual(@as(u64, 1), snap.refused);
    const warn = skewWarning(a, &snap) orelse return error.TestExpectedSkew;
    try std.testing.expect(std.mem.indexOf(u8, warn, "search") != null);

    reset();
    for (0..3) |_| _ = record(a, search, false);
    for (0..3) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }, false);
    for (0..3) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__batch", .input = .null }, false);
    var even = snapshot();
    try std.testing.expect(skewWarning(a, &even) == null);
    // ...and below the 8-call floor the warning stays out of thin sessions.
    reset();
    for (0..5) |_| _ = record(a, search, false);
    var thin = snapshot();
    try std.testing.expect(skewWarning(a, &thin) == null);
}

test "record edge-triggers the steering nudge: once per dominant class" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const search: tools.ToolCall = .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null };
    var nudges: usize = 0;
    for (0..9) |_| if (record(a, search, false)) |_| {
        nudges += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), nudges); // fired exactly once, at the crossing
    // A non-suite call never nudges.
    try std.testing.expect(record(a, .{ .id = "t", .name = "edit_file", .input = .null }, false) == null);
}

test "render shows classes, gate state and skew" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (0..9) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null }, false);
    recordRefusal();
    var snap = snapshot();
    const text = try render(a, &snap, true, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "search 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fallback closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skew:") != null);
}

test "#1879: recordWithMode edge-triggers once on a long read-only streak and resets after edit_file" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const read_call: tools.ToolCall = .{ .id = "t", .name = "read_file", .input = .null };
    var fired: usize = 0;
    for (0..read_streak_threshold + 4) |_| {
        if (recordWithMode(a, read_call, false, true)) |nudge| {
            try std.testing.expect(std.mem.indexOf(u8, nudge, "exploration balance:") != null);
            fired += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fired);
    // An edit resets the streak and re-arms the nudge for a later spiral.
    try std.testing.expect(recordWithMode(a, .{ .id = "t", .name = "edit_file", .input = .null }, false, true) == null);
    for (0..read_streak_threshold) |_| {
        if (recordWithMode(a, read_call, false, true)) |_| fired += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fired);
}

test "#1887: read-only shell idioms (sed -n, nl | sed, piped grep, find) advance g_read_streak while sed -i / pytest reset it" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mkShell = struct {
        fn call(alloc: Allocator, cmd: []const u8) tools.ToolCall {
            var map: std.json.ObjectMap = .empty;
            map.put(alloc, "command", .{ .string = cmd }) catch unreachable;
            return .{ .id = "s", .name = "shell", .input = .{ .object = map } };
        }
    }.call;

    var fired: usize = 0;
    for (0..8) |_| _ = recordWithMode(a, mkShell(a, "sed -n '1,50p' compiler.go"), false, true);
    for (0..4) |_| _ = recordWithMode(a, mkShell(a, "nl -ba httpx/_models.py | sed -n '760,900p'"), false, true);
    for (0..3) |_| _ = recordWithMode(a, mkShell(a, "grep -rn foo src | head -20"), false, true);
    if (recordWithMode(a, mkShell(a, "find . -maxdepth 3 -name '*.py'"), false, true)) |nudge| {
        try std.testing.expect(std.mem.indexOf(u8, nudge, "exploration balance:") != null);
        fired += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fired);

    // Mutating sed -i or test run resets the streak and re-arms the nudge.
    try std.testing.expect(recordWithMode(a, mkShell(a, "sed -i 's/a/b/' compiler.go"), false, true) == null);
    for (0..read_streak_threshold) |_| {
        if (recordWithMode(a, mkShell(a, "git grep needle"), false, true)) |_| fired += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fired);
}
