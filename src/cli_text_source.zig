//! Build-time source for --help and --version.

pub const changelog_text = @import("cli_changelog_source.zig").changelog_text;

/// Release builds leave `graff learn` out (build option `learn`).
const learn_usage = if (@import("build_options").learn)
    "  graff learn [help]                local mutate/evaluate/promote/rollback engine\n"
else
    "";

pub const usage_text =
    \\graff — a minimal agentic coding harness in Zig (zero deps)
    \\
    \\usage:
    \\  graff [flags]                    start the line REPL
    \\  graff repl                       line REPL (scripted when stdin is piped)
    \\  graff tui [--yes] [args...]         launch graff-tui; installs it from the Harness release on first use
    \\  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
    \\  graff login                      get a codegraff key (device-code OAuth)
    \\  graff login chatgpt              ChatGPT sign-in (also: codex, openai)
    \\  graff login anthropic            Claude subscription browser sign-in (also: ant)
    \\  graff login console              metered Console sign-in through the `ant` CLI
    \\  graff login claude-agent         Claude through your own Claude Code login (`claude`)
    \\  graff login kimi                 Kimi Code OAuth login (kimi.ai; kimi.com for China)
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
    \\  graff plugins [list|load|enable|disable|register|remove|reload]  manage in-place plugin metadata
    \\  graff lsp diagnostics PATH          query a configured local language server
    \\  graff extensions list --json       list trusted native extension panels
    \\  graff extensions invoke ID ACTION  invoke a declared native panel action
    \\  graff computer [status|install|stop|off|allow|grant|open]  nanocua's switches (macOS)
    \\
++ learn_usage ++
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
    \\  graff peer list|send|inbox       talk with other agents on this device (Claude Code, Codex, graff)
    \\  graff bot create|run|routine     experimental, off until `graff bot enable`: standing roles with their own memory, log and routines
    \\  graff bot tick                   run every routine that is due, once (for cron, launchd or a client's timer)
    \\  graff bot --user ...             your own bots in ~/.graff/bots, for any project; one can be --primary
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
    \\  graff update [--force|--check]   update graff to the latest stable release
    \\  graff update --beta [--check]   install the newest beta for the next launch
    \\  graff title <prompt>            print the AI tab-title for a prompt (test title styles)
    \\
    \\flags:
    \\  --model <name>   start on this model (same fuzzy resolution as /model)
    \\  --subagent-model <name>         pin children/workflows/judges on the root provider
    \\  --subagent-provider <id>        route pinned workers through this provider
    \\  --allow-cross-provider-subagents confirm prompts/code may go to the worker provider
    \\  --no-subagent-tier              opt out of the default worker tier ladder (inherit the root model)
    \\  --resume <name>  resume/autosave <name>.session.json
    \\  --branch <name>  clone --resume (or --continue) into an independent autosave target
    \\  -c, --continue   resume the most recently updated session in this workspace
    \\  --session-id <id>                assign this session's id (resumes it if <id> exists here); letters, digits, . _ -
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
    \\  --orchestrator[=off|auto|on]  same-chat read-only planning -> cheaper executor baton handoff (GRAFF_ORCHESTRATOR)
    \\  --no-orchestrator             disable orchestrator baton handoff (same as --orchestrator=off)
    \\  --unharnessed[=on|off]        expose ONLY a persistent stateful python REPL tool (GRAFF_UNHARNESSED)
    \\  --no-unharnessed              disable unharnessed mode (same as --unharnessed=off)
    \\  --lean           slim tool surface (8 core tools) + MCP schemas folded behind load_tool_schemas — the DEFAULT for -p one-shots (GRAFF_LEAN=1). `.mcp.json` still connects.
    \\  --no-lean        opt a one-shot out of the implied --lean: full tool surface + eager MCP schemas, the pre-default -p behavior
    \\  --no-local-tools embedder mode: hard-disable the built-in bash/bash_output/bash_kill/read_file/edit_file/write_file/codedb tools for the whole process (subagents included), so graff can run outside the sandbox and get its coding tools from an MCP server instead; webfetch, orchestration and MCP tools still work (GRAFF_NO_LOCAL_TOOLS=1)
    \\  -p, --print      one-shot print mode (answer on stdout, progress on stderr)
    \\  --output-format text|stream-json  one-shot output; stream-json emits run_started and result
    \\  --timing         show per-tool wall-clock on result lines
    \\  --cost           show running session spend in the prompt
    \\  --json           structured stdio protocol (JSON in, JSONL events out)
    \\  --max-run-tool-calls N  aggregate root/descendant tool ceiling for this invocation
    \\  --max-tool-calls N  reject root tool calls after N per turn (JSON-safe budget)
    \\  --compact-at PCT    start automatic compaction at PCT% of the context window (10-95, default 80)
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
