//! Code-fence syntax highlighting — grok-build's token classes and colors
//! (grok-night / grok-day tmThemes), driven by a small line-resumable lexer
//! instead of syntect. One `State` threads across a fence's lines so block
//! comments and multiline strings survive line breaks; clone it for a
//! streaming tail the way grok's open-fence cache does.

const std = @import("std");

pub const Class = enum { text, comment, string, escape, number, keyword, type_name, builtin, function, operator, bracket, property };

/// grok-night (dark) token colors, verbatim from the tmTheme.
fn darkColor(c: Class) []const u8 {
    return switch (c) {
        .text => "\x1b[38;2;200;200;200m", // #c8c8c8
        .comment => "\x1b[38;2;81;89;125m", // #51597d
        .string => "\x1b[38;2;158;206;106m", // #9ece6a
        .escape => "\x1b[38;2;137;221;255m", // #89ddff
        .number => "\x1b[38;2;255;158;100m", // #ff9e64
        .keyword => "\x1b[38;2;187;154;247m", // #bb9af7
        .type_name => "\x1b[38;2;13;185;215m", // #0db9d7
        .builtin => "\x1b[38;2;13;185;215m", // #0db9d7
        .function => "\x1b[38;2;122;162;247m", // #7aa2f7
        .operator => "\x1b[38;2;137;221;255m", // #89ddff
        .bracket => "\x1b[38;2;154;189;245m", // #9abdf5
        .property => "\x1b[38;2;125;207;255m", // #7dcfff
    };
}

/// grok-day (light) token colors, verbatim from the tmTheme.
fn lightColor(c: Class) []const u8 {
    return switch (c) {
        .text => "\x1b[38;2;68;68;68m", // #444444
        .comment => "\x1b[38;2;144;144;144m", // #909090
        .string => "\x1b[38;2;55;142;35m", // #378E23
        .escape => "\x1b[38;2;85;128;168m", // #5580A8
        .number => "\x1b[38;2;195;105;30m", // #C3691E
        .keyword => "\x1b[38;2;125;75;198m", // #7D4BC6
        .type_name => "\x1b[38;2;15;135;162m", // #0F87A2
        .builtin => "\x1b[38;2;15;135;162m", // #0F87A2
        .function => "\x1b[38;2;47;100;210m", // #2F64D2
        .operator => "\x1b[38;2;85;128;168m", // #5580A8
        .bracket => "\x1b[38;2;74;114;176m", // #4A72B0
        .property => "\x1b[38;2;0;130;170m", // #0082AA
    };
}

pub fn color(c: Class, light: bool) []const u8 {
    return if (light) lightColor(c) else darkColor(c);
}

/// Code-block background band (grok `md_code_bg`): #1c1c1c dark / #e4e4e4 light.
pub fn codeBg(light: bool) []const u8 {
    return if (light) "\x1b[48;2;228;228;228m" else "\x1b[48;2;28;28;28m";
}

pub const Lang = struct {
    names: []const []const u8, // fence tokens AND file extensions
    line_comment: []const u8,
    block_open: []const u8 = "",
    block_close: []const u8 = "",
    keywords: []const []const u8,
    types: []const []const u8,
    builtins: []const []const u8 = &.{},
    hash_types_upper: bool = false, // Capitalized identifiers are types (Zig/Rust/Go style)
};

