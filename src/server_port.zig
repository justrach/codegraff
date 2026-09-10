//! Conservative, best-effort preflight. This is not a bind reservation.
const std = @import("std");
const jobs = @import("jobs.zig");

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn numeric(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    for (s) |c| if (c < '0' or c > '9') return null;
    const p = std.fmt.parseInt(u16, s, 10) catch return null;
    return if (p == 0) null else p;
}

// Quotes remain opaque: text containing flags is never interpreted as flags.
// Complex shell syntax is deliberately unsupported rather than guessed.
fn tokens(cmd: []const u8, out: *[128][]const u8) ?usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < cmd.len) {
        while (i < cmd.len and std.ascii.isWhitespace(cmd[i])) : (i += 1) {
            if (cmd[i] == '\n' or cmd[i] == '\r') return null;
        }
        if (i == cmd.len) break;
        if (n == out.len) return null;
        const start = i;
        var quote: u8 = 0;
        while (i < cmd.len) : (i += 1) {
            const c = cmd[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
            } else if (std.ascii.isWhitespace(c)) break else if (std.mem.indexOfScalar(u8, "\\$`;|<>()#", c) != null) return null;
        }
        if (quote != 0) return null;
        out[n] = cmd[start..i];
        n += 1;
    }
    return n;
}

fn known(t: []const []const u8) ?usize {
    if (t.len == 0) return null;
    const base = std.fs.path.basename(t[0]);
    if (eq(base, "next")) {
        if (t.len > 1 and (eq(t[1], "dev") or eq(t[1], "start"))) return 2;
        return null;
    }
    if (eq(base, "vite") or eq(base, "uvicorn") or eq(base, "http-server")) return 1;
    if (eq(base, "npm") or eq(base, "pnpm") or eq(base, "yarn") or eq(base, "bun")) {
        var i: usize = 1;
        if (i < t.len and eq(t[i], "run")) i += 1;
        if (i < t.len and (eq(t[i], "dev") or eq(t[i], "start") or eq(t[i], "serve"))) return i + 1;
    }
    if (eq(base, "npx") and t.len > 1) {
        // Do not recursively accept arbitrary package-manager invocations.
        if (eq(t[1], "next") or eq(t[1], "vite") or eq(t[1], "http-server")) {
            if (known(t[1..])) |n| return n + 1;
        }
    }
    return null;
}

/// Returns only an explicit numeric request in a recognized server launch.
/// cd DIR && launch is supported; pipelines, substitutions and scripts are not.
pub fn requested(cmd: []const u8) ?u16 {
    var buf: [128][]const u8 = undefined;
    const count = tokens(cmd, &buf) orelse return null;
    var t = buf[0..count];
    if (t.len >= 3 and eq(t[0], "cd") and eq(t[2], "&&")) t = t[3..];
    for (t) |word| if (std.mem.indexOfScalar(u8, word, '&') != null) return null;
    var port: ?u16 = null;
    while (t.len > 0 and std.mem.indexOfScalar(u8, t[0], '=') != null) {
        const split = std.mem.indexOfScalar(u8, t[0], '=').?;
        if (split == 0) return null;
        for (t[0][0..split], 0..) |c, i| {
            if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return null;
        }
        if (eq(t[0][0..split], "PORT")) port = numeric(t[0][split + 1 ..]) orelse return null;
        t = t[1..];
    }
    var i = known(t) orelse return null;
    while (i < t.len) : (i += 1) {
        const word = t[i];
        if (eq(word, "--port") or eq(word, "-p")) {
            i += 1;
            if (i == t.len) return null;
            port = numeric(t[i]) orelse return null;
        } else if (std.mem.startsWith(u8, word, "--port=")) {
            port = numeric(word[7..]) orelse return null;
        }
    }
    return port;
}

pub const Status = enum { clear, conflict, unknown };

/// lsof -Fn yields nADDRESS:PORT for both IPv4 and IPv6. Match numeric
/// ports, never address families, substrings, process names or PID ownership.
pub fn listenerStatus(output: []const u8, port: u16) Status {
    var lines = std.mem.tokenizeAny(u8, output, "\r\n");
    var malformed = false;
    while (lines.next()) |line| {
        if (line[0] != 'n') continue;
        const colon = std.mem.lastIndexOfScalar(u8, line, ':') orelse {
            malformed = true;
            continue;
        };
        const p = numeric(line[colon + 1 ..]) orelse {
            malformed = true;
            continue;
        };
        if (p == port) return .conflict;
    }
    return if (malformed) .unknown else .clear;
}

