//! Guard against detouring local workspace edits through an independently
//! launched `run_task` MCP server (`mcp__codegraff__run_task`) whose launch
//! directory or server-owned permission mode does not match the active session
//! (#1909). Preserves the external server's `--safe` boundary — never elevates
//! permissions or passes caller cwd/approvals to the external service.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const mcp = @import("mcp.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const tools = @import("tools.zig");
const no_local_tools = @import("no_local_tools.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");
const ToolOutput = tools.ToolOutput;

pub const PolicyMode = enum { safe, yolo, server_owned_external };

pub const ServerBoundary = struct {
    server_name: []const u8,
    mode: PolicyMode,
    server_cwd: ?[]const u8 = null,
};

pub const Mismatch = struct {
    safe_mode: bool = false,
    cwd_mismatch: bool = false,
    external_http: bool = false,

    pub fn any(self: Mismatch) bool {
        return self.safe_mode or self.cwd_mismatch or self.external_http;
    }
};

/// True when `qualified_name` refers to a `run_task` MCP tool exposed by an
/// external Codegraff task server (`mcp__<server>__run_task`).
pub fn isRunTaskTool(qualified_name: []const u8, original_name: []const u8) bool {
    return std.mem.eql(u8, original_name, "run_task") and
        std.mem.startsWith(u8, qualified_name, "mcp__") and
        std.mem.endsWith(u8, qualified_name, "__run_task");
}

const edit_keywords = [_][]const u8{
    "edit",   "edits",  "modify", "patch",  "update", "replace",
    "write",  "create", "delete", "remove", "rename", "insert",
    "append", "apply",  "fix",    "add",    "change", "rewrite",
};

const negation_words = [_][]const u8{
    "no",     "not",      "never",    "without", "none",
    "zero",   "non",      "dont",     "cannot",  "cant",
    "wont",   "shouldnt", "mustnt",   "avoid",   "skip",
    "forbid", "prohibit", "disallow", "refuse",
};

const pivot_words = [_][]const u8{
    "but",    "however", "instead", "except",
    "unless", "yet",     "though",  "although",
    "so",     "then",
};

const max_negation_gap: usize = 4;

fn isCurlyApostrophe(s: []const u8, i: usize) bool {
    return i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x80 and s[i + 2] == 0x99;
}

fn isDashUtf8(s: []const u8, i: usize) bool {
    return i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x80 and (s[i + 2] == 0x93 or s[i + 2] == 0x94);
}

fn eqlNormalizedWord(word: []const u8, target: []const u8) bool {
    var wi: usize = 0;
    var ti: usize = 0;
    while (wi < word.len) {
        if (word[wi] == '\'') {
            wi += 1;
            continue;
        }
        if (isCurlyApostrophe(word, wi)) {
            wi += 3;
            continue;
        }
        if (ti >= target.len) return false;
        if (std.ascii.toLower(word[wi]) != target[ti]) return false;
        wi += 1;
        ti += 1;
    }
    return ti == target.len;
}

fn inWordList(word: []const u8, list: []const []const u8) bool {
    for (list) |kw| {
        if (eqlNormalizedWord(word, kw)) return true;
    }
    return false;
}

/// True when the delegated task text asks to modify/write/create/delete files.
/// Explicit clause-local negations ("No edits.", "Do not edit or modify",
/// "without making any file edits", "no-edit") are not treated as edit requests
/// (#1914), while positive edit instructions in the same or another clause stay
/// guarded.
pub fn requestsLocalEdit(prompt: []const u8) bool {
    var negated = false;
    var negated_edit_seen = false;
    var gap: usize = 0;

    var i: usize = 0;
    while (i < prompt.len) {
        const ch = prompt[i];
        if (std.ascii.isAlphanumeric(ch)) {
            const start = i;
            while (i < prompt.len) {
                if (std.ascii.isAlphanumeric(prompt[i])) {
                    i += 1;
                } else if (prompt[i] == '\'' and i + 1 < prompt.len and std.ascii.isAlphanumeric(prompt[i + 1])) {
                    i += 1;
                } else if (isCurlyApostrophe(prompt, i) and i + 3 < prompt.len and std.ascii.isAlphanumeric(prompt[i + 3])) {
                    i += 3;
                } else break;
            }
            const word = prompt[start..i];
            if (inWordList(word, &pivot_words)) {
                negated = false;
                negated_edit_seen = false;
                gap = 0;
            } else if (inWordList(word, &negation_words)) {
                negated = true;
                negated_edit_seen = false;
                gap = 0;
            } else if (inWordList(word, &edit_keywords)) {
                if (!negated) return true;
                negated_edit_seen = true;
                gap = 0;
            } else if (negated) {
                if (negated_edit_seen and (eqlNormalizedWord(word, "or") or eqlNormalizedWord(word, "nor"))) {
                    gap = 0;
                } else if (eqlNormalizedWord(word, "and")) {
                    if (negated_edit_seen and gap == 0) {
                        gap = 1;
                    } else {
                        negated = false;
                        negated_edit_seen = false;
                        gap = 0;
                    }
                } else {
                    gap += 1;
                    if (gap > max_negation_gap) {
                        negated = false;
                        negated_edit_seen = false;
                        gap = 0;
                    }
                }
            }
            continue;
        }

        if (isDashUtf8(prompt, i)) {
            negated = false;
            negated_edit_seen = false;
            gap = 0;
            i += 3;
            continue;
        }

        switch (ch) {
            '.', '!', '?', ';', ':', '\n', '\r', '(', ')', '[', ']', '{', '}' => {
                negated = false;
                negated_edit_seen = false;
                gap = 0;
            },
            ',' => {
                if (!negated_edit_seen) {
                    negated = false;
                    gap = 0;
                }
            },
            '-' => {
                const intra_word = i > 0 and i + 1 < prompt.len and
                    std.ascii.isAlphanumeric(prompt[i - 1]) and
                    std.ascii.isAlphanumeric(prompt[i + 1]);
                if (!intra_word) {
                    negated = false;
                    negated_edit_seen = false;
                    gap = 0;
                }
            },
            else => {},
        }
        i += 1;
    }
    return false;
}

