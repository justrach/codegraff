# Changelog

Notable changes per release, newest first. Some releases also have longer
narrative notes under [docs/releases/](docs/releases/), `graff --version`
prints a short what's-new, and the
[releases page](https://github.com/justrach/codegraff/releases) has the full
commit history for every tag.

The release workflow uses a tag's section here as its release notes (a
hand-written `docs/releases/<tag>.md` wins if present), so keeping this file
current is part of cutting a release.

## v0.0.277 (2026-08-25)

- MCP tools that `load_tool_schemas` has unfolded are `rlm` host functions
  (`each` / `len` / `project`). Return **shapes** (keys + broad types, never
  values) persist in `.graff/mcp-shapes.json` and splice onto the next load
  **result**, never the catalog prefix (ADR 0029).
- Fat MCP JSON arrays auto-slim after `remember()`: identity keys on
  issue-like rows; comments fold to `{n, latest_author}`. Two stored shapes
  add a `# muscle:` playbook on the load result.
- Full-harness SuperGrok grok-4.6 (`graff-dev-nolean`): **L** (warm slim)
  14.8s / 31k / 5 and **N** (cold slim) 20.8s / 30k / 5 dominate the
  pre-slim H/I/J front. Lean catalog (R) is a different prefix and is not
  on that front.
- Default `-p` connects a workspace `.mcp.json` and folds schemas; it no
  longer skips MCP. `--no-lean` is eager schemas, not the MCP on-switch.