pub fn probe(gpa: std.mem.Allocator, io: std.Io, port: u16) Status {
    // No -i4/-i6: inspect ALL TCP listeners. Bound both runtime and output.
    const run = jobs.runCappedWithOptions(gpa, io, &.{ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fn" }, 256 * 1024, 4096, 2000, .{}) catch return .unknown;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const parsed = listenerStatus(run.stdout, port);
    if (parsed == .conflict) return .conflict;
    if (run.timed_out or run.cancelled or run.stdout_truncated or run.stderr_truncated or run.stderr.len != 0) return .unknown;
    switch (run.term) {
        .exited => |code| {
            if (code != 0 and !(code == 1 and run.stdout.len == 0)) return .unknown;
        },
        else => return .unknown,
    }
    return parsed;
}

pub const unknown_warning = "[warning: server port preflight unavailable or incomplete; port availability is unknown. Launching without verified collision protection; no existing listener was stopped.]\n";

test "server port: conservative command table" {
    const Case = struct { cmd: []const u8, port: ?u16 };
    for ([_]Case{
        .{ .cmd = "next dev --port 3000", .port = 3000 },
        .{ .cmd = "npx next start --port=3001", .port = 3001 },
        .{ .cmd = "npm run dev -- -p 3002", .port = 3002 },
        .{ .cmd = "PORT=3003 pnpm dev", .port = 3003 },
        .{ .cmd = "cd 'my project' && PORT=3004 yarn start", .port = 3004 },
        .{ .cmd = "vite --host ::1 --port=3000", .port = 3000 },
        .{ .cmd = "uvicorn app:app --port 8000", .port = 8000 },
        .{ .cmd = "git -p log", .port = null },
        .{ .cmd = "curl -p 3000 localhost", .port = null },
        .{ .cmd = "arbitrary --port 3000", .port = null },
        .{ .cmd = "PORT=3000 echo hello", .port = null },
        .{ .cmd = "echo 'next dev --port 3000'", .port = null },
        .{ .cmd = "next dev '--port 3000'", .port = null },
        .{ .cmd = "next dev --port $PORT", .port = null },
        .{ .cmd = "next dev --port 65536", .port = null },
        .{ .cmd = "next dev --port 0", .port = null },
        .{ .cmd = "next dev --port 3000 | cat", .port = null },
        .{ .cmd = "next dev --port 3000; echo done", .port = null },
        .{ .cmd = "next dev --port 3000\necho done", .port = null },
        .{ .cmd = "next dev --port '3000'", .port = null },
        .{ .cmd = "npm install --port 3000", .port = null },
        .{ .cmd = "next dev # --port 3000", .port = null },
    }) |c| try std.testing.expectEqual(c.port, requested(c.cmd));
}

test "server port: all listener families and exact numeric ports" {
    try std.testing.expectEqual(Status.conflict, listenerStatus("p123\nf5\nn127.0.0.1:3000\n", 3000));
    try std.testing.expectEqual(Status.conflict, listenerStatus("p456\nf6\nn[::1]:3000\n", 3000));
    try std.testing.expectEqual(Status.conflict, listenerStatus("n*:3000\n", 3000));
    try std.testing.expectEqual(Status.clear, listenerStatus("n[::1]:13000\nn127.0.0.1:3001\n", 3000));
    try std.testing.expectEqual(Status.clear, listenerStatus("", 3000));
    try std.testing.expectEqual(Status.unknown, listenerStatus("nlocalhost:http\n", 3000));
}

test "server port: loopback listener preflight does not stop listener" {
    const io = std.testing.io;
    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);
    const status = probe(std.testing.allocator, io, server.socket.address.getPort());
    if (status == .unknown) return error.SkipZigTest; // lsof is optional
    try std.testing.expectEqual(Status.conflict, status);
    var target = server.socket.address;
    const stream = try std.Io.net.IpAddress.connect(&target, io, .{ .mode = .stream });
    defer stream.close(io);
}
