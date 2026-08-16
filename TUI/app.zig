//! Application model: screens, focus, overlays, conversation entries.
//! No zigzag — input is TUI/input.zig.

const std = @import("std");

const engine = @import("engine.zig");
const input_mod = @import("input.zig");
const theme_mod = @import("theme.zig");

pub const Screen = enum { welcome, agent };
pub const Focus = enum { prompt, scrollback };
pub const Overlay = enum { none, palette, help, theme, model, effort, settings, rewind, slash, debug, image, file, jump };
/// One vocabulary with the engine (#551): the Model does not keep a private
/// copy of the permission policy, it holds the engine's own enum and hands it
/// straight to the turn backend.
pub const AgentMode = engine.Mode;
pub const EscArm = enum { none, clear, rewind };
pub const EntryKind = enum { user, assistant, tool, system, err, pending };

/// A tool row's payload, straight off the engine's ToolInvocation /
/// ToolOutcome / ToolRejection (#551). Rendering reads these FIELDS; nothing
/// re-derives them by splitting a rendered line on a glyph or on " | ".
pub const ToolInfo = struct {
    /// The engine's tool name, verbatim. Classification (mcp / search) tests
    /// this, never the whole row.
    name: []const u8,
    /// Argument preview on a call, result preview on an outcome.
    detail: []const u8 = "",
    /// false = the call was announced, true = it returned (or was refused).
    done: bool = false,
    is_error: bool = false,
    /// Refused by the harness before it ran.
    denied: bool = false,
};

pub const Entry = struct {
    kind: EntryKind,
    text: []const u8,
    folded: bool = false,
    /// Non-null on every `.tool` row a live turn produces. Null on a legacy
    /// `.tool` row restored from a session written before the typed contract —
    /// those still render from `text` alone (see scrollback.zig), which is the
    /// whole reason this is optional rather than required.
    tool: ?ToolInfo = null,
};

pub const Effect = enum { stay, quit, background };

/// The rows of a composed frame that a scroll actually MOVES: content only, no
/// chrome. `off` is the transcript line the first of them shows, so comparing
/// two consecutive frames' bands says whether the viewport merely slid — which
/// is the one thing a row-against-row diff can never see (perf/tui-scroll-paint).
/// `live` is false whenever there is nothing scrollable: the welcome pane, a
/// transcript shorter than the viewport.
pub const Band = struct {
    live: bool = false,
    /// First screen row of the band, 0-based.
    top: usize = 0,
    len: usize = 0,
    /// Index, in the composed mid-lines, of the line on `top`.
    off: usize = 0,
    /// Visual lines the band is a window ONTO — the whole wrapped transcript,
    /// not the screenful of it. The scrollbar's proportions come from here.
    total: usize = 0,
};

pub const ESC_MS: u64 = 800;

