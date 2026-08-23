//! Workspace-local OpenAI-compatible router configuration.
//!
//! `.graff/.config.router` contains endpoint metadata only. Credentials stay
//! in the named environment variable or Graff's existing secure key store.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const provider = @import("provider.zig");
const pricing = @import("pricing.zig");

pub const path = ".graff/.config.router";

pub const Error = error{
    InvalidJson,
    ExpectedObject,
    MissingId,
    MissingBaseUrl,
    MissingEnvKey,
    MissingDefaultModel,
    InvalidId,
    DuplicateId,
    InvalidBaseUrl,
    InvalidEnvKey,
    InvalidDefaultModel,
    InvalidName,
    InlineSecret,
};

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 48 or !std.ascii.isAlphanumeric(id[0])) return false;
    for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn validEnvKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128 or !(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > 256) return false;
    for (model) |c| if (std.ascii.isWhitespace(c) or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validBaseUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > 2048) return false;
    const scheme_len: usize = if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else
        return false;
    if (url.len <= scheme_len or url[scheme_len] == '/' or std.mem.indexOfAny(u8, url, "?#") != null) return false;
    for (url) |c| if (std.ascii.isWhitespace(c) or c < 0x20 or c == 0x7f) return false;
    return true;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

pub fn parse(arena: Allocator, data: []const u8) (Error || Allocator.Error)!provider.ProviderSpec {
    const value = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch
        return error.InvalidJson;
    if (value != .object) return error.ExpectedObject;
    if (value.object.get("api_key") != null or value.object.get("key") != null or value.object.get("token") != null)
        return error.InlineSecret;
    const id = stringField(value.object, "id") orelse return error.MissingId;
    const base_value = stringField(value.object, "base_url") orelse return error.MissingBaseUrl;
    const env_key = stringField(value.object, "env_key") orelse return error.MissingEnvKey;
    const default_model = stringField(value.object, "default_model") orelse return error.MissingDefaultModel;
    if (!validId(id)) return error.InvalidId;
    for (provider.provider_specs) |spec|
        if (std.mem.eql(u8, spec.id, id)) return error.DuplicateId;
    if (!validBaseUrl(base_value)) return error.InvalidBaseUrl;
    if (!validEnvKey(env_key)) return error.InvalidEnvKey;
    if (!validModel(default_model)) return error.InvalidDefaultModel;

    const base_url = std.mem.trimEnd(u8, base_value, "/");
    const display_name = stringField(value.object, "name") orelse id;
    if (!validName(display_name)) return error.InvalidName;
    const takes_effort = if (value.object.get("takes_effort")) |field|
        field == .bool and field.bool
    else
        false;
    return .{
        .id = try arena.dupe(u8, id),
        .display_name = try arena.dupe(u8, display_name),
        .kind = .openai,
        .auth = .bearer,
        .url = try std.fmt.allocPrint(arena, "{s}/chat/completions", .{base_url}),
        .env_key = try arena.dupe(u8, env_key),
        .default_model = try arena.dupe(u8, default_model),
        .catalog = .openai,
        .models_url = try std.fmt.allocPrint(arena, "{s}/models", .{base_url}),
        .takes_effort = takes_effort,
    };
}

/// Load the optional project router. A missing file is normal; malformed
/// configuration is returned so startup can explain it instead of ignoring it.
pub fn load(io: Io, arena: Allocator) !void {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            provider.additional_router = null;
            return;
        },
        else => return err,
    };
    const spec = try parse(arena, data);
    provider.additional_router = spec;
    const fallback = [_]pricing.ModelInfo{.{
        .provider = spec.id,
        .name = spec.default_model,
        .context = pricing.default_context,
        .supports_reasoning = spec.takes_effort,
    }};
    _ = pricing.activateProviderModels(arena, spec.id, &fallback);
}

test "parse derives OpenAI-compatible endpoints without accepting a secret" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const spec = try parse(state.allocator(),
        \\{
        \\  "id": "myrouter",
        \\  "name": "My Router",
        \\  "base_url": "https://router.example.com/v1/",
        \\  "env_key": "MYROUTER_API_KEY",
        \\  "default_model": "example/model",
        \\  "takes_effort": true
        \\}
    );
    try std.testing.expectEqualStrings("myrouter", spec.id);
    try std.testing.expectEqualStrings("https://router.example.com/v1/chat/completions", spec.url);
    try std.testing.expectEqualStrings("https://router.example.com/v1/models", spec.models_url);
    try std.testing.expect(spec.takes_effort);
}

test "parse rejects collisions and malformed router fields" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const allocator = state.allocator();
    try std.testing.expectError(error.DuplicateId, parse(allocator,
        \\{"id":"openai","base_url":"https://example.com/v1","env_key":"KEY","default_model":"m"}
    ));
    try std.testing.expectError(error.InvalidBaseUrl, parse(allocator,
        \\{"id":"custom","base_url":"file:///tmp","env_key":"KEY","default_model":"m"}
    ));
    try std.testing.expectError(error.InvalidEnvKey, parse(allocator,
        \\{"id":"custom","base_url":"https://example.com/v1","env_key":"BAD-KEY","default_model":"m"}
    ));
    try std.testing.expectError(error.InlineSecret, parse(allocator,
        \\{"id":"custom","base_url":"https://example.com/v1","env_key":"KEY","default_model":"m","api_key":"secret"}
    ));
}
