//! Codex-style optional skills + companion-server subsystem: the
//! skills_registry/companion_servers/mcp_notes config tables, install-status
//! detection (binOnPath/skillInstalled/skillActive), per-skill/companion
//! opt-out persistence (.harness/settings.json), the companion tool-name
//! classifiers (trusted/read-only/native-name lookup), and the codedb-pro
//! license probe + system-prompt note picker. Split out of main.zig (600-line
//! goal). companionRoute/companionNativeFallback stay in main.zig — they take
//! ToolCtx/ToolCall, which are still main-resident (the tools/exec region
//! hasn't been extracted yet), and are only called from execTool's routing
//! path there. Back-imports main for runCapped (= jobs.runCapped) and the LIVE
//! mutable globals g_path_env/g_skill_disabled/
//! g_companion_disabled — these stay `pub var` in main.zig (its own /skills
//! command handler and startup code read/write them directly too), never
//! aliased by value here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");

const main_mod = @import("main.zig");
// Only the settings-file location, never the approval session (#422 ratchet).
const policy = @import("harness_policy.zig");
const jobs = @import("jobs.zig");
const runCapped = jobs.runCapped;

/// Codex-style optional skills: known companion tools the harness quietly
/// upgrades itself with when they're installed. Progressive disclosure, same
/// shape as codex SKILL.md metadata: the `note` is the only thing that ever
/// enters the model's context (one line, injected at startup when the bins
/// are on PATH); the tool's own --help is the on-demand body. `/skills`
/// lists them with install status; `/skills add <name>` runs the installer.
const SkillDef = struct {
    name: []const u8,
    desc: []const u8,
    bins: []const []const u8, // every one must resolve on PATH to count as installed
    install: []const u8, // shell one-liner run by `/skills add <name>`
    note: []const u8, // system-prompt line when installed ("" = covered elsewhere)
};
pub const skills_registry = [_]SkillDef{
    .{
        .name = "graff",
        .desc = "code-intelligence suite — codedb-pro edits/search, zigrep, codedb index; edit_file upgrades to atomic zigpatch splices",
        .bins = &.{ "zigpatch", "codedb-pro" },
        .install = "curl -fsSL https://codegraff.com/install-graff.sh | sh",
        .note = "", // the codedb tool description + zigpatch delegation already cover it
    },
    .{
        .name = "kuri",
        .desc = "browser automation, web crawling, iOS/Android device control (github.com/justrach/kuri)",
        .bins = &.{"kuri"},
        .install = "curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh",
        .note = "The `kuri` CLI is installed (browser automation, HAR capture, iOS/Android device control) — prefer it via bash for those tasks; run `kuri --help` once first. Never synthesize simulator input (`kuri ios tap/swipe/scroll/type`) in background work — it grabs the user's real cursor and focus; use `xcrun simctl` instead, shut down devices you boot, and never `open -a Simulator` for background work (#407).",
    },
};

/// System-prompt notes for known MCP servers (the MCP twin of skill notes):
/// one line injected at startup when the server is actually connected, so the
/// model knows when to reach for its tools. The native tools stay registered
/// regardless — they are the fallback whenever an MCP call fails, is denied,
/// or the server is disconnected/skipped.
/// Licensed-aware variant of the codedbpro note. When `codedb-pro probe`
/// succeeds (paid + usable) we inject THIS instead of the conservative
/// "prefer free codedb" note below — leaning into the tools the user pays for.
/// Edits inside the cwd stay native: edit_file/write_file are
/// /rewind-snapshotted and already splice via zigpatch, whereas codedb-pro
/// edit/patch/replace bypass /rewind. Explicit external targets use gated bash.
const codedbpro_note_licensed = "The codedb-pro MCP server is connected and LICENSED — its mcp__codedbpro__* tools (load once per session via load_tool_schemas, e.g. by query) REPLACE native read/search (read_file and the legacy codedb tool are hidden). Shell cat/grep/sed/head of source is redirected or refused. KEEP EDITS on native edit_file/write_file — codedb-pro write tools are hidden because they bypass /rewind. Size reads to the file: mode=full in ONE call for small files — outline/symbol/lines for files too big to read whole. Any codedb-pro failure unblocks the natives for the rest of the session.";

