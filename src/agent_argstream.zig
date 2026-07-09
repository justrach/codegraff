//! Live streaming of `attempt_completion`/`ask_user` tool-argument prose:
//! a byte-at-a-time JSON scanner (ArgLive) that finds the target string
//! field inside the still-in-flight tool-call arguments and prints it as
//! it arrives, so strict mode (where the whole answer is a tool call)
//! doesn't look frozen until the call completes. Split out of the Agent
//! struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const Agent = main_mod.Agent;
const ToolCall = main_mod.ToolCall;

// sseIndex lives in agent_stream.zig; reached through the Agent struct's
// member alias.
const sseIndex = Agent.sseIndex;

pub const ArgTool = enum { none, attempt_completion, ask_user };

pub fn argToolFor(name: []const u8) ArgTool {
    if (std.mem.eql(u8, name, "attempt_completion")) return .attempt_completion;
    if (std.mem.eql(u8, name, "ask_user")) return .ask_user;
    return .none;
}

pub fn argField(tool: ArgTool) []const u8 {
    return switch (tool) {
        .attempt_completion => "result",
        .ask_user => "question",
        .none => "",
    };
}

/// Live tool-argument text. attempt_completion and ask_user carry their
/// user-facing prose inside tool-call argument JSON, which the text-delta
/// matching in printDelta can't see — in strict mode that's the *whole*
/// answer, so the turn looked frozen while it streamed, then dumped at
/// once. This is a byte-at-a-time scanner over the argument fragments:
/// skip to the target string field at the top level of the args object
/// ("result" / "question"), then unescape its value and print it as it
/// arrives. Best-effort mirror of the real parse that follows the stream
/// — a glitch here is cosmetic, never semantic.
pub const ArgLive = struct {
    tool: ArgTool = .none, // which whitelisted call is open
    index: i64 = -1, // the provider's stream index for that call
    state: State = .seek_key,
    depth: u32 = 0, // container nesting while skipping a non-target value
    in_str: bool = false, // inside a skipped string
    esc: bool = false, // previous byte was '\'
    uni_left: u8 = 0, // hex digits still expected in a \uXXXX escape
    uni_val: u16 = 0,
    hi_sur: u16 = 0, // pending UTF-16 high surrogate (0 = none)
    key: [24]u8 = undefined,
    key_len: usize = 0,
    key_over: bool = false, // key overflowed/escaped — cannot be the target

    const State = enum { seek_key, key, post_key, pre_val, skip_val, val, done };

    pub fn open(self: *ArgLive, name: []const u8, ix: i64) void {
        const tool = argToolFor(name);
        if (tool == .none) return;
        self.* = .{ .tool = tool, .index = ix };
    }

    fn close(self: *ArgLive, ix: i64) void {
        if (ix == self.index) self.* = .{};
    }

    pub fn feed(self: *ArgLive, agent: *Agent, ix: i64, frag: []const u8) void {
        if (self.tool == .none or ix != self.index or self.state == .done) return;
        var out_buf: [512]u8 = undefined;
        var out_len: usize = 0;
        for (frag) |c| {
            if (out_len > out_buf.len - 8) { // keep room for one decoded escape
                agent.emitArgText(self.tool, out_buf[0..out_len]);
                out_len = 0;
            }
            switch (self.state) {
                .done => break,
                .seek_key => switch (c) {
                    '"' => {
                        self.state = .key;
                        self.key_len = 0;
                        self.key_over = false;
                    },
                    '}' => self.state = .done,
                    else => {}, // '{', ',', whitespace
                },
                .key => if (self.esc) {
                    self.esc = false;
                    self.key_over = true; // escaped keys never match the plain target
                } else switch (c) {
                    '\\' => self.esc = true,
                    '"' => self.state = .post_key,
                    else => if (self.key_len < self.key.len) {
                        self.key[self.key_len] = c;
                        self.key_len += 1;
                    } else {
                        self.key_over = true;
                    },
                },
                .post_key => if (c == ':') {
                    self.state = .pre_val;
                },
                .pre_val => switch (c) {
                    ' ', '\t', '\r', '\n' => {},
                    '"' => if (!self.key_over and std.mem.eql(u8, self.key[0..self.key_len], argField(self.tool))) {
                        self.state = .val;
                    } else {
                        self.state = .skip_val;
                        self.in_str = true;
                        self.depth = 0;
                    },
                    '{', '[' => {
                        self.state = .skip_val;
                        self.in_str = false;
                        self.depth = 1;
                    },
                    else => { // number / true / false / null
                        self.state = .skip_val;
                        self.in_str = false;
                        self.depth = 0;
                    },
                },
                .skip_val => if (self.in_str) {
                    if (self.esc) {
                        self.esc = false;
                    } else if (c == '\\') {
                        self.esc = true;
                    } else if (c == '"') {
                        self.in_str = false;
                        if (self.depth == 0) self.state = .seek_key;
                    }
                } else switch (c) {
                    '"' => self.in_str = true,
                    '{', '[' => self.depth += 1,
                    ']' => {
                        if (self.depth > 0) self.depth -= 1;
                        if (self.depth == 0) self.state = .seek_key;
                    },
                    '}' => if (self.depth == 0) {
                        self.state = .done; // end of the args object
                    } else {
                        self.depth -= 1;
                        if (self.depth == 0) self.state = .seek_key;
                    },
                    ',' => if (self.depth == 0) {
                        self.state = .seek_key;
                    },
                    else => {},
                },
                .val => {
                    if (self.uni_left > 0) {
                        const d = std.fmt.charToDigit(c, 16) catch {
                            self.uni_left = 0; // malformed escape: drop it
                            continue;
                        };
                        self.uni_val = self.uni_val * 16 + d;
                        self.uni_left -= 1;
                        if (self.uni_left == 0) out_len += self.takeUnit(out_buf[out_len..]);
                        continue;
                    }
                    if (self.esc) {
                        self.esc = false;
                        switch (c) {
                            'n' => out_len += self.put(out_buf[out_len..], '\n'),
                            't' => out_len += self.put(out_buf[out_len..], '\t'),
                            'r' => out_len += self.put(out_buf[out_len..], '\r'),
                            'b' => out_len += self.put(out_buf[out_len..], 0x08),
                            'f' => out_len += self.put(out_buf[out_len..], 0x0c),
                            'u' => {
                                self.uni_left = 4;
                                self.uni_val = 0;
                            },
                            else => out_len += self.put(out_buf[out_len..], c), // " \ /
                        }
                    } else switch (c) {
                        '\\' => self.esc = true,
                        '"' => self.state = .done, // value captured — nothing else prints
                        else => out_len += self.put(out_buf[out_len..], c),
                    }
                },
            }
        }
        if (out_len > 0) agent.emitArgText(self.tool, out_buf[0..out_len]);
    }

    /// Emit one literal byte, flushing any orphaned high surrogate first.
    fn put(self: *ArgLive, buf: []u8, c: u8) usize {
        var n: usize = 0;
        if (self.hi_sur != 0) {
            n = replacement(buf);
            self.hi_sur = 0;
        }
        buf[n] = c;
        return n + 1;
    }

    /// A completed \uXXXX code unit: pair surrogates, emit UTF-8.
    fn takeUnit(self: *ArgLive, buf: []u8) usize {
        const u = self.uni_val;
        self.uni_val = 0;
        if (u >= 0xD800 and u <= 0xDBFF) { // high surrogate: hold for its pair
            var n: usize = 0;
            if (self.hi_sur != 0) n = replacement(buf); // two highs in a row
            self.hi_sur = u;
            return n;
        }
        var cp: u21 = u;
        var n: usize = 0;
        if (u >= 0xDC00 and u <= 0xDFFF) { // low surrogate
            if (self.hi_sur == 0) return replacement(buf); // unpaired
            cp = 0x10000 + (@as(u21, self.hi_sur - 0xD800) << 10) + (u - 0xDC00);
            self.hi_sur = 0;
        } else if (self.hi_sur != 0) {
            n = replacement(buf); // high surrogate not followed by a low
            self.hi_sur = 0;
        }
        n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
        return n;
    }

    fn replacement(buf: []u8) usize {
        @memcpy(buf[0..3], "\u{FFFD}");
        return 3;
    }
};

