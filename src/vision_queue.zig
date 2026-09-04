//! Multi-image staging queue (#580).
//!
//! Ctrl-V / drop / `@[path]` used to overwrite a single `pending_image` slot,
//! so nine ask_user pastes left nine `[Image]` markers and one payload. This
//! queue keeps every successful stage (cap 16) until the next model request
//! consumes them as real vision blocks.
//!
//! Composer pastes (#634) are marked `from_composer`. Submit keeps those
//! payloads only while a chip (`[Image]`, `[Image #N]`, `@[path]`) is still
//! in the prompt. `/image` and `/paste` stay sticky for the next text-only
//! line. Identical `b64` payloads collapse so a double-stage cannot emit
//! four blocks from two pastes.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const PendingImage = vision.PendingImage;
const messages = @import("messages.zig");
const compact_cut = @import("compact_cut.zig");

pub const cap = 16;

pub const unsupported_note =
    "[ask_user: those image attachments did not reach the model. Save the files and pass their paths, paste the text, or send the images in your next normal prompt.]";

pub fn stage(root: *Agent, img: PendingImage) void {
    root.pending_image = img;
    if (root.pending_image_len < cap) {
        root.pending_images[root.pending_image_len] = img;
        root.pending_image_len += 1;
        return;
    }
    root.pending_images[cap - 1] = img;
}

pub fn take(root: *Agent) []const PendingImage {
    const n = root.pending_image_len;
    root.pending_image_len = 0;
    root.pending_image = null;
    return root.pending_images[0..n];
}

pub fn clear(root: *Agent) void {
    root.pending_image_len = 0;
    root.pending_image = null;
}

pub fn markLastComposer(root: *Agent) void {
    if (root.pending_image_len == 0) return;
    root.pending_images[root.pending_image_len - 1].from_composer = true;
    if (root.pending_image) |*img| img.from_composer = true;
}

pub fn hasLabel(root: *const Agent, path: []const u8) bool {
    for (root.pending_images[0..root.pending_image_len]) |img| {
        if (std.mem.eql(u8, img.label, path)) return true;
    }
    return false;
}

/// old queue index → new 1-based chip number, or 0 if that slot was dropped.
pub const Remap = [cap]u8;

/// Drop composer-staged images the prompt no longer names. Command-staged
/// `/image` / `/paste` payloads stay. Dedupes identical `b64`. Returns the
/// old-index → new-chip map so the composer can rewrite remaining `#N`s.
pub fn retainReferenced(root: *Agent, text: []const u8) Remap {
    const imgs = root.pending_images[0..root.pending_image_len];
    var keep_buf: [cap]PendingImage = undefined;
    const kept = selectForPrompt(imgs, text, &keep_buf);
    var remap: Remap = @splat(0);
    var k: usize = 0;
    for (imgs, 0..) |img, i| {
        if (k >= kept.len) break;
        if (!samePayload(img, kept[k])) continue;
        remap[i] = @intCast(k + 1);
        k += 1;
    }
    for (kept, 0..) |img, i| root.pending_images[i] = img;
    root.pending_image_len = @intCast(kept.len);
    root.pending_image = if (kept.len > 0) kept[kept.len - 1] else null;
    return remap;
}

/// Next `[Image #N]` for a new composer paste after the live queue is synced.
pub fn nextChipNumber(root: *const Agent) u8 {
    return root.pending_image_len + 1;
}

pub fn consumePromptImages(arena: Allocator, root: *Agent, text: []const u8) !Value {
    _ = retainReferenced(root, text);
    const imgs = take(root);
    for (imgs) |img| {
        if (!img.from_composer or img.media_type.len == 0) continue;
        const bytes: u64 = if (img.b64.len == 0) 0 else std.base64.standard.Decoder.calcSizeForSlice(img.b64) catch img.b64.len;
        vision.tracePaste(root, "sent", "submit", bytes, img.media_type);
    }
    if (imgs.len == 0) return messages.textMessage(arena, "user", text);
    return vision.imageMessages(arena, root.provider.kind, text, imgs);
}

/// After an ask_user (or any tool that staged pixels) tool result, attach the
/// queued images as a follow-up user message. Responses/OpenAI tool output is
/// text-only; this is the shared multimodal shape.
pub fn flushPending(root: *Agent) !void {
    const imgs = take(root);
    if (imgs.len == 0) return;
    try root.messages.append(try vision.imageMessages(root.arena, root.provider.kind, "", imgs));
}

pub fn withUnsupportedNote(arena: Allocator, answer: []const u8) ![]const u8 {
    if (!hasImageMarker(answer)) return answer;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ answer, unsupported_note });
}

fn hasImageMarker(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "[Image]") != null or
        std.mem.indexOf(u8, text, "[Image #") != null;
}

