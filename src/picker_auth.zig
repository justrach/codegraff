//! Provider authentication flow used by the interactive model picker.
//! The picker UI itself stays in pickers.zig; it is injected here to avoid
//! making this helper depend back on the module that re-exports it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;
const term = @import("term.zig");
const tty = term.tty;
const oauth = @import("oauth.zig");
const providers = @import("providers.zig");
const switchProvider = providers.switchProvider;
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const command_catalog = @import("command_catalog.zig");
const pricing = @import("pricing.zig");

const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const provider_specs = provider_mod.provider_specs;
const storeKey = keys_cli.storeKey;
const PickItem = command_catalog.Item;

pub const PickerFn = *const fn (
    root: *Agent,
    arena: Allocator,
    out: *Io.Writer,
    title: []const u8,
    items: []const PickItem,
) ?usize;

/// After an in-session `/login` writes its credential file, pull the fresh key
/// (and the Codex account id) into the live Keys so the current conversation
/// uses it without a restart — the in-session twin of the startup loaders.
pub fn reloadLoginKey(root: *Agent, keys: *Keys, arena: Allocator, provider_id: []const u8) void {
    const home = root.home;
    for (provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        if (std.mem.eql(u8, provider_id, "codegraff")) {
            if (oauth.loadCodegraffKey(root.io, arena, home)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "kimi")) {
            if (oauth.loadKimiOAuth(root.io, root.gpa, arena, home, false)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "xai")) {
            if (oauth.loadXaiOAuth(root.io, root.gpa, arena, home, false)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "codex")) {
            if (oauth.loadCodexAuth(root.io, arena, home)) |auth| {
                value.* = auth.token;
                source.* = .login;
                keys.codex_account = auth.account;
            }
        }
    }
    if (std.mem.eql(u8, provider_id, "codex") and keys.get("codex") != null)
        root.reloadModelCatalog(keys.*);
}

/// Read an API key without terminal echo or history persistence. The ordinary
/// REPL line editor masks `/key provider secret`; this covers the model
/// picker's separate "paste an API key" flow too.
fn readSecret(root: *Agent, arena: Allocator, out: *Io.Writer) ?[]const u8 {
    const in = root.in orelse return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    var secret: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = in.takeByte() catch return null;
        switch (byte) {
            '\r', '\n' => {
                out.writeByte('\n') catch {};
                out.flush() catch {};
                return secret.toOwnedSlice(arena) catch secret.items;
            },
            0x03, 0x07 => {
                out.writeByte('\n') catch {};
                out.flush() catch {};
                return null;
            },
            0x7f, 0x08 => if (secret.items.len > 0) {
                _ = secret.pop();
                out.writeAll("\x08 \x08") catch {};
                out.flush() catch {};
            },
            else => if (byte >= 0x20) {
                secret.append(arena, byte) catch return null;
                out.writeByte('*') catch {};
                out.flush() catch {};
            },
        }
    }
}

/// Better UX when /model targets a provider with no key: offer OAuth login or
/// key entry and then switch to the requested provider/model. `pick` is the
/// generic picker owned by pickers.zig.
pub fn offerProviderAuth(
    root: *Agent,
    keys: *Keys,
    arena: Allocator,
    out: *Io.Writer,
    pid: []const u8,
    model: []const u8,
    default_selection: bool,
    use_color: bool,
    pick: PickerFn,
) !void {
    var spec_idx: ?usize = null;
    for (provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, pid)) {
        spec_idx = i;
    };
    const si = spec_idx orelse {
        try out.print("unknown provider '{s}' — see /model for the list\n", .{pid});
        try out.flush();
        return;
    };
    const can_login = std.mem.eql(u8, pid, "codegraff") or std.mem.eql(u8, pid, "codex") or std.mem.eql(u8, pid, "kimi") or std.mem.eql(u8, pid, "xai");

    // Non-interactive (one-shot / no TTY): no picker — print the hint and bail.
    if (!use_color or root.in == null) {
        if (can_login)
            try out.print("no key for {s} — /login {s} (OAuth) or /key {s} <key>\n", .{ pid, pid, pid })
        else
            try out.print("no key for {s} — /key {s} <key> (or set {s})\n", .{ pid, pid, provider_specs[si].env_key });
        try out.flush();
        return;
    }

    // Choice menu — login row only when the provider actually has an OAuth flow.
    var items: [3]PickItem = undefined;
    var n: usize = 0;
    if (can_login) {
        items[n] = .{ .name = "log in (OAuth)", .desc = "device/browser sign-in — no key to paste" };
        n += 1;
    }
    items[n] = .{ .name = "paste an API key", .desc = "enter a key now (used live + saved)" };
    n += 1;
    items[n] = .{ .name = "keep current model", .desc = "cancel — stay on the current model" };
    n += 1;

    const title = std.fmt.allocPrint(arena, "No key for {s} \xe2\x80\xba", .{pid}) catch "No key \xe2\x80\xba";
    const choice = pick(root, arena, out, title, items[0..n]) orelse {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    const picked = items[choice].name;

    if (std.mem.eql(u8, picked, "keep current model")) {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, picked, "log in (OAuth)")) {
        const home = root.home;
        try out.flush(); // hand stdout to the login flow's own writer
        if (std.mem.eql(u8, pid, "codegraff")) {
            oauth.codegraffLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 codegraff login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "codex")) {
            oauth.codexLogin(root.io, root.gpa, arena, home, false) catch |err| {
                try out.print("\xe2\x9c\x97 codex login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "kimi")) {
            oauth.kimiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 kimi login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "xai")) {
            oauth.xaiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 xai login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        }
        reloadLoginKey(root, keys, arena, pid);
    } else {
        try out.print("paste your {s} API key, then Enter (input is hidden; blank cancels): ", .{pid});
        try out.flush();
        const key = readSecret(root, arena, out) orelse "";
        if (key.len == 0) {
            try out.print("cancelled — kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
            try out.flush();
            return;
        }
        const dup = arena.dupe(u8, key) catch key;
        keys.values[si] = dup;
        const saved = storeKey(root.io, root.gpa, arena, root.home, pid, dup);
        keys.sources[si] = if (saved) .stored else .session;
        try out.print("\xe2\x9c\x93 {s} key set (live{s})\n", .{ pid, if (saved) " + Keychain" else "" });
    }

    // Auth done — switch now if the key/login took, else keep the current model.
    const selected_model = if (default_selection and std.mem.eql(u8, pid, "codex"))
        pricing.providerDefaultModel(pid, provider_specs[si].default_model)
    else
        model;
    const provider = keys.providerById(pid, selected_model) catch {
        try out.print("still no usable key for {s} — kept {s}{s}{s}\n", .{ pid, style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    try switchProvider(root, arena, provider, out);
}
