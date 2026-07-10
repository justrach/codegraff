//! `graff cube` + `graff sandboxes` — the cloud sandbox/cube CLI plus the
//! gateway REST helpers they share. Split out of main.zig (#123).
//!
//! Imports ansi for the color palette and back-imports main for the shared
//! JSON getters (strFieldObj/intFieldObj), the gateway base URL, and the
//! version string. Zig resolves the main<->cube import cycle fine.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const root = @import("main.zig");
const util = @import("util.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const codegraff_device_base = root.codegraff_device_base;
const harness_version = root.harness_version;

// Gateway REST helpers shared by `graff sandboxes` and `graff cube`.
// gatewayFetch returns status + raw body without judging; gatewayJson is the
// strict variant — non-2xx is fatal with the gateway's error message. A null
// payload on POST sends "{}" (the gateway rejects empty bodies).
const GatewayResponse = struct { code: u16, body: []const u8 };

fn gatewayFetch(io: Io, gpa: Allocator, arena: Allocator, method: std.http.Method, url: []const u8, key: []const u8, payload: ?[]const u8) !GatewayResponse {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const default_payload: ?[]const u8 = if (method == .POST) "{}" else null;
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload orelse default_payload,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{key}) },
            .user_agent = .{ .override = "simple-harness/" ++ harness_version },
        },
    });
    return .{ .code = @intFromEnum(res.status), .body = aw.writer.buffered() };
}

fn gatewayJson(io: Io, gpa: Allocator, arena: Allocator, method: std.http.Method, url: []const u8, key: []const u8, payload: ?[]const u8) !Value {
    const r = try gatewayFetch(io, gpa, arena, method, url, key, payload);
    if (r.code < 200 or r.code >= 300) {
        var msg: []const u8 = r.body;
        if (std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) if (v.object.get("error")) |e| if (e == .object)
                if (e.object.get("message")) |m| if (m == .string) {
                    msg = m.string;
                };
        } else |_| {}
        std.process.fatal("gateway: HTTP {d}: {s}", .{ r.code, msg[0..@min(msg.len, 200)] });
    }
    return std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always });
}

// `graff sandboxes [stop <id>]` — the account's gateway sandboxes: the same
// ones the PR bot, the e2e cube probe, and the iOS app create. List shows
// state + spec + labels so you can see what's burning credits; stop spins one
// down via the gateway, which settles its billing meter.

pub fn sandboxesCommand(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    if (args.len >= 2 and std.mem.eql(u8, args[0], "stop")) {
        const url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/stop", .{args[1]});
        const resp = try gatewayJson(io, gpa, arena, .POST, url, key, null);
        const state = if (resp == .object) (strFieldObj(resp.object, "state") orelse "stopped") else "stopped";
        const cost_micro = if (resp == .object) intFieldObj(resp.object, "costMicro", 0) else 0;
        const usd = @as(f64, @floatFromInt(cost_micro)) / 1e6;
        try out.print("{s}✓{s} {s} → {s} (meter settled ${d:.4})\n", .{ style.green, style.reset, args[1], state, usd });
        try out.flush();
        return;
    }
    if (args.len != 0 and !std.mem.eql(u8, args[0], "list"))
        std.process.fatal("usage: graff sandboxes [stop <id>]", .{});

    const resp = try gatewayJson(io, gpa, arena, .GET, codegraff_device_base ++ "/v1/sandboxes", key, null);
    if (resp != .array) std.process.fatal("sandboxes: unexpected gateway response (not a list)", .{});
    if (resp.array.items.len == 0) {
        try out.writeAll("no sandboxes — nothing is burning credits\n");
        try out.flush();
        return;
    }
    try out.print("{s}{s:<36}  {s:<8}  {s:<9}  {s:<16}  {s}{s}\n", .{ style.dim, "id", "state", "spec", "label", "created", style.reset });
    for (resp.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const id = strFieldObj(o, "id") orelse "?";
        const state = strFieldObj(o, "state") orelse "?";
        const spec = try std.fmt.allocPrint(arena, "{d}c/{d}g/{d}g", .{
            intFieldObj(o, "cpu", 0), intFieldObj(o, "memory", 0), intFieldObj(o, "disk", 0),
        });
        var label: []const u8 = "";
        if (o.get("labels")) |l| if (l == .object) {
            label = strFieldObj(l.object, "purpose") orelse strFieldObj(l.object, "app") orelse "";
        };
        const created_full = strFieldObj(o, "createdAt") orelse "";
        const created = created_full[0..@min(created_full.len, 16)];
        const scolor = if (std.mem.eql(u8, state, "started")) style.green else style.dim;
        try out.print("{s:<36}  {s}{s:<8}{s}  {s:<9}  {s:<16}  {s}\n", .{ id, scolor, state, style.reset, spec, label, created });
    }
    try out.flush();
}

