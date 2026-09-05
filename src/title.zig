//! Session-title + header rendering + provider-response text extraction: the
//! mechanical prompt->title, folder basename, first-user title, the terminal
//! OSC title + session header, the streamed-reasoning + assistant-text parsers
//! per wire format, and the AI-title cleaner. Split out of main.zig (600-line
//! goal). Imports ansi (palette); back-imports main (as main_mod, since a param
//! is named `root`) for Provider, extractText, and the live use_color/json_mode
//! toggles. main aliases all 9 back.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Provider = provider_mod.Provider;
const providers = @import("providers.zig");
const extractText = providers.extractText;

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const peer_context = @import("peer_context.zig");

pub fn titleFromPrompt(prompt: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed.len == 0) return "Chat";
    var end: usize = 0;
    var codepoints: usize = 0;
    while (end < trimmed.len and codepoints < 64) {
        if (trimmed[end] == '\n' or trimmed[end] == '\r' or trimmed[end] == '\t') break;
        const cp_len = std.unicode.utf8ByteSequenceLength(trimmed[end]) catch 1;
        end += cp_len;
        codepoints += 1;
    }
    var out = std.mem.trim(u8, trimmed[0..@min(end, trimmed.len)], " \t\r\n");
    if (out.len == 0) return "Chat";
    if (codepoints >= 64 and end < trimmed.len) {
        if (std.mem.lastIndexOfScalar(u8, out, ' ')) |sp| {
            if (sp >= 12) out = std.mem.trim(u8, out[0..sp], " ");
        }
    }
    return out;
}

pub fn folderBasename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |idx| return trimmed[idx + 1 ..];
    return trimmed;
}

pub fn firstUserTitle(arena: Allocator, msgs: std.json.Array) []const u8 {
    for (msgs.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        if (!std.mem.eql(u8, role, "user")) continue;
        if (peer_context.isPeerInject(m)) continue;
        return titleFromPrompt(extractText(arena, m));
    }
    return "Chat";
}

pub fn setTerminalTitle(w: *Io.Writer, title: []const u8, folder: []const u8) void {
    if (!main_mod.use_color or main_mod.json_mode) return;
    const folder_name = folderBasename(folder);
    // OSC 0 is conventional xterm title; OSC 1/2 make iTerm/Ghostty-style tab
    // and window titles update too instead of leaving the launch command there.
    w.print("\x1b]0;{s} — {s}\x07\x1b]1;{s} — {s}\x07\x1b]2;{s} — {s}\x07", .{ title, folder_name, title, folder_name, title, folder_name }) catch return;
    w.flush() catch return;
}

pub fn printSessionHeader(w: *Io.Writer, title: []const u8, folder: []const u8) !void {
    _ = w;
    _ = title;
    _ = folder;
    // The › status line owns model · effort · ~/folder. Restating the ask
    // in a Codegraff box was vertical tax: the prompt is already on screen.
    if (main_mod.json_mode) return;
}