const McpNote = struct { server: []const u8, note: []const u8 };
pub const mcp_notes = [_]McpNote{
    .{
        .server = "codedbpro",
        .note = "The codedb-pro MCP server is connected (mcp__codedbpro__* tools). SEARCH ORDER: the native codedb tool is free and indexed — always try it first (context/around/callpath/list_dir/status); reach for mcp__codedbpro__faster_search or meta_search only when codedb can't answer (raw literal/regex content matches, fuzzy queries, non-indexed files) — codedb-pro is metered. Prefer mcp__codedbpro__read (mode=outline first, then symbol) over read_file for navigating large code files, and mcp__codedbpro__batch to run several independent reads/searches/edits in one round-trip. Keep edits on the native edit_file/write_file tools (/rewind-tracked; the cwd and explicit-external-target rules above apply). These tools are accelerators, not requirements: if an mcp__codedbpro__ call fails, fall back to read_file/codedb/bash and continue.",
    },
    .{
        .server = "muonry",
        .note = "The muonry MCP server is connected (mcp__muonry__* tools). SEARCH ORDER: the native codedb tool is free and indexed — always try it first (context/around/callpath/list_dir/status); use mcp__muonry__search or faster_search only when codedb can't answer (raw literal/regex content matches, non-code or non-indexed files) — muonry is metered. Prefer mcp__muonry__read (mode=outline first, then symbol) over read_file for navigating large code files, and mcp__muonry__batch to run several independent reads/searches/edits in one round-trip. Keep edits on the native edit_file/write_file tools (/rewind-tracked; the cwd and explicit-external-target rules above apply). These tools are accelerators, not requirements: if an mcp__muonry__ call fails, fall back to read_file/codedb/bash and continue.",
    },
};

/// The metered code-intelligence companion. It first shipped as `muonry` and
/// was renamed to `codedb-pro`; both run as an MCP server (`<bin> --mcp`) and
/// expose the same tool surface. We auto-connect the first one present and
/// trust it like the native tools. Server names match the qualified tool
/// prefix the model sees (mcp__<server>__*); listed in preference order.
const CompanionServer = struct { server: []const u8, bin: []const u8 };
pub const companion_servers = [_]CompanionServer{
    .{ .server = "codedbpro", .bin = "codedb-pro" },
    .{ .server = "muonry", .bin = "muonry" }, // legacy name, same suite
};

/// Read-only tool names on the companion server, mirroring its own
/// readOnlyHint annotations.
const companion_readonly_tools = [_][]const u8{ "read", "search", "faster_search", "meta_search", "diff", "lint" };

fn companionToolReadOnly(t: []const u8) bool {
    for (companion_readonly_tools) |ok| if (std.mem.eql(u8, t, ok)) return true;
    return false;
}

/// Strip the companion's `mcp__<server>__` prefix, returning the bare tool
/// name — or null when the call isn't a companion tool at all.
pub fn companionToolName(tool: []const u8) ?[]const u8 {
    inline for (companion_servers) |c| {
        const prefix = "mcp__" ++ c.server ++ "__";
        if (std.mem.startsWith(u8, tool, prefix)) return tool[prefix.len..];
    }
    return null;
}

/// Every companion call skips the approval gate — the suite (codedb-pro/muonry,
/// zigpatch, zigrep, codedb) is a user-installed trusted companion, same
/// standing as the native read_file/edit_file tools, which never prompt.
pub fn companionTrusted(tool: []const u8) bool {
    return companionToolName(tool) != null;
}

