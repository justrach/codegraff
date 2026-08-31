//! Image/vision support: the staged-image type + per-provider vision-capability
//! check, media-type-from-extension, the anthropic/openai/responses image
//! message builder, and the /image·/paste·Ctrl-V·GUI-attachment stagers.
//! Split out of main.zig (600-line goal). Back-imports main (as main_mod,
//! since the stagers' param is named `root`) for Agent, Provider, and
//! isImagePath. main aliases the public surface back. The macOS pasteboard
//! cascade itself (and the byte budget staged images live under) is one level
//! down in vision_clipboard.zig and re-exported here.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Provider = provider_mod.Provider;
const input_util = @import("input_util.zig");
const isImagePath = input_util.isImagePath;

/// The macOS pasteboard cascade, temp paths, the sips gate/downscaler and the
/// raw-byte budget (vision_clipboard.zig, 600-line goal). Re-exported below so
/// readline/commands_model keep importing only `vision`.
const clip = @import("vision_clipboard.zig");
pub const Flavor = clip.Flavor;
pub const Grab = clip.Grab;
pub const grabClipboardImage = clip.grabClipboardImage;
pub const max_staged_image_bytes = clip.max_staged_image_bytes;
pub const fmtBytes = clip.fmtMb;

pub const PendingImage = struct {
    media_type: []const u8,
    b64: []const u8,
    url: []const u8 = "",
    label: []const u8,
    /// Ctrl-V / drop inserted a composer chip. Submit keeps the payload only
    /// while that chip (or an `@[path]`) is still in the prompt (#634).
    from_composer: bool = false,
};

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
        std.mem.startsWith(u8, m, "glm-5v") or // glm-5v-turbo & co: explicit vision variants
        std.mem.startsWith(u8, m, "glm-5.3") or // glm-5.3 / glm-5.3-flash accept images on codegraff
        std.mem.startsWith(u8, m, "kimi") or
        (m.len > 1 and m[0] == 'k' and std.ascii.isDigit(m[1])) or // Kimi Code k3+
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
    return imageMessages(arena, kind, text, &.{img});
}

/// A user message carrying text + every staged image, in the provider's wire
/// format. Used by the main prompt and by ask_user follow-ups (#580).
pub fn imageMessages(arena: Allocator, kind: Provider.Kind, text: []const u8, imgs: []const PendingImage) !Value {
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = "user" });
    var content = std.json.Array.init(arena);

    var tb: std.json.ObjectMap = .empty;
    try tb.put(arena, "type", .{ .string = if (kind == .responses) "input_text" else "text" });
    try tb.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    try content.append(.{ .object = tb });

    for (imgs) |img| {
        var ib: std.json.ObjectMap = .empty;
        switch (kind) {
            .anthropic => {
                try ib.put(arena, "type", .{ .string = "image" });
                var src: std.json.ObjectMap = .empty;
                if (img.url.len > 0) {
                    try src.put(arena, "type", .{ .string = "url" });
                    try src.put(arena, "url", .{ .string = img.url });
                } else {
                    try src.put(arena, "type", .{ .string = "base64" });
                    try src.put(arena, "media_type", .{ .string = img.media_type });
                    try src.put(arena, "data", .{ .string = img.b64 });
                }
                try ib.put(arena, "source", .{ .object = src });
            },
            .openai => {
                try ib.put(arena, "type", .{ .string = "image_url" });
                var iu: std.json.ObjectMap = .empty;
                const url = if (img.url.len > 0) img.url else try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 });
                try iu.put(arena, "url", .{ .string = url });
                try ib.put(arena, "image_url", .{ .object = iu });
            },
            .responses => {
                try ib.put(arena, "type", .{ .string = "input_image" });
                const url = if (img.url.len > 0) img.url else try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{ img.media_type, img.b64 });
                try ib.put(arena, "image_url", .{ .string = url });
            },
        }
        try content.append(.{ .object = ib });
    }
    try msg.put(arena, "content", .{ .array = content });
    return .{ .object = msg };
}

