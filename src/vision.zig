//! Image/vision support: the staged-image type + per-provider vision-capability
//! check, media-type-from-extension, the anthropic/openai/responses image
//! message builder, and the /image·/paste·Ctrl-V·GUI-attachment stagers +
//! macOS clipboard grab. Split out of main.zig (600-line goal). Back-imports
//! main (as main_mod, since the stagers' param is named `root`) for Agent,
//! Provider, and isImagePath. main aliases the public surface back.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = main_mod.Agent;
const Provider = main_mod.Provider;
const input_util = @import("input_util.zig");
const isImagePath = input_util.isImagePath;

pub const PendingImage = struct { media_type: []const u8, b64: []const u8, label: []const u8 };

/// Conservative vision check: only models we know accept images. Everything
/// else (deepseek, kimi, glm, minimax, mimo, …) is treated as text-only so
/// `/image` can point it out instead of triggering a provider 400.
/// Vision support by model-name prefix (provider-agnostic): which models
/// accept image content blocks. Used by /image, Ctrl-V, image drops, and
/// the /models vision column.
pub fn visionModel(m_full: []const u8) bool {
    // Local / OpenAI-compatible providers (LM Studio, Ollama, …) report
    // org-prefixed ids like "google/gemma-4-26b-a4b-qat" — match the bare name.
    const slash = std.mem.lastIndexOfScalar(u8, m_full, '/');
    const m = if (slash) |i| m_full[i + 1 ..] else m_full;
    return std.mem.startsWith(u8, m, "claude") or
        std.mem.startsWith(u8, m, "gpt-5") or
        std.mem.startsWith(u8, m, "gpt-4") or
        std.mem.startsWith(u8, m, "grok-4") or
        std.mem.startsWith(u8, m, "kimi") or // kimi-k2.7+ see images (Kimi for Coding endpoint, verified 2026-06-16)
        std.mem.startsWith(u8, m, "gemini") or
        std.mem.startsWith(u8, m, "gemma") or // gemma-3/4 are multimodal (LM Studio etc.)
        std.mem.startsWith(u8, m, "llava") or
        std.mem.startsWith(u8, m, "pixtral") or
        std.mem.indexOf(u8, m, "-vl") != null or // qwen2-vl, qwen2.5-vl, internvl, …
        std.mem.indexOf(u8, m, "vision") != null; // llama-3.2-vision, minicpm-v-vision, …
}

pub fn visionCapable(p: Provider) bool {
    return visionModel(p.model);
}

/// Guess an image media type from a file extension (default image/png).
pub fn imageMediaType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    return "image/png";
}

/// A user message carrying text + one image, in the provider's wire format.
pub fn imageMessage(arena: Allocator, kind: Provider.Kind, text: []const u8, img: PendingImage) !Value {
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = "user" });
    var content = std.json.Array.init(arena);

    var tb: std.json.ObjectMap = .empty;
    try tb.put(arena, "type", .{ .string = if (kind == .responses) "input_text" else "text" });
    try tb.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    try content.append(.{ .object = tb });

    var ib: std.json.ObjectMap = .empty;
    switch (kind) {
        .anthropic => {
            try ib.put(arena, "type", .{ .string = "image" });
            var src: std.json.ObjectMap = .empty;
            try src.put(arena, "type", .{ .string = "base64" });
            try src.put(arena, "media_type", .{ .string = img.media_type });
            try src.put(arena, "data", .{ .string = img.b64 });
            try ib.put(arena, "source", .{ .object = src });
        },
        .openai => {
            try ib.put(arena, "type", .{ .string = "image_url" });
            var iu: std.json.ObjectMap = .empty;
            try iu.put(arena, "url", .{ .string = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 }) });
            try ib.put(arena, "image_url", .{ .object = iu });
        },
        .responses => {
            try ib.put(arena, "type", .{ .string = "input_image" });
            try ib.put(arena, "image_url", .{ .string = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 }) });
        },
    }
    try content.append(.{ .object = ib });
    try msg.put(arena, "content", .{ .array = content });
    return .{ .object = msg };
}

pub const StageResult = enum { ok, no_vision, read_fail };

/// Read an image file, base64-encode it, and stage it on the agent for the next
/// turn (shared by /image, /paste, and Ctrl-V). Refuses on non-vision models.
pub fn stageImagePath(root: *Agent, path: []const u8) StageResult {
    if (!visionCapable(root.provider)) return .no_vision;
    const arena = root.arena;
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(5 * 1024 * 1024)) catch return .read_fail;
    const enc = std.base64.standard.Encoder;
    const b64 = arena.alloc(u8, enc.calcSize(data.len)) catch return .read_fail;
    _ = enc.encode(b64, data);
    root.pending_image = .{ .media_type = imageMediaType(path), .b64 = b64, .label = arena.dupe(u8, path) catch path };
    return .ok;
}

