//! Focused regressions for incremental markdown streaming, `/bash` result
//! ownership, and `/save`|`/resume` session-name ownership — each driven
//! through the real handler, since every one of these defects lived in a call
//! site rather than in a helper.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const Keys = @import("provider.zig").Keys;
const util = @import("util.zig");
const session_writer = @import("session_writer.zig");
const handleCommand = @import("main.zig").handleCommand;

fn prewarmCaBundle(client: *std.http.Client, gpa: std.mem.Allocator, io: Io) void {
    const now = Io.Clock.real.now(io);
    client.ca_bundle.rescan(gpa, io, now) catch return;
    client.now = now;
}

test "incremental markdown streaming renders like renderMdLine" {
    // style is the empty default in tests, so styled output == de-marked text.
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.md_buf.deinit(std.testing.allocator);
    defer a.md_word.deinit(std.testing.allocator);
    defer {
        for (a.md_table.items) |r| std.testing.allocator.free(r);
        a.md_table.deinit(std.testing.allocator);
    }

    // Prose is visible word-by-word, before any newline arrives (the
    // word in flight is held for wrap decisions).
    a.streamMarkdown("Hey! I'm her");
    try std.testing.expectEqualStrings("Hey! I'm ", aw.writer.buffered());
    a.streamMarkdown("e and ready\n");
    try std.testing.expectEqualStrings("Hey! I'm here and ready\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Bullets stream too: marker styled up front, text word-by-word, and a
    // split **bold** span styles eagerly (markers dropped as in renderInline).
    a.streamMarkdown("- has **bo");
    try std.testing.expectEqualStrings("• has ", aw.writer.buffered());
    a.streamMarkdown("ld** spans\n");
    try std.testing.expectEqualStrings("• has bold spans\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Numbered/task/nested items, headings, quotes, and inline code.
    a.streamMarkdown("12) **Immediately:** point\n## Title\nuse `zig build` here\n- [ ] ship it\n  - nested\n> warning\n");
    try std.testing.expectEqualStrings("12) Immediately: point\n◆ Title\nuse zig build here\n☐ ship it\n  ◦ nested\n│ warning\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Fences: open/close render as labeled dim rules, body streams unprefixed.
    a.streamMarkdown("```zig\nconst x = 1;\n```\nafter\n");
    try std.testing.expectEqualStrings("── zig " ++ util.repeatBytes("─", 33) ++ "\nconst x = 1;\n" ++ util.repeatBytes("─", 40) ++ "\nafter\n", aw.writer.buffered());
    try std.testing.expect(!a.md_fence);
    aw.clearRetainingCapacity();

    // Horizontal rule renders at line end.
    a.streamMarkdown("---\n");
    try std.testing.expectEqualStrings("────────────\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Tables buffer until the first non-row line, then render aligned:
    // column widths from the widest cell, header above a ─┼─ rule.
    a.streamMarkdown("| Item | Desc |\n| --- | --- |\n| 1 | Inspect files |\n");
    try std.testing.expectEqualStrings("", aw.writer.buffered()); // still buffering
    a.streamMarkdown("| 22 | Edit |\ndone\n");
    try std.testing.expectEqualStrings("Item │ Desc\n" ++
        "─────┼──────────────\n" ++
        "1    │ Inspect files\n" ++
        "22   │ Edit\n" ++
        "done\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A table pending at stream end flushes from the tail path.
    a.streamMarkdown("| x | y |");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("x │ y\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Stream tail: a partial prose line flushes whatever is pending.
    a.streamMarkdown("tail without newline");
    a.flushStreamTail();
    try std.testing.expectEqualStrings("tail without newline", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Long lines wrap at the terminal edge on word boundaries; bullet
    // continuations align under the text (hanging indent).
    a.md_width = 12; // pinned for the line — mdFinishLine re-reads after
    a.streamMarkdown("- alpha beta gamma\n");
    try std.testing.expectEqualStrings("• alpha beta\n  gamma\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // Plain prose wraps at column 0; the break replaces the joining space.
    a.md_width = 10;
    a.streamMarkdown("word1 word2 word3\n");
    try std.testing.expectEqualStrings("word1 \nword2 \nword3\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // A word too wide for any line is not torn — the terminal wraps it.
    a.md_width = 6;
    a.streamMarkdown("abc defghijklm\n");
    try std.testing.expectEqualStrings("abc defghijklm\n", aw.writer.buffered());
}

test "streamed markdown: pipe-less tables align; lone candidates stay prose; indented code streams raw" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.md_buf.deinit(std.testing.allocator);
    defer a.md_word.deinit(std.testing.allocator);
    defer {
        for (a.md_table.items) |r| std.testing.allocator.free(r);
        a.md_table.deinit(std.testing.allocator);
    }

    // Indented code blocks (4+ spaces) stream raw — never word-wrapped.
    a.md_width = 12;
    a.streamMarkdown("    const x = longcall(a, b);\n");
    try std.testing.expectEqualStrings("    const x = longcall(a, b);\n", aw.writer.buffered());
    aw.clearRetainingCapacity();

    // CRLF deltas: a stray \r must not turn the row into wrapped prose.
    a.streamMarkdown("| a | b |\r\n| --- | --- |\r\n");
    try std.testing.expectEqualStrings("", aw.writer.buffered()); // still buffering, not printed
    a.flushStreamTail();
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), " │ ") != null);
}

test "/bash slash command runs the bash tool and frees its gpa-allocated result" {
    // Regression guard for PR #38: the /bash slash handler routes through execTool, whose result.text is gpa-owned (NOT arena-owned — every other
    // caller frees it). Forgetting `defer root.gpa.free(result.text)` in handleCommand leaks on every /bash call; std.testing.allocator catches it here.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    prewarmCaBundle(&client, gpa, io);

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{
            .id = "test",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "",
            .model = "m",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
    var keys: Keys = .{ .values = @splat(null) };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    defer root.tools_used.deinit(gpa);
    try handleCommand(&root, &keys, arena, "/bash echo leak-guard-XYZ", &aw.writer);

    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "leak-guard-XYZ") != null);
}

/// True when `name` points anywhere inside the line buffer's allocation — the
/// whole defect below. A plain `name.ptr != buf.ptr` would miss it: the typed
/// name starts past the command word, so it never equals the buffer's base.
fn aliasesLineBuffer(name: []const u8, buf: std.ArrayList(u8)) bool {
    const base = @intFromPtr(buf.items.ptr);
    const p = @intFromPtr(name.ptr);
    return p >= base and p < base + buf.capacity;
}

test "typed session name survives readline reusing its line buffer" {
    // mainloop hands handleCommand a slice of ctx.linebuf, and readline clears
    // + regrows that SAME ArrayList every turn. /save and /resume each stored
    // that borrowed slice in root.session_name, which every later autosave
    // reads — so the next line the user typed silently retargeted the save.
    //
    // Both handlers are driven for real here. The defect is in the two
    // assignments, not in any helper: asserting on the helper alone stays
    // green with either call site reverted.
    //
    // saveSession/loadSession resolve against the process cwd (neither takes a
    // Dir), so move into a scratch directory for the duration — the same fchdir
    // dance agent_eval_tests.zig uses, and POSIX-only for the same reason.
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    session_writer.resetForTest();
    defer session_writer.resetForTest();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    // One user turn: #184 skips the write for a blank draft, and /save must
    // reach disk for the /resume half below to have a file to load.
    var msgs = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "first prompt" });
    try msgs.append(.{ .object = user });

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{
            .id = "anthropic",
            .kind = .anthropic,
            .auth = .x_api_key,
            .url = "",
            .api_key = "k",
            .model = "claude-opus-4-8",
            .context = 100_000,
        },
        .messages = msgs,
        .sub = false,
        .label = "root",
        .out = null,
    };
    defer root.tools_used.deinit(gpa);
    // /resume rebuilds the provider from the saved id, which needs a key.
    var keys: Keys = .{ .values = @splat("k") };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // Stands in for mainloop's ctx.linebuf: ONE allocation, cleared and
    // refilled every turn. Reserved up front so no refill ever reallocates —
    // exactly how readline reuses it, and so the stale-read is in live memory.
    var linebuf: std.ArrayList(u8) = .empty;
    defer linebuf.deinit(gpa);
    try linebuf.ensureTotalCapacity(gpa, 64);

    linebuf.appendSliceAssumeCapacity("/save alpha");
    try handleCommand(&root, &keys, arena, linebuf.items, &aw.writer);
    try std.testing.expectEqualStrings("alpha", root.session_name);
    try std.testing.expect(!aliasesLineBuffer(root.session_name, linebuf));

    // The next turn overwrites the buffer in place. A borrowed name now reads
    // "other", and every autosave from here writes the wrong session file.
    linebuf.clearRetainingCapacity();
    linebuf.appendSliceAssumeCapacity("/some other line entirely");
    try std.testing.expectEqualStrings("alpha", root.session_name);

    // /resume assigns root.session_name at its own, separate call site. It
    // reloads the file /save just wrote, so the handler runs to completion —
    // a failed load returns early and leaves this "last" behind.
    root.session_name = "last";
    linebuf.clearRetainingCapacity();
    linebuf.appendSliceAssumeCapacity("/resume alpha");
    try handleCommand(&root, &keys, arena, linebuf.items, &aw.writer);
    try std.testing.expectEqualStrings("alpha", root.session_name);
    try std.testing.expect(!aliasesLineBuffer(root.session_name, linebuf));

    linebuf.clearRetainingCapacity();
    linebuf.appendSliceAssumeCapacity("/some other line entirely");
    try std.testing.expectEqualStrings("alpha", root.session_name);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "resumed alpha") != null);
}

