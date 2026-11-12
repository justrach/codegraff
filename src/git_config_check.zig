//! Is every config file git reads for `rev-parse` one git is sure to accept?
//!
//! git dies on a config line its parser rejects (config.c `git_parse_source`)
//! and on a bad value for a key `rev-parse` interprets at startup
//! (environment.c `git_default_config`, setup.c `check_repo_format`). Either
//! way the old spawn printed nothing and the cwd was "not git". So git_dirs may
//! answer in-process only when this check passes; anything it cannot prove
//! acceptable is `false`, and the caller asks git.
//!
//! The parser mirrors git's byte for byte where it accepts; oddities git
//! tolerates but this does not model (a BOM, control bytes, a lone CR, a key
//! before any section) are `false`. Includes are followed whatever their
//! condition, so the check covers a superset of what git reads.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_depth = 8;
const max_bytes = 64 * 1024;

pub const Ctx = struct {
    io: Io,
    arena: Allocator,
    /// `$HOME`, for `~/` in include paths and pathname values; null if unset.
    home: ?[]const u8,
    depth: u8 = 0,
};

/// A config file at `path` (absolute). Missing is `missing_ok`; unreadable,
/// oversized or not a regular file is false.
pub fn fileOk(ctx: Ctx, path: []const u8, missing_ok: bool) bool {
    if (ctx.depth > max_depth) return false;
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(max_bytes)) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => missing_ok,
        else => false,
    };
    var p: Parser = .{ .s = text };
    var c = ctx;
    c.depth += 1;
    return p.run(c, std.fs.path.dirname(path) orelse "/");
}

/// Config text as if read from a file in `dir` (for relative includes).
pub fn textOk(ctx: Ctx, text: []const u8, dir: []const u8) bool {
    var p: Parser = .{ .s = text };
    return p.run(ctx, dir);
}

