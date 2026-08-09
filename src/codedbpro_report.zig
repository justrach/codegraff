//! codedb-pro failure reporter: when an mcp__codedbpro__* tool call fails,
//! dedupe the failure, redact everything an upstream issue does not strictly
//! need (harness-side, BEFORE any model sees it), and spawn ONE background
//! subagent to file it on justrach/codegraff under the `codedb-pro` label —
//! the calling model just falls back to native tools and keeps working.
//!
//! Three bounds keep a down server from becoming an issue-filing storm:
//! root-only (ctx.from_sub short-circuits, so the reporter subagent's own
//! failures can never re-trigger it), a per-session signature set (the same
//! tool+error reports once), and a hard spawn cap. The subagent's `gh` calls
//! still pass the normal tool gate — unattended sessions draft to
//! .graff/issue-drafts/ instead of publishing without consent.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");
const util = @import("util.zig");
const subagent = @import("subagent.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const main_mod = @import("main.zig"); // g_codedbpro_licensed, plan_mode
const skills = @import("skills.zig"); // mcpServerConnected

pub const server_name = "codedbpro";
pub const issue_repo = "justrach/codegraff";
pub const issue_label = "codedb-pro";
pub const label = "codedb-pro issue reporter";

/// Hard bounds: at most this many reporter spawns a session, and this many
/// distinct failure signatures remembered for dedupe.
pub const max_reports: usize = 3;
const max_seen: usize = 16;

const State = struct {
    mutex: Io.Mutex = .init,
    seen: [max_seen]u64 = @splat(0),
    seen_count: usize = 0,
    reports: usize = 0,
};

var g_state: State = .{};

/// The dedupe/cap decision, Io-free so tests need no thread pool (same split
/// as subagent.zig's admitOneLocked). Callers hold State.mutex.
fn admitLocked(state: *State, sig: u64) bool {
    for (state.seen[0..state.seen_count]) |s| if (s == sig) return false;
    if (state.reports >= max_reports) return false;
    if (state.seen_count < max_seen) {
        state.seen[state.seen_count] = sig;
        state.seen_count += 1;
    }
    state.reports += 1;
    return true;
}

/// Same tool plus the same redacted error essence = the same report. The
/// excerpt is already path/token-scrubbed, so the signature never keys on
/// anything sensitive either.
fn signature(tool: []const u8, redacted: []const u8) u64 {
    const essence = util.utf8Prefix(redacted, 128);
    return std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, tool), essence);
}

fn tokenish(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '+' or ch == '/' or ch == '_' or ch == '=' or ch == '-';
}

/// Harness-side redaction, applied BEFORE the failure text reaches any model
/// or issue body: absolute/home paths become `<path>`, URLs keep scheme+host
/// but lose query strings, and long credential-looking runs become
/// `<redacted>`. Relative `src/foo.zig:42` references survive — they are the
/// detail an issue actually needs. Output capped at 400 bytes.
pub fn redact(gpa: Allocator, raw: []const u8) ![]u8 {
    const capped = util.utf8Prefix(raw, 2048);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, capped, " \t\r\n");
    while (it.next()) |tok| {
        const replacement: ?[]const u8 = blk: {
            if (tok.len >= 2 and tok[0] == '/' or std.mem.startsWith(u8, tok, "~/")) break :blk "<path>";
            if (std.mem.indexOf(u8, tok, "/Users/") != null or std.mem.indexOf(u8, tok, "/home/") != null) break :blk "<path>";
            if (tok.len >= 24 and std.mem.indexOfAny(u8, tok, "0123456789") != null) {
                var all = true;
                for (tok) |ch| if (!tokenish(ch)) {
                    all = false;
                    break;
                };
                if (all) break :blk "<redacted>";
            }
            break :blk null;
        };
        if (out.items.len > 0) try out.append(gpa, ' ');
        if (replacement) |r| {
            try out.appendSlice(gpa, r);
        } else if (std.mem.indexOf(u8, tok, "://") != null) {
            // URLs keep scheme+host+path but drop the query string, wherever
            // it sits — wrapping punctuation like "(https://…" is common.
            const no_query = tok[0 .. std.mem.indexOfScalar(u8, tok, '?') orelse tok.len];
            try out.appendSlice(gpa, util.utf8Prefix(no_query, 80));
        } else {
            try out.appendSlice(gpa, tok);
        }
        if (out.items.len >= 400) break;
    }
    const kept = util.utf8Prefix(out.items, 400);
    const result = try gpa.dupe(u8, kept);
    out.deinit(gpa);
    return result;
}

