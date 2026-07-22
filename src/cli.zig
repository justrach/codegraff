//! `graff update [--force|--check]`: compare the installed harness_version
//! against the latest GitHub release tag (SemVer parse; refuse to downgrade a
//! dev/newer build) and delegate the download / codesign / atomic swap to
//! install.sh. Split out of main.zig (600-line goal). Back-imports main for
//! harness_version. main aliases updateCommand back.
//!
//! changelog_text/usage_text (the `--version`/`--help` text blocks) also live
//! here (600-line goal, #123) — pure string consts, aliased back in main.zig
//! since they're only ever printed from within main().

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_version = root.harness_version;

/// Shown under `graff --version` — a terse "what's new" for recent releases.
/// Keep it short and current; bump alongside the version each release.
pub const changelog_text =
    \\What's new
    \\──────────
    \\0.0.209
    \\  • Kimi Code now follows each live catalog model's native or Anthropic beta protocol, auth style, context, and thinking metadata
    \\  • Native Kimi tool schemas are normalized to Moonshot's stricter validator; OAuth requests carry the current Kimi Code identity headers
    \\  • `--model kimi` selects K3 today and automatically follows future pure Kimi generations
    \\
    \\0.0.206
    \\  • The CLI now uses Codegraff's accessible vermilion-coral accent for prompts, tools, Markdown structure, and active selections
    \\  • A quiet Ensō brush-circle is the stable thinking default; every existing animation remains selectable, including random
    \\  • Ultracode motion is now a slower rust/coral/gold ember sweep instead of a full-spectrum rainbow
    \\
    \\0.0.201
    \\  • A send-failed request no longer re-pools its dead connection, so one network blip can't storm every later compaction, title, and subagent call
    \\  • The "ultracode" codeword is matched only on what you actually typed (not on appended goal/todo notes), and /clear now clears the standing goal and ultracode mode
    \\  • `graff login codex` lands on a branded, dark-mode-aware confirmation page instead of a bare line of text
    \\
    \\0.0.200
    \\  • Codex WS delta bodies are never replayed over SSE — fixes "Unsupported parameter: previous_response_id" after a long idle
    \\  • The held codex WS now re-anchors preemptively after 4 min idle (GRAFF_CODEX_WS_IDLE_SECS to tune) instead of eating a dead-socket round trip
    \\  • A server-side previous_response_id rejection now self-heals with one full-input retry
    \\
    \\0.0.192
    \\  • The REPL prompt now shows color-coded reasoning and active mode badges
    \\  • PTY debugging can script commands, keys, assertions, and terminal dimensions
    \\  • Interactive prompt redraws and ANSI colors now have a real-PTY CI regression
    \\
;

