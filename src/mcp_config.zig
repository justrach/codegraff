//! User-level (global) MCP configuration and its merge with the workspace file
//! (#345).
//!
//! `mcpServers` used to come from the repository `.mcp.json` alone, so a remote
//! server a user wants everywhere — DeepWiki, say — had to be re-declared in
//! every checkout. The global file uses the identical `{"mcpServers": {...}}`
//! schema and is merged with the project file at every read site, with PROJECT
//! ENTRIES WINNING on a name conflict: a repository's own config must never be
//! silently shadowed by whatever the user happens to have set up globally.
//! Names neither file defines are filled from in-place plugin trees and other
//! harness configs (ADR 0007) — still below this merge, still consent-gated.
//!
//! The file lives under `~/.codegraff/`, this repo's home-scoped convention
//! (see models_cache.zig and router_catalog.zig), rather than inventing a new
//! `~/.graff/`. `GRAFF_MCP_CONFIG` overrides the location with an absolute
//! path, which is also what keeps the tests below off the real `$HOME`.
//!
//! Global entries are NOT more trusted than project ones: they flow through the
//! same untrusted-server consent gate at startup and the same in-session
//! `/mcp trust`. Writes (`graff mcp add`, `/mcp add`) stay project-local — this
//! module only ever reads.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const plugins = @import("plugins.zig");

/// Home-relative location of the user-level config.
pub const global_rel_path = ".codegraff/mcp.json";

/// Absolute-path override for the global config.
pub const path_env = "GRAFF_MCP_CONFIG";

/// A home-scoped path some other MCP clients read and graff does not. Startup
/// mentions it once when it exists, so a config a user wrote is never ignored
/// in complete silence.
pub const unsupported_rel_path = ".mcpconfig.json";

/// The merged `mcpServers` set plus the provenance callers need to describe it.
pub const Merged = struct {
    /// Every server graff should consider: plugins/foreign, then global, then project.
    servers: std.json.ObjectMap = .empty,
    /// The workspace half on its own, so `graff mcp list` can tag an entry the
    /// project does not define as `(global)`.
    project: std.json.ObjectMap = .empty,
    /// Whether either file existed. `mcp.Registry.init` returns null (MCP stays
    /// optional) only when neither did.
    found: bool = false,
    /// A file that existed but was not `{"mcpServers": {...}}`. The other half
    /// still loads: one bad file must not disable MCP everywhere.
    invalid_project: bool = false,
    invalid_global: bool = false,

    /// Whether `name` is defined by the global file only.
    pub fn isGlobalOnly(self: Merged, name: []const u8) bool {
        return self.project.get(name) == null;
    }
};

/// Resolve the user-level config path: `GRAFF_MCP_CONFIG` when set (an absolute
/// path, mainly for tests and sandboxes), else `{home}/.codegraff/mcp.json`.
/// Null means simply "no global config" — never an error.
pub fn globalPath(arena: Allocator, home: []const u8, environ_map: anytype) ?[]const u8 {
    if (environ_map.get(path_env)) |override| if (override.len > 0) return override;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/" ++ global_rel_path, .{home}) catch null;
}

/// Whether `GRAFF_MCP_CONFIG` points at a real path. An existing, valid, empty
/// override is a wholesale MCP off-switch (#549); the default global file is
/// never that — relocating `~/.codegraff/mcp.json` still merges the project.
pub fn isEnvOverride(environ_map: anytype) bool {
    if (environ_map.get(path_env)) |override| return override.len > 0;
    return false;
}

/// Read `path` and return its `mcpServers` object. Best-effort throughout:
/// only "no such file" reads as absent, everything else reads as invalid (and
/// empty) so a caller can say which file it could not use.
fn readServers(io: Io, arena: Allocator, dir: Io.Dir, path: []const u8, found: *bool, invalid: *bool) std.json.ObjectMap {
    const text = dir.readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .empty,
        // A directory, a permission denial or a file over the 1 MiB limit is a
        // config the user meant graff to read. Silently treating it as "no
        // config" is how a whole MCP setup disappears without a word.
        else => {
            found.* = true;
            invalid.* = true;
            return .empty;
        },
    };
    found.* = true;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch {
        invalid.* = true;
        return .empty;
    };
    if (parsed != .object) {
        invalid.* = true;
        return .empty;
    }
    const servers = parsed.object.get("mcpServers") orelse return .empty;
    if (servers != .object) {
        invalid.* = true;
        return .empty;
    }
    return servers.object;
}