fn samePayload(a: PendingImage, b: PendingImage) bool {
    return std.mem.eql(u8, a.b64, b.b64) and std.mem.eql(u8, a.url, b.url);
}

fn selectForPrompt(imgs: []const PendingImage, text: []const u8, keep: *[cap]PendingImage) []PendingImage {
    const refs = parseRefs(text);
    var n: usize = 0;
    var bare_left = refs.bare;
    for (imgs, 0..) |img, i| {
        var want = !img.from_composer;
        if (img.from_composer) {
            if (i < cap and (refs.bits & (@as(u16, 1) << @intCast(i))) != 0) {
                want = true;
            } else if (labelInAtPath(text, img.label)) {
                want = true;
            } else if (bare_left > 0) {
                want = true;
                bare_left -= 1;
            } else {
                want = false;
            }
        }
        if (!want) continue;
        var dup = false;
        for (keep[0..n]) |k| {
            if (std.mem.eql(u8, k.b64, img.b64) and std.mem.eql(u8, k.url, img.url)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        keep[n] = img;
        n += 1;
    }
    return keep[0..n];
}

fn parseRefs(text: []const u8) struct { bits: u16, bare: u8 } {
    var bits: u16 = 0;
    var bare: u8 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "[Image #")) {
            var p = i + "[Image #".len;
            var num: u16 = 0;
            while (p < text.len and text[p] >= '0' and text[p] <= '9') : (p += 1) {
                num = num *% 10 + (text[p] - '0');
            }
            if (num >= 1 and num <= cap and p < text.len and text[p] == ']') {
                bits |= @as(u16, 1) << @intCast(num - 1);
                i = p + 1;
                continue;
            }
        }
        if (std.mem.startsWith(u8, text[i..], "[Image]")) {
            bare += 1;
            i += "[Image]".len;
            continue;
        }
        i += 1;
    }
    return .{ .bits = bits, .bare = bare };
}

fn labelInAtPath(text: []const u8, label: []const u8) bool {
    if (label.len == 0) return false;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, text, search, "@[")) |open| {
        const rest = text[open + 2 ..];
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse break;
        const path = rest[0..close];
        if (std.mem.eql(u8, path, label) or
            std.mem.endsWith(u8, label, path) or
            std.mem.endsWith(u8, path, label))
            return true;
        search = open + 2 + close + 1;
    }
    return false;
}

fn testAgent(arena: Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
}

test "queue keeps two staged images in order" {
    var root: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png" });
    try std.testing.expectEqual(@as(u8, 2), root.pending_image_len);
    const imgs = take(&root);
    try std.testing.expectEqual(@as(usize, 2), imgs.len);
    try std.testing.expectEqualStrings("AAA", imgs[0].b64);
    try std.testing.expectEqualStrings("BBB", imgs[1].b64);
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
    try std.testing.expect(root.pending_image == null);
}

test "ask_user images become follow-up vision blocks (#580)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "q1.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "q2.png" });
    try root.messages.append(try messages.toolResultMessage(arena, .responses, "ask1", "[Image] [Image]", false));
    try flushPending(&root);
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    try std.testing.expectEqual(@as(u32, 2), compact_cut.countImageBlocks(root.messages.items[1]));
    const content = root.messages.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("input_image", content[2].object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, content[1].object.get("image_url").?.string, "AAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, content[2].object.get("image_url").?.string, "BBB") != null);
}

test "remote URL and base64 parts become native provider image blocks (#615)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const request = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"user","text":"read it","images":[
        \\ {"type":"image_url","url":"https://images.test/code.png"},
        \\ {"type":"image_base64","mediaType":"image/png","data":"aGVsbG8="}]}
    , .{});
    const remote = @import("remote_images.zig");

    for ([_]@import("provider.zig").Provider.Kind{ .responses, .openai, .anthropic }) |kind| {
        var root = testAgent(arena);
        root.provider.kind = kind;
        try std.testing.expect(remote.stage(&root, request.object));
        const msg = try consumePromptImages(arena, &root, "read it");
        const content = msg.object.get("content").?.array.items;
        try std.testing.expectEqual(@as(usize, 3), content.len);
        switch (kind) {
            // Interactions carries raw base64 + mime_type, with a remote URL
            // degraded to a text marker (no proven inline form on that wire).
            .interactions => {
                try std.testing.expectEqualStrings("[image: https://images.test/code.png]", content[1].object.get("text").?.string);
                try std.testing.expectEqualStrings("aGVsbG8=", content[2].object.get("data").?.string);
                try std.testing.expectEqualStrings("image/png", content[2].object.get("mime_type").?.string);
            },
            .responses => {
                try std.testing.expectEqualStrings("https://images.test/code.png", content[1].object.get("image_url").?.string);
                try std.testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", content[2].object.get("image_url").?.string);
            },
            .openai => {
                try std.testing.expectEqualStrings("https://images.test/code.png", content[1].object.get("image_url").?.object.get("url").?.string);
                try std.testing.expectEqualStrings("data:image/png;base64,aGVsbG8=", content[2].object.get("image_url").?.object.get("url").?.string);
            },
            .anthropic => {
                const url_source = content[1].object.get("source").?.object;
                const b64_source = content[2].object.get("source").?.object;
                try std.testing.expectEqualStrings("url", url_source.get("type").?.string);
                try std.testing.expectEqualStrings("https://images.test/code.png", url_source.get("url").?.string);
                try std.testing.expectEqualStrings("base64", b64_source.get("type").?.string);
                try std.testing.expectEqualStrings("aGVsbG8=", b64_source.get("data").?.string);
            },
        }
    }
}

