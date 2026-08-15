//! Application model: screens, focus, overlays, conversation entries.
//! No zigzag — input is TUI/input.zig.

const std = @import("std");

const engine = @import("engine.zig");
const input_mod = @import("input.zig");
const theme_mod = @import("theme.zig");

pub const Screen = enum { welcome, agent };
pub const Focus = enum { prompt, scrollback };
pub const Overlay = enum { none, palette, help, theme, model, effort, settings, rewind, slash, debug, image, file, jump };
pub const AgentMode = enum { normal, plan, always_approve };
pub const EscArm = enum { none, clear, rewind };
pub const EntryKind = enum { user, assistant, tool, system, err, pending };

pub const Entry = struct {
    kind: EntryKind,
    text: []const u8,
    folded: bool = false,
};

pub const Effect = enum { stay, quit, background };

pub const ESC_MS: u64 = 800;

pub const Model = struct {
    alloc: std.mem.Allocator,
    input: input_mod.Input,
    history: std.array_list.Managed(Entry),
    prompt_hist: std.array_list.Managed([]const u8),
    steer_queue: std.array_list.Managed([]const u8),
    images: std.array_list.Managed([]const u8),
    pending: ?*engine.Job = null,

    screen: Screen = .welcome,
    focus: Focus = .prompt,
    overlay: Overlay = .none,
    overlay_sel: usize = 0,
    overlay_filter: []const u8 = "",
    slash_sel: usize = 0,

    theme_id: theme_mod.Id = .night,
    /// Set once the user picks a theme; blocks the OSC-11 auto polarity.
    theme_explicit: bool = false,
    mode: AgentMode = .normal,
    effort: engine.Effort = .medium,
    fast: bool = false,
    thinking_show: bool = false,
    ultracode: bool = false,
    strict: bool = false,
    title: bool = true,
    multiline: bool = false,
    compact_mode: bool = false,
    vim_mode: bool = false,
    follow: bool = true,
    running: bool = true,

    goal: ?[]const u8 = null,
    session_name: ?[]const u8 = null,
    scroll: usize = 0,
    selected: usize = 0,
    turns: usize = 0,
    chars_in: usize = 0,
    chars_out: usize = 0,
    last_term_width: usize = 80,
    last_term_height: usize = 24,
    /// Screen row (0-based) where scrollback/welcome starts — for mouse hits.
    mid_origin: usize = 0,
    /// First screen row (0-based) of the composer — clicks here focus the prompt.
    prompt_origin: usize = 20,
    /// How many mid-lines were clipped above the viewport.
    mid_skip: usize = 0,
    now_ms: u64 = 0,
    hist_idx: ?usize = null,
    /// Newline-joined paths for the @-file picker, loaded once per session.
    files_cache: ?[]const u8 = null,

    toast: []const u8 = "",
    toast_until_ms: u64 = 0,
    esc_arm: EscArm = .none,
    esc_until_ms: u64 = 0,
    new_arm_until_ms: u64 = 0,
    preview_path: []const u8 = "",
    preview_n: u32 = 0,
    preview_pin: bool = false,
    preview_rows: usize = 0,
    cancel_requested: bool = false,
    quit_requested: bool = false,
    chat: bool = false,
    pasting: bool = false,

    pub fn setup(self: *Model, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .input = input_mod.Input.init(alloc),
            .history = std.array_list.Managed(Entry).init(alloc),
            .prompt_hist = std.array_list.Managed([]const u8).init(alloc),
            .steer_queue = std.array_list.Managed([]const u8).init(alloc),
            .images = std.array_list.Managed([]const u8).init(alloc),
            .chat = engine.g_turn_fn != null,
        };
        self.input.setPlaceholder("");
    }

    pub fn deinit(self: *Model) void {
        if (self.pending) |job| self.destroyJob(job);
        for (self.history.items) |e| self.alloc.free(e.text);
        self.history.deinit();
        for (self.prompt_hist.items) |s| self.alloc.free(s);
        self.prompt_hist.deinit();
        for (self.steer_queue.items) |s| self.alloc.free(s);
        self.steer_queue.deinit();
        for (self.images.items) |s| self.alloc.free(s);
        self.images.deinit();
        if (self.goal) |g| self.alloc.free(g);
        if (self.session_name) |s| self.alloc.free(s);
        if (self.overlay_filter.len > 0) self.alloc.free(self.overlay_filter);
        if (self.files_cache) |f| self.alloc.free(f);
        self.input.deinit();
    }

    pub fn destroyJob(self: *Model, job: *engine.Job) void {
        if (job.threaded) job.thread.join();
        if (job.result) |r| self.alloc.free(r);
        for (job.history) |t| self.alloc.free(t.text);
        self.alloc.free(job.history);
        if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
        self.alloc.destroy(job);
        self.pending = null;
    }

    pub fn theme(self: *const Model) theme_mod.Theme {
        return theme_mod.of(self.theme_id);
    }

    pub fn push(self: *Model, kind: EntryKind, text: []const u8) !void {
        const owned = try sanitized(self.alloc, text);
        errdefer self.alloc.free(owned);
        try self.history.append(.{ .kind = kind, .text = owned, .folded = kind == .tool });
        if (kind == .user or kind == .assistant) {
            self.screen = .agent;
            self.follow = true;
            self.scroll = 0;
        }
    }

    pub fn pushFmt(self: *Model, kind: EntryKind, comptime fmt: []const u8, args: anytype) !void {
        const raw = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(raw);
        const text = try sanitized(self.alloc, raw);
        errdefer self.alloc.free(text);
        try self.history.append(.{ .kind = kind, .text = text });
    }

    pub fn setToast(self: *Model, text: []const u8) void {
        self.toast = text;
        self.toast_until_ms = self.now_ms + 1500;
    }

    pub fn clearHistory(self: *Model) void {
        for (self.history.items) |e| self.alloc.free(e.text);
        self.history.clearRetainingCapacity();
        self.turns = 0;
        self.chars_in = 0;
        self.chars_out = 0;
        self.selected = 0;
        self.scroll = 0;
        self.screen = .welcome;
    }

    pub fn userTurnCount(self: *const Model) usize {
        var n: usize = 0;
        for (self.history.items) |e| {
            if (e.kind == .user) n += 1;
        }
        return n;
    }

    pub fn modeLabel(self: *const Model) []const u8 {
        return switch (self.mode) {
            .normal => "Normal",
            .plan => "Plan",
            .always_approve => "Always-approve",
        };
    }

    pub fn modeSlug(self: *const Model) []const u8 {
        return switch (self.mode) {
            .normal => "normal",
            .plan => "plan",
            .always_approve => "always-approve",
        };
    }

    /// Inclusive-exclusive run of consecutive `.tool` rows containing `idx`.
    pub fn toolRun(self: *const Model, idx: usize) struct { start: usize, end: usize } {
        if (idx >= self.history.items.len or self.history.items[idx].kind != .tool)
            return .{ .start = idx, .end = idx };
        var start = idx;
        while (start > 0 and self.history.items[start - 1].kind == .tool) start -= 1;
        var end = idx + 1;
        while (end < self.history.items.len and self.history.items[end].kind == .tool) end += 1;
        return .{ .start = start, .end = end };
    }

    pub fn toggleToolGroup(self: *Model, idx: usize) void {
        const run = self.toolRun(idx);
        if (run.start >= run.end) return;
        const open = !self.history.items[run.start].folded;
        var i = run.start;
        while (i < run.end) : (i += 1) self.history.items[i].folded = open;
    }

    pub fn cycleMode(self: *Model) void {
        self.mode = switch (self.mode) {
            .normal => .plan,
            .plan => .always_approve,
            .always_approve => .normal,
        };
        self.setToast(self.modeLabel());
    }

    pub fn closeOverlay(self: *Model) void {
        self.overlay = .none;
        self.overlay_sel = 0;
        self.preview_path = "";
        self.preview_n = 0;
        self.preview_pin = false;
        if (self.overlay_filter.len > 0) {
            self.alloc.free(self.overlay_filter);
            self.overlay_filter = "";
        }
    }

    pub fn openOverlay(self: *Model, which: Overlay) void {
        self.overlay = which;
        self.overlay_sel = 0;
        if (self.overlay_filter.len > 0) {
            self.alloc.free(self.overlay_filter);
            self.overlay_filter = "";
        }
    }

    pub fn typeOverlayFilter(self: *Model, c: u8) void {
        const old = self.overlay_filter;
        const buf = self.alloc.alloc(u8, old.len + 1) catch return;
        if (old.len > 0) @memcpy(buf[0..old.len], old);
        buf[old.len] = c;
        if (old.len > 0) self.alloc.free(old);
        self.overlay_filter = buf;
        self.overlay_sel = 0;
    }

    pub fn attachImage(self: *Model, path: []const u8) void {
        const owned = self.alloc.dupe(u8, path) catch return;
        self.images.append(owned) catch {
            self.alloc.free(owned);
            return;
        };
        self.setToast(if (self.images.items.len == 1) "[Image #1] attached" else "image attached");
    }

    pub fn takeImagesPrefix(self: *Model, a: std.mem.Allocator) []const u8 {
        if (self.images.items.len == 0) return "";
        var out = std.array_list.Managed(u8).init(a);
        for (self.images.items) |p| {
            out.appendSlice("@[") catch {};
            out.appendSlice(p) catch {};
            out.appendSlice("] ") catch {};
        }
        for (self.images.items) |p| self.alloc.free(p);
        self.images.clearRetainingCapacity();
        return out.toOwnedSlice() catch "";
    }

    pub fn backspaceOverlayFilter(self: *Model) void {
        const old = self.overlay_filter;
        if (old.len == 0) return;
        if (old.len == 1) {
            self.alloc.free(old);
            self.overlay_filter = "";
        } else {
            const buf = self.alloc.dupe(u8, old[0 .. old.len - 1]) catch return;
            self.alloc.free(old);
            self.overlay_filter = buf;
        }
        self.overlay_sel = 0;
    }
};

/// History entries render verbatim inside the alt screen — drop escape
/// sequences and stray C0 controls a tool result (or the model) may carry.
fn sanitized(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null and
        std.mem.indexOfScalar(u8, text, '\r') == null) return alloc.dupe(u8, text);
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            i = theme_mod.skipEsc(text, i);
            continue;
        }
        if ((c < 0x20 and c != '\n' and c != '\t') or c == 0x7f) {
            i += 1;
            continue;
        }
        try out.append(c);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "cycleMode walks Normal → Plan → Always-approve" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(AgentMode.normal, m.mode);
    m.cycleMode();
    try std.testing.expectEqual(AgentMode.plan, m.mode);
    m.cycleMode();
    try std.testing.expectEqual(AgentMode.always_approve, m.mode);
}

test "push user flips welcome to agent" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Screen.welcome, m.screen);
    try m.push(.user, "hi");
    try std.testing.expectEqual(Screen.agent, m.screen);
}

test "push strips raw ANSI, OSC, and CR from tool text" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.tool, "⚙ bash | \x1b[31mred\x1b[0m\x1b]0;title\x07 done\r");
    try std.testing.expectEqualStrings("⚙ bash | red done", m.history.items[0].text);
}