/// Merge the user-level and workspace configs into one `mcpServers` set. `dir`
/// is the workspace root (`Io.Dir.cwd()` in production, a tmp dir in tests) and
/// `global_path` may be absolute — an absolute path ignores the directory
/// handle it is opened through. Never fails: a missing or malformed file simply
/// contributes nothing. Values stay arena-allocated, like the rest of the MCP
/// config handling.
///
/// `global_is_override` is true only when `GRAFF_MCP_CONFIG` selected the
/// path. A file that exists, parses, and lists no servers is then a wholesale
/// off-switch (pty/harness): the project `.mcp.json` and plugin trees do not
/// merge in. A *populated* override still merges, so relocating the global
/// file is unchanged. A missing or invalid override is not an off-switch.
pub fn load(io: Io, arena: Allocator, dir: Io.Dir, project_path: []const u8, global_path: ?[]const u8, home: []const u8, global_is_override: bool) Merged {
    var merged: Merged = .{};
    const global = if (global_path) |p|
        readServers(io, arena, dir, p, &merged.found, &merged.invalid_global)
    else
        std.json.ObjectMap.empty;
    // #549: existing + valid + empty override → MCP stays off. `found` is
    // already true (the file existed), so Registry.init does not treat this
    // as "no config" and then pick up a project file on a later read.
    if (global_is_override and merged.found and !merged.invalid_global and global.count() == 0)
        return merged;

    merged.project = readServers(io, arena, dir, project_path, &merged.found, &merged.invalid_project);

    // Global first, project second: the later `put` for a name overwrites, so
    // the workspace keeps the final say over its own tooling.
    var global_it = global.iterator();
    while (global_it.next()) |entry| merged.servers.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch return merged;
    var project_it = merged.project.iterator();
    while (project_it.next()) |entry| merged.servers.put(arena, entry.key_ptr.*, entry.value_ptr.*) catch return merged;
    // Plugin / Claude / Cursor / Grok configs fill names still missing. They
    // never beat a graff file. `home` empty keeps tests off the real $HOME.
    plugins.mergeMcp(io, arena, home, dir, &merged.servers, &merged.found);
    return merged;
}

/// Name every config file that existed but could not be used. A file graff
/// cannot parse must never read back as "nothing configured" — that is exactly
/// the case where the user needs to be told which file to look at, and with two
/// files in play a bad project file would otherwise leave a healthy-looking
/// global-only listing behind. `prefix`/`suffix` carry the caller's styling
/// (dim/reset at startup, empty for the plain CLI).
pub fn reportInvalid(merged: Merged, w: *Io.Writer, project_path: []const u8, global_path: ?[]const u8, prefix: []const u8, suffix: []const u8) !void {
    if (merged.invalid_project) try w.print("{s}{s}" ++ invalid_complaint ++ "{s}\n", .{ prefix, project_path, suffix });
    if (merged.invalid_global) try w.print("{s}{s}" ++ invalid_complaint ++ "{s}\n", .{ prefix, global_path orelse "", suffix });
}

/// What follows the path in that report. Public because startup says the same
/// thing as a typed notice now (#429) rather than printing it here.
pub const invalid_complaint = " is not valid MCP config (expected a JSON object with \"mcpServers\"); ignoring it.";

/// Whether `{home}/.mcpconfig.json` exists. That path belongs to other MCP
/// clients and graff never reads it, so startup says so once instead of leaving
/// the user to wonder why their servers never appeared.
pub fn unsupportedConfigPresent(io: Io, arena: Allocator, home: []const u8) bool {
    if (home.len == 0) return false;
    const path = std.fmt.allocPrint(arena, "{s}/" ++ unsupported_rel_path, .{home}) catch return false;
    if (Io.Dir.cwd().statFile(io, path, .{})) |_| return true else |_| return false;
}

const testing = std.testing;

/// Stands in for `std.process.Environ.Map` — `globalPath` only ever calls
/// `get`, and a real environment would not be hermetic.
const TestEnv = struct {
    override: ?[]const u8 = null,
    fn get(self: TestEnv, key: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, key, path_env)) self.override else null;
    }
};

/// Both halves are read through the tmp dir handle, so no test touches `$HOME`
/// or the real workspace.
fn loadTmp(arena: Allocator, dir: Io.Dir) Merged {
    return load(testing.io, arena, dir, ".mcp.json", "global.json", "", false);
}

fn loadTmpOverride(arena: Allocator, dir: Io.Dir) Merged {
    return load(testing.io, arena, dir, ".mcp.json", "global.json", "", true);
}

test "global MCP path prefers the env override and otherwise lives under ~/.codegraff" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/home/alice/.codegraff/mcp.json", globalPath(arena, "/home/alice", TestEnv{}).?);
    try testing.expectEqualStrings("/tmp/mcp.json", globalPath(arena, "/home/alice", TestEnv{ .override = "/tmp/mcp.json" }).?);
    // An empty override falls back rather than resolving to the file "".
    try testing.expectEqualStrings("/home/alice/.codegraff/mcp.json", globalPath(arena, "/home/alice", TestEnv{ .override = "" }).?);
    try testing.expect(isEnvOverride(TestEnv{ .override = "/tmp/mcp.json" }));
    try testing.expect(!isEnvOverride(TestEnv{ .override = "" }));
    try testing.expect(!isEnvOverride(TestEnv{}));
    // No HOME and no override is "no global config", not a crash.
    try testing.expect(globalPath(arena, "", TestEnv{}) == null);
}