// ---- graff cube: a personal cloud graff (sandbox + serve + preview) ----
// `cube new` productizes scripts/e2e-cube-serve.py: create a gateway sandbox,
// install graff in it, start `graff serve` behind a fresh token, mint a
// Daytona preview URL, and save the connection to .graff/cube-state.json so
// any serve client (the iOS app, curl, another machine) can attach with the
// printed base + token. `cube status` re-checks it; `cube stop` spins the
// sandbox down and settles the meter. This is the broker the iOS app mirrors.
const cube_state_file = ".graff/cube-state.json";
const cube_port: u16 = 8787;

fn cubeExec(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, sandbox_id: []const u8, command: []const u8, timeout_s: i64, asynch: bool) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "command", .{ .string = command });
    try obj.put(arena, "timeoutSeconds", .{ .integer = timeout_s });
    if (asynch) try obj.put(arena, "async", .{ .bool = true });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    const url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/exec", .{sandbox_id});
    return gatewayJson(io, gpa, arena, .POST, url, key, aw.writer.buffered());
}

fn cubeReadState(io: Io, arena: Allocator) ?std.json.ObjectMap {
    const data = Io.Dir.cwd().readFileAlloc(io, cube_state_file, arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    return v.object;
}

fn cubePrintAttach(out: *Io.Writer, st: std.json.ObjectMap) !void {
    const url = strFieldObj(st, "preview_url") orelse return;
    const tok = strFieldObj(st, "serve_token") orelse return;
    try out.print("  attach any serve client:\n    GRAFF_SERVE_BASE={s}\n    GRAFF_SERVE_TOKEN={s}\n", .{ url, tok });
    if (strFieldObj(st, "preview_token")) |pt|
        try out.print("    x-daytona-preview-token: {s}\n", .{pt});
    if (strFieldObj(st, "github_login")) |gl|
        try out.print("  github: {s} (git push + gh ready inside)\n", .{gl});
}

// GitHub for the cube — the same access @codegraff-bot gets. The frontend
// mints a 1-hour installation token for the account's connected GitHub
// (POST /api/github/mint-token, Bearer cg_sk_); we then provision the sandbox:
// git credential store + identity, the gh CLI, and a 0600 token file that the
// serve environment exports as GH_TOKEN. Not connected → the cube still
// works, just without repo access.
const cube_mint_url = "https://codegraff.com/api/github/mint-token";
const CubeGithub = struct { login: []const u8, token: []const u8 };

fn cubeGithubProvision(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, sandbox_id: []const u8, out: *Io.Writer) !?CubeGithub {
    const r = gatewayFetch(io, gpa, arena, .POST, cube_mint_url, key, "{}") catch {
        try out.writeAll("  github: mint endpoint unreachable — cube gets no repo access\n");
        try out.flush();
        return null;
    };
    if (r.code == 404) {
        try out.writeAll("  github: not connected — connect at codegraff.com/dashboard for repo access\n");
        try out.flush();
        return null;
    }
    if (r.code < 200 or r.code >= 300) {
        try out.print("  github: mint failed (HTTP {d}) — cube gets no repo access\n", .{r.code});
        try out.flush();
        return null;
    }
    const v = std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const token = strFieldObj(v.object, "token") orelse return null;
    const login = strFieldObj(v.object, "account_login") orelse "github";

    try out.print("  wiring github ({s}) …\n", .{login});
    try out.flush();
    const cmd = try std.fmt.allocPrint(arena, "mkdir -p $HOME/bin && git config --global credential.helper store && " ++
        "printf 'https://x-access-token:%s@github.com\\n' '{s}' > $HOME/.git-credentials && chmod 600 $HOME/.git-credentials && " ++
        "printf '%s' '{s}' > $HOME/.cube-github-token && chmod 600 $HOME/.cube-github-token && " ++
        "git config --global user.name '{s}' && git config --global user.email '{s}@users.noreply.github.com' && " ++
        "(command -v gh >/dev/null 2>&1 || (A=$(uname -m); case \"$A\" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; esac; " ++
        "V=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | grep -o '\"tag_name\": *\"[^\"]*\"' | head -1 | cut -d'\"' -f4); " ++
        "curl -fsSL https://github.com/cli/cli/releases/download/$V/gh_${{V#v}}_linux_$A.tar.gz | tar -xz -C /tmp && " ++
        "mv /tmp/gh_${{V#v}}_linux_$A/bin/gh $HOME/bin/gh)) && echo GH-PROVISIONED", .{ token, token, login, login });
    const res = cubeExec(io, gpa, arena, key, sandbox_id, cmd, 90, false) catch {
        try out.writeAll("  github: provisioning exec failed — continuing without\n");
        try out.flush();
        return null;
    };
    const okout = if (res == .object) (strFieldObj(res.object, "result") orelse "") else "";
    if (std.mem.indexOf(u8, okout, "GH-PROVISIONED") == null) {
        try out.print("  github: provisioning failed — continuing without (tail: {s})\n", .{okout[(okout.len -| 160)..]});
        try out.flush();
        return null;
    }
    try out.print("  github: connected as {s} (git push + gh CLI ready; token ~1h)\n", .{login});
    try out.flush();
    return .{ .login = login, .token = token };
}

// Reach serve from THIS machine through the preview proxy — any HTTP status
// proves the pipe (serve 404s a bare GET /); only a transport error means no.
fn cubePipeProbe(io: Io, gpa: Allocator, arena: Allocator, base: []const u8, serve_token: []const u8, preview_token: ?[]const u8) u16 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    var extra: [1]std.http.Header = undefined;
    var n: usize = 0;
    if (preview_token) |pt| {
        extra[n] = .{ .name = "x-daytona-preview-token", .value = pt };
        n += 1;
    }
    const res = client.fetch(.{
        .location = .{ .url = std.fmt.allocPrint(arena, "{s}/", .{base}) catch return 0 },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{
            .authorization = .{ .override = std.fmt.allocPrint(arena, "Bearer {s}", .{serve_token}) catch return 0 },
            .user_agent = .{ .override = "simple-harness/" ++ harness_version },
        },
        .extra_headers = extra[0..n],
    }) catch return 0;
    return @intFromEnum(res.status);
}