pub const usage_text =
    \\graff — a minimal agentic coding harness in Zig (zero deps)
    \\
    \\usage:
    \\  graff [flags]                    start the REPL
    \\  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
    \\  graff login                      get a codegraff key (device-code OAuth)
    \\  graff login codex [--refresh]    ChatGPT/Codex OAuth login (PKCE)
    \\  graff login kimi                 Kimi Code OAuth login (device-code)
    \\  graff login xai                  Grok/SuperGrok OAuth login (device-code)
    \\  graff key set <provider> <key>   store a key (macOS Keychain, else 0600 file)
    \\  graff key list                   show which providers have keys
    \\  graff models [refresh]           list the live catalog; refresh Codex + models.dev metadata
    \\  graff mcp add <name> -- <cmd>     add an MCP server to .mcp.json
    \\  graff mcp                         list configured MCP servers
    \\  graff learn [help]                local mutate/evaluate/promote/rollback engine
    \\  graff worktree list              list the per-tab worktrees created by -w
    \\  graff worktree merge <name>      squash-land worktree-<name> onto the current branch + clean up
    \\  graff worktree remove <name>     discard worktree-<name> (drops its scratch work) + delete the branch
    \\  graff worktree prune             drop git registrations for worktrees whose dirs were deleted
    \\  graff sandboxes                  list your gateway sandboxes (what's burning credits)
    \\  graff sandboxes stop <id>        spin a sandbox down (stops it + settles the meter)
    \\  graff cube new                   spin up a cloud graff (sandbox + serve + preview URL)
    \\  graff cube [status|stop]         inspect the running cube or spin it down
    \\  graff --schema                   print the machine-readable interface (SDK codegen)
    \\  graff serve                      HTTP/NDJSON bridge over the --json protocol
    \\                                   (--host/--port/--token; sessions are --json children)
    \\  graff update [--force|--check]   update graff to the latest GitHub release
    \\  graff title <prompt>            print the AI tab-title for a prompt (test title styles)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --resume <name>  resume/autosave <name>.session.json
    \\  --new            start a fresh autosaved session (default)
    \\  --no-resume      ignore --resume and start fresh
    \\  --system-prompt <text>          replace the built-in system prompt
    \\  --append-system-prompt <text>   append extra text to the system prompt
    \\  --goal <text>                   seed a standing objective (tracked as a todo checklist) for every turn
    \\  --eval <cmd>                    scoring command for an eval-driven loop (the `eval` tool runs it)
    \\  --until <0-100>                 eval-loop target score; stop when reached (default 90)
    \\  --niche <name>                  fleet niche this eval optimizes (reviewer/researcher/implementer/skeptic or a custom agent); tags submitted scores so the DGM can promote a champion for that role
    \\  -w, --worktree <name>           isolate this session in a git worktree (.graff/worktrees/<name>) so parallel agents don't collide on files
    \\  --no-autocommit                 with -w, don't auto-commit each turn (default on; land work with `graff worktree merge`)
    \\  --yolo           skip all permission prompts for the session
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
    \\  --max-tool-calls N  reject root tool calls after N per turn (JSON-safe budget)
    \\  --max-model-calls N total provider calls allowed across this run (default 256; includes children/title/judges)
    \\  --dedupe-tool-calls reject duplicate root tool name+input calls per turn
    \\  --no-telemetry   disable anonymous usage telemetry for this run
    \\  --learning-privacy <mode>       learning egress ceiling: local|aggregate|templates|examples (default local)
    \\  -h, --help       this help
    \\  -V, --version    print version
    \\
    \\keys: <PROVIDER>_API_KEY env vars, `graff key set`, or `graff login`;
    \\a Codex CLI login is picked up automatically.
    \\inside the REPL: /help lists commands, a bare "/" opens the command menu,
    \\"@" opens a fuzzy file picker (drag-and-dropped files paste as their path),
    \\esc interrupts a streaming response, "always allow" persists to
    \\.harness/settings.json.
    \\telemetry: anonymous OTLP usage stats are sent only when
    \\OTEL_EXPORTER_OTLP_ENDPOINT (or GRAFF_OTEL_ENDPOINT) is set; opt out
    \\with --no-telemetry or GRAFF_NO_TELEMETRY=1. GRAFF_TELEMETRY_KEY sends
    \\an optional x-harness-key token to the configured collector.
    \\learning privacy: prompt-policy learning stays local by default; /privacy
    \\changes the session ceiling. Template text still needs exact approval.
    \\
;

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn eql(self: Version, other: Version) bool {
        return self.major == other.major and self.minor == other.minor and self.patch == other.patch;
    }

    fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

/// Parse a leading `MAJOR.MINOR.PATCH` from `s` (after any leading 'v' is
/// stripped by the caller). Returns null if the numeric triple isn't present.
fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    // Each component must be all digits up to the next '.' (or end). `patch`
    // may trail a pre-release suffix ("-3-gabc", "-dev"); take only the leading
    // digits so "0.0.14-3-gabc" parses as 0.0.14.
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch_digits = std.mem.indexOfAny(u8, patch_s, "-+") orelse patch_s.len;
    const patch = std.fmt.parseInt(u32, patch_s[0..patch_digits], 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// True when `s` is a bare release version with no `git describe` suffix — i.e.
/// exactly `MAJOR.MINOR.PATCH` (optionally 'v'-prefixed), no "-N-gHASH",
/// "-dirty", "-dev", or "+build". A dev/dirty/commit-ahead build is not a clean
/// release and shouldn't be silently "updated" (downgraded) to an older tag.
fn isCleanReleaseVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var dots: u8 = 0;
    for (s) |c| {
        switch (c) {
            '0'...'9' => {},
            '.' => dots += 1,
            else => return false, // any '-','+','g',... means it's not a bare tag
        }
    }
    return dots == 2;
}

/// `graff update [--force|--check]` — bring the installed binary up to the
/// latest GitHub release. Checks the release tag first and skips when already
/// current (unless --force); --check only reports, never installs. The actual
/// download, codesign, and atomic binary swap are delegated to install.sh
/// (curl | sh) — that platform-specific logic already lives there, so we don't
/// reimplement it. HARNESS_NO_GRAFF=1 keeps the installer from also pulling in
/// the companion suite: an update touches only graff itself.
pub fn updateCommand(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    force: bool,
    check_only: bool,
) !void {
    const repo_api = "https://api.github.com/repos/justrach/codegraff/releases/latest";
    const install_url = environ.get("GRAFF_INSTALL_URL") orelse environ.get("HARNESS_INSTALL_URL") orelse
        "https://github.com/justrach/codegraff/releases/latest/download/install.sh";

    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    // current version, leading 'v' stripped so the comparison ignores tag style.
    const cur_raw = if (std.mem.startsWith(u8, harness_version, "v")) harness_version[1..] else harness_version;

    // A release tag is a bare "MAJOR.MINOR.PATCH". A dev/dirty/commit-ahead
    // build (from `git describe --tags --always --dirty`) carries a suffix
    // ("-3-gabc", "-dirty", "-dev+hash", "0.1.0-dev") and is NOT a clean
    // release version. Comparing such a string against a release tag with exact
    // equality always mismatched, so `graff update` would "update" (downgrade)
    // a newer dev build to an older release, and `--check` always reported an
    // update available. Parse the leading numeric triple instead, and refuse to
    // act on a non-release local build rather than silently downgrading it.
    const cur = parseVersion(cur_raw);
    const cur_is_release = cur != null and isCleanReleaseVersion(cur_raw);

    // Query the latest release tag. GitHub's API requires a User-Agent; the
    // Accept header pins the v3 JSON response. Any failure → null, handled below.
    const latest_tag: ?[]const u8 = blk: {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        var aw: Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/vnd.github+json" }};
        const res = client.fetch(.{
            .location = .{ .url = repo_api },
            .method = .GET,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
            .extra_headers = &extra,
        }) catch break :blk null;
        if (@intFromEnum(res.status) != 200) break :blk null;
        // Cap the response before parsing: the endpoint is pinned to GitHub's
        // API (normally a small JSON blob), but a captive-portal redirect or a
        // TLS MITM could stream an unbounded body and exhaust memory. 64 KiB is
        // far above any legitimate /releases/latest payload.
        if (aw.writer.buffered().len > 64 * 1024) break :blk null;
        const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch break :blk null;
        if (v != .object) break :blk null;
        const t = v.object.get("tag_name") orelse break :blk null;
        break :blk if (t == .string) t.string else null;
    };

    // `latest` is a release tag from GitHub, so it parses to a clean triple.
    const latest_raw = if (latest_tag) |tag| (if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag) else null;
    const latest = if (latest_raw) |r| parseVersion(r) else null;

    if (latest_tag != null and latest == null) {
        // The release endpoint returned a tag we couldn't parse — treat like a
        // failed check rather than guessing.
        if (check_only) std.process.fatal("update check failed — unparseable release tag '{s}'", .{latest_tag.?});
        try out.print("could not parse latest release tag '{s}'; running installer anyway…\n", .{latest_tag.?});
    } else if (latest != null) {
        const up_to_date = cur != null and cur.?.eql(latest.?);
        const cur_newer = cur != null and cur.?.order(latest.?) == .gt;

        if (check_only) {
            if (cur_is_release and up_to_date) {
                try out.print("graff is up to date (v{s})\n", .{cur_raw});
            } else if (cur_is_release and cur_newer) {
                try out.print("graff v{s} is newer than latest release v{s} — not downgrading\n", .{ cur_raw, latest_raw.? });
            } else if (cur_is_release) {
                // Release build older than latest.
                try out.print("update available: v{s} → v{s}  (run `graff update`)\n", .{ cur_raw, latest_raw.? });
            } else if (cur_newer) {
                // Dev/dirty build whose base version is ahead of the latest release.
                try out.print("local build v{s} is newer than latest release v{s} — not a release build; no update needed\n", .{ cur_raw, latest_raw.? });
            } else {
                // Dev/dirty build at or below the release version: installing the
                // release is reasonable if the user wants it.
                try out.print("update available: v{s} → v{s}  (local build {s} is not a release; run `graff update` to install the release)\n", .{ cur_raw, latest_raw.?, cur_raw });
            }
            try out.flush();
            return;
        }

        // Install path.
        if (up_to_date and cur_is_release and !force) {
            try out.print("graff is already up to date (v{s})\n", .{cur_raw});
            try out.flush();
            return;
        }
        // Refuse to downgrade a build whose version is strictly ahead of the
        // latest release without --force (applies to both release and dev builds
        // — installing would replace a newer version with an older one).
        if (cur_newer and !force) {
            try out.print("graff v{s} is newer than latest release v{s} — not downgrading (use --force to override)\n", .{ cur_raw, latest_raw.? });
            try out.flush();
            return;
        }
        try out.print("updating graff v{s} → v{s}…\n", .{ cur_raw, latest_raw.? });
    } else {
        // Version check failed (offline / rate-limited / bad response). For
        // --check that's a hard error; otherwise fall through to the installer,
        // which fetches the latest release on its own.
        if (check_only) std.process.fatal("update check failed — could not reach GitHub", .{});
        try out.writeAll("could not determine latest version; running installer anyway…\n");
    }
    try out.flush();

    // Delegate download/codesign/atomic swap to install.sh. Inherit our stdio
    // so its progress (and any sudo prompt) reaches the terminal directly.
    // "set -o pipefail" is required: without it, a failed "curl" is masked
    // by the right-hand "sh" exiting 0 on EOF, and the pipeline reports
    // success while installing nothing — silently.
    //
    // `install_url` is user-controllable via GRAFF_INSTALL_URL / HARNESS_INSTALL_URL,
    // so it MUST NOT be interpolated into the sh -c string (shell injection).
    // Pass it as positional $1 instead — the shell never re-parses it and curl
    // receives it verbatim.
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "set -o pipefail; curl -fsSL \"$1\" | HARNESS_NO_GRAFF=1 sh", "sh", install_url },
    }) catch |err|
        std.process.fatal("update: could not launch installer: {t}", .{err});
    const term = child.wait(io) catch std.process.fatal("update: installer did not exit cleanly", .{});
    if (term != .exited or term.exited != 0)
        std.process.fatal("update: installer failed — try again or download manually from https://github.com/justrach/codegraff/releases/latest", .{});
    try out.writeAll("✓ update installed — restart every running graff session to load the new binary\n");
    try out.flush();
}
