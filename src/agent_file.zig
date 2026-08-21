//! Hand-authored subagent personas on disk.
//!
//! Same niche as `.harness/agents/<name>.md` (YAML frontmatter + body), plus
//! Codex-shaped standalone TOML (`name` / `description` / `developer_instructions`,
//! optional `model`, `model_reasoning_effort`, `isolation`, `tier`). A file with
//! no prompt body is skipped. Strings stay slices of `data` unless a TOML value
//! needed unescaping, in which case they are arena-owned.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Draft = struct {
    name: []const u8,
    desc: []const u8 = "",
    prompt: []const u8 = "",
    score: ?f64 = null,
    isolation: ?[]const u8 = null,
    model: ?[]const u8 = null,
    tier: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

pub fn stemOf(filename: []const u8) []const u8 {
    if (std.mem.endsWith(u8, filename, ".md")) return filename[0 .. filename.len - 3];
    if (std.mem.endsWith(u8, filename, ".toml")) return filename[0 .. filename.len - 5];
    return filename;
}

/// Dispatch on the extension. Unknown suffixes return null (the loader skips).
pub fn parse(arena: Allocator, filename: []const u8, data: []const u8) ?Draft {
    if (std.mem.endsWith(u8, filename, ".toml")) return parseToml(arena, data, stemOf(filename));
    if (std.mem.endsWith(u8, filename, ".md")) return parseMarkdown(data, stemOf(filename));
    return null;
}

/// YAML-ish frontmatter (`---\n…\n---`) + body as the prompt. Matches the
/// field set loadAgentDir has always accepted.
pub fn parseMarkdown(data: []const u8, fallback_name: []const u8) ?Draft {
    var d: Draft = .{
        .name = fallback_name,
        .prompt = std.mem.trim(u8, data, " \t\r\n"),
    };
    if (std.mem.startsWith(u8, data, "---\n")) {
        if (std.mem.indexOfPos(u8, data, 4, "\n---")) |fm_end| {
            var lines = std.mem.tokenizeScalar(u8, data[4..fm_end], '\n');
            while (lines.next()) |ln| applyKv(&d, ln);
            const body_start = fm_end + "\n---".len;
            d.prompt = std.mem.trim(u8, data[@min(body_start + 1, data.len)..], " \t\r\n");
        }
    }
    return if (d.prompt.len == 0) null else d;
}

fn applyKv(d: *Draft, ln: []const u8) void {
    const sep = std.mem.indexOfScalar(u8, ln, ':') orelse return;
    const key = std.mem.trim(u8, ln[0..sep], " \t");
    const val = std.mem.trim(u8, ln[sep + 1 ..], " \t\"");
    applyField(d, key, val);
}

/// Codex-compatible subset: top-level `key = value`, `#` comments, basic and
/// multiline strings. Tables (`[mcp_servers.…]`, `[[skills.config]]`) and
/// everything after the first one are ignored — they are Codex session config,
/// not a persona.
pub fn parseToml(arena: Allocator, data: []const u8, fallback_name: []const u8) ?Draft {
    var d: Draft = .{ .name = fallback_name };
    var i: usize = 0;
    var in_table = false;
    while (i < data.len) {
        skipWsComments(data, &i);
        if (i >= data.len) break;
        if (data[i] == '[') {
            in_table = true;
            while (i < data.len and data[i] != '\n') i += 1;
            continue;
        }
        const key = parseKey(data, &i) orelse break;
        skipSpace(data, &i);
        if (i >= data.len or data[i] != '=') break;
        i += 1;
        const val = parseValue(arena, data, &i) orelse continue;
        if (!in_table) applyField(&d, key, val);
    }
    return if (d.prompt.len == 0) null else d;
}

fn applyField(d: *Draft, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "name") and val.len > 0) d.name = val;
    if (std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "desc")) d.desc = val;
    if (std.mem.eql(u8, key, "developer_instructions") or std.mem.eql(u8, key, "instructions") or std.mem.eql(u8, key, "prompt"))
        d.prompt = val;
    if (std.mem.eql(u8, key, "model")) d.model = if (val.len > 0) val else null;
    if (std.mem.eql(u8, key, "tier")) d.tier = if (val.len > 0) val else null;
    if (std.mem.eql(u8, key, "effort") or std.mem.eql(u8, key, "model_reasoning_effort"))
        d.effort = if (val.len > 0) val else null;
    if (std.mem.eql(u8, key, "isolation")) d.isolation = if (val.len > 0) val else null;
    if (std.mem.eql(u8, key, "score")) d.score = std.fmt.parseFloat(f64, val) catch null;
    // sandbox_mode is Codex's permission axis, not graff isolation. Accept so
    // a copied file still loads; only honor it when the value is already one
    // of graff's isolation tags (a file that said isolation in the wrong key).
    if (std.mem.eql(u8, key, "sandbox_mode") and d.isolation == null) {
        if (std.mem.eql(u8, val, "worktree") or std.mem.eql(u8, val, "shared_cwd")) d.isolation = val;
    }
}

