//! #352: the fallback imagegen engine — the Codex imagegen skill's bundled
//! `scripts/image_gen.py`, driven directly against the OpenAI images API.
//!
//! It is the fallback rather than the default because it needs an
//! OPENAI_API_KEY the codex engine does not (that one rides the user's
//! existing ChatGPT auth), and because it bills separately. It stays because
//! it is the only engine that honours the model/quality/background/
//! output_format knobs at all — the hosted image_gen tool exposes none of
//! them — and because a codex CLI too old for an image-capable model is a
//! situation this path is unaffected by.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_model = "gpt-image-2";
/// One generation is a network round trip through an image model; 4 minutes is
/// generous for the slowest (high quality, large size) and still bounded.
pub const deadline_ms: u64 = 240 * 1000;

pub const Args = struct {
    prompt: []const u8,
    out: []const u8,
    model: []const u8 = default_model,
    size: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    background: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
};

/// `python3 <script> generate --prompt <p> --out <path> --force --model <m> …`
///
/// `--force` because the caller may have named a path that exists and the CLI
/// would otherwise refuse; whether the rewrite actually happened is not the
/// CLI's word to take, it is what verification decides afterwards.
///
/// `--dry-run` is deliberately never assembled: it prints a plan and writes no
/// file, so it could only ever produce an unverifiable "success".
pub fn buildArgv(arena: Allocator, script: []const u8, a: Args) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "python3",  script,    "generate",
        "--prompt", a.prompt,  "--out",
        a.out,      "--force", "--model",
        a.model,
    });
    if (a.size) |v| try argv.appendSlice(arena, &.{ "--size", v });
    if (a.quality) |v| try argv.appendSlice(arena, &.{ "--quality", v });
    if (a.background) |v| try argv.appendSlice(arena, &.{ "--background", v });
    if (a.output_format) |v| try argv.appendSlice(arena, &.{ "--output-format", v });
    return argv.items;
}

/// Optional values land straight in an argv slot, so they must not be able to
/// impersonate a flag or smuggle a second argument. The real vocabulary here
/// is short (1024x1024, high, transparent, gpt-image-1.5), so the allowed
/// characters can be narrow.
pub fn okFlagValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (value[0] == '-') return false;
    for (value) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

pub const no_python_text = "python3 is not on PATH, so the imagegen CLI fallback cannot run. Install Python 3, or use the codex engine (a logged-in codex CLI needs no Python and no API key). Nothing was generated.";

const testing = std.testing;

test "#352: argv is a generate call with the required flags, optionals only when given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const minimal = try buildArgv(arena, "/s/image_gen.py", .{ .prompt = "a red circle", .out = "out.png" });
    const want = [_][]const u8{
        "python3", "/s/image_gen.py", "generate", "--prompt", "a red circle",
        "--out",   "out.png",         "--force",  "--model",  default_model,
    };
    try testing.expectEqual(want.len, minimal.len);
    for (want, minimal) |w, got| try testing.expectEqualStrings(w, got);

    const full = try buildArgv(arena, "/s/image_gen.py", .{
        .prompt = "p",
        .out = "o.webp",
        .model = "gpt-image-1.5",
        .size = "1024x1536",
        .quality = "high",
        .background = "transparent",
        .output_format = "webp",
    });
    try testing.expectEqual(@as(usize, 18), full.len);
    for ([_][]const u8{ "--size", "1024x1536", "--quality", "high", "--background", "transparent", "--output-format", "webp" }) |needle| {
        var found = false;
        for (full) |arg| {
            if (std.mem.eql(u8, arg, needle)) found = true;
        }
        try testing.expect(found);
    }
    for (full) |arg| try testing.expect(!std.mem.eql(u8, arg, "--dry-run"));
}

test "#352: optional values cannot impersonate a flag or smuggle an argument" {
    for ([_][]const u8{ "1024x1024", "auto", "high", "transparent", "gpt-image-1.5", "PNG" }) |ok|
        try testing.expect(okFlagValue(ok));
    for ([_][]const u8{ "", "--out", "-q", "1024 1024", "a;rm -rf /", "$(id)", "a\nb", "a/b" }) |bad|
        try testing.expect(!okFlagValue(bad));
    var long: [65]u8 = @splat('a');
    try testing.expect(!okFlagValue(&long));
}
