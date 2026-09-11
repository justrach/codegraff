//! The staged-image payload and the four provider wire shapes that carry it in
//! one user message (anthropic / interactions / openai / responses).
//! Split out of vision.zig, which was at the 600-line ceiling; vision.zig
//! re-exports `PendingImage`, `imageMessage` and `imageMessages` so every
//! caller keeps importing only `vision`.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;

pub const PendingImage = struct {
    media_type: []const u8,
    b64: []const u8,
    url: []const u8 = "",
    label: []const u8,
    /// Ctrl-V / drop inserted a composer chip. Submit keeps the payload only
    /// while that chip (or an `@[path]`) is still in the prompt (#634).
    from_composer: bool = false,
};

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
            .interactions => try @import("interactions_steps.zig").imagePart(arena, &ib, img),
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
