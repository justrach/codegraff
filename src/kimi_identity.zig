//! Kimi Coding request identity. Field *shapes* follow MoonshotAI/kimi-code
//! `packages/oauth/src/identity.ts` (hostname, Node-style device model,
//! `os.release()`). The product token stays `graff/<version>`: Moonshot treats
//! a spoofed User-Agent as a violation, and a host must state its own name.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const user_agent = "graff/" ++ @import("build_options").version;
pub const platform = "kimi_code_cli";
pub const version = @import("build_options").version;

pub var device_id: []const u8 = "unknown";
pub var device_name: []const u8 = "unknown";
pub var device_model: []const u8 = "unknown";
pub var os_version: []const u8 = "unknown";

var device_name_buf: [256]u8 = undefined;
var device_model_buf: [128]u8 = undefined;
var os_version_buf: [128]u8 = undefined;
var host_fields_ready = false;

const private_file_permissions: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o600) else .default_file;
const private_dir_permissions: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit) @enumFromInt(0o700) else .default_dir;

/// Node `os.arch()` names. kimi-code puts these in `X-Msh-Device-Model`.
pub fn nodeArch(tag: std.Target.Cpu.Arch) []const u8 {
    return switch (tag) {
        .x86_64 => "x64",
        .x86 => "ia32",
        .aarch64 => "arm64",
        .arm, .armeb, .thumb, .thumbeb => "arm",
        else => @tagName(tag),
    };
}

/// kimi-code `deviceModel()`: `Windows ${release} ${arch}`, `macOS ${product} ${arch}`,
/// otherwise `${type} ${release} ${arch}`.
pub fn formatDeviceModel(
    buf: []u8,
    os_tag: std.Target.Os.Tag,
    release: []const u8,
    macos_product: ?[]const u8,
    arch: []const u8,
) []const u8 {
    const rel = if (release.len == 0) "unknown" else release;
    const printed = switch (os_tag) {
        .windows => std.fmt.bufPrint(buf, "Windows {s} {s}", .{ rel, arch }),
        .macos => std.fmt.bufPrint(buf, "macOS {s} {s}", .{ macos_product orelse rel, arch }),
        .linux => std.fmt.bufPrint(buf, "Linux {s} {s}", .{ rel, arch }),
        .freebsd => std.fmt.bufPrint(buf, "FreeBSD {s} {s}", .{ rel, arch }),
        else => std.fmt.bufPrint(buf, "{s} {s} {s}", .{ @tagName(os_tag), rel, arch }),
    };
    return printed catch "unknown";
}

/// kimi-code `asciiHeader`: printable ASCII, trimmed, else `unknown`.
pub fn persistAscii(buf: []u8, value: []const u8) []const u8 {
    var n: usize = 0;
    for (value) |c| {
        if (c >= 0x20 and c <= 0x7E) {
            if (n == buf.len) break;
            buf[n] = c;
            n += 1;
        }
    }
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return if (trimmed.len == 0) "unknown" else trimmed;
}

fn secureDir(io: Io, path: []const u8) void {
    const dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (builtin.os.tag != .windows) dir.setPermissions(io, private_dir_permissions) catch {};
}

fn validDeviceId(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn readHostname(buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return windowsHostname(buf);
    if (comptime builtin.os.tag == .wasi) return "unknown";
    const uts = std.posix.uname();
    const host = std.mem.sliceTo(&uts.nodename, 0);
    const n = @min(host.len, buf.len);
    @memcpy(buf[0..n], host[0..n]);
    return buf[0..n];
}

fn readOsRelease(buf: []u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return windowsRelease(buf);
    if (comptime builtin.os.tag == .wasi) return "unknown";
    const uts = std.posix.uname();
    const rel = std.mem.sliceTo(&uts.release, 0);
    const n = @min(rel.len, buf.len);
    @memcpy(buf[0..n], rel[0..n]);
    return buf[0..n];
}

fn windowsHostname(buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return "unknown";
    const w = std.os.windows;
    const GetComputerNameExA = struct {
        extern "kernel32" fn GetComputerNameExA(NameType: u32, lpBuffer: ?[*]u8, nSize: *u32) callconv(.winapi) w.BOOL;
    }.GetComputerNameExA;
    var size: u32 = @intCast(buf.len);
    if (GetComputerNameExA(1, buf.ptr, &size).toBool() and size > 0)
        return buf[0..@min(size, buf.len)];
    return "unknown";
}

fn windowsRelease(buf: []u8) []const u8 {
    if (comptime builtin.os.tag != .windows) return "unknown";
    var info: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    info.dwOSVersionInfoSize = @sizeOf(@TypeOf(info));
    _ = std.os.windows.ntdll.RtlGetVersion(&info);
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{
        info.dwMajorVersion,
        info.dwMinorVersion,
        info.dwBuildNumber,
    }) catch "unknown";
}

fn readMacosProduct(buf: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .macos) return null;
    const sysctlbyname = struct {
        extern "c" fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
    }.sysctlbyname;
    var len: usize = buf.len;
    if (sysctlbyname("kern.osproductversion", buf.ptr, &len, null, 0) != 0) return null;
    if (len == 0) return null;
    const n = if (buf[len - 1] == 0) len - 1 else len;
    return if (n == 0) null else buf[0..n];
}

pub fn fillHostFields() void {
    if (host_fields_ready) return;
    host_fields_ready = true;
    const arch = nodeArch(builtin.cpu.arch);
    var host_raw: [256]u8 = undefined;
    var rel_raw: [128]u8 = undefined;
    var product_raw: [64]u8 = undefined;
    device_name = persistAscii(&device_name_buf, readHostname(&host_raw));
    os_version = persistAscii(&os_version_buf, readOsRelease(&rel_raw));
    const product = readMacosProduct(&product_raw);
    device_model = formatDeviceModel(&device_model_buf, builtin.os.tag, os_version, product, arch);
}

