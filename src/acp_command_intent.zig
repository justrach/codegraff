//! Harness carries completion acceptance separately from prompt text. Legacy
//! ACP clients retain their command syntax; explicit false means literal prose.
const std = @import("std");

pub fn selected(params: ?std.json.Value) bool {
    const root = params orelse return true;
    if (root != .object) return true;
    const meta = root.object.get("_meta") orelse return true;
    if (meta != .object) return true;
    const value = meta.object.get("harness/command") orelse return true;
    return value == .bool and value.bool;
}
