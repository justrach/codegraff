//! The registry's image inbox (#1866): every image a tool batch stages waits
//! here for the batch checkpoint, which hands the lot to the next model
//! request.
//!
//! It used to be one optional slot. Two image reads in one batch raced for
//! it: the first to finish was attached and the other came back as an
//! ordinary result saying "not attached", so a before/after comparison
//! reached the model as one picture.
//!
//! The contract now: a batch may queue up to `cap` images and `byte_budget`
//! of base64 between them. Each one admitted is delivered once, in the order
//! the model made the calls: parallel reads finish in any order, so each
//! image carries its call's position in the batch and the drain sorts by it.
//! One that does not fit is refused as a tool error naming the limit, never
//! dropped under a successful result. The transition table
//! is `Graff.ImageDelivery` in lean-proofs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const PendingImage = @import("vision.zig").PendingImage;

/// The agent-side queue's own ceiling (`vision_queue.cap`): an image the
/// inbox admits always has a slot to land in.
pub const cap = 16;

/// Base64 bytes one batch may queue. Each image is already under the
/// per-image limit; this keeps a full batch under the 32 MB the strictest
/// provider accepts for a whole request, with room left for the history.
pub const byte_budget: usize = 24 * 1024 * 1024;

pub const Verdict = enum { queued, full, over_budget };

/// The position of an image staged outside a tool batch. It sorts after
/// every batch call and keeps its arrival order among its own kind.
pub const unsequenced: u32 = std.math.maxInt(u32);

pub fn Queue(comptime slots: usize, comptime budget: usize) type {
    return struct {
        items: [slots]PendingImage = undefined,
        /// Each image's call position in the batch that staged it.
        seqs: [slots]u32 = undefined,
        len: usize = 0,
        bytes: usize = 0,

        const Self = @This();

        /// What `push` would answer for an image of `size` base64 bytes.
        pub fn admit(self: *const Self, size: usize) Verdict {
            if (self.len >= slots) return .full;
            if (self.bytes + size > budget) return .over_budget;
            return .queued;
        }

        pub fn push(self: *Self, img: PendingImage) Verdict {
            return self.pushAt(img, unsequenced);
        }

        /// Queue `img`, staged by the batch call at position `seq`.
        pub fn pushAt(self: *Self, img: PendingImage, seq: u32) Verdict {
            const verdict = self.admit(img.b64.len);
            if (verdict != .queued) return verdict;
            self.items[self.len] = img;
            self.seqs[self.len] = seq;
            self.len += 1;
            self.bytes += img.b64.len;
            return .queued;
        }

        /// Move every queued image into `out` in call order, and empty the
        /// queue. The sort is stable: images of one call, and unsequenced
        /// ones, keep the order they arrived in.
        pub fn drain(self: *Self, out: *[slots]PendingImage) []const PendingImage {
            const n = self.len;
            for (1..@max(n, 1)) |i| {
                const img = self.items[i];
                const seq = self.seqs[i];
                var j = i;
                while (j > 0 and self.seqs[j - 1] > seq) : (j -= 1) {
                    self.items[j] = self.items[j - 1];
                    self.seqs[j] = self.seqs[j - 1];
                }
                self.items[j] = img;
                self.seqs[j] = seq;
            }
            @memcpy(out[0..n], self.items[0..n]);
            self.len = 0;
            self.bytes = 0;
            return out[0..n];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn first(self: *const Self) ?PendingImage {
            return if (self.len == 0) null else self.items[0];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.bytes = 0;
        }
    };
}

pub const Inbox = Queue(cap, byte_budget);

/// The tool error for an image the inbox would not take. It names the limit
/// and the way out, so the model retries instead of reasoning without it.
pub fn refusal(gpa: Allocator, path: []const u8, verdict: Verdict) ![]u8 {
    return switch (verdict) {
        .queued => unreachable,
        .full => std.fmt.allocPrint(gpa, "Image could not be attached: {s} was not queued because {d} images are already waiting for the next model request, the most one request carries. Read it again in a later tool call, after those have been delivered.", .{ path, cap }),
        .over_budget => std.fmt.allocPrint(gpa, "Image could not be attached: {s} was not queued because the images already waiting for the next model request fill its {d} MB image budget. Read it again in a later tool call, after those have been delivered.", .{ path, byte_budget / (1024 * 1024) }),
    };
}

/// Move the registry's queued images to the caller and tell the registry
/// whether this model takes images at all: the registry sees the pixels but
/// has no route to the provider (#249). `reg` is a `*mcp.Registry`, taken as
/// anytype so this module stays out of the MCP client's imports. A text-only
/// model gets nothing: the images are dropped here rather than surfacing
/// several turns later, stripped of their context.
pub fn handoff(reg: anytype, supports_vision: bool, out: *[cap]PendingImage) []const PendingImage {
    reg.mutex.lockUncancelable(reg.io); // tools stage from agent pool threads
    defer reg.mutex.unlock(reg.io);
    reg.vision_capable = supports_vision;
    const imgs = reg.pending_images.drain(out);
    return if (supports_vision) imgs else imgs[0..0];
}

fn image(b64: []const u8) PendingImage {
    return .{ .media_type = "image/png", .b64 = b64, .label = b64 };
}

test "#1866: a batch of image reads is queued whole and drained in order" {
    var inbox: Inbox = .{};
    try std.testing.expectEqual(Verdict.queued, inbox.push(image("before")));
    try std.testing.expectEqual(Verdict.queued, inbox.push(image("after")));
    var out: [cap]PendingImage = undefined;
    const got = inbox.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("before", got[0].b64);
    try std.testing.expectEqualStrings("after", got[1].b64);
    try std.testing.expect(inbox.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), inbox.drain(&out).len); // delivered once
}

