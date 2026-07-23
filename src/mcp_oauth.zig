//! OAuth 2.1 support for remote MCP servers.  This is deliberately a leaf
//! module: callers supply all allocators, I/O, and the user's home directory.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");
const discovery = @import("mcp_oauth_discovery.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const max_response = 1024 * 1024;
const redirect_uri = "http://127.0.0.1:1456/callback";
const smolify_resource = "https://app.smol.ly/mcp";
const smolify_read_scopes = "profile email offline_access projects:read docs:read";

const EndpointSet = struct {
    issuer: []const u8,
    authorization: []const u8,
    token: []const u8,
    registration: []const u8,
    scope: []const u8 = "",
};

const ClientInfo = struct {
    id: []const u8,
    secret: []const u8 = "",
};

const TokenSet = struct {
    access: []const u8,
    refresh: []const u8 = "",
    expires_at_ms: i64,
};

const requireHttps = discovery.requireHttps;

fn writePercentEncoded(w: *Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else {
            try w.writeAll(&.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}

fn formEncode(arena: Allocator, fields: []const struct { []const u8, []const u8 }) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (fields, 0..) |field, i| {
        if (i != 0) try aw.writer.writeByte('&');
        try writePercentEncoded(&aw.writer, field[0]);
        try aw.writer.writeByte('=');
        try writePercentEncoded(&aw.writer, field[1]);
    }
    return aw.writer.buffered();
}

fn jsonObject(body: []const u8, arena: Allocator) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always });
    if (v != .object) return error.BadOAuthResponse;
    return v.object;
}

fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn integerField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = obj.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn supportedScopes(arena: Allocator, metadata: std.json.ObjectMap) ![]const u8 {
    const scopes = metadata.get("scopes_supported") orelse return "";
    if (scopes != .array) return error.BadOAuthResponse;
    var aw: Io.Writer.Allocating = .init(arena);
    for (scopes.array.items) |scope| {
        if (scope != .string) return error.BadOAuthResponse;
        if (aw.writer.buffered().len != 0) try aw.writer.writeByte(' ');
        try aw.writer.writeAll(scope.string);
    }
    return aw.writer.buffered();
}

fn fetchJson(io: Io, gpa: Allocator, arena: Allocator, url: []const u8) !std.json.ObjectMap {
    try requireHttps(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const storage = try arena.alloc(u8, max_response);
    var writer: Io.Writer = .fixed(storage);
    const headers = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer,
        .redirect_behavior = .not_allowed,
        .extra_headers = &headers,
    });
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.OAuthHttpFailure;
    return jsonObject(writer.buffered(), arena);
}

fn postJson(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, payload: []const u8) !std.json.ObjectMap {
    try requireHttps(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const storage = try arena.alloc(u8, max_response);
    var writer: Io.Writer = .fixed(storage);
    const headers = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &writer,
        .redirect_behavior = .not_allowed,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &headers,
    });
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.OAuthHttpFailure;
    return jsonObject(writer.buffered(), arena);
}

fn postForm(io: Io, gpa: Allocator, arena: Allocator, url: []const u8, payload: []const u8) !std.json.ObjectMap {
    try requireHttps(url);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const storage = try arena.alloc(u8, max_response);
    var writer: Io.Writer = .fixed(storage);
    const headers = [_]std.http.Header{.{ .name = "Accept", .value = "application/json" }};
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &writer,
        .redirect_behavior = .not_allowed,
        .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
        .extra_headers = &headers,
    });
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.OAuthHttpFailure;
    return jsonObject(writer.buffered(), arena);
}

fn authorizationEndpoints(io: Io, gpa: Allocator, arena: Allocator, issuer: []const u8, metadata_url: []const u8) !EndpointSet {
    const metadata = try fetchJson(io, gpa, arena, metadata_url);
    const advertised_issuer = stringField(metadata, "issuer") orelse return error.AuthorizationServerMismatch;
    if (!std.mem.eql(u8, advertised_issuer, issuer)) return error.AuthorizationServerMismatch;
    if (!discovery.supportsS256(metadata)) return error.PkceS256Unsupported;

    const authorization = stringField(metadata, "authorization_endpoint") orelse return error.BadOAuthResponse;
    const token = stringField(metadata, "token_endpoint") orelse return error.BadOAuthResponse;
    const registration = stringField(metadata, "registration_endpoint") orelse return error.DynamicRegistrationUnsupported;
    try requireHttps(authorization);
    try requireHttps(token);
    try requireHttps(registration);
    return .{
        .issuer = issuer,
        .authorization = authorization,
        .token = token,
        .registration = registration,
        .scope = try supportedScopes(arena, metadata),
    };
}

