//! MCP protocol negotiation. Tool JSON Schema normalization lives in the sibling mcp_schema.zig.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

/// Tool-schema normalization (rewriteOneOf, flattenTopLevel) moved to
/// mcp_schema.zig at the 600-line ceiling; re-exported so every existing
/// call site keeps working.
const mcp_schema = @import("mcp_schema.zig");
pub const rewriteOneOf = mcp_schema.rewriteOneOf;
pub const combinators = mcp_schema.combinators;
pub const topLevelCombinator = mcp_schema.topLevelCombinator;
pub const flattenTopLevel = mcp_schema.flattenTopLevel;

test { // the moved tests still have to run from a referenced module
    _ = mcp_schema;
}

/// The one modern (stateless, per-request `_meta`) revision graff speaks.
/// Never sent in a legacy `initialize` handshake — see `supported_protocols`.
pub const modern_protocol = "2026-07-28";

/// What graff offers in a legacy `initialize` handshake, and the newest
/// revision `negotiatedProtocol` will accept back from a server.
pub const legacy_protocol = "2025-11-25";

/// Revisions whose initialize, tools, and content schemas are compatible with
/// the legacy subset implemented by this client. Deliberately excludes
/// `modern_protocol`: a server that echoes it back inside an `initialize`
/// result is not speaking the stateless 2026-07-28 wire format at all.
pub const supported_protocols = [_][]const u8{
    legacy_protocol,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
};

pub const Transport = enum {
    stdio,
    streamable_http,
};

fn supportsProtocol(transport: Transport, version: []const u8) bool {
    for (supported_protocols) |supported| {
        if (!std.mem.eql(u8, version, supported)) continue;
        // Streamable HTTP replaced the legacy HTTP+SSE transport in
        // 2025-03-26. The older revision remains compatible over stdio only.
        return transport == .stdio or !std.mem.eql(u8, version, "2024-11-05");
    }
    return false;
}

pub fn negotiatedProtocol(response: Value, transport: Transport) ![]const u8 {
    if (response != .object) return error.BadMcpInitializeResponse;
    const result = response.object.get("result") orelse return error.BadMcpInitializeResponse;
    if (result != .object) return error.BadMcpInitializeResponse;
    const version = result.object.get("protocolVersion") orelse return error.MissingMcpProtocolVersion;
    if (version != .string) return error.InvalidMcpProtocolVersion;
    if (supportsProtocol(transport, version.string)) return version.string;
    return error.UnsupportedMcpProtocolVersion;
}

// ── 2026-07-28 stateless envelope: pure helpers, not wired to any transport
// yet (see mcp_http.zig's `probe`/`buildHeaders` and mcp_rpc.zig's stdio
// probe for the callers). ─────────────────────────────────────────────────

/// The three reserved `_meta` keys (basic/index § `_meta`), pre-rendered as a
/// single JSON object member. graff supports exactly one modern version and
/// declares no client capabilities, so this is a comptime constant rather
/// than something built per request.
pub const modern_meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"codegraff","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}
;

/// Build a JSON-RPC request line. Modern era splices the `_meta` envelope
/// into `params` (first, so the splice is a single concat with no
/// trailing-comma case); legacy era emits `params` byte-for-byte unchanged.
///
/// LOAD-BEARING: when `modern` is false, this must produce exactly the bytes
/// graff wrote before the 2026-07-28 migration — no `_meta`, nothing added.
/// That byte-identity is the whole backward-compatibility guarantee for
/// every server graff talks to today (codedbpro, smolify, every stdio
/// server in a workspace `.mcp.json`). See the "legacy byte-identity" test.
pub fn buildRequest(a: Allocator, id: i64, method: []const u8, params: []const u8, modern: bool) ![]u8 {
    if (params.len < 2 or params[0] != '{' or params[params.len - 1] != '}') return error.BadMcpParams;
    if (!modern) {
        return std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{s}}}
        , .{ id, method, params });
    }
    const inner = std.mem.trim(u8, params[1 .. params.len - 1], " \t\r\n");
    if (inner.len == 0) {
        return std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{{{s}}}}}
        , .{ id, method, modern_meta });
    }
    return std.fmt.allocPrint(a,
        \\{{"jsonrpc":"2.0","id":{d},"method":"{s}","params":{{{s},{s}}}}}
    , .{ id, method, modern_meta, inner });
}