test "remote image validation rejects malformed data before staging (#615)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    const bad = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"type":"user","text":"read it","images":[
        \\ {"type":"image_url","url":"https://images.test/valid.png"},
        \\ {"type":"image_base64","media_type":"image/png","data":"!!!!"}]}
    , .{});
    try std.testing.expect(!@import("remote_images.zig").stage(&root, bad.object));
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
}

test "placeholder-only ask_user reply gets an explicit fallback" {
    const note = try withUnsupportedNote(std.testing.allocator, "[Image] [Image]");
    defer std.testing.allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "did not reach the model") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "next normal prompt") != null);
}

test "deleted composer chips are not sent (#634)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png", .from_composer = true });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png", .from_composer = true });
    const msg = try consumePromptImages(arena, &root, "just the remaining text");
    try std.testing.expectEqual(@as(u32, 0), compact_cut.countImageBlocks(msg));
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
}

test "numbered chip keeps only that composer slot (#634)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png", .from_composer = true });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png", .from_composer = true });
    const msg = try consumePromptImages(arena, &root, "[Image #2] what is this");
    try std.testing.expectEqual(@as(u32, 1), compact_cut.countImageBlocks(msg));
    const content = msg.object.get("content").?.array.items;
    try std.testing.expect(std.mem.indexOf(u8, content[1].object.get("image_url").?.string, "BBB") != null);
}

test "duplicate b64 collapses to one block (#634)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png" });
    const msg = try consumePromptImages(arena, &root, "see these");
    try std.testing.expectEqual(@as(u32, 2), compact_cut.countImageBlocks(msg));
}

test "command-staged /image still rides a text-only prompt" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "CMD", .label = "/tmp/shot.png" });
    const msg = try consumePromptImages(arena, &root, "what is this");
    try std.testing.expectEqual(@as(u32, 1), compact_cut.countImageBlocks(msg));
}

test "@[path] keeps the matching composer payload" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = testAgent(arena);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "/tmp/a.png", .from_composer = true });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "/tmp/b.png", .from_composer = true });
    const msg = try consumePromptImages(arena, &root, "@[/tmp/b.png] look");
    try std.testing.expectEqual(@as(u32, 1), compact_cut.countImageBlocks(msg));
    const content = msg.object.get("content").?.array.items;
    try std.testing.expect(std.mem.indexOf(u8, content[1].object.get("image_url").?.string, "BBB") != null);
}

test "retainReferenced drops leftover composer pastes before ask_user flush" {
    var root = testAgent(std.testing.allocator);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "gone.png", .from_composer = true });
    _ = retainReferenced(&root, "I changed my mind");
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
    try std.testing.expect(root.pending_image == null);
}

test "deleting a composer chip reuses #1 (#702)" {
    var root = testAgent(std.testing.allocator);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png", .from_composer = true });
    try std.testing.expectEqual(@as(u8, 2), nextChipNumber(&root));
    _ = retainReferenced(&root, "changed my mind");
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
    try std.testing.expectEqual(@as(u8, 1), nextChipNumber(&root));
}

test "remaining composer chip remaps to #1 after an earlier chip is dropped (#702)" {
    var root = testAgent(std.testing.allocator);
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png", .from_composer = true });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png", .from_composer = true });
    const remap = retainReferenced(&root, "[Image #2] look");
    try std.testing.expectEqual(@as(u8, 1), root.pending_image_len);
    try std.testing.expectEqualStrings("BBB", root.pending_images[0].b64);
    try std.testing.expectEqual(@as(u8, 0), remap[0]);
    try std.testing.expectEqual(@as(u8, 1), remap[1]);
    try std.testing.expectEqual(@as(u8, 2), nextChipNumber(&root));
}

test "command-staged /image survives an empty composer sync (#702)" {
    var root = testAgent(std.testing.allocator);
    stage(&root, .{ .media_type = "image/png", .b64 = "CMD", .label = "/tmp/shot.png" });
    _ = retainReferenced(&root, "no chips here");
    try std.testing.expectEqual(@as(u8, 1), root.pending_image_len);
    try std.testing.expectEqualStrings("CMD", root.pending_images[0].b64);
}