fn cubeNew(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, out: *Io.Writer, minutes: i64) !void {
    // Cost ladder, cheapest first: a running cube is reused as-is; a stopped
    // one is woken without reinstalling (its disk survives a stop); only a
    // gone/archived one pays the full spin-up again.
    var resume_id: ?[]const u8 = null;
    if (cubeReadState(io, arena)) |st| {
        if (strFieldObj(st, "sandbox_id")) |old_id| {
            const info_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}", .{old_id});
            if (gatewayFetch(io, gpa, arena, .GET, info_url, key, null)) |r| {
                if (r.code >= 200 and r.code < 300) {
                    if (std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always })) |info| {
                        if (info == .object) {
                            const s = strFieldObj(info.object, "state") orelse "";
                            if (std.mem.eql(u8, s, "started")) {
                                try out.print("cube already running: {s} (no new spin-up cost)\n", .{old_id});
                                try cubePrintAttach(out, st);
                                try out.flush();
                                return;
                            }
                            if (std.mem.eql(u8, s, "stopped")) resume_id = try arena.dupe(u8, old_id);
                        }
                    } else |_| {}
                }
            } else |_| {}
        }
    }

    var id: []const u8 = undefined;
    if (resume_id) |rid| {
        id = rid;
        try out.print("waking stopped cube {s} — cheaper than a fresh spin-up (no reinstall)\n", .{rid});
        try out.flush();
        const start_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/start", .{rid});
        _ = try gatewayJson(io, gpa, arena, .POST, start_url, key, null);
    } else {
        try out.writeAll("spinning up a cube …\n");
        try out.flush();
        const create_body = try std.fmt.allocPrint(arena, "{{\"autoStopMinutes\":{d},\"labels\":{{\"purpose\":\"cube\"}}}}", .{minutes});
        const created = try gatewayJson(io, gpa, arena, .POST, codegraff_device_base ++ "/v1/sandboxes", key, create_body);
        if (created != .object) std.process.fatal("cube: unexpected create response", .{});
        id = strFieldObj(created.object, "id") orelse std.process.fatal("cube: create returned no id", .{});
        try out.print("  sandbox {s}\n", .{id});
        try out.flush();
    }

    var state: []const u8 = "";
    var waits: usize = 0;
    while (waits < 60) : (waits += 1) {
        const info_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}", .{id});
        const info = try gatewayJson(io, gpa, arena, .GET, info_url, key, null);
        if (info == .object) state = strFieldObj(info.object, "state") orelse "";
        if (std.mem.eql(u8, state, "started")) break;
        io.sleep(Io.Duration.fromSeconds(2), .awake) catch {};
    }
    if (!std.mem.eql(u8, state, "started"))
        std.process.fatal("cube: sandbox never reached started (last state '{s}')", .{state});

    if (resume_id == null) {
        try out.writeAll("  installing graff …\n");
        try out.flush();
        const inst = try cubeExec(io, gpa, arena, key, id, "curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash", 120, false);
        if (inst != .object or intFieldObj(inst.object, "exitCode", 1) != 0) {
            const r = if (inst == .object) (strFieldObj(inst.object, "result") orelse "") else "";
            std.process.fatal("cube: graff install failed: {s}", .{r[(r.len -| 300)..]});
        }
    }

    // Fresh token every bring-up — the previous one expires after an hour.
    const gh = try cubeGithubProvision(io, gpa, arena, key, id, out);

    var tok_bytes: [24]u8 = undefined;
    io.random(&tok_bytes);
    var tok_buf: [32]u8 = undefined;
    const serve_token = std.base64.url_safe_no_pad.Encoder.encode(&tok_buf, &tok_bytes);

    try out.writeAll("  starting graff serve …\n");
    try out.flush();
    const launch = if (gh) |g|
        try std.fmt.allocPrint(arena, "CODEGRAFF_API_KEY={s} GH_TOKEN={s} GITHUB_LOGIN={s} exec $HOME/bin/graff serve --host 0.0.0.0 --port {d} --token {s}", .{ key, g.token, g.login, cube_port, serve_token })
    else
        try std.fmt.allocPrint(arena, "CODEGRAFF_API_KEY={s} exec $HOME/bin/graff serve --host 0.0.0.0 --port {d} --token {s}", .{ key, cube_port, serve_token });
    const started = try cubeExec(io, gpa, arena, key, id, launch, 60, true);
    const exec_id = if (started == .object) (strFieldObj(started.object, "execId") orelse "") else "";

    const probe_cmd = try std.fmt.allocPrint(arena, "curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{d}/", .{cube_port});
    var up = false;
    var tries: usize = 0;
    while (tries < 20) : (tries += 1) {
        const p: ?Value = cubeExec(io, gpa, arena, key, id, probe_cmd, 15, false) catch null;
        if (p) |pv| if (pv == .object) {
            const code_s = std.mem.trim(u8, strFieldObj(pv.object, "result") orelse "", " \t\r\n'");
            if (code_s.len > 0 and !std.mem.eql(u8, code_s, "000")) {
                up = true;
                break;
            }
        };
        io.sleep(Io.Duration.fromSeconds(1), .awake) catch {};
    }
    if (!up) {
        const logcmd = try std.fmt.allocPrint(arena, "cat /tmp/cg-exec/{s}.out 2>/dev/null | tail -5", .{exec_id});
        const lg: ?Value = cubeExec(io, gpa, arena, key, id, logcmd, 15, false) catch null;
        const tail = if (lg) |l| (if (l == .object) (strFieldObj(l.object, "result") orelse "") else "") else "";
        std.process.fatal("cube: serve never came up; log tail: {s}", .{tail});
    }

    const pv_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/ports/{d}/preview", .{ id, cube_port });
    const pv = try gatewayJson(io, gpa, arena, .GET, pv_url, key, null);
    if (pv != .object) std.process.fatal("cube: unexpected preview response", .{});
    const purl_raw = strFieldObj(pv.object, "url") orelse std.process.fatal("cube: preview returned no url", .{});
    const purl = std.mem.trimEnd(u8, purl_raw, "/");
    const ptok = strFieldObj(pv.object, "token");

    const pipe = cubePipeProbe(io, gpa, arena, purl, serve_token, ptok);
    if (pipe == 0) {
        try out.print("  {s}!{s} preview minted but unreachable from here — check network\n", .{ style.yellow, style.reset });
    } else {
        try out.print("  pipe ok (HTTP {d} through the preview proxy)\n", .{pipe});
    }

    Io.Dir.cwd().createDirPath(io, ".graff") catch {};
    var st: std.json.ObjectMap = .empty;
    try st.put(arena, "sandbox_id", .{ .string = id });
    try st.put(arena, "preview_url", .{ .string = purl });
    if (ptok) |p| try st.put(arena, "preview_token", .{ .string = p });
    try st.put(arena, "serve_token", .{ .string = try arena.dupe(u8, serve_token) });
    try st.put(arena, "exec_id", .{ .string = exec_id });
    try st.put(arena, "port", .{ .integer = cube_port });
    if (gh) |g| try st.put(arena, "github_login", .{ .string = g.login });
    var aw: Io.Writer.Allocating = .init(arena);
    var sfy: std.json.Stringify = .{ .writer = &aw.writer };
    try sfy.write(Value{ .object = st });
    const f = try Io.Dir.cwd().createFile(io, cube_state_file, .{});
    defer f.close(io);
    var wbuf: [1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    try fw.interface.writeAll(aw.writer.buffered());
    try fw.interface.flush();

    try out.print("{s}✓{s} cube ready{s}\n", .{ style.green, style.reset, if (resume_id != null) " (woken, not rebuilt)" else "" });
    try cubePrintAttach(out, st);
    try out.print("  state → {s}\n  stop  → graff cube stop\n", .{cube_state_file});
    try out.flush();
}