fn skipWsComments(src: []const u8, i: *usize) void {
    while (i.* < src.len) {
        const c = src[i.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i.* += 1;
            continue;
        }
        if (c == '#') {
            while (i.* < src.len and src[i.*] != '\n') i.* += 1;
            continue;
        }
        break;
    }
}

fn skipSpace(src: []const u8, i: *usize) void {
    while (i.* < src.len and (src[i.*] == ' ' or src[i.*] == '\t')) i.* += 1;
}

fn parseKey(src: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= src.len) return null;
    if (src[i.*] == '"' or src[i.*] == '\'') {
        const q = src[i.*];
        i.* += 1;
        const start = i.*;
        const end = std.mem.indexOfScalarPos(u8, src, start, q) orelse return null;
        i.* = end + 1;
        return src[start..end];
    }
    const start = i.*;
    while (i.* < src.len) : (i.* += 1) {
        const c = src[i.*];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') continue;
        break;
    }
    return if (i.* > start) src[start..i.*] else null;
}

fn parseValue(arena: Allocator, src: []const u8, i: *usize) ?[]const u8 {
    skipSpace(src, i);
    if (i.* >= src.len) return null;
    if (match(src, i.*, "\"\"\"")) return parseTriple(arena, src, i, "\"\"\"", true);
    if (match(src, i.*, "'''")) return parseTriple(arena, src, i, "'''", false);
    if (src[i.*] == '"') return parseQuoted(arena, src, i, '"', true);
    if (src[i.*] == '\'') return parseQuoted(arena, src, i, '\'', false);
    if (src[i.*] == '{' or src[i.*] == '[') {
        skipBalanced(src, i);
        return "";
    }
    const start = i.*;
    while (i.* < src.len) : (i.* += 1) {
        const c = src[i.*];
        if (c == '#' or c == '\n' or c == '\r') break;
    }
    return std.mem.trim(u8, src[start..i.*], " \t");
}

fn match(src: []const u8, at: usize, lit: []const u8) bool {
    return at + lit.len <= src.len and std.mem.eql(u8, src[at .. at + lit.len], lit);
}

fn parseTriple(arena: Allocator, src: []const u8, i: *usize, delim: []const u8, unescape_esc: bool) ?[]const u8 {
    i.* += delim.len;
    if (i.* < src.len and src[i.*] == '\n') {
        i.* += 1;
    } else if (i.* + 1 < src.len and src[i.*] == '\r' and src[i.* + 1] == '\n') {
        i.* += 2;
    }
    const start = i.*;
    const end = std.mem.indexOfPos(u8, src, start, delim) orelse return null;
    i.* = end + delim.len;
    const raw = src[start..end];
    return if (unescape_esc) unescape(arena, raw) else raw;
}

fn parseQuoted(arena: Allocator, src: []const u8, i: *usize, q: u8, unescape_esc: bool) ?[]const u8 {
    i.* += 1;
    const start = i.*;
    while (i.* < src.len) {
        if (src[i.*] == '\\' and unescape_esc) {
            i.* += if (i.* + 1 < src.len) 2 else 1;
            continue;
        }
        if (src[i.*] == q) {
            const raw = src[start..i.*];
            i.* += 1;
            return if (unescape_esc) unescape(arena, raw) else raw;
        }
        if (src[i.*] == '\n') return null; // unterminated basic/literal string
        i.* += 1;
    }
    return null;
}

fn skipBalanced(src: []const u8, i: *usize) void {
    const open = src[i.*];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: u32 = 0;
    var quote: ?u8 = null;
    while (i.* < src.len) : (i.* += 1) {
        const c = src[i.*];
        if (quote) |q| {
            if (c == '\\' and i.* + 1 < src.len) {
                i.* += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) {
                i.* += 1;
                return;
            }
        }
    }
}

fn unescape(arena: Allocator, raw: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out = arena.alloc(u8, raw.len) catch return raw;
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            out[n] = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => raw[i],
            };
            n += 1;
            i += 1;
            continue;
        }
        out[n] = raw[i];
        n += 1;
        i += 1;
    }
    return out[0..n];
}

