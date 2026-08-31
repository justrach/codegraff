//! The session-lifecycle cluster's terminal half (#422 slice 2), the sibling
//! of agent_stream_render.zig (the stream) and agent_tool_render.zig (tools):
//! the one file down here that reaches the palette, so the lifecycle engine
//! files (session_start, session_run, providers, hooks) reach none of it.
//!
//! Every function is the old inline code path byte for byte — the format
//! strings, the argument order, and the two places where a reset deliberately
//! lands somewhere other than just before the newline are reproduced exactly,
//! because a rendered line changing shape is a UX change and this is a
//! refactor. Two intentional differences from the inline originals, both
//! shared with slice 1: write errors are swallowed rather than propagated (a
//! sink cannot fail its emitter), and every line flushes.
//!
//! `emit` takes an OPTIONAL writer: this cluster runs where a frontend may not
//! exist at all (a one-shot with stdout reserved for the answer, `graff acp`).
//! Null means "no frontend": almost everything is then silent, exactly as
//! before, and the failover notice falls back to stderr the way its old
//! `std.debug.print` branch did.

const std = @import("std");
const Io = std.Io;

const ansi = @import("ansi.zig");
const style = &ansi.style;
const terminal = @import("term.zig");
const mcp_config = @import("mcp_config.zig"); // the global config path the consent prompt names
const engine_events = @import("engine_events.zig");
const EngineEvent = engine_events.EngineEvent;

/// The `-w` line's suffix when the session will checkpoint each turn.
const autocommit_suffix = " · auto-committing each turn (`graff worktree merge` to land it)";

/// Startup found a color-capable terminal. A capability handshake rather than
/// an event — nothing has been drawn yet — but the palette is this half's own
/// state, so the engine says only that color exists and this decides what it
/// looks like. Reached through engine_sink.enableColor.
pub fn enableColor() void {
    ansi.style = ansi.Style.ansi;
}

/// Draw one lifecycle event, or nothing when the moment belongs to another
/// cluster. The caller has already applied the engine's own gates (json_mode,
/// one-shot) — see the vocabulary's note on why those stayed at the emit site.
pub fn emit(w: ?*Io.Writer, ev: EngineEvent) void {
    switch (ev) {
        .session_notice => |n| notice(w, n),
        .session_banner => |b| line(w, "{s}codegraff{s}  {s}{s}{s}\n", .{
            style.bold, style.reset, style.accent, b.cwd, style.reset,
        }),
        .worktree_entered => |t| line(w, "{s}worktree:{s} {s}{s}{s} (branch {s}) — edits isolated from the main checkout{s}\n", .{
            style.dim,                                   style.reset, style.accent, t.path, style.reset, t.branch,
            if (t.autocommit) autocommit_suffix else "",
        }),
        .shared_worktree_owner => |owner| sharedWorktreeOwner(w, owner),
        .saved_model_unavailable => |m| savedModelUnavailable(w, m),
        .mcp_consent_prompt => |p| line(
            w,
            "{s}⚠ {d} untrusted MCP server(s) are configured for this session (.mcp.json and/or ~/" ++
                mcp_config.global_rel_path ++
                "). They may run local commands or receive data over the network. Connect them this session? [y/N] {s}",
            .{ style.bold, p.count, style.reset },
        ),
        .provider_fallback => |f| providerFallback(w, f),
        .session_saved => |s| line(w, "{s}↩ session saved → {s}{s}{s}\n", .{ style.dim, s.name, style.reset, s.ext }),
        // #396: the run is over, so the terminal goes back to the shell before
        // teardown. Unconditional, as the old inline call was — a --json
        // one-shot still ran on somebody's tty.
        .run_finished => terminal.tty.releaseTerminal(),
        else => {},
    }
}