/// Why an image did or did not reach the provider.
///
/// A tagged union, not an enum, because "too big" is only actionable if the
/// user is told BY HOW MUCH. The old `.read_fail` collapsed oversize, missing,
/// permission-denied and OOM into one sentence that guessed ("missing, or
/// larger than 5MB"), so a 7.3 MB screenshot and a typo'd path produced the
/// same unhelpful line (#349).
pub const StageResult = union(enum) {
    ok: struct { bytes: u64, media_type: []const u8 },
    no_vision,
    /// Over the wire budget even after `sips` downscaling. Both numbers are
    /// carried so the message can print them.
    too_large: struct { bytes: u64, limit: u64 },
    /// Nothing at that path, or not a regular file.
    not_found,
    /// It was there and the right size, but the read or the encode failed.
    read_error,

    pub fn isOk(self: StageResult) bool {
        return std.meta.activeTag(self) == .ok;
    }
};

/// Read an image file, base64-encode it, and stage it on the agent for the next
/// turn (shared by /image, /paste, and Ctrl-V). Refuses on non-vision models.
///
/// Stats before reading: the size has to be a number we can report, not
/// something inferred after the fact from `error.StreamTooLong`. Over-budget
/// files are downscaled rather than dropped.
pub fn stageImagePath(root: *Agent, path: []const u8) StageResult {
    if (!visionCapable(root.provider)) return .no_vision;
    const io = root.io;
    const fit = switch (clip.planStage(io, root.gpa, path, clip.max_staged_image_bytes, clip.sipsResize)) {
        .not_found => return .not_found,
        .too_large => |bytes| return .{ .too_large = .{ .bytes = bytes, .limit = clip.max_staged_image_bytes } },
        .fits => |f| f,
    };
    defer if (fit.temp) clip.discard(io, root.gpa, fit.path);

    const arena = root.arena;
    const data = Io.Dir.cwd().readFileAlloc(io, fit.path, arena, .limited(@intCast(clip.max_staged_image_bytes))) catch return .read_error;
    const enc = std.base64.standard.Encoder;
    const b64 = arena.alloc(u8, enc.calcSize(data.len)) catch return .read_error;
    _ = enc.encode(b64, data);
    // Media type from the file we actually encoded, but labelled with the path
    // the USER named — a temp file's random name means nothing to them. A
    // downscale step is PNG because `sipsResize` forces `-s format png` AND
    // `fitToBudget` re-checks the magic bytes; without both, `sips -Z` would
    // keep the source encoding and we'd send JPEG bytes as `image/png`.
    const media = imageMediaType(fit.path);
    @import("vision_queue.zig").stage(root, .{ .media_type = media, .b64 = b64, .label = arena.dupe(u8, path) catch path });
    return .{ .ok = .{ .bytes = fit.bytes, .media_type = media } };
}

/// One actionable line per staging failure. `what` names the thing that failed
/// ("the clipboard image", "'shot.png'"); `buf` wants ~192 bytes.
pub fn stageMessage(buf: []u8, r: StageResult, what: []const u8) []const u8 {
    var got: [16]u8 = undefined;
    var cap: [16]u8 = undefined;
    return switch (r) {
        .ok => "",
        .no_vision => no_vision_message,
        .too_large => |t| std.fmt.bufPrint(
            buf,
            "{s} is {s} — over the {s} limit; downscale it or use a smaller crop",
            .{ what, clip.fmtMb(&got, t.bytes), clip.fmtMb(&cap, t.limit) },
        ) catch "that image is too large to send",
        .not_found => std.fmt.bufPrint(buf, "can't find {s}", .{what}) catch "can't find that image",
        .read_error => std.fmt.bufPrint(buf, "couldn't read {s}", .{what}) catch "couldn't read that image",
    };
}

/// One `clipboard_paste` receipt per Ctrl-V / `/paste`, whatever the outcome
/// (#350). Before this a dropped paste left ZERO evidence behind: a failing
/// and a succeeding run produced byte-identical `.graff/traces` JSONL.
/// Successful stages omit MIME / bytes until the image is actually sent
/// (#702 / ADR 0056). Failures may still carry a size. Never the pixels.
pub fn tracePaste(root: *Agent, result: []const u8, flavor: []const u8, bytes: u64, mime: []const u8) void {
    const tracer = root.tracer orelse return;
    tracer.write(.{
        .t = tracer.elapsedMs(),
        .ev = "clipboard_paste",
        .result = result,
        .flavor = flavor,
        .bytes = bytes,
        .mime = mime,
    });
}

