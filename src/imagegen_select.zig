//! #352: which imagegen engine a call gets, and what to say when it gets none.
//!
//! Pure over three booleans and the caller's request, so the whole matrix is a
//! table test rather than something you can only find out by spawning codex.
//!
//! The one non-obvious rule: `model`, `quality`, `background` and
//! `output_format` only exist on the openai_api engine — the hosted image_gen
//! tool exposes none of them. Silently ignoring them on the codex engine would
//! be the same class of dishonesty this whole tool exists to prevent (the
//! caller asks for a transparent background, gets an opaque one, and is told it
//! succeeded), so setting one STEERS `auto` to the engine that can honour it,
//! and is a hard error when that engine is unavailable or was ruled out
//! explicitly. `size` is not in that list: graff can deliver it on either
//! engine, resizing the codex result itself.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Engine = enum { codex, openai_api };

/// Parameters only the openai_api engine can apply.
pub const tuned_params = [_][]const u8{ "model", "quality", "background", "output_format" };

pub const Reason = enum {
    /// Neither engine is usable on this machine.
    no_engine,
    /// engine:"codex" but no codex CLI + login.
    codex_unavailable,
    /// engine:"openai_api" but no OPENAI_API_KEY (or no script).
    api_unavailable,
    /// A tuned param was set, and the only engine that could apply it is not
    /// available.
    tuned_needs_api,
    /// engine:"codex" was explicit AND a tuned param was set — the two cannot
    /// both be honoured, and dropping one silently is not an option.
    tuned_not_on_codex,
};

pub const Choice = union(enum) { use: Engine, refuse: Reason };

pub fn parseEngine(name: []const u8) ?Engine {
    if (std.ascii.eqlIgnoreCase(name, "auto")) return null; // absent == auto
    if (std.ascii.eqlIgnoreCase(name, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(name, "openai_api")) return .openai_api;
    return null;
}

/// `parseEngine` returns null for both "auto" and garbage, so callers that must
/// tell them apart ask this first.
pub fn knownEngineName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "auto") or parseEngine(name) != null;
}

/// The first openai_api-only parameter present in the call, if any.
pub fn firstTunedParam(input: Value) ?[]const u8 {
    if (input != .object) return null;
    for (tuned_params) |name| {
        const v = input.object.get(name) orelse continue;
        if (v == .string and v.string.len > 0) return name;
    }
    return null;
}

pub fn choose(requested: ?Engine, codex_ok: bool, api_ok: bool, tuned: bool) Choice {
    if (requested) |want| return switch (want) {
        .codex => if (tuned)
            .{ .refuse = .tuned_not_on_codex }
        else if (codex_ok)
            .{ .use = .codex }
        else
            .{ .refuse = .codex_unavailable },
        .openai_api => if (api_ok) .{ .use = .openai_api } else .{ .refuse = .api_unavailable },
    };
    // auto
    if (tuned) {
        if (api_ok) return .{ .use = .openai_api };
        return .{ .refuse = if (codex_ok) .tuned_needs_api else .no_engine };
    }
    if (codex_ok) return .{ .use = .codex };
    if (api_ok) return .{ .use = .openai_api };
    return .{ .refuse = .no_engine };
}

/// The tool is not even installed — the gate should have kept us out of here.
pub const no_skill_text = "imagegen is not available in this session: graff did not find the Codex imagegen skill at $CODEX_HOME/skills/.system/imagegen (CODEX_HOME defaults to ~/.codex), and both of this tool's engines come from it. Install the Codex imagegen skill and restart graff. Do not substitute an existing file for a generated one.";

const nothing_generated = "NOTHING was generated — do not report an image, and do not pass off an existing file as one.";

pub fn refusalText(gpa: Allocator, reason: Reason, tuned: ?[]const u8) ![]u8 {
    return switch (reason) {
        .no_engine => std.fmt.allocPrint(gpa,
            \\imagegen has no usable engine in this session, so it did not run anything. It needs ONE of:
            \\  - a logged-in codex CLI (preferred, no API key): install it with `bun install -g @openai/codex`, then `codex login`. graff checks for a codex binary on PATH and $CODEX_HOME/auth.json.
            \\  - OPENAI_API_KEY exported in graff's environment, for the imagegen skill's scripts/image_gen.py fallback. graff reads it at startup, so export it and restart graff.
            \\The hosted codex image_gen tool is server-side and cannot be reached any other way (issue #352). {s}
        , .{nothing_generated}),
        .codex_unavailable => std.fmt.allocPrint(gpa,
            \\engine "codex" was requested, but this machine has no usable codex CLI: graff needs a `codex` binary on PATH AND $CODEX_HOME/auth.json (run `codex login`). Install it with `bun install -g @openai/codex`, or drop the engine argument to let graff pick, or pass engine "openai_api" if OPENAI_API_KEY is set. {s}
        , .{nothing_generated}),
        .api_unavailable => std.fmt.allocPrint(gpa,
            \\engine "openai_api" was requested, but OPENAI_API_KEY was not set in graff's environment when this session started (or the imagegen skill's scripts/image_gen.py is missing). Export the key and restart graff, or drop the engine argument to use the codex engine, which needs no API key. {s}
        , .{nothing_generated}),
        .tuned_needs_api => std.fmt.allocPrint(gpa,
            \\'{s}' is only supported by the openai_api engine, and OPENAI_API_KEY was not set when this session started. The codex engine is available but drives the hosted image_gen tool, which has no {s} option — graff will not quietly ignore it and call the result a success. Either export OPENAI_API_KEY and restart graff, or drop {s} (and any other of model/quality/background/output_format) and call again to use the codex engine. {s}
        , .{ tuned orelse "that option", tuned orelse "that", tuned orelse "it", nothing_generated }),
        .tuned_not_on_codex => std.fmt.allocPrint(gpa,
            \\engine "codex" was requested together with '{s}', which only the openai_api engine supports — the hosted image_gen tool has no such option, and graff will not ignore it and report success anyway. Drop {s} (and any other of model/quality/background/output_format) to use the codex engine, or pass engine "openai_api" with OPENAI_API_KEY set. size is fine on either engine. {s}
        , .{ tuned orelse "that option", tuned orelse "it", nothing_generated }),
    };
}