/// An ordinary notice: the tone colors the whole line, or just the badge when
/// the notice carries one. A plain notice emits no escape bytes at all, which
/// is what keeps the un-styled lines (the Codex login line, the MCP init
/// failure) byte-identical to their old un-styled prints.
fn notice(w: ?*Io.Writer, n: engine_events.Notice) void {
    const color = toneColor(n.tone);
    if (n.lead.len > 0) return line(w, "{s}{s}{s}{s}\n", .{ color, n.lead, style.reset, n.text });
    if (n.tone == .plain) return line(w, "{s}\n", .{n.text});
    line(w, "{s}{s}{s}\n", .{ color, n.text, style.reset });
}

fn toneColor(tone: engine_events.Notice.Tone) []const u8 {
    return switch (tone) {
        .plain => "",
        .dim => style.dim,
        .warn => style.yellow,
        .alert => style.red,
    };
}

fn sharedWorktreeOwner(w: ?*Io.Writer, owner: engine_events.SharedWorktreeOwner) void {
    const out = w orelse return;
    const session_id = if (owner.session_id.len > 0) owner.session_id else "unknown session";
    out.print("{s}╭─{s} {s}{s}◆ Shared worktree{s}\n", .{ style.dim, style.reset, style.accent, style.bold, style.reset }) catch return;
    out.print("{s}│{s} {s}Active session{s}  {s}{s}{s} · pid {d} · active {d}m\n", .{
        style.dim, style.reset, style.dim, style.reset, style.accent, session_id, style.reset, owner.pid, owner.active_minutes,
    }) catch return;
    if (owner.goal.len > 0) out.print("{s}│{s} {s}Goal{s}            {s}\n", .{ style.dim, style.reset, style.dim, style.reset, owner.goal }) catch return;
    out.print("{s}╰─{s} Edits share this checkout. Coordinate, or restart with {s}graff -w{s} to isolate.\n", .{
        style.dim, style.reset, style.bold, style.reset,
    }) catch return;
    out.flush() catch {};
}

/// The startup twin of providerFallback. The reset lands AFTER the newline
/// here because the inline original wrote it with a separate `writeAll`, and
/// this is a refactor: the bytes are the contract.
fn savedModelUnavailable(w: ?*Io.Writer, m: engine_events.SavedModelNotice) void {
    const out = w orelse return;
    out.print("{s}note: saved model '{s}' is unavailable — selected {s} via {s} for this session; saved preference kept{s}{s}\n", .{
        style.dim,
        m.saved,
        m.model,
        m.provider,
        if (m.blocked) ". Cross-provider use is blocked until /fallback allow " else "",
        if (m.blocked) m.provider else "",
    }) catch return;
    out.writeAll(style.reset) catch return;
    out.flush() catch {};
}

/// A run with no frontend still owes the user this one: a silent model swap is
/// a cost and consent surprise, so it goes to stderr when stdout is reserved
/// for the answer (`-p`) or is a protocol stream someone else owns (`acp`).
fn providerFallback(w: ?*Io.Writer, f: engine_events.ProviderFallback) void {
    const out = w orelse {
        std.debug.print("⚠ {s} via {s} is unavailable; trying {s} via {s} for this session ({s}) — saved default kept\n", .{
            f.from_model, f.from_provider, f.to_model, f.to_provider, f.context_note,
        });
        return;
    };
    line(out, "{s}⚠ {s} via {s} is unavailable; trying {s} via {s} for this session ({s}) — saved default kept{s}\n", .{
        style.yellow, f.from_model, f.from_provider, f.to_model, f.to_provider, f.context_note, style.reset,
    });
}

fn line(w: ?*Io.Writer, comptime fmt: []const u8, args: anytype) void {
    const out = w orelse return;
    out.print(fmt, args) catch return;
    out.flush() catch {};
}

// ── Byte-identity tests ──────────────────────────────────────────────────
// Each case is the literal the pre-#429 inline call site produced, spelled out
// rather than rebuilt from the same constants: a test that compares the code
// to itself cannot guard a conversion.