fn looksLikeSentinel(value: []const u8) bool {
    return value.len >= 4 and std.mem.startsWith(u8, value, "=?") and std.mem.endsWith(u8, value, "?=");
}

fn isHeaderSafe(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value[0] == ' ' or value[0] == '\t') return false;
    if (value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return false;
    for (value) |c| {
        if (!(c == 0x20 or c == 0x09 or (c >= 0x21 and c <= 0x7E))) return false;
    }
    return !looksLikeSentinel(value);
}

/// Encode an `Mcp-Name` (or any MCP header) value per the spec's encoding
/// table: plain if every byte is space/tab/0x21-0x7E, no leading/trailing
/// space or tab, and it does not already look like the sentinel below —
/// otherwise the whole value is base64'd inside `=?base64?<b64>?=` so a
/// non-ASCII or newline-bearing tool name can't corrupt an HTTP header line.
pub fn headerValue(a: Allocator, value: []const u8) ![]const u8 {
    if (isHeaderSafe(value)) return a.dupe(u8, value);
    const encoder = std.base64.standard.Encoder;
    const encoded = try a.alloc(u8, encoder.calcSize(value.len));
    _ = encoder.encode(encoded, value);
    return std.fmt.allocPrint(a, "=?base64?{s}?=", .{encoded});
}

/// The three renumbered error codes actually introduced by the 2026-07-28
/// draft. `-32000..-32019` is the grandfathered implementation-defined
/// sub-range: a real 2025-11-25 server may legitimately emit e.g. `-32003`
/// for something unrelated, so only these three exact codes are ever read
/// as "this server speaks the modern protocol".
pub const ModernError = enum { header_mismatch, missing_capability, unsupported_version };

pub fn modernErrorCode(code: i64) ?ModernError {
    return switch (code) {
        -32020 => .header_mismatch,
        -32021 => .missing_capability,
        -32022 => .unsupported_version,
        else => null,
    };
}

/// Result of inspecting a Streamable HTTP/stdio probe reply. `unsupported_version`
/// carries the server's raw `data.supported` list (only when it overlaps
/// something graff speaks — see `classifyProbe`); the caller picks `modern_protocol`
/// if present, else the legacy `initialize` handshake, per versioning §
/// Protocol Version Negotiation.
pub const Probe = union(enum) {
    modern,
    legacy,
    unsupported_version: []const Value,
    incompatible,
};

fn versionOverlap(version: []const u8) bool {
    if (std.mem.eql(u8, version, modern_protocol)) return true;
    for (supported_protocols) |ours| if (std.mem.eql(u8, version, ours)) return true;
    return false;
}

/// Classify a non-2xx Streamable HTTP body (or a stdio `server/discover`
/// error) to decide modern-vs-legacy. Never crashes on empty/malformed
/// input — an unparseable body is exactly what a legacy server (which does
/// not know this probe exists) produces, so it reads as `.legacy`.
pub fn classifyProbe(a: Allocator, raw_body: []const u8) Probe {
    const trimmed = std.mem.trim(u8, raw_body, " \t\r\n");
    if (trimmed.len == 0) return .legacy;
    const parsed = std.json.parseFromSliceLeaky(Value, a, trimmed, .{ .allocate = .alloc_always }) catch return .legacy;
    if (parsed != .object) return .legacy;
    const err_v = parsed.object.get("error") orelse return .legacy;
    if (err_v != .object) return .legacy;
    const code_v = err_v.object.get("code") orelse return .legacy;
    if (code_v != .integer) return .legacy;
    const kind = modernErrorCode(code_v.integer) orelse return .legacy;
    switch (kind) {
        .header_mismatch, .missing_capability => return .modern,
        .unsupported_version => {
            const data_v = err_v.object.get("data") orelse return .incompatible;
            if (data_v != .object) return .incompatible;
            const supported_v = data_v.object.get("supported") orelse return .incompatible;
            if (supported_v != .array) return .incompatible;
            for (supported_v.array.items) |v| {
                if (v == .string and versionOverlap(v.string)) return .{ .unsupported_version = supported_v.array.items };
            }
            return .incompatible;
        },
    }
}