/// Extracts the reasoning/thinking text from one streamed SSE delta object for
/// the given provider wire format, or "" when this delta carries no reasoning.
/// deepseek/openai stream `reasoning_content`, anthropic a `thinking_delta`,
/// codex/responses a `response.reasoning_summary_text.delta`.
pub fn reasoningDelta(kind: Provider.Kind, obj: std.json.ObjectMap) []const u8 {
    return switch (kind) {
        // Gemini never streams reasoning PROSE — a thought step carries only an
        // opaque signature, so there is nothing to show in the thinking panel.
        .interactions => "",
        .anthropic => blk: {
            const d = obj.get("delta") orelse break :blk "";
            if (d != .object) break :blk "";
            const dt = d.object.get("type") orelse break :blk "";
            if (dt != .string or !std.mem.eql(u8, dt.string, "thinking_delta")) break :blk "";
            const x = d.object.get("thinking") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
        .openai => blk: {
            const choices = obj.get("choices") orelse break :blk "";
            if (choices != .array or choices.array.items.len == 0) break :blk "";
            const c0 = choices.array.items[0];
            if (c0 != .object) break :blk "";
            const d = c0.object.get("delta") orelse break :blk "";
            if (d != .object) break :blk "";
            const x = d.object.get("reasoning_content") orelse d.object.get("reasoning") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
        .responses => blk: {
            const t = obj.get("type") orelse break :blk "";
            if (t != .string or !std.mem.eql(u8, t.string, "response.reasoning_summary_text.delta")) break :blk "";
            const x = obj.get("delta") orelse break :blk "";
            break :blk if (x == .string) x.string else "";
        },
    };
}

/// Pulls the assistant's text out of a non-streamed completion response for the
/// given provider wire format — the shape both compaction and AI title naming
/// read back.
pub fn assistantText(kind: Provider.Kind, root: std.json.ObjectMap) []const u8 {
    return switch (kind) {
        .anthropic => blk: {
            const content = root.get("content") orelse break :blk "";
            if (content != .array) break :blk "";
            for (content.array.items) |block| {
                if (block != .object) continue;
                const bt = if (block.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, bt, "text"))
                    if (block.object.get("text")) |txt| if (txt == .string) break :blk txt.string;
            }
            break :blk "";
        },
        // Interactions returns execution steps; the answer is the text parts of
        // the model_output step (thought steps carry only an opaque signature).
        .interactions => blk: {
            const steps = root.get("steps") orelse break :blk "";
            if (steps != .array) break :blk "";
            for (steps.array.items) |step| {
                if (step != .object) continue;
                const st = if (step.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (!std.mem.eql(u8, st, "model_output")) continue;
                if (step.object.get("content")) |c| if (c == .array) {
                    for (c.array.items) |part| {
                        if (part != .object) continue;
                        if (part.object.get("text")) |txt| if (txt == .string) break :blk txt.string;
                    }
                };
            }
            break :blk "";
        },
        .openai => blk: {
            const choices = root.get("choices") orelse break :blk "";
            if (choices != .array or choices.array.items.len == 0) break :blk "";
            const c0 = choices.array.items[0];
            if (c0 != .object) break :blk "";
            const message = c0.object.get("message") orelse break :blk "";
            if (message != .object) break :blk "";
            const c = message.object.get("content") orelse break :blk "";
            break :blk if (c == .string) c.string else "";
        },
        .responses => blk: {
            const output = root.get("output") orelse break :blk "";
            if (output != .array) break :blk "";
            for (output.array.items) |item| {
                if (item != .object) continue;
                const it = if (item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (!std.mem.eql(u8, it, "message")) continue;
                if (item.object.get("content")) |c| if (c == .array) {
                    for (c.array.items) |b| {
                        if (b != .object) continue;
                        const bt = if (b.object.get("type")) |x| (if (x == .string) x.string else "") else "";
                        if (std.mem.eql(u8, bt, "output_text")) {
                            if (b.object.get("text")) |txt| if (txt == .string) break :blk txt.string;
                        }
                    }
                };
            }
            break :blk "";
        },
    };
}

/// Strips matched wrapping quotes/backticks (ASCII and curly), repeatedly, that a
/// model may add around a one-line title — `"'Fix bug'"` becomes `Fix bug`.
pub fn stripWrappingQuotes(s_in: []const u8) []const u8 {
    var s = s_in;
    const pairs = [_][2][]const u8{
        .{ "\"", "\"" },
        .{ "'", "'" },
        .{ "`", "`" },
        .{ "“", "”" },
        .{ "‘", "’" },
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (pairs) |p| {
            if (s.len >= p[0].len + p[1].len and std.mem.startsWith(u8, s, p[0]) and std.mem.endsWith(u8, s, p[1])) {
                s = std.mem.trim(u8, s[p[0].len .. s.len - p[1].len], " \t");
                changed = true;
            }
        }
    }
    return s;
}

/// Normalizes a model's raw reply into a tab-label title: first line only, drop a
/// leading "Title:" label and wrapping quotes, trim trailing sentence punctuation,
/// then cap to one line at a word boundary (via titleFromPrompt). Returns null
/// when nothing usable remains, so the caller keeps the mechanical title.
pub fn cleanTitle(raw: []const u8) ?[]const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.indexOfScalar(u8, s, '\n')) |nl| s = std.mem.trim(u8, s[0..nl], " \t\r");
    if (s.len >= 6 and std.ascii.eqlIgnoreCase(s[0..6], "title:")) s = std.mem.trim(u8, s[6..], " \t");
    s = stripWrappingQuotes(s);
    while (s.len > 0 and (s[s.len - 1] == '.' or s[s.len - 1] == '!' or s[s.len - 1] == '?')) s = s[0 .. s.len - 1];
    s = std.mem.trim(u8, s, " \t");
    if (s.len == 0) return null;
    return titleFromPrompt(s);
}
test "titleFromPrompt and folderBasename format TUI headers" {
    try std.testing.expectEqualStrings("Chat", titleFromPrompt(" \n\t "));
    try std.testing.expectEqualStrings("Refactor the auth middleware", titleFromPrompt("  Refactor the auth middleware\nwith tests"));
    try std.testing.expectEqualStrings("codegraff", folderBasename("/Users/example/src/codegraff"));
    try std.testing.expectEqualStrings("codegraff", folderBasename("/Users/example/src/codegraff/"));
}

test "reasoningDelta extracts thinking/reasoning per provider wire format (#75)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) std.json.ObjectMap {
            return (std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable).object;
        }
    }.p;

    // anthropic streams a thinking_delta inside content_block_delta
    const an = mk(a, "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"ponder\"}}");
    try std.testing.expectEqualStrings("ponder", reasoningDelta(.anthropic, an));
    // openai/deepseek stream reasoning_content (or reasoning) on choices[0].delta
    const oa = mk(a, "{\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}");
    try std.testing.expectEqualStrings("hmm", reasoningDelta(.openai, oa));
    // codex/responses stream a reasoning summary delta
    const re = mk(a, "{\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"plan\"}");
    try std.testing.expectEqualStrings("plan", reasoningDelta(.responses, re));
    // a plain answer-text delta carries no reasoning
    const txt = mk(a, "{\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}");
    try std.testing.expectEqualStrings("", reasoningDelta(.openai, txt));
}