/// Render one event into a fresh buffer with the palette pinned so the
/// assertions are about text, not about which escape codes are in fashion.
fn renderTest(aw: *Io.Writer.Allocating, ev: EngineEvent) []const u8 {
    aw.clearRetainingCapacity();
    emit(&aw.writer, ev);
    return aw.writer.buffered();
}

test "slice 2: the startup lines render exactly as the inline prints did" {
    const saved = ansi.style;
    ansi.style = .{}; // color off: the un-styled shape the no-TTY startup writes
    defer ansi.style = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try std.testing.expectEqualStrings(
        "codegraff  /repo\n",
        renderTest(&aw, .{ .session_banner = .{ .cwd = "/repo", .trace_path = ".graff/traces/ab.jsonl" } }),
    );
    try std.testing.expectEqualStrings(
        "worktree: .graff/worktrees/w (branch worktree-w) — edits isolated from the main checkout · auto-committing each turn (`graff worktree merge` to land it)\n",
        renderTest(&aw, .{ .worktree_entered = .{ .path = ".graff/worktrees/w", .branch = "worktree-w", .autocommit = true } }),
    );
    try std.testing.expectEqualStrings(
        "worktree: .graff/worktrees/w (branch worktree-w) — edits isolated from the main checkout\n",
        renderTest(&aw, .{ .worktree_entered = .{ .path = ".graff/worktrees/w", .branch = "worktree-w", .autocommit = false } }),
    );
    try std.testing.expectEqualStrings(
        "╭─ ◆ Shared worktree\n" ++
            "│ Active session  session-42 · pid 4242 · active 5m\n" ++
            "│ Goal            polish startup output\n" ++
            "╰─ Edits share this checkout. Coordinate, or restart with graff -w to isolate.\n",
        renderTest(&aw, .{ .shared_worktree_owner = .{
            .session_id = "session-42",
            .pid = 4242,
            .active_minutes = 5,
            .goal = "polish startup output",
        } }),
    );
    try std.testing.expectEqualStrings(
        "note: saved model 'k2' is unavailable — selected sonnet via anthropic for this session; saved preference kept\n",
        renderTest(&aw, .{ .saved_model_unavailable = .{ .saved = "k2", .model = "sonnet", .provider = "anthropic", .blocked = false } }),
    );
    try std.testing.expectEqualStrings(
        "note: saved model 'k2' is unavailable — selected sonnet via anthropic for this session; saved preference kept. Cross-provider use is blocked until /fallback allow anthropic\n",
        renderTest(&aw, .{ .saved_model_unavailable = .{ .saved = "k2", .model = "sonnet", .provider = "anthropic", .blocked = true } }),
    );
    // No trailing newline: the answer is typed on this line (still #430's).
    try std.testing.expectEqualStrings(
        "⚠ 2 untrusted MCP server(s) are configured for this session (.mcp.json and/or ~/.codegraff/mcp.json). They may run local commands or receive data over the network. Connect them this session? [y/N] ",
        renderTest(&aw, .{ .mcp_consent_prompt = .{ .count = 2 } }),
    );
    try std.testing.expectEqualStrings(
        "↩ session saved → session-17.session.json\n",
        renderTest(&aw, .{ .session_saved = .{ .name = "session-17", .ext = ".session.json" } }),
    );
}

