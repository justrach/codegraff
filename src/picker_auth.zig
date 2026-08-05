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
const oauth_helpers = @import("oauth_helpers.zig"); // the test pins g_codex_home, the resolver startup sets
const policy = @import("agent_request_policy.zig");
const providers = @import("providers.zig");
const switchProvider = providers.switchProvider;
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const command_catalog = @import("command_catalog.zig");
const pricing = @import("pricing.zig");
const kimi_catalog = @import("kimi_catalog.zig");

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
/// (and the Codex account id) into the live Keys AND into the running agent, so
/// the current conversation uses it without a restart — the in-session twin of
/// the startup loaders.
pub fn reloadLoginKey(root: *Agent, keys: *Keys, arena: Allocator, provider_id: []const u8) void {
    const home = root.home;
    for (provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        var reloaded = false;
        if (std.mem.eql(u8, provider_id, "codegraff")) {
            if (oauth.loadCodegraffKey(root.io, arena, home)) |k| {
                value.* = k;
                source.* = .login;
                reloaded = true;
            }
        } else if (std.mem.eql(u8, provider_id, "kimi")) {
            if (oauth.loadKimiOAuth(root.io, root.gpa, arena, home, false, null)) |k| {
                value.* = k;
                source.* = .login;
                reloaded = true;
            }
        } else if (std.mem.eql(u8, provider_id, "xai")) {
            if (oauth.loadXaiOAuth(root.io, root.gpa, arena, home, false, null)) |k| {
                value.* = k;
                source.* = .login;
                reloaded = true;
            }
        } else if (std.mem.eql(u8, provider_id, "codex")) {
            if (oauth.loadCodexAuth(root.io, arena, home)) |auth| {
                value.* = auth.token;
                source.* = .login;
                keys.codex_account = auth.account;
                reloaded = true;
            }
        }
        // #402: the live Agent holds its OWN Provider copy — providers.applyProviderInner
        // is otherwise the only writer — so refreshing Keys alone left the active
        // session bound to the token that had just expired: `/login` reported success
        // and every following turn (plus its auto-compaction) kept 401ing. The
        // provider.id guard is what keeps `/login kimi` from hijacking a live codex
        // session; the model-picker path re-assigns via switchProvider anyway.
        //
        // adoptFreshAuth is the same binding the mid-turn refresh uses: it dupes
        // BOTH the key and the account id onto the session arena (this function's
        // `arena` parameter can be a scoped caller arena, and account outlives it),
        // and releases the WS transport latch the expired credential earned.
        if (reloaded) if (value.*) |key| if (std.mem.eql(u8, root.provider.id, provider_id)) {
            const is_codex = std.mem.eql(u8, provider_id, "codex");
            policy.adoptFreshAuth(root, .{ .key = key, .account = if (is_codex) keys.codex_account else "" });
            root.provider.source = .login;
            root.closeCodexWs(); // the held socket was dialed with the stale bearer
        };
    }
    if (std.mem.eql(u8, provider_id, "codex") and keys.get("codex") != null)
        root.reloadModelCatalog(keys.*);
}

