//! Windows shell detection and command preparation.
//!
//! Passing `cmd.exe /c <cmd>` through `std.process.spawn` applies Win32
//! `CommandLineToArgvW` escaping (`\"`) to `argv[2]`. `cmd.exe /c` does not
//! unescape `\"`, so commands like `python -c "import os"` or
//! `powershell -Command "..."` arrive with literal backslashes and fail with
//! syntax errors.
//!
//! Strategy on Windows:
//!   1. Default to `cmd.exe /d /c` so native Windows backslash paths
//!      (`C:\Users\...`, `.\bin\tool.exe`) work without POSIX backslash
//!      stripping. Whenever `cmd` contains double quotes or newlines, write a
//!      temporary `.cmd` script and run `cmd.exe /d /c <temp.cmd>` so
//!      `argvToCommandLineWindows` never sees embedded quotes to escape.
//!   2. Opt-in Git Bash via `GRAFF_WINDOWS_SHELL=bash` (auto-detecting Git
//!      Bash on PATH or standard Git install paths while skipping WSL's
//!      `System32\bash.exe` / `WindowsApps\bash.exe` shims) or an explicit
//!      `GRAFF_WINDOWS_SHELL=<path>` executable path.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Kind = enum { posix, git_bash, cmd };

var g_kind: Kind = if (builtin.os.tag == .windows) .cmd else .posix;
var g_bash_buf: [std.fs.max_path_bytes]u8 = undefined;
var g_bash_len: usize = 0;
var g_script_seq: std.atomic.Value(u64) = .init(0);

pub fn kind() Kind {
    return g_kind;
}

pub fn isGitBash() bool {
    return g_kind == .git_bash and g_bash_len > 0;
}

pub fn gitBashPath() ?[]const u8 {
    if (!isGitBash()) return null;
    return g_bash_buf[0..g_bash_len];
}

/// Test hook: set the active shell mode and optional bash path.
pub fn setForTest(k: Kind, bash_path: []const u8) void {
    g_kind = k;
    const n = @min(bash_path.len, g_bash_buf.len);
    @memcpy(g_bash_buf[0..n], bash_path[0..n]);
    g_bash_len = n;
}

fn rememberBash(path: []const u8) void {
    if (path.len == 0 or path.len > g_bash_buf.len) return;
    @memcpy(g_bash_buf[0..path.len], path);
    g_bash_len = path.len;
    g_kind = .git_bash;
}

/// True when `path` points at the WSL launcher shim rather than Git Bash.
pub fn isWslLauncher(path: []const u8) bool {
    var lower_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len > lower_buf.len) return false;
    for (path, 0..) |c, i| {
        lower_buf[i] = if (c == '/') '\\' else std.ascii.toLower(c);
    }
    const norm = lower_buf[0..path.len];
    return std.mem.indexOf(u8, norm, "\\system32\\bash.exe") != null or
        std.mem.indexOf(u8, norm, "\\syswow64\\bash.exe") != null or
        std.mem.indexOf(u8, norm, "\\windowsapps\\bash.exe") != null;
}

fn isExistingFile(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .file;
}

/// Detect the Windows shell once at startup (before the tool catalog renders).
/// Defaults to `cmd.exe` (preserving Windows backslash paths); opts into Git
/// Bash when `GRAFF_WINDOWS_SHELL=bash` (or `git-bash` / an explicit path).
/// No-op on POSIX platforms.
pub fn detect(io: Io, environ_map: anytype) void {
    if (builtin.os.tag != .windows) {
        g_kind = .posix;
        g_bash_len = 0;
        return;
    }
    g_kind = .cmd;
    g_bash_len = 0;

    const raw = environ_map.get("GRAFF_WINDOWS_SHELL") orelse return;
    const val = std.mem.trim(u8, raw, " \t\r\n");
    if (val.len == 0 or std.ascii.eqlIgnoreCase(val, "cmd") or std.ascii.eqlIgnoreCase(val, "cmd.exe")) return;
    if (!std.ascii.eqlIgnoreCase(val, "bash") and !std.ascii.eqlIgnoreCase(val, "git-bash")) {
        if (isExistingFile(io, val)) rememberBash(val);
        return;
    }

    var cand_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (environ_map.get("PATH")) |path_env| {
        var dirs = std.mem.tokenizeScalar(u8, path_env, ';');
        while (dirs.next()) |raw_dir| {
            const dir = std.mem.trimEnd(u8, std.mem.trim(u8, raw_dir, " \t\""), "/\\");
            if (dir.len == 0) continue;
            const cand = std.fmt.bufPrint(&cand_buf, "{s}\\bash.exe", .{dir}) catch continue;
            if (isWslLauncher(cand)) continue;
            if (isExistingFile(io, cand)) {
                rememberBash(cand);
                return;
            }
        }
    }

    const roots = [_]?[]const u8{
        environ_map.get("ProgramFiles"),
        environ_map.get("ProgramFiles(x86)"),
        environ_map.get("LOCALAPPDATA"),
    };
    const suffixes = [_][]const u8{
        "\\Git\\bin\\bash.exe",
        "\\Git\\usr\\bin\\bash.exe",
        "\\Programs\\Git\\bin\\bash.exe",
        "\\Programs\\Git\\usr\\bin\\bash.exe",
    };
    for (roots) |root_opt| {
        const root = std.mem.trimEnd(u8, root_opt orelse continue, "/\\");
        if (root.len == 0) continue;
        for (suffixes) |suf| {
            const cand = std.fmt.bufPrint(&cand_buf, "{s}{s}", .{ root, suf }) catch continue;
            if (isExistingFile(io, cand)) {
                rememberBash(cand);
                return;
            }
        }
    }
}