pub fn outputIndex(obj: std.json.ObjectMap) ?i64 {
    const ix = obj.get("output_index") orelse return null;
    return if (ix == .integer) ix.integer else null;
}

/// Track tool-call open/delta/close events in the SSE stream and feed
/// attempt_completion / ask_user argument fragments to the ArgLive
/// extractor for live printing. Root interactive streams only — SDK
/// (--json) clients get the assembled tool_call event instead.
pub fn argLiveDelta(self: *Agent, obj: std.json.ObjectMap) void {
    if (self.sub or main_mod.json_mode or self.stream_quiet) return;
    switch (self.provider.kind) {
        .anthropic => {
            const t = obj.get("type") orelse return;
            if (t != .string) return;
            if (std.mem.eql(u8, t.string, "content_block_start")) {
                const ix = sseIndex(obj) orelse return;
                const cb = obj.get("content_block") orelse return;
                if (cb != .object) return;
                const bt = cb.object.get("type") orelse return;
                if (bt != .string or !std.mem.eql(u8, bt.string, "tool_use")) return;
                const name = cb.object.get("name") orelse return;
                if (name == .string) self.arg_live.open(name.string, @intCast(ix));
            } else if (std.mem.eql(u8, t.string, "content_block_delta")) {
                const ix = sseIndex(obj) orelse return;
                const d = obj.get("delta") orelse return;
                if (d != .object) return;
                const dt = d.object.get("type") orelse return;
                if (dt != .string or !std.mem.eql(u8, dt.string, "input_json_delta")) return;
                const pj = d.object.get("partial_json") orelse return;
                if (pj == .string) self.arg_live.feed(self, @intCast(ix), pj.string);
            } else if (std.mem.eql(u8, t.string, "content_block_stop")) {
                const ix = sseIndex(obj) orelse return;
                self.arg_live.close(@intCast(ix));
            }
        },
        .openai => {
            const choices = obj.get("choices") orelse return;
            if (choices != .array or choices.array.items.len == 0) return;
            const c0 = choices.array.items[0];
            if (c0 != .object) return;
            const d = c0.object.get("delta") orelse return;
            if (d != .object) return;
            const tcs = d.object.get("tool_calls") orelse return;
            if (tcs != .array) return;
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const ix: i64 = if (tc.object.get("index")) |iv|
                    (if (iv == .integer) iv.integer else 0)
                else
                    0;
                const f = tc.object.get("function") orelse continue;
                if (f != .object) continue;
                if (f.object.get("name")) |n| if (n == .string and n.string.len > 0)
                    self.arg_live.open(n.string, ix);
                if (f.object.get("arguments")) |a| if (a == .string)
                    self.arg_live.feed(self, ix, a.string);
            }
        },
        .responses => {
            const t = obj.get("type") orelse return;
            if (t != .string) return;
            if (std.mem.eql(u8, t.string, "response.output_item.added")) {
                const ix = outputIndex(obj) orelse return;
                const item = obj.get("item") orelse return;
                if (item != .object) return;
                const it = item.object.get("type") orelse return;
                if (it != .string or !std.mem.eql(u8, it.string, "function_call")) return;
                const name = item.object.get("name") orelse return;
                if (name == .string) self.arg_live.open(name.string, ix);
            } else if (std.mem.eql(u8, t.string, "response.function_call_arguments.delta")) {
                const ix = outputIndex(obj) orelse return;
                const dl = obj.get("delta") orelse return;
                if (dl == .string) self.arg_live.feed(self, ix, dl.string);
            } else if (std.mem.eql(u8, t.string, "response.output_item.done")) {
                const ix = outputIndex(obj) orelse return;
                self.arg_live.close(ix);
            }
        },
    }
}

