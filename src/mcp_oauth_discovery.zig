const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp_protocol = @import("mcp_protocol.zig");

pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub fn requireHttps(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidOAuthUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureOAuthEndpoint;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null)
        return error.InvalidOAuthUrl;
}

fn splitOrigin(url: []const u8) !struct { origin: []const u8, path: []const u8 } {
    try requireHttps(url);
    const authority_start = "https://".len;
    var authority_end = url.len;
    for (url[authority_start..], authority_start..) |c, i| {
        if (c == '/' or c == '?' or c == '#') {
            authority_end = i;
            break;
        }
    }
    if (authority_end == authority_start) return error.InvalidOAuthUrl;
    const tail = url[authority_end..];
    const path_end = std.mem.indexOfAny(u8, tail, "?#") orelse tail.len;
    const path = if (path_end == 0 or tail[0] != '/') "/" else tail[0..path_end];
    return .{ .origin = url[0..authority_end], .path = path };
}

/// RFC 9728 section 3.1: insert the well-known name between the origin and the
/// protected resource's path.
pub fn protectedMetadataUrl(arena: Allocator, resource_url: []const u8) ![]const u8 {
    const p = try splitOrigin(resource_url);
    return std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource{s}", .{
        p.origin,
        if (std.mem.eql(u8, p.path, "/")) "" else p.path,
    });
}

pub fn rootProtectedMetadataUrl(arena: Allocator, resource_url: []const u8) ![]const u8 {
    const p = try splitOrigin(resource_url);
    return std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource", .{p.origin});
}

/// RFC 8414 section 3: issuer paths follow the well-known component.
pub fn authorizationMetadataUrl(arena: Allocator, issuer: []const u8) ![]const u8 {
    const p = try splitOrigin(issuer);
    return std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{
        p.origin,
        if (std.mem.eql(u8, p.path, "/")) "" else p.path,
    });
}

pub fn oidcInsertedMetadataUrl(arena: Allocator, issuer: []const u8) ![]const u8 {
    const p = try splitOrigin(issuer);
    return std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration{s}", .{
        p.origin,
        if (std.mem.eql(u8, p.path, "/")) "" else p.path,
    });
}

pub fn oidcAppendedMetadataUrl(arena: Allocator, issuer: []const u8) ![]const u8 {
    try requireHttps(issuer);
    return std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{std.mem.trimEnd(u8, issuer, "/")});
}

fn skipOws(value: []const u8, pos: *usize) void {
    while (pos.* < value.len and (value[pos.*] == ' ' or value[pos.*] == '\t')) pos.* += 1;
}

fn tokenEnd(value: []const u8, start: usize) usize {
    var end = start;
    while (end < value.len and std.ascii.isAlphanumeric(value[end]) or
        (end < value.len and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", value[end]) != null)) end += 1;
    return end;
}

fn parseValue(arena: Allocator, value: []const u8, pos: *usize) !?[]const u8 {
    if (pos.* >= value.len) return null;
    if (value[pos.*] != '"') {
        const end = tokenEnd(value, pos.*);
        if (end == pos.*) return null;
        const result = value[pos.*..end];
        pos.* = end;
        return result;
    }
    pos.* += 1;
    var result: std.ArrayList(u8) = .empty;
    while (pos.* < value.len) {
        const c = value[pos.*];
        pos.* += 1;
        if (c == '"') return try result.toOwnedSlice(arena);
        if (c == '\\') {
            if (pos.* >= value.len) return error.InvalidAuthenticationChallenge;
            try result.append(arena, value[pos.*]);
            pos.* += 1;
        } else {
            if (c == '\r' or c == '\n') return error.InvalidAuthenticationChallenge;
            try result.append(arena, c);
        }
    }
    return error.InvalidAuthenticationChallenge;
}

/// Parse a WWW-Authenticate field value, including multiple challenges and
/// quoted-string escaping, and return the first Bearer challenge with MCP params.
pub fn parseChallenge(arena: Allocator, value: []const u8) !Challenge {
    var pos: usize = 0;
    while (pos < value.len) {
        skipOws(value, &pos);
        while (pos < value.len and value[pos] == ',') {
            pos += 1;
            skipOws(value, &pos);
        }
        const scheme_end = tokenEnd(value, pos);
        if (scheme_end == pos) break;
        const bearer = std.ascii.eqlIgnoreCase(value[pos..scheme_end], "Bearer");
        pos = scheme_end;
        var found: Challenge = .{};
        while (pos < value.len) {
            skipOws(value, &pos);
            if (pos >= value.len) break;
            if (value[pos] == ',') {
                pos += 1;
                skipOws(value, &pos);
            }
            const name_start = pos;
            const name_end = tokenEnd(value, pos);
            if (name_end == pos) break;
            pos = name_end;
            skipOws(value, &pos);
            if (pos >= value.len or value[pos] != '=') {
                pos = name_start;
                break;
            }
            pos += 1;
            skipOws(value, &pos);
            const param_value = (try parseValue(arena, value, &pos)) orelse break;
            if (bearer and std.ascii.eqlIgnoreCase(value[name_start..name_end], "resource_metadata"))
                found.resource_metadata = param_value;
            if (bearer and std.ascii.eqlIgnoreCase(value[name_start..name_end], "scope"))
                found.scope = param_value;
        }
        if (bearer and (found.resource_metadata != null or found.scope != null)) return found;
    }
    return .{};
}

pub fn probe(io: Io, gpa: Allocator, arena: Allocator, resource_url: []const u8) !Challenge {
    try requireHttps(resource_url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"
    ++ mcp_protocol.latest_protocol ++
        \\","capabilities":{},"clientInfo":{"name":"codegraff-mcp-login","version":"1"}}}
    ;
    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json, text/event-stream" },
        .{ .name = "mcp-protocol-version", .value = mcp_protocol.latest_protocol },
    };
    var request = try client.request(.POST, try std.Uri.parse(resource_url), .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .user_agent = .{ .override = "codegraff-mcp/1" },
        },
        .extra_headers = &extra_headers,
    });
    defer request.deinit();
    errdefer {
        if (request.connection) |connection| connection.closing = true;
    }
    request.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try request.connection.?.flush();
    const response = try request.receiveHead(&.{});
    if (request.connection) |connection| connection.closing = true;

    var challenge: Challenge = .{};
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "WWW-Authenticate")) continue;
        const parsed = try parseChallenge(arena, header.value);
        if (challenge.resource_metadata == null) challenge.resource_metadata = parsed.resource_metadata;
        if (challenge.scope == null) challenge.scope = parsed.scope;
    }
    return challenge;
}

