//! Impl half of the provider kernel: baked `provider_specs` must match
//! spec/kernels/providers.json (the Lean table).

const std = @import("std");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const ProviderSpec = provider_mod.ProviderSpec;

const fixtures_json = @embedFile("spec_providers");

fn kindName(k: Provider.Kind) []const u8 {
    return switch (k) {
        .anthropic => "anthropic",
        .openai => "openai",
        .responses => "responses",
        .interactions => "interactions",
    };
}

fn authName(a: Provider.Auth) []const u8 {
    return switch (a) {
        .x_api_key => "x_api_key",
        .bearer => "bearer",
        .goog_api_key => "goog_api_key",
    };
}

fn loginName(l: ProviderSpec.LoginKind) []const u8 {
    return switch (l) {
        .api_key => "api_key",
        .codegraff_device => "codegraff_device",
        .codex_device => "codex_device",
        .kimi_device => "kimi_device",
        .xai_device => "xai_device",
    };
}

fn catalogName(c: ProviderSpec.CatalogKind) []const u8 {
    return switch (c) {
        .baked => "baked",
        .codex => "codex",
        .kimi => "kimi",
        .openai => "openai",
        .anthropic => "anthropic",
    };
}

fn findRow(rows: []const std.json.Value, id: []const u8) ?std.json.ObjectMap {
    for (rows) |r| {
        if (std.mem.eql(u8, r.object.get("id").?.string, id)) return r.object;
    }
    return null;
}

test "spec/provider: baked specs match the Lean table" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("rows").?.array.items;
    try std.testing.expectEqual(rows.len, provider_mod.provider_specs.len);

    for (provider_mod.provider_specs) |spec| {
        const row = findRow(rows, spec.id) orelse {
            std.debug.print("\ncounterexample: {s} missing from Lean table\n", .{spec.id});
            return error.CatalogMismatch;
        };
        const fields = [_]struct { name: []const u8, want: []const u8, got: []const u8 }{
            .{ .name = "kind", .want = row.get("kind").?.string, .got = kindName(spec.kind) },
            .{ .name = "auth", .want = row.get("auth").?.string, .got = authName(spec.auth) },
            .{ .name = "login", .want = row.get("login").?.string, .got = loginName(spec.login) },
            .{ .name = "catalog", .want = row.get("catalog").?.string, .got = catalogName(spec.catalog) },
        };
        for (fields) |f| {
            if (!std.mem.eql(u8, f.want, f.got)) {
                std.debug.print("\ncounterexample {s}.{s}: want={s} got={s}\n", .{ spec.id, f.name, f.want, f.got });
                return error.CatalogMismatch;
            }
        }
        if (row.get("sub_login").?.bool != spec.sub_login) {
            std.debug.print("\ncounterexample {s}.sub_login\n", .{spec.id});
            return error.CatalogMismatch;
        }
        if (row.get("takes_effort").?.bool != spec.takes_effort) {
            std.debug.print("\ncounterexample {s}.takes_effort\n", .{spec.id});
            return error.CatalogMismatch;
        }
    }
}