fn discover(io: Io, gpa: Allocator, arena: Allocator, resource_url: []const u8) !EndpointSet {
    // RFC 9728 challenges are authoritative hints and must be obtained before
    // attempting either protected-resource well-known location.
    const challenge = try discovery.probe(io, gpa, arena, resource_url);
    const resource_metadata = if (challenge.resource_metadata) |url|
        try fetchJson(io, gpa, arena, url)
    else
        fetchJson(io, gpa, arena, try discovery.protectedMetadataUrl(arena, resource_url)) catch
            try fetchJson(io, gpa, arena, try discovery.rootProtectedMetadataUrl(arena, resource_url));
    const advertised_resource = stringField(resource_metadata, "resource") orelse return error.ResourceMetadataMismatch;
    if (!std.mem.eql(u8, advertised_resource, resource_url)) return error.ResourceMetadataMismatch;

    const servers = resource_metadata.get("authorization_servers") orelse return error.MissingAuthorizationServer;
    if (servers != .array or servers.array.items.len == 0) return error.MissingAuthorizationServer;
    var issuer: ?[]const u8 = null;
    for (servers.array.items) |server| {
        if (server != .string) continue;
        requireHttps(server.string) catch continue;
        issuer = server.string;
        break;
    }
    const selected = issuer orelse return error.InsecureOAuthEndpoint;

    var endpoints = authorizationEndpoints(io, gpa, arena, selected, try discovery.authorizationMetadataUrl(arena, selected)) catch
        authorizationEndpoints(io, gpa, arena, selected, try discovery.oidcInsertedMetadataUrl(arena, selected)) catch
        try authorizationEndpoints(io, gpa, arena, selected, try discovery.oidcAppendedMetadataUrl(arena, selected));
    var scope = discovery.preferredScope(
        challenge.scope,
        try supportedScopes(arena, resource_metadata),
        endpoints.scope,
    );
    // Core Smolify remains read-only. An explicit challenge is authoritative,
    // but fail closed if it requests permissions outside the pinned allowlist.
    if (std.mem.eql(u8, resource_url, smolify_resource)) {
        if (challenge.scope) |challenged| {
            if (challenged.len == 0) {
                scope = smolify_read_scopes;
            } else if (!discovery.scopeSubsetOf(challenged, smolify_read_scopes)) {
                return error.SmolifyScopeNotReadOnly;
            }
        } else {
            scope = smolify_read_scopes;
        }
    }
    endpoints.scope = scope;
    return endpoints;
}

fn registerClient(io: Io, gpa: Allocator, arena: Allocator, endpoint: []const u8, server_name: []const u8) !ClientInfo {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "client_name", .{ .string = server_name });
    try obj.put(arena, "token_endpoint_auth_method", .{ .string = "none" });
    var redirects = std.json.Array.init(arena);
    try redirects.append(.{ .string = redirect_uri });
    try obj.put(arena, "redirect_uris", .{ .array = redirects });
    var grants = std.json.Array.init(arena);
    try grants.append(.{ .string = "authorization_code" });
    try grants.append(.{ .string = "refresh_token" });
    try obj.put(arena, "grant_types", .{ .array = grants });
    var responses = std.json.Array.init(arena);
    try responses.append(.{ .string = "code" });
    try obj.put(arena, "response_types", .{ .array = responses });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    const response = try postJson(io, gpa, arena, endpoint, aw.writer.buffered());
    return .{
        .id = stringField(response, "client_id") orelse return error.BadOAuthResponse,
        .secret = stringField(response, "client_secret") orelse "",
    };
}

fn b64url(arena: Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const result = try arena.alloc(u8, encoder.calcSize(bytes.len));
    return encoder.encode(result, bytes);
}

fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{ "open", url }
    else if (builtin.os.tag == .windows)
        // Avoid cmd.exe: OAuth URLs contain '&', and passing discovered URLs
        // through a shell would both truncate them and permit injection.
        &.{ "rundll32.exe", "url.dll,FileProtocolHandler", url }
    else
        &.{ "xdg-open", url };
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return;
    _ = child.wait(io) catch {};
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn percentDecode(arena: Allocator, encoded: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, encoded.len);
    var src: usize = 0;
    var dst: usize = 0;
    while (src < encoded.len) {
        if (encoded[src] == '%') {
            if (src + 2 >= encoded.len) return error.BadOAuthResponse;
            const hi = hexNibble(encoded[src + 1]) orelse return error.BadOAuthResponse;
            const lo = hexNibble(encoded[src + 2]) orelse return error.BadOAuthResponse;
            out[dst] = (hi << 4) | lo;
            src += 3;
        } else {
            out[dst] = if (encoded[src] == '+') ' ' else encoded[src];
            src += 1;
        }
        dst += 1;
    }
    return out[0..dst];
}

fn queryParam(arena: Allocator, request_line: []const u8, name: []const u8) !?[]const u8 {
    const target_start = std.mem.indexOfScalar(u8, request_line, ' ') orelse return error.BadOAuthResponse;
    const target_tail = request_line[target_start + 1 ..];
    const target_end = std.mem.indexOfScalar(u8, target_tail, ' ') orelse return error.BadOAuthResponse;
    const target = target_tail[0..target_end];
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[qmark + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equal], name)) return try percentDecode(arena, pair[equal + 1 ..]);
    }
    return null;
}

fn tokenFromResponse(obj: std.json.ObjectMap, io: Io) !TokenSet {
    const access = stringField(obj, "access_token") orelse return error.BadOAuthResponse;
    const now = util.unixMs(io);
    const expires_at = if (integerField(obj, "expires_in")) |expires_in|
        if (expires_in <= 0)
            now
        else if (expires_in > @divTrunc(std.math.maxInt(i64) - now, 1000))
            std.math.maxInt(i64)
        else
            now + expires_in * 1000
    else
        std.math.maxInt(i64);
    return .{
        .access = access,
        .refresh = stringField(obj, "refresh_token") orelse "",
        .expires_at_ms = expires_at,
    };
}