/// Is this companion call read-only? Decides what it may do in PLAN MODE
/// (read-only by mode semantics — native edit_file is blocked there too,
/// trust notwithstanding). Mirrors the server's readOnlyHint annotations;
/// batch is read-only iff every op inside it is.
pub fn companionReadOnly(tool: []const u8, input: Value) bool {
    const t = companionToolName(tool) orelse return false;
    if (companionToolReadOnly(t)) return true;
    if (!std.mem.eql(u8, t, "batch")) return false;
    if (input != .object) return false;
    const ops = input.object.get("ops") orelse return false;
    if (ops != .array or ops.array.items.len == 0) return false;
    for (ops.array.items) |op| {
        if (op != .object) return false;
        const name = op.object.get("tool") orelse return false;
        if (name != .string or !companionToolReadOnly(name.string)) return false;
    }
    return true;
}

/// True when any discovered MCP tool belongs to `server` (qualified names
/// are "mcp__<server>__<tool>").
pub fn mcpServerConnected(tools: []const mcp.Tool, server: []const u8) bool {
    var buf: [128]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "mcp__{s}__", .{server}) catch return false;
    for (tools) |t| if (std.mem.startsWith(u8, t.qualified_name, prefix)) return true;
    return false;
}

pub fn binOnPath(io: Io, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, main_mod.g_path_env, ':');
    var buf: [1024]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return true;
    }
    return false;
}

pub fn skillInstalled(io: Io, sk: SkillDef) bool {
    for (sk.bins) |b| if (!binOnPath(io, b)) return false;
    return true;
}

pub fn skillIndex(name: []const u8) ?usize {
    for (skills_registry, 0..) |sk, i| if (std.mem.eql(u8, sk.name, name)) return i;
    return null;
}

pub fn skillDisabled(name: []const u8) bool {
    const i = skillIndex(name) orelse return false;
    return main_mod.g_skill_disabled[i];
}

/// Companion-server opt-out (e.g. codedb-pro): {"skills": {"codedbpro": false}}.
/// Server names aren't in skills_registry, so skillDisabled() can't see them —
/// the companion auto-connect gate uses this instead.
pub fn companionDisabled(server: []const u8) bool {
    for (companion_servers, 0..) |c, i| if (std.mem.eql(u8, c.server, server)) return main_mod.g_companion_disabled[i];
    return false;
}

