//! Explicit, non-overwriting Claude conversation import (#1495).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const conversation = @import("adopt_conversation.zig");
const session = @import("session_index.zig");

pub const Report = struct { imported: usize = 0, skipped: usize = 0, failed: usize = 0 };

pub fn projectSlug(a: Allocator, cwd: []const u8) ![]const u8 {
    const slug = try a.dupe(u8, cwd);
    for (slug) |*ch| if (!std.ascii.isAlphanumeric(ch.*)) {
        ch.* = '-';
    };
    return slug;
}

pub fn run(io: Io, a: Allocator, home: []const u8, cwd: []const u8) !Report {
    if (home.len == 0) return .{};
    return runConfig(io, a, try std.fmt.allocPrint(a, "{s}/.claude", .{home}), cwd, null, null);
}

/// Import just one transcript, without adopting hooks, skills or MCP settings.
pub fn importOne(io: Io, a: Allocator, config: []const u8, cwd: []const u8, id: []const u8, project_name: ?[]const u8) ![]const u8 {
    if (!session.validSessionName(id) or std.mem.startsWith(u8, id, "agent-")) return error.InvalidSessionName;
    const base = try std.fmt.allocPrint(a, "claude-{s}", .{id});
    if (!session.validSessionName(base)) return error.InvalidSessionName;
    const report = try runConfig(io, a, config, cwd, id, project_name);
    if (report.imported + report.skipped == 0 or report.failed > 0) return error.ClaudeImportFailed;
    return base;
}

fn runConfig(io: Io, a: Allocator, config: []const u8, cwd: []const u8, only: ?[]const u8, project_name: ?[]const u8) !Report {
    var report: Report = .{};
    const projects = try std.fmt.allocPrint(a, "{s}/projects", .{config});
    var dir = Io.Dir.cwd().openDir(io, projects, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return report;
        return err;
    };
    defer dir.close(io);
    if (project_name) |name| {
        if (!session.validSessionName(name) or name.len > 64) return error.InvalidSessionName;
        try importProject(io, a, dir, name, cwd, only, &report);
        return report;
    }
    const slug = try projectSlug(a, cwd);
    if (slug.len <= 200) {
        try importProject(io, a, dir, slug, cwd, only, &report);
    } else {
        // Claude appends an implementation-specific hash after truncating long
        // names. Validate the transcript cwd instead of guessing that hash.
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, slug[0..200]))
                try importProject(io, a, dir, entry.name, cwd, only, &report);
        }
    }
    return report;
}

fn importProject(io: Io, a: Allocator, projects: Io.Dir, name: []const u8, cwd: []const u8, only: ?[]const u8, report: *Report) !void {
    var project = projects.openDir(io, name, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer project.close(io);
    var idx_scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer idx_scratch.deinit();
    const idx_alloc = idx_scratch.allocator();
    const index_data = project.readFileAlloc(io, "sessions-index.json", idx_alloc, .limited(8 << 20)) catch "";
    const index = std.json.parseFromSliceLeaky(std.json.Value, idx_alloc, index_data, .{}) catch .null;
    var workspace = try Io.Dir.cwd().openDir(io, cwd, .{});
    defer workspace.close(io);
    var it = project.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl") or std.mem.startsWith(u8, entry.name, "agent-")) continue;
        const id = entry.name[0 .. entry.name.len - ".jsonl".len];
        if (only) |wanted| if (!std.mem.eql(u8, id, wanted)) continue;
        if (!session.validSessionName(id)) continue;
        const base = try std.fmt.allocPrint(a, "claude-{s}", .{id});
        if (!session.validSessionName(base)) {
            report.failed += 1;
            continue;
        }
        const dest = try session.sessionPath(a, base);
        if (workspace.statFile(io, dest, .{}) catch null != null) {
            report.skipped += 1;
            continue;
        }
        // Release JSONL/parser allocations after each file, including skips.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const temp = scratch.allocator();
        const data = project.readFileAlloc(io, entry.name, temp, .limited(64 << 20)) catch {
            report.failed += 1;
            continue;
        };
        var converted = conversation.convert(temp, data, cwd) catch |err| {
            if (err != error.EmptyTranscript and err != error.OtherWorkspace) report.failed += 1;
            continue;
        };
        applyIndex(&converted, index, id);
        if (converted.updated_ms == 0) {
            if (project.statFile(io, entry.name, .{})) |st| {
                converted.updated_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
            } else |_| {}
        }
        var out: Io.Writer.Allocating = .init(temp);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        // List metadata must precede the potentially large messages array.
        try json.write(.{
            .format_version = @import("session_version.zig").current, // ADR 0319
            .title = converted.title,
            .updated_ms = converted.updated_ms,
            .workspace = cwd,
            .provider = "anthropic",
            .model = converted.model,
            .imported_from = "claude",
            .messages = std.json.Value{ .array = converted.messages },
        });
        const bytes = out.written();
        if (bytes.len > 8 << 20) {
            report.failed += 1;
            continue;
        }
        @import("graff_dir.zig").ensure(io, workspace);
        try workspace.createDirPath(io, session.sessions_dir);
        // Exclusive create also protects against another importer racing us.
        var file = workspace.createFile(io, dest, .{ .exclusive = true }) catch |err| {
            if (err == error.PathAlreadyExists) report.skipped += 1 else report.failed += 1;
            continue;
        };
        defer file.close(io);
        var writer = file.writer(io, &.{});
        writer.interface.writeAll(bytes) catch {
            workspace.deleteFile(io, dest) catch {};
            report.failed += 1;
            continue;
        };
        report.imported += 1;
    }
}

fn applyIndex(result: *conversation.Conversation, index: std.json.Value, id: []const u8) void {
    if (index != .object) return;
    const entries = index.object.get("entries") orelse return;
    if (entries != .array) return;
    for (entries.array.items) |entry| {
        if (entry != .object) continue;
        const sid = conversation.string(entry.object, "sessionId") orelse continue;
        if (!std.mem.eql(u8, sid, id)) continue;
        if (result.title_priority < 3) {
            if (conversation.string(entry.object, "customTitle")) |title| {
                result.title = title;
                result.title_priority = 3;
            }
        }
        if (result.title_priority < 1) {
            if (conversation.string(entry.object, "summary")) |title| result.title = title;
        }
        if (conversation.string(entry.object, "modified")) |ts| result.updated_ms = @max(result.updated_ms, conversation.timestampMs(ts) orelse 0);
        return;
    }
}