fn credentialPath(arena: Allocator, home: []const u8, resource_url: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(resource_url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(arena, "{s}/.simple-harness-mcp/{s}.json", .{ home, &hex });
}

fn secureWindowsCredentials(io: Io, dir: []const u8, path: []const u8) !void {
    // Zig 0.16 does not implement chmod on Windows. Remove inherited ACLs and
    // grant full control only to the file owner, using a fixed SID and a
    // hash-only basename so no shell or user-controlled command text is used.
    const argv: []const []const u8 = &.{
        "icacls.exe",
        std.fs.path.basename(path),
        "/inheritance:r",
        "/grant:r",
        "*S-1-3-4:F",
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.CredentialPermissionsFailed;
}

fn writeCredentials(io: Io, arena: Allocator, home: []const u8, resource_url: []const u8, endpoints: EndpointSet, client: ClientInfo, tokens: TokenSet) !void {
    const dir = try std.fmt.allocPrint(arena, "{s}/.simple-harness-mcp", .{home});
    Io.Dir.cwd().createDir(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const path = try credentialPath(arena, home, resource_url);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "resource", .{ .string = resource_url });
    try obj.put(arena, "issuer", .{ .string = endpoints.issuer });
    try obj.put(arena, "authorization_endpoint", .{ .string = endpoints.authorization });
    try obj.put(arena, "token_endpoint", .{ .string = endpoints.token });
    try obj.put(arena, "registration_endpoint", .{ .string = endpoints.registration });
    try obj.put(arena, "scope", .{ .string = endpoints.scope });
    try obj.put(arena, "client_id", .{ .string = client.id });
    try obj.put(arena, "client_secret", .{ .string = client.secret });
    try obj.put(arena, "access_token", .{ .string = tokens.access });
    try obj.put(arena, "refresh_token", .{ .string = tokens.refresh });
    try obj.put(arena, "expires_at_ms", .{ .integer = tokens.expires_at_ms });
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    try stringify.write(Value{ .object = obj });
    const user_only: Io.Dir.Permissions = @enumFromInt(0o600);
    {
        const file = try Io.Dir.cwd().createFile(io, path, .{ .permissions = user_only });
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var fw = file.writer(io, &buffer);
        try fw.interface.writeAll(aw.writer.buffered());
        try fw.interface.flush();
    }
    if (builtin.os.tag == .windows)
        try secureWindowsCredentials(io, dir, path)
    else
        try Io.Dir.cwd().setFilePermissions(io, path, user_only, .{});
}

fn loginInner(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, server_name: []const u8, resource_url: []const u8, out: *Io.Writer) !void {
    try requireHttps(resource_url);
    try out.print("Discovering OAuth configuration for {s}…\n", .{resource_url});
    try out.flush();
    const endpoints = try discover(io, gpa, arena, resource_url);
    try out.print("Registering {s} with {s}…\n", .{ server_name, endpoints.issuer });
    try out.flush();
    const client = try registerClient(io, gpa, arena, endpoints.registration, server_name);

    var verifier_bytes: [48]u8 = undefined;
    io.random(&verifier_bytes);
    const verifier = try b64url(arena, &verifier_bytes);
    var challenge_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &challenge_bytes, .{});
    const challenge = try b64url(arena, &challenge_bytes);
    var state_bytes: [24]u8 = undefined;
    io.random(&state_bytes);
    const state = try b64url(arena, &state_bytes);

    var authorization_fields: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    try authorization_fields.append(arena, .{ "response_type", "code" });
    try authorization_fields.append(arena, .{ "client_id", client.id });
    try authorization_fields.append(arena, .{ "redirect_uri", redirect_uri });
    try authorization_fields.append(arena, .{ "code_challenge", challenge });
    try authorization_fields.append(arena, .{ "code_challenge_method", "S256" });
    try authorization_fields.append(arena, .{ "state", state });
    if (endpoints.scope.len != 0) try authorization_fields.append(arena, .{ "scope", endpoints.scope });
    try authorization_fields.append(arena, .{ "resource", resource_url });
    const query = try formEncode(arena, authorization_fields.items);
    const authorization_url = try std.fmt.allocPrint(arena, "{s}{c}{s}", .{
        endpoints.authorization,
        @as(u8, if (std.mem.indexOfScalar(u8, endpoints.authorization, '?') == null) '?' else '&'),
        query,
    });

    var address = std.Io.net.IpAddress.parseLiteral("127.0.0.1:1456") catch return error.BadOAuthResponse;
    var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer listener.deinit(io);
    try out.print("\nOpen this URL to authorize (the browser should open automatically):\n\n{s}\n\nWaiting for the callback on {s} …\n", .{ authorization_url, redirect_uri });
    try out.flush();
    openBrowser(io, authorization_url);

    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.net.Stream.Reader.init(stream, io, &read_buffer);
    const request_line = (reader.interface.takeDelimiter('\n') catch null) orelse return error.BadOAuthResponse;
    const code = try queryParam(arena, request_line, "code") orelse {
        const description = try queryParam(arena, request_line, "error_description") orelse
            try queryParam(arena, request_line, "error") orelse "authorization server returned no code";
        try out.print("OAuth authorization failed: {s}\n", .{description});
        try out.flush();
        return error.AuthorizationDenied;
    };
    const returned_state = try queryParam(arena, request_line, "state") orelse return error.StateMismatch;

    var write_buffer: [2048]u8 = undefined;
    var stream_writer = std.Io.net.Stream.Writer.init(stream, io, &write_buffer);
    if (!std.mem.eql(u8, state, returned_state)) {
        try stream_writer.interface.writeAll("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nOAuth state mismatch. Return to the CLI and try again.\n");
        try stream_writer.interface.flush();
        return error.StateMismatch;
    }
    try stream_writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nMCP authorization complete. You can close this tab.\n");
    try stream_writer.interface.flush();

    var fields = [_]struct { []const u8, []const u8 }{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", client.id },
        .{ "code", code },
        .{ "redirect_uri", redirect_uri },
        .{ "code_verifier", verifier },
        .{ "resource", resource_url },
        .{ "client_secret", client.secret },
    };
    const field_count: usize = if (client.secret.len == 0) fields.len - 1 else fields.len;
    const response = try postForm(io, gpa, arena, endpoints.token, try formEncode(arena, fields[0..field_count]));
    const tokens = try tokenFromResponse(response, io);
    try writeCredentials(io, arena, home, resource_url, endpoints, client, tokens);
    try out.print("✓ {s} authorized; credentials saved to {s}\n", .{ server_name, try credentialPath(arena, home, resource_url) });
    try out.flush();
}

/// Discover, register, and run an OAuth 2.1 authorization-code + PKCE flow for
/// an MCP protected resource, then persist the resulting credentials.
pub fn login(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, server_name: []const u8, resource_url: []const u8) !void {
    if (home.len == 0) return error.HomeDirectoryUnavailable;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    loginInner(io, gpa, arena, home, server_name, resource_url, &stdout.interface) catch |err| {
        try stdout.interface.print("✗ MCP OAuth login failed: {t}. Check the server URL and authorization-server metadata, then try again.\n", .{err});
        try stdout.interface.flush();
        return err;
    };
}

/// Load a resource's persisted access token.  Tokens within one minute of
/// expiry are refreshed first; any malformed, insecure, or failed credential
/// set is treated as unavailable.
pub fn loadAccessToken(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, resource_url: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    requireHttps(resource_url) catch return null;
    const path = credentialPath(arena, home, resource_url) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_response)) catch return null;
    const obj = jsonObject(data, arena) catch return null;
    const stored_resource = stringField(obj, "resource") orelse return null;
    if (!std.mem.eql(u8, stored_resource, resource_url)) return null;
    const access = stringField(obj, "access_token") orelse return null;
    const expires_at = integerField(obj, "expires_at_ms") orelse return null;
    if (expires_at > util.unixMs(io) + 60_000) return access;

    const refresh = stringField(obj, "refresh_token") orelse return null;
    if (refresh.len == 0) return null;
    const token_endpoint = stringField(obj, "token_endpoint") orelse return null;
    requireHttps(token_endpoint) catch return null;
    const client = ClientInfo{
        .id = stringField(obj, "client_id") orelse return null,
        .secret = stringField(obj, "client_secret") orelse "",
    };
    const fields = [_]struct { []const u8, []const u8 }{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", client.id },
        .{ "refresh_token", refresh },
        .{ "resource", resource_url },
        .{ "client_secret", client.secret },
    };
    const field_count: usize = if (client.secret.len == 0) fields.len - 1 else fields.len;
    const response = postForm(io, gpa, arena, token_endpoint, formEncode(arena, fields[0..field_count]) catch return null) catch return null;
    var tokens = tokenFromResponse(response, io) catch return null;
    if (tokens.refresh.len == 0) tokens.refresh = refresh;
    const endpoints = EndpointSet{
        .issuer = stringField(obj, "issuer") orelse return null,
        .authorization = stringField(obj, "authorization_endpoint") orelse return null,
        .token = token_endpoint,
        .registration = stringField(obj, "registration_endpoint") orelse return null,
        .scope = stringField(obj, "scope") orelse "",
    };
    writeCredentials(io, arena, home, resource_url, endpoints, client, tokens) catch return null;
    return tokens.access;
}

test "form encoding uses RFC 3986 percent encoding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const encoded = try formEncode(arena_state.allocator(), &.{
        .{ "plain", "AZaz09-._~" },
        .{ "space + slash", "a b+c/d" },
    });
    try std.testing.expectEqualStrings("plain=AZaz09-._~&space%20%2B%20slash=a%20b%2Bc%2Fd", encoded);
}

test "supported scopes are joined for authorization requests" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const metadata = try jsonObject("{\"scopes_supported\":[\"openid\",\"docs:read\",\"offline_access\"]}", arena);
    try std.testing.expectEqualStrings("openid docs:read offline_access", try supportedScopes(arena, metadata));
}

test "credential path is stable and resource-specific" {
    const path = try credentialPath(std.testing.allocator, "/home/alice", "https://mcp.example/api");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(
        "/home/alice/.simple-harness-mcp/d48481de503249e9a60247e669c522a432c2685e9af626d9d7e15794ab8f092e.json",
        path,
    );
}