fn normalizedPathTrim(p: []const u8) []const u8 {
    return std.mem.trimEnd(u8, p, "/\\");
}

fn samePath(a: []const u8, b: []const u8) bool {
    const ca = normalizedPathTrim(a);
    const cb = normalizedPathTrim(b);
    if (ca.len != cb.len) return false;
    for (ca, cb) |ac, bc| {
        const a_sep = ac == '/' or ac == '\\';
        const b_sep = bc == '/' or bc == '\\';
        if (a_sep and b_sep) continue;
        if (@import("builtin").os.tag == .windows) {
            if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
        } else if (ac != bc) return false;
    }
    return true;
}

pub fn boundaryFromConfig(server_name: []const u8, cfg_opt: ?std.json.ObjectMap, is_http: bool) ServerBoundary {
    if (is_http) return .{ .server_name = server_name, .mode = .server_owned_external, .server_cwd = null };
    const cfg = cfg_opt orelse return .{ .server_name = server_name, .mode = .safe, .server_cwd = null };
    var has_yolo = false;
    if (cfg.get("args")) |args| if (args == .array) {
        for (args.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, "--yolo")) {
                has_yolo = true;
                break;
            }
        }
    };
    const cwd = if (cfg.get("cwd")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    return .{
        .server_name = server_name,
        .mode = if (has_yolo) .yolo else .safe,
        .server_cwd = cwd,
    };
}

/// Pure policy evaluation: detect whether delegating `prompt` to `boundary`
/// from `session_cwd` while native file tools are active would detour an edit
/// across an unsuitable workspace or permission boundary.
pub fn checkBoundary(boundary: ServerBoundary, session_cwd: []const u8, prompt: []const u8, native_tools_available: bool) Mismatch {
    if (!native_tools_available) return .{};
    if (!requestsLocalEdit(prompt)) return .{};
    var out: Mismatch = .{};
    switch (boundary.mode) {
        .safe => out.safe_mode = true,
        .server_owned_external => out.external_http = true,
        .yolo => {},
    }
    if (boundary.server_cwd) |scwd| {
        if (session_cwd.len > 0 and !samePath(scwd, session_cwd)) out.cwd_mismatch = true;
    }
    return out;
}

pub fn formatMismatch(gpa: Allocator, boundary: ServerBoundary, session_cwd: []const u8, m: Mismatch) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print(
        "refused detour to external MCP tool mcp__{s}__run_task for a local workspace edit: ",
        .{boundary.server_name},
    );
    var wrote_reason = false;
    if (m.external_http) {
        try aw.writer.writeAll("the external HTTP task service owns its own launch directory and permission policy (typically --safe) rather than this session's workspace/approvals");
        wrote_reason = true;
    } else if (m.safe_mode) {
        try aw.writer.writeAll("the MCP server is configured in --safe mode (its child cannot apply local edits without server-side --yolo)");
        wrote_reason = true;
    }
    if (m.cwd_mismatch) {
        if (wrote_reason) try aw.writer.writeAll("; ");
        try aw.writer.print("server launch cwd '{s}' differs from active session workspace '{s}'", .{
            boundary.server_cwd orelse "(server-owned)",
            session_cwd,
        });
    }
    try aw.writer.writeAll(". Preserve the server's boundary: do not retry with larger budgets, do not bypass --safe, and do not launch separate chats. Use this session's workspace-native edit_file/write_file/shell tools or a scoped shared-cwd subagent directly, then verify the changed file bytes with read_file.");
    return aw.toOwnedSlice();
}