/// True when passing `cmd` directly as `argv[2]` to `cmd.exe /c` would suffer
/// Win32 `CommandLineToArgvW` quote escaping (`\"`) or newline truncation.
pub fn needsCmdScript(cmd: []const u8) bool {
    return std.mem.indexOfAny(u8, cmd, "\"\r\n") != null;
}

fn isEnvVarSpan(s: []const u8, pct_idx: usize) ?usize {
    if (pct_idx + 2 >= s.len) return null;
    const first = s[pct_idx + 1];
    if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;
    var i = pct_idx + 2;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '%') return i;
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
    }
    return null;
}

/// Build `@echo off` batch script content for `cmd.exe /d /c <script.cmd>`.
/// Preserves quotes verbatim (avoiding `\"` corruption) and doubles stray `%`
/// characters (like `'%Y-%m-%d'` or `'%{http_code}'`) so batch parsing passes
/// a literal `%` to child programs while keeping `%ENV_VAR%` expansion intact.
pub fn formatCmdScript(gpa: Allocator, cmd: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "@echo off\r\n");
    var i: usize = 0;
    while (i < cmd.len) {
        const c = cmd[i];
        if (c == '\r') {
            i += 1;
            continue;
        }
        if (c == '\n') {
            try out.appendSlice(gpa, "\r\n");
            i += 1;
            continue;
        }
        if (c == '%') {
            if (i + 1 < cmd.len and cmd[i + 1] == '%') {
                try out.appendSlice(gpa, "%%");
                i += 2;
                continue;
            }
            if (isEnvVarSpan(cmd, i)) |close_idx| {
                try out.appendSlice(gpa, cmd[i .. close_idx + 1]);
                i = close_idx + 1;
                continue;
            }
            try out.appendSlice(gpa, "%%");
            i += 1;
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    try out.appendSlice(gpa, "\r\n");
    return out.toOwnedSlice(gpa);
}

fn writeTempCmdScript(gpa: Allocator, io: Io, cmd: []const u8) ![]u8 {
    const body = try formatCmdScript(gpa, cmd);
    defer gpa.free(body);
    const env_map = @import("tool_env.zig").get();
    const raw_dir = if (env_map) |m|
        (m.get("TEMP") orelse m.get("TMP") orelse m.get("TMPDIR") orelse ".")
    else
        ".";
    const dir = std.mem.trimEnd(u8, raw_dir, "/\\");
    const seq = g_script_seq.fetchAdd(1, .monotonic);
    const stamp: u64 = @intCast(@max(Io.Timestamp.now(io, .awake).nanoseconds, 0));
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    const path = try std.fmt.allocPrint(gpa, "{s}{s}graff-cmd-{d}-{d}.cmd", .{
        if (dir.len > 0) dir else ".",
        sep,
        stamp,
        seq,
    });
    errdefer gpa.free(path);
    const file = if (std.fs.path.isAbsolute(path))
        try Io.Dir.createFileAbsolute(io, path, .{ .truncate = true })
    else
        try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(io, &wbuf);
    try fw.interface.writeAll(body);
    try fw.interface.flush();
    return path;
}

pub fn removeTempScript(io: Io, path: []const u8) void {
    if (std.fs.path.isAbsolute(path)) {
        Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else {
        Io.Dir.cwd().deleteFile(io, path) catch {};
    }
}

pub const Prepared = struct {
    argv_buf: [4][]const u8 = undefined,
    argv_len: usize = 3,
    temp_script: ?[]u8 = null,

    pub fn argv(self: *const Prepared) []const []const u8 {
        return self.argv_buf[0..self.argv_len];
    }

    pub fn takeTempScript(self: *Prepared) ?[]u8 {
        const p = self.temp_script;
        self.temp_script = null;
        return p;
    }

    pub fn cleanup(self: *Prepared, gpa: Allocator, io: Io) void {
        if (self.temp_script) |p| {
            removeTempScript(io, p);
            gpa.free(p);
            self.temp_script = null;
        }
    }
};

/// Prepare the shell argv for `cmd`. On POSIX returns `/bin/sh -c <cmd>`.
/// On Windows uses detected Git Bash (`bash.exe -c <cmd>`), or `cmd.exe /d /c`
/// backed by a temporary `.cmd` file whenever `cmd` contains quotes or newlines.
pub fn prepare(gpa: Allocator, io: Io, cmd: []const u8) Prepared {
    if (builtin.os.tag != .windows) {
        return .{ .argv_buf = .{ "/bin/sh", "-c", cmd, "" }, .argv_len = 3 };
    }
    if (gitBashPath()) |bash| {
        return .{ .argv_buf = .{ bash, "-c", cmd, "" }, .argv_len = 3 };
    }
    if (needsCmdScript(cmd)) {
        if (writeTempCmdScript(gpa, io, cmd)) |script_path| {
            return .{ .argv_buf = .{ "cmd.exe", "/d", "/c", script_path }, .argv_len = 4, .temp_script = script_path };
        } else |_| {}
    }
    return .{ .argv_buf = .{ "cmd.exe", "/d", "/c", cmd }, .argv_len = 4 };
}

test "isWslLauncher distinguishes WSL shims from Git Bash" {
    try std.testing.expect(isWslLauncher("C:\\Windows\\System32\\bash.exe"));
    try std.testing.expect(isWslLauncher("c:/windows/SysWOW64/bash.exe"));
    try std.testing.expect(isWslLauncher("C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe"));
    try std.testing.expect(!isWslLauncher("C:\\Program Files\\Git\\bin\\bash.exe"));
    try std.testing.expect(!isWslLauncher("C:\\Program Files\\Git\\usr\\bin\\bash.exe"));
}

test "needsCmdScript catches quoted and multiline Windows commands" {
    try std.testing.expect(needsCmdScript("python -c \"import os; print(1)\""));
    try std.testing.expect(needsCmdScript("echo a\necho b"));
    try std.testing.expect(!needsCmdScript("dir /b"));
    try std.testing.expect(!needsCmdScript("python script.py"));
}

test "formatCmdScript preserves double quotes and env vars while escaping literal percent tokens" {
    const gpa = std.testing.allocator;
    const py = try formatCmdScript(gpa, "python -c \"import datetime; print(datetime.date.today().strftime('%Y-%m-%d'))\"");
    defer gpa.free(py);
    try std.testing.expectEqualStrings(
        "@echo off\r\npython -c \"import datetime; print(datetime.date.today().strftime('%%Y-%%m-%%d'))\"\r\n",
        py,
    );

    const curl = try formatCmdScript(gpa, "curl -s -o NUL -w \"%{http_code}\" https://example.com && echo %USERPROFILE%");
    defer gpa.free(curl);
    try std.testing.expectEqualStrings(
        "@echo off\r\ncurl -s -o NUL -w \"%%{http_code}\" https://example.com && echo %USERPROFILE%\r\n",
        curl,
    );
}

test "Windows cmd.exe temp script runs quoted commands without backslash-quote corruption" {
    if (builtin.os.tag != .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var prep = prepare(gpa, io, "powershell -NoProfile -Command \"Write-Output ('ok:' + '100%')\"");
    defer prep.cleanup(gpa, io);
    try std.testing.expect(prep.temp_script != null);
    const run = try @import("process_runner.zig").runCapped(gpa, io, prep.argv(), 4096, 4096, 30_000);
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    try std.testing.expect(@import("process_runner.zig").ranOk(run));
    try std.testing.expectEqualStrings("ok:100%", std.mem.trim(u8, run.stdout, " \r\n"));
}