/// GUI image attachments arrive inline as `@[path]` markers in the prompt text
/// (see the desktop AttachmentTray / appendAttachmentsToPrompt). Stage the first
/// image one as a real vision block so a vision model sees it natively instead
/// of receiving only a path to OCR. The marker is left in the text — harmless
/// once the image is visible — so non-image `@[path]` entries the agent should
/// open with its tools are untouched. No-op for non-vision providers, when an
/// image is already staged (e.g. via /image), or when no image marker is found.
pub fn stageGuiImageAttachment(root: *Agent, msg: []const u8) void {
    if (root.pending_image != null) return;
    if (!visionCapable(root.provider)) return;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, msg, search, "@[")) |open| {
        const rest = msg[open + 2 ..];
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
        const path = rest[0..close];
        if (isImagePath(path) and stageImagePath(root, path) == .ok) return;
        search = open + 2 + close + 1;
    }
}

/// macOS: dump the clipboard image (if any) to a temp PNG via osascript and
/// return its path; null if the clipboard holds no image (or not macOS).
/// (A terminal can't receive clipboard image bytes over stdin, so we ask the OS.)
pub fn grabClipboardImage(io: Io) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const path = "/tmp/.harness-clip.png";
    var child = std.process.spawn(io, .{
        .argv = &.{
            "osascript",
            "-e",
            "try",
            "-e",
            "set thePNG to (the clipboard as «class PNGf»)",
            "-e",
            "set fp to open for access POSIX file \"/tmp/.harness-clip.png\" with write permission",
            "-e",
            "set eof fp to 0",
            "-e",
            "write thePNG to fp",
            "-e",
            "close access fp",
            "-e",
            "on error",
            "-e",
            "error number 1",
            "-e",
            "end try",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    const term = child.wait(io) catch return null;
    if (term == .exited and term.exited == 0) return path;
    return null;
}
test "imageMediaType from extension" {
    try std.testing.expectEqualStrings("image/png", imageMediaType("shot.png"));
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("p.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", imageMediaType("p.jpeg"));
    try std.testing.expectEqualStrings("image/gif", imageMediaType("a.gif"));
    try std.testing.expectEqualStrings("image/webp", imageMediaType("a.webp"));
    try std.testing.expectEqualStrings("image/png", imageMediaType("noext")); // default
}

test "visionCapable allowlist" {
    const mk = struct {
        fn p(model: []const u8) Provider {
            return .{ .id = "x", .kind = .openai, .auth = .bearer, .url = "", .model = model, .context = 0, .api_key = "", .account = "" };
        }
    }.p;
    try std.testing.expect(visionCapable(mk("claude-opus-4-8")));
    try std.testing.expect(visionCapable(mk("gpt-5.5")));
    try std.testing.expect(!visionCapable(mk("deepseek-v4-pro")));
    try std.testing.expect(visionCapable(mk("kimi-k2.7"))); // Kimi for Coding sees images
    try std.testing.expect(!visionCapable(mk("minimax-m3")));
}

test "visionModel: vision-capable model families only" {
    try std.testing.expect(visionModel("claude-opus-4-8"));
    try std.testing.expect(visionModel("gpt-5.5"));
    try std.testing.expect(visionModel("gpt-4o"));
    try std.testing.expect(visionModel("grok-4.3"));
    try std.testing.expect(visionModel("kimi-k2.7"));
    try std.testing.expect(visionModel("gemini-2.0"));
    // Local / OpenAI-compat providers report org-prefixed ids — match the bare name.
    try std.testing.expect(visionModel("google/gemma-4-26b-a4b-qat"));
    try std.testing.expect(visionModel("gemma-3-12b"));
    try std.testing.expect(visionModel("llava-1.6"));
    try std.testing.expect(visionModel("pixtral-12b"));
    try std.testing.expect(visionModel("qwen2.5-vl-7b"));
    try std.testing.expect(visionModel("llama-3.2-11b-vision"));
    try std.testing.expect(!visionModel("deepseek-v4-pro"));
    try std.testing.expect(!visionModel("mimo-v2.5"));
    try std.testing.expect(!visionModel("grok-build")); // grok-4 prefix only, not all grok
    try std.testing.expect(!visionModel("qwen2.5-coder-7b")); // text-only local model
}