/// Preflight guard called before dispatching an MCP tool in `exec.zig`.
/// Returns a refusal `ToolOutput` when a local edit would detour through an
/// unsuitable external `run_task` server while native tools are available.
pub fn preflight(gpa: Allocator, io: Io, ctx: tools.ToolCtx, reg: *mcp.Registry, qualified_name: []const u8, input: Value) ?ToolOutput {
    if (no_local_tools.enabled or ctx.read_only_shell) return null;
    if (!std.mem.endsWith(u8, qualified_name, "__run_task")) return null;
    const prompt = tools.strField(input, "prompt") orelse return null;

    var boundary_opt: ?ServerBoundary = null;
    {
        reg.mutex.lockUncancelable(io);
        defer reg.mutex.unlock(io);
        for (reg.tools) |t| {
            if (!std.mem.eql(u8, t.qualified_name, qualified_name)) continue;
            if (!isRunTaskTool(t.qualified_name, t.original_name)) break;
            if (t.server_index >= reg.servers.len) break;
            const srv: *mcp_rpc.Server = reg.servers[t.server_index];
            const cfg_opt: ?std.json.ObjectMap = switch (srv.transport) {
                .stdio => |s| if (s.relaunch) |r| r.cfg else null,
                .dormant => |d| d.cfg,
                .http => null,
            };
            boundary_opt = boundaryFromConfig(srv.name, cfg_opt, srv.transport == .http);
            break;
        }
    }
    const boundary = boundary_opt orelse return null;
    const session_cwd = codedbpro_paths.sessionAbs(gpa, io, ctx.agent_cwd, ".") catch "";
    defer if (session_cwd.len > 0) gpa.free(session_cwd);
    const m = checkBoundary(boundary, session_cwd, prompt, true);
    if (!m.any()) return null;
    const msg = formatMismatch(gpa, boundary, session_cwd, m) catch return .{ .is_error = true };
    return .{ .text = msg, .is_error = true };
}

pub const exit_only_caveat = "\n[note: run_task completion reflects process exit only, not verified file edits — inspect the returned text and verify actual file bytes on disk with read_file before reporting edits complete.]";

/// Appends the truthful process-exit caveat to successful `run_task` tool
/// results so callers never mistake exit 0 for verified file changes (#1909).
pub fn annotateCompleted(gpa: Allocator, qualified_name: []const u8, has_meta: bool, text: []u8) ![]u8 {
    if (!has_meta and !std.mem.endsWith(u8, qualified_name, "__run_task")) return text;
    if (std.mem.indexOf(u8, text, "process exit only") != null) return text;
    const joined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ text, exit_only_caveat });
    gpa.free(text);
    return joined;
}

