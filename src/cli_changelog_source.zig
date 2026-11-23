//! Build-time CLI changelog. Keep all release notes intact.

/// Shown under `graff --version` — a terse "what's new" for recent releases.
/// Keep it short and current; bump alongside the version each release.
pub const changelog_text =
    \\What's new
    \\──────────
    \\0.302.74.80
    \\  • Accept Windows extended-length (`\\?\`) workspace paths on ACP `session/load` (#1922).
    \\
    \\0.302.74.79
    \\  • Report unannotated MCP tools as not declared read-only in plan mode / RLM instead of edits (#1919).
    \\
    \\0.302.74.78
    \\  • Let read-only `run_task` prompts say `No edits.` while still guarding actual edits (#1914).
    \\
    \\0.302.74.77
    \\  • Prefer `rlm` for independent reads, JSON row counts, and field extraction (#1915).
    \\
    \\0.302.74.76
    \\  • Raise `gpt-6.2-astra` subscription context window to 500k on `codex`/`chatgpt-new` (ADR 0292 addendum).
    \\  • Ignore empty optional args and normalize `mcp__<server>` prefixes in MCP schema loading; add `CLA.md` PR check.
    \\
    \\0.302.74.75
    \\  • Add built-in `nanoattention/flint` local provider (#1905, ADR 0349) and persistent `python_repl` + `--unharnessed` single-tool mode (#1904, ADR 0348).
    \\  • Add `gpt-6.2-sol` / `gpt-6.2-astra`, `client_version=0.170.0`, 0ms-boot 5-min background catalog refresh + `/refresh` (ADR 0350), and Codex/ChatGPT `ultrafast` service tier.
    \\  • Only latch ACP `saw_text` when visible text survives citation stripping (#1912).
    \\
    \\0.302.74.74
    \\  • Fix HTTP/2 error-body capture across allocators (#1903), give `webfetch` 64 KiB header/redirect buffers (#1911), and preserve `nanocua` AXError/ScreenCaptureKit failure diagnostics (#1910).
    \\  • Add `run_task` boundary metadata, mismatched safe/cwd edit preflight refusal, and exit-only verification caveats while keeping `--safe` intact (#1909).
    \\  • Quote Windows `cmd.exe` commands via temp `.cmd` scripts (opt-in Git Bash via `GRAFF_WINDOWS_SHELL=bash`), add Windows UTF-8/non-interactive env defaults, read-only skill sibling reads, `read_file` `contains`+range support, and empty/null optional tool-arg tolerance.
    \\
    \\0.302.74.73
    \\  • Keep Orchestrator phase directives turn-scoped and allow quoted `rg` alternations, read-only `gh`, stdout `pdftotext`, and `readOnlyHint` MCP tools in plan mode (#1908).
    \\  • Skip Auto Orchestrator planning on informational `?` questions or compacted histories, and settle expanded Phase 2 compaction inside `compactAt()` (#1906).
    \\  • Strip Codex `tool_search_*` items on non-Codex Responses failover with local unfolding, and avoid auth-refresh loops on `subscription_sharing_unsupported_capability` (#1907).
    \\
    \\0.302.74.71
    \\  • Add Orchestrator Mode (`off | auto | on`) same-chat read-only planning and KV-identical executor handoffs with short follow-up and wake bypasses (ADR 0347).
    \\
    \\0.302.74.69
    \\  • Track live rate-limit headers, WebSocket `codex.rate_limits`, and `claude-agent` events, and bypass exhausted `claude-fable-5-2` pools onto `claude-opus-5-5` (ADR 0346).
    \\  • Surface signed-in account identities, plan credits, and remaining usage windows across `/usage`, `/cost`, ACP `graff/accounts`, and `_codegraff/usage.planWindows`.
    \\  • Advertise `_meta["codegraff/accounts"]` and all 7 terminal `authMethods` in ACP `initialize`.
    \\
    \\0.302.74.68
    \\  • Add dual-frontier worker tier selection (`hard_frontier` at `xhigh`/`max`), single-model ladder bounds, and live-catalog rung fallback (ADR 0345).
    \\  • Surface separate plan quota pools in `/models` (`plan*`) and ACP `graff/models` (`separateQuota`), with intra-plan frontier stepdown on usage limits.
    \\  • Restrict cross-provider flat-rate borrowing to `.plan` subscription logins and keep equal-scored rungs on the active plan.
    \\  • Enable the workspace-owning ACP client profile for `zeron` in `graff acp` and read `~/.simple-harness-keys.json` before macOS Keychain lookup.
    \\
    \\0.302.74.67
    \\  • Add opt-in runtime extensions (`graff extensions`, `plugins enable|disable`) and worker-inherited `policies` across REPL and ACP (ADR 0343).
    \\  • Add opt-in post-write `formatters` with verified-byte restore and multicall symlink preservation.
    \\  • Add read-only `lsp` queries and `graff lsp` CLI (`status`, `setup`, diagnostics, hover, definition, references, symbols) with folded root schemas, `~/.graff/lsp/settings.json` defaults, and optional POSIX warm reuse (ADR 0344).
    \\  • Accept `provider/model` qualifiers on `--subagent-model` across REPL and ACP.
    \\
    \\0.302.74.66
    \\  • Repair paused request history and avoid invalid worker retries (#1895).
    \\  • Retain longer prompt-cache TTL across returning interactive turns (#1898).
    \\  • Reconcile application targets and strengthen background-safe GUI verification guidance (#1899, #832).
    \\  • Add schema-ownership coverage and fix Windows test linking (#1892, #1900).
    \\
    \\0.302.74.65
    \\  • Improve startup responsiveness across the REPL, one-shot, and ACP paths.
    \\  • Avoid blocking startup on optional companion handshakes and model-catalog refreshes.
    \\  • Explain output-length continuation exhaustion in ACP while preserving partial work (#1893).
    \\
    \\0.302.74.64
    \\  • mcp: tool schemas are deep-cloned before normalization — mutating the Value copy through shared ArrayHashMap storage corrupted the parsed tools tree, so debug builds segfaulted in mcp_cache.store right after a successful connect (#1892)
    \\
    \\0.302.74.63
    \\  • `read_file` honors `offset` and `limit` line-window aliases when `start_line`/`end_line` are omitted (#1885)
    \\  • native file tools normalize `<agent_cwd>/…` absolute paths inside the workspace instead of rejecting them (#1886)
    \\  • `tool_balance` treats read-only `shell` inspection commands/pipelines as `.read_explore` without resetting read streaks (#1887)
    \\  • standalone `shell` `sleep N` polls run inline alongside background jobs and no longer hold `run_idle` open (#1888)
    \\  • headless `graff -p` wires `SIGINT` to `esc_cancel` and flushes the final `result` record (#1889)
    \\  • `write_file` and `edit_file` append inline JSON, Zig/ZON, Python, and Go syntax diagnostics (#1890)
    \\
    \\0.302.74.62
    \\  • the primary bot is your main bot (ADR 0335): one thread for every project; in a client such as Harness it starts each piece of work as its own chat where it belongs and reports when the client says it stopped; it asks only when the project is unclear
    \\  • from a terminal the main bot names the project and gives the command; single-job bots stay as helpers it hands their own jobs to; Bots are still off until `graff bot enable`
    \\
    \\0.302.74.61
    \\  • Bots (experimental, off until `graff bot enable`): standing roles with one job and their own memory, work log and routines in `.graff/bots/<name>/`; `graff bot run`, `routine add`, `tick` for cron or a client's timer (ADR 0333)
    \\  • `graff bot --user`: your own bots in `~/.graff/bots` for any project, one `--primary`; a late check records what it missed instead of running it late (`--stale-after`, `graff bot missed`); `graff bot state --json` for clients (ADR 0334)
    \\
    \\0.302.74.60
    \\  • runaway raw reasoning streams stop at a byte bound, run loop detection (`ReplyRunaway` -> `ModelLoop`), and skip the 270s empty-reply backoff (#1878)
    \\  • `delta.reasoning` normalizes into `reasoning_content` on replay and `ReplySize` (#1881)
    \\  • `#390` final budget-landing calls keep `tools` with `tool_choice: "none"`, settle reasoning-only `length` stops cleanly, and exit `0` when tool work completed (#1882)
    \\  • `edit_file` resolves multi-line `old_string` blocks with stripped line-1 indentation and restores the matched prefix (#1880)
    \\  • unattended `-p` action turns nudge long read-only streaks and bounce once on zero-mutation unfinished prose (#1879)
    \\  • explicit truncation markers on capped instruction/skill/MCP sections (#1871), `CLAUDE_CODE_USER_EMAIL` stripped in `claude-agent` (#1870), and worktree-scoped `codedb` guards + exit-code checks (#54)
    \\
    \\0.302.74.59
    \\  • Claude Fable 5.2 in the baked catalog: `--model claude-fable-5-2` resolves by its bare name and is priced
    \\  • image reads in one tool batch all reach the model, in call order (#1866): a bounded queue (16 images, 24 MB) replaces the single slot, with a tool error past the limit
    \\  • uploads a client leaves as an `Attached images` trailer are staged as native images instead of paths the file tools refuse, also when sent mid-turn (#1865)
    \\  • `graff refresh` / `graff models` / `/models` say when a provider rejects the live model-list request instead of silently showing the cached list
    \\  • Lean 4 ImageDelivery kernel (3,870 verified cells): every staged image is delivered once or refused, in call order
    \\
    \\0.302.74.58
    \\  • prompt-cache stability (#1320): jev_auto off by default (opt-in via /effort auto or GRAFF_JEV_AUTO=1), BustCause.effort HUD tracking, deterministic per-turn prompt_cache_key fallback, and in-session HTTP MCP schema retention
    \\  • ACP low-latency path + Lean 4 AcpLatency kernel (3,768 verified cells): 0-subprocess in-process .git worktree resolution, single-parse ACP inbox routing, batch-flushed LineWriter/EventSink with reusable scratch arena, and single-pass startup MCP config load
    \\
    \\0.302.74.57
    \\  • adaptive codedb workspace threshold (<8 code files in-process list_dir+read_file; >=8 code files codedb) + ~/.codedb/projects CoW seeding
    \\  • pre-tool transcript checkpointing (beforeToolBatch), crash-tail suffix replay, and effect-aware TOOL_INTERRUPTED_READONLY recovery
    \\  • deferred, single-pass streaming, cached (.graff/folded_priors.json), and ring-capped trajectory archive folding (#1864)
    \\  • Lean 4 resource/durability kernel (3,742 verified cells) + scoped arena and O(1) incremental hashing optimizations
    \\
    \\0.302.74.56
    \\  • unified subagent steering (@agent-N, @sa-..., /workers send, ACP graff/agents action: "steer") for foreground and background workers
    \\  • named background subagents/tasks in REPL standing bar and ACP session_info_update (_meta["graff/waiting"])
    \\  • cross-turn ACP tool_call_update progress streaming for detached subagents and immediate user follow-up wakeup in agent_output
    \\  • monotonic rewind-proof attempt ledger across /undo and /rewind preserved in compact_handoff_note.durableState
    \\  • wall-clock grid-aligned recurring schedules (nextGridSlot) with @every <delay> and --missed=once|skip policies
    \\  • APFS clonefile / Linux reflink Copy-on-Write cache seeding in subagent worktrees and adaptive sub-100ms foreground bash polling
    \\  • corrupt-safe playbook JSONL self-healing + storage_warning diagnostics, markdown agent line:col validation, and OAuth child-env scrubbing
    \\
    \\0.302.74.55
    \\  • scoped temporary arena parsing in mcp_cache.lookupWith/store/forget and single-server tool entry cloning
    \\  • per-request scratch allocation in agent_ws.postResponsesWs and scoped arena cleanup in session_workspaces.remember
    \\  • automatic same-plan subscription credential failover in providers.runTurnWithFallback
    \\
    \\0.302.74.54
    \\  • Phase-1 deterministic pre-compaction tool-result pruning (compact_prune), crash-tail TOOL_OUTCOME_UNKNOWN vs TOOL_NOT_STARTED repair, and key-sorted repeat hashing
    \\  • content-addressed dirty workspace snapshots (workspace_tree_snap) for edit_contract and hook/fsmonitor/LFS-safe subagent worktrees
    \\  • Linux bwrap --unshare-pid isolation, Landlock ABI probing, and read-only sandbox denial boundary tagging
    \\
    \\0.302.74.53
    \\  • workspace-invariant skill catalog prefix ordering and deepseekChat repo_context split for cross-directory prompt caching
    \\  • Kimi global (kimi.ai) vs Mainland China (kimi.com) OAuth region resolution and k3.1-pro catalog + plan routing across CLI and ACP
    \\
    \\0.302.74.52
    \\  • read-only trajectory inspection and verified user-facing chat title + chat ID reporting
    \\  • background workers preserve independent tool-result sequence counters; synthetic compaction skips mcp_preload scans
    \\  • workspace-invariant skill catalog prefix ordering, deepseekChat repo_context split, and Kimi global (kimi.ai) + k3.1-pro catalog routing
    \\
    \\0.302.74.51
    \\  • graff sessions reads 64 KiB header prefixes in a reusable scratch arena; session load/resume frees parse trees after load
    \\  • single-copy message arena reclaim, scoped trajectory archive folds, and faster remembered-model startup
    \\  • -Dminimal and per-subsystem build flags (-Dlearn, -Dserve, -Dacp, -Dextras), codedb symbol ranking, and --eval contrastive reflection
    \\  • zero-binary ServerlessHarness SDK runtime with InMemoryWorkspace, pluggable tools, lifecycle hooks, steer/followUp, and state snapshots
    \\
    \\0.302.74.5
    \\  • Claude Agent ignores unprefixed tool calls rejected by Claude Code and keeps earlier images across checkpoints
    \\  • read_tool_result keeps originating workspace handles across workspace switches
    \\  • background shared_cwd workers stay pinned to their spawn workspace when the root session switches trees
    \\
    \\0.302.74.4
    \\  • WebSocket Responses turns keep server token counts without re-compacting on ciphertext size
    \\  • compaction and session switches reclaim dropped history memory; ACP startup and session/load are faster
    \\  • --session-id and -c/--continue launch flags, versioned session files, and upright EXIF photo uploads
    \\
    \\0.302.74.3
    \\  • Responses compaction uses server token counts instead of re-compacting on ciphertext size
    \\  • cross-format model switches expand compaction checkpoints first and drop tool-only preambles
    \\
    \\0.302.74.2
    \\  • Windows installs can recover through GitHub's asset API without skipping checksum verification
    \\  • nanocua keeps text and refs by default; coordinates are available with include_frames
    \\  • frameless reads skip unused geometry queries; controls-only filtering remains opt-in
    \\
    \\0.302.74.1
    \\  • a provider or model switch expands opaque compaction state from its checkpoint instead of replaying it
    \\
    \\0.302.74
    \\  • rejected compaction state restores exact input when a private checkpoint is available
    \\  • short TLS-construction outages get a longer bounded recovery window
    \\
    \\0.302.71
    \\  • computer use on macOS: graff ships nanocua, an app that lets agents work in other apps
    \\  • graff computer and /computer: status, stop, switches; turning input on takes your click
    \\  • Codex's computer-use plugins are no longer loaded
    \\
    \\0.302.70
    \\  • Claude Agent: a reply that starts during a tool-list refresh no longer fails
    \\  • simulator tests can't overwrite your clipboard; large uploads aren't cut off
    \\  • an empty-reply failure says what happened and how to retry
    \\
    \\0.302.69
    \\  • reading peer mail no longer rewrites history the model was already sent
    \\  • graff login kimi works for kimi.ai (international) accounts; sign-in links are copied
    \\  • workers can use gateway models; graff harness-tree shows the harness as one tree
    \\
    \\0.302.68
    \\  • Claude Agent: compaction writes a summary instead of continuing the task
    \\  • Claude Agent: a prompt after a finished turn keeps its images
    \\
    \\0.302.67
    \\  • Claude Agent: loading a tool no longer drops the call or ends the turn
    \\  • a finished task still hears peers who message it directly
    \\
    \\0.302.66
    \\  • a one-shot answer built on hosted search is kept, not bounced and replaced
    \\
    \\0.302.65
    \\  • Claude Agent models use their full 1M context window (was listed as 200k)
    \\
    \\0.302.64
    \\  • an expired Console sign-in is skipped, and the error says to run graff login console
    \\
    \\0.302.63
    \\  • auth errors say which credential was rejected: the sign-in, or the API key (and when it was the fallback)
    \\
    \\0.302.62
    \\  • rlm's llm_query works on Claude Agent, on a throwaway claude process
    \\
    \\0.302.61
    \\  • Claude Agent: Claude models through your own Claude Code login (graff login claude-agent)
    \\  • subagent requests keep agent_output in lean mode, so the turn waits for its workers
    \\
    \\0.302.60
    \\  • a resumed session keeps its real context size instead of re-estimating compaction state
    \\  • large compaction items work over WebSocket without re-running the turn
    \\
    \\0.302.59
    \\  • steadily arriving partial SSE events no longer trigger false stalls or replay
    \\  • genuine stalls still time out and unfinished events remain bounded
    \\
    \\0.302.58
    \\  • ACP startup and model discovery no longer wait on slow model-catalog hosts
    \\  • note_constraint states its 240-byte limit up front
    \\
    \\0.302.57
    \\  • images are typed by their bytes, so a mislabelled file no longer wedges a chat
    \\  • resending a prompt after a failed request makes a new request
    \\  • stream error events surface the provider's error instead of retrying
    \\  • withdrawn checklist items can be cancelled with a reason
    \\
    \\0.302.56
    \\  • native file tools follow dependency symlinks that stay inside the workspace
    \\  • escaping, dangling, and cyclic links remain blocked
    \\
    \\0.302.55
    \\  • help, release history, and bundled playbooks are compressed until needed
    \\  • long home paths keep the macOS background-launch protection
    \\
    \\0.302.54
    \\  • normal terminal startup is quiet; diagnostics stay opt-in
    \\  • live thinking shows Ctrl+T collapse/expand beside its header
    \\
    \\0.302.53
    \\  • smaller binaries share prompt text and compress runtime resources
    \\  • release builds keep safety checks and leave local learning optional
    \\  • workflow synthesis keeps its catalog at the final report boundary
    \\
    \\0.302.52
    \\  • clearer terminal status, Markdown emphasis, and checklist styling
    \\  • /workers opens a read-only browser of subagent activity and reports
    \\
    \\0.302.51
    \\  • Kimi API keys and logins work again (no more RstStream)
    \\  • a used-up Kimi plan window stops instead of retrying
    \\  • retrying a prompt after a connection failure works again
    \\  • subagents and workflows can fork the conversation
    \\
    \\0.302.48
    \\  • oMLX is a built-in local provider: --model omlx
    \\  • compaction counts opaque state by the provider's own measure
    \\  • a stopped local server is named in the failed turn
    \\
    \\0.302.47
    \\  • compaction waits instead of repeating when it can't make room
    \\  • the shared-tree checkpoint lets a re-issued call through
    \\  • fyi peer mail stays in the inbox without starting a turn
    \\
    \\0.302.46
    \\  • images over ACP reach the hosted default models
    \\  • a worker keeps its report when its state can't be saved
    \\  • a client's own cancel isn't called the user's
    \\
    \\0.302.45
    \\  • ACP context meter reports what graff kept out of context
    \\  • render_html says a page is saved, not displayed
    \\  • workspace use: instructions follow the tree you switch to
    \\
    \\0.302.43
    \\  • updated subscription context capacity avoids premature compaction
    \\  • model catalog and ACP usage updates report the same window
    \\
    \\0.302.42
    \\  • output-limit recovery keeps later requests and saved history valid
    \\  • ACP subagent activity shows the resolved worker model
    \\  • current main plus session, MCP, compaction and parked-command fixes
    \\
    \\0.302.41
    \\  • native subscription sign-in across terminal and ACP clients
    \\  • MCP structured results, resource content and inbound ping handling
    \\  • request-local loopback deadlines and repeatable fixture comparisons
    \\
    \\0.302.40
    \\  • stream recovery preserves partial replies across ACP and resume
    \\  • workspace skills in headless runs; actionable claim inventory
    \\  • MCP off-lists and JSON configuration listing; atomic companion updates
    \\  • stored conversation continuation and typed sign-in recovery
    \\
    \\0.302.39
    \\  • unattended runs recover from output limits and empty replies
    \\  • one-shot stream-json reports a resume handle, outcome and usage
    \\  • exhausted budgets and account limits stop with distinct exit codes
    \\
    \\0.302.38
    \\  • Windows: faster start, and the companion is found on PATH
    \\
    \\0.302.37
    \\  • ChatGPT sign-in keeps your saved token out of the sign-in URL and always prints it
    \\
    \\0.302.36
    \\  • new worktrees link .agents/linked files and run .agents/prepare
    \\
    \\0.302.35
    \\  • gateway models are priced from the gateway itself; new models show their cost
    \\  • graff models shows each gateway model's real rate
    \\  • a model without its provider's login names --model codegraff/<model>
    \\
    \\0.302.34
    \\  • Gemini API key sign-in works again
    \\  • Gemini 4 Argon shows its cost; /effort minimal runs as low on Gemini
    \\  • a gateway timeout mid-answer is retried instead of ending the turn
    \\
    \\0.302.33
    \\  • Claude: a new repo reads graff's tools and instructions from the prompt cache
    \\
    \\0.302.32
    \\  • a yield_turn handoff shows once in ACP clients
    \\  • graff login anthropic works from the desktop app, SSH and servers
    \\  • graff tui installs its client on first use
    \\
    \\0.302.31
    \\  • tool rows for todo_write, peer_message and schema loads finish in ACP clients
    \\  • graff update works on Windows
    \\
    \\0.302.30
    \\  • graff mcp status / reconnect / enable / disable, and /mcp reconnect in a session
    \\  • graff login anthropic: use an Anthropic Console account
    \\  • Claude Haiku 5.5 replaces Haiku 4.5
    \\
    \\0.0.302.29
    \\  • streamed requests to the Codegraff gateway carry graff's version too
    \\
    \\0.0.302.28
    \\  • the Codegraff usage page shows which graff version and device sent each request
    \\
    \\0.0.302.27
    \\  • choose where compaction starts: /compact-at 70, --compact-at, or the desktop setting
    \\
    \\0.0.302.26
    \\  • compaction replies no longer show up in the desktop chat
    \\  • a question no longer restarts an earlier task's checklist
    \\  • a model switch across providers keeps the conversation
    \\  • computer-use and closed stdio MCP servers recover
    \\
    \\0.0.302.25
    \\  • ChatGPT/OpenAI sessions no longer compact before every tool call
    \\  • OpenAI routes compact only with the provider's own compaction
    \\  • fewer hosted-model requests per task; empty tool results no longer break a chat
    \\
    \\0.0.302.24
    \\  • Codegraff sign-in: models on the Messages wire use it natively
    \\  • goals set from the desktop app start immediately; unfinished work survives a question
    \\
    \\0.0.302.23
    \\  • ChatGPT-plan sign-in caches the prompt again, on every model
    \\
    \\0.0.302.22
    \\  • /import-claude brings this project's Claude Code conversations to /resume
    \\  • imported conversations continue on your graff provider and credentials
    \\
    \\0.0.302.21
    \\  • Windows: irm https://codegraff.com/install.ps1 | iex installs graff natively
    \\  • graff login prints the link with your code; Windows opens the browser
    \\  • an expired ChatGPT sign-in reopens in the browser and the request continues
    \\
    \\0.0.302.20
    \\  • includes everything from 0.0.302.19 (not published on its own)
    \\  • one oversized MCP message no longer breaks every later call to that server
    \\  • Windows: an empty HOME no longer hides your profile directory
    \\  • GRAFF_COMPACT_MIX=1: experimental two-pass compaction
    \\
    \\0.0.302.19
    \\  • tool results inline up to 64 KiB: large files read in one piece
    \\  • no false stalls while the model composes a batch of tool calls
    \\  • parked work is named above the prompt; graff says it will continue
    \\  • PR commands run like any other command (no readiness gate)
    \\  • logged in, Jev picks each turn's effort alongside the first request
    \\
    \\0.0.302.18
    \\  • graff tui launches the separate fullscreen client; terminals get the line REPL
    \\  • shorter turns: one-line heads-ups, no recomputed answers, fewer false stalls
    \\  • instructions cache across repos; the shell names python3's version
    \\  • clearer session lists and cross-project resume
    \\  • paste warnings, MCP recovery, and catalog-tolerant model selection
    \\
    \\0.0.302.17
    \\  • rlm scripts keep whole MCP results; print() still shows the slim view
    \\
    \\0.0.302.16
    \\  • license: companies that raised over US$500k need a commercial license
    \\
    \\0.0.302.15
    \\  • DeepSeek's default effort thinks at its low level (/effort high for more)
    \\
    \\0.0.302.14
    \\  • MiMo answers without thinking unless effort is high (/effort high)
    \\  • MCP servers connect in the background; the first message never waits
    \\  • sub-agents start with your prompts and their parent's effort
    \\  • the shell tool names the OS; small reads and sed -i pass the guard
    \\  • rlm takes JSON literals; todo_write replies with counts
    \\
    \\0.0.302.13
    \\  • fewer round trips: named MCP servers and subagents load up front
    \\  • write_file won't replace an unread file and says what it did
    \\  • sub-agents call inherited MCP tools from their first request
    \\  • piped repl: a bracketed paste is one prompt
    \\
    \\0.0.302.12
    \\  • every ChatGPT login (chatgpt, codex) is the new ChatGPT sign-in
    \\  • browser sign-ins survive stray connections and old tabs
    \\  • sub-agents get the MCP tools their root loaded
    \\  • codex follows the model's default effort and verbosity
    \\
    \\0.0.302.11
    \\  • codex prompt cache is per account: a new repo starts warm
    \\  • tool loads keep the cached prefix; rare tools load on demand
    \\  • MCP says how it slims results and keeps the full result
    \\  • GPT-6 follow-ups steer the running reply; graff login chatgpt
    \\  • scripted repl sends the prompt once and waits for background work
    \\
    \\0.0.302.10
    \\  • a tool call cut off mid-response is refused with its cause, not run
    \\  • /loop waits for its background work; resends never start a second turn
    \\  • slow Anthropic calls keep their prompt cache; OpenRouter caches Claude
    \\
    \\0.0.302.9
    \\  • macOS CLI signed and notarized by the release workflow
    \\  • local MCP servers start on first use; "shared": true runs one per machine
    \\  • the desktop app is Harness; the in-repo desktop apps are removed
    \\  • graff mcp add --everywhere saves to the user-level MCP config
    \\  • Harness room messages from other agents arrive framed as advisory
    \\
    \\0.0.302.8
    \\  • instruction-file edits reach the model without busting the prompt cache
    \\  • no more /pr-acceptance: a draft PR completes as an unverified handoff
    \\  • PR review budget fits small edits in large files; finite jobs stay awaitable
    \\  • MCP client: pagination, list_changed, progress, cancellation, MRTR
    \\  • graff mcp add infers, checks and hot-joins a server; desktop computer use removed
    \\
    \\0.0.302.7
    \\  • tool shells: provider keys stay out, git and NUL-byte commands are safer
    \\  • tool calls left as <tool_call> markup in a reply now run
    \\  • ACP: diffs and locations on tool calls, richer approvals, faster session/new offline
    \\  • graff mcp serve speaks MCP 2026-07-28
    \\
    \\0.0.302.6
    \\  • ask_user over ACP uses standard elicitation and never freezes a client
    \\  • ACP subagents stream their work onto the parent tool call
    \\  • ACP v2 draft preview (GRAFF_ACP_V2=1)
    \\  • graff peer: message other agents on this device; graff keys: sync logins
    \\
    \\0.0.302.5
    \\  • WebSocket turns stream live, with automatic HTTPS fallback
    \\  • ACP sessions use the client's folder and report their worktree
    \\  • openai/codex models and ACP image blocks accept images
    \\  • the old browser companion is retired; webfetch uses built-in HTTP
    \\
    \\Full release history: https://github.com/justrach/codegraff/releases
    \\
;