test "firstUserTitle: first user message becomes the header title, else Chat (#83)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;

    var msgs = std.json.Array.init(a);
    try msgs.append(mk(a, "{\"role\":\"assistant\",\"content\":\"hi\"}"));
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"[peer] 1 unread from s-2 — peer_message action=inbox\"}"));
    try msgs.append(mk(a, "{\"role\":\"user\",\"content\":\"Fix the parser\\nmore detail\"}"));
    try std.testing.expectEqualStrings("Fix the parser", firstUserTitle(a, msgs));

    const empty = std.json.Array.init(a);
    try std.testing.expectEqualStrings("Chat", firstUserTitle(a, empty));
}

test "titleFromPrompt: truncates long prompts at a word boundary, UTF-8 intact (#83)" {
    const long = "Refactor the streaming parser and add tests for partial UTF-8 edge cases that panic";
    const t = titleFromPrompt(long);
    try std.testing.expect(t.len < long.len); // capped
    try std.testing.expect(std.mem.startsWith(u8, long, t)); // a clean prefix
    try std.testing.expect(t[t.len - 1] != ' '); // trailing space trimmed
    // a short multibyte prompt is returned whole, never split mid-codepoint
    try std.testing.expectEqualStrings("héllo wörld", titleFromPrompt("héllo wörld"));
}