/// `tracePaste` for a paste that got as far as staging.
pub fn tracePasteResult(root: *Agent, flavor: Flavor, r: StageResult) void {
    switch (r) {
        // #702: a successful stage is not a sent attachment. MIME / bytes
        // wait for consumePromptImages so an abandoned draft leaves no
        // content-derived receipt. Failures still record why they died.
        .ok => tracePaste(root, "ok", flavor.name(), 0, ""),
        .too_large => |t| tracePaste(root, "too_large", flavor.name(), t.bytes, ""),
        else => tracePaste(root, @tagName(r), flavor.name(), 0, ""),
    }
}

/// GUI image attachments arrive inline as `@[path]` markers in the prompt text
/// (see the desktop AttachmentTray / appendAttachmentsToPrompt). Stage the first
/// image one as a real vision block so a vision model sees it natively instead
/// of receiving only a path to OCR. The marker is left in the text — harmless
/// once the image is visible — so non-image `@[path]` entries the agent should
/// open with its tools are untouched. No-op for non-vision providers, when an
/// image is already staged (e.g. via /image), or when no image marker is found.
///
/// Also the per-turn home of the MCP image handoff (#249): mainloop calls this
/// once per user message with the root agent in hand, which is the only place
/// that holds both the registry and the provider.
pub fn stageGuiImageAttachment(root: *Agent, msg: []const u8) void {
    if (root.registry) |reg| if (mcpImageHandoff(reg, visionCapable(root.provider), &root.pending_image)) return; // #249
    if (!visionCapable(root.provider)) return;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, msg, search, "@[")) |open| {
        const rest = msg[open + 2 ..];
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
        const path = rest[0..close];
        if (isImagePath(path) and !@import("vision_queue.zig").hasLabel(root, path))
            _ = stageImagePath(root, path);
        search = open + 2 + close + 1;
    }
}

/// An MCP `tools/call` content block that carries pixels:
/// `{type:"image", data:"<base64>", mimeType:"image/png"}` (#249). The strings
/// are borrowed from the parsed response, so `stage` copies them out before the
/// per-call response arena dies.
pub const McpImageBlock = struct {
    media_type: []const u8,
    b64: []const u8,
    bytes: usize, // decoded size, for the line the model reads

    pub fn stage(self: McpImageBlock, arena: Allocator, label: []const u8) !PendingImage {
        return .{
            .media_type = try arena.dupe(u8, self.media_type),
            .b64 = try arena.dupe(u8, self.b64),
            .label = try arena.dupe(u8, label),
        };
    }
};

/// The same ceiling `stageImagePath` reads a file under — the base64 math is
/// identical whether the pixels came from a tool or from disk, so an MCP
/// screenshot over the budget is refused here (with a note the model reads)
/// instead of turning into a provider 400 one call later.
const max_mcp_image_bytes: usize = @intCast(clip.max_staged_image_bytes);

/// Recognize an MCP image content block. Null for anything else — a text block,
/// a non-`image/*` mime, base64 we cannot decode, or a payload over the ceiling
/// — so a malformed result is rejected at our boundary instead of turning into
/// a provider 400 one call later.
pub fn mcpImageBlock(block: Value) ?McpImageBlock {
    if (block != .object) return null;
    const t = block.object.get("type") orelse return null;
    if (t != .string or !std.mem.eql(u8, t.string, "image")) return null;
    const data = block.object.get("data") orelse return null;
    if (data != .string) return null;
    // mimeType is required by the spec; default rather than drop an otherwise
    // usable image, but refuse a mime that is not an image at all.
    const mime = if (block.object.get("mimeType")) |m| (if (m == .string) m.string else "") else "";
    const media_type = if (mime.len == 0) "image/png" else mime;
    if (!std.mem.startsWith(u8, media_type, "image/")) return null;
    const bytes = std.base64.standard.Decoder.calcSizeForSlice(data.string) catch return null;
    if (bytes == 0 or bytes > max_mcp_image_bytes) return null;
    return .{ .media_type = media_type, .b64 = data.string, .bytes = bytes };
}

/// What became of an image block, so the tool result says it out loud instead
/// of dropping the pixels in silence the way it used to (#249).
pub const McpImageFate = enum { staged, no_vision, already_staged };