test "#402: reloadLoginKey hot-reloads the ACTIVE agent's credential, not just Keys" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/.codex", .{home}));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/.codex/auth.json", .{home}),
        .data =
        \\{"tokens":{"access_token":"fresh-tok","refresh_token":"r1","account_id":"acct-2"}}
        ,
    });

    const saved_codex_home = oauth_helpers.g_codex_home;
    defer oauth_helpers.g_codex_home = saved_codex_home;
    oauth_helpers.g_codex_home = ""; // CODEX_HOME unset: ~/.codex

    var root: Agent = undefined;
    root.io = io;
    root.gpa = std.testing.allocator;
    root.arena = arena;
    root.scratch_arena = null;
    root.tracer = null;
    root.sub = false;
    root.out = null;
    root.label = "root";
    root.home = home;
    root.model_catalog = null; // the catalog reload would go to the network
    root.codex_ws = null;
    root.codex_prev_id = try std.testing.allocator.dupe(u8, "resp_stale");
    root.codex_sent_upto = 7;
    root.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "expired-tok", .model = "gpt-5.6", .context = 272000, .account = "acct-1", .source = .login };

    var keys: Keys = .{ .values = @splat(null) };
    reloadLoginKey(&root, &keys, arena, "codex");

    try std.testing.expectEqualStrings("fresh-tok", keys.get("codex").?);
    // The #402 fix: the LIVE provider, not only Keys. Without this, /login reported
    // success while every subsequent turn and auto-compaction kept 401ing.
    try std.testing.expectEqualStrings("fresh-tok", root.provider.api_key);
    try std.testing.expectEqualStrings("acct-2", root.provider.account);
    // The held WS was dialed with the stale bearer, and PR #195 forbids resending
    // against a chain the new credential never anchored.
    try std.testing.expect(root.codex_prev_id == null);
    try std.testing.expectEqual(@as(usize, 0), root.codex_sent_upto);

    // `/login kimi` mid-codex-session must not repoint the active provider — that
    // would silently switch the user's model AND wire format.
    root.provider.api_key = "expired-tok";
    root.codex_prev_id = try std.testing.allocator.dupe(u8, "resp_two");
    reloadLoginKey(&root, &keys, arena, "kimi"); // no kimi credential on disk here
    try std.testing.expectEqualStrings("expired-tok", root.provider.api_key);
    try std.testing.expectEqualStrings("codex", root.provider.id);
    try std.testing.expect(root.codex_prev_id != null);
    std.testing.allocator.free(root.codex_prev_id.?);
    root.codex_prev_id = null;

    // The #402 split-brain: with CODEX_HOME set, `/login` must read back the very
    // file the request loop's refresh reads and writes. Before the fix this half
    // stayed on ~/.codex while the refresh resolved $CODEX_HOME, so `/login`
    // reported success and the next request's proactive read silently reverted the
    // session to the expired token.
    const custom = try std.fmt.allocPrint(arena, "{s}/custom-codex-home", .{home});
    try Io.Dir.cwd().createDirPath(io, custom);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{custom}),
        .data =
        \\{"tokens":{"access_token":"env-tok","refresh_token":"","account_id":"acct-3"}}
        ,
    });
    oauth_helpers.g_codex_home = custom;
    root.provider.api_key = "expired-tok";
    reloadLoginKey(&root, &keys, arena, "codex");
    try std.testing.expectEqualStrings("env-tok", root.provider.api_key);
    try std.testing.expectEqualStrings("acct-3", root.provider.account);

    // …and the mid-turn recovery resolves the SAME file, so it cannot undo the
    // login it just observed.
    var refreshed = false;
    try std.testing.expect(!policy.retryAfterAuthRefresh(&root, "Unauthorized", &refreshed));
    try std.testing.expectEqualStrings("env-tok", root.provider.api_key);
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
        const byte = @import("input_util.zig").editByte(in) orelse return null; // #396: guarded
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
    const spec = provider_mod.specFor(pid) orelse {
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
            try out.print("no key for {s} — /key {s} <key> (or set {s})\n", .{ pid, pid, spec.env_key });
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
        try out.print("kept {s}{s}{s}\n", .{ style.accent, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    const picked = items[choice].name;

    if (std.mem.eql(u8, picked, "keep current model")) {
        try out.print("kept {s}{s}{s}\n", .{ style.accent, root.provider.model, style.reset });
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
            try out.print("cancelled — kept {s}{s}{s}\n", .{ style.accent, root.provider.model, style.reset });
            try out.flush();
            return;
        }
        const dup = arena.dupe(u8, key) catch key;
        const saved = storeKey(root.io, root.gpa, arena, root.home, pid, dup);
        _ = keys.set(pid, dup, if (saved) .stored else .session);
        if (std.mem.eql(u8, pid, "kimi")) _ = kimi_catalog.load(root.io, root.gpa, arena, root.home, dup);
        try out.print("\xe2\x9c\x93 {s} key set (live{s})\n", .{ pid, if (saved) " + Keychain" else "" });
    }

    // Auth done — switch now if the key/login took, else keep the current model.
    const selected_model = if (default_selection and std.mem.eql(u8, pid, "codex"))
        pricing.providerDefaultModel(pid, spec.default_model)
    else
        model;
    const provider = keys.providerById(pid, selected_model) catch {
        try out.print("still no usable key for {s} — kept {s}{s}{s}\n", .{ pid, style.accent, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    try switchProvider(root, arena, provider, out);
}