test "#1866: images drain in call order whatever order the reads finished in" {
    var inbox: Inbox = .{};
    _ = inbox.pushAt(image("third"), 2);
    _ = inbox.push(image("from outside a batch"));
    _ = inbox.pushAt(image("first"), 0);
    _ = inbox.pushAt(image("second"), 1);
    _ = inbox.pushAt(image("second again"), 1);
    var out: [cap]PendingImage = undefined;
    const got = inbox.drain(&out);
    const want = [_][]const u8{ "first", "second", "second again", "third", "from outside a batch" };
    try std.testing.expectEqual(want.len, got.len);
    for (got, want) |img, b64| try std.testing.expectEqualStrings(b64, img.b64);
}

test "#1866: an image past the count or byte limit is refused, and a drain makes room" {
    var inbox: Inbox = .{};
    for (0..cap) |_| try std.testing.expectEqual(Verdict.queued, inbox.push(image("x")));
    try std.testing.expectEqual(Verdict.full, inbox.push(image("x")));
    try std.testing.expectEqual(@as(usize, cap), inbox.len); // the refusal queued nothing
    var out: [cap]PendingImage = undefined;
    _ = inbox.drain(&out);
    try std.testing.expectEqual(Verdict.queued, inbox.push(image("x")));

    var tight: Queue(4, 10) = .{};
    try std.testing.expectEqual(Verdict.queued, tight.push(image("123456")));
    try std.testing.expectEqual(Verdict.over_budget, tight.push(image("12345")));
    try std.testing.expectEqual(Verdict.queued, tight.push(image("1234"))); // exactly the budget
    try std.testing.expectEqual(@as(usize, 10), tight.bytes);

    const a = std.testing.allocator;
    const full = try refusal(a, "after.png", .full);
    defer a.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "after.png") != null and std.mem.indexOf(u8, full, "Read it again") != null);
    const over = try refusal(a, "after.png", .over_budget);
    defer a.free(over);
    try std.testing.expect(std.mem.indexOf(u8, over, "24 MB") != null);
}