pub fn mcpImageNote(w: *Io.Writer, blk: McpImageBlock, fate: McpImageFate) !void {
    try w.print("[image: {s}, {d} bytes — {s}]", .{ blk.media_type, blk.bytes, switch (fate) {
        .staged => "attached to your next turn",
        .no_vision => no_vision_message,
        .already_staged => "not attached: another image is already queued for the next turn",
    } });
}

/// Move an image an MCP tool staged on the registry into the agent's slot, and
/// tell the registry whether this model takes images at all — the registry sees
/// the pixels but has no route to the provider (#249). `reg` is a
/// `*mcp.Registry`, taken as anytype so vision.zig need not import back into the
/// MCP client. Returns true when an image was promoted.
pub fn mcpImageHandoff(reg: anytype, supports_vision: bool, slot: *?PendingImage) bool {
    reg.mutex.lockUncancelable(reg.io); // `call` stages from agent pool threads
    defer reg.mutex.unlock(reg.io);
    reg.vision_capable = supports_vision;
    const img = reg.pending_image orelse return false;
    reg.pending_image = null;
    // A text-only model, or /image already won this turn: drop it rather than
    // let it surface several turns later, stripped of its context.
    if (!supports_vision or slot.* != null) return false;
    slot.* = img;
    return true;
}

/// Why a Ctrl-V clipboard paste did or did not produce an image (#258).
/// Ordered so the cheapest, most-likely-wrong condition is decided first.
/// (A terminal can't receive clipboard image bytes over stdin, so the actual
/// pixels are fetched from the OS by `grabClipboardImage`'s flavor cascade.)
pub const ClipboardPasteSource = union(enum) {
    image: Grab,
    no_image,
    no_vision,
    unsupported_platform,
};

/// Decide a Ctrl-V paste WITHOUT touching the clipboard unless it can help.
///
/// The vision check comes first deliberately: on a non-vision model the paste
/// can never succeed, so shelling out to the clipboard would spend a subprocess
/// (and on macOS, a pasteboard read of whatever the user last copied) purely to
/// produce an error. `grabber` is injected so the ordering is testable without
/// a real clipboard.
pub fn clipboardPasteSource(io: Io, gpa: Allocator, supports_vision: bool, is_macos: bool, grabber: anytype) ClipboardPasteSource {
    if (!supports_vision) return .no_vision;
    if (!is_macos) return .unsupported_platform;
    return .{ .image = grabber(io, gpa) orelse return .no_image };
}

/// The user-facing line for every non-image paste outcome, so the caller's
/// switch stays one prong instead of three parallel string literals.
pub fn pasteMessage(source: ClipboardPasteSource) []const u8 {
    return switch (source) {
        .no_vision => no_vision_message,
        .unsupported_platform => "clipboard image paste is macOS-only — use /image <path>",
        .no_image => "no image on the clipboard — copy an image first (this is Ctrl-V; ⌘V can't be captured)",
        .image => "",
    };
}

/// Shared by the pre-clipboard guard and the post-stage failure path, which
/// previously carried two copies of the same sentence.
pub const no_vision_message = "this model can't see images — /model to a vision one (claude-*, gpt-5*)";

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
    try std.testing.expect(visionCapable(mk("k3"))); // Kimi for Coding sees images
    try std.testing.expect(visionCapable(mk("glm-5.3-flash"))); // codegraff backend accepts images
    try std.testing.expect(visionCapable(mk("glm-5v-turbo"))); // glm's explicit vision variant
    try std.testing.expect(!visionCapable(mk("minimax-m3")));
}