/// The reporter's whole brief. Self-contained (subagents share no context),
/// minimal on purpose: the user asked for NO detail beyond what an issue
/// strictly needs, dedupe against existing issues first, and the
/// `codedb-pro` label on every filing.
fn buildPrompt(gpa: Allocator, tool: []const u8, redacted_err: []const u8) ![]u8 {
    var safe_tool: std.ArrayList(u8) = .empty;
    defer safe_tool.deinit(gpa);
    for (tool) |ch| try safe_tool.append(gpa, if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_');
    return std.fmt.allocPrint(gpa,
        \\A licensed codedb-pro MCP tool call just failed in the parent graff session. Your ONLY job: make sure exactly one GitHub issue exists for it.
        \\
        \\Facts (the harness redacted everything else before you saw this — add NO detail beyond these facts; never include absolute paths, usernames, tokens, or file contents):
        \\- failing tool: {s}
        \\- redacted error excerpt: {s}
        \\
        \\Steps:
        \\1. Dedupe first: `gh issue list --repo {s} --label {s} --state all --search "{s}" --limit 20`. If an issue already covers this tool + error, stop and report "duplicate: <url>".
        \\2. Otherwise file it: `gh issue create --repo {s} --label {s} --title "codedb-pro: {s} failed" --body <body>` — the body is ONLY the two facts above, one sentence of context ("automated report from a graff session on a licensed codedb-pro tool failure"), and a note that details were redacted at the source. If gh rejects the label as unknown, run `gh label create {s} --repo {s}` once and retry; if that fails too, file without --label and put "label: {s}" in the body.
        \\3. If `gh` is unavailable or the call is denied, write the would-be title and body to `.graff/issue-drafts/{s}.md` with write_file and report the draft path.
        \\
        \\Keep the issue minimal on purpose — the user wants no detail beyond what is strictly necessary. Report back: the issue URL, "duplicate: <url>", or the draft path.
    , .{ tool, redacted_err, issue_repo, issue_label, tool, issue_repo, issue_label, tool, issue_label, issue_repo, issue_label, safe_tool.items });
}

/// The fallback hatch the enforcement half answers to: once ANY codedb-pro
/// call has failed this session, the native tools it replaced are allowed
/// again — the pro tools being "in charge" must never leave the model with
/// no working way to read or search. Atomic: tool calls run on pool threads.
var g_fallback_open: std.atomic.Value(bool) = .init(false);

pub fn fallbackOpen() bool {
    return g_fallback_open.load(.acquire);
}

/// The native tools the licensed pro tools replace. edit_file/write_file are
/// deliberately NOT here: edits stay native regardless (they are
/// /rewind-snapshotted; codedb-pro edits bypass /rewind).
fn replacedNative(name: []const u8) bool {
    return std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "codedb");
}

/// A bash call is only intercepted when the search command LEADS the line —
/// `grep x log` is a replaced search, `curl … | grep x` is output filtering
/// and stays allowed.
fn leadingSearchCommand(cmd: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first = trimmed[0..end];
    return std.mem.eql(u8, first, "grep") or std.mem.eql(u8, first, "rg") or std.mem.eql(u8, first, "find");
}

/// Whether the licensed-pro enforcement applies to this call right now.
/// Plan mode denies every MCP call, so blocking the natives there would
/// leave NO way to read — it is exempt. A disconnected server or an open
/// fallback likewise stand the gate down.
fn enforcementActive(ctx: tools.ToolCtx) bool {
    if (!main_mod.g_codedbpro_licensed or main_mod.plan_mode) return false;
    if (fallbackOpen()) return false;
    const reg = ctx.registry orelse return false;
    return skills.mcpServerConnected(reg.tools, server_name);
}

/// What a blocked call is pointed at. Shell searches go to zigrep — the
/// suite's own CLI, run directly via bash, no MCP round trip — when the
/// binary is on PATH; reads and the codedb tool point at the pro MCP tools.
fn replacementFor(call_name: []const u8, is_bash_search: bool, zigrep_installed: bool) []const u8 {
    if (is_bash_search) return if (zigrep_installed)
        "zigrep — run it directly via bash (e.g. `zigrep PATTERN src/`); it is the suite's search CLI. Caveat: zigrep always skips vendor dirs (node_modules & co) even with --no-ignore — use `rg -uu` for vendor dives"
    else
        "mcp__codedbpro__faster_search / meta_search";
    if (std.mem.eql(u8, call_name, "read_file")) return "mcp__codedbpro__read (mode=outline first, then symbol/lines)";
    return "mcp__codedbpro__faster_search / meta_search";
}

