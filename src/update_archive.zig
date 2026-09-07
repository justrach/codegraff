//! Pin a release artifact, verify it against that release's SHA256SUMS, and
//! extract the `graff` binary. Fail closed if the sums file is missing,
//! malformed, or does not match. No remote scripts.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ VerifyFailed, Malformed, OutOfMemory };

pub fn sha256Hex(bytes: []const u8, out: *[64]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const digits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

/// Find the lowercase hex digest for `asset` in GNU `sha256sum` text.
/// Fail closed on a missing or malformed line.
pub fn digestFor(sums: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line.len < 66) return null;
        const hex = line[0..64];
        for (hex) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!ok) return null;
        }
        var rest = std.mem.trim(u8, line[64..], " \t");
        if (rest.len > 0 and (rest[0] == '*' or rest[0] == ' ')) rest = std.mem.trim(u8, rest, " *");
        if (std.mem.eql(u8, rest, asset) or std.mem.endsWith(u8, rest, asset)) return hex;
    }
    return null;
}

pub fn verifyAsset(sums: []const u8, asset: []const u8, bytes: []const u8) Error!void {
    const want = digestFor(sums, asset) orelse return error.VerifyFailed;
    var hex: [64]u8 = undefined;
    const got = sha256Hex(bytes, &hex);
    if (!eqlHex(want, got)) return error.VerifyFailed;
}

fn eqlHex(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var same: u8 = 0;
    for (a, b) |x, y| same |= std.ascii.toLower(x) ^ std.ascii.toLower(y);
    return same == 0;
}

fn isZeroBlock(hdr: []const u8) bool {
    for (hdr) |b| if (b != 0) return false;
    return true;
}

fn tarName(hdr: []const u8) []const u8 {
    const prefix = memCstr(hdr[345..500]);
    const name = memCstr(hdr[0..100]);
    if (prefix.len == 0) return name;
    return name; // we only match a basename of graff
}

fn memCstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, 0) orelse s.len];
}

fn tarSize(hdr: []const u8) ?u64 {
    const field = memCstr(hdr[124..136]);
    const trimmed = std.mem.trim(u8, field, " \t");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, trimmed, 8) catch null;
}

fn isGraffMember(name: []const u8) bool {
    const base = std.fs.path.basename(name);
    return std.mem.eql(u8, base, "graff") or std.mem.eql(u8, base, "graff.exe");
}

pub fn extractGraff(gpa: Allocator, tar_bytes: []const u8) Error![]u8 {
    if (tar_bytes.len < 512) return error.Malformed;
    var off: usize = 0;
    while (off + 512 <= tar_bytes.len) {
        const hdr = tar_bytes[off .. off + 512];
        if (isZeroBlock(hdr)) break;
        const size = tarSize(hdr) orelse return error.Malformed;
        const typeflag = hdr[156];
        off += 512;
        if (off + size > tar_bytes.len) return error.Malformed;
        const payload = tar_bytes[off .. off + @as(usize, @intCast(size))];
        off += std.mem.alignForward(usize, @as(usize, @intCast(size)), 512);
        if ((typeflag == 0 or typeflag == '0') and isGraffMember(tarName(hdr)))
            return gpa.dupe(u8, payload);
    }
    return error.Malformed;
}

pub fn gunzip(gpa: Allocator, gz: []const u8) Error![]u8 {
    var in_reader: std.Io.Reader = .fixed(gz);
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = dec.reader.streamRemaining(&out.writer) catch return error.Malformed;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn extractVerified(gpa: Allocator, sums: []const u8, asset: []const u8, archive: []const u8) Error![]u8 {
    try verifyAsset(sums, asset, archive);
    const tar = gunzip(gpa, archive) catch |err| switch (err) {
        error.Malformed, error.OutOfMemory => return err,
        else => return error.Malformed,
    };
    defer gpa.free(tar);
    return extractGraff(gpa, tar);
}

fn checksumField(hdr: []u8) void {
    @memset(hdr[148..156], ' ');
    var sum: u32 = 0;
    for (hdr[0..512]) |b| sum += b;
    _ = std.fmt.bufPrint(hdr[148..155], "{o:0>6}", .{sum}) catch {};
    hdr[155] = 0;
}

/// Build a one-file ustar + gzip for isolated fixtures. Never used as a
/// production download path.
pub fn fixtureArchive(gpa: Allocator, member_name: []const u8, payload: []const u8) ![]u8 {
    const data_pad = std.mem.alignForward(usize, payload.len, 512);
    const tar = try gpa.alloc(u8, 512 + data_pad + 1024);
    errdefer gpa.free(tar);
    @memset(tar, 0);
    const hdr = tar[0..512];
    const name_len = @min(member_name.len, 99);
    @memcpy(hdr[0..name_len], member_name[0..name_len]);
    _ = try std.fmt.bufPrint(hdr[100..107], "{o:0>7}", .{@as(u32, 0o0755)});
    _ = try std.fmt.bufPrint(hdr[124..135], "{o:0>11}", .{payload.len});
    hdr[156] = '0';
    @memcpy(hdr[257..262], "ustar");
    hdr[263] = '0';
    checksumField(hdr);
    @memcpy(tar[512 .. 512 + payload.len], payload);
    const gz = try gzipAlloc(gpa, tar);
    gpa.free(tar);
    return gz;
}

pub fn gzipAlloc(gpa: Allocator, plain: []const u8) ![]u8 {
    var out_buf: [1 << 16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(std.compress.flate.Compress);
    defer gpa.destroy(c);
    c.* = try std.compress.flate.Compress.init(&out, window, .gzip, .default);
    try c.writer.writeAll(plain);
    try c.finish();
    return gpa.dupe(u8, out.buffered());
}

pub fn sumsLine(gpa: Allocator, asset: []const u8, bytes: []const u8) ![]u8 {
    var hex: [64]u8 = undefined;
    _ = sha256Hex(bytes, &hex);
    return std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ hex, asset });
}

test "digestFor reads GNU sha256sum lines and rejects junk" {
    const body = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  graff-x86_64-linux.tar.gz\n";
    try std.testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        digestFor(body, "graff-x86_64-linux.tar.gz").?,
    );
    try std.testing.expect(digestFor("not-a-sum\n", "graff-x86_64-linux.tar.gz") == null);
    try std.testing.expect(digestFor(body, "graff-aarch64-macos.tar.gz") == null);
}

test "verify + extract a fixture archive" {
    const gpa = std.testing.allocator;
    const archive = try fixtureArchive(gpa, "graff-x86_64-linux/graff", "NEWBIN");
    defer gpa.free(archive);
    const sums = try sumsLine(gpa, "graff-x86_64-linux.tar.gz", archive);
    defer gpa.free(sums);
    const bin = try extractVerified(gpa, sums, "graff-x86_64-linux.tar.gz", archive);
    defer gpa.free(bin);
    try std.testing.expectEqualStrings("NEWBIN", bin);
}

test "verification fails closed on a wrong digest" {
    const gpa = std.testing.allocator;
    const archive = try fixtureArchive(gpa, "graff", "NEWBIN");
    defer gpa.free(archive);
    try std.testing.expectError(
        error.VerifyFailed,
        extractVerified(gpa, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  graff-x86_64-linux.tar.gz\n", "graff-x86_64-linux.tar.gz", archive),
    );
}
