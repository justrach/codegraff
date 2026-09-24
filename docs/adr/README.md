# Architecture Decision Records

Settled decisions with their reasoning, so nobody (human or agent) has to
re-derive or re-litigate them from scratch. Each record is one decision: the
context that forced it, what was decided, and what it costs.

**Start here.** The index below gives you the rule in one line; open the
record only when you need the evidence or the edge cases.

## Index

| ADR | The rule |
|---|---|
| [0001](0001-structured-outputs-are-a-formatting-step.md) | Structured output is a final formatting step. Never constrain the agentic phase with a schema grammar, and do not use `--output-schema` unless a program consumes the result. |
| [0002](0002-xai-defaults-to-the-responses-wire.md) | xAI runs on the Responses wire by default (WS turns + on-socket `previous_response_id`). Compaction is the client summarizer, not xAI's blob endpoint. `GRAFF_XAI_WIRE=chat` opts out. |
| [0003](0003-codegraff-wire-follows-model-capability.md) | Codegraff uses Responses + WS for GPT-5.6+ (incl. GPT-6 Astra / Codex `gpt-5.6-*`) and grok-4.6; Claude, Gemini, and other aliases stay on Chat Completions. |
| [0004](0004-peer-speech-is-a-working-set.md) | Peer speech is pull: a one-line `[peer]` wake in history, bodies in the inbox ring; compact drops spent injects and never treats them as the human. |
| [0005](0005-standing-goal-lives-in-the-prefix.md) | Standing goal is one prefix line; the user-message essay injects on change only, never every N turns. |
| [0006](0006-workspace-switch-is-a-tool.md) | Mid-session worktree switch is a real `workspace` tool; a skill cannot move file-tool cwd. |
| [0007](0007-plugins-are-read-in-place.md) | Cursor/Claude/Grok/Codex plugins and MCP are read in place (Claude/Cursor cache via installed_plugins.json, Codex via config.toml PluginStore, never walked); skills stay on-demand; MCP stays consent-gated. |
| [0008](0008-synthetic-evals-use-external-verifiers.md) | Synthetic coding evals promote only external-verifier passes; model judges may tiebreak correctness, never decide it. |
| [0009](0009-gpt-5-6-explicit-prompt-cache-boundary.md) | GPT-5.6 OpenAI Platform marks the stable prefix explicitly; Codex and xAI stay on their supported keyed automatic-cache paths. |
| [0010](0010-background-jobs-wait-for-exit.md) | `bash_output`/`agent_output` `wait_ms>0` blocks until exit (10h cap); do not poll every 30s. |
| [0011](0011-prompt-cache-max-is-visible.md) | Prompt-cache max is on: stable catalog by default; `/cache` is the HUD; `/btw` rides the parent prefix; children share role-lane `x-grok-conv-id` / `prompt_cache_key` (not the root id). |
| [0012](0012-overflow-handles-named-limits-extra-roots.md) | Fat tool results become `tr_N` handles; named `--context-limit` caps prefix bytes; `--add-dir` extra roots are PathConfine allow-lists, not cwd/skill/session sources. |
| [0013](0013-list-dir-lives-in-codedb.md) | Directory listing is `codedb list_dir` (in-process BFS, gitignore, 10k cap), not a new always-on catalog tool. |
| [0014](0014-session-resume-carries-the-room-cursor.md) | `/resume` restores the peer-channel byte cursor and inbox; it does not replay the room into history. |
| [0015](0015-ask-user-images-are-a-follow-up-user-message.md) | `ask_user` images ride a follow-up user message after the text tool result; Responses/OpenAI tool output stays text-only. |
| [0016](0016-line-repl-is-a-working-block.md) | Line REPL chrome is a `WORKING` block plus a bare `›`; tool fan-out is a tree, never `✓ bash`. |
| [0017](0017-model-election-ranks-signed-in-plans-first.md) | `/model` and `/models` on both frontends rank signed-in plan seats above credits and metered keys (`src/models_rank.zig`). |
| [0018](0018-standing-chrome-shows-last-turn-cache-hit.md) | Last-turn cache hit % rides with `ctx` on the line-REPL meter and the TUI footer; `/cache` stays the posture HUD. |
| [0019](0019-codedb-one-shot-over-hop-chains.md) | Advertise only `context` / `around` / `callpath` / `list_dir` / `status`; hop verbs stay callable, not on the menu. |
| [0020](0020-transcript-shows-decisions.md) | Transcript shows decisions: one interpreted tool line, collapsed infra failures, compact WORKING; `↵ raw`, `/debug`, and TUI-fold disclose the bytes explicitly. |
| [0021](0021-transcript-is-the-task-not-the-bus.md) | Transcript is the task, not the event bus: bookkeeping is silent, todos are WORKING, subagents are scouts. |
| [0022](0022-rlm-is-opt-in-speculative-ptc.md) | `rlm` (Alex Zhang spec-ptc + RLM, Zig) is the default loop. `--old` restores structured-only. Prime persist + `subagent()` only — no IPython. |
| [0023](0023-codex-subagent-is-sidecar-not-v8.md) | Codex check: take sidecar-vs-critical-path spawn prompts; reject V8 Code Mode, extra spawn tools, and parent-history fork. |
| [0024](0024-three-harness-compare-prompt-subagent-rss.md) | Steal short child briefs + sidecar spawn; `print(read_file)` returns the file; `-p` skips the shared-tree checkpoint (evals are sibling sandboxes); reject rlm-only catalog, grok heap, Harbor. |
| [0025](0025-io-uring-is-not-the-process-io.md) | Process Io stays Zig `Threaded`. spec-ptc is already the default loop (ADR 0022). Do not take ublk or switch `main` to `std.Io.Uring`. |
| [0026](0026-foreground-bash-auto-backgrounds.md) | Root foreground `bash` auto-backgrounds after 120s (a shorter `timeout` may promote earlier); it is not killed. Subagents still kill at 120s (#93). |
| [0027](0027-kimi-identity-is-graff.md) | Kimi Coding User-Agent is `graff/<version>`, not a spoofed `kimi-code-cli` token. X-Msh device fields follow kimi-code's shapes. |
| [0028](0028-codex-session-id-is-the-cache-key.md) | Codex HTTP/WS `session_id` is the `prompt_cache_key` (openai/codex ModelClient default), not a per-process random UUID. |
| [0029](0029-mcp-inside-rlm-and-return-shapes.md) | Loaded MCP tools are rlm host functions; persist return shapes on the load result, never the prefix; fat MCP results auto-slim; default `-p` connects `.mcp.json` (folded, not skipped). |
| [0030](0030-rlm-late-showcase.md) | Superseded by [0140](0140-rlm-is-listed-when-available.md). Late showcase hid `rlm` on small turns; that gate is gone. |
| [0031](0031-xai-hosted-x-search.md) | xAI Responses splices hosted `x_search` onto tools turns. It is not a catalog function; `GRAFF_XAI_X_SEARCH=0` opts out. |
| [0032](0032-acp-streams-mid-turn.md) | `graff acp` streams thought / tool / text `session/update`s mid-turn. The native app is an ACP client; it does not need `graff serve`. |
| [0033](0033-user-can-retire-a-standing-constraint.md) | Only the user retires a standing constraint: TTY `/never` picker (two confirms), ACP/`rm`, or an explicit override. The model cannot. |
| [0034](0034-remote-images-stay-native.md) | JSON/serve image inputs are a typed URL/base64 union, validated atomically and preserved as native provider vision blocks; never flatten pixels into prompt text. |
| [0035](0035-first-turn-skips-deferred-mcp-join.md) | First model call after a deferred MCP boot does not wait for the handshake; companion auto-connect is the same defer; native tools run now. |
| [0036](0036-computer-use-keeps-the-signed-codex-bridge.md) | Codex Computer Use keeps its authenticated node_repl process chain: Graff launches it through the signed Codex sandbox wrapper, never embeds V8 or spoofs the service. |
| [0037](0037-experiment-pool-is-opt-in.md) | `--experiment N` / `/experiment N` pre-mints a child worktree pool; the root must spawn; pool trees are listed and delivered back, never auto-deleted. |
| [0038](0038-in-process-acp-core.md) | Same-process embed is `libgraff` + `graff-core.wasm` + `createGraffAgent()` (ACP core, echo turn). Live coding stays `graff acp`. |
| [0039](0039-local-tools-are-project-scripts.md) | Agent-authored local tools are project scripts under `.graff/tools/`; skills stay instructions. Runtime catalog extras, not `schema.effectiveRootSpecs`. |
| [0040](0040-codedb-stays-when-licensed.md) | Ordinary reads use native `codedb` / `read_file`; codedb-pro is extra search, not the default reader. |
| [0041](0041-tui-is-an-acp-client.md) | The fullscreen TUI is an in-process ACP client: session/prompt in, session/update thought/tool/text out. No child `graff acp`. |
| [0042](0042-tui-claims-screen-before-session.md) | `graff tui` / TTY `graff repl` claim the alt-screen before keys/MCP/prompt; leftover boot happens inside the pager. |
| [0043](0043-pi-swe-same-seat.md) | Pi SWE A/B uses `pi-xai` on the SuperGrok seat; do not steal Pi's catalog or heap from the json-stream pass. |
| [0044](0044-oneshot-skips-learn-auto.md) | `-p` and `--json` skip learn auto-init; the Pi SWE wall gap was a 38s `graff-pinned` copy, not their catalog. |
| [0045](0045-glm-flash-swe-codegraff.md) | Codegraff `glm-5.3-flash` SWE: Pi 5/6 in 758s, graff 3/6 with three 300s timeouts; do not steal Pi's heap. |
| [0046](0046-flash-omits-default-effort.md) | Flash / Gemini send `reasoning_effort=low` (omit still thinks); lean `-p` shortens tool prose; `-p` streams. |
| [0047](0047-codegraff-swe-not-glm-only.md) | Codegraff SWE A/B is not GLM-only: Gemini graff 5/6 in 103s; DeepSeek flash still one-shots; do not steal Pi's catalog. |
| [0048](0048-model-http-client-recovery-uses-generations.md) | Model HTTP calls lease a recoverable client generation; request-construction TLS failure rotates safely without deinitializing in-flight users. |
| [0049](0049-resume-branches-have-independent-durable-identity.md) | `--resume SOURCE --branch DEST` clones provider history and peer cursor state once; every later save belongs only to DEST. |
| [0050](0050-reuse-warmed-tls-on-known-networks.md) | Reuse warmed TLS: MCP probe/initialized stay on the persistent HTTP client; WSS CA is scanned once per process; WS→SSE keeps the prewarmed pool; MCP HTTP accepts gzip. |
| [0051](0051-sandbox-teleport-and-gc.md) | `/teleport` restores a snapshot tar onto another CLI backend; `/snapshot gc` keeps the newest n trees. |
| [0052](0052-lean-oneshot-bounces-prose.md) | Lean `-p` bounces a first-turn prose-only "done"; one user note naming file tools, then re-open. |
| [0053](0053-codegraff-flake-retry-opencode.md) | Retry short Codegraff follow-up flakes (2); `opencode-codegraff` A/B on the same seat. Auth/quota stay fail-fast. |
| [0054](0054-deepseek-thinking-disabled-at-low.md) | DeepSeek family default low sends `thinking.type=disabled`; `/effort high` still thinks. GLM stays low-only. |
| [0055](0055-lean-oneshot-bash-15s.md) | Lean `-p` bash auto-backgrounds at 15s; interactive / `--no-lean` stay 120s (ADR 0026). |
| [0056](0056-composer-image-chips-sync-on-delete.md) | Composer image chips sync on delete and reuse `#N`; `clipboard_paste` MIME/bytes wait until send. |
| [0057](0057-peer-title-is-an-address.md) | `peer_message` resolves exact title / saved-session base before opaque id or goal. |
| [0058](0058-compact-cut-stalls-on-no-progress.md) | Same unresolved `compact_cut` pin that does not shrink stops after two tries. |
| [0059](0059-saved-session-discovery-is-device-scoped.md) | `/resume` and `/sessions` list cwd then `~/.graff/sessions`; home-origin resume keeps tools in the current cwd. Linked worktrees: [0155](0155-resume-reenters-saved-worktree.md). |
| [0060](0060-named-source-gate-is-per-unanswered-mention.md) | The named-source nudge is per unanswered mention; identical user turns do not replay (#714). |
| [0061](0061-tool-only-turns-narrate-and-ask-in-band.md) | Heads-up text rides in the same response as the tool calls; a choice for the user is an `ask_user` call; a job exit the model already read never wakes it. |
| [0062](0062-background-servers-idle-lifecycle-and-ownership-record.md) | A background job silent and unread for 2h is stopped with its command kept; `/jobs keep` pins one (retained at exit); every job has an ownership record `graff servers` can list and stop, verified by start identity (#199). |
| [0063](0063-unsourced-cancel-is-the-harness.md) | Every cancel records its source; a turn cancelled with no recorded source is labelled a harness cancel, never a user interrupt, and the source lands in the trace (#728). |
| [0064](0064-plain-finals-reconcile-open-work.md) | Plain root finals with open current work get one reconciliation request; a remaining stop is explicit, not a promise of continued execution. |
| [0065](0065-stop-bounded-prose-repetition.md) | Stop bounded lexical prose loops before delivery without user cancellation, transport retries, or completion nudges. |
| [0066](0066-publication-policy-and-ledger-authority.md) | Publication safeguards survive custom prompts; recaps cannot change ledger authority, and constraint writes refresh active prompts atomically. |
| [0067](0067-recorded-constraints-are-ledger-state.md) | Recorded constraints are live ledger JSON in the root prefix; recap prose is not authority, and a write refreshes instructions in the same turn. |
| [0068](0068-background-agent-handles-survive-interrupt.md) | Background-agent ids are a session ledger; an interrupted parent turn must not report them as never started (#753). |
| [0069](0069-cache-affinity-is-the-git-root.md) | Prompt-cache affinity is the git root (or a shared scratch seed), not the leaf cwd. |
| [0070](0070-electron-browser-and-native-panels.md) | The local Electron desktop renders browser pages directly, keeps coding in graff ACP, and hosts narrow SwiftUI panels through a native bridge. |
| [0071](0071-desktop-tools-and-macos-computer-use.md) | Desktop MCP controls embedded Chromium and a user-enabled native macOS bridge; coding stays in graff. |
| [0072](0072-gui-profiler-exports-measurements-only.md) | GUI profiling is bounded and off by default; feedback exports contain allowlisted measurements with no automatic upload. |
| [0073](0073-acp-stream-and-shared-review.md) | One ACP stdout reader routes responses; shared review reads Git working trees without inferring edit authorship. |
| [0074](0074-gui-skills-and-portable-themes.md) | Explicit desktop skills and validated themes live in the GUI; selected instructions travel over ACP. |
| [0075](0075-acp-adapter-and-desktop-measurements.md) | ACP presentation decoding is separate from session lifecycle; desktop performance uses bounded workload measurements and default Chromium acceleration. |
| [0076](0076-local-agent-panel.md) | Verified local peer discovery, non-consuming history, explicit queued DMs and anonymous profiler slots. |
| [0077](0077-desktop-command-parity-and-bounded-disclosure.md) | ACP shares the complete REPL catalog; desktop menus, tool disclosure and initial history rendering stay bounded. |
| [0078](0078-workspace-terminals-are-lazy-pty-sessions.md) | Desktop workspace terminals start lazily, preserve hidden shells and bound output through a trusted PTY bridge. |
| [0079](0079-desktop-updates-are-signed-and-user-restarted.md) | Signed desktop updates download in the background and install only on explicit restart; one process owns each profile. |
| [0080](0080-desktop-projects-are-folders.md) | Desktop projects are folders; preferences survive local UI origin changes, and new chats inherit the focused project's folder. |
| [0081](0081-desktop-split-focus-and-layout.md) | Split positions remain stable as focus changes; shared controls and draggable separators keep navigation usable. |
| [0082](0082-subagent-activity-through-acp.md) | Sub-agents publish bounded, independent activity snapshots for read-only ACP inspection without mixing parent transcripts. |
| [0083](0083-meta-tool-choice-is-auto-only.md) | Meta / Muse Spark `tool_choice` is `auto` at the source; `max` effort folds to `xhigh` (#751). |
| [0084](0084-codedb-context-honors-local-only.md) | Native `codedb context` is `--local` (or refused before spawn) when repository policy or `local_only` forbids transmitting working data; no-retention hybrid is not no egress. |
| [0085](0085-in-session-update-is-next-launch.md) | `/update` installs a verified release for the next launch; this session keeps its original binary. |
| [0086](0086-desktop-drafts-belong-to-open-chats.md) | Unsent desktop drafts and uploads belong to open chats and survive hidden panes; closing a chat disposes them. |
| [0087](0087-bounded-desktop-presentation-work.md) | Bound syntax caches and live code rendering; project saved transcripts before sending them to the renderer and measure identical desktop workloads. |
| [0088](0088-failed-children-return-partial-evidence.md) | Failed children return bounded partial evidence with error status intact, including an excerpt for workflow synthesis. |
| [0089](0089-canonical-compaction-windows-survive-recovery.md) | Preserve standalone compaction windows across pruning and resume; opaque recovery uses the server or reports failure without discarding history. |
| [0090](0090-project-constraints-require-explicit-scope.md) | Local steering stays local; durable project constraints require explicit scope and exact current-user text, while legacy unscoped records are reviewable. |
| [0091](0091-persistent-jobs-honor-wait-ms.md) | Superseded by [0152](0152-persistent-shells-snapshot-once.md) for persistent `wait_ms`; finite jobs still wait until exit (ADR 0010). |
| [0092](0092-codedb-context-is-local-first.md) | Bare `codedb context` is `--local`; `--hybrid` / `--semantic` are opt-in remote rerank (and still refused under ADR 0084 policy). |
| [0093](0093-project-layout-breadth-and-directory-hints.md) | Project layout favors breadth under its caps; missing directories offer bounded sibling hints without changing confinement or ADR 0090 constraint policy. |
| [0094](0094-subagent-interrupt-is-a-cancel-file.md) | GUI Stop writes `{id}.cancel` in the activity dir; the child finishes failed even if the model returns. Not `session/cancel`. |
| [0095](0095-live-evals-are-gated-prs.md) | Live evals are gated PRs with no SPEC.md; score pass @ n=3 and list$ on passing reps only. |
| [0096](0096-desktop-link-destination.md) | Persist the desktop link destination outside origin-scoped storage; validate once and reveal the focused chat's Browser without navigating the app. |
| [0097](0097-isolate-probe-clipboards.md) | Offline PTY probes get private clipboard commands per process; direct probe runs retain OS clipboard integration. |
| [0098](0098-orphan-listeners-are-not-stop-authority.md) | Legacy listener discovery is read-only; stop authority requires verified ownership, port preflight checks both families, and unknown browser visibility protects listening jobs. |
| [0099](0099-gui-saved-sessions-are-snapshots.md) | A saved-session GET is a snapshot with unknown live status; the GUI must not infer the REPL finished. |
| [0100](0100-publication-claims-and-verified-completion.md) | Non-draft PRs fail closed on CI/Verification/helper-only claims; artifact presence ACK is not ownership; recipe success is verified task success. |
| [0101](0101-gui-tests-preserve-desktop-focus.md) | GUI tests stay hidden by default; visible opt-in can overlap other apps, and native foreground checks require separate opt-in. |
| [0102](0102-workspace-agents-and-cancel-recovery.md) | Agents uses the workspace area, Tasks visibility is explicit and persisted, and timed-out cancellation retires the worker before session recovery. |
| [0103](0103-mcp-apps-are-isolated-result-views.md) | MCP Apps are private saved result views in isolated GUI/browser sandboxes; app tool calls require a future approval path. |
| [0104](0104-live-publication-and-deferred-tool-evidence.md) | Requests merge only ready MCP tasks; publication and completion use fresh head evidence; claim transactions serialize handoffs. |
| [0105](0105-explicit-legacy-listener-stop.md) | Only an explicit identity-bound stop-suspect action may terminate an unrecorded legacy listener; automatic cleanup stays conservative. |
| [0106](0106-desktop-html-explanations.md) | Desktop HTML explanations are private saved results in static, opaque sandboxes with bounded source and offscreen teardown. |
| [0107](0107-model-drawn-pages-render-in-an-opaque-frame.md) | A page the model draws (`render_html`) is a private snapshot served under a CSP sandbox; the model picks the presentation, never the privilege. |
| [0108](0108-browser-events-outrank-pending-snapshots.md) | Browser page-info events invalidate older pending IPC snapshots; a loaded page must not revert to loading. |
| [0109](0109-resume-retains-catalog-and-layout-snapshots.md) | Resume restores loaded tool selections and the same-workspace layout snapshot, without freezing current instructions or granting permissions. |
| [0110](0110-project-mcp-listing-opts-in-optional-servers.md) | Project MCP entries opt in optional servers; inherited extras still require opt-in, and startup consent applies to both. |
| [0111](0111-peer-inbox-retains-bodies-and-reports-loss.md) | Peer inbox owns complete bodies, reports and persists loss, and clears only after a complete read result is allocated. |
| [0112](0112-mcp-wire-names-preserve-raw-routing.md) | MCP wire names are escaped and bounded; raw server/tool identities control policy and dispatch. |
| [0113](0113-clipboard-errors-need-evidence.md) | Direct AppKit clipboard failures need typed evidence; generic helper failures never imply Automation permission. |
| [0114](0114-live-citations-are-terminal-presentation.md) | Live terminal citations use per-stream display filters with independent reasoning state; structured JSON/ACP output stays unchanged. |
| [0116](0116-informational-turns-have-bounded-scope.md) | Summary turns gather bounded evidence; coding completion requirements apply to requested changes. |
| [0118](0118-file-edits-check-target-worktree.md) | File edits checkpoint the target Git worktree; unresolved paths retain the caller checkpoint. |
| [0119](0119-computer-tools-receive-caller-context.md) | Computer-use MCP requests receive opaque caller-owned session and turn context. |
| [0120](0120-draft-publication-does-not-complete-verification.md) | Draft PRs cannot satisfy verified completion; only a user control scoped to this conversation and goal permits an unverified draft handoff. |
| [0121](0121-claims-include-repository-identity.md) | Claims include repository identity; literal PR mutations compare the observed repository, PR number and branch, while unknown scopes stay conservative. |

| [0122](0122-one-session-navigation-surface.md) | Open chats use the expanded sidebar or collapsed top tabs, preserving drafts and groups; focused mode keeps a compact composer and accessible settings. |

| [0123](0123-pr-check-observations-retain-the-rollup.md) | PR completion retains named current-head check observations locally; diagnostic receipts never replace fresh verification. |

| [0124](0124-review-checkpoints-preserve-unfinished-scope.md) | Explicit reviews request a findings checkpoint every twenty calls without forcing completion or changing authority. |

| [0125](0125-review-deadlines-belong-to-one-turn.md) | Opt-in review deadlines use joined turn-owned watchers, preserve user cancellation, and cannot validate late results. |

| [0126](0126-publication-retains-observed-check-failures.md) | Observed failed checks survive resumes; non-draft publication waits for successful reruns and occupies its own tool batch. |


| [0127](0127-title-generation-is-an-explicit-result.md) | GUI titles require one explicit result and successful process exit; diagnostics never become chat names. |

| [0128](0128-gui-context-meter-uses-harness-occupancy.md) | The GUI context ring uses last-reported harness occupancy; missing usage stays unknown. |

| [0129](0129-mcp-server-delegates-bounded-cli-tasks.md) | `graff mcp serve` exposes bounded fresh CLI tasks over stdio; launch-time permissions and workspace stay outside tool arguments. |
| [0130](0130-mcp-task-app-is-an-optional-result-view.md) | MCP task apps negotiate presentation only; structured results and text fallback share the same bounded task execution. |
| [0131](0131-mcp-http-and-managed-client-registration.md) | HTTP MCP shares bounded task execution; CLI and GUI installs register detected clients additively through a private local service. |
| [0132](0132-desktop-passkeys-use-signed-device-credentials.md) | Desktop Touch ID uses matching signed keychain configuration; account choice is explicit and existing iCloud credentials need a fallback. |
| [0133](0133-clipboard-files-follow-consumer-ownership.md) | Clipboard cleanup requires file ownership and released consumers; age alone never deletes active or saved attachments. |

| [0133](0133-publication-review-binds-committed-inputs.md) | Proposed: non-draft publication reviews immutable source and observed checks; changed inputs invalidate earlier assessments. |
| [0134](0134-accord-live-jsonl-durable.md) | JSONL is the durable peer room; Accord Unix 0600 is live by default (`GRAFF_ACCORD=0` opts out). |
| [0135](0135-one-shell-tool.md) | Advertise one `shell` tool (`run` / `output` / `kill`); bash names stay dispatch aliases. Not a PTY. |
| [0136](0136-follow-up-promotes-a-live-shell.md) | A queued follow-up or force-steer promotes a foreground shell; Esc still kills it. |
| [0137](0137-desktop-appearance-is-a-turn-note.md) | Desktop appearance tokens for `render_html` ride the turn, never the prefix or tool catalog; drawn HTML uses them unless the user named colors. |
| [0138](0138-unselected-splits-use-glass-overlay.md) | Unselected split panes keep their transcript under a light wash; the focused pane stays the working surface. |
| [0139](0139-bounced-answers-stay-turn-local.md) | Retain a bounced answer only in the current turn, before unfinished-work reconciliation; never recover it from persisted history. |
| [0140](0140-rlm-is-listed-when-available.md) | `rlm` is on the catalog whenever it is available. No batch-size or compactAt gate. `--old` still hides it. |
| [0141](0141-observer-notch-is-a-nonactivating-panel.md) | The desktop session observer is a non-activating SwiftUI edge panel; cells are live ACP work, opt-in from Settings. |
| [0142](0142-zigzag-is-not-a-frontend.md) | Zigzag is not a frontend. TTY `graff repl` is `TUI/`; piped/CI uses a local scripted Model. Do not vendor zigzag. |
| [0143](0143-release-desktop-is-com-codegraff-app.md) | Packaged Codegraff.app is `com.codegraff.app`. `dev.*` identities are local rebuilds only. |
| [0144](0144-claim-asks-on-accord.md) | Claim conflicts ping the owner on Accord/JSONL; the model does not broker handoff in chat. |
| [0145](0145-live-claims-are-accord-progress.md) | Claim acquire/release/handoff replicate as replaceable Accord progress; the JSON ledger stays canonical. |
| [0146](0146-concurrent-sessions-auto-isolate.md) | A second live session in the same Git checkout gets its own worktree; concurrent agents never share `index.lock`. |
| [0147](0147-finish-is-not-cleanup-fanout.md) | Finish is not archive: park peer wakes until idle, paint the tally at the step boundary, refuse cleanup/fix-it children, cap live fan-out. |
| [0148](0148-read-file-miss-storm-stops.md) | After N same-prefix or incrementing `read_file` misses, refuse further guesses this turn and point at `codedb list_dir`. |
| [0145](0145-gpt-5-6-reasoning-replays-from-local-history.md) | GPT-5.6 reasoning replays from local history: never send `reasoning.context` or `reasoning.mode`; `max` effort is the ladder ceiling (shown as Ultra); PTC items stay opaque history. |
| [0148](0148-midstream-provider-error-is-a-transient-500.md) | A streamed provider "internal error" after output began is a transient 500: bounded backoff retry, never overflow. Overflow needs a size/length phrasing or code; the meter pins only on a real rejection. Reverses `#1019`. |
| [0149](0149-daddy-directives-are-explicit-control.md) | Ambient `[peer]` wakes are not a new task; `[daddy]` directives are explicit supervisor control. |
| [0150](0150-subagent-briefs-are-structured.md) | Child briefs are headed sections plus a harness environment header; the judge stays a bare prompt. |
| [0151](0151-zai-coding-plan-login.md) | Z.AI Coding Plan is a `sub_login` like Kimi/xAI: `graff login zai` uses ZCode's public CLI OAuth broker, then provisions a Graff-named API key onto `/api/coding/paas/v4`. |
| [0152](0152-persistent-shells-snapshot-once.md) | Persistent shells snapshot immediately (`wait_ms` ignored) and stay on `/jobs`; do not poll. Finite jobs still wait until exit (ADR 0010). |
| [0153](0153-task-workspaces-copy-and-scripts.md) | Task workspaces copy gitignored include files from the main checkout and run setup/run/archive scripts from `.graff/workspace.toml`. Finish is still not archive. |
| [0154](0154-parked-shells-yield-the-parent.md) | Interactive parked shells yield the parent like subagents: 15s foreground wait, then the prompt is yours until the job-exit wake. |
| [0155](0155-resume-reenters-saved-worktree.md) | Resume of a linked-worktree save re-enters that tree; `$HOME` origin stays history-only. |
| [0156](0156-linux-desktop-sandbox-fallback.md) | Linux desktop uses system window decorations, a POSIX terminal, and a sandbox fallback when user namespaces or the setuid helper are unavailable. |
| [0157](0157-linux-desktop-release-is-the-unsigned-deb.md) | Tag releases upload the unsigned Linux `.deb` (and AppImage when the packager built one). macOS stays notarized; do not skip the Linux upload for lack of a signature. |

| [0158](0158-mimo-workers-prefer-local-flash.md) | MiMo workers use local Pro/Flash defaults; live catalog and price checks still apply, and benchmark scores are never invented. |

| [0159](0159-picker-catalog-refresh-is-bounded.md) | Opening a model surface refreshes only the gateway catalog, with a short deadline and the existing snapshot as fallback. |
| [0160](0160-model-picks-wait-for-next-prompt.md) | Running model picks stay per chat and apply only at the next prompt boundary without cancelling the current response. |
| [0161](0161-default-model-stays-on-selected-provider.md) | Default model preferences stay on the selected provider; explicit and saved choices win. |
| [0162](0162-http2-streams-own-exclusive-sessions.md) | HTTP/2 requests exclusively lease active sessions; the process pool owns only one idle connection. |
| [0163](0163-restored-tool-results-use-wire-normalization.md) | Restore and request admission share tool-result repairs while preserving typed blocks. |
| [0164](0164-task-workspace-archive-needs-current-evidence.md) | Task archive requires current commit evidence; live writers and failed teardown keep the checkout visible. |
| [0167](0167-workflow-isolation-belongs-to-dependent-chains.md) | Dependent stages share a worktree; pipeline items stay isolated and retained edits are explicitly delivered. |
| [0168](0168-tui-permission-input-belongs-to-the-frontend.md) | Normal TUI tool approvals use frontend-owned typed requests and once-only responses. |
| [0169](0169-aggregate-tool-limits-share-descendant-admission.md) | Invocation tool limits reserve atomically across descendants; legacy per-turn root limits keep their meaning. |
| [0170](0170-workers-retain-owned-conversations.md) | Workers retain owned conversation state; queue-only messages and explicit resume have distinct semantics. |
| [0171](0171-cost-rates-belong-to-the-provider-route.md) | Cost estimates use the actual provider route, preserve cache and long-context rates, and leave unknown tariffs unpriced. |
| [0172](0172-model-guidance-is-request-scoped.md) | Model guidance is composed once per request from the current model, with root-only delegation and stable repeated prefixes. |

| [0173](0173-loaded-tool-order-survives-resume.md) | Native and external schemas share admission order, which survives session save and restore. |

| [0174](0174-completion-requires-terminal-tool-results.md) | Deferred completion rejects pending work and preserves background verification exit status. |
| [0175](0175-rlm-preserves-dependent-tool-order.md) | RLM speculates only leading read-only calls, then preserves statement order and stopped tool results. |
| [0176](0176-completed-streams-do-not-replay-on-trailer-timeout.md) | A trailer deadline after valid completion returns buffered output; missing usage stays explicitly unknown. |
| [0177](0177-owned-async-tool-execution.md) | Direct read-only async jobs own their lifetime, preserve order, and join before the next request. |
| [0178](0178-batched-edits-preflight-before-commit.md) | Preflight every edit span in memory, then perform one verified replacement; an invalid later span leaves the file unchanged. |

| [0179](0179-durable-shell-handles.md) | Reserve durable JS-exact shell handles before spawning; stale handles never target new jobs. |

| [0180](0180-acp-permissions-belong-to-the-client.md) | ACP permission decisions belong to the active client and request; cancellation never grants approval. |
| [0181](0181-acp-load-replays-saved-conversation.md) | Live ACP loads saved conversations in their selected workspace and replays history without rerunning tools. |
| [0182](0182-acp-connection-usage-is-an-extension.md) | Connection-scoped ACP usage preserves unknown totals through a custom notification; network retries remain activity indicators. |
| [0183](0183-request-policy-owns-ambiguous-retries.md) | Ambiguous HTTP/2 failures return to the request retry policy so attempts and unknown usage remain observable. |
| [0184](0184-directory-scan-budgets-count-examined-entries.md) | Directory scan limits count examined entries before filtering; truncated listings and suggestions remain explicitly partial. |
| [0185](0185-input-semantics-belong-to-the-task-contract.md) | Empty-input, whitespace, and record-framing semantics come from the task contract, not global work instructions. |
| [0186](0186-tool-previews-use-original-source-ranges.md) | Tool previews select whole diagnostic lines from original omitted ranges within byte and line budgets. |
| [0187](0187-optional-judgments-preserve-usage-uncertainty.md) | Optional judgments use an independent gateway login; tokens and unsettled cost remain distinct in CLI and ACP usage. |
| [0188](0188-streamed-tool-calls-retain-identity.md) | Streamed tool calls use explicit IDs; reused indexes keep incomplete predecessors invalid, and prose is not execution evidence. |
| [0189](0189-bounded-buffered-http2-posts.md) | Buffered HTTP/2 posts cap body growth, use exclusive pooled leases with durable transport allocation, join deadlines, and never replay ambiguous sends. |
| [0190](0190-catalog-gets-share-bounded-http2-transport.md) | Catalog GETs use bounded HTTP/2 pages with joined deadlines, shared redirect limits, and credentials scoped to the original origin. |
| [0191](0191-acp-effort-is-session-configuration.md) | ACP thought-level options follow the active model and share `/effort` state; changes received during a turn apply after that turn. |
| [0192](0192-mimo-thinking-is-a-binary-setting.md) | MiMo exposes Off/On, preserves legacy positive settings as On, and uses the documented thinking control on each wire. |
| [0193](0193-jev-selects-effort-only.md) | Optional Jev selects only supported session effort at the next request boundary; arbitrary judgments are not exposed. |
| [0194](0194-acp-child-sessions-are-an-opt-in-preview.md) | Draft ACP child sessions stream live only with explicit opt-in; durable replay is required before default enablement. |
| [0195](0195-embedded-browser-replaces-kuri.md) | Desktop browser uses embedded Chromium, web preview uses the paired extension, and CLI fetch uses built-in HTTP without a sidecar. |
| [0196](0196-background-acp-agents-use-a-graff-extension.md) | Detached ACP workers stream through an opted-in Graff extension with connection-lifetime output ownership; draft child sessions remain foreground-only. |
| [0197](0197-deferred-mcp-joins-are-registry-serial.md) | Deferred MCP queues, joins, tool lookup, and catalog snapshots use the registry lock so concurrent requests consume and publish each connection once. |
| [0198](0198-desktop-page-transitions-preserve-tabs.md) | Desktop restart/reload confirms active-turn interruption and restores tab references from saved sessions in their workspaces. |
| [0199](0199-generated-checkouts-belong-to-project-history.md) | Generated worktree activity rolls up to the owning project in automatic suggestions; explicitly saved checkouts stay selectable. |

## When to write one

Write an ADR when a decision is load-bearing and non-obvious: it was reached
through measurement, a debate, or a failure, and someone later would
plausibly "fix" it back. Do not write ADRs for conventions the linter or
tier 1 already enforces (those live in [AGENTS.md](../../AGENTS.md)).

## How to add one

1. Copy the template below into `docs/adr/NNNN-short-slug.md` (next free number).
2. Add one row to the index above with the rule stated in one line.
3. Keep it under a page. Evidence beats prose: link the eval, issue, or commit.

```markdown
# NNNN. Title stating the decision

Status: accepted YYYY-MM-DD

## Context

What forced a decision, with the measurements or failures that framed it.

## Decision

What we do now, stated so a reader can comply without reading anything else.

## Consequences

What this costs, what it protects, and what would justify revisiting it.
```