/// exec.zig consults this on every tool call: when the licensed pro tools are
/// in charge, calls to the natives they replaced are refused with a pointer
/// to the replacement. The refusal is guidance, not a security boundary —
/// approvals are untouched, and any codedb-pro failure stands it down.
pub fn nativeRefusal(ctx: tools.ToolCtx, call: tools.ToolCall) ?tools.ToolOutput {
    if (!enforcementActive(ctx)) return null;
    const is_bash_search = std.mem.eql(u8, call.name, "bash") and
        if (tools.strField(call.input, "command")) |cmd| leadingSearchCommand(cmd) else false;
    if (!is_bash_search and !replacedNative(call.name)) return null;
    const pro = replacementFor(call.name, is_bash_search, skills.binOnPath(ctx.io, "zigrep"));
    const text = std.fmt.allocPrint(ctx.gpa, "{s} is blocked while the LICENSED code-intelligence suite is in charge of reads/searches — use {s} instead (if its schema is not loaded yet, pass its name to load_tool_schemas first — once per session). If a codedb-pro call fails, the native tools unblock automatically for the rest of the session (and the failure is reported upstream).", .{ call.name, pro }) catch return null;
    return .{ .text = text, .is_error = true };
}

/// The splice request body, factored out so a test can pin the contract the
/// live benchmark validated: op MUST be "str_replace" — without it the
/// daemon answers "no content provided" (is_error) and every edit silently
/// falls back to the zigpatch spawn, killing the fast path it bought.
fn splicePayload(gpa: Allocator, file: []const u8, old: []const u8, new: []const u8, count: usize) ?std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(gpa);
    obj.put(gpa, "file", .{ .string = file }) catch return null;
    obj.put(gpa, "op", .{ .string = "str_replace" }) catch return null;
    obj.put(gpa, "old_string", .{ .string = old }) catch return null;
    obj.put(gpa, "new_string", .{ .string = new }) catch return null;
    obj.put(gpa, "replace_all", .{ .bool = true }) catch return null;
    obj.put(gpa, "expected", .{ .integer = @intCast(count) }) catch return null;
    return .{ .object = obj };
}

/// The edit_file fast path (edit_verify.zig's splice site): a splice over the
/// PERSISTENT codedb-pro connection skips zigpatch's fork/exec floor — same
/// atomic write, and the caller still holds the /rewind snapshot and runs
/// verifyOnDisk, so only the byte-splice is delegated, never the safety.
/// null = fall through to the zigpatch spawn, then the native write (daemon
/// absent, unlicensed, refused). `expected: count` makes the daemon itself
/// enforce the occurrence semantics the caller already computed.
///
/// Size gate, measured (median per edit): with the daemon's cache-read fix
/// (zigrepper handler_edit now snapshots from the stat-validated content
/// cache instead of a fresh mmap — mmap'ing a just-renamed file cost ~7.6ms
/// per 3.2MB on macOS), the daemon beats the spawn at every size up to its
/// 4 MiB cache ceiling: 0.36 vs 2.4ms at 18KB, 2.49 vs 5.00ms at 1 MiB,
/// 10.7 vs 11.5ms at 3.2MB. Past the ceiling the daemon falls back to the
/// churned-mmap path and loses, so big files go straight to the spawn.
pub const daemon_splice_max_bytes: usize = 4 << 20;

pub fn spliceViaDaemon(gpa: Allocator, ctx: tools.ToolCtx, file: []const u8, display_path: []const u8, old: []const u8, new: []const u8, count: usize, file_bytes: usize) ?[]u8 {
    if (file_bytes > daemon_splice_max_bytes) return null;
    const reg = ctx.registry orelse return null;
    if (!skills.mcpServerConnected(reg.tools, server_name)) return null;
    var payload = splicePayload(gpa, file, old, new, count) orelse return null;
    defer payload.object.deinit(gpa);
    const r = reg.call(gpa, "mcp__codedbpro__edit", payload) catch return null;
    const ok = !r.is_error;
    gpa.free(r.text);
    if (!ok) return null;
    return std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s} (codedb-pro, verified)", .{ count, display_path }) catch null;
}

