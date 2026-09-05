//! Live streaming of `attempt_completion`/`ask_user` tool-argument prose:
//! a byte-at-a-time JSON scanner (ArgLive) that finds the target string
//! field inside the still-in-flight tool-call arguments and streams it out
//! as typed events (#422) as it arrives, so strict mode (where the whole
//! answer is a tool call) doesn't look frozen until the call completes.
//! Split out of the Agent struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const engine_sink = @import("engine_sink.zig"); // #422: emissions go through the sink
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const rlm_spec = @import("rlm_spec.zig");

// sseIndex lives in agent_stream.zig; reached through the Agent struct's
// member alias.
const sseIndex = Agent.sseIndex;

pub const ArgTool = enum { none, attempt_completion, ask_user, rlm };

pub fn argToolFor(name: []const u8) ArgTool {
    if (std.mem.eql(u8, name, "attempt_completion")) return .attempt_completion;
    if (std.mem.eql(u8, name, "ask_user")) return .ask_user;
    if (std.mem.eql(u8, name, "rlm")) return .rlm;
    return .none;
}

pub fn argField(tool: ArgTool) []const u8 {
    return switch (tool) {
        .attempt_completion => "result",
        .ask_user => "question",
        .rlm => "code",
        .none => "",
    };
}

fn toolCtx(self: *Agent) tools_mod.ToolCtx {
    return .{
        .gpa = self.gpa,
        .io = self.io,
        .client = self.client,
        .provider = self.provider,
        .subagent_provider = self.subagent_provider,
        .subagent_cross_provider = self.subagent_cross_provider,
        .registry = if (self.sub) null else self.registry,
        .from_sub = self.sub,
        .has_eval = self.eval_cmd != null,
        .approvals = self.approvals,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .depth = self.depth,
        .snapshots = self.snapshots,
        .tools_used = &self.tools_used,
        .loop_deadline_ms = self.loop_deadline_ms,
        .agent_cwd = self.agent_cwd,
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
    if (self.sub) return;
    const ui = !main_mod.json_mode and !self.stream_quiet;
    if (!ui and !rlm_spec.available) return;
    switch (self.provider.kind) {
        // Interactions streams arguments as `arguments_delta` chunks keyed by
        // step index rather than the per-wire shapes this extractor models.
        // The live argument preview is simply not rendered there; the call is
        // still dispatched in full from the assembled step.
        .interactions => return,
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
                if (name == .string) openLive(self, name.string, @intCast(ix));
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
                    openLive(self, n.string, ix);
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
                if (name == .string) openLive(self, name.string, ix);
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

/// Live tool-argument text (#422 slice 1b): the engine-side bookkeeping —
/// the Esc-interrupt capture, and which meta tool already showed its prose
/// so handleMeta / sayToolUse don't repeat it after the call completes —
/// stays here; the bytes leave as a typed event. TuiSink renders them
/// exactly like a text delta (spinner handoff included); the --json wire
/// never carried these moments (argLiveDelta gates --json off), so JsonSink
/// stays silent.
fn openLive(self: *Agent, name: []const u8, ix: i64) void {
    if (argToolFor(name) == .rlm) rlm_spec.resetLive(self.gpa, self.io);
    self.arg_live.open(name, ix);
}

pub fn emitArgText(self: *Agent, tool: ArgTool, text: []const u8) void {
    if (text.len > 0) self.traceFirstToken();
    if (tool == .rlm) {
        if (rlm_spec.available and text.len > 0) rlm_spec.feedLive(toolCtx(self), text);
        return;
    }
    if (self.out == null) return; // frontendless agents skip capture too, as ever
    if (text.len == 0) return;
    self.streamed_text = true;
    if (self.streamed_args != tool) self.streamed_args_len = 0;
    self.streamed_args = tool;
    self.streamed_args_len += text.len;
    self.partial_text.appendSlice(self.arena, text) catch {};
    engine_sink.forAgent(self).emit(self.io, .{ .tool_arg_delta = .{ .text = text } });
}

/// True iff this meta call's prose already streamed live *in full*: the
/// bytes ArgLive emitted match the parsed field exactly. Only then may
/// the authoritative re-print be suppressed — a scanner glitch must cost
/// duplication, never content.
pub fn argStreamedFully(self: *Agent, call: ToolCall) bool {
    const at = argToolFor(call.name);
    if (at == .none or at != self.streamed_args) return false;
    // `call.input` is model-supplied: a non-object here is undefined behavior in
    // a ReleaseFast build, not a panic. This sits one line above the gate that
    // fix B2 added, so it was the last unguarded deref on that path.
    if (call.input != .object) return false;
    const v = call.input.object.get(argField(at)) orelse return false;
    return v == .string and v.string.len == self.streamed_args_len;
}

test "argStreamedFully: a non-object tool input is refused, not dereferenced" {
    var a: Agent = undefined;
    a.streamed_args = .attempt_completion;
    a.streamed_args_len = 3;
    // Exactly what a malformed tool call delivers: the arguments are a bare
    // string (or null, or a number), never the object the schema promised.
    for ([_]std.json.Value{ .{ .string = "abc" }, .null, .{ .integer = 1 } }) |bad|
        try std.testing.expect(!argStreamedFully(&a, .{ .id = "1", .name = "attempt_completion", .input = bad }));
}

test "ArgLive streams the target argument field across fragment splits" {
    // Pin the frontend the emitted events resolve to (#422 slice 1b): the
    // bytes below are TuiSink's no-color rendering of .tool_arg_delta.
    const saved_json = main_mod.json_mode;
    const saved_color = main_mod.use_color;
    main_mod.json_mode = false;
    main_mod.use_color = false;
    defer {
        main_mod.json_mode = saved_json;
        main_mod.use_color = saved_color;
    }
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

test "argToolFor: structured tools stay none; only rlm is mid-stream speculated" {
    try std.testing.expectEqual(ArgTool.none, argToolFor("subagent"));
    try std.testing.expectEqual(ArgTool.none, argToolFor("workflow"));
    try std.testing.expectEqual(ArgTool.none, argToolFor("bash"));
    try std.testing.expectEqual(ArgTool.none, argToolFor("agent_output"));
    try std.testing.expectEqual(ArgTool.none, argToolFor("codedb"));
    try std.testing.expectEqual(ArgTool.rlm, argToolFor("rlm"));
    try std.testing.expectEqual(ArgTool.attempt_completion, argToolFor("attempt_completion"));
    try std.testing.expectEqual(ArgTool.ask_user, argToolFor("ask_user"));

    var live: ArgLive = .{};
    live.open("subagent", 0);
    try std.testing.expectEqual(ArgTool.none, live.tool);
    live.open("workflow", 1);
    try std.testing.expectEqual(ArgTool.none, live.tool);
    live.open("rlm", 2);
    try std.testing.expectEqual(ArgTool.rlm, live.tool);
    try std.testing.expectEqualStrings("code", argField(.rlm));
}

test "emitArgText feeds live only for rlm, even when available is the default" {
    const spec_ptc = @import("spec_ptc.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved_avail = rlm_spec.available;
    const saved_host = rlm_spec.run_host;
    defer {
        rlm_spec.available = saved_avail;
        rlm_spec.run_host = saved_host;
        rlm_spec.resetLive(gpa, io);
    }
    rlm_spec.available = true;
    rlm_spec.run_host = struct {
        fn host(ctx: tools_mod.ToolCtx, call: spec_ptc.Call) tools_mod.ToolOutput {
            _ = call;
            return .{ .text = ctx.gpa.dupe(u8, "launched") catch &.{}, .is_error = false };
        }
    }.host;

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var a: Agent = .{
        .gpa = gpa,
        .arena = gpa,
        .io = io,
        .client = &dummy_client,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
    };
    defer a.partial_text.deinit(gpa);

    emitArgText(&a, .attempt_completion, "a = sleep_ms(1)\n");
    a.arg_live.open("subagent", 0);
    a.arg_live.feed(&a, 0, "{\"prompt\":\"a = sleep_ms(1)\\n\"}");
    const ctx = toolCtx(&a);
    var claimed = std.StringHashMap(tools_mod.ToolOutput).init(gpa);
    defer {
        var it = claimed.iterator();
        while (it.next()) |e| gpa.free(e.value_ptr.text);
        claimed.deinit();
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    rlm_spec.takeLive(ctx, &claimed, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 0), claimed.count());

    emitArgText(&a, .rlm, "a = sleep_ms(1)\n");
    rlm_spec.takeLive(ctx, &claimed, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), claimed.count());
    const hit = claimed.get("sleep_ms\n{\"ms\":1}").?;
    try std.testing.expectEqualStrings("launched", hit.text);
}
