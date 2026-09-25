//! Frontend-owned permission input; the engine owns which calls need consent.
const std = @import("std");
pub const Decision = enum { allow_once, allow_always, deny };
pub const Request = struct { call_id: []const u8, tool: []const u8, description: []const u8, allow_always: bool = false, always_label: []const u8 = "Always allow this permission", input: ?std.json.Value = null };
pub const Handler = struct {
    ctx: *anyopaque,
    request: *const fn (*anyopaque, std.Io, Request) Decision,
    pub fn ask(self: Handler, io: std.Io, req: Request) Decision {
        return self.request(self.ctx, io, req);
    }
};
threadlocal var current: ?Handler = null;
pub fn bind(handler: ?Handler) ?Handler {
    const previous = current;
    current = handler;
    return previous;
}
pub fn get() ?Handler {
    return current;
}
