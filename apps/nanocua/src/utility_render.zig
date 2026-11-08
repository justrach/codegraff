//! Headless utility-eval adapter: real tree formatting, synthetic nodes only.
//! No nanoui, AX, input, app launch, or desktop access is linked here.
const std = @import("std");
const tree = @import("tree.zig");
const tools = @import("tools.zig");

const Item = struct { node: tree.Node, depth: usize = 0 };
const Request = struct {
    catalog: bool = false,
    nodes: []const Item = &.{},
    options: ?std.json.Value = null,
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var input: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try input.appendSlice(a, buf[0..@intCast(n)]);
        if (input.items.len > 1024 * 1024) return error.RequestTooLarge;
    }
    const req = try std.json.parseFromSliceLeaky(Request, a, input.items, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    if (req.catalog) {
        try tools.writeList(&out.writer);
        return send(out.written());
    }
    const opts = tree.Options.fromArgs(tools.Args.of(req.options));
    try out.writer.writeAll("app \"Fixture\" pid 1\n");
    var indices: std.ArrayList(usize) = .empty;
    var child_depth: [65]usize = @splat(0);
    for (req.nodes, 0..) |item, index| {
        if (item.depth >= child_depth.len) return error.DepthExceeded;
        const depth = if (item.depth == 0) 0 else child_depth[item.depth - 1];
        child_depth[item.depth] = depth;
        if (!opts.includes(item.node)) continue;
        if (indices.items.len >= opts.max_nodes) break;
        try indices.append(a, index);
        try opts.write(&out.writer, item.node, @intCast(indices.items.len), depth);
        child_depth[item.depth] += 1;
    }
    if (opts.interactive_only) try out.writer.writeAll("(controls only; static text omitted)\n");
    const result = try std.json.Stringify.valueAlloc(a, .{ .text = out.written(), .indices = indices.items }, .{});
    try send(result);
}

fn send(text: []const u8) !void {
    var pos: usize = 0;
    while (pos < text.len) {
        const n = std.c.write(1, text.ptr + pos, text.len - pos);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
}