/// Kimi Code sends a stable random device id with its X-Msh identity headers.
/// Graff owns a separate ~/.kimi/device_id so it never mutates another CLI's
/// credential store or impersonates that installation.
pub fn initIdentity(io: Io, arena: Allocator, home: []const u8) void {
    fillHostFields();
    if (!std.mem.eql(u8, device_id, "unknown") or home.len == 0) return;
    const dir = std.fmt.allocPrint(arena, "{s}/.kimi", .{home}) catch return;
    const path = std.fmt.allocPrint(arena, "{s}/device_id", .{dir}) catch return;
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(128))) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (validDeviceId(value)) {
            device_id = arena.dupe(u8, value) catch "unknown";
            secureDir(io, dir);
            const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            defer file.close(io);
            file.setPermissions(io, private_file_permissions) catch {};
            return;
        }
    } else |_| {}
    var random: [16]u8 = undefined;
    io.random(&random);
    random[6] = (random[6] & 0x0f) | 0x40;
    random[8] = (random[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(random, .lower);
    const id = arena.alloc(u8, 36) catch return;
    @memcpy(id[0..8], hex[0..8]);
    id[8] = '-';
    @memcpy(id[9..13], hex[8..12]);
    id[13] = '-';
    @memcpy(id[14..18], hex[12..16]);
    id[18] = '-';
    @memcpy(id[19..23], hex[16..20]);
    id[23] = '-';
    @memcpy(id[24..36], hex[20..32]);
    device_id = id;
    Io.Dir.cwd().createDir(io, dir, private_dir_permissions) catch {};
    secureDir(io, dir);
    const file = Io.Dir.cwd().createFile(io, path, .{ .permissions = private_file_permissions }) catch return;
    defer file.close(io);
    file.setPermissions(io, private_file_permissions) catch {};
    var buf: [64]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.interface.print("{s}\n", .{id}) catch return;
    writer.interface.flush() catch {};
}

pub fn identityHeaders(buf: []std.http.Header) []std.http.Header {
    fillHostFields();
    if (buf.len < 6) return buf[0..0];
    buf[0] = .{ .name = "X-Msh-Platform", .value = platform };
    buf[1] = .{ .name = "X-Msh-Version", .value = version };
    buf[2] = .{ .name = "X-Msh-Device-Name", .value = device_name };
    buf[3] = .{ .name = "X-Msh-Device-Model", .value = device_model };
    buf[4] = .{ .name = "X-Msh-Os-Version", .value = os_version };
    buf[5] = .{ .name = "X-Msh-Device-Id", .value = device_id };
    return buf[0..6];
}

test "user_agent is graff/<version>, not a spoofed kimi-code-cli token" {
    try std.testing.expect(std.mem.startsWith(u8, user_agent, "graff/"));
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "kimi-code-cli") == null);
    try std.testing.expect(std.mem.indexOf(u8, user_agent, "claude-code") == null);
}

test "nodeArch matches Node os.arch() names kimi-code puts in Device-Model" {
    try std.testing.expectEqualStrings("x64", nodeArch(.x86_64));
    try std.testing.expectEqualStrings("arm64", nodeArch(.aarch64));
    try std.testing.expectEqualStrings("ia32", nodeArch(.x86));
}

test "formatDeviceModel matches kimi-code deviceModel() on Windows, macOS, Linux" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Windows 10.0.26100 x64",
        formatDeviceModel(&buf, .windows, "10.0.26100", null, "x64"),
    );
    try std.testing.expectEqualStrings(
        "macOS 15.4.1 arm64",
        formatDeviceModel(&buf, .macos, "24.4.0", "15.4.1", "arm64"),
    );
    try std.testing.expectEqualStrings(
        "macOS 24.4.0 arm64",
        formatDeviceModel(&buf, .macos, "24.4.0", null, "arm64"),
    );
    try std.testing.expectEqualStrings(
        "Linux 6.8.0-101-generic x64",
        formatDeviceModel(&buf, .linux, "6.8.0-101-generic", null, "x64"),
    );
}

test "persistAscii strips non-ASCII and falls back like kimi-code asciiHeader" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("host", persistAscii(&buf, " host "));
    try std.testing.expectEqualStrings("abc", persistAscii(&buf, "ab\x80c"));
    try std.testing.expectEqualStrings("unknown", persistAscii(&buf, "\x80\x81"));
    try std.testing.expectEqualStrings("unknown", persistAscii(&buf, "   "));
}

test "identityHeaders use hostname and Node-shaped model, not zig os tags" {
    var headers: [6]std.http.Header = undefined;
    const got = identityHeaders(&headers);
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("X-Msh-Platform", got[0].name);
    try std.testing.expectEqualStrings("kimi_code_cli", got[0].value);
    try std.testing.expectEqualStrings(version, got[1].value);
    try std.testing.expectEqualStrings(device_name, got[2].value);
    try std.testing.expect(device_name.len > 0);
    try std.testing.expect(!std.mem.eql(u8, device_name, "unknown"));
    const prefix = switch (builtin.os.tag) {
        .windows => "Windows ",
        .macos => "macOS ",
        .linux => "Linux ",
        else => "",
    };
    if (prefix.len != 0) try std.testing.expect(std.mem.startsWith(u8, got[3].value, prefix));
    try std.testing.expect(std.mem.endsWith(u8, got[3].value, nodeArch(builtin.cpu.arch)));
    try std.testing.expect(!std.mem.eql(u8, got[4].value, @tagName(builtin.os.tag)));
}
