//! Native image parts on the JSON/serve user-turn boundary (#615).
//!
//! The request owns its parsed strings only until mainloop advances, so this
//! module validates every part first, then copies it into the Agent's existing
//! staged-image queue. `vision.imageMessages` performs the provider-specific
//! Anthropic/OpenAI/Responses conversion at the ordinary prompt boundary.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");

const Spec = union(enum) {
    url: []const u8,
    base64: struct { media_type: []const u8, data: []const u8 },
};

fn stringField(obj: std.json.ObjectMap, name: []const u8) []const u8 {
    const value = obj.get(name) orelse return "";
    return if (value == .string) value.string else "";
}

fn fail(root: *Agent, message: []const u8) bool {
    root.emit(.{ .type = "error", .message = message });
    return false;
}

fn validUrl(url: []const u8) bool {
    return url.len <= 8192 and
        (std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://"));
}

/// Validate and stage `images` from one `{type:"user",text,images}` request.
/// Canonical wire fields are snake_case; `mediaType` is accepted for the
/// generated TypeScript SDK's idiomatic public shape.
pub fn stage(root: *Agent, request: std.json.ObjectMap) bool {
    const value = request.get("images") orelse return true;
    if (value != .array) return fail(root, "request images must be an array");
    const parts = value.array.items;
    if (parts.len == 0) return true;
    if (parts.len + root.pending_image_len > vision_queue.cap)
        return fail(root, "request exceeds the 16-image limit");
    if (!vision.visionCapable(root.provider))
        return fail(root, "the selected model does not advertise native image input");

    var specs: [vision_queue.cap]Spec = undefined;
    for (parts, 0..) |part, i| {
        if (part != .object) return fail(root, "each request image must be an object");
        const kind = stringField(part.object, "type");
        if (std.mem.eql(u8, kind, "image_url")) {
            const url = stringField(part.object, "url");
            if (!validUrl(url)) return fail(root, "image_url needs an http(s) URL of at most 8192 bytes");
            specs[i] = .{ .url = url };
            continue;
        }
        if (std.mem.eql(u8, kind, "image_base64")) {
            const data = stringField(part.object, "data");
            const snake = stringField(part.object, "media_type");
            const camel = stringField(part.object, "mediaType");
            const media_type = if (snake.len > 0) snake else camel;
            if (!std.mem.startsWith(u8, media_type, "image/"))
                return fail(root, "image_base64 needs an image/* media_type");
            const bytes = std.base64.standard.Decoder.calcSizeForSlice(data) catch
                return fail(root, "image_base64 data is not valid base64");
            if (bytes == 0 or bytes > vision.max_staged_image_bytes)
                return fail(root, "image_base64 is empty or exceeds the staged-image limit");
            {
                const scratch = root.gpa.alloc(u8, bytes) catch
                    return fail(root, "could not validate remote image data");
                defer root.gpa.free(scratch);
                std.base64.standard.Decoder.decode(scratch, data) catch
                    return fail(root, "image_base64 data is not valid base64");
            }
            specs[i] = .{ .base64 = .{ .media_type = media_type, .data = data } };
            continue;
        }
        return fail(root, "request image type must be image_url or image_base64");
    }

    const prior_len = root.pending_image_len;
    const prior_latest = root.pending_image;
    for (specs[0..parts.len]) |spec| {
        const image: vision.PendingImage = switch (spec) {
            .url => |url| .{
                .media_type = "",
                .b64 = "",
                .url = root.arena.dupe(u8, url) catch {
                    root.pending_image_len = prior_len;
                    root.pending_image = prior_latest;
                    return fail(root, "could not retain remote image URL");
                },
                .label = "remote URL",
            },
            .base64 => |b| .{
                .media_type = root.arena.dupe(u8, b.media_type) catch {
                    root.pending_image_len = prior_len;
                    root.pending_image = prior_latest;
                    return fail(root, "could not retain remote image media type");
                },
                .b64 = root.arena.dupe(u8, b.data) catch {
                    root.pending_image_len = prior_len;
                    root.pending_image = prior_latest;
                    return fail(root, "could not retain remote image data");
                },
                .label = "remote image",
            },
        };
        vision_queue.stage(root, image);
    }
    return true;
}