pub const Model = struct {
    alloc: std.mem.Allocator,
    input: input_mod.Input,
    history: std.array_list.Managed(Entry),
    prompt_hist: std.array_list.Managed([]const u8),
    steer_queue: std.array_list.Managed([]const u8),
    images: std.array_list.Managed([]const u8),
    pending: ?*engine.Job = null,
    /// A background engine op (/compact, !cmd, @-file list) — same thread +
    /// done-flag contract as `pending`, so neither can freeze the loop (#533).
    bg: ?*engine.BgOp = null,

    screen: Screen = .welcome,
    focus: Focus = .prompt,
    overlay: Overlay = .none,
    overlay_sel: usize = 0,
    overlay_filter: []const u8 = "",
    slash_sel: usize = 0,

    theme_id: theme_mod.Id = .night,
    /// Set once the user picks a theme; blocks the OSC-11 auto polarity.
    theme_explicit: bool = false,
    /// Rows of sticky-header chrome at the top of the viewport this frame —
    /// keys.zig must treat them as inert instead of clicking what they occlude.
    sticky_rows: usize = 0,
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
    /// Owns the string `engine.g_model_name` points at after a mid-turn
    /// provider failover (#551): the event that carried it is freed as soon as
    /// the drain that delivered it returns.
    model_override: ?[]const u8 = null,
    scroll: usize = 0,
    selected: usize = 0,
    turns: usize = 0,
    /// The engine's last reported meters (#551). Null until a turn has run —
    /// there is nothing honest to say about a context nobody has measured.
    /// Its strings are owned here; setStatus and deinit are the only writers.
    status: ?engine.Status = null,
    last_term_width: usize = 80,
    last_term_height: usize = 24,
    /// Screen row (0-based) where scrollback/welcome starts — for mouse hits.
    mid_origin: usize = 0,
    /// First screen row (0-based) of the composer — clicks here focus the prompt.
    prompt_origin: usize = 20,
    /// How many mid-lines were clipped above the viewport.
    mid_skip: usize = 0,
    /// The scrollable band of the frame just composed, and the painter hint
    /// derived from how it moved since the frame before it. Presentation state
    /// for the diff painter's scroll fast path: render.zig is the only writer,
    /// paint.zig the only reader, and both treat it as a claim to verify.
    band: Band = .{},
    paint_hint: ?@import("scrollpaint.zig").Hint = null,
    now_ms: u64 = 0,
    /// When the viewport last MOVED. The scrollbar fades out of a tail-parked
    /// viewport this many milliseconds later (scrollbar.zig); zero means the
    /// session has never scrolled, so no gutter has ever been earned.
    scroll_seen_ms: u64 = 0,
    /// A one-shot byte string the run loop owes the TERMINAL, not the screen:
    /// the OSC 52 clipboard write a copy just produced. Deliberately not part
    /// of the frame — a frame is re-painted (the self-heal rewrites it every
    /// few seconds), and a clipboard write must happen exactly once.
    osc_pending: []const u8 = "",
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
    /// Drag-selection band over the composed frame (#529) — presentation only.
    sel: @import("selection.zig").Sel = .{},
    /// Wrapped-line layout of the transcript, keyed by width/theme/fold/entry
    /// identity (layout_cache.zig). Presentation state: a pure memo of what the
    /// row builders would produce, so scrolling is a slice and not a re-layout.
    layout: @import("layout_cache.zig").Cache = .{},
    /// Text the band currently covers, captured by the same pass that paints
    /// it, so what the clipboard gets is exactly what the user saw highlighted.
    sel_text: []const u8 = "",
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
        // Never an unbounded join in a destructor (#534): by the time deinit
        // runs, run.zig's terminal defers have already handed the shell back,
        // so joining a stalled provider call here hangs invisibly. run.zig
        // settles the job while the alt screen is still up; a thread still
        // running at this point is abandoned, leak and all.
        if (self.pending) |job| {
            if (!job.threaded or job.done.load(.acquire)) self.destroyJob(job) else self.pending = null;
        }
        if (self.bg) |op| {
            if (!op.threaded or op.done.load(.acquire)) @import("bgop.zig").reap(self) else self.bg = null;
        }
        self.layout.deinit(self.alloc);
        for (self.history.items) |e| self.freeEntry(e);
        self.history.deinit();
        for (self.prompt_hist.items) |s| self.alloc.free(s);
        self.prompt_hist.deinit();
        for (self.steer_queue.items) |s| self.alloc.free(s);
        self.steer_queue.deinit();
        for (self.images.items) |s| self.alloc.free(s);
        self.images.deinit();
        if (self.goal) |g| self.alloc.free(g);
        if (self.session_name) |s| self.alloc.free(s);
        self.dropStatus();
        if (self.model_override) |m| {
            // The global points into this buffer; drop it before the free so a
            // late reader cannot follow a dangling slice.
            if (engine.g_model_name.ptr == m.ptr) engine.g_model_name = "";
            self.alloc.free(m);
        }
        if (self.overlay_filter.len > 0) self.alloc.free(self.overlay_filter);
        if (self.files_cache) |f| self.alloc.free(f);
        if (self.sel_text.len > 0) self.alloc.free(self.sel_text);
        if (self.osc_pending.len > 0) self.alloc.free(self.osc_pending);
        self.input.deinit();
    }

    pub fn destroyJob(self: *Model, job: *engine.Job) void {
        if (job.threaded) job.thread.join();
        if (job.result) |r| self.alloc.free(r);
        for (job.history) |t| self.alloc.free(t.text);
        self.alloc.free(job.history);
        if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
        job.events.deinit();
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

    /// Append a FIELD-BACKED tool row (#551). `name`/`detail` come from the
    /// engine's typed event and are copied here; `text` is kept only as the
    /// plain fallback the non-rendering readers use (sticky header, selection
    /// copy, session persistence), never as the thing rendering parses.
    pub fn pushTool(self: *Model, info: ToolInfo) !void {
        const name = try self.alloc.dupe(u8, info.name);
        errdefer self.alloc.free(name);
        const detail = try sanitized(self.alloc, info.detail);
        errdefer self.alloc.free(detail);
        const text = if (detail.len > 0)
            try std.fmt.allocPrint(self.alloc, "{s}  {s}", .{ name, detail })
        else
            try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(text);
        try self.history.append(.{
            .kind = .tool,
            .text = text,
            .folded = true,
            .tool = .{
                .name = name,
                .detail = detail,
                .done = info.done,
                .is_error = info.is_error,
                .denied = info.denied,
            },
        });
    }

    /// Release everything an entry owns. Tool rows own two extra strings, so
    /// freeing `text` alone leaks them.
    pub fn freeEntry(self: *Model, e: Entry) void {
        self.alloc.free(e.text);
        if (e.tool) |t| {
            self.alloc.free(t.name);
            self.alloc.free(t.detail);
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
        // Before the entries go: the layout holds wrapped bytes for them and a
        // back-pointer into their text.
        self.layout.invalidate(self.alloc);
        for (self.history.items) |e| self.freeEntry(e);
        self.history.clearRetainingCapacity();
        self.turns = 0;
        // The meters describe a conversation that no longer exists. Compaction
        // replays through here too and re-reports its own on the next turn.
        self.dropStatus();
        self.selected = 0;
        self.scroll = 0;
        self.screen = .welcome;
    }

    /// Adopt the engine's meters. The event's copy dies with the drain that
    /// delivered it, so the two strings are re-owned here.
    pub fn setStatus(self: *Model, st: engine.Status) void {
        const model = self.alloc.dupe(u8, st.model) catch return;
        const provider = self.alloc.dupe(u8, st.provider_id) catch {
            self.alloc.free(model);
            return;
        };
        self.dropStatus();
        var owned = st;
        owned.model = model;
        owned.provider_id = provider;
        self.status = owned;
    }

    pub fn dropStatus(self: *Model) void {
        const st = self.status orelse return;
        self.alloc.free(st.model);
        self.alloc.free(st.provider_id);
        self.status = null;
    }

    /// Percent of the model's context window in use, or null while nothing has
    /// been measured — a "0%" drawn before the first response is a lie.
    pub fn contextPercent(self: *const Model) ?u64 {
        const st = self.status orelse return null;
        if (!st.has_context) return null;
        return st.percent();
    }

    /// /new, /clear, Ctrl+N twice: start over. Distinct from clearHistory,
    /// which the compaction replay also uses — that one REPLACES the visible
    /// transcript for a conversation the engine has just rewritten and must
    /// keep, while this one throws the conversation away too (#551).
    ///
    /// Returns false while an engine call is in flight, and does nothing: the
    /// reset frees the arena that call is allocating its history from, so
    /// "clear the screen" would be a use-after-free on the turn thread. /new
    /// already refused mid-turn (#521); Ctrl+N did not, and only became
    /// dangerous once the reset reached past the transcript.
    pub fn newSession(self: *Model) bool {
        if (self.pending != null or self.bg != null) return false;
        self.clearHistory();
        engine.historyChanged(.reset);
        return true;
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