/// Print live tool-argument text exactly like a text delta: clears the
/// spinner, lands in the Esc-interrupt capture, and records which meta
/// tool already showed its prose so handleMeta / sayToolUse don't repeat
/// it after the call completes.
pub fn emitArgText(self: *Agent, tool: ArgTool, text: []const u8) void {
    const w = self.out orelse return;
    if (text.len == 0) return;
    self.spinnerStop(); // first visible byte: clear the thinking line
    self.streamed_text = true;
    if (self.streamed_args != tool) self.streamed_args_len = 0;
    self.streamed_args = tool;
    self.streamed_args_len += text.len;
    self.partial_text.appendSlice(self.arena, text) catch {};
    if (main_mod.use_color) {
        self.streamMarkdown(text);
    } else {
        w.writeAll(text) catch return;
        w.flush() catch return;
    }
}

/// True iff this meta call's prose already streamed live *in full*: the
/// bytes ArgLive emitted match the parsed field exactly. Only then may
/// the authoritative re-print be suppressed — a scanner glitch must cost
/// duplication, never content.
pub fn argStreamedFully(self: *Agent, call: ToolCall) bool {
    const at = argToolFor(call.name);
    if (at == .none or at != self.streamed_args) return false;
    const v = call.input.object.get(argField(at)) orelse return false;
    return v == .string and v.string.len == self.streamed_args_len;
}