test "project MCP entries win over global entries with the same name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://global.example/mcp\"}}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://project.example/mcp\"}}}" });

    const merged = loadTmp(arena_state.allocator(), tmp.dir);
    try testing.expect(merged.found);
    try testing.expectEqual(@as(usize, 1), merged.servers.count());
    try testing.expectEqualStrings("https://project.example/mcp", merged.servers.get("deepwiki").?.object.get("url").?.string);
    try testing.expect(!merged.isGlobalOnly("deepwiki"));
}

test "merged MCP set carries global-only and project-only servers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://mcp.deepwiki.com/mcp\"}}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });

    const merged = loadTmp(arena_state.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 2), merged.servers.count());
    try testing.expectEqualStrings("https://mcp.deepwiki.com/mcp", merged.servers.get("deepwiki").?.object.get("url").?.string);
    try testing.expectEqualStrings("./srv", merged.servers.get("local").?.object.get("command").?.string);
    try testing.expect(merged.isGlobalOnly("deepwiki"));
    try testing.expect(!merged.isGlobalOnly("local"));
}

test "no MCP config anywhere is absent, not merely empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const merged = loadTmp(arena_state.allocator(), tmp.dir);
    // `found` false is what keeps `mcp.Registry.init` returning null.
    try testing.expect(!merged.found);
    try testing.expectEqual(@as(usize, 0), merged.servers.count());
    try testing.expect(!merged.invalid_project and !merged.invalid_global);
}

test "a malformed MCP config does not take the other half down" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bad_global = testing.tmpDir(.{});
    defer bad_global.cleanup();
    try bad_global.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{ not json" });
    try bad_global.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });
    const global_broken = loadTmp(arena, bad_global.dir);
    try testing.expect(global_broken.invalid_global and !global_broken.invalid_project);
    try testing.expectEqual(@as(usize, 1), global_broken.servers.count());
    try testing.expect(global_broken.servers.get("local") != null);

    var bad_project = testing.tmpDir(.{});
    defer bad_project.cleanup();
    // A well-formed file whose `mcpServers` is the wrong shape counts as
    // invalid too — otherwise a typo reads as "no servers configured".
    try bad_project.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":[]}" });
    try bad_project.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://mcp.deepwiki.com/mcp\"}}}" });
    const project_broken = loadTmp(arena, bad_project.dir);
    try testing.expect(project_broken.invalid_project and !project_broken.invalid_global);
    try testing.expectEqual(@as(usize, 1), project_broken.servers.count());
    try testing.expect(project_broken.isGlobalOnly("deepwiki"));
}

test "an unreadable MCP config is invalid, not absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A directory where a file was expected: the read fails with something other
    // than FileNotFound, which must not read back as "no global config".
    try tmp.dir.createDir(testing.io, "global.json", .default_dir);

    const merged = loadTmp(arena_state.allocator(), tmp.dir);
    try testing.expect(merged.found and merged.invalid_global);
    try testing.expect(!merged.invalid_project);
    try testing.expectEqual(@as(usize, 0), merged.servers.count());
}

test "a valid empty GRAFF_MCP_CONFIG override is a wholesale MCP off-switch (#549)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{\"mcpServers\":{}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });

    const off = loadTmpOverride(arena_state.allocator(), tmp.dir);
    try testing.expect(off.found);
    try testing.expect(!off.invalid_global and !off.invalid_project);
    try testing.expectEqual(@as(usize, 0), off.servers.count());
    try testing.expectEqual(@as(usize, 0), off.project.count());

    // The default global file is never that switch: an empty ~/.codegraff/mcp.json
    // still merges the project (relocating the global file stays a merge).
    const merged = loadTmp(arena_state.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 1), merged.servers.count());
    try testing.expect(merged.servers.get("local") != null);
}

test "a populated GRAFF_MCP_CONFIG override still merges the project file (#549)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://mcp.deepwiki.com/mcp\"}}}" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });

    const merged = loadTmpOverride(arena_state.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 2), merged.servers.count());
    try testing.expect(merged.isGlobalOnly("deepwiki"));
    try testing.expect(!merged.isGlobalOnly("local"));
}

test "a missing or invalid GRAFF_MCP_CONFIG override is not an off-switch (#549)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var missing = testing.tmpDir(.{});
    defer missing.cleanup();
    try missing.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });
    const no_file = loadTmpOverride(arena, missing.dir);
    try testing.expect(no_file.servers.get("local") != null);

    var broken = testing.tmpDir(.{});
    defer broken.cleanup();
    try broken.dir.writeFile(testing.io, .{ .sub_path = "global.json", .data = "{ not json" });
    try broken.dir.writeFile(testing.io, .{ .sub_path = ".mcp.json", .data = "{\"mcpServers\":{\"local\":{\"command\":\"./srv\"}}}" });
    const bad = loadTmpOverride(arena, broken.dir);
    try testing.expect(bad.invalid_global);
    try testing.expect(bad.servers.get("local") != null);
}