test "markdown frontmatter fills name, pins, and body" {
    const d = parseMarkdown(
        \\---
        \\name: worker
        \\description: does the work
        \\model: grok-4.6
        \\tier: mid
        \\effort: high
        \\isolation: worktree
        \\score: 1.25
        \\---
        \\Be brief.
        \\
    , "fallback") orelse return error.Skipped;
    try std.testing.expectEqualStrings("worker", d.name);
    try std.testing.expectEqualStrings("does the work", d.desc);
    try std.testing.expectEqualStrings("Be brief.", d.prompt);
    try std.testing.expectEqualStrings("grok-4.6", d.model.?);
    try std.testing.expectEqualStrings("mid", d.tier.?);
    try std.testing.expectEqualStrings("high", d.effort.?);
    try std.testing.expectEqualStrings("worktree", d.isolation.?);
    try std.testing.expect(d.score.? > 1.2 and d.score.? < 1.3);
}

test "markdown without a body is skipped" {
    try std.testing.expect(parseMarkdown("---\nname: x\n---\n", "x") == null);
}

test "toml Codex file: developer_instructions, aliases, ignored tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src =
        \\# personal explorer
        \\name = "pr_explorer"
        \\description = "Read-only codebase explorer."
        \\model = "grok-4.6"
        \\model_reasoning_effort = "medium"
        \\sandbox_mode = "read-only"
        \\isolation = "shared_cwd"
        \\developer_instructions = """
        \\Stay in exploration mode.
        \\Cite files.
        \\"""
        \\
        \\[mcp_servers.openaiDeveloperDocs]
        \\url = "https://developers.openai.com/mcp"
        \\
        \\[[skills.config]]
        \\path = "/tmp/x"
        \\enabled = false
    ;
    const d = parseToml(arena_state.allocator(), src, "from-filename") orelse return error.Skipped;
    try std.testing.expectEqualStrings("pr_explorer", d.name);
    try std.testing.expectEqualStrings("Read-only codebase explorer.", d.desc);
    try std.testing.expectEqualStrings("Stay in exploration mode.\nCite files.\n", d.prompt);
    try std.testing.expectEqualStrings("grok-4.6", d.model.?);
    try std.testing.expectEqualStrings("medium", d.effort.?);
    try std.testing.expectEqualStrings("shared_cwd", d.isolation.?);
    try std.testing.expect(d.tier == null);
}

test "toml sandbox_mode does not become isolation unless it is a graff tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = parseToml(arena_state.allocator(),
        \\name = "x"
        \\sandbox_mode = "read-only"
        \\developer_instructions = "go"
        \\
    , "x") orelse return error.Skipped;
    try std.testing.expect(d.isolation == null);
}

test "toml name field beats the filename stem" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = parse(arena_state.allocator(), "pr-explorer.toml",
        \\name = "pr_explorer"
        \\prompt = "look around"
        \\
    ) orelse return error.Skipped;
    try std.testing.expectEqualStrings("pr_explorer", d.name);
    try std.testing.expectEqualStrings("look around", d.prompt);
}

test "toml comments, escapes, and single-quoted strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = parseToml(arena_state.allocator(),
        \\name = 'docs_researcher' # inline
        \\description = "says \"hello\""
        \\instructions = "line\nbreak"
        \\
    , "stem") orelse return error.Skipped;
    try std.testing.expectEqualStrings("docs_researcher", d.name);
    try std.testing.expectEqualStrings("says \"hello\"", d.desc);
    try std.testing.expectEqualStrings("line\nbreak", d.prompt);
}

test "unknown extension is not a persona" {
    try std.testing.expect(parse(std.testing.allocator, "notes.txt", "name = \"x\"\nprompt = \"y\"\n") == null);
}

test "empty toml without instructions is skipped" {
    try std.testing.expect(parseToml(std.testing.allocator, "name = \"ghost\"\nmodel = \"grok-4.6\"\n", "ghost") == null);
}

test "shipped pr_explorer.toml example parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "docs/examples/agents/pr_explorer.toml", arena, .limited(16 * 1024)) catch return error.SkipZigTest;
    const d = parseToml(arena, data, "pr_explorer") orelse return error.Skipped;
    try std.testing.expectEqualStrings("pr_explorer", d.name);
    try std.testing.expectEqualStrings("medium", d.effort.?);
    try std.testing.expect(std.mem.indexOf(u8, d.prompt, "Stay in exploration mode.") != null);
}