/// Extract `result.supportedVersions` from a `server/discover` reply.
pub fn discoverSupportedVersions(response: Value) ![]const Value {
    if (response != .object) return error.BadMcpDiscoverResponse;
    const result = response.object.get("result") orelse return error.BadMcpDiscoverResponse;
    if (result != .object) return error.BadMcpDiscoverResponse;
    const versions = result.object.get("supportedVersions") orelse return error.MissingMcpSupportedVersions;
    if (versions != .array) return error.InvalidMcpSupportedVersions;
    return versions.array.items;
}

/// A result's `resultType`. Absent MUST read as "complete" (the backward
/// -compatibility rule for every server older than this field existing);
/// anything other than the literal string "complete" is not complete —
/// including a malformed non-string value, which never crashes here.
pub fn resultIsComplete(result: std.json.ObjectMap) bool {
    const v = result.get("resultType") orelse return true;
    return v == .string and std.mem.eql(u8, v.string, "complete");
}

test "initialize negotiation accepts transport-compatible protocol versions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for (supported_protocols) |version| {
        const json = try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":1,"result":{{"protocolVersion":"{s}"}}}}
        , .{version});
        const response = try std.json.parseFromSliceLeaky(Value, a, json, .{});
        try std.testing.expectEqualStrings(version, try negotiatedProtocol(response, .stdio));
        if (std.mem.eql(u8, version, "2024-11-05")) {
            try std.testing.expectError(error.UnsupportedMcpProtocolVersion, negotiatedProtocol(response, .streamable_http));
        } else {
            try std.testing.expectEqualStrings(version, try negotiatedProtocol(response, .streamable_http));
        }
    }
}

test "initialize negotiation rejects missing, non-string, and unsupported versions" {
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"result\":{}}", .expected = error.MissingMcpProtocolVersion },
        .{ .json = "{\"result\":{\"protocolVersion\":20251125}}", .expected = error.InvalidMcpProtocolVersion },
        .{ .json = "{\"result\":{\"protocolVersion\":\"2099-01-01\"}}", .expected = error.UnsupportedMcpProtocolVersion },
        // A server echoing the modern, handshake-free revision back inside a
        // legacy `initialize` result is nonsense — the legacy negotiator must
        // never accept it (mcp_rpc's stdio/HTTP probe path is the only place
        // `modern_protocol` is ever legitimate).
        .{ .json = "{\"result\":{\"protocolVersion\":\"2026-07-28\"}}", .expected = error.UnsupportedMcpProtocolVersion },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, negotiatedProtocol(parsed.value, .streamable_http));
    }
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "buildRequest: modern with empty params splices the full _meta envelope" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try buildRequest(a, 1, "tools/list", "{}", true);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ modern_meta ++ "}}",
        line,
    );
    var parsed = try std.json.parseFromSlice(Value, a, line, .{});
    defer parsed.deinit();
    const meta = parsed.value.object.get("params").?.object.get("_meta").?;
    try std.testing.expect(meta.object.get("io.modelcontextprotocol/protocolVersion") != null);
    try std.testing.expect(meta.object.get("io.modelcontextprotocol/clientCapabilities") != null);
    try std.testing.expect(meta.object.get("io.modelcontextprotocol/clientInfo") != null);
}