const zig_lang: Lang = .{
    .names = &.{ "zig", "ziglang" },
    .line_comment = "//",
    .keywords = &.{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "defer", "errdefer", "try", "catch", "orelse", "break", "continue", "struct", "enum", "union", "error", "test", "comptime", "inline", "export", "extern", "and", "or", "unreachable", "usingnamespace", "async", "await", "threadlocal", "packed", "volatile", "align", "callconv", "noalias" },
    .types = &.{ "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "bool", "void", "type", "anytype", "anyerror", "noreturn", "u21", "c_int", "null", "undefined", "true", "false" },
    .hash_types_upper = true,
};
const rust_lang: Lang = .{
    .names = &.{ "rust", "rs" },
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .keywords = &.{ "fn", "let", "mut", "pub", "use", "mod", "struct", "enum", "impl", "trait", "return", "if", "else", "while", "for", "loop", "match", "break", "continue", "move", "ref", "where", "async", "await", "dyn", "unsafe", "extern", "crate", "self", "Self", "super", "static", "const", "type", "in", "as" },
    .types = &.{ "u8", "u16", "u32", "u64", "usize", "i8", "i16", "i32", "i64", "isize", "f32", "f64", "bool", "str", "String", "Vec", "Option", "Result", "Box", "true", "false", "None", "Some", "Ok", "Err" },
    .hash_types_upper = true,
};
const py_lang: Lang = .{
    .names = &.{ "python", "py", "python3" },
    .line_comment = "#",
    .keywords = &.{ "def", "class", "return", "if", "elif", "else", "while", "for", "in", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "not", "and", "or", "is", "async", "await", "match", "case" },
    .types = &.{ "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "None", "True", "False", "self", "object" },
    .builtins = &.{ "print", "len", "range", "open", "enumerate", "zip", "map", "filter", "sorted", "isinstance", "super", "type", "getattr", "setattr", "hasattr" },
};
const js_lang: Lang = .{
    .names = &.{ "javascript", "js", "typescript", "ts", "jsx", "tsx", "mjs", "cjs" },
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .keywords = &.{ "function", "const", "let", "var", "return", "if", "else", "while", "for", "of", "in", "class", "extends", "new", "import", "export", "from", "default", "async", "await", "try", "catch", "finally", "throw", "switch", "case", "break", "continue", "typeof", "instanceof", "delete", "yield", "static", "get", "set", "interface", "implements", "enum", "declare", "readonly", "as", "satisfies" },
    .types = &.{ "string", "number", "boolean", "object", "any", "unknown", "never", "undefined", "null", "true", "false", "this", "void", "Promise", "Array", "Map", "Set" },
    .builtins = &.{ "console", "require", "module", "process", "JSON", "Math", "Object", "window", "document" },
    .hash_types_upper = true,
};
const go_lang: Lang = .{
    .names = &.{ "go", "golang" },
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .keywords = &.{ "func", "var", "const", "type", "struct", "interface", "map", "chan", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "package", "import", "fallthrough", "goto" },
    .types = &.{ "string", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte", "rune", "float32", "float64", "bool", "error", "any", "nil", "true", "false", "iota" },
    .builtins = &.{ "make", "len", "cap", "append", "copy", "new", "delete", "panic", "recover", "print", "println" },
    .hash_types_upper = true,
};
const c_lang: Lang = .{
    .names = &.{ "c", "h", "cpp", "cc", "cxx", "hpp", "c++" },
    .line_comment = "//",
    .block_open = "/*",
    .block_close = "*/",
    .keywords = &.{ "if", "else", "while", "for", "return", "break", "continue", "switch", "case", "default", "struct", "enum", "union", "typedef", "static", "extern", "const", "inline", "sizeof", "goto", "do", "class", "public", "private", "protected", "template", "typename", "namespace", "using", "new", "delete", "virtual", "override", "nullptr", "auto", "constexpr" },
    .types = &.{ "int", "char", "long", "short", "unsigned", "signed", "float", "double", "void", "bool", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "true", "false", "NULL" },
    .hash_types_upper = true,
};
const sh_lang: Lang = .{
    .names = &.{ "bash", "sh", "shell", "zsh", "console" },
    .line_comment = "#",
    .keywords = &.{ "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "return", "local", "export", "source", "in", "select", "until", "declare", "readonly", "shift", "exit", "set", "unset", "trap" },
    .types = &.{"true"},
    .builtins = &.{ "echo", "cd", "ls", "grep", "sed", "awk", "cat", "curl", "git", "rm", "cp", "mv", "mkdir", "printf", "read", "test", "which", "find", "xargs", "sort", "head", "tail" },
};
const json_lang: Lang = .{
    .names = &.{"json"},
    .line_comment = "",
    .keywords = &.{},
    .types = &.{ "true", "false", "null" },
};
const yaml_lang: Lang = .{
    .names = &.{ "yaml", "yml" },
    .line_comment = "#",
    .keywords = &.{},
    .types = &.{ "true", "false", "null", "yes", "no" },
};
const sql_lang: Lang = .{
    .names = &.{ "sql", "sqlite", "postgres", "mysql" },
    .line_comment = "--",
    .block_open = "/*",
    .block_close = "*/",
    .keywords = &.{ "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "in", "is", "like", "between", "union", "all", "distinct", "primary", "key", "foreign", "references", "drop", "alter", "add", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "AS", "AND", "OR", "NOT", "IN", "IS", "LIKE", "UNION", "PRIMARY", "KEY", "DROP", "ALTER", "ADD" },
    .types = &.{ "integer", "text", "real", "blob", "varchar", "boolean", "date", "timestamp", "INTEGER", "TEXT", "REAL", "BLOB", "VARCHAR", "BOOLEAN", "NULL" },
};

const langs = [_]*const Lang{ &zig_lang, &rust_lang, &py_lang, &js_lang, &go_lang, &c_lang, &sh_lang, &json_lang, &yaml_lang, &sql_lang };

/// Fence-info resolution, grok order: `start:end:path` citation form first
/// (extension lookup), then the whole info string as a token. Unknown → null
/// (the fence still gets the background band, just uncolored text).
pub fn resolve(fence_info: []const u8) ?*const Lang {
    const info = std.mem.trim(u8, fence_info, " \t");
    if (info.len == 0) return null;
    blk: {
        var it = std.mem.splitScalar(u8, info, ':');
        const a = it.next() orelse break :blk;
        const b = it.next() orelse break :blk;
        const path = it.rest();
        if (a.len == 0 or b.len == 0 or path.len == 0) break :blk;
        for (a) |ch| if (!std.ascii.isDigit(ch)) break :blk;
        for (b) |ch| if (!std.ascii.isDigit(ch)) break :blk;
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse break :blk;
        if (byName(path[dot + 1 ..])) |l| return l;
        break :blk;
    }
    return byName(info);
}

fn byName(token: []const u8) ?*const Lang {
    var buf: [24]u8 = undefined;
    if (token.len == 0 or token.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, token);
    for (&langs) |l| {
        for (l.names) |n| if (std.mem.eql(u8, lower, n)) return l;
    }
    return null;
}

/// Lexer state threaded across a fence's lines.
pub const State = struct {
    in_block_comment: bool = false,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '@';
}

fn listHas(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

/// Highlight one line into `out` as SGR spans. Emits fg colors only — the
/// caller owns the background band and the trailing reset.
pub fn highlightLine(out: *std.array_list.Managed(u8), line: []const u8, lang: *const Lang, st: *State, light: bool) !void {
    var i: usize = 0;
    var cls: ?Class = null;
    while (i < line.len) {
        if (st.in_block_comment) {
            const close = std.mem.indexOf(u8, line[i..], lang.block_close);
            const end = if (close) |c| i + c + lang.block_close.len else line.len;
            try emit(out, &cls, .comment, line[i..end], light);
            if (close != null) st.in_block_comment = false;
            i = end;
            continue;
        }
        const c = line[i];
        // comments
        if (lang.line_comment.len > 0 and std.mem.startsWith(u8, line[i..], lang.line_comment)) {
            try emit(out, &cls, .comment, line[i..], light);
            break;
        }
        if (lang.block_open.len > 0 and std.mem.startsWith(u8, line[i..], lang.block_open)) {
            st.in_block_comment = true;
            try emit(out, &cls, .comment, line[i .. i + lang.block_open.len], light);
            i += lang.block_open.len;
            continue;
        }
        // strings (single-line; escapes highlighted inside)
        if (c == '"' or c == '\'' or c == '`') {
            const quote = c;
            var j = i + 1;
            try emit(out, &cls, .string, line[i .. i + 1], light);
            while (j < line.len) {
                if (line[j] == '\\' and j + 1 < line.len) {
                    try emit(out, &cls, .escape, line[j .. j + 2], light);
                    j += 2;
                    continue;
                }
                if (line[j] == quote) break;
                const k = std.mem.indexOfAnyPos(u8, line, j, &.{ '\\', quote }) orelse line.len;
                try emit(out, &cls, .string, line[j..k], light);
                j = k;
            }
            if (j < line.len) {
                try emit(out, &cls, .string, line[j .. j + 1], light);
                j += 1;
            }
            i = j;
            continue;
        }
        // numbers
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < line.len and (std.ascii.isHex(line[j]) or line[j] == '.' or line[j] == 'x' or line[j] == '_' or line[j] == 'o' or line[j] == 'b')) j += 1;
            try emit(out, &cls, .number, line[i..j], light);
            i = j;
            continue;
        }
        // identifiers
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '@') {
            var j = i + 1;
            while (j < line.len and isIdent(line[j])) j += 1;
            const word = line[i..j];
            const wc: Class = if (listHas(lang.keywords, word))
                .keyword
            else if (listHas(lang.types, word))
                .type_name
            else if (listHas(lang.builtins, word))
                .builtin
            else if (word[0] == '@')
                .builtin
            else if (j < line.len and line[j] == '(')
                .function
            else if (lang.hash_types_upper and std.ascii.isUpper(word[0]))
                .type_name
            else if (j < line.len and line[j] == ':' and lang == &json_lang)
                .property
            else
                .text;
            try emit(out, &cls, wc, word, light);
            i = j;
            continue;
        }
        // brackets vs operators vs plain
        const oc: Class = switch (c) {
            '(', ')', '[', ']', '{', '}' => .bracket,
            '+', '-', '*', '/', '=', '<', '>', '!', '&', '|', '^', '%', '~', '?', ';', ':', ',', '.' => .operator,
            else => .text,
        };
        try emit(out, &cls, oc, line[i .. i + 1], light);
        i += 1;
    }
}

fn emit(out: *std.array_list.Managed(u8), current: *?Class, cls: Class, text: []const u8, light: bool) !void {
    if (text.len == 0) return;
    if (current.* != cls) {
        try out.appendSlice(color(cls, light));
        current.* = cls;
    }
    try out.appendSlice(text);
}

test "zig line: keywords, types, strings, numbers, comment take grok-night colors" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    var st: State = .{};
    try highlightLine(&out, "const x: u32 = 0x1f; // note \"quoted\"", &zig_lang, &st, false);
    const s = out.items;
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[38;2;187;154;247mconst") != null); // keyword
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[38;2;13;185;215mu32") != null); // type
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[38;2;255;158;100m0x1f") != null); // number
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b[38;2;81;89;125m// note \"quoted\"") != null); // comment eats the rest
}

test "block comment state survives across lines" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    var st: State = .{};
    try highlightLine(&out, "let a = 1; /* open", &js_lang, &st, false);
    try std.testing.expect(st.in_block_comment);
    out.clearRetainingCapacity();
    try highlightLine(&out, "still comment */ let b = 2;", &js_lang, &st, false);
    try std.testing.expect(!st.in_block_comment);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;81;89;125mstill comment */") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;187;154;247mlet") != null);
}

test "fence info resolution: token, citation path, unknown" {
    try std.testing.expect(resolve("rust") == &rust_lang);
    try std.testing.expect(resolve("py") == &py_lang);
    try std.testing.expect(resolve("37:65:crates/foo/src/bar.rs") == &rust_lang);
    try std.testing.expect(resolve("rust title=x") == null); // whole-string token, grok semantics
    try std.testing.expect(resolve("") == null);
    try std.testing.expect(resolve("madeuplang") == null);
}

test "light polarity swaps to grok-day colors" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    var st: State = .{};
    try highlightLine(&out, "def f():", &py_lang, &st, true);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;125;75;198mdef") != null); // #7D4BC6
}

test "strings color their escapes separately" {
    var out = std.array_list.Managed(u8).init(std.testing.allocator);
    defer out.deinit();
    var st: State = .{};
    try highlightLine(&out, "s = \"a\\nb\"", &py_lang, &st, false);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;137;221;255m\\n") != null);
    // the opening quote and 'a' share one string span; 'b' re-opens it after the escape
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;158;206;106m\"a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[38;2;158;206;106mb") != null);
}