const testing = std.testing;

test "#352: engine names parse, and auto is not a garbage name" {
    try testing.expectEqual(Engine.codex, parseEngine("codex").?);
    try testing.expectEqual(Engine.openai_api, parseEngine("OPENAI_API").?);
    try testing.expect(parseEngine("auto") == null);
    try testing.expect(parseEngine("dall-e") == null);
    try testing.expect(knownEngineName("auto") and knownEngineName("codex"));
    try testing.expect(!knownEngineName("dall-e"));
}

test "#352: the full engine-selection matrix" {
    // auto, no tuned params: codex wins whenever it is there.
    try testing.expectEqual(Choice{ .use = .codex }, choose(null, true, true, false));
    try testing.expectEqual(Choice{ .use = .codex }, choose(null, true, false, false));
    try testing.expectEqual(Choice{ .use = .openai_api }, choose(null, false, true, false));
    try testing.expectEqual(Choice{ .refuse = .no_engine }, choose(null, false, false, false));

    // auto + a tuned param: steer to the only engine that can apply it.
    try testing.expectEqual(Choice{ .use = .openai_api }, choose(null, true, true, true));
    try testing.expectEqual(Choice{ .use = .openai_api }, choose(null, false, true, true));
    try testing.expectEqual(Choice{ .refuse = .tuned_needs_api }, choose(null, true, false, true));
    try testing.expectEqual(Choice{ .refuse = .no_engine }, choose(null, false, false, true));

    // explicit codex
    try testing.expectEqual(Choice{ .use = .codex }, choose(.codex, true, true, false));
    try testing.expectEqual(Choice{ .refuse = .codex_unavailable }, choose(.codex, false, true, false));
    try testing.expectEqual(Choice{ .refuse = .tuned_not_on_codex }, choose(.codex, true, true, true));

    // explicit openai_api
    try testing.expectEqual(Choice{ .use = .openai_api }, choose(.openai_api, true, true, false));
    try testing.expectEqual(Choice{ .use = .openai_api }, choose(.openai_api, false, true, true));
    try testing.expectEqual(Choice{ .refuse = .api_unavailable }, choose(.openai_api, true, false, false));
}

test "#352: tuned params are detected by name, and size is deliberately not one" {
    const gpa = testing.allocator;
    const cases = [_]struct { json: []const u8, want: ?[]const u8 }{
        .{ .json = "{\"prompt\":\"p\"}", .want = null },
        .{ .json = "{\"prompt\":\"p\",\"size\":\"1024x1024\"}", .want = null }, // graff resizes, so size works everywhere
        .{ .json = "{\"prompt\":\"p\",\"out\":\"a.png\",\"engine\":\"codex\"}", .want = null },
        .{ .json = "{\"prompt\":\"p\",\"background\":\"transparent\"}", .want = "background" },
        .{ .json = "{\"prompt\":\"p\",\"model\":\"gpt-image-1.5\"}", .want = "model" },
        .{ .json = "{\"prompt\":\"p\",\"output_format\":\"webp\"}", .want = "output_format" },
        .{ .json = "{\"prompt\":\"p\",\"quality\":\"\"}", .want = null }, // empty is not a request
    };
    for (cases) |c| {
        var parsed = try std.json.parseFromSlice(Value, gpa, c.json, .{});
        defer parsed.deinit();
        const got = firstTunedParam(parsed.value);
        if (c.want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }
}

test "#352: every refusal names what to install or export, and says nothing was generated" {
    const gpa = testing.allocator;
    for ([_]Reason{ .no_engine, .codex_unavailable, .api_unavailable, .tuned_needs_api, .tuned_not_on_codex }) |reason| {
        const text = try refusalText(gpa, reason, "background");
        defer gpa.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "NOTHING was generated") != null);
        try testing.expect(text.len > 120);
    }
    const none = try refusalText(gpa, .no_engine, null);
    defer gpa.free(none);
    // The both-engines-missing case has to name both requirements.
    try testing.expect(std.mem.indexOf(u8, none, "codex login") != null);
    try testing.expect(std.mem.indexOf(u8, none, "OPENAI_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, none, "#352") != null);

    const tuned = try refusalText(gpa, .tuned_not_on_codex, "background");
    defer gpa.free(tuned);
    try testing.expect(std.mem.indexOf(u8, tuned, "background") != null);
    try testing.expect(std.mem.indexOf(u8, tuned, "size is fine on either engine") != null);
}