/// exec.zig's MCP branch calls this on any failed mcp__codedbpro__* call
/// (transport error or is_error result). Never blocks the calling turn: the
/// reporter runs as a background subagent, and every failure path here is
/// silent by design — the tool result the model got already says it failed.
pub fn onFailure(ctx: tools.ToolCtx, tool: []const u8, err_text: []const u8) void {
    if (!std.mem.eql(u8, mcp_schema_gate.serverOf(tool), server_name)) return;
    // First failure opens the native fallback — dedupe/cap below only govern
    // ISSUE FILING, never the model's ability to keep working.
    g_fallback_open.store(true, .release);
    if (ctx.from_sub) return; // the reporter IS a subagent — never recurse
    const gpa = ctx.gpa;
    const redacted = redact(gpa, err_text) catch return;
    defer gpa.free(redacted);
    const sig = signature(tool, redacted);
    g_state.mutex.lockUncancelable(ctx.io);
    const admitted = admitLocked(&g_state, sig);
    g_state.mutex.unlock(ctx.io);
    if (!admitted) return;
    const prompt = buildPrompt(gpa, tool, redacted) catch return;
    defer gpa.free(prompt);
    subagent.spawnBackground(ctx, label, prompt) catch {};
}

test "redact scrubs absolute paths, home paths and tokens, keeps relative refs" {
    const a = std.testing.allocator;
    const out = try redact(a, "open /Users/alice/project/secret.zig failed: token Ab3dEf9012345678ijklMNOP at src/exec.zig:399 (https://api.codedb.pro/v1?key=Ab3dEf9012345678ijklMNOP)");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "alice") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Ab3dEf9012345678ijklMNOP") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/exec.zig:399") != null); // relative ref is the necessary detail
    try std.testing.expect(std.mem.indexOf(u8, out, "?key=") == null); // URL query strings are not
}

test "redact caps its output" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 5000);
    defer a.free(big);
    @memset(big, 'x');
    const out = try redact(a, big);
    defer a.free(out);
    try std.testing.expect(out.len <= 400);
}

test "admitLocked dedupes one signature and caps the session" {
    var s: State = .{};
    try std.testing.expect(admitLocked(&s, 111));
    try std.testing.expect(!admitLocked(&s, 111)); // same failure twice: one report
    try std.testing.expect(admitLocked(&s, 222));
    try std.testing.expect(admitLocked(&s, 333));
    try std.testing.expect(!admitLocked(&s, 444)); // cap reached
    try std.testing.expectEqual(@as(usize, max_reports), s.reports);
}

test "buildPrompt carries repo, label and redacted facts only" {
    const a = std.testing.allocator;
    const p = try buildPrompt(a, "mcp__codedbpro__read", "connection refused");
    defer a.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, issue_repo) != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "--label " ++ issue_label) != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "mcp__codedbpro__read") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "connection refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "gh issue list") != null); // dedupe-before-file
}

// ── the enforcement gate ────────────────────────────────────────────────────

const mcp = @import("mcp.zig");

fn gateTestCtx(a: Allocator, reg: *mcp.Registry) tools.ToolCtx {
    return .{
        .gpa = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .registry = reg,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
}

fn licensedRegistry() mcp.Registry {
    var reg = mcp.Registry.emptyWithOAuthHome(std.testing.allocator, std.testing.io, "");
    reg.tools = @constCast(&[_]mcp.Tool{.{ .server_index = 0, .original_name = "read", .qualified_name = "mcp__codedbpro__read", .description = "", .input_schema = .null }});
    return reg;
}

fn bashCall(a: Allocator, cmd: []const u8) tools.ToolCall {
    const input = std.fmt.allocPrint(a, "{{\"command\":\"{s}\"}}", .{cmd}) catch unreachable;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}) catch unreachable;
    return .{ .id = "t", .name = "bash", .input = parsed };
}

fn namedCall(name: []const u8) tools.ToolCall {
    return .{ .id = "t", .name = name, .input = .null };
}