test "#1909: safe-mode external run_task rooted elsewhere is blocked for local edits while native edit verifies bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "active_ws");
    try tmp.dir.createDirPath(io, "other_server_root");
    try tmp.dir.writeFile(io, .{ .sub_path = "active_ws/notes.md", .data = "# Notes\nold line\n" });

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const active_ws = try std.fmt.allocPrint(a, "{s}/active_ws", .{root});
    const other_root = try std.fmt.allocPrint(a, "{s}/other_server_root", .{root});

    // External MCP server configured in default safe mode and rooted elsewhere.
    const cfg_json = try std.fmt.allocPrint(
        a,
        "{{\"command\":\"graff\",\"args\":[\"mcp\",\"serve\"],\"cwd\":{f}}}",
        .{std.json.fmt(other_root, .{})},
    );
    const cfg_val = try std.json.parseFromSliceLeaky(Value, a, cfg_json, .{ .allocate = .alloc_always });
    const boundary = boundaryFromConfig("codegraff", cfg_val.object, false);
    try std.testing.expectEqual(PolicyMode.safe, boundary.mode);

    const mismatch = checkBoundary(boundary, active_ws, "Update notes.md to replace old line with new line", true);
    try std.testing.expect(mismatch.safe_mode);
    try std.testing.expect(mismatch.cwd_mismatch);

    const refusal = try formatMismatch(gpa, boundary, active_ws, mismatch);
    defer gpa.free(refusal);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "--safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "differs from active session workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "workspace-native edit_file") != null);
    // File was untouched by the refused external detour.
    const untouched = try tmp.dir.readFileAlloc(io, "active_ws/notes.md", gpa, .limited(4096));
    defer gpa.free(untouched);
    try std.testing.expectEqualStrings("# Notes\nold line\n", untouched);

    // Workspace-native edit applies the change in active_ws and verifies changed bytes on disk.
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = active_ws,
    };
    const edit_args = try std.json.parseFromSliceLeaky(
        Value,
        a,
        "{\"path\":\"notes.md\",\"old_string\":\"old line\",\"new_string\":\"new line\"}",
        .{ .allocate = .alloc_always },
    );
    const edited = try @import("edit_verify.zig").execEdit(ctx, edit_args);
    defer gpa.free(edited.text);
    try std.testing.expect(!edited.is_error);
    try std.testing.expect(std.mem.indexOf(u8, edited.text, "verified") != null);

    const updated = try tmp.dir.readFileAlloc(io, "active_ws/notes.md", gpa, .limited(4096));
    defer gpa.free(updated);
    try std.testing.expectEqualStrings("# Notes\nnew line\n", updated);

    // A matching --yolo server in the same cwd or a --no-local-tools caller is allowed.
    const yolo_json = try std.fmt.allocPrint(
        a,
        "{{\"command\":\"graff\",\"args\":[\"mcp\",\"serve\",\"--yolo\"],\"cwd\":{f}}}",
        .{std.json.fmt(active_ws, .{})},
    );
    const yolo_val = try std.json.parseFromSliceLeaky(Value, a, yolo_json, .{ .allocate = .alloc_always });
    const yolo_b = boundaryFromConfig("codegraff", yolo_val.object, false);
    try std.testing.expect(!checkBoundary(yolo_b, active_ws, "Update notes.md", true).any());
    try std.testing.expect(!checkBoundary(boundary, active_ws, "Update notes.md", false).any());
    // Pure read-only questions are not blocked either.
    try std.testing.expect(!checkBoundary(boundary, active_ws, "Summarize the architecture in README.md", true).any());

    // Process completion on run_task carries explicit caveat that edits were not verified.
    const raw = try gpa.dupe(u8, "I could not edit notes.md in safe mode.");
    const annotated = try annotateCompleted(gpa, "mcp__codegraff__run_task", true, raw);
    defer gpa.free(annotated);
    try std.testing.expect(std.mem.indexOf(u8, annotated, "process exit only") != null);
}

test "#1914: explicit no-edit instructions are allowed while positive local edits remain guarded" {
    const http_boundary = boundaryFromConfig("remote_tasks", null, true);
    try std.testing.expectEqual(PolicyMode.server_owned_external, http_boundary.mode);

    const safe_boundary: ServerBoundary = .{
        .server_name = "codegraff",
        .mode = .safe,
        .server_cwd = "/other/root",
    };

    const allowed_read_only = [_][]const u8{
        "Look up the latest public release notes online. No edits.",
        "Check the public API docs (no edits)",
        "Do not edit any local files.",
        "Don't edit or modify notes.md.",
        "Don\xE2\x80\x99t edit, write, or delete any files.",
        "Run a read-only search without making any file edits.",
        "Make no local edits or patches.",
        "Perform a no-edit lookup of the documentation.",
        "Never create, update, or remove files.",
        "You must not rewrite or replace anything.",
        "Avoid any patch or edit to the workspace.",
        "Summarize the architecture in README.md.",
    };
    for (allowed_read_only) |prompt| {
        try std.testing.expect(!requestsLocalEdit(prompt));
        try std.testing.expect(!checkBoundary(http_boundary, "/active/ws", prompt, true).any());
        try std.testing.expect(!checkBoundary(safe_boundary, "/active/ws", prompt, true).any());
    }

    const guarded_edits = [_][]const u8{
        "Update notes.md to replace old line with new line.",
        "Edit README.md. Do not modify LICENSE.",
        "Do not delete tests, but update README.md.",
        "Do not modify tests; fix src/main.zig.",
        "No, edit src/main.zig.",
        "No comments needed. Fix src/main.zig.",
        "(No edits) Update notes.md.",
        "No edits - update notes.md.",
        "No edits \xE2\x80\x94 update notes.md.",
        "No tests exist so add one in src/main.zig.",
        "Do not edit tests and update README.md.",
        "The parser can't handle this input, fix it.",
        "No timeout limit configured on the client when you update notes.md.",
    };
    for (guarded_edits) |prompt| {
        try std.testing.expect(requestsLocalEdit(prompt));
        const http_m = checkBoundary(http_boundary, "/active/ws", prompt, true);
        try std.testing.expect(http_m.external_http);
        const safe_m = checkBoundary(safe_boundary, "/active/ws", prompt, true);
        try std.testing.expect(safe_m.safe_mode);
        try std.testing.expect(safe_m.cwd_mismatch);
    }
}
