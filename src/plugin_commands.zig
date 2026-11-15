//! Shared explicit-user REPL/ACP and CLI plugin commands.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plugins = @import("plugins.zig");
const scan = @import("plugin_scan.zig");
const management = @import("plugin_management.zig");

pub const usage = "plugins [list|load <name>|enable <id>|disable <id>|register <directory>|install <directory>|remove <directory>|unregister <directory>|reload]\n";

pub fn run(io: Io, arena: Allocator, home: []const u8, project: Io.Dir, rest: []const u8, out: *Io.Writer) !bool {
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const verb = rest[0..split];
    const arg = std.mem.trim(u8, rest[split..], " \t");
    const enable = std.mem.eql(u8, verb, "enable");
    const disable = std.mem.eql(u8, verb, "disable");
    const register = std.mem.eql(u8, verb, "register") or std.mem.eql(u8, verb, "install");
    const remove = std.mem.eql(u8, verb, "remove") or std.mem.eql(u8, verb, "unregister");
    if (enable or disable or register or remove) {
        if (arg.len == 0) {
            try out.writeAll(usage);
        } else {
            mutate(io, arena, project, arg, enable, disable, register) catch |err| {
                try out.print("plugin management failed: {t}\n", .{err});
                try out.flush();
                return true;
            };
            try out.writeAll("plugin configuration saved; takes effect at the next safe user/catalog boundary. Foreign hooks are never run; native runtime trust is separate.\n");
        }
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, verb, "reload") and arg.len == 0) {
        management.requestReload();
        try out.writeAll("plugin reload queued for the next safe user/catalog boundary.\n");
        try out.flush();
        return true;
    }
    if (rest.len > 0 and !(std.mem.eql(u8, rest, "list") or (std.mem.eql(u8, verb, "load") and arg.len > 0))) {
        try out.writeAll(usage);
        try out.flush();
        return true;
    }
    const state = management.load(io, arena, project) catch |err| {
        try out.print("plugin management failed: {t}\n", .{err});
        try out.flush();
        return true;
    };
    for (state.disabled) |id| try out.print("  {s} [disabled]\n", .{id});
    if (plugins.disabled) {
        try out.writeAll("plugins disabled (GRAFF_NO_PLUGINS). unset it and restart to scan Cursor/Claude/Grok/Codex trees.\n");
        try out.flush();
        return true;
    }
    const list = plugins.discover(io, arena, if (home.len > 0) home else null, project);
    if (std.mem.eql(u8, verb, "load")) {
        const want = arg;
        for (list) |p| {
            const id = try management.foreignId(arena, p.origin, p.name);
            if (!std.ascii.eqlIgnoreCase(p.name, want) and !std.mem.eql(u8, id, want)) continue;
            try out.print("{s}  [{s}/{s}]  {s}\n", .{ p.name, p.origin, if (p.personal) "user" else "project", p.path });
            if (p.commands) try out.writeAll("  commands/*.md load as skills (Claude default)\n");
            if (p.root_skill) |rs| try out.print("  root skill: {s}\n", .{rs.name});
            if (p.skills) try out.writeAll("  skills: on-demand via the skill tool / /skills\n");
            if (p.agents) try out.writeAll("  agents: in the fleet\n");
            if (p.mcp) try out.writeAll("  mcp: in the merge (needs /mcp trust or --yolo)\n");
            try out.print("hooks are not run. {s}\n", .{scan.format(arena)});
            try out.flush();
            return true;
        }
        try out.print("no plugin named '{s}'. /plugins lists what graff is reading.\n", .{want});
        try out.flush();
        return true;
    }
    if (list.len == 0) {
        try out.print("no plugins discovered ({d}ms, {d} dirs). graff reads Claude/Cursor/Grok/Codex trees in place (skills/, commands/, agents/, mcp.json, root SKILL.md). nothing to copy; GRAFF_NO_PLUGINS=1 disables.\n", .{ scan.last.ms, scan.last.visits });
        try out.flush();
        return true;
    }
    try out.print("{s} (in-place, Claude layout, not copied):\n", .{scan.format(arena)});
    for (list) |p| {
        try out.print("  {s}  [{s}/{s}] id={s}/{s}", .{ p.name, p.origin, if (p.personal) "user" else "project", p.origin, p.name });
        if (p.skills) try out.writeAll(" skills");
        if (p.commands) try out.writeAll(" commands");
        if (p.agents) try out.writeAll(" agents");
        if (p.mcp) try out.writeAll(" mcp");
        try out.print("  {s}\n", .{p.path});
    }
    try out.writeAll("skills and commands/*.md load on demand (skill tool / /skills). /plugins load <name> shows one. MCP still needs /mcp trust or --yolo.\n");
    try out.flush();
    return true;
}

fn mutate(io: Io, arena: Allocator, project: Io.Dir, arg: []const u8, enable: bool, disable: bool, register: bool) !void {
    if (enable or disable) {
        try management.setEnabled(io, arena, project, arg, enable);
    } else if (register) {
        _ = try management.register(io, arena, project, arg);
    } else {
        try management.remove(io, arena, project, arg);
    }
}