test "slice 2: a notice's tone colors the line, a badge colors only itself" {
    const saved = ansi.style;
    ansi.style = ansi.Style.ansi; // the interactive palette: where the escapes matter
    defer ansi.style = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // Whole-line dim, reset before the newline — the shape every startup
    // "loaded N …" / "[mcp:…] …" line had inline.
    try std.testing.expectEqualStrings(
        "\x1b[2mloaded 2 saved approval(s) from .harness/settings.json\x1b[0m\n",
        renderTest(&aw, .{ .session_notice = .{ .text = "loaded 2 saved approval(s) from .harness/settings.json", .tone = .dim } }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[33m⚠ session save failed: AccessDenied\x1b[0m\n",
        renderTest(&aw, .{ .session_notice = .{ .text = "⚠ session save failed: AccessDenied", .tone = .warn } }),
    );
    // A badge is colored and closed, then the rest of the line rides plain.
    try std.testing.expectEqualStrings(
        "\x1b[31m⚠ YOLO\x1b[0m mode (--yolo): all bash/tool/MCP permission prompts are skipped\n",
        renderTest(&aw, .{ .session_notice = .{
            .lead = "⚠ YOLO",
            .text = " mode (--yolo): all bash/tool/MCP permission prompts are skipped",
            .tone = .alert,
        } }),
    );
    // A plain notice emits no escape bytes even with the palette live.
    try std.testing.expectEqualStrings(
        "[mcp] init failed: ConnectionRefused — continuing without MCP\n",
        renderTest(&aw, .{ .session_notice = .{ .text = "[mcp] init failed: ConnectionRefused — continuing without MCP" } }),
    );
}

test "slice 2: yolo boot receipts match the plugins line (dim, then reset)" {
    const saved = ansi.style;
    ansi.style = ansi.Style.ansi;
    defer ansi.style = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const plugins = "plugins: 16 plugin(s) in 1ms (7 dirs)";
    const mcp = "mcp: 3 server(s) in background";
    const companion = "companion: codedb-pro (background)";
    try std.testing.expectEqualStrings(
        "\x1b[2m" ++ plugins ++ "\x1b[0m\n",
        renderTest(&aw, .{ .session_notice = .{ .text = plugins, .tone = .dim } }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[2m" ++ mcp ++ "\x1b[0m\n",
        renderTest(&aw, .{ .session_notice = .{ .text = mcp, .tone = .dim } }),
    );
    try std.testing.expectEqualStrings(
        "\x1b[2m" ++ companion ++ "\x1b[0m\n",
        renderTest(&aw, .{ .session_notice = .{ .text = companion, .tone = .dim } }),
    );
}

test "slice 2: the failover notice, with a frontend and without one" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const swap: engine_events.ProviderFallback = .{
        .from_provider = "codex",
        .from_model = "gpt-5.5",
        .to_provider = "anthropic",
        .to_model = "sonnet",
        .to_context = 200_000,
        .context_note = "context kept",
    };
    try std.testing.expectEqualStrings(
        "⚠ gpt-5.5 via codex is unavailable; trying sonnet via anthropic for this session (context kept) — saved default kept\n",
        renderTest(&aw, .{ .provider_fallback = swap }),
    );
    // With no writer the notice goes to stderr instead of vanishing; nothing
    // reaches the (absent) frontend, which is what this can assert.
    emit(null, .{ .provider_fallback = swap });
}

test "slice 2: a frontendless lifecycle draws nothing" {
    // Everything except the failover is silent with no writer — and none of it
    // may fault on the null.
    emit(null, .{ .session_banner = .{ .cwd = "/repo", .trace_path = "t" } });
    emit(null, .{ .session_notice = .{ .text = "x", .tone = .dim } });
    emit(null, .{ .worktree_entered = .{ .path = "p", .branch = "b", .autocommit = true } });
    emit(null, .{ .shared_worktree_owner = .{ .session_id = "s", .pid = 1, .active_minutes = 0, .goal = "" } });
    emit(null, .{ .saved_model_unavailable = .{ .saved = "a", .model = "b", .provider = "c", .blocked = true } });
    emit(null, .{ .mcp_consent_prompt = .{ .count = 1 } });
    emit(null, .{ .session_saved = .{ .name = "s", .ext = ".session.json" } });
    // A moment from another cluster is not this renderer's business.
    emit(null, .{ .text_delta = .{ .text = "hi" } });
}