test "/save and /resume report a failed name copy instead of ending the REPL" {
    // mainloop.zig calls handleCommand unguarded, so an error returned from a
    // slash command tears the loop down. Every other way /save or /resume can
    // fail prints and returns to the prompt; copying the name must too. The
    // `try` on each handleCommand below IS the assertion — a propagated
    // OutOfMemory fails this test exactly as it would kill the session.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = io,
        .client = &client,
        .provider = .{
            .id = "anthropic",
            .kind = .anthropic,
            .auth = .x_api_key,
            .url = "",
            .api_key = "k",
            .model = "claude-opus-4-8",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena_state.allocator()),
        .sub = false,
        .label = "root",
        .out = null,
    };
    defer root.tools_used.deinit(gpa);
    var keys: Keys = .{ .values = @splat("k") };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // fail_index 0: the copy of the typed name is the first turn allocation,
    // so this is the OOM the two call sites have to absorb.
    for ([_][]const u8{ "/save alpha", "/resume alpha" }) |line| {
        var failing = std.testing.FailingAllocator.init(arena_state.allocator(), .{ .fail_index = 0 });
        try handleCommand(&root, &keys, failing.allocator(), line, &aw.writer);
        try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "failed: OutOfMemory") != null);
        // The name was never adopted: autosaves keep writing where they were.
        try std.testing.expectEqualStrings("last", root.session_name);
        aw.clearRetainingCapacity();
    }
}

// main.zig itself is at the 600-line ceiling (#274 fix), so
// startup_tests.zig's regression coverage is pulled in from here instead —
// same test-root-reference requirement as main.zig's own hook: an
// unreferenced module's test {} blocks silently compile to nothing.
test {
    _ = @import("startup_tests.zig");
    _ = @import("recap.zig"); // #419: session-recap bounds/heuristic/parsing tests
}

test "failure (#253): fd-quota errors carry actionable advice, system-wide says ulimit won't help" {
    const tools = @import("tools.zig");
    const gpa = std.testing.allocator;
    const p = tools.failure(gpa, error.ProcessFdQuotaExceeded);
    defer gpa.free(p.text);
    try std.testing.expect(std.mem.indexOf(u8, p.text, "ulimit -n 4096") != null);
    const s = tools.failure(gpa, error.SystemFdQuotaExceeded);
    defer gpa.free(s.text);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "SYSTEM-wide") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.text, "`ulimit` will not help") != null);
    // The generic path is untouched: unknown errors still print the bare name.
    const g = tools.failure(gpa, error.AccessDenied);
    defer gpa.free(g.text);
    try std.testing.expectEqualStrings("error: AccessDenied", g.text);
}