pub fn cubeCommand(io: Io, gpa: Allocator, arena: Allocator, key: []const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const sub = if (args.len > 0) args[0] else "status";
    if (std.mem.eql(u8, sub, "new")) {
        var minutes: i64 = 30;
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--minutes") and i + 1 < args.len) {
                i += 1;
                minutes = std.fmt.parseInt(i64, args[i], 10) catch std.process.fatal("cube: --minutes needs a number", .{});
            } else std.process.fatal("usage: graff cube new [--minutes N]", .{});
        }
        try cubeNew(io, gpa, arena, key, out, minutes);
        return;
    }
    if (std.mem.eql(u8, sub, "stop")) {
        const st = cubeReadState(io, arena) orelse std.process.fatal("cube: nothing to stop — no {s}", .{cube_state_file});
        const id = strFieldObj(st, "sandbox_id") orelse std.process.fatal("cube: state file has no sandbox_id", .{});
        const url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/stop", .{id});
        const resp = try gatewayJson(io, gpa, arena, .POST, url, key, null);
        const state = if (resp == .object) (strFieldObj(resp.object, "state") orelse "stopped") else "stopped";
        const cost_micro = if (resp == .object) intFieldObj(resp.object, "costMicro", 0) else 0;
        Io.Dir.cwd().deleteFile(io, cube_state_file) catch {};
        try out.print("{s}✓{s} cube {s} → {s} (meter settled ${d:.4})\n", .{ style.green, style.reset, id, state, @as(f64, @floatFromInt(cost_micro)) / 1e6 });
        try out.flush();
        return;
    }
    if (!std.mem.eql(u8, sub, "status"))
        std.process.fatal("usage: graff cube [new [--minutes N]|status|stop]", .{});

    const st = cubeReadState(io, arena) orelse {
        try out.writeAll("no cube — `graff cube new` spins one up\n");
        try out.flush();
        return;
    };
    const id = strFieldObj(st, "sandbox_id") orelse std.process.fatal("cube: state file has no sandbox_id", .{});
    const info_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}", .{id});
    var state: []const u8 = "unknown";
    if (gatewayFetch(io, gpa, arena, .GET, info_url, key, null)) |r| {
        if (r.code >= 200 and r.code < 300) {
            if (std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always })) |info| {
                if (info == .object) state = strFieldObj(info.object, "state") orelse "unknown";
            } else |_| {}
        } else state = "gone";
    } else |_| {}
    const scolor = if (std.mem.eql(u8, state, "started")) style.green else style.dim;
    try out.print("cube {s}: {s}{s}{s}\n", .{ id, scolor, state, style.reset });
    const meter_url = try std.fmt.allocPrint(arena, codegraff_device_base ++ "/v1/sandboxes/{s}/meter", .{id});
    if (gatewayFetch(io, gpa, arena, .GET, meter_url, key, null)) |r| {
        if (r.code >= 200 and r.code < 300) {
            if (std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always })) |m| {
                if (m == .object) {
                    const up_s = intFieldObj(m.object, "current_uptime_seconds", 0);
                    const billed = @as(f64, @floatFromInt(intFieldObj(m.object, "billed_so_far_micro_usd", 0))) / 1e6;
                    const unbilled = @as(f64, @floatFromInt(intFieldObj(m.object, "unbilled_cost_micro_usd", 0))) / 1e6;
                    try out.print("  uptime {d}s · billed ${d:.4} · unbilled ${d:.4}\n", .{ up_s, billed, unbilled });
                }
            } else |_| {}
        }
    } else |_| {}
    if (std.mem.eql(u8, state, "started")) try cubePrintAttach(out, st);
    try out.flush();
}