test "visionModel: vision-capable model families only" {
    try std.testing.expect(visionModel("claude-opus-4-8"));
    try std.testing.expect(visionModel("gpt-5.5"));
    try std.testing.expect(visionModel("gpt-4o"));
    try std.testing.expect(visionModel("grok-4.3"));
    try std.testing.expect(visionModel("glm-5.3-flash"));
    try std.testing.expect(visionModel("glm-5v-turbo"));
    try std.testing.expect(visionModel("k3"));
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

test "clipboardPasteSource: vision is checked before the clipboard is touched (#258)" {
    // The ordering IS the fix: on a non-vision model the paste can never work,
    // so the clipboard must not be read at all. `calls` proves that.
    const MockGrabber = struct {
        var calls: usize = 0;
        var image: ?Grab = .{ .path = "/tmp/test.png", .flavor = .png, .owned = false };

        fn grab(_: Io, _: Allocator) ?Grab {
            calls += 1;
            return image;
        }
    };
    const expectTag = struct {
        fn expect(expected: std.meta.Tag(ClipboardPasteSource), actual: ClipboardPasteSource) !void {
            try std.testing.expectEqual(expected, std.meta.activeTag(actual));
        }
    }.expect;

    MockGrabber.calls = 0;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    try expectTag(.no_vision, clipboardPasteSource(io, gpa, false, true, MockGrabber.grab));
    try expectTag(.no_vision, clipboardPasteSource(io, gpa, false, false, MockGrabber.grab));
    try expectTag(.unsupported_platform, clipboardPasteSource(io, gpa, true, false, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 0), MockGrabber.calls);

    try expectTag(.image, clipboardPasteSource(io, gpa, true, true, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 1), MockGrabber.calls);

    MockGrabber.image = null;
    try expectTag(.no_image, clipboardPasteSource(io, gpa, true, true, MockGrabber.grab));
    try std.testing.expectEqual(@as(usize, 2), MockGrabber.calls);
}

test "pasteMessage: every non-image outcome has a distinct, non-empty line" {
    const cases = [_]ClipboardPasteSource{ .no_vision, .unsupported_platform, .no_image };
    for (cases, 0..) |a, i| {
        try std.testing.expect(pasteMessage(a).len > 0);
        for (cases[i + 1 ..]) |b|
            try std.testing.expect(!std.mem.eql(u8, pasteMessage(a), pasteMessage(b)));
    }
    // The staged-failure path reuses the same sentence rather than duplicating it.
    try std.testing.expectEqualStrings(no_vision_message, pasteMessage(.no_vision));
}

test "stageMessage: an oversized paste names both real sizes, and each failure reads differently (#349)" {
    var buf: [256]u8 = undefined;
    const too_big = stageMessage(&buf, .{ .too_large = .{ .bytes = 7_682_253, .limit = max_staged_image_bytes } }, "the clipboard image");
    // The whole point: the user is told how big it is and how big it may be,
    // instead of the old "missing, or larger than 5MB" guess.
    try std.testing.expectEqualStrings(
        "the clipboard image is 7.3 MB — over the 3.5 MB limit; downscale it or use a smaller crop",
        too_big,
    );

    var b2: [256]u8 = undefined;
    const missing = stageMessage(&b2, .not_found, "'shot.png'");
    try std.testing.expect(std.mem.indexOf(u8, missing, "shot.png") != null);
    try std.testing.expect(!std.mem.eql(u8, missing, too_big));

    var b3: [256]u8 = undefined;
    const unreadable = stageMessage(&b3, .read_error, "'shot.png'");
    try std.testing.expect(!std.mem.eql(u8, unreadable, missing));
    try std.testing.expectEqualStrings(no_vision_message, stageMessage(&b3, .no_vision, "x"));
}

/// Parse one JSON literal into `a` — the MCP content blocks these tests feed in.
fn parseBlock(a: Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{ .allocate = .alloc_always });
}

test "mcpImageBlock: an MCP image block round-trips base64 + mimeType (#249)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const png = "\x89PNG\r\n\x1a\n"; // 8 bytes of a real PNG signature
    var b64_buf: [16]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, png);
    const json = try std.fmt.allocPrint(a, "{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\"}}", .{b64});

    const img = mcpImageBlock(try parseBlock(a, json)) orelse return error.ImageBlockNotRecognized;
    try std.testing.expectEqualStrings("image/png", img.media_type);
    try std.testing.expectEqual(@as(usize, png.len), img.bytes);

    const staged = try img.stage(a, "mcp__shots__grab");
    try std.testing.expectEqualStrings("image/png", staged.media_type);
    try std.testing.expectEqualStrings(b64, staged.b64);
    try std.testing.expectEqualStrings("mcp__shots__grab", staged.label);
    var round_trip: [png.len]u8 = undefined;
    try std.base64.standard.Decoder.decode(&round_trip, staged.b64);
    try std.testing.expectEqualSlices(u8, png, &round_trip);

    // Everything that is not a usable image stays out of the vision path.
    try std.testing.expect(mcpImageBlock(try parseBlock(a, "{\"type\":\"text\",\"text\":\"hi\"}")) == null);
    try std.testing.expect(mcpImageBlock(try parseBlock(a, "{\"type\":\"image\",\"data\":\"!!not-base64!!\"}")) == null);
    try std.testing.expect(mcpImageBlock(try parseBlock(a, "{\"type\":\"image\",\"data\":\"aGVsbG8=\",\"mimeType\":\"text/plain\"}")) == null);
    // mimeType is optional in the wild; default instead of dropping the pixels.
    const defaulted = mcpImageBlock(try parseBlock(a, "{\"type\":\"image\",\"data\":\"aGVsbG8=\"}")) orelse return error.ImageBlockNotRecognized;
    try std.testing.expectEqualStrings("image/png", defaulted.media_type);
}