pub fn preferredScope(challenge: ?[]const u8, resource: []const u8, authorization_server: []const u8) []const u8 {
    if (challenge) |scope| if (scope.len != 0) return scope;
    if (resource.len != 0) return resource;
    return authorization_server;
}

pub fn scopeSubsetOf(scope: []const u8, allowed: []const u8) bool {
    var requested = std.mem.tokenizeScalar(u8, scope, ' ');
    while (requested.next()) |item| {
        var candidates = std.mem.tokenizeScalar(u8, allowed, ' ');
        while (candidates.next()) |candidate| {
            if (std.mem.eql(u8, item, candidate)) break;
        } else return false;
    }
    return true;
}

pub fn supportsS256(metadata: std.json.ObjectMap) bool {
    const methods = metadata.get("code_challenge_methods_supported") orelse return false;
    if (methods != .array) return false;
    for (methods.array.items) |method|
        if (method == .string and std.mem.eql(u8, method.string, "S256")) return true;
    return false;
}

test "OAuth URLs require a parsed HTTPS URI without userinfo or fragments" {
    try requireHttps("HTTPS://login.example/token?audience=mcp");
    try std.testing.expectError(error.InsecureOAuthEndpoint, requireHttps("http://login.example/token"));
    try std.testing.expectError(error.InvalidOAuthUrl, requireHttps("https://user@login.example/token"));
    try std.testing.expectError(error.InvalidOAuthUrl, requireHttps("https://login.example/token#fragment"));
    try std.testing.expectError(error.InvalidOAuthUrl, requireHttps("https:///missing-host"));
}

test "metadata URL construction covers RFC and OIDC issuer paths" {
    const allocator = std.testing.allocator;
    const protected = try protectedMetadataUrl(allocator, "https://mcp.example:8443/a/b?x=1");
    defer allocator.free(protected);
    try std.testing.expectEqualStrings("https://mcp.example:8443/.well-known/oauth-protected-resource/a/b", protected);
    const root = try rootProtectedMetadataUrl(allocator, "https://mcp.example:8443/a/b");
    defer allocator.free(root);
    try std.testing.expectEqualStrings("https://mcp.example:8443/.well-known/oauth-protected-resource", root);
    const rfc = try authorizationMetadataUrl(allocator, "https://login.example/tenant");
    defer allocator.free(rfc);
    try std.testing.expectEqualStrings("https://login.example/.well-known/oauth-authorization-server/tenant", rfc);
    const inserted = try oidcInsertedMetadataUrl(allocator, "https://login.example/tenant");
    defer allocator.free(inserted);
    try std.testing.expectEqualStrings("https://login.example/.well-known/openid-configuration/tenant", inserted);
    const appended = try oidcAppendedMetadataUrl(allocator, "https://login.example/tenant/");
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("https://login.example/tenant/.well-known/openid-configuration", appended);
}

test "Bearer challenge parsing handles other challenges and quoted escapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const challenge = try parseChallenge(arena_state.allocator(), "Bearer realm=\"old\", Basic realm=\"legacy\", Bearer resource_metadata=\"https://mcp.example/meta\\?v=1\", scope=\"docs:read profile\", Digest realm=\"later\"");
    try std.testing.expectEqualStrings("https://mcp.example/meta?v=1", challenge.resource_metadata.?);
    try std.testing.expectEqualStrings("docs:read profile", challenge.scope.?);
}

test "challenge scope takes priority over metadata scopes" {
    try std.testing.expectEqualStrings("challenge:read", preferredScope("challenge:read", "resource:write", "server:write"));
    try std.testing.expectEqualStrings("resource:read", preferredScope(null, "resource:read", "server:write"));
    try std.testing.expectEqualStrings("server:read", preferredScope(null, "", "server:read"));
}

test "scope subset rejects unapproved challenge permissions" {
    try std.testing.expect(scopeSubsetOf("docs:read profile", "profile email docs:read"));
    try std.testing.expect(!scopeSubsetOf("docs:read docs:write", "profile email docs:read"));
}

test "PKCE metadata requires exact S256 array member" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const good = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"code_challenge_methods_supported\":[\"plain\",\"S256\"]}", .{})).object;
    const wrong_case = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"code_challenge_methods_supported\":[\"s256\"]}", .{})).object;
    const wrong_type = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"code_challenge_methods_supported\":\"S256\"}", .{})).object;
    try std.testing.expect(supportsS256(good));
    try std.testing.expect(!supportsS256(wrong_case));
    try std.testing.expect(!supportsS256(wrong_type));
}
