//! Kimi Coding request identity. Field *shapes* follow MoonshotAI/kimi-code
//! `packages/oauth/src/identity.ts` (hostname, Node-style device model,
//! `os.release()`). Every host states its own identity there: the product
//! token is `graff/<version>` and `X-Msh-Platform` is `graff`, never the Kimi
//! CLI's `kimi_code_cli` (#1297, ADR 0204).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const user_agent = "graff/" ++ @import("build_options").version;
pub const platform = "graff";
pub const version = @import("build_options").version;

pub var device_name: []const u8 = "unknown";
pub var device_model: []const u8 = "unknown";
pub var os_version: []const u8 = "unknown";

var device_name_buf: [256]u8 = undefined;
var device_model_buf: [128]u8 = undefined;
var os_version_buf: [128]u8 = undefined;
var host_fields_ready = false;

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

pub fn identityHeaders(buf: []std.http.Header) []std.http.Header {
    fillHostFields();
    if (buf.len < 5) return buf[0..0];
    buf[0] = .{ .name = "X-Msh-Platform", .value = platform };
    buf[1] = .{ .name = "X-Msh-Version", .value = version };
    buf[2] = .{ .name = "X-Msh-Device-Name", .value = device_name };
    buf[3] = .{ .name = "X-Msh-Device-Model", .value = device_model };
    buf[4] = .{ .name = "X-Msh-Os-Version", .value = os_version };
    return buf[0..5];
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
    var headers: [5]std.http.Header = undefined;
    const got = identityHeaders(&headers);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    // No device id: graff keeps no persistent install identifier for Kimi.
    for (got) |h| try std.testing.expect(!std.ascii.eqlIgnoreCase(h.name, "X-Msh-Device-Id"));
    try std.testing.expectEqualStrings("X-Msh-Platform", got[0].name);
    // graff states its own platform; it never reports the Kimi CLI's (#1297).
    try std.testing.expectEqualStrings("graff", got[0].value);
    for (got) |h| try std.testing.expect(std.mem.indexOf(u8, h.value, "kimi_code_cli") == null);
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