test "ArgLive streams the target argument field across fragment splits" {
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
    defer a.partial_text.deinit(std.testing.allocator);

    // attempt_completion: the result value streams as it arrives, with
    // escapes (split across fragments) unescaped.
    a.arg_live.open("attempt_completion", 0);
    a.arg_live.feed(&a, 0, "{\"res");
    a.arg_live.feed(&a, 0, "ult\": \"Hello ");
    try std.testing.expectEqualStrings("Hello ", aw.writer.buffered());
    a.arg_live.feed(&a, 0, "line\\");
    a.arg_live.feed(&a, 0, "nnext \\\"q\\\"");
    try std.testing.expectEqualStrings("Hello line\nnext \"q\"", aw.writer.buffered());
    a.arg_live.feed(&a, 0, "\"}");
    try std.testing.expectEqualStrings("Hello line\nnext \"q\"", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .attempt_completion);
    // The emitted byte count matches the parsed value — re-print suppressible.
    try std.testing.expectEqual("Hello line\nnext \"q\"".len, a.streamed_args_len);
    aw.clearRetainingCapacity();

    // ask_user: a non-target field first (options array with tricky strings)
    // is skipped; the question prints. \u escapes decode, surrogate pairs too.
    a.streamed_args = .none;
    a.arg_live.open("ask_user", 2);
    a.arg_live.feed(&a, 2, "{\"options\": [\"a \\\"x\\\"\", \"b, {c}\"], ");
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    a.arg_live.feed(&a, 2, "\"question\": \"caf\\u00e9 \\ud83d\\ude00?\"}");
    try std.testing.expectEqualStrings("café 😀?", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .ask_user);
    try std.testing.expectEqual("café 😀?".len, a.streamed_args_len);
    aw.clearRetainingCapacity();

    // Wrong index and non-whitelisted tools print nothing.
    a.streamed_args = .none;
    a.arg_live.feed(&a, 5, "{\"question\": \"nope\"}");
    a.arg_live.open("bash", 3);
    a.arg_live.feed(&a, 3, "{\"result\": \"nope\"}");
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    try std.testing.expect(a.streamed_args == .none);
}