/// Run the companion's `probe` — its own harness-gating capability check, the
/// same gate the codedb-pro CLI hooks use. Exit 0 == licensed and usable.
pub fn probeCodedbproLicensed(gpa: Allocator, io: Io) bool {
    const run = runCapped(gpa, io, &.{ "codedb-pro", "probe" }, 256, 256, 0) catch return false;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    return switch (run.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Pick the codedbpro system-prompt note: the lean-in note when licensed, else
/// the conservative free-codedb fallback (`conservative`, from mcp_notes).
pub fn codedbproNote(server: []const u8, licensed: bool, conservative: []const u8) []const u8 {
    if (licensed and std.mem.eql(u8, server, "codedbpro")) return codedbpro_note_licensed;
    return conservative;
}

/// Installed AND not user-disabled — the only check callers should use.
pub fn skillActive(io: Io, sk: SkillDef) bool {
    return !skillDisabled(sk.name) and skillInstalled(io, sk);
}

/// Parse the "skills" section of .harness/settings.json into the disabled
/// flags (call once at startup): {"skills": {"<name>": false}} disables;
/// anything else leaves it enabled. Covers skills_registry AND companion
/// servers (codedb-pro).
pub fn loadSkillSettings(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, policy.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const skills = v.object.get("skills") orelse return;
    applySkillSettings(skills);
}

/// Pure half of loadSkillSettings (no disk I/O), so the opt-out wiring is
/// unit-testable: maps {"skills": {"<name>": false}} onto the disabled flags.
fn applySkillSettings(skills: Value) void {
    if (skills != .object) return;
    for (skills_registry, 0..) |sk, i| {
        const entry = skills.object.get(sk.name) orelse continue;
        if (entry == .bool and !entry.bool) main_mod.g_skill_disabled[i] = true;
    }
    for (companion_servers, 0..) |c, i| {
        const entry = skills.object.get(c.server) orelse continue;
        if (entry == .bool and !entry.bool) main_mod.g_companion_disabled[i] = true;
    }
}

/// Persist one skill's enabled/disabled state to .harness/settings.json,
/// preserving every other key (allow-list and hooks live there too).
/// Enabling removes the key; disabling writes `false`. Best-effort.
pub fn saveSkillSetting(io: Io, gpa: Allocator, name: []const u8, enabled: bool) bool {
    Io.Dir.cwd().createDir(io, policy.settings_dir, .default_dir) catch {}; // already-exists is fine
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, policy.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    var skills_obj: std.json.ObjectMap = if (root_obj.get("skills")) |s|
        (if (s == .object) s.object else .empty)
    else
        .empty;
    if (enabled) {
        _ = skills_obj.orderedRemove(name);
    } else {
        skills_obj.put(a, name, .{ .bool = false }) catch return false;
    }
    if (skills_obj.count() == 0) {
        _ = root_obj.orderedRemove("skills");
    } else {
        root_obj.put(a, "skills", .{ .object = skills_obj }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, policy.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

test "companion trust: whole suite skips the gate; plan mode only frees read-only calls" {
    try std.testing.expect(companionTrusted("mcp__codedbpro__read"));
    try std.testing.expect(companionTrusted("mcp__codedbpro__edit"));
    try std.testing.expect(companionTrusted("mcp__muonry__read")); // legacy alias
    try std.testing.expect(companionTrusted("mcp__muonry__batch"));
    try std.testing.expect(!companionTrusted("mcp__other__read"));
    try std.testing.expect(!companionTrusted("read_file"));
}

test "companionReadOnly: the plan-mode classifier mirrors readOnlyHint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    const none = Value{ .null = {} };
    try std.testing.expect(companionReadOnly("mcp__codedbpro__read", none));
    try std.testing.expect(companionReadOnly("mcp__codedbpro__search", none));
    try std.testing.expect(companionReadOnly("mcp__codedbpro__faster_search", none));
    try std.testing.expect(companionReadOnly("mcp__muonry__read", none)); // legacy alias
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__edit", none));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__patch", none));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__memo", none));
    try std.testing.expect(!companionReadOnly("mcp__other__read", none)); // only the trusted server
    try std.testing.expect(!companionReadOnly("read_file", none));
    try std.testing.expect(!companionReadOnly("mcp__smolify__search_docs", none));
    // batch: read-only iff every op is
    try std.testing.expect(companionReadOnly("mcp__codedbpro__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"search","args":{}}]}
    )));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a,
        \\{"ops":[{"tool":"read","args":{}},{"tool":"edit","args":{}}]}
    )));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a, "{\"ops\":[]}")));
    try std.testing.expect(!companionReadOnly("mcp__codedbpro__batch", parse(a, "{}")));
}

test "companionToolName: strips either server prefix, else null" {
    try std.testing.expectEqualStrings("read", companionToolName("mcp__codedbpro__read").?);
    try std.testing.expectEqualStrings("faster_search", companionToolName("mcp__codedbpro__faster_search").?);
    try std.testing.expectEqualStrings("batch", companionToolName("mcp__muonry__batch").?); // legacy alias
    try std.testing.expect(companionToolName("mcp__other__read") == null);
    try std.testing.expect(companionToolName("read_file") == null);
    try std.testing.expect(companionToolName("codedb") == null); // free codedb is a native tool, not a companion
}

test "companion_servers: codedb-pro is the preferred target, muonry the legacy alias" {
    try std.testing.expectEqualStrings("codedbpro", companion_servers[0].server);
    try std.testing.expectEqualStrings("codedb-pro", companion_servers[0].bin);
    try std.testing.expectEqualStrings("muonry", companion_servers[1].server);
    try std.testing.expectEqualStrings("muonry", companion_servers[1].bin);
}