test "renderContent: a text+image MCP result keeps both and stages the image (#249)" {
    const mcp_content = @import("mcp_content.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const content = try parseBlock(a,
        \\[{"type":"text","text":"here is the screenshot"},
        \\ {"type":"image","data":"aGVsbG8=","mimeType":"image/jpeg"}]
    );
    var slot: ?PendingImage = null;
    var w: Io.Writer.Allocating = .init(a);
    try mcp_content.renderContent(&w.writer, content, .{ .arena = a, .slot = &slot, .label = "mcp__shots__grab", .supports_vision = true });

    const text = w.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "here is the screenshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "image/jpeg") != null);
    const img = slot orelse return error.ImageNotStaged;
    try std.testing.expectEqualStrings("image/jpeg", img.media_type);
    try std.testing.expectEqualStrings("aGVsbG8=", img.b64);
    try std.testing.expectEqualStrings("mcp__shots__grab", img.label);
}

test "renderContent: an image-only result is never silently empty (#249)" {
    const mcp_content = @import("mcp_content.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const content = try parseBlock(a, "[{\"type\":\"image\",\"data\":\"aGVsbG8=\",\"mimeType\":\"image/png\"}]");

    // Vision model: staged, and the text says so.
    var slot: ?PendingImage = null;
    var w: Io.Writer.Allocating = .init(a);
    try mcp_content.renderContent(&w.writer, content, .{ .arena = a, .slot = &slot, .label = "t", .supports_vision = true });
    try std.testing.expect(slot != null);
    try std.testing.expect(std.mem.indexOf(u8, w.writer.buffered(), "image/png") != null);

    // Text-only model: nothing staged, but the model is TOLD, rather than
    // receiving "" and inferring the tool did nothing.
    var slot2: ?PendingImage = null;
    var w2: Io.Writer.Allocating = .init(a);
    try mcp_content.renderContent(&w2.writer, content, .{ .arena = a, .slot = &slot2, .label = "t", .supports_vision = false });
    try std.testing.expect(slot2 == null);
    try std.testing.expect(std.mem.indexOf(u8, w2.writer.buffered(), no_vision_message) != null);
    try std.testing.expect(w2.writer.buffered().len > 0);
}

test "mcpImageHandoff: registry image reaches the agent slot, vision models only (#249)" {
    const mcp = @import("mcp.zig");
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    const img: PendingImage = .{ .media_type = "image/png", .b64 = "aGVsbG8=", .label = "mcp__shots__grab" };

    // Text-only model: the fact is pushed to the registry and the image is
    // dropped rather than surfacing turns later out of context.
    reg.pending_image = img;
    var slot: ?PendingImage = null;
    try std.testing.expect(!mcpImageHandoff(&reg, false, &slot));
    try std.testing.expect(slot == null);
    try std.testing.expect(!reg.vision_capable);
    try std.testing.expect(reg.pending_image == null);

    // Vision model: promoted, and the registry slot is cleared so one image is
    // never attached to two turns.
    reg.pending_image = img;
    try std.testing.expect(mcpImageHandoff(&reg, true, &slot));
    try std.testing.expect(reg.vision_capable);
    try std.testing.expect(reg.pending_image == null);
    try std.testing.expectEqualStrings("aGVsbG8=", slot.?.b64);

    // /image already won this turn: keep the user's pick, drop the tool's.
    reg.pending_image = .{ .media_type = "image/gif", .b64 = "R0lG", .label = "later" };
    try std.testing.expect(!mcpImageHandoff(&reg, true, &slot));
    try std.testing.expectEqualStrings("aGVsbG8=", slot.?.b64);
    try std.testing.expect(reg.pending_image == null);
}