test "buildRequest: modern with non-empty params preserves them and adds no stray comma" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try buildRequest(a, 3, "tools/call", "{\"name\":\"t\",\"arguments\":{}}", true);
    var parsed = try std.json.parseFromSlice(Value, a, line, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?.object;
    try std.testing.expect(params.get("_meta") != null);
    try std.testing.expectEqualStrings("t", params.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), params.get("arguments").?.object.count());
    // no double/trailing comma: exactly 3 top-level params members
    try std.testing.expectEqual(@as(usize, 3), params.count());
}

test "buildRequest: rejects non-object params" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.BadMcpParams, buildRequest(a, 1, "tools/list", "[]", true));
    try std.testing.expectError(error.BadMcpParams, buildRequest(a, 1, "tools/list", "", true));
    try std.testing.expectError(error.BadMcpParams, buildRequest(a, 1, "tools/list", "null", true));
}

test "buildRequest: LEGACY BYTE-IDENTITY GUARD — modern=false reproduces the pre-migration wire format exactly" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try buildRequest(a, 3, "tools/call", "{\"name\":\"t\",\"arguments\":{}}", false);
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"t\",\"arguments\":{}}}",
        line,
    );
    try std.testing.expect(std.mem.indexOf(u8, line, "_meta") == null);
}

test "headerValue: matches the spec's encoding table verbatim" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("get_weather", try headerValue(a, "get_weather"));
    try std.testing.expectEqualStrings("=?base64?SGVsbG8sIOS4lueVjA==?=", try headerValue(a, "Hello, 世界"));
    try std.testing.expectEqualStrings("=?base64?IHBhZGRlZCA=?=", try headerValue(a, " padded "));
    try std.testing.expectEqualStrings("=?base64?bGluZTEKbGluZTI=?=", try headerValue(a, "line1\nline2"));
    try std.testing.expectEqualStrings("=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", try headerValue(a, "=?base64?literal?="));
}

test "modernErrorCode: only the three spec-reserved codes map, draft codes never do" {
    try std.testing.expectEqual(ModernError.header_mismatch, modernErrorCode(-32020).?);
    try std.testing.expectEqual(ModernError.missing_capability, modernErrorCode(-32021).?);
    try std.testing.expectEqual(ModernError.unsupported_version, modernErrorCode(-32022).?);
    // The draft-code trap: -32001/-32003/-32004 never shipped in a released
    // revision and live in the grandfathered -32000..-32019 range. Treating
    // them as modern would skip the legacy fallback and break a real
    // 2025-11-25 server that happens to emit one for something unrelated.
    try std.testing.expect(modernErrorCode(-32001) == null);
    try std.testing.expect(modernErrorCode(-32003) == null);
    try std.testing.expect(modernErrorCode(-32004) == null);
    try std.testing.expect(modernErrorCode(-32000) == null);
    try std.testing.expect(modernErrorCode(-32601) == null);
    try std.testing.expect(modernErrorCode(-32602) == null);
    try std.testing.expect(modernErrorCode(-32700) == null);
}

test "classifyProbe: the real TS-SDK legacy rejection classifies as legacy" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // id:null proves classification never routes through matchingResponse,
    // which requires an integer id match and would return null here.
    const probe = classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Bad Request: Server not initialized\"},\"id\":null}");
    try std.testing.expectEqual(Probe.legacy, probe);
}

test "a 200 carrying a JSON-RPC error is NOT proof of a modern server" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // JSON-RPC puts application errors in a 200 body, so status alone cannot
    // decide the era. A legacy server enforcing "initialize first" answers the
    // stateless probe with exactly this, and an earlier version read the 2xx
    // as "modern", skipped the fallback, and broke every such server.
    const rejection = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Server not initialized\"},\"id\":1}";
    const parsed = try std.json.parseFromSliceLeaky(Value, a, rejection, .{});
    // The rule the caller applies: a `result` member, not the status, is what
    // proves the server understood a request sent with no handshake.
    try std.testing.expect(parsed == .object and parsed.object.get("result") == null);
    // And a real modern reply does carry one.
    const ok = try std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}", .{});
    try std.testing.expect(ok == .object and ok.object.get("result") != null);
}