test "printSessionHeader is silent; the ask is not restated (#83)" {
    const saved = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved;

    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printSessionHeader(&aw.writer, "Fix the bug", "/tmp/proj");
    const s = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expect(std.mem.indexOf(u8, s, "Working on:") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Fix the bug") == null);

    // JSON mode emits nothing (the header would corrupt the event stream).
    main_mod.json_mode = true;
    var jw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer jw.deinit();
    try printSessionHeader(&jw.writer, "x", "/y");
    try std.testing.expectEqual(@as(usize, 0), jw.writer.buffered().len);
}

test "setTerminalTitle emits OSC title with folder basename, gated by color/json (#83)" {
    const sc = main_mod.use_color;
    const sj = main_mod.json_mode;
    defer {
        main_mod.use_color = sc;
        main_mod.json_mode = sj;
    }

    main_mod.use_color = true;
    main_mod.json_mode = false;
    var on: Io.Writer.Allocating = .init(std.testing.allocator);
    defer on.deinit();
    setTerminalTitle(&on.writer, "Add dark mode", "/a/b/myproj");
    const s = on.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "Add dark mode — myproj") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b]0;") != null); // window title
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b]2;") != null); // tab title

    // Gated off in JSON mode (would corrupt the stream) and when color is off.
    main_mod.json_mode = true;
    var off: Io.Writer.Allocating = .init(std.testing.allocator);
    defer off.deinit();
    setTerminalTitle(&off.writer, "x", "/y");
    try std.testing.expectEqual(@as(usize, 0), off.writer.buffered().len);
}

test "cleanTitle: normalizes a model reply into a tab label, else null (/title)" {
    // plain title passes through (capped/word-boundaried by titleFromPrompt)
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("Fix The Parser").?);
    // wrapping quotes, a leading label, and trailing punctuation are stripped
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("  \"Fix The Parser\"  ").?);
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("Title: Fix The Parser.").?);
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("'`Fix The Parser`'").?);
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("“Fix The Parser”").?);
    // only the first line is used
    try std.testing.expectEqualStrings("Fix The Parser", cleanTitle("Fix The Parser\nsome rambling").?);
    // nothing usable → null so the caller keeps the mechanical titleFromPrompt label
    try std.testing.expect(cleanTitle("   ") == null);
    try std.testing.expect(cleanTitle("\"\"") == null);
}

/// Generate a terse tab-label title for the turn's first prompt — runs on its
/// own arena + a throwaway one-message sub-Agent, so it can be spawned via
/// io.async and overlap the real turn instead of blocking after it. Returns a
/// gpa-owned title (caller frees), or null on any failure. Uses the session
/// provider as-is (same model and wire as the turn).
pub fn titleTask(gpa: std.mem.Allocator, io: Io, client: *std.http.Client, provider: Provider, prompt: []const u8, run_budget: ?*@import("run_budget.zig").RunBudget, tracer: ?*@import("trace.zig").Tracer) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = client,
        .provider = provider,
        .messages = std.json.Array.init(arena),
        .sub = true, // pool thread: never touches stdout or the main agent's state
        .label = "title",
        .out = null,
        .tracer = tracer,
        .run_budget = run_budget,
        .call_kind = .title,
        .responses_output_limit = 64,
        .sys_override = "You summarize what a coding session is about in a short, natural phrase. Reply with only the phrase.",
    };
    defer agent.tools_used.deinit(gpa);
    const instr = std.fmt.allocPrint(arena, "In a short natural phrase (about 3-8 words, sentence case, no quotes, no period), say what the user is working on — e.g. 'defining what a dragon is', 'fixing the login bug', 'planning the release'. Reply with ONLY the phrase.\n\nTask:\n{s}", .{prompt}) catch return null;
    agent.messages.append(textMessage(arena, "user", instr) catch return null) catch return null;
    const root = agent.request(null) catch return null;
    const cleaned = cleanTitle(assistantText(provider.kind, root)) orelse return null;
    return gpa.dupe(u8, cleaned) catch null;
}