/// One `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` pair (config.c
/// `config_parse_pair`). Includes from the environment are git's call.
pub fn pairOk(ctx: Ctx, name: []const u8, value: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, name, '.') orelse return false;
    const last = std.mem.lastIndexOfScalar(u8, name, '.').?;
    if (first == 0 or last + 1 >= name.len or !std.ascii.isAlphabetic(name[last + 1])) return false;
    const sub: ?[]const u8 = if (last > first) name[first + 1 .. last] else null;
    if (sub) |s| if (std.mem.indexOfScalar(u8, s, '\n') != null) return false;
    for (name[0..first]) |c| if (!Parser.keyChar(c)) return false;
    for (name[last + 1 ..]) |c| if (!Parser.keyChar(c)) return false;
    const section = std.ascii.allocLowerString(ctx.arena, name[0..first]) catch return false;
    const key = std.ascii.allocLowerString(ctx.arena, name[last + 1 ..]) catch return false;
    if (std.mem.startsWith(u8, section, "include")) return false;
    return entryOk(ctx, "/", section, sub, key, value);
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    eof: bool = false,
    section: std.ArrayList(u8) = .empty,
    sub: ?std.ArrayList(u8) = null,
    key: std.ArrayList(u8) = .empty,
    value: std.ArrayList(u8) = .empty,

    /// config.c `get_next_char`: CRLF folds to LF, EOF reads as LF.
    fn next(p: *Parser) u8 {
        if (p.i >= p.s.len) {
            p.eof = true;
            return '\n';
        }
        const c = p.s[p.i];
        p.i += 1;
        if (c == '\r' and p.i < p.s.len and p.s[p.i] == '\n') {
            p.i += 1;
            return '\n';
        }
        return c;
    }

    fn run(p: *Parser, ctx: Ctx, dir: []const u8) bool {
        // Bytes git's parser handles in ways not modelled here: say "unsure".
        for (p.s, 0..) |c, i| {
            if (c == '\r' and !(i + 1 < p.s.len and p.s[i + 1] == '\n')) return false;
            if (c < 0x20 and c != '\t' and c != '\n' and c != '\r') return false;
            if (c == 0x7f) return false;
        }
        if (std.mem.startsWith(u8, p.s, "\xef")) return false; // BOM
        var comment = false;
        var in_section = false;
        while (true) {
            const c = p.next();
            if (c == '\n') {
                if (p.eof) return true;
                comment = false;
                continue;
            }
            if (comment or c == ' ' or c == '\t') continue;
            if (c == '#' or c == ';') {
                comment = true;
                continue;
            }
            if (c == '[') {
                if (!p.header(ctx.arena)) return false;
                in_section = true;
                continue;
            }
            if (!std.ascii.isAlphabetic(c) or !in_section) return false;
            const has_value = p.entry(ctx.arena, c) orelse return false;
            if (!entryOk(ctx, dir, p.section.items, if (p.sub) |s| s.items else null, p.key.items, if (has_value) p.value.items else null)) return false;
        }
    }

    fn keyChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-';
    }

    /// `[section]`, `[section "sub"]` or the old `[section.sub]`.
    fn header(p: *Parser, a: Allocator) bool {
        p.section.clearRetainingCapacity();
        p.sub = null;
        while (true) {
            const c = p.next();
            if (p.eof or c == '\n') return false;
            if (c == ']') break;
            if (c == ' ' or c == '\t') return p.quotedSub(a);
            if (!keyChar(c) and c != '.') return false;
            p.section.append(a, std.ascii.toLower(c)) catch return false;
        }
        if (p.section.items.len == 0) return false;
        if (std.mem.indexOfScalar(u8, p.section.items, '.')) |dot| {
            var sub: std.ArrayList(u8) = .empty;
            sub.appendSlice(a, p.section.items[dot + 1 ..]) catch return false;
            p.section.shrinkRetainingCapacity(dot);
            p.sub = sub;
        }
        return p.section.items.len > 0;
    }

    /// config.c `get_extended_base_var`.
    fn quotedSub(p: *Parser, a: Allocator) bool {
        if (p.section.items.len == 0 or std.mem.indexOfScalar(u8, p.section.items, '.') != null) return false;
        var c = p.next();
        while (c == ' ' or c == '\t') c = p.next();
        if (c != '"') return false;
        var sub: std.ArrayList(u8) = .empty;
        while (true) {
            c = p.next();
            if (c == '\n') return false;
            if (c == '"') break;
            if (c == '\\') {
                c = p.next();
                if (c == '\n') return false;
            }
            sub.append(a, c) catch return false;
        }
        if (p.next() != ']') return false;
        p.sub = sub;
        return true;
    }

    /// config.c `get_value`: key, then `= value` or end of line (bare key).
    /// Null on a parse error, else whether a value was given.
    fn entry(p: *Parser, a: Allocator, first: u8) ?bool {
        p.key.clearRetainingCapacity();
        p.key.append(a, std.ascii.toLower(first)) catch return null;
        var c: u8 = undefined;
        while (true) {
            c = p.next();
            if (p.eof or !keyChar(c)) break;
            p.key.append(a, std.ascii.toLower(c)) catch return null;
        }
        while (c == ' ' or c == '\t') c = p.next();
        if (c == '\n') return false;
        if (c != '=') return null;
        return if (p.parseValue(a)) true else null;
    }

    /// config.c `parse_value`: quotes, `\` escapes, comments, trimming.
    fn parseValue(p: *Parser, a: Allocator) bool {
        p.value.clearRetainingCapacity();
        var quote = false;
        var comment = false;
        var trim_len: usize = 0;
        while (true) {
            var c = p.next();
            if (c == '\n') {
                if (quote) return false;
                if (trim_len > 0) p.value.shrinkRetainingCapacity(trim_len);
                return true;
            }
            if (comment) continue;
            if ((c == ' ' or c == '\t') and !quote) {
                if (trim_len == 0) trim_len = p.value.items.len;
                if (p.value.items.len > 0) p.value.append(a, c) catch return false;
                continue;
            }
            if (!quote and (c == ';' or c == '#')) {
                comment = true;
                continue;
            }
            trim_len = 0;
            if (c == '\\') {
                c = switch (p.next()) {
                    '\n' => continue,
                    't' => '\t',
                    'b' => 0x08,
                    'n' => '\n',
                    '\\' => '\\',
                    '"' => '"',
                    else => return false,
                };
            } else if (c == '"') {
                quote = !quote;
                continue;
            }
            p.value.append(a, c) catch return false;
        }
    }
};

fn eqlAny(v: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |s| if (std.mem.eql(u8, v, s)) return true;
    return false;
}

