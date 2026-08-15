//! #249 leftover: a first-class `view_image` tool. read_file already stages
//! pixels as a side effect; this names the intent so a model does not have
//! to infer vision from a path.

const std = @import("std");
const Io = std.Io;

const tools = @import("tools.zig");
const vision = @import("vision.zig");

pub const name = "view_image";
pub var available = false; // set at boot when the session model is a VLM
pub const desc = "Attach a local png/jpg/gif/webp as visual input on the next model turn.";
pub const schema =
    \\{"type": "object", "properties": {"path": {"type": "string", "description": "Filesystem path of the image"}}, "required": ["path"]}
;

pub fn exec(ctx: tools.ToolCtx, input: std.json.Value) !tools.ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const path = tools.strField(input, "path") orelse return tools.missingArg(gpa, "path");
    if (!@import("approvals.zig").confinedPath(path)) return tools.outsideCwd(gpa, path);
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return .{
        .text = try std.fmt.allocPrint(gpa, "view_image: cannot read {s}", .{path}),
        .is_error = true,
    };
    if (!vision.visionCapable(ctx.provider)) return .{
        .text = try std.fmt.allocPrint(gpa, "view_image: the active model does not accept images ({s}, {d} bytes)", .{ vision.imageMediaType(path), st.size }),
        .is_error = true,
    };
    const reg = ctx.registry orelse return .{
        .text = try gpa.dupe(u8, "view_image: no session registry to attach to"),
        .is_error = true,
    };
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(5 * 1024 * 1024)) catch return .{
        .text = try std.fmt.allocPrint(gpa, "view_image: failed to read {s}", .{path}),
        .is_error = true,
    };
    defer gpa.free(data);
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(data.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, data);
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    if (reg.pending_image != null) return .{
        .text = try gpa.dupe(u8, "view_image: another image is already queued for the next turn"),
        .is_error = true,
    };
    const arena = reg.arena();
    const media = vision.imageMediaType(path);
    reg.pending_image = .{
        .media_type = try arena.dupe(u8, media),
        .b64 = try arena.dupe(u8, b64),
        .label = try arena.dupe(u8, path),
    };
    return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to your next turn]", .{ media, data.len }),
    };
}

test "#249: view_image name is advertised as a first-class tool" {
    try std.testing.expectEqualStrings("view_image", name);
    try std.testing.expect(std.mem.indexOf(u8, schema, "path") != null);
}