/// The `Graff.ImageDelivery` transition function, written again without the
/// queue's bookkeeping: lists of sizes and call positions, a refusal count,
/// and what each request received.
const Model = struct {
    const slots = 2;
    const budget = 3;
    queue: [slots]usize = undefined,
    calls: [slots]u32 = undefined,
    len: usize = 0,
    refused: usize = 0,
    delivered: usize = 0,

    fn stage(m: *Model, size: usize, call: u32) bool {
        var bytes: usize = 0;
        for (m.queue[0..m.len]) |s| bytes += s;
        if (m.len == slots or bytes + size > budget) {
            m.refused += 1;
            return false;
        }
        m.queue[m.len] = size;
        m.calls[m.len] = call;
        m.len += 1;
        return true;
    }

    /// The request's images: the queue in call order, ties in arrival order.
    /// Two slots, so one comparison is the whole sort.
    fn flush(m: *Model, out: *[slots]usize) []const usize {
        const n = m.len;
        @memcpy(out[0..n], m.queue[0..n]);
        if (n == 2 and m.calls[0] > m.calls[1]) std.mem.swap(usize, &out[0], &out[1]);
        m.delivered += n;
        m.len = 0;
        return out[0..n];
    }
};

test "#1866: the queue agrees with the ImageDelivery machine on every run of six events" {
    // Events: stage a 1-, 2- or 3-byte image, or flush. 4^6 runs cover every
    // reachable fill level and byte total of a 2-slot, 3-byte queue. A bigger
    // image comes from an earlier call, so arrival order and call order differ.
    const sizes = [_][]const u8{ "1", "22", "333" };
    var run: usize = 0;
    while (run < 4096) : (run += 1) {
        var q: Queue(Model.slots, Model.budget) = .{};
        var m: Model = .{};
        var staged: usize = 0;
        var delivered: usize = 0;
        var code = run;
        for (0..6) |_| {
            const event = code % 4;
            code /= 4;
            if (event == 3) {
                var out: [Model.slots]PendingImage = undefined;
                var want_buf: [Model.slots]usize = undefined;
                const got = q.drain(&out);
                const want = m.flush(&want_buf);
                try std.testing.expectEqual(want.len, got.len);
                for (got, want) |img, size| try std.testing.expectEqual(size, img.b64.len);
                delivered += got.len;
            } else {
                staged += 1;
                const call: u32 = @intCast(2 - event);
                const admitted = m.stage(sizes[event].len, call);
                try std.testing.expectEqual(admitted, q.pushAt(image(sizes[event]), call) == .queued);
            }
            try std.testing.expectEqual(m.len, q.len);
            // Nothing is lost: every staged image is delivered, waiting, or refused.
            try std.testing.expectEqual(staged, delivered + q.len + m.refused);
            try std.testing.expect(q.len <= Model.slots and q.bytes <= Model.budget);
        }
    }
}

test "handoff: queued images reach a vision model once; a text-only model gets none (#249)" {
    const mcp = @import("mcp.zig");
    var reg = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    var out: [cap]PendingImage = undefined;

    // Text-only model: the fact is pushed to the registry and the images are
    // dropped rather than surfacing turns later out of context.
    _ = reg.pending_images.push(image("aGVsbG8="));
    try std.testing.expectEqual(@as(usize, 0), handoff(&reg, false, &out).len);
    try std.testing.expect(!reg.vision_capable);
    try std.testing.expect(reg.pending_images.isEmpty());

    // Vision model: all of them, in order, and the inbox is emptied so one
    // image is never attached to two requests.
    _ = reg.pending_images.push(image("aGVsbG8="));
    _ = reg.pending_images.push(image("R0lG"));
    const got = handoff(&reg, true, &out);
    try std.testing.expect(reg.vision_capable);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("aGVsbG8=", got[0].b64);
    try std.testing.expectEqualStrings("R0lG", got[1].b64);
    try std.testing.expectEqual(@as(usize, 0), handoff(&reg, true, &out).len);
}
