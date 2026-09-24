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
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_version = root.harness_version;
const version_status = @import("version_status.zig");

/// Shown under `graff --version` — a terse "what's new" for recent releases.
/// Keep it short and current; bump alongside the version each release.
pub const changelog_text =
    \\What's new
    \\──────────
    \\0.0.302.5
    \\  • route checks preserve explicitly qualified selections
    \\
    \\Full release history: https://github.com/justrach/codegraff/releases
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
    \\  graff login zai                  Z.AI Coding Plan OAuth login
    \\  graff key set <provider> <key>   store a key (Keychain; POSIX 0600 file; Windows home ACL)
    \\  graff key list                   show which providers have keys
    \\  graff refresh                    pull live catalogs (same as `graff models refresh`)
    \\  graff models [refresh]           list the live catalog; refresh Codex + provider lists + models.dev
    \\  graff route <model>…             dry-run which provider/billing a model lands on (no API call)
    \\  graff mcp add <name> -- <cmd>     add a stdio MCP server to .mcp.json
    \\  graff mcp add <name> --url <url>  add a Streamable HTTP MCP server
    \\  graff mcp login <name>            OAuth login for a remote MCP server
    \\  graff mcp                         list configured MCP servers
    \\  graff mcp install                configure local HTTP service and MCP clients
    \\  graff mcp serve [--http] [--port N] expose run_task to MCP clients
    \\  graff plugins [load <name>]       list Claude/Cursor/Grok/Codex plugin trees (in place)
    \\  graff learn [help]                local mutate/evaluate/promote/rollback engine
    \\  graff worktree list              list -w tabs and experiment-pool trees (tagged)
    \\  graff worktree create <name> [base]  mint a task workspace from the remote base (origin/main after fetch; optional base)
    \\  graff worktree run <name>        run the workspace run script from that checkout
    \\  graff worktree archive <name>    remove a clean duplicate checkout; dirty or unique-commit trees stay
    \\  graff worktree merge <name>      squash-land worktree-<name> onto the current branch + clean up
    \\  graff worktree land <name>       same as merge
    \\  graff worktree update <name>     merge the remote base into that workspace
    \\  graff worktree gc                drop dead session trees and clean merged-PR trees
    \\  graff worktree remove <name>     discard worktree-<name> (drops its scratch work) + delete the branch
    \\  graff worktree prune             drop git registrations for worktrees whose dirs were deleted
    \\  graff servers                    background servers graff started (this session's or older): pid, port, age
    \\  graff servers stop <pid>         end one (its whole process tree); `prune` drops records of dead ones
    \\  graff sandboxes                  list your gateway sandboxes (what's burning credits)
    \\  graff sandboxes stop <id>        spin a sandbox down (stops it + settles the meter)
    \\  graff cube new                   spin up a cloud graff (sandbox + serve + preview URL)
    \\  graff cube [status|stop]         inspect the running cube or spin it down
    \\  graff --schema                   print the machine-readable interface (SDK codegen)
    \\  graff serve                      HTTP/NDJSON bridge over the --json protocol
    \\                                   (--host/--port/--token; sessions are --json children)
    \\  graff remote-control [--name n]  serve with no listener: dial out to your Codegraff account so
    \\                                   `graff remote` anywhere can drive sessions on this machine
    \\  graff remote [new|send|tail|…]   list and drive the sessions of machines running remote-control
    \\  graff acp                        Agent Client Protocol agent on stdio (Zed and other ACP editors)
    \\  graff update [--force|--check]   update graff to the latest GitHub release
    \\  graff title <prompt>            print the AI tab-title for a prompt (test title styles)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --subagent-model <name>         pin children/workflows/judges on the root provider
    \\  --subagent-provider <id>        route pinned workers through this provider
    \\  --allow-cross-provider-subagents confirm prompts/code may go to the worker provider
    \\  --no-subagent-tier              opt out of the default worker tier ladder (inherit the root model)
    \\  --resume <name>  resume/autosave <name>.session.json
    \\  --branch <name>  clone --resume into an independent autosave target
    \\  --new            start a fresh autosaved session (default)
    \\  --no-resume      ignore --resume and start fresh
    \\  --system-prompt <text>          replace the built-in system prompt
    \\  --append-system-prompt <text>   append extra text to the system prompt
    \\  --goal <text>                   seed a standing objective (tracked as a todo checklist) for every turn; persists across completions
    \\  --eval <cmd>                    scoring command for an eval-driven loop (the `eval` tool runs it)
    \\  --until <0-100>                 eval-loop target score; stop when reached (default 90)
    \\  --niche <name>                  fleet niche this eval optimizes (reviewer/researcher/implementer/skeptic or a custom agent); tags submitted scores so the DGM can promote a champion for that role
    \\  -w, --worktree <name>           isolate this session in a git worktree (.graff/worktrees/<name>) so parallel agents don't collide on files. A second session in a claimed checkout auto-isolates.
    \\  --experiment N                  pre-mint N child worktrees (1-16) under .graff/worktrees/exp-<id>/; next spawns claim a seat
    \\  --add-dir <path>                extra file-tool root (repeatable, max 16). Not a cwd switch; no skills/sessions from it
    \\  --context-limit name=N          cap a named prefix: skill_catalog_bytes|mcp_schema_bytes|agents_md_bytes
    \\  --no-autocommit                 with -w, don't auto-commit each turn (default on; land work with `graff worktree merge`)
    \\  --yolo           skip all permission prompts for the session
    \\  --rlm            advertise the rlm REPL (default; persistent binds, subagent(), llm_query, mid-stream spec-ptc; GRAFF_RLM=1)
    \\  --old, --no-rlm  restore the pre-rlm structured-only catalog (GRAFF_OLD=1 or GRAFF_RLM=0)
    \\  --lean           slim tool surface (8 core tools) + MCP schemas folded behind load_tool_schemas — the DEFAULT for -p one-shots (GRAFF_LEAN=1). `.mcp.json` still connects.
    \\  --no-lean        opt a one-shot out of the implied --lean: full tool surface + eager MCP schemas, the pre-default -p behavior
    \\  --no-local-tools embedder mode: hard-disable the built-in bash/bash_output/bash_kill/read_file/edit_file/write_file/codedb tools for the whole process (subagents included), so graff can run outside the sandbox and get its coding tools from an MCP server instead; webfetch, orchestration and MCP tools still work (GRAFF_NO_LOCAL_TOOLS=1)
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
    \\  --max-run-tool-calls N  aggregate root/descendant tool ceiling for this invocation
    \\  --max-tool-calls N  reject root tool calls after N per turn (JSON-safe budget)
    \\  --max-model-calls N total provider calls allowed across this run (default 0 = unlimited; includes children/title/judges)
    \\  --dedupe-tool-calls reject duplicate root tool name+input calls per turn
    \\  --no-telemetry   disable anonymous usage telemetry for this run
    \\  --learning-privacy <mode>       learning egress ceiling: local|aggregate|templates|examples (default aggregate)
    \\  -h, --help       this help
    \\  -V, --version    print version
    \\
    \\keys: <PROVIDER>_API_KEY env vars, `graff key set`, or `graff login`;
    \\a Codex CLI login is picked up automatically.
    \\inside the REPL: /help lists commands, a bare "/" opens the command menu,
    \\"@" opens a fuzzy file picker (a drag-and-dropped image attaches as a
    \\native vision block on vision models; other files paste as their path),
    \\esc interrupts a streaming response, "always allow" persists to
    \\.harness/settings.json.
    \\telemetry: /debug is a local content-free HUD (session/turn/tool
    \\decisions). Anonymous OTLP usage stats leave the process only when
    \\OTEL_EXPORTER_OTLP_ENDPOINT (or GRAFF_OTEL_ENDPOINT) is set; opt out
    \\with --no-telemetry or GRAFF_NO_TELEMETRY=1. GRAFF_TELEMETRY_KEY sends
    \\an optional x-harness-key token to the configured collector.
    \\learning privacy: local learning trials publish prompt-free aggregate grades
    \\by default, announced once per machine; /privacy local (or
    \\GRAFF_LEARNING_PRIVACY=local, GRAFF_FLEET=off, --no-telemetry) sends nothing.
    \\/privacy changes the session ceiling; template text still needs exact approval.
    \\
;

/// Dim REPL/TUI line when GitHub has a newer release. Null if current, newer,
/// offline, or GRAFF_NO_UPDATE_CHECK is set.
pub fn updateAvailableLine(io: Io, gpa: Allocator, arena: Allocator, skip: bool) ?[]const u8 {
    if (skip) return null;
    const check = version_status.checkLatest(io, gpa, arena, harness_version);
    if (check.order != .lt) return null;
    return std.fmt.allocPrint(arena, "graff v{s} is available (you have {s}) — graff update", .{ check.latest.?, check.running }) catch null;
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
    const install_url = environ.get("GRAFF_INSTALL_URL") orelse environ.get("HARNESS_INSTALL_URL") orelse
        "https://github.com/justrach/codegraff/releases/latest/download/install.sh";

    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const check = version_status.checkLatest(io, gpa, arena, harness_version);
    const cur_raw = check.running;
    const latest_tag = check.latest_tag;
    const latest_raw = check.latest;

    if (check.failure == .latest_tag) {
        // The release endpoint returned a tag we couldn't parse — treat like a
        // failed check rather than guessing.
        if (check_only) std.process.fatal("update check failed — unparseable release tag '{s}'", .{latest_tag.?});
        try out.print("could not parse latest release tag '{s}'; running installer anyway…\n", .{latest_tag.?});
    } else if (latest_raw != null) {
        const up_to_date = check.order == .eq;
        const cur_newer = check.order == .gt;
        const cur_is_release = check.clean_release;

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