test "replacementFor: shell searches point at zigrep directly, reads at the pro MCP tools" {
    try std.testing.expect(std.mem.indexOf(u8, replacementFor("bash", true, true), "zigrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacementFor("bash", true, false), "mcp__codedbpro__faster_search") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacementFor("read_file", false, true), "mcp__codedbpro__read") != null);
    try std.testing.expect(std.mem.indexOf(u8, replacementFor("codedb", false, true), "mcp__codedbpro__faster_search") != null);
}

test "nativeRefusal: licensed pro tools block the natives they replaced" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var reg = licensedRegistry();
    const ctx = gateTestCtx(a, &reg);
    const saved_licensed = main_mod.g_codedbpro_licensed;
    const saved_plan = main_mod.plan_mode;
    const saved_fallback = fallbackOpen();
    defer {
        main_mod.g_codedbpro_licensed = saved_licensed;
        main_mod.plan_mode = saved_plan;
        g_fallback_open.store(saved_fallback, .release);
    }
    main_mod.g_codedbpro_licensed = true;
    main_mod.plan_mode = false;
    g_fallback_open.store(false, .release);

    try std.testing.expect(nativeRefusal(ctx, namedCall("read_file")) != null);
    try std.testing.expect(nativeRefusal(ctx, namedCall("codedb")) != null);
    try std.testing.expect(nativeRefusal(ctx, bashCall(a, "find . -name '*.zig'")) != null);
    try std.testing.expect(nativeRefusal(ctx, bashCall(a, "rg TODO src")) != null);
    // Untouched: edits stay native, non-search bash stays open, a piped grep
    // filters command output rather than searching the tree.
    try std.testing.expect(nativeRefusal(ctx, namedCall("edit_file")) == null);
    try std.testing.expect(nativeRefusal(ctx, bashCall(a, "git status")) == null);
    try std.testing.expect(nativeRefusal(ctx, bashCall(a, "curl -s x | grep err")) == null);
}

test "nativeRefusal stands down: unlicensed, plan mode, fallback open, server gone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var reg = licensedRegistry();
    const ctx = gateTestCtx(a, &reg);
    const saved_licensed = main_mod.g_codedbpro_licensed;
    const saved_plan = main_mod.plan_mode;
    const saved_fallback = fallbackOpen();
    defer {
        main_mod.g_codedbpro_licensed = saved_licensed;
        main_mod.plan_mode = saved_plan;
        g_fallback_open.store(saved_fallback, .release);
    }
    const call = namedCall("read_file");

    main_mod.g_codedbpro_licensed = false; // unlicensed: conservative note, no gate
    main_mod.plan_mode = false;
    g_fallback_open.store(false, .release);
    try std.testing.expect(nativeRefusal(ctx, call) == null);

    main_mod.g_codedbpro_licensed = true;
    main_mod.plan_mode = true; // plan mode denies MCP — natives are the only readers
    try std.testing.expect(nativeRefusal(ctx, call) == null);

    main_mod.plan_mode = false;
    g_fallback_open.store(true, .release); // a pro failure opened the fallback
    try std.testing.expect(nativeRefusal(ctx, call) == null);

    g_fallback_open.store(false, .release);
    var empty = mcp.Registry.emptyWithOAuthHome(std.testing.allocator, std.testing.io, "");
    try std.testing.expect(nativeRefusal(gateTestCtx(a, &empty), call) == null); // server gone
}

test "splicePayload pins the daemon contract (op str_replace, replace_all, expected)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var payload = splicePayload(a, "/tmp/x", "old", "new", 2) orelse return error.TestExpectedPayload;
    defer payload.object.deinit(a);
    const obj = payload.object;
    try std.testing.expectEqualStrings("str_replace", obj.get("op").?.string); // missing op = daemon rejects, fast path never fires
    try std.testing.expectEqualStrings("old", obj.get("old_string").?.string);
    try std.testing.expectEqualStrings("new", obj.get("new_string").?.string);
    try std.testing.expect(obj.get("replace_all").?.bool);
    try std.testing.expectEqual(@as(i64, 2), obj.get("expected").?.integer);
}

test "spliceViaDaemon stands down cleanly: no registry, no connected codedbpro" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var client: std.http.Client = undefined;
    const no_reg: tools.ToolCtx = .{ .gpa = a, .io = std.testing.io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    try std.testing.expect(spliceViaDaemon(a, no_reg, "/tmp/x", "x", "o", "n", 1, 100) == null);
    var empty = mcp.Registry.emptyWithOAuthHome(a, std.testing.io, "");
    const no_pro = tools.ToolCtx{ .gpa = a, .io = std.testing.io, .client = &client, .provider = undefined, .registry = &empty, .from_sub = false, .approvals = null, .tracer = null };
    try std.testing.expect(spliceViaDaemon(a, no_pro, "/tmp/x", "x", "o", "n", 1, 100) == null); // never reaches reg.call
    // The measured size gate: past it, big files go straight to the spawn.
    try std.testing.expect(spliceViaDaemon(a, no_pro, "/tmp/x", "x", "o", "n", 1, daemon_splice_max_bytes + 1) == null);
}

test "onFailure opens the native fallback even from a subagent (no spawn, no recurse)" {
    const saved_fallback = fallbackOpen();
    defer g_fallback_open.store(saved_fallback, .release);
    g_fallback_open.store(false, .release);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var reg = licensedRegistry();
    var ctx = gateTestCtx(arena_state.allocator(), &reg);
    ctx.from_sub = true; // returns before the spawn path, which tests must not hit
    onFailure(ctx, "mcp__codedbpro__read", "connection refused");
    try std.testing.expect(fallbackOpen());
    onFailure(ctx, "mcp__deepwiki__ask_question", "boom"); // not ours: no effect
    try std.testing.expect(fallbackOpen());
}