- Licensed codedb-pro: one read/search surface (hide native `read_file` /
  `codedb`, omit companion writes, keep native edits) (#626/#627).
- Long turns and transport retries pulse without a default 16-call cap
  (#624/#625).
- Smolify / deepwiki / mobbin stay out of the default catalog unless opted
  in (`GRAFF_SMOLIFY`) (#628).
- No `v0.0.277` git tag on this cut.
- Test ratchet: unit suite 1664.

## v0.0.276 (2026-08-25)

- `rlm` (Zhang/Khattab RLM + alexzhang13 spec-ptc, Zig — not Prime's
  IPython kernel) is the default loop. `--old` / `--no-rlm` (or
  `GRAFF_OLD=1` / `GRAFF_RLM=0`) restore the structured-only catalog.
  `--rlm` stays as an explicit on. Last CLI flag wins; env does not
  clobber `--old` / `--rlm`.
- The spec stays folded behind `load_tool_schemas`. `--schema` / the
  64-cell tool-catalog kernel do not grow a new tool.
- Prompt-cache max: `GRAFF_STABLE_CATALOG` is on by default so
  `load_tool_schemas` (including `rlm`) does not rewrite tools JSON.
  Spawned subagents inherit it. Children share four role-lane
  `x-grok-conv-id` / `prompt_cache_key` values (official xAI sticky
  routing — same id, same server). rlm's `subagent("task")` uses
  label `subagent`, so siblings hit one lane. They do not reuse the
  root id. Opt out of stable catalog with `GRAFF_STABLE_CATALOG=0`
  or `GRAFF_NO_STABLE_CATALOG=1`.
- Measured default-RLM vs `--old` on grok-4.6 SuperGrok (one `rlm`
  suite rep): both 5/5, $0.0000 / $0.0000 (flat-rate). Persist
  `bind-reuse` 99.6s / 135k in → 39.2s / 25.3k in. Suite totals
  161s / 203k in → 136s / 105k in. Scatter wall is a wash this rep
  (#619's 86.8s → 23.7s did not reproduce). See ADR 0022.
- Root foreground `bash` no longer waits forever: after 120s (or `timeout`
  ms) a still-running command is moved to the background and the model
  gets a job id, matching grok-build. Esc still kills; the cancelled
  result tells the model to use `run_in_background`. Subagents keep the
  #93 120s kill. (#620)
- Kimi Coding keeps User-Agent `graff/<version>` (Moonshot forbids spoofing)
  and matches kimi-code's X-Msh device fields: hostname, `Windows ${release}
  ${arch}` / `macOS ${product} ${arch}`, kernel `os.release()` (#617)
- Codex `session_id` header is the same value as `prompt_cache_key` (openai/codex
  ModelClient default), not a per-process random UUID
- Codex high-effort thinking no longer trips the 45s stall watchdog after
  `in_progress` (encrypted reasoning is silent). A stall notice no longer says
  "ending turn" while reconnect still has retries. Interactive sessions print a
  dim `graff update` line when GitHub has a newer release.

## v0.0.275 (2026-08-24)

- OpenRouter requests carry app attribution (`categories: cli-agent, programming-app`).
- TUI: Esc with a draft in the composer never kills a live turn.
- Agent retries degenerate empty completions and keep-alive-only bodies.

## v0.0.274 (2026-08-23)

- Rate-limit and 5xx retries no longer dump the provider's raw error JSON
  onto the REPL (user ids, BYOK/settings links, routing docs). The line is
  `[rate limited (429) — retrying in 1s (1/5)]` and nothing else. Quota
  classifiers still read the captured body internally.

## v0.0.273 (2026-08-22)

- Long-running tool calls no longer read as a hang: after 15s of
  silence (then every interval) a dim `· bash still running · 2m10s`
  pulse prints on the line REPL and the TUI — for foreground bash and
  for blocking `bash_output` waits alike.
- CI: `scripts/test-pty-repl.py` follows cwd back onto the prompt meter.
- Test ratchet: unit suite 1586.

## v0.0.272 (2026-08-22)

- Windows: the line REPL prompt (`readline` / pickers) and standalone
  `graff-repl` also switch the console to UTF-8 (CP 65001). 0.0.271 did
  this at process start and in the fullscreen TUI; the `›` editor path
  did not (#607).
- Test ratchet: unit suite 1582.

## v0.0.271 (2026-08-22)

- Windows: line REPL and fullscreen TUI switch the console to UTF-8
  (CP 65001) before any chrome is printed, so box-drawing and icons are
  not decoded as CP437/1252 in PowerShell 5.1 (#607). zigzag's `graff repl`
  already did this; `graff` and `graff tui` did not.
- Test ratchet: unit suite 1580.

## v0.0.270 (2026-08-22)

- OpenRouter is a built-in OpenAI-chat seat (`OPENROUTER_API_KEY`,
  `graff key set openrouter …`, default `anthropic/claude-sonnet-4.6`).
  Chat goes to `openrouter.ai/api/v1`; live `/models` overlays the
  catalog. Attribution headers `http-referer` + `x-title`. Provider
  kernel 21.
- Windows: `edit_file`/`write_file` no longer panic the session on Zig 0.17's
  unimplemented path chmod (`dirSetFilePermissions`). Mode restore uses handle
  chmod (#606).
- Line REPL transcript is the task, not the event bus (ADR 0021).
- TUI markdown paints numbered lists, quotes, tasks, rules, and `_italic_`.
- Test ratchet: unit suite 1578.

## v0.0.269 (2026-08-20)

- codedb pairing (ADR 0019): advertise five one-shots — `context <task>`,
  `around <name>` (def+callers), `callpath A B`, `list_dir <path>`,
  `status`. Hop verbs stay callable, not on the catalog menu.
- Vercel AI Gateway is a built-in OpenAI-chat seat (`AI_GATEWAY_API_KEY`,
  `graff key set vercel …`, default `alibaba/qwen3.8-27b`). Chat goes to
  `ai-gateway.vercel.sh/coding-agent/v1` (docs: marks harness traffic;
  `GRAFF_VERCEL_URL` rewrites to generic `/v1`). Live `/models` overlays
  language rows only; image/video/embedding are not chat seats. `/effort`
  becomes `reasoning.effort` (`max`/`ultra` → `xhigh`). Attribution
  headers `http-referer` + `x-title`.
- Z.AI's existing seat now defaults to GLM-5.3 (1M context) with live
  `/api/paas/v4/models`, `thinking.type=enabled`, and `/effort` remapped
  onto `low`/`high`/`max` (graff `medium` → `high`). Pay-go stays on
  `api.z.ai/api/paas/v4`; GLM Coding Plan keys use `ZAI_CODING=1` or
  `GRAFF_ZAI_URL`. Prompt-cache max: implicit prefix reuse
  (`cached_tokens`) plus `thinking.clear_thinking=false` so replayed
  `reasoning_content` stays in that prefix. This is the GLM chat API,
  not image/video.
- Test ratchet: unit suite 1531.

## v0.0.268 (2026-08-20)

- Cerebras Inference is a built-in OpenAI-chat provider (`CEREBRAS_API_KEY`,
  `graff key set cerebras …`, default `gpt-oss-120b`). Live `/v1/models`
  overlay; this is `api.cerebras.ai`, not the WSE CSL SDK.
- imagegen's Codex engine uses a private features-only `config.toml` so
  `codex exec` no longer dies with `input contains invalid characters at
  line 1 column N` from the user's MCP/skills overlay (#576).
- `/resume` restores the peer-channel byte cursor and parked inbox instead
  of replaying the last 10 room lines (ADR 0014). Peer wakes are not a
  human turn for title or meaningful-state.
- Directory listing is `codedb list_dir` (in-process BFS, gitignore, 10k
  cap), not a new always-on catalog tool (ADR 0013).
- Custom subagent files can be Codex-shaped TOML: `name`, `description`,
  `developer_instructions`, plus `model` / `model_reasoning_effort` /
  `isolation` / `tier`. Loaded from `~/.codex/agents`, `~/.harness/agents`,
  `.codex/agents`, and `.harness/agents` (a graff file of the same name
  wins). Markdown frontmatter still works; `/agents promote` still writes
  `.md`.
- Foreground bash streams as `bash_output_chunk` frames (16 KiB) onto a
  raw terminal buffer, not the prose stream. Background jobs inject a
  grok-build-style completion wake at the next step and, in the TUI,
  start a turn while idle. Do not poll.
- `ask_user` pasted images reach the next model request as real vision
  blocks (a follow-up user message after the text tool result). Nine
  `[Image]` placeholders with no pixels was #580. If nothing staged, the
  tool result says so and names path / paste-text / next-prompt fallbacks.
- Compaction and emergency trim stop before an unresolved current user
  prompt and keep its image blocks verbatim (#581). A retry does not move
  that cut. If the live prompt is the whole history, compact fails
  explicitly instead of summarizing attachments to text. Traces emit
  `compact_cut` with the boundary and preserved image count, not pixels.
- Test ratchet: unit suite 1486.

## v0.0.267 (2026-08-19)

- Background jobs wait like grok-build: `bash_output(wait_ms>0)` and
  `agent_output(wait_ms>0)` block until exit (10h cap), not until the
  next byte or 30s of silence. The old 1–30000 poll values are promoted
  to that cap so a `gh run watch` loop is one tool call, not hundreds of
  model hops (ADR 0010).

## v0.0.266 (2026-08-19)

- Peer talk is pull, not a second copy of the room: `peer_message
  action=list` / `action=inbox` parks bodies in a ring and injects one
  `[peer]` wake line. Named pings are DMs to the agent doing the work
  (ADR 0004).
- `--goal` / `/goal` is one `[standing goal: …]` prefix line. The long
  coaching essay injects on first sight and on change only — not every
  N turns (ADR 0005). Bundled `jspace` skill stays on-demand.
- Mid-session worktree switch is a real `workspace` tool (`action=list` /
  `action=use`). A skill cannot move file-tool cwd (ADR 0006).
- Plugins and foreign MCP are read in place (ADR 0007): Cursor / Claude /
  Grok / Codex trees, Claude `commands/*.md`, no copy into `~/.codegraff`.
  `cache/` is never walked. Claude/Cursor cache comes from
  `installed_plugins.json`; Codex from `~/.codex/config.toml`
  `[plugins."name@marketplace"]` → `plugins/cache/<mp>/<name>/<ver>`.
- Prompt-cache max: the skill catalog is names + triggers only, sorted,
  pinned once at session start, no `file:` paths. Bodies load on
  `skill name=`. GPT-5.6 OpenAI Platform marks the stable instructions/tool
  prefix explicitly for 30-minute reuse; Codex and xAI remain on their
  supported keyed automatic-cache paths (ADR 0009).
- Cache creation tokens are tracked separately from reads and ordinary input,
  including the documented 1.25× GPT-5.6 and Anthropic write price.
- Path confinement, transport, score filing, and terminal mode lifecycles now
  have executable state-machine references with matching Lean proofs.
- `install.sh` appends `~/bin` to the login shell so `graff` is on PATH.
- Synthetic long-horizon evals (`evals/long_horizon/`) grade with
  external deterministic checks (ADR 0008).
- Test ratchet: unit suite 1444. `GRAFF_NO_PLUGINS=1` still hides
  foreign trees.

## v0.0.265 (2026-08-17)

- The TUI is clickable everywhere it looks clickable: a click on any picker
  row (models, files, themes, settings, effort, jump, the slash menu) moves
  the highlight and a click on the highlighted row confirms it, exactly like
  Enter. Clicking the backdrop around a panel dismisses it. The scroll thumb
  is live: click the gutter to seek, hold and drag to scroll. A motionless
  click never starts a copy, and a drag never toggles a fold.
- Overlays draw as proper panels: a framed, docked pane with the title in
  the frame, so pickers read as surfaces instead of floating text.
- `/models` finally says who serves each model. Every picker row and the
  REPL table show the provider plus a cost badge (plan, credits, api,
  local), search matches provider names, and picking one of two same-named
  models switches to that row's provider, not the first name match. Codex
  on your ChatGPT plan and the same model on a metered OpenAI key are now
  visibly different things.
- Prices and context windows refresh from the community LiteLLM price
  database (cached a day in `~/.codegraff/prices.json`, `GRAFF_PRICES_PATH`
  overrides). The baked table remains the offline floor, canonical vendor
  rows outrank reseller copies, and codex context caps are untouched.
- New sandbox seam: `/snapshot attach` puts a Docker container under the
  session, `/snapshot` captures its filesystem, `/rewind <id>` restores it,
  and `/snapshot list` shows what you have. The tarball streams disk to
  disk without entering memory, and the conversation log is never rewound
  with the sandbox. `/rewind <number>` still rewinds the conversation.
- Test substrate: three new live probes (clicks, model picker, overlay
  panels) join the tier 1 gate; the suites grew to 1400 unit and 415 TUI
  tests.

## v0.0.264 (2026-08-17)

- The frame painter now guarantees screen == frame: rows that measure full
  are erased before they are written, every repainted row re-establishes its
  own style, no frame row can exceed the screen's width or height, and a
  latched SIGWINCH plus an idle self-heal repair anything that repaints the
  terminal behind graff's back. stderr is parked on `.graff/tui-stderr.log`
  while fullscreen, so nothing can scribble on the alt screen.
- Scrolling is 120fps-class: the transcript is laid out once and scrolled as
  a slice (frame build p95 0.23ms on a 10k-line transcript, ~78x faster), a
  one-line scroll emits one hardware scroll plus the exposed rows, and wheel
  storms coalesce to one paint per 8ms with typing echoed in under 30ms
  throughout. A 500-report burst settles in 3 paints.
- Tool folds read like sentences: "Reading 2 files…" counts up while the run
  streams and settles to "Read 3 files", with a ›/⌄ disclosure chevron, an
  indented card gutter when open, and a brief settle flash when the run
  finishes. "Called N tools" survives only for mixed runs.
- Clickable rows look clickable: the row under the pointer takes a hover
  tint one step off the canvas (text untouched) and restores on leave. A
  double click is one net toggle on a fold header, and a double click on the
  sticky prompt pin jumps the viewport back to that prompt.
- A scroll position thumb rides the right edge while scrolled and fades at
  the tail, and drag-copy also reaches the terminal's own clipboard via
  OSC 52, so copying works over SSH. Both respect the selection band.
- Drag-selection copies text rows only: blank screen padding contributes
  nothing, leading/trailing blanks drop, an interior blank run collapses to
  one empty line, the toast counts text rows, and a drag over nothing leaves
  the clipboard untouched.
- A width resize keeps your place: the entry on the top visible line is
  re-anchored after the rewrap, and height changes keep bottom-follow while
  tailing.
- Unified diffs in tool results and ```diff fences render with add/delete
  background bands that survive wrapping without bleeding into the next row.
- Streaming markdown is boundary-proof: carriage returns, raw escape
  sequences from the model, and UTF-8 glyphs split across deltas are held or
  stripped, so a chunked answer always lands on the one-shot render.
- Every animated chrome glyph is pinned to one terminal column, and an open
  picker or slash menu owns the wheel, one item per notch.
- Compaction on the Responses route (codex/OpenAI) now defaults to the
  server-side path for every install: the A/B concluded recall-safe, so the
  bucketing is retired. GRAFF_SERVER_COMPACT=0 still forces the client
  summary, and the near-the-wall client fallback is unchanged.
- Testing: a stdlib-only virtual-screen pty harness (scripts/ptyharness.py)
  renders the byte stream into a cell grid and can corrupt the screen behind
  the child to prove self-healing; fourteen live pty probes now gate tier-1,
  and the spec corpus grew GoalLoop and PromptCache process kernels.

## v0.0.263 (2026-08-17)

- grok-4.6 is the xAI default: 500k context, compact at 400k, published
  dual-band prices (`$2/$0.50/$6` under 200k prompt tokens, `$4/$1/$12`
  at or above). SuperGrok login stays $0; metered `XAI_API_KEY` uses the
  bands. grok-4.3 is unchanged.
- `/effort low|medium|high|xhigh` now applies on native Grok. The default
  Responses wire already sent `reasoning.effort`; the UI no longer claims
  the model ignores it, and `GRAFF_XAI_WIRE=chat` sends `reasoning_effort`.
  `grok-build` via the Codegraff gateway still rejects the hint.
- Prompt-cache affinity is durable per project: a new session in the same
  cwd reuses `prompt_cache_key` / `x-grok-conv-id` instead of minting a
  process-local id.
- TUI: crash/suspend/panic restore the terminal; SIGTSTP no longer livelocks
  a background op; in-app drag selection copies on release; quit cancels and
  settles the live turn before leaving fullscreen.
- The TUI is a real client of the REPL engine now. Tool rows come from the
  engine's typed events instead of re-parsing rendered text (no more phantom
  tool rows when an answer starts with a status glyph), `/thinking` actually
  streams reasoning, and denied tools, notices, and provider failovers show
  up in the transcript.
- `/plan` and `/strict` are enforced, not footer labels: plan mode denies
  writes and `!` commands through the engine's own gate, and `!cmd` runs
  under the same approvals, hooks, and accounting as the model's bash tool,
  with its output entering the conversation.
- The session conversation lives in the engine across turns, so a follow-up
  request carries the previous turn's tool calls and results, and provider
  prompt caching works again. `/context` and `/session-info` report the
  engine's token meters instead of local character counts.
- Input hardening: a split or unterminated bracketed paste recovers (bounded
  holds everywhere, a resting mouse can't stall it), lost escape-sequence
  debris no longer types itself or eats the next word, the kitty numeric
  keypad works, and Ctrl+D quits from an empty composer.
- `/models` pings every keyed provider catalog live on each listing, so new
  gateway rollouts appear without a restart.
- Structured outputs reach Anthropic (schema as a tool) and survive DeepSeek's
  json_schema reject by degrading to a `structured_output` tool.
- Conformance corpus grew to ten Lean kernels (3,642 cells). TUI pty
  lifecycle guards joined tier-1, and the README documents the full
  54-command catalog.

## v0.0.262 (2026-08-15)

- A formal conformance corpus now guards the harness's decision procedures:
  six Lean kernels (tool catalog, transport, provider table, goal loop,
  path confinement, routing shapes) prove the invariants, an executable
  reference model exports every reachable cell (1,770 of them), and
  `zig build test` diffs the live implementation against the export —
  a wrong flag combination fails with the exact counterexample cell.
  `scripts/eval-spec.sh` runs the whole triangle offline; `lake` is
  optional and never on the test path.
- TUI `/compact` now runs the engine's real compaction (same summarizer as
  the REPL) instead of silently cropping to the last few rows; the model's
  context and the transcript finally agree about what survived.
- Thinking no longer pulses the transcript: the flickering live bar is gone
  from every collapsed "Called N tools" row; liveness is the pending row's
  steady bar and animated dots.
- Split escape sequences get a second hardening pass: the input loop now
  waits ~500ms for a truncated sequence's tail (slow ssh/tmux links
  complete instead of losing input), and only then drops it — still arming
  the orphan-debris sweeper. An unterminated OSC/DCS introducer (Alt+] in
  meta-sends-ESC terminals) recovers the text typed behind it instead of
  wedging the keyboard until it is destroyed (#516), and a buffer-filling
  wedge can no longer masquerade as a TTY hangup that exits the TUI
  mid-session (#517).
- Mid-turn safety: /new, /compact and /rewind are refused while a turn is
  running instead of wiping history under the live job (#521); the
  slash-menu selection clamps to the filtered list and scrolls with the
  highlight, so Enter always fires the row you see (#522); steering can no
  longer strand a permanent "thinking" row (#520).
- Raw mode clears IEXTEN and IXON: Ctrl+V pastes as advertised and Ctrl+S
  cannot freeze the whole TUI (#523).

## v0.0.261 (2026-08-15)

- The TUI looks and behaves like grok-build where it counts: syntax-highlighted
  code fences (grok-night/grok-day token colors on a full-width band, hidden
  markers), a sticky header pinning the prompt you scrolled past, automatic
  light/dark from the terminal's reported background, and flicker-free
  synchronized painting.
- Two dozen rendering and input bugs found by a three-pass audit and a live
  visual-capture pipeline, headlined by: a half-arrived mouse-hover report
  could fire a phantom Escape that silently cancelled the running turn and
  then type its debris (`39;7;32M…`) into the composer; the orphan-sequence
  sweeper ate pasted text like `0x1f` and `1e5`; the first `**bold**` made the
  rest of the message bold; emoji and CJK widths bent every box border;
  `/theme` left most rows in the old background; `/jump` hid the very turn it
  jumped to; clicking blank space toggled the last tool run.
- Grok requests carry `x-grok-conv-id` and `prompt_cache_key` on every wire so
  xAI's automatic prompt caching actually hits; WebSocket sessions retire
  before the server's 25-minute cap and classify its error frames instead of
  burning the stall budget. `GRAFF_XAI_WS_CHAIN=1` opts into on-socket
  delta chaining (experimental).

## v0.0.260 (2026-08-15)

- Fixed the composer silently wiping mid-typing: switching apps with Cmd+Tab
  latched a phantom Super modifier (the release went to the other app), so
  the next Backspace acted as Cmd+Backspace and deleted to the start of the
  line. A plain keypress now clears stale modifier latches.

## v0.0.259 (2026-08-15)

- Grok now defaults to xAI's Responses wire: WebSocket turns (with the SSE
  fallback ladder), lossless first-party server compaction, and structured
  outputs work out of the box on a SuperGrok subscription. Set
  `GRAFF_XAI_WIRE=chat` to return to chat completions.
- Fixed duplicate MCP tool definitions when a deferred server start raced the
  eager codedb-pro companion; strict Responses endpoints rejected every turn
  over the duplicate.

## v0.0.258 (2026-08-15)

- Full Grok support on a SuperGrok subscription (#502): opt into xAI's
  Responses wire with `GRAFF_XAI_WIRE=responses` for first-party server-side
  compaction (encrypted blob; measured −80% follow-up input tokens on a 9.3k
  conversation, with the client summary kept as automatic fallback), WebSocket
  turns over the held socket, and `--output-schema '<json>'`/`@file`
  structured outputs on both wires. grok-4.6's stray `<|eos|>` after
  strict-schema JSON is stripped, and structured output runs two-phase — an
  unconstrained agentic run, then one tools-off formatting turn — so a strict
  grammar can no longer talk the model out of using its tools.
- graff-evals: an in-repo, RL-style eval environment — 12 deterministic
  agentic tasks (debugging, shell, git, refactor, long-context recall,
  structured output …) with sandboxed checks; `run.py --harness graff,grok`
  prints a side-by-side pass/wall/latency/token table.
- Kitty keyboard overhaul: the real kitty modifier table (Right-Alt/Right-Cmd
  no longer type Escape), key-release events never double-fire, a stale
  alt/super latch resyncs, and terminal state (kitty pop, alt-screen, mouse)
  is restored even on SIGTERM/SIGHUP. Shift+number punctuation and mouse
  hover for image chips both keep working.
- REPL parity commands from the grok-build gap review: `!` shell prefix, `@`
  file mentions, `/jump`, `/copy`, `/btw`, `/vim-mode`.
- Fewer discovery rounds when a prompt names its target file/symbol (#489).

## v0.0.257 (2026-08-15)

- Composer box corners line up with the sides, wrap at word boundaries, and
  the hint row is clipped so it no longer ends on a stray "E".

## v0.0.256 (2026-08-15)

- Leftover Kitty keyboard CSI (`3u7444;9u`) is ignored instead of typed or
  turned into Escape/Ctrl+C (which cancelled the turn).
- Shift+number keys type the punctuation they should (`Shift+9` is `(`,
  `Shift+0` is `)`), including via Kitty CSI-u and modifyOtherKeys.
- Interrupting a turn collapses Thinking immediately (Grok ❙ + static
  "Thinking"; no leftover spinner next to ■ interrupted).
- The pager appends raw stdin hex to `.graff/tui-traj.jsonl` and the last
  visible frame on exit so the next leak can be replayed.

## v0.0.255 (2026-08-14)

- The fullscreen pager no longer prints raw SGR mouse reports
  (`39;33;23M`) into the thinking line. Hover-motion tracking is off;
  split/orphan mouse sequences are consumed instead of typed.

## v0.0.254 (2026-08-14)

- `graff tui` (and TTY `graff repl`) is a Grok-style fullscreen pager: wrapped
  composer with Ctrl+Z undo, folded multi-tool cards that click open, image
  chips, a searchable effort picker, markdown tables, and a headless Term
  driver for tests. Bare `graff` stays the line REPL.
- `/import-claude` copies Claude/Cursor MCP servers, skills, and hooks into
  `~/.codegraff` and the current repo; first start adopts automatically, the
  command remains for a later rescan.
- Hosted TUI tool rows carry the path or a one-line preview so live `⚙`/`✓`
  lines stay inspectable without dumping raw JSON.
- macOS CLI and desktop assets are Developer ID signed and Apple notarized
  (`notary-local`); the `.dmg` and updater tarball ship beside the CLI
  tarballs.

## v0.0.253 (2026-08-14)

- Explicit `/compact` uses OpenAI's standalone Responses compact endpoint for
  direct API-key sessions and supported in-stream compaction for Codex, with
  transactional history replacement and local fallback; non-OpenAI providers
  remain local-only.
- Measured interactive yolo startup falls from 5.85s to 2.76s—53% less waiting,
  or about 2.1x faster—through Kimi prompt-cache affinity, low-effort lookup
  routing, concurrent live-catalog fetches, and concurrent/deferred MCP startup,
  while preserving deterministic catalog and tool ordering.
- `@codegraff/sdk` ships its platform harness binary and production embedding
  APIs for persistent turns, live events, controls, cancellation, and process
  ownership, backed by packed-install and JSON integration coverage.
- The normal REPL keeps recovered recap retries and verbose tool/startup details
  out of the way; `/debug` provides a content-free HUD, `/usage` reports spend,
  `read_file contains=` handles exact-key lookups in one bounded read, and
  shared-worktree owners render as a structured callout.
- The desktop app replaces the persistent agent overview column with compact
  agent control and adopts the Codegraff emblem across web, desktop, Android,
  and iOS assets.
- Run-budget landing, Codex overload retry, xAI OAuth parity, and benchmark
  fixture validation harden autonomous and release workflows.

## v0.0.252 (2026-08-13)

- Grok models are discovered live: xAI joins the generic `/v1/models`
  catalog and always fetches `api.x.ai` (disk cache is offline fallback
  only), so new Grok rollouts become routable without a release. SuperGrok
  login tokens send `X-XAI-Token-Auth` on chat and catalog requests, matching
  grok-build.
- The #469 peer-message spacing bracket is pinned by a unit test on the
  emitted event sequence, plus a CI-wired PTY smoke test for device-room
  delivery.
- release.yml uploads assets onto an existing release instead of failing
  into an untagged draft (the v0.0.251 updater-404 race).

## v0.0.251 (2026-08-13)

- Peer messages get breathing room in the REPL: the `#469 channel` block used
  to render mid-stream with no spacing, clumped against the text above and
  below; it is now bracketed by a blank line on either side. Render-only —
  history bytes and the GUI are unchanged.

## v0.0.250 (2026-08-12)

- First-party OpenAI server compaction now installs the complete canonical
  `/responses/compact` output transactionally on both the Codex subscription
  and official Platform Responses routes. Missing, invalid, or empty output
  leaves history intact and falls back to readable local compaction; other
  providers remain local-only.
- The official `openai` provider uses the Responses API with ordinary bearer
  authentication, without inheriting ChatGPT backend headers, WebSocket
  chaining, or Codex-only priority behavior.
- REPL tool activity is visible again as stable terse start/result rows with
  human-readable command, path, URL, or description previews instead of raw
  JSON or cursor-rewriting output.
- Controlled replay evidence covers 21/21 perfect continuations across the
  first-party OpenAI host/auth paths, including long paired tool histories.

## v0.0.249 (2026-08-12)

- Folded native tools become callable immediately after their schemas load
  (#492). The active catalog is rebuilt from the loaded schemas instead of
  continuing to advertise tools that can never enter dispatch.
- Turn events expose cumulative input, output, cache-read, and cache-write
  token usage, with the TypeScript SDKs regenerated from the same schema
  source (#491).
- codedb-pro tool paths resolve from the active session worktree rather than
  the daemon's startup directory, preventing false missing-path reports when
  Graff changes projects.
- Piped sessions end an unanswered `ask_user` cleanly at EOF instead of
  spinning or hanging (#478).
- The default prompt carries a capped skills catalog, and the release suite
  now exercises concurrent interactive WebSocket tool loops across multiple
  sessions (#480).

## v0.0.245 (2026-08-09)

- Licensed codedb-pro is now the default toolset, not an ornament. The license
  probe at startup pins the server's schemas eager (no per-session
  `load_tool_schemas` toll that steered models back to the built-ins), the
  system note makes `mcp__codedbpro__read`/`faster_search`/`batch` the stated
  defaults for reads and searches, and the built-ins they replace are actually
  *refused* while the licensed server is healthy: `read_file`, `codedb`, and
  bash lines leading with `grep`/`rg`/`find` get a refusal naming the
  replacement (shell searches point at `zigrep` directly; it always skips
  vendor dirs, so the refusal says when `rg -uu` is the right call instead).
  Plan mode is exempt (it denies MCP calls outright), and any codedb-pro
  failure opens the fallback for the rest of the session — being in charge
  must never leave the model with no working way to read.
- codedb-pro failures file their own bug reports: the first failure per
  signature (cap 3/session, root-only) spawns a background subagent that
  dedupes against open issues and files on justrach/codegraff under the
  `codedb-pro` label. The harness redacts before anything reaches a model or
  the issue body — absolute/home paths, credential-looking tokens, URL query
  strings — keeping only the tool name and the error essence. Unattended
  sessions (or unapproved `gh`) draft to `.graff/issue-drafts/` instead of
  publishing without consent.
- Edits go through the persistent daemon instead of spawning zigpatch per
  edit: `edit_file` keeps the /rewind snapshot and the on-disk verification,
  but the byte-splice rides the always-on MCP connection (measured 0.34ms vs
  2.37ms per edit on small files — fork/exec was ~85% of the cost). A
  measured size gate (4 MiB, matching the daemon's cache ceiling) sends big
  files to the spawn path. Pairs with zigrepper 0.2.21, where the same edits
  got 2.9x faster still (cache-backed snapshots, light edit loads).
- `/tools` shows the session's tool balance: codedb-pro read/search/batch vs
  zigrep vs native fallbacks, gate refusals, and errors. When suite usage
  skews (8+ calls, one class ≥80%), the nudge rides the tool result so the
  model hears it — once per dominant class, not on repeat.

## v0.0.244 (2026-08-08)

- Co-resident sessions see and coordinate with each other (#469): a per-user
  registry at `~/.graff/live` names any live session already in your worktree,
  probed for liveness on read via `proc_identity`, so crashed sessions reap
  themselves — no heartbeats, no daemon. The first index- or tree-mutating git
  command, file write, or shell move against a peer's tree pauses once for a
  deliberate re-issue, under `--yolo` too, where no approval prompt exists. The
  motivating failure: two `--yolo` roots in one worktree picked up the same task
  and one git-staged the other's files mid-write, because neither could see the
  other. Sessions can also talk — the `peer_message` tool, `/tell`, and `/peek`
  over a shared per-worktree room plus a device-wide one.
- Session recaps ride the event stream (#419): a settled turn carries a
  Completed or Needs-input status and a one-line recap, so a GUI overview can
  say what each agent did without re-reading the transcript.
- Subscriptions are billed and routed as subscriptions (#471). A flat-rate
  login and a metered API key on the same provider are different *seats*, and
  nothing in the routing stack knew that: billing was a hardcoded provider-id
  list, the third of four such lists in the tree, and they disagreed. xAI has
  had a real device-code login since `graff login xai`, so a paid SuperGrok
  session was billed at grok list price and excluded from subscription routing
  entirely. Now the plan **outranks** the key on the same provider instead of
  losing to it by arriving second, contributes $0 to `/cost`, and the displaced
  key is parked — taking over, announced, only when the plan hits a quota cap.
- Worker tiers land on seats you already pay for (#471): an explicit `tier` ask
  crosses to a logged-in plan (`mid` → k3, `small` → gpt-5.6-luna) rather than
  a metered rung. The #291 ladder descent had been blocking this by looking
  like a manual pin, which made subscription routing dead in most sessions —
  found by running the harness for real, not by the unit suite.
- A tier rung must be a genuinely cheaper SEAT (#471): the bench sheet ranks by
  $/task, which folds the seat's rate together with how many tokens a model
  burns, so an equally-priced older model read as the cheap rung. Every opus
  generation bills $5/$25, so descending opus-5 → opus-4-8 saved nothing at
  all. Anthropic now descends opus-5 → sonnet-5, deepseek-v4-flash replaces pro
  outright, and a mid rung that cost *more* than its own frontier is gone.
- `graff route` with no model lists every provider you can reach, what it
  bills, and the tiers it offers — including a plan whose displaced key is
  parked behind it. Detection stats the credential file only: listing providers
  never refreshes a token or spends anything.
- Anthropic serves its live model list, like the OpenAI routers: new Claude
  releases arrive without a rebuild, with the baked rows kept as the
  no-key/offline fallback.

## v0.0.242 (2026-08-06)

- MCP tool schemas load on demand (#416): a server's tools are advertised by
  name and one-line description, and `load_tool_schemas` fetches the full JSON
  on request, once per session. On a real 13-tool server the served catalog
  drops 10,505 → 3,696 bytes, a 64.8% cut and roughly 1,700 input tokens off
  every request for the whole session. Servers under 4 KiB of schema stay eager,
  so small servers behave byte-for-byte as before and only the expensive ones
  change. Trust and consent are untouched — deferral is about context cost, not
  permissions.
- Tool results above a threshold return a handle instead of their contents
  (#440): a bounded preview, the path holding the complete result, the byte
  count, and a measured shape hint (line count, or a JSON payload's top-level
  keys). This replaces a three-cap stack in which the middle cap made the outer
  one unreachable, so the #409 spill could never fire for bash, read_file,
  webfetch or codedb. The bash capture ceiling rises 128 KiB → 1 MiB, since at
  the old value the handle would have described a result already a quarter
  destroyed.
- The session transcript is append-only (#441). The premise shipped in #410 was
  false: `<name>.session.json` is one JSON object whose history is rewritten in
  place, so compaction permanently discarded it. A new
  `<name>.transcript.jsonl` records each message as it first enters history and
  is never rewritten, which makes "what did that error say exactly?" a grep
  again. At its size cap the generation rotates by rename rather than being
  truncated in place — an in-place rewrite is the very failure this fixes.
- Compaction now says what survives, on both sides. Before the boundary the
  agent spends one budgeted turn writing notes to its future self (#391),
  drawn from the same ledger as the landing reserve rather than a second one,
  and refused outright when the session is already being rescued. After it, a
  note states the durable state that actually persists: active goal and todos,
  files modified this session, the transcript path, and any live result handles
  (#411).
- The durable-transcript prompt line waits for the first compaction (#445).
  Before one, the live context is a superset of the file, so the line pointed
  the model at wording it could already see; the measured cost was ~240 input
  tokens on every call. Short sessions, which is most of them, now pay nothing.
- **Windows: the transcript wrote nothing at all** (#441). `File.stat` on a
  write-only handle returns `ACCESS_DENIED` there, so the append offset lookup
  failed after the file had been created and every transcript was 0 bytes. The
  same pattern is still live in `playbook.zig` and `serve_events.zig`, tracked
  in #462. `.graff/` paths are forward-slashed on every platform by invariant,
  since those strings are shown to the model.
- The `anyOf` test failure was never a flake (#444). The build runner prints a
  full step-failure report for a *successful* step whose stderr is non-empty,
  and records `failed command:` before the child's exit status is known. Cached
  test steps do not re-run the tests, so "warm re-runs passed" was vacuous and
  seed-independence followed for free. Engine stderr is now silent in test
  builds and the suite emits zero bytes.
- Engine/REPL separation reached the lifecycle and long-tail clusters (#429):
  `session_start`, `session_run`, `providers`, `hooks`, `skills`, `skill_docs`,
  `review`, `imagegen` and `agent_prompt` no longer import the terminal.
  `session_run.zig` fell 597 → 450 lines, relieving the cap pressure the epic
  predicted it would. The inventory also found that `approvals.zig` was on the
  ban list as a consent surface rather than for any terminal coupling, so its
  pure half moved to `harness_policy.zig`.
- `/btw` asks a side question over the live conversation with tools disabled,
  renders the answer, and adds nothing to the session (#415). It is billed in
  the `[usage]` footer, because the cost is real even though the exchange is
  not kept. There are two persistence paths to stay out of now — the session
  file and the new append-only transcript — and both are asserted byte-for-byte
  before and after. A `{"type":"btw"}` `--json` control replies with an explicit
  `persisted:false` so a client mirroring the stream can tell it apart from a
  real turn.
- A GUI panel answers "what are my agents doing" without opening each
  conversation, sorted attention-first (#419).
- Child usage is pinned to the bill and kept out of the parent's context math
  (#418). The audit found no leak — a subagent gets a fresh `Agent` whose meter
  starts at zero and a `ToolCtx` with no pointer back to the parent, so it has
  nothing to write to — and the invariant is now held by a test rather than by
  construction alone: eight workers each ending past the parent's compaction
  threshold leave the parent's context estimate identical to the control, while
  the bill moves by exactly their usage. Had it leaked, compaction would fire
  early on every fleet-heavy run.
- Two eval harnesses became durable rather than living in scratch: the live A/B
  token-economics rig that produced the numbers above, and the golden
  byte-identity harness the engine work is verified against.
- Two silent-failure classes gained guards, each proven by break-and-revert: an
  environment knob that stops being parsed now fails a test instead of quietly
  ceasing to exist, and the prompt funnel can no longer arm a process-global
  from a test build.

## v0.0.241 (2026-08-06)

- The engine separation reached the tool-execution cluster (#422): tool-call
  announcements, results, rejections, parallel-batch brackets, and the
  goal/todo notices now travel the typed event stream, with the inventory
  finding that only `agent_tools.zig` ever wrote to the terminal — the rest
  of the cluster was already clean. The wire sink is now provably unable to
  ship a shapeless durable event or reserve sequence ids for a frontendless
  agent.
- A WebSocket 426 refusal latches SSE immediately (#427): the server answered
  authoritatively, so the session falls back on the same attempt instead of
  burning a rebuild and a redial before the two-failure latch.
- The tier-1 gate counts tests off the compiled artifact when a cached build
  prints no summary, selects the reachability binary by content instead of
  mtime, and warns when its test-count ratchet goes stale (#439).
- The system prompt is now assembled from capability-gated segments (#421):
  an instruction ships only when its capability is actually present, read
  from the same predicates dispatch uses to refuse a hallucinated call, so
  the prompt can never disagree with the tool catalog. An embedder session
  (`--no-local-tools`) drops 28.5% of the base prompt; the floor config
  drops 43.2%. At full capability the compose returns the comptime constant
  itself — zero allocation, byte-identical to what shipped before. Two
  standing doctrine lines joined the always-on intro: never invent a tool or
  wrapper API, and run the target project through its OWN environment — a
  failure there is the relevant result.
- A durable root session's prompt now names its own transcript (#410): the
  path to `.graff/sessions/<name>.session.json`, described truthfully — one
  JSON object, lags the live turn, rewritten in place by compaction (a
  resume artifact, not an append-only archive) — so the model can consult
  it without burning turns on wrong assumptions. Suppressed when local
  tools are gone (an unreadable path is pure token waste).
- Context-overflow classification got a guard list and two behavioral
  detectors (#414). Non-overflow patterns are now checked FIRST, so a
  throttle whose wording collides with an overflow phrase — Bedrock's
  `ThrottlingException: Too many tokens` is the canonical one — keeps riding
  the Retry-After ladder instead of triggering a compaction that cannot help.
  The overflow table itself grew from six substrings to the phrasings twelve
  more providers actually send (Bedrock, Gemini, Copilot, xAI, Groq,
  llama.cpp, Kimi, Mistral, Ollama, MiniMax, z.ai, Anthropic 413), and now
  matches case-insensitively. Two shapes that never send an error at all are
  caught from the reported usage instead: an HTTP 200 with an empty
  completion whose input is at or over the window (z.ai's silent overflow),
  and `finish_reason: length` with zero output while the input fills the
  window (a provider truncating the input to fit, seen on MiMo) — the latter
  is now named rather than shipped as an inexplicably short answer.
- An oversized tool output is now spilled, not destroyed (#409). The
  per-result cap (#193/#201) used to delete the elided bytes, leaving the
  model to re-run the tool and guess a better slice; when the session is
  durable the full output is now written to
  `.graff/sessions/<session>/artifacts/tool-<n>.txt` first, and the marker in
  the transcript cites the absolute path and the byte count, so the next turn
  can read or grep exactly what it needs. Bounded by a 64 MiB per-session
  budget (whole artifacts only, so a marker can never overstate what is on
  disk), and reclaimed with the session: an artifact dir whose
  `<session>.session.json` is gone is swept at the next spill. Subagents,
  whose history is never persisted, keep the plain truncation.
- Cross-process locks stopped trusting a bare pid (#413): an owner record now
  carries the holder's process START identity next to its pid (`/proc/<pid>/stat`
  field 22 on Linux, `proc_pidinfo` on macOS, `GetProcessTimes` on Windows), so
  liveness is "the pid is alive AND it is still the same process". A recycled
  pid can no longer look like a live owner forever, and a crashed holder's lock
  is reclaimed because its identity provably mismatches rather than because a
  timeout guessed. A record written by an older graff carries no identity and
  keeps the pid-only contract exactly as before, so an in-flight lock is never
  bricked, and an identity that cannot be read fails safe: held, never stolen.
  The #320 worktree lease gets the producer it was missing, and a session save
  on a filesystem with no working locks (#289) now coordinates through an owner
  record instead of racing unguarded.
- A no-progress `eval` is no longer paid for (#412). A goal/loop run
  re-verifies on every continuation, so a model that has edited nothing since
  the last RED re-ran the whole `--eval` command — plus a `--judge` model call,
  plus 1500 bytes of output tail — to re-derive a verdict that could not have
  changed. graff now fingerprints the verification before running it (the eval
  command text, `git status --porcelain -z -uall`, `git diff --binary HEAD`,
  and the contents of every untracked file, since the first two are blind to an
  untracked edit); identical to the tree the last verification failed on means
  the verifier is not run at all. The attempt still counts, so a stuck loop
  converges on its iteration cap instead of spinning for free, and the model is
  steered at the real blocker: the workspace has not changed, edit something
  first. Fail-open throughout — no repo, no git, a timed-out or truncated
  probe, an unreadable file all read as "changed" and the verifier runs.

## v0.0.240 (2026-08-06)

- The REPL/engine separation began (#422): agent output now flows through a
  typed event vocabulary and a strict sink boundary (`engine_events.zig` /
  `engine_sink.zig`), with streamed model output, the codex WS transport
  notices, and streamed tool-call arguments converted first — the TUI
  renders and the `--json` wire serializes the same events, so the two can no
  longer drift. Proven byte-identical to v0.0.239 by a golden before/after
  eval harness (the same scripted mock session over both the protocol and a
  real PTY) plus live one-shot, tool-call, and interactive smoke runs.
  Groundwork for detached sessions and attach (#420).
- Loop exit tears down the held codex WebSocket and its response-id anchor
  (#424): the delta chain deliberately spans user turns, so only exit may
  free them — and no exit path did. The socket now gets a proper close on
  quit, and Debug builds finish with a clean allocator report instead of
  four leak stacks.

## v0.0.239 (2026-08-06)

- A successful `/login` now reaches the live session (#402): the codex
  `.responses` error path runs the same bounded auth recovery as every other
  wire format — re-read `auth.json` from disk first (adopting a re-login by
  this session, a second graff, or the real codex CLI, gated on the ChatGPT
  account id), then spend the refresh token, then retry once — instead of
  resending the full request + compaction bodies with a dead bearer forever.
  One `$CODEX_HOME` resolver serves every reader and writer of `auth.json`
  (subagents included), and the mid-turn refresh persist preserves the fields
  the codex CLI owns in that co-owned file, 0600, staged + renamed.
- `/save <name>` and `/resume <name>` copy the typed name out of readline's
  reused line buffer; the next prompt can no longer silently retarget the
  autosave (or worse) via a stale slice.
- `/rewind` never deletes a file it failed to snapshot: a pre-write read
  failure (oversized, unreadable) now records "no snapshot" and rewind leaves
  the file as-is with an honest count, instead of conflating read failure with
  "didn't exist" and unlinking it.
- `graff serve` no longer wedges permanently on `set_ultracode`: the ultracode
  ack is a terminal event, the ack list is pinned against the emitter by test,
  and the JSON-controls E2E covers it.
- Credential and catalog writes are atomic (staged temp + rename via a shared
  writer): a crash or full disk can no longer truncate the only copy of a
  refresh token. xAI credentials now land 0600/0700 like kimi's; the MCP OAuth
  store and the multi-provider key map write through the same path.
- Codex WebSocket turns no longer sit silent for minutes when the backend goes
  quiet mid-response. The WS reader armed its stall watchdog with a hardcoded
  "no tokens yet", so it re-armed the full 120s pre-first-token budget on every
  frame and never tightened once the model was actually emitting — the SSE
  reader has always tightened to a quarter. Silence after visible prose now
  trips in ~30s, while a silent reasoning phase keeps the full budget, exactly
  as on SSE. "Visible prose" means both things that print on SSE: a
  `response.output_text.delta`, and the streamed arguments of `attempt_completion`
  / `ask_user` — which is all a final-answer turn emits, so keying on output
  text alone would have left the commonest turn shape on the old budget. Mere
  frame arrival is still not the signal: the protocol events land milliseconds
  after the send and would stall out a long thinking turn. The trace gains
  `sent <n>b`, `first frame` and `first output text` notes, so a hang says which
  half of the turn went quiet instead of stopping dead at `reuse (delta)` (#401).
- A REUSED codex WS that answers nothing is now caught in ~30s instead of ~120s,
  and as a transport failure rather than a stalled turn. Nothing proves a held
  socket is still alive, and the backend acks a send within milliseconds, so
  zero frames back is a dead socket: it gets the head budget and re-anchors on a
  fresh connection (SSE only after a second failure), instead of spending a slot
  of the turn's stall budget waiting out the full pre-first-token window. A
  freshly dialed socket is unaffected — its handshake just proved the peer is
  there, so it keeps the full budget for a model that thinks before it speaks.
- The WS send and dial are under a deadline too (an unbounded blocking write /
  an unbounded dial through DNS + TLS + the 101 status line), with Esc live
  during both. They report the transport-flake error the SSE guard uses, so a
  wedged socket is retried on a fresh one rather than spending the turn's stall
  budget; the send deadline scales with the frame so a full-conversation
  re-anchor is not a false positive. Both name themselves in the trace
  (`send stall` / `connect stall`), so a stalled dial is no longer reported as a
  bare error name. Under Io-pool exhaustion they follow the SSE guard exactly: a
  failed payload spawn fails retryable, a failed watchdog spawn degrades to the
  unwatched call already in flight, so a momentary pool shortage cannot latch a
  session onto SSE. A socket the idle window condemns is torn down with a plain
  FIN rather than a courtesy close frame that could block again, and a failed WS
  handshake no longer leaks its fd and CA bundle.
- A one-shot that dies (budget exhaustion, a late gateway refusal) still prints
  the `[usage]` footer and notes how many tool calls already completed — the
  runs most likely to be expensive no longer exit with no cost accounting, and
  an aborted run no longer reads as if nothing happened (#387, #389).
- Rate-limit errors that say "try again in 350000 seconds" now append a human
  duration ("~4d 1h"). The provider's exact words are preserved — the hint is
  display-only (#398).
- Auto-compaction escalates instead of looping when the model keeps returning
  empty summaries: two consecutive complete-but-unusable summaries over the
  threshold unlock the bounded emergency trim, and compaction summary requests
  run at low reasoning effort so a high-effort reasoner can't complete with
  reasoning items and no summary text (#379).
- iOS simulator scripts clean up what they start: the app is terminated and a
  device is shut down when (and only when) the run booted it; the Simulator
  window no longer pops open unless `SIM_GUI=1`, and `KEEP=1` preserves
  everything for debugging (#407).

## v0.0.238 (2026-08-05)

- Tight-budget runs hold back a landing reserve, so they finish, verify, and
  still deliver the final answer instead of dying mid-narration.
- A completed run releases the terminal instead of suspending on tty input
  (#396), and worker activity lines wait for the foreground's line boundary.
- Completed todo items parked from a prior goal retire at the next ask instead
  of piling up across prompts (#394).
- Fleet workers retry transient failures within a bound — one flaky HTTP
  response can't lose a finished report, and budget refusals never blind-retry.
- Search roles ride the small rung; landed turns feed local learning, and a
  learned decline names the policy it came from.

## v0.0.237 (2026-08-04)

- Ultracode redesigned around an escalation ladder: the codeword now means
  "escalate to the smallest rung that fits" — solo for 1-2 known files, one
  scout for context-flooding exploration, a fleet only for 3+ independent
  workstreams or after a failed attempt, full shape + judges only for
  audit-class asks. An admission gate + budget reservation ledger enforce it;
  duplicate briefs collapse at spawn; implement phases carry an edit contract
  (no diff = error + retry); every rung decision writes `kind:"orch"` rows so
  the ladder itself becomes learnable. Measured on the 5-eval study that
  motivated it: old ultracode 80 mean at 133 calls; new: 100 mean at 44 calls
  (1.22x the single-agent baseline), zero budget deaths, and a genuinely large
  audit task still fans out (R3, 4 workers) then lands from partial evidence.

- Vision-aware worker routing: a subagent task that names an image file
  re-seats automatic workers onto a vision-capable model (`source=vision-ask`
  in the routing trace); a worker report that disclaims image-viewing gets a
  `[vision warning]` flag the root cannot mistake for observation (#380).
- Brief-diversity gate: fanning out 3+ near-identical variant briefs (workflow
  phases or sibling spawns) draws a calibrated warning — reskins of one
  template are one concept, not N. New `concept-fleet` shape requires a design
  thesis and one signature system per variant (#382).
- Durable user-constraint ledger: `/never <text>` (or the model calling the
  append-only `note_constraint` tool when you reject something) writes to
  `.graff/playbook.jsonl`; a `HARD CONSTRAINTS` block derived from the file at
  brief-assembly time rides every worker brief and the root prompt — surviving
  compaction and session boundaries by construction (#381).
- Learned playbook (ACE-style): after a target-met eval, one bounded
  reflection call mints up to 3 insight bullets with run provenance, curated
  by deterministic code (dedupe, caps, tombstones — never model rewrites) and
  injected as an advisory block below user constraints (#383).
- The long-standing ubuntu pty CI flake was never a shutdown hang: a Ctrl-D
  arriving in a canonical-mode tty window is delivered by Linux as NUL and was
  dropped by readline — the REPL then (correctly) waited forever. Type-ahead
  bytes are now normalized across the mode switch; 15/15 container hangs
  became 25/25 passes. Teardown phases are stamped under
  `GRAFF_SHUTDOWN_DEBUG` so any future hang names its phase (#364).

## v0.0.236 (2026-08-04)

- Every spawned worker emits a routing trace — shape, role, tier, resolved
  model, and *why* (explicit-pin / persona / learned-policy / session-default
  / ladder) — to the tracer, the local archive, and a new `agent_route` JSON
  event (#372).
- Learned tier policy: scored runs teach (shape, role) cells which model to
  seat; a learned answer must dominate the ladder's (≥ quality, strictly
  cheaper) and explicit pins always win (#372). Workflow phases take one
  learned seat before fan-out, and fitness is stratified by resolved model so
  genome comparisons never mix rungs (#376).
- Family-prefixed model spellings route to the direct provider: `--model
  kimi-k3` now bills the flat-rate kimi login instead of silently seating the
  gateway (#377).
- `graff route <model>…` dry-runs provider seating + billing in ~2s with zero
  API calls, through the same resolution a real session uses.
- `graff acp`: Agent Client Protocol agent mode over stdio JSON-RPC — point
  Zed's agent panel at the binary (#375, ACP half).
- Blocking pre_tool hooks can name their sanctioned replacement via a
  `suggest` field, and hooks got their first README documentation (#369). SDK
  generation is deterministic by construction — a scrubbed HOME, so local
  catalog caches can never drift the committed MODELS list (#370).
- Longer notes: [docs/releases/v0.0.236.md](docs/releases/v0.0.236.md).

## v0.0.235 (2026-08-03)

- Eight defects found by turning the harness on itself, fixed same-day with
  live verification: honest eval-score parsing with exit-code fallback
  (#367), budget exhaustion that names what ran out and what state survives
  (#368), unattended denials that explain themselves (#369 first half), a
  hard gate on the model editing `.harness/settings.json` (#366), `/model`
  re-deriving the worker ladder (#371), Pareto-front rung seating so no tier
  is dominated by a cheaper one (#373), DGM score feedback re-weighting the
  bench sheet (#374 follow-on), and pty/autosave test reliability (#364/#365).
- Longer notes: [docs/releases/v0.0.235.md](docs/releases/v0.0.235.md).

## v0.0.234 (2026-08-03)

- The local evolution loop closes: eval scores land in the local trajectory
  archive, a target-met new best auto-promotes the niche champion and
  hot-reloads it mid-session, and VERIFIER RED grants a bounded in-loop
  repair turn instead of scoring an honest run 0.
- Worker economy: compiled bench priors seat per-provider tier ladders,
  logged-in flat-rate subscriptions outrank metered models for tier asks, and
  workers never silently cost more than the model you chose. Personas gain
  independent `effort` pins ("Luna Max" = `model: gpt-5.6-luna` +
  `effort: max`) (#291/#292).
- Codex-parity system prompt upgrade; plan/todo discipline verified against
  it.
- Longer notes: [docs/releases/v0.0.234.md](docs/releases/v0.0.234.md).

## v0.0.233 (2026-08-03)

- iOS stops inventing outcomes: per-turn outcome in the transcript, liveness
  that never fabricates success, ordered per-session sync with revision
  guards and tombstones (#286, #310, #316).
- MCP companion only falls back to the legacy protocol on a real refusal, with
  a cold-start-safe probe timeout (#327). GUI emphasis pairing fixed so `**`
  can no longer leak into linkified URLs (#197).
- Incremental autosave (#273) and per-spawn worker model pins (#292) land.
- Longer notes: [docs/releases/v0.0.233.md](docs/releases/v0.0.233.md).

## v0.0.232 (2026-08-03)

- `imagegen`: image generation the model can't fake — fresh-artifact
  verification (mtime, magic bytes, size floor) after Codex was caught
  fabricating success from a stale file; exit 0 with no fresh artifact is a
  hard error (#352).
- Clipboard paste failures become honest and usually recoverable; MCP tool
  schemas with top-level `oneOf`/`allOf`/`anyOf` are lowered instead of
  rejected wholesale.
- Longer notes: [docs/releases/v0.0.232.md](docs/releases/v0.0.232.md).

## v0.0.231 (2026-08-01)

- `edit_file` now verifies every edit actually landed on disk before reporting
  success: a silent no-op becomes a loud tool error instead of a false
  "replaced 1 occurrence(s)" (#337, #338).
- Batched edits to the same file are serialized per path, fixing a race where
  parallel tool calls could erase each other's writes (#338).
- Embedder mode part 1: a hard `--no-local-tools` / `GRAFF_NO_LOCAL_TOOLS=1`
  gate disables local bash/file/codedb tools for the whole process, subagents
  included, so coding tools can come from a sandbox MCP server instead (#330,
  #335).
- Embedder mode part 2: resumable `graff serve` streams with monotonic `seq`
  ids, `?from=N` replay after a dropped connection, and durable sessions.
  `--json` schema 0.10 (#330, #336).
- Longer notes: [docs/releases/v0.0.231.md](docs/releases/v0.0.231.md).

## v0.0.230 (2026-08-01)

- The bundled `skill-creator` skill teaches the full authoring loop: capture
  intent from the live conversation, write trigger-rich descriptions,
  forward-test with fresh subagents against baseline runs, and iterate on user
  feedback until it comes back empty (#334).

## v0.0.229 (2026-07-31)

- SKILL.md skills: drop a markdown playbook in `.harness/skills/<name>/` (or
  `~/.harness/skills/` for every project) and graff loads it only when a task
  calls for it. Only name + description enter the system prompt;
  `.claude/skills/` is read for compatibility; `/skills` lists, hides, and
  restores them. Ships with `skill-creator` and `mcp-config` built in (#333).
  See [docs/skills.md](docs/skills.md).

## v0.0.228 (2026-07-31)

- Local learning defaults corrected to the documented privacy posture, with
  the full write-up in [docs/learning-privacy.md](docs/learning-privacy.md)
  (#332).
- Test-dispatch fixes: modules whose tests were silently never running are now
  wired into the test root (#331).

## v0.0.227 (2026-07-31)

- kuri, the headless-browser companion that backs `webfetch`'s markdown path
  and the kuri skill, installs by default now; opt out with
  `HARNESS_NO_KURI=1` (#329).
- Both the root and subagent system prompts now ask for parallel tool calls,
  with the dependency caveat that keeps same-file writes from racing (#329).

## v0.0.226 (2026-07-31)

- `/images` opens image URLs from the last response (for example a
  `gh issue view` with attachments) in your browser (#103).
- The prompt line is width-budgeted so long model and mode badges cannot break
  interactive redraw (#209).
- Kimi and xAI OAuth tokens refresh selectively at startup (#274).

## v0.0.225 (2026-07-31)

- Remote MCP supports stateless-core servers, with a legacy fallback.
- The system-prompt variants are built through one funnel, removing drift
  between the interactive, subagent, and review prompts (#326).

## v0.0.224 (2026-07-30)

- `/goal` hardening follow-ups: pinned call-site coverage and a real-PTY
  regression for goal collapse.

## v0.0.223 (2026-07-30)

- Orchestration hardening: worktree commit-loss fix, JSON tag guards against
  undefined-behavior derefs, subagent task pinning, and five ultracode audit
  fixes (retry gating, all-failed abort, phase budgets, worktree rejection in
  pipelines, shared context slots).
- Anthropic models stream summarized thinking (#322), and review mode no
  longer races the background learning writer (#324).

## v0.0.222 (2026-07-30)

- `/goal` and `/loop` are one autonomous run: the same engine with or without
  a standing objective, including time budgets like `/goal 30m <text>`.

## v0.0.221 (2026-07-30)

- Goal epochs, and a standing `--goal` that survives compaction via an
  objective snapshot (#318).
- Retained reasoning is pinned across all wire formats.
- MCP servers get a bounded teardown at session exit (#305).

## v0.0.220 (2026-07-26)

- `learn` auto-initialization fix (#304).

## v0.0.219 (2026-07-26)

- The local learning loop closed end to end: zero-config `graff learn init`,
  session-triggered background trials, and the learned genome becomes the root
  prompt (#302). See [docs/local-learning.md](docs/local-learning.md).

## v0.0.218 (2026-07-26)

- Workspace router configuration for providers; router cache entries
  serialize independently.
- GUI: provider surfaces reachable in QA mock mode, useful sidebar empty
  states, and narrow-window fixes (#300).

## v0.0.217 (2026-07-25)

- Zig 0.17 nightly compatibility for CI (#298).
- OAuth refresh is single-flight (#245), clipboard paste gets a vision guard
  (#258), a provider-routing fix (#294), and the ultracode shape catalog with
  a slot axis (#290, #293).

## v0.0.216 (2026-07-24)

- `/review` is bounded correctly without a hard call cap (#280, #281).
- Subagent harness orchestration (#279).

Older releases: narrative notes for v0.0.211, v0.0.212, and v0.0.215 live in
[docs/releases/](docs/releases/), and `graff --version` prints highlights back
to v0.0.192.