test "classifyProbe: never crashes on empty, HTML, or truncated bodies" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(Probe.legacy, classifyProbe(a, ""));
    try std.testing.expectEqual(Probe.legacy, classifyProbe(a, "<html>404</html>"));
    try std.testing.expectEqual(Probe.legacy, classifyProbe(a, "{"));
}

test "classifyProbe: -32022 with modern_protocol in data.supported — selection picks it" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const probe = classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32022,\"data\":{\"supported\":[\"2026-07-28\",\"2025-11-25\"]}},\"id\":null}");
    const supported = switch (probe) {
        .unsupported_version => |s| s,
        else => return error.TestUnexpectedResult,
    };
    // the caller's selection step: modern_protocol present -> retry modern once
    var picked: ?[]const u8 = null;
    for (supported) |v| if (v == .string and std.mem.eql(u8, v.string, modern_protocol)) {
        picked = v.string;
    };
    try std.testing.expectEqualStrings(modern_protocol, picked.?);
}

test "classifyProbe: -32022 with only a legacy overlap drives the legacy handshake" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const probe = classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32022,\"data\":{\"supported\":[\"2025-11-25\"]}},\"id\":null}");
    const supported = switch (probe) {
        .unsupported_version => |s| s,
        else => return error.TestUnexpectedResult,
    };
    var has_modern = false;
    var has_legacy = false;
    for (supported) |v| if (v == .string) {
        if (std.mem.eql(u8, v.string, modern_protocol)) has_modern = true;
        for (supported_protocols) |ours| if (std.mem.eql(u8, v.string, ours)) {
            has_legacy = true;
        };
    };
    try std.testing.expect(!has_modern);
    try std.testing.expect(has_legacy); // -> caller runs the legacy initialize handshake
}

test "classifyProbe: -32022 with no mutual version at all is incompatible" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const probe = classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32022,\"data\":{\"supported\":[\"1999-01-01\"]}},\"id\":null}");
    try std.testing.expectEqual(Probe.incompatible, probe);
}

test "classifyProbe: -32020/-32021 mark the server modern, never fall back to legacy" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(Probe.modern, classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32020,\"message\":\"bad headers\"},\"id\":null}"));
    try std.testing.expectEqual(Probe.modern, classifyProbe(a, "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32021,\"message\":\"missing capability\"},\"id\":null}"));
}

test "discoverSupportedVersions: extracts the list, errors on missing or non-array" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try std.json.parseFromSliceLeaky(Value, a,
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":["2026-07-28"],"serverInfo":{"name":"fixture","version":"1"}}}
    , .{});
    const versions = try discoverSupportedVersions(ok);
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings("2026-07-28", versions[0].string);

    const missing = try std.json.parseFromSliceLeaky(Value, a,
        \\{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"fixture","version":"1"}}}
    , .{});
    try std.testing.expectError(error.MissingMcpSupportedVersions, discoverSupportedVersions(missing));

    const not_array = try std.json.parseFromSliceLeaky(Value, a,
        \\{"jsonrpc":"2.0","id":1,"result":{"supportedVersions":"2026-07-28"}}
    , .{});
    try std.testing.expectError(error.InvalidMcpSupportedVersions, discoverSupportedVersions(not_array));
}

test "resultIsComplete: absent is the MUST-complete default for older servers" {
    var arena_state = testArena();
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const absent = (try std.json.parseFromSliceLeaky(Value, a, "{\"tools\":[]}", .{})).object;
    try std.testing.expect(resultIsComplete(absent));
    const complete = (try std.json.parseFromSliceLeaky(Value, a, "{\"resultType\":\"complete\"}", .{})).object;
    try std.testing.expect(resultIsComplete(complete));
    const input_required = (try std.json.parseFromSliceLeaky(Value, a, "{\"resultType\":\"input_required\"}", .{})).object;
    try std.testing.expect(!resultIsComplete(input_required));
    const malformed = (try std.json.parseFromSliceLeaky(Value, a, "{\"resultType\":42}", .{})).object;
    try std.testing.expect(!resultIsComplete(malformed));
}