test "mcpServerConnected: detects codedb-pro by its qualified prefix" {
    const tools = [_]mcp.Tool{
        .{ .server_index = 0, .original_name = "search", .qualified_name = "mcp__codedbpro__search", .description = "", .input_schema = .null },
    };
    try std.testing.expect(mcpServerConnected(&tools, "codedbpro"));
    try std.testing.expect(!mcpServerConnected(&tools, "muonry"));
    try std.testing.expect(!mcpServerConnected(&tools, "codedb")); // native codedb tool isn't an MCP server
}

test "mcpServerConnected: prefix match on qualified names" {
    const tools = [_]mcp.Tool{
        .{ .server_index = 0, .original_name = "read", .qualified_name = "mcp__muonry__read", .description = "", .input_schema = .null },
        .{ .server_index = 0, .original_name = "edit", .qualified_name = "mcp__muonry__edit", .description = "", .input_schema = .null },
    };
    try std.testing.expect(mcpServerConnected(&tools, "muonry"));
    try std.testing.expect(!mcpServerConnected(&tools, "muon")); // no partial server names
    try std.testing.expect(!mcpServerConnected(&tools, "codedb"));
    try std.testing.expect(!mcpServerConnected(&.{}, "muonry"));
}

test "skillDisabled: registry lookup and toggle" {
    const i = skillIndex("kuri").?;
    const saved = main_mod.g_skill_disabled[i];
    defer main_mod.g_skill_disabled[i] = saved;
    main_mod.g_skill_disabled[i] = false;
    try std.testing.expect(!skillDisabled("kuri"));
    main_mod.g_skill_disabled[i] = true;
    try std.testing.expect(skillDisabled("kuri"));
    try std.testing.expect(!skillDisabled("not-a-skill"));
}

test "companion opt-out: {\"skills\":{\"codedbpro\":false}} disables auto-connect" {
    // applySkillSettings is the pure half of loadSkillSettings; prove the
    // settings key flips companionDisabled(), the flag the auto-connect reads.
    const saved_companion = main_mod.g_companion_disabled;
    const ki = skillIndex("kuri").?;
    const saved_kuri = main_mod.g_skill_disabled[ki];
    defer {
        main_mod.g_companion_disabled = saved_companion;
        main_mod.g_skill_disabled[ki] = saved_kuri;
    }
    main_mod.g_companion_disabled = @splat(false);
    main_mod.g_skill_disabled[ki] = false;

    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const json = "{\"skills\":{\"codedbpro\":false,\"kuri\":false}}";
    const v = try std.json.parseFromSliceLeaky(Value, arena_inst.allocator(), json, .{ .allocate = .alloc_always });
    applySkillSettings(v.object.get("skills").?);

    try std.testing.expect(companionDisabled("codedbpro")); // the fix: was always false before
    try std.testing.expect(skillDisabled("kuri")); // existing registry path still works
    try std.testing.expect(!companionDisabled("not-a-server"));
}

test "codedbproNote: licensed flips codedbpro to the lean-in note" {
    const cons = "CONSERVATIVE-NOTE";
    try std.testing.expectEqualStrings(cons, codedbproNote("codedbpro", false, cons)); // unlicensed -> conservative
    try std.testing.expectEqualStrings(cons, codedbproNote("muonry", true, cons)); // other servers untouched
    try std.testing.expectEqualStrings(codedbpro_note_licensed, codedbproNote("codedbpro", true, cons)); // licensed -> lean-in
    try std.testing.expect(std.mem.indexOf(u8, codedbpro_note_licensed, "mcp__codedbpro__*") != null);
    try std.testing.expect(std.mem.indexOf(u8, codedbpro_note_licensed, "load_tool_schemas") != null);
    try std.testing.expect(std.mem.indexOf(u8, codedbpro_note_licensed, "/rewind") != null);
}

test "skillIndex: registry lookup" {
    try std.testing.expect(skillIndex("graff") != null);
    try std.testing.expect(skillIndex("kuri") != null);
    try std.testing.expect(skillIndex("nonexistent-skill") == null);
}