/// `git_config_bool`: bare key, empty, a word, or a plain integer.
fn isBool(v: ?[]const u8) bool {
    const s = v orelse return true;
    if (s.len == 0) return true;
    inline for (.{ "true", "yes", "on", "false", "no", "off" }) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    const digits = if (s[0] == '-') s[1..] else s;
    if (digits.len == 0 or digits.len > 9) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn boolOr(v: ?[]const u8, word: []const u8) bool {
    if (v) |s| if (std.ascii.eqlIgnoreCase(s, word)) return true;
    return isBool(v);
}

/// `interpolate_path` succeeds: no `~user` or `%(prefix)`, `~/` needs HOME.
fn pathOk(ctx: Ctx, v: ?[]const u8) bool {
    const s = v orelse return false;
    if (std.mem.startsWith(u8, s, "~/")) return ctx.home != null;
    return s.len > 0 and s[0] != '~' and !std.mem.startsWith(u8, s, "%(");
}

/// Follow `include.path` / `includeIf.*.path` to the file git would read.
fn includeOk(ctx: Ctx, dir: []const u8, v: ?[]const u8) bool {
    const s = v orelse return false;
    if (!pathOk(ctx, s)) return false;
    const path = if (std.mem.startsWith(u8, s, "~/"))
        std.fs.path.join(ctx.arena, &.{ ctx.home.?, s[2..] }) catch return false
    else if (std.fs.path.isAbsolute(s)) s else std.fs.path.join(ctx.arena, &.{ dir, s }) catch return false;
    return fileOk(ctx, path, true);
}

/// One `section[.sub].key = value`: true when git accepts it at startup.
fn entryOk(ctx: Ctx, dir: []const u8, section: []const u8, sub: ?[]const u8, key: []const u8, v: ?[]const u8) bool {
    const S = std.mem.eql;
    if (S(u8, section, "extensions")) return false; // repository format: git's call
    if (S(u8, section, "include")) return sub != null or !S(u8, key, "path") or includeOk(ctx, dir, v);
    if (S(u8, section, "includeif")) {
        const cond = sub orelse return true; // git ignores includeIf without a condition
        if (!S(u8, key, "path")) return true;
        if (std.ascii.startsWithIgnoreCase(cond, "hasconfig:")) return false; // carries its own rules
        return includeOk(ctx, dir, v);
    }
    if (S(u8, section, "color")) {
        if (sub) |s| return !std.ascii.startsWithIgnoreCase(s, "advice");
        if (S(u8, key, "pager")) return isBool(v);
        return !std.mem.startsWith(u8, key, "advice");
    }
    if (S(u8, section, "branch")) {
        if (sub != null) return true;
        if (S(u8, key, "autosetupmerge")) return (v != null and eqlAny(v.?, &.{ "always", "inherit", "simple" })) or isBool(v);
        if (S(u8, key, "autosetuprebase")) return v != null and eqlAny(v.?, &.{ "never", "local", "remote", "always" });
        return true;
    }
    if (S(u8, section, "pack")) return sub != null or !eqlAny(key, &.{ "packsizelimit", "compression" });
    if (S(u8, section, "pager")) return sub != null or !S(u8, key, "color") or isBool(v);
    const interpreted = [_][]const u8{ "core", "user", "author", "committer", "i18n", "push", "attr", "advice", "sparse" };
    if (!eqlAny(section, &interpreted)) return true; // not read by rev-parse
    if (sub != null) return false;
    if (S(u8, section, "core")) return coreOk(ctx, key, v);
    if (S(u8, section, "advice")) return isBool(v);
    if (S(u8, section, "push")) return !S(u8, key, "default") or (v != null and eqlAny(v.?, &.{ "nothing", "matching", "simple", "upstream", "tracking", "current" }));
    if (S(u8, section, "sparse")) return !S(u8, key, "expectfilesoutsideofpatterns") or isBool(v);
    if (S(u8, section, "user") and S(u8, key, "useconfigonly")) return isBool(v);
    if (S(u8, section, "i18n")) return !eqlAny(key, &.{ "commitencoding", "logoutputencoding" }) or v != null;
    if (S(u8, section, "attr")) return !S(u8, key, "tree") or v != null;
    return !eqlAny(key, &.{ "name", "email" }) or v != null; // user / author / committer
}

/// `git_default_core_config` and `check_repo_format`. Keys git checks in ways
/// not modelled here are false; keys it does not read at startup are true.
fn coreOk(ctx: Ctx, key: []const u8, v: ?[]const u8) bool {
    if (std.mem.eql(u8, key, "repositoryformatversion")) return v != null and eqlAny(v.?, &.{ "0", "1" });
    if (eqlAny(key, &.{ "filemode", "trustctime", "quotepath", "symlinks", "ignorecase", "bare", "ignorestat", "fsyncobjectfiles", "lockfilepid", "sparsecheckout", "sparsecheckoutcone", "precomposeunicode", "protecthfs", "protectntfs" })) return isBool(v);
    if (std.mem.eql(u8, key, "autocrlf")) return boolOr(v, "input");
    if (std.mem.eql(u8, key, "safecrlf")) return boolOr(v, "warn");
    if (std.mem.eql(u8, key, "logallrefupdates")) return boolOr(v, "always");
    if (eqlAny(key, &.{ "editor", "askpass", "checkroundtripencoding", "worktree" })) return v != null;
    if (eqlAny(key, &.{ "excludesfile", "attributesfile" })) return pathOk(ctx, v);
    return !eqlAny(key, &.{ "checkstat", "abbrev", "disambiguate", "loosecompression", "compression", "eol", "commentchar", "commentstring", "whitespace", "fsync", "fsyncmethod", "createobject" });
}
