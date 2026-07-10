<p align="center">
  <img src="codegraff.png" alt="codegraff" width="360">
</p>

<h1 align="center">graff</h1>

<p align="center">
  <strong>An AI that actually does the work. Not just talks about it.</strong>
</p>

<p align="center">
  Install it on your Mac or Linux machine, sign in with the AI subscription you
  <em>already have</em>, and hand it real tasks. graff writes and runs code,
  automates the boring stuff, digs through your files, researches the web, and
  runs its own experiments, on its own, until the job is done.<br/>
  <strong>You don't chat with it. You give it work.</strong>
</p>

<p align="center">
  <img alt="macOS · Linux" src="https://img.shields.io/badge/macOS%20·%20Linux-555">
  <img alt="One binary, 1.7 MB" src="https://img.shields.io/badge/one%20binary-1.7%20MB-44cc11">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/dependencies-0-44cc11">
  <img alt="Built in Zig 0.16" src="https://img.shields.io/badge/built%20in-Zig%200.16-f7a41d?logo=zig&logoColor=white">
</p>

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

<p align="center"><sub>Prefer a window? Grab the <a href="#install">desktop app</a>. Then just run <code>graff</code> and tell it what you need.</sub></p>

## What can I ask it?

If you could do it at a computer, you can ask graff to do it for you:

- *"Build me a little app to track my workouts."* It writes it, runs it, and shows you.
- *"Turn this folder of messy CSVs into one clean spreadsheet."*
- *"Figure out why my site is slow, then fix it."*
- *"Scrape these five pages and summarize them."*
- *"Run an experiment: try three versions of this and tell me which scores best."*

It works in your real terminal, on your real files, with the real internet, and it can spin up a whole team of sub-agents to work in parallel. It even keeps score of which approaches work and gets better over time.

> **Don't write code?** You don't have to. Say what you want in plain English; graff figures out the steps and does them.

---

## How it compares

<p align="center">
  <img src="comparison.png" alt="graff vs Claude Code vs Codex: ~20x cheaper ($0.022 vs $0.51 vs $0.42 per task), ~25 MB vs ~410 MB vs ~206 MB peak memory, 4.4s vs 8.9s one-shot gpt-5.5 latency" width="860">
</p>

Run the same job on graff, Claude Code, and Codex (three read-only questions about this repo, plus an 8-trial latency test), and here is what it means for you:

**Your AI bill is a fraction.** graff runs the same task on whatever model fits your budget. On `deepseek-v4-pro` it averaged **$0.022 per task**, against Claude Code's **$0.51** (Opus 4.8) and Codex's **$0.42** (gpt-5.5). That is roughly **20× cheaper**, because Claude Code only runs Claude and Codex only runs GPT, while graff runs deepseek, kimi, glm, grok, minimax, gpt, claude, and more. On the *same* model the token usage is comparable, so the win is the freedom to pick a cheaper one, not a token trick.

**It stays out of your way.** graff is one 1.7 MB Zig binary. In these runs it used about **25 MB of memory** for focused work (more when it reads a lot of code), against Claude Code's steady **~410 MB** (Node) and Codex's **~206 MB** (Rust). Leave it running next to everything else and your laptop won't notice.

**Scripts and CI finish in half the time.** For one-shot runs (`graff -p`, the SDKs, a CI step), graff completed a gpt-5.5 turn in **4.4 s** versus Codex's **8.9 s** on the identical ChatGPT endpoint, on every single trial. That is graff's near-instant startup beating a heavier per-call launch. In a long interactive session the startup amortizes and both settle to model latency, so this is a one-shot and automation win, not a blanket "graff is faster."

<sub><b>Method:</b> macOS, same machine, read-only code questions on this repo. Cost is each tool's own reported usage at <a href="https://codegraff.com/docs/models">codegraff gateway prices</a>; memory is peak RSS via <code>/usr/bin/time -l</code>; latency is 8 concurrent graff/Codex pairs on a tool-free prompt with reasoning effort matched. Your numbers will vary with the task, the model, and the network. Reproduce it yourself: <a href="benchmarks/">benchmarks/</a>.</sub>

---
## Under the hood

<strong>the super simple harness.</strong> A minimal agentic coding harness in Zig 0.16. One <strong>1.7&nbsp;MB</strong> binary, zero dependencies. Talks to <strong>Anthropic</strong>, any <strong>OpenAI-compatible</strong> endpoint (DeepSeek, OpenAI, …), or your <strong>ChatGPT subscription</strong>.

```
user text ─→ POST ─→ model asks for tools?
                  ↑           │
                  │  results  ▼
                  └─ io.async ×N  (parallel: bash/files/subagents)
              … repeat until the model stops
```

A REPL that talks to the model directly over HTTPS (`std.http.Client`),
hand-rolls every JSON wire format (`std.json`), and runs tool calls (subagents
included) in parallel on the std.Io thread pool. It also compacts its own
context when the conversation gets long.

**Contents**

- [Install](#install) · [give it a key](#give-it-a-key) · [run it](#run-it)
- [Why](#why)
- [Code intelligence](#code-intelligence-token-efficient-by-default)
- [An evolutionary harness](#an-evolutionary-harness)
- [Providers & models](#providers--models)
- [CLI reference](#cli-reference)
- [REPL commands](#repl-commands)
- [Permission modes](#permission-modes)
- [SDKs: TypeScript & Python](#sdks-typescript--python)
- [Reference](#reference)
- [Coming soon](#coming-soon)

---

## Install

### Desktop app: macOS (Apple Silicon)

Prefer a window over a terminal? Download the latest signed, notarized build, drag it to Applications, and open it. The desktop app is **fully self-contained**: it bundles the `graff` agent, so there's nothing else to install to start coding, and it keeps itself up to date automatically. On first launch it drops two commands on your PATH: `codegraff <path>` (opens that folder in the app, `code`-style) and `graff` itself (the agent CLI, in your terminal), so the one install covers both the window and the command line. The terminal `graff` is symlinked into the app, so it auto-updates along with it. Not on Apple Silicon, or want a standalone CLI? Use the command-line install below.

<p align="center">
  <a href="https://github.com/justrach/codegraff/releases/latest/download/Codegraff.dmg"><img alt="Download Codegraff for macOS" src="https://img.shields.io/badge/Download%20for%20macOS-Apple%20Silicon-000000?style=for-the-badge&logo=apple&logoColor=white"></a>
  <br/>
  <sub><a href="https://github.com/justrach/codegraff/releases/latest">or browse all releases</a></sub>
</p>

### Command line: macOS · Linux

Grab the latest prebuilt release binary: macOS builds are Developer ID signed
and Apple notarized; on any other platform the installer builds from source with
Zig 0.16:

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

From a checkout, just run `./install.sh`. The binary lands in `~/bin` by default
(override with `HARNESS_DIR`):

| tool      | purpose |
| --------- | ------- |
| `graff`   | the agent CLI + REPL: the one binary this script installs |
| `codedb`  | optional code-intelligence companion (structural search/outline/callers). graff auto-detects it and points at the [one-line install](https://github.com/justrach/codedb) if it's missing; everything else works without it |

### Give it a key

Three ways, pick whichever is easiest:

```sh
graff login                     # free codegraff key (device-code OAuth, no signup forms)
graff key set deepseek sk-...   # store ANY provider's key (macOS Keychain, else 0600 file)
export DEEPSEEK_API_KEY=sk-...  # or just an env var (env always wins)
```

Already logged into the Codex CLI? Skip this step. Your ChatGPT subscription is
picked up automatically from `${CODEX_HOME:-~/.codex}/auth.json`. Or run
`graff login codex`.

> **Note on `login`:** there is no per-provider `login` command. `graff login`
> is *specifically* the free codegraff key, and `graff login codex` is the
> ChatGPT-subscription OAuth. **Every other provider** (deepseek, openai,
> anthropic, kimi, xai, zai, minimax, xiaomi) is a key: set it with
> `graff key set <provider> <key>` or its `<PROVIDER>_API_KEY` env var, then
> select a model with `--model` / `/model`. See [Providers & models](#providers--models).

### Run it

```sh
graff                            # starts on the first provider you have a key for
graff --model deepseek-reasoner  # or pin one explicitly
```

First things to try once you're at the `›` prompt:

```
› what's in this directory? summarize the build setup.
› /model sonnet                  # fuzzy-switches to claude-sonnet-4-6
› spawn three subagents to summarize src/, count TODOs, and check git status, in parallel
› ultracode audit this repo for error-handling gaps   # codeword → multi-agent workflow mode
› /help                          # everything else
```

---

## Why

Measured, not vibes: arm64 macOS, ReleaseFast; methodology and the budgets each
change is held to live in [architecture.md](architecture.md):

| metric                      | measured                                        |
| --------------------------- | ----------------------------------------------- |
| binary                      | **1.69 MB**, zero dependencies (Zig std only)   |
| cold start                  | **~1.4 ms**                                     |
| full agentic turn           | **12 MB** peak RSS, ~4% CPU (network-bound)     |
| 8 parallel subagents        | **+0.4 MB each** (15 MB total)                  |
| tool output into history    | hard 128 KB cap: a 500 MB python child process never touches the harness's footprint |

Benchmarked against the Rust codegraff ([justrach/codegraff](https://github.com/justrach/codegraff),
39 MB binary, 934 crates) on the *same model through the same endpoint*,
interleaved 3×: turn speed was a dead tie (2.94 s vs 2.93 s; the network and
the model dominate the turn), but the Zig harness ran in **4.3× less memory**
(11.3 MB vs 48.5 MB), starts 3.5× faster, and is 23× smaller on disk. An agent
CLI rarely wins on turn speed; it can win on the cost of being there.

---

## Code intelligence: token-efficient by default

The fastest way to blow a context window is to read whole files into it. graff
ships with a built-in **`codedb`** tool: read-only, structural code
intelligence over a local index of the repo
([github.com/justrach/codedb](https://github.com/justrach/codedb)), and the
system prompt steers the model to reach for it *before* `grep` or
whole-file reads. Instead of paying for a 2,000-line file to find one function,
the model asks for exactly the shape it needs:

```
codedb outline src/main.zig          # just the symbol map, functions/types, no bodies
codedb symbol switchProvider --body  # one function, by name
codedb callers recordUsage           # who calls it (call sites, not files)
codedb search "parse SSE"            # indexed search, ranked hits, not a grep dump
codedb context "add a new provider"  # task-shaped orientation across the codebase
```

Why this keeps token cost low:

- **Structural slices, not files.** `outline`/`symbol`/`callers`/`deps` return a
  function map or a single definition, tens of lines where a `read_file` would
  spend thousands. The index is queried, not the raw bytes streamed into history.
- **It's free and indexed; the metered tools come second.** The system prompt
  encodes an explicit search order: try the free, indexed `codedb` first;
  fall to (metered) `muonry`/raw search only for literal/regex or non-indexed
  files. The cheap path is the default path.
- **Hard output cap.** A query is truncated at **64 KB** with a marker that nudges
  the model back toward targeted queries (`outline`, `symbol --body`) rather than
  whole-file reads, so even a broad search can't balloon the context.
- **Same index powers the `@` file picker** (`codedb glob`), so attaching a file
  by name never shells out to a directory walk.

Pure-Zig client to a pure-Zig server, zero dependencies on either side. Allowed
subcommands: `search · symbol · callers · find · outline · read · tree ·
context · word · deps · glob · ls · file · hot`. Not installed? The tool says so
and points at the one-line install; everything else keeps working without it.

---

## An evolutionary harness

graff doesn't just run an agent; it records every run as a node in a
**Darwin Gödel Machine-style archive tree** ([arXiv:2505.22954](https://arxiv.org/abs/2505.22954)),
so the harness itself is the substrate for agent self-improvement. Each session
appends to `harness.trajectory.jsonl` (truncated per session, like the trace):

- **A lineage tree, not a flat log.** Root turns form a spine (each turn's
  parent is the previous one); every subagent and workflow task hangs off the
  turn that spawned it. Each node carries a **fingerprint of the system prompt
  it ran with** (`prompt_sha` = first 8 bytes of SHA-256), so prompt mutations (
  `set_system_prompt` on the spine, per-child `system_prompt` overrides on the
  fan-out) show up as hash changes along edges. A lineage can be replayed or
  scored offline.
- **Personas are variants.** Subagents pick a persona with `agent` (built-ins:
  `reviewer · researcher · implementer · skeptic`, plus anything in
  `.harness/agents/`) or take a custom `system_prompt`; either way the
  trajectory records the lineage, so you can mine *which agent variant actually
  worked*.
- **A fitness ledger with integrity.** The `score` channel appends evaluation
  records (`prompt_sha`, `score`, `parent_sha`; the lineage edge DGM parent
  selection counts children with). Because the archive lives in the working
  directory, a forged `score` row could manufacture fitness, so every score the
  harness writes is **HMAC-signed** (keyed by `GRAFF_SCORE_KEY_FILE`, a secret
  outside the cwd that the evolving agent's confined tools can't reach). Readers
  recompute the HMAC and reject unsigned or forged rows. Signing is opt-in and
  backward-compatible (no key → unsigned, accepted as before).
- **Tool-use is mined too.** Each agent logs its tool calls (name + error flag,
  in order): the process signal behind "which tool combinations work",
  joinable to scores via `prompt_sha`.
- **Closed loop in releases.** Release binaries ship anonymous evolution
  telemetry (opt-out) so agent-variant fitness is learned across the fleet, not
  just one laptop. `/trajectory` renders the current session's agent tree; see
  [docs/hyperagents.md](docs/hyperagents.md) for the full design.

---

## Providers & models

Six API-key providers plus a subscription login, three wire formats. A
`ProviderSpec` table (`provider_specs` in `src/main.zig`) holds each provider's
endpoint, auth style, env var, and default model; base URLs and key names come
from [models.dev](https://models.dev)'s `api.json` (snapshot 2026-06-10).

| Provider    | Wire format / auth          | Key env var          |
|-------------|-----------------------------|----------------------|
| `anthropic` | Anthropic Messages, x-api-key | `ANTHROPIC_API_KEY`  |
| `codegraff` | OpenAI chat, bearer         | `CODEGRAFF_API_KEY` (`cg_sk_...`) |
| `deepseek`  | OpenAI chat, bearer         | `DEEPSEEK_API_KEY`   |
| `openai`    | OpenAI chat, bearer         | `OPENAI_API_KEY`     |
| `minimax`   | Anthropic Messages, bearer  | `MINIMAX_API_KEY`    |
| `xiaomi` (MiMo) | OpenAI chat, bearer     | `XIAOMI_API_KEY`     |
| `kimi` / `xai` (grok) / `zai` (GLM) | OpenAI chat, bearer | `KIMI_API_KEY` / `XAI_API_KEY` / `ZAI_API_KEY` (via `graff key set`) |
| `codex`     | Responses API, ChatGPT login | `${CODEX_HOME:-~/.codex}/auth.json` (no API key) |

**Using a specific provider directly** is always the same two steps: give it
the key, then name a model. For example, DeepSeek straight to `api.deepseek.com`:

```sh
graff key set deepseek sk-...          # or: export DEEPSEEK_API_KEY=sk-...
graff --model deepseek-reasoner        # models: deepseek-v4-pro · deepseek-v4-flash · deepseek-chat · deepseek-reasoner
```

The same pattern works for every API-key row above: swap in the provider id
and one of its models (`graff key set openai sk-...` → `--model gpt-...`,
`graff key set anthropic sk-ant-...` → `--model sonnet`, and so on).

A model is routed to the first provider (in the table order above) that both has
a key set **and** lists the model in the active catalog. Codex names, rollout
visibility, ordering, and context windows come from its account-scoped `/models`
endpoint, cached for five minutes with Graff's supported Codex protocol version
(a separately installed older Codex CLI cannot hide newer models). Baked Codex
rows are only the logged-out/offline fallback, currently including `gpt-5.6-sol`,
Terra, and Luna. Unknown `claude*` models
fall back to Anthropic; any other unknown model falls back to the codegraff
gateway, and `/model` prints a warning when that fallback fires, since a typo'd
name will be rejected by the API on the first request. The startup default is
the first provider with a key, on its default model. `/models` prints the full
table: context window, compaction point, provider, and which providers you have
keys for; `/model <name>` switches (a bare `/model` opens an interactive fuzzy
picker). `graff models refresh` forces a fresh Codex catalog request and refreshes
the independent models.dev price/context metadata cache.

<details>
<summary><strong>Codex login (ChatGPT subscription)</strong> · <strong>why no Claude login</strong></summary>

<br/>

If you're logged into the Codex CLI, the harness reads the ChatGPT OAuth token
from `${CODEX_HOME:-~/.codex}/auth.json` at startup (the same on-disk-credential
trick used for the codegraff key) and prints `logged into Codex (ChatGPT account …)`. Switch to
it with `/model codex`; Graff selects the first visible model in your live,
account-scoped Codex catalog. This is a third wire format: the
**Responses API** against the ChatGPT backend
(`chatgpt.com/backend-api/codex/responses`), not `api.openai.com`, so it uses
your ChatGPT Pro/Plus subscription rather than a paid API key. Text, tool
calling, compaction, and `/save`/`/resume` all work on it. Not logged in?
`graff login codex` runs the PKCE browser flow itself.

Claude models route through a real `ANTHROPIC_API_KEY` or the codegraff gateway
only. There is deliberately no Claude-subscription login: reusing a Claude Code
OAuth token outside the official client violates Anthropic's terms of service.

Tool definitions are written once as comptime specs and rendered into both
formats (Anthropic `input_schema` vs OpenAI `function.parameters`) at compile
time. See `anthropicToolsJson` / `openaiToolsJson` in `src/main.zig`.

</details>

---

## CLI reference

```
usage:
  graff [flags]                    start the REPL
  graff [-p] "prompt"              one-shot: run the prompt, print the answer, exit
  graff login                      get a codegraff key (device-code OAuth)
  graff login codex [--refresh]    ChatGPT/Codex OAuth login (PKCE)
  graff key set <provider> <key>   store a key (macOS Keychain, else 0600 file)
  graff key list                   show which providers have keys
  graff mcp add <name> -- <cmd>     add an MCP server to .mcp.json
  graff mcp                         list configured MCP servers
  graff --schema                   print the machine-readable interface (SDK codegen)

flags:
  --model <name>   start on this model (same fuzzy resolution as /model)
  --yolo           skip all permission prompts for the session
  -p, --print      one-shot print mode (answer on stdout, tool progress on stderr)
  --timing         show per-tool wall-clock on result lines (✓ (312ms) …)
  --cost           show running session spend in the prompt ([model · 12k tok · $0.0042])
  --json           structured stdio protocol (JSON in, JSONL events out, SDK transport)
  -h, --help       usage
  -V, --version    version
```

Unknown flags are an error (with a pointer to `--help`), a missing `--model`
value is an error, and `--help`/`--version` are handled before subcommand
dispatch, so `graff login --help` prints usage instead of starting an OAuth
flow. With no key configured at all, startup fails with the three quickest fixes
spelled out rather than a bare env-var list.

**One-shot mode** makes the harness scriptable without the SDK: `graff -p "how
many TODOs in src/?"` runs a full agentic turn (tools included), prints only the
final answer on stdout (progress lines go to stderr), and exits non-zero on
failure. There's no human to ask, so the permission gate denies anything not
already allowed. Pre-approve commands in `.harness/settings.json` or pass
`--yolo`.

---

## REPL commands

A bare `/` opens the whole list as a filterable full-screen menu (type to
narrow, Enter runs it); **Esc during a response interrupts the turn**:
generation stops (it works from the moment the request is sent, including a slow
provider connect), what already streamed stays in history with an
`[interrupted]` marker, and you're back at the prompt. A bare Esc at the prompt
clears the input line.

While a response streams you stay in control: besides Esc to interrupt,
**Ctrl-T (`^T`) folds/unfolds the live "Thinking" block** in place, and the mouse
wheel scrolls your terminal's own scrollback: the REPL doesn't grab the mouse, so
scrolling up to re-read earlier output works like any normal terminal (parity with
Claude Code). Folding the Thinking block is keyboard-only (`^T`). There is no
click-to-fold.

```
/model [name]   no arg → interactive fuzzy picker; or /model <name|provider|provider model>
/models         list known models, context windows, compaction points
/clear          wipe the conversation and start fresh
/plan           toggle plan mode: read-only explore + propose; writes/edits denied
/key [p k]      show API-key status; /key <provider> <key> adds one live (+ Keychain)
/keepcontext    toggle keeping the conversation when /model switches wire format (default on)
/reasoning      reasoning picker: low|medium|high|xhigh|max|ultra (persists)
/fast           toggle Codex priority service tier for lower latency
/ultracode      toggle persistent multi-agent workflow mode
/rewind [n]     list past prompts; /rewind <n> drops prompt n+after & reverts its file edits
/image <path>   attach an image to your next message (vision models only)
/paste          attach the clipboard image (macOS); also Ctrl-V (⌘V can't be captured)
/strict         toggle "every message is a tool" mode
/yolo           toggle bash auto-approval (skip permission prompts)
/trace          toggle the JSONL event trace (harness.trace.jsonl)
/compact        summarize history into a fresh context
/save | /resume | /sessions   session persistence; bare /resume → interactive picker
/todo           show the current task list
/mcp [add …]    list MCP servers/tools; /mcp add <name> <cmd> connects one live
/help           list commands
exit | /exit | ctrl-d | ctrl-c(empty)   quit
```

`/plan`, `/yolo`, and `/strict` change how the permission gate behaves for the
session. See [Permission modes](#permission-modes).

The line editor supports ↑/↓ history (persisted to `~/.simple-harness-history`),
Tab completion (commands, and model names after `/model `), and emacs-style
editing (Ctrl-A/E/W/U/K, Option+Delete, word moves). The selected model is
remembered in `~/.simple-harness-model` and resumed next launch
(`--model <name>` overrides; a remembered model that's no longer in the table is
ignored with a note). The prompt is a small statusline:
`[model · Extra high · Fast · Plan · cwd /repo · 12345/800k tok (1%) · ⚡cached]`.
Active modes are visible at a glance: Low is green, Medium cyan, High yellow,
Extra high/Ultra/Ultracode magenta, Max/Strict/YOLO red, and Plan yellow.
Badges for unsupported settings are hidden instead of implying they apply. The
tail shows context used vs the compaction budget, last cache hit, and (for
metered providers) session spend.
Errors aim to be actionable: `/resume nope` says the session file wasn't found
and points at `/sessions`; an unknown `/foo` points at `/help`.

---

## Permission modes

By default graff **asks before doing anything that can change your machine.**
File writes (`write_file`/`edit_file`), MCP tool calls, and any bash command
that isn't read-only stop at a permission gate:

```
⚠ rm -rf build/
[y]es once · [a]lways allow "rm" (saved to .harness/settings.json) · [n]o ›
```

- **y** runs it once · **a** runs it *and* remembers the rule · **n** denies it
  (the model is told and picks another path).
- **Always** appends a prefix rule to `.harness/settings.json` under `"allow"`,
  so that command never prompts again, this session or a future one. Pre-seed
  that file by hand to allow commands up front (it lives next to your hooks; the
  harness preserves the rest of the file).
- Read-only commands are auto-allowed and never prompt: `ls cat head tail wc
  grep rg pwd which file`, `git status|diff|log|show`, `zig build|fmt`, but
  only while every path stays inside the working directory (`cat /etc/passwd`
  still asks), and only as a plain command. A pipe, redirect, `&&`, or `$(…)`
  always prompts, so a second command can't be smuggled past a prefix match.

Three session-wide modes change the gate. Set on the CLI, or flip them live in
the REPL:

| mode       | turn on              | what it does |
| ---------- | -------------------- | ------------ |
| **yolo**   | `--yolo` · `/yolo`   | Skip **every** prompt: bash, edits, and MCP all run without asking. For sandboxes, CI, and `-p`/`--json` runs where there's no human to answer. `--yolo` starts the session in it; `/yolo` toggles mid-session. |
| **plan**   | `/plan`              | Read-only: the model explores and *proposes* a plan; the gate hard-denies writes, edits, MCP, and any bash beyond the read-only seed (even your saved allow-list) until you `/plan` again to execute. The prompt shows a yellow `Plan` badge. |
| **strict** | `/strict`            | "Every message is a tool": the model must call exactly one tool per message and finish with `attempt_completion`. Useful for deterministic, scriptable agent loops. |

**One-shot mode** (`graff -p "…"` or `--json`) has no human to answer the
prompt, so the gate denies anything not already allowed. Pre-approve commands
in `.harness/settings.json` or pass `--yolo`.

---

## SDKs: TypeScript & Python

graff is scriptable from your own code. `graff --json` is a structured stdio
protocol (JSON requests in, JSONL events out; `ask_user` is answered with a
structured `{"type":"answer","text":"...","cancelled":false}` line) and `graff --schema` prints the
machine-readable interface, and the **TypeScript and Python SDKs in
[`sdk/`](sdk/) are auto-generated from that schema**, so they never drift from
the binary. On every release tag a GitHub Action rebuilds, regenerates, fails if
the committed SDKs are stale, and publishes to npm (`@graff-new/sdk`) and PyPI
(`simple-harness-sdk`).

```python
# Python
from harness_sdk import Harness

with Harness(yolo=True, model="gpt-5.5") as h:
    print(h.ask("what is 2+2?"))
    for ev in h.chat("read foo.txt"):
        print(ev["type"], ev)
```

```ts
// TypeScript
import { Harness, runAgent } from "@graff-new/sdk";

// one-shot, streamed
for await (const ev of runAgent({ prompt: "summarize README.md", model: "gpt-5.5", yolo: true })) {
  if (ev.type === "text") process.stdout.write(ev.text);
  if (ev.type === "turn") console.log("\ncost $", ev.cost_usd);
}

// long-lived, multi-turn
const session = Harness.init({ model: "claude-opus-4-8", yolo: true }).session();
console.log(await session.ask("what files are here?"));
session.close();
```

Can't spawn a local process (edge runtimes, browsers, other machines)? Run
`graff serve` and both SDKs ship matching **remote clients** that drive it over
HTTP: `@graff-new/sdk/remote` (fetch-only: Workers/Deno/Bun/browsers) and
Python's `RemoteHarness` (stdlib only). Same method surface, same event stream.
See [`sdk/README.md`](sdk/README.md).

---

## Reference

<details>
<summary><strong>Tools & the permission gate</strong></summary>

<br/>

| Tool                 | Kind     | Implementation                                            |
|----------------------|----------|-----------------------------------------------------------|
| `bash`               | built-in | `std.process.run` → `/bin/sh -c`, stdout+stderr+exit code |
| `read_file`          | built-in | `Io.Dir.cwd().readFileAlloc` (256 KB cap)                 |
| `edit_file`          | built-in | exact string replace; unique match required unless `replace_all` |
| `write_file`         | built-in | `Io.Dir.cwd().writeFile`                                  |
| `codedb`             | built-in | shells out to [codedb](https://github.com/justrach/codedb): read-only code-intel (search/symbol/callers/outline/…) |
| `subagent`           | built-in | this same agent loop, recursively (root agent only)       |
| `workflow`           | built-in | phases of parallel subagents; `{{prev}}` carries results forward (root only) |
| `todo_write`/`_read` | meta     | mutate/read the agent's own task list                     |
| `ask_user`           | meta     | ask the human a question; their reply returns as the result |
| `attempt_completion` | meta     | carry the final answer out; ends the turn                 |
| `mcp__<server>__*`   | MCP      | tools discovered from `.mcp.json` servers (see below)     |

**Meta tools** act on the agent or the conversation, not the outside world, so
the orchestrator handles them inline rather than on a pool thread. `ask_user` +
`attempt_completion` make the human↔agent conversation fully tool-mediated: the
agent asks via a tool, the person's reply comes back as that tool's result, and
the agent finishes via another tool. In `/strict` mode the model is forced to
call a tool every turn, so *every* message is a tool call or tool result.

**Permission gate.** The gate (`gateTool`) covers `bash`, `write_file`,
`edit_file`, and MCP tool calls. A call that isn't pre-approved prompts at the
REPL: `[y]es once · [a]lways allow "<key>" (saved) · [n]o`. The approval key is
the command's first word for bash, the tool name for writes/MCP. "Always"
**persists**: it's written to `.harness/settings.json` in the cwd
(`{"allow": ["touch", "write_file", …]}`) and loaded back on every launch in
that project. Edit the file by hand to revoke or pre-approve. A small seed
allowlist (read-only basics like `ls`/`cat`/`rg`, plus `zig build`/`zig fmt` and
`git status`/`diff`/`log`/`show`) never prompts; `find` is deliberately excluded
(its `-exec`/`-delete` make it an exec tool). Commands containing chaining,
pipes, redirection, substitution, or newlines never match a prefix: they always
prompt. Approving an interpreter as a bash word (`python3`, `node`, …) prints a
heads-up that it grants arbitrary code execution.

**Path confinement.** `read_file`/`write_file`/`edit_file` are confined to the
working-directory subtree: no absolute paths, no `..`. This is structural (not
bypassed by `/yolo`): `read_file /etc/shadow` and `write_file ../../x` are
refused with an error.

**bash is cwd-locked by default too.** A seed/approved command auto-runs only
when all its path arguments stay in the cwd (`escapesCwd` rejects absolute, `~`,
and `..` tokens). So `cat local.txt` runs free but `cat /etc/passwd` falls
through to a prompt at the root (you can still approve it per-call) and is denied
for subagents. `/yolo` lifts this.

**Subagents** have no stdin, so they're gated structurally, not by prompt: bash
is allowlist-only (unapproved → denied), file writes are allowed but
path-confined, and MCP isn't exposed to them at all. `/yolo` turns the prompt
gate off (path confinement stays).

</details>

<details>
<summary><strong>MCP servers</strong></summary>

<br/>

The harness is an MCP **client** (`src/mcp.zig`). Drop a `.mcp.json` in the
working directory and it spawns each server, speaks JSON-RPC 2.0 over stdio,
discovers their tools, and offers them to the model namespaced
`mcp__<server>__<tool>`:

```json
{
  "mcpServers": {
    "codedb":      { "command": "codedb", "args": ["mcp", "."] },
    "everything":  { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-everything"] }
  }
}
```

Pointing it at `codedb mcp .` gives the agent 22 structural code-intelligence
tools: pure-Zig client to pure-Zig server, zero dependencies on either side.
`/mcp` lists what connected; `/mcp add <name> <cmd> [args…]` connects a server
live and saves it to `.mcp.json`. From a shell, use the Codex-style form
`graff mcp add <name> [--env KEY=VALUE ...] -- <cmd> [args…]`; for example,
`graff mcp add context7 -- npx -y @upstash/context7-mcp`. `graff mcp` lists the
servers already saved in `.mcp.json`. Workspace servers auto-connect only with
`--yolo` (trusted) or per-session consent.

One known companion is exempt from the workspace gate: if the `muonry` binary is
on PATH (the fast code-intelligence suite), the harness auto-connects it in
every workspace (it's a user-installed tool, not arbitrary repo config) and
injects its usage note so the model prefers `mcp__muonry__read`/`search` over
native navigation, falling back to the native tools whenever a call fails. Opt
out with `{"skills": {"muonry": false}}` in `.harness/settings.json`.

</details>

<details>
<summary><strong>ultracode & workflows: multi-agent fan-out</strong></summary>

<br/>

**ultracode: the multi-agent codeword.** Put the word **ultracode** anywhere in
a message and the harness augments that turn with a note steering the model into
multi-agent workflow mode: it prints `⚡ ultracode: multi-agent workflow mode
engaged`, records an `ultracode` trace event, and asks the model to fan the work
out across phases of parallel subagents (then synthesize) via the `workflow`
tool rather than doing it solo. It's a per-turn toggle: no flag, no mode to
remember, just the keyword.

**Workflows.** Dynamic workflows as data (inspired by pi-dynamic-workflows,
minus the JS sandbox): the model calls the `workflow` tool with a JSON plan of up
to 5 sequential phases, each holding up to 8 tasks that run in parallel as
isolated subagents. From phase 2 on, `{{prev}}` in a task prompt is replaced
with the labeled results of the previous phase (auto-appended if omitted), and
the final phase's results return to the root agent. Good for fan-out +
synthesis: audits, multi-perspective review, parallel research.

</details>

<details>
<summary><strong>Subagents</strong></summary>

<br/>

A subagent is just a tool whose executor is the same `Agent` loop with a fresh
history, its own arena, and a subagent-specific system prompt (`execSubagent`).
Because tool calls already fan out via `io.async`, the model spawning three
subagents in one response gets three agent loops running concurrently, each
making its own HTTPS calls through the shared (thread-safe) `std.http.Client`.
Subagents inherit the parent's provider, so deepseek subagents work the same as
claude ones.

- Depth capped at one level: subagents don't get the `subagent` tool.
- Subagents don't share the root agent's context, so the orchestrator must put
  everything needed into the prompt (the tool description tells it so).
- Progress lines (`[label] ⚙ bash …`) go to stderr via `std.debug.print`, which
  locks stderr and is safe from pool threads.

</details>

<details>
<summary><strong>Sessions & compaction</strong></summary>

<br/>

**Session persistence.** `/save [name]` writes the conversation (messages +
provider + strict flag) to `<name>.session.json` in the cwd (default name
`last`); `/resume [name]` restores it (provider, model, and full history) in
any later run, and `/sessions` lists the saved ones. The stored message array is
already the provider-native wire shape, so resume is a verbatim restore and
works across providers (including codex's Responses-format items).

**Compaction**, client-side, provider-agnostic:

1. Every response's `usage` is recorded (`input+output+cache` tokens for
   Anthropic, `total_tokens` for OpenAI) and shown in the prompt.
2. Past the model's compaction threshold, 80% of its context window, from a
   comptime model table (`/models` prints it: 800k for the 1M-context models,
   160k for `claude-haiku-4-5`, 160k fallback for unknown models), or on
   `/compact`, the harness sends the history plus a handoff instruction *with no
   tools offered*, so the model must reply with a text summary covering goals,
   decisions, file paths, code state, and pending work.
3. History is replaced by a single user message embedding that summary, and the
   token counter resets.

If the summary request fails, history is left untouched.

</details>

<details>
<summary><strong>KV-cache efficiency (Manus lessons)</strong></summary>

<br/>

Following [Manus's context-engineering notes](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus),
the loop is built to keep the prompt prefix cacheable: the system prompt is
stable (no per-request timestamps), history is strictly append-only, and tool
definitions are rendered once at comptime so their order never shifts. On the
real Anthropic API the harness also sets an explicit `cache_control` breakpoint.
Cache reads are surfaced: `recordUsage` parses `cache_read_input_tokens`
(Anthropic) and `prompt_cache_hit_tokens` / `prompt_tokens_details.cached_tokens`
(OpenAI/DeepSeek), and every `api` trace line carries a `cache_read_tokens` field
so you can see the hit rate in `harness.trace.jsonl`.

The one deliberate exception is `set_system_prompt` (--json protocol / SDK
`setSystemPrompt`): the system prompt is the *first* token of the cached prefix,
so mutating it, even appending, invalidates the KV-cache for the entire
conversation and the next request re-reads everything at full input price. Treat
it as a task-boundary operation: prefer the spawn-time
`--system-prompt`/`--append-system-prompt` flags, and never flip the prompt back
and forth inside an agent loop.

</details>

<details>
<summary><strong>Tracing & telemetry</strong></summary>

<br/>

**Tracing: the harness can debug itself.** Every API round trip (latency,
request/response bytes, context tokens) and every tool execution (duration,
result size, errors, root-vs-subagent) is appended as one JSON line to
`harness.trace.jsonl` in the cwd, truncated at startup so it always covers the
current session. The system prompt tells the agent the file exists, so "profile
yourself" or "why was that slow?" makes the agent read its own trace and answer
from data. `/trace` toggles it.

**Telemetry, pseudonymous, opt-out, on by default.** *Every* build (release,
source, and dev) bakes in a default OTLP endpoint (pass `-Dtelemetry-endpoint=""`
to disable it at build time), so by default a session ships best-effort OTLP/HTTP
JSON POSTs to `<endpoint>/v1/logs` (at exit, plus mid-session batches). **Opt out
any time** with `--no-telemetry` or `GRAFF_NO_TELEMETRY=1`; setting
`OTEL_EXPORTER_OTLP_ENDPOINT` (or `GRAFF_OTEL_ENDPOINT`) redirects it to your own
collector instead.

It's *pseudonymous, not anonymous*: records carry a **random** per-install id
(`~/.simple-harness-install-id`, generated with `io.random`, not derived from your
name, host, or user) plus your request IP, version, OS, and arch. The payload is
**counts, hashes, and tool names**: a `session` summary (duration, turns, API/tool
call+error counts, models used, workflow/ultracode counts), per-`workflow` and
per-error records, and per-turn/score records keyed by a one-way **system-prompt
fingerprint** + `prompt_sha` hashes with a tool-**name** sequence (e.g.
`read_file, bash, edit_file`). It does **not** send your prompts, your code, file
contents, file paths, or tool arguments. Your input is never an argument to any
telemetry call.

**Fleet / evolution signals** (`fleet:propose|submit|elite_pull`, the
agent-evolution fitness loop) ride the same channel and have a *separate* opt-out:
`GRAFF_FLEET=off` or `/fleet off`. They're hashes and labels, with one exception.
`fleet:propose` sends an agent's **system-prompt / persona text** (≤8192 chars: the
evolved "genome"; graff's own text for built-in agents, *your* text for a custom
agent or inline override). Error details are capped at 200 chars. The SDKs tag their
child harness with `HARNESS_CLIENT=sdk-ts|sdk-py` and a separate id
(`~/.simple-harness-sdk-id`). A flush failure never disturbs the session.

</details>

<details>
<summary><strong>Project instructions (AGENTS.md / CLAUDE.md)</strong></summary>

<br/>

At startup the harness reads the first of `AGENTS.md`, `HARNESS.md`, or
`CLAUDE.md` it finds in the working directory and appends it to the root system
prompt (subagents keep the lean prompt). It prints `loaded project instructions
from AGENTS.md (N bytes)`. Because the system prompt stays frozen for the
session, this is KV-cache-friendly. Drop conventions, codewords, or do/don't
rules in `AGENTS.md` and the harness picks them up like any real coding agent.

</details>

<details>
<summary><strong>Install details, keys & SDKs</strong></summary>

<br/>

`install.sh` compiles `graff` (ReleaseFast) and installs it to `~/bin` (override
with `HARNESS_DIR=`); it builds the current checkout, or clones the repo if run
standalone. It detects the platform (Windows → WSL hint), checks for Zig 0.16,
and ends with a PATH check. Alternatively, run in place:

```sh
zig build run            # or: ./zig-out/bin/graff
zig build test           # the test suite (also run by CI, .github/workflows/ci.yml)
```

**Releases & verification.** Tagged releases ship a prebuilt **darwin-arm64**
binary that is **codesigned with a Developer ID certificate and notarized by
Apple**, so it runs without Gatekeeper prompts. Verify a download:

```sh
codesign --verify --strict --verbose=2 graff   # → valid on disk; satisfies its Designated Requirement
codesign -dv --verbose=4 graff 2>&1 | grep Authority
#   Authority=Developer ID Application: Rachit Pradhan (WWP9DLJ27P)
```

Keys can come from env vars, or be stored safely with `graff key set <provider>
<key>`. On macOS that's the login **Keychain** (service `simple-harness`),
elsewhere a `0600` `~/.simple-harness-keys.json`; the harness auto-loads them at
startup for any provider whose env var isn't set (env always wins). `graff key
list` shows which providers have a stored key. Providers
(OpenAI/Anthropic-format, matched to graff): anthropic, openai, deepseek,
**kimi**, **xai** (grok), **zai** (GLM), minimax, xiaomi, codegraff, plus the
codex & claude subscription logins.

`graff login` runs graff's codegraff device-code flow (a `user_code` to enter at
codegraff.com/cli/auth → poll → key, saved to `~/.simple-harness-codegraff.json`);
the codegraff key is also auto-picked-up from graff's own
`~/forge/.credentials.json` if present, so no env var is needed. `graff login
codex` runs the Codex/ChatGPT OAuth browser flow (PKCE → localhost callback →
token) and `graff login codex --refresh` refreshes it. Those built-in login
flows write `~/.codex/auth.json`; set `CODEX_HOME` when reusing credentials from
a custom Codex CLI home.

**SDKs.** `graff --json` exposes a structured stdio protocol (JSON requests in,
JSONL events out) and `graff --schema` prints the machine-readable interface.
Together they are the foundation for the auto-generated TypeScript + Python SDKs
in [`sdk/`](sdk/) (regenerated on release by `sdk/generate.py` /
`.github/workflows/sdk.yml`).

`graff serve` puts that same protocol on HTTP for clients that can't spawn a
local process (edge runtimes, browsers, other machines): each session is a real
`graff --json` child, one non-answer POST is one protocol request, and the
response streams NDJSON events until that request's terminal event. `answer`
POSTs can be sent while the original stream is waiting on `ask_user`; they ack
immediately and the original stream continues to the `tool_result`/`turn`.
Bearer auth via `--token`/`HARNESS_SERVE_TOKEN` (required to bind beyond
loopback); CORS opens only when a token gates access. The SDKs ship matching
remote clients: `@graff-new/sdk/remote` (fetch-only: Workers/Deno/Bun/browsers)
and Python's `RemoteHarness` (stdlib urllib). Endpoints are documented under the
`serve` key of `graff --schema`.

</details>

<details>
<summary><strong>Why Zig & implementation notes</strong></summary>

<br/>

- An agent harness is I/O-bound, so you don't need an async runtime. Zig 0.16's
  new `std.Io` interface gives you one anyway: `io.async(fn, args)` returns a
  typed `Future`, executed on a thread pool you configure (`std.Io.Threaded`).
  Parallel tools and parallel subagents are the same ~6 lines (see
  `runToolsParallel`).
- The new `pub fn main(init: std.process.Init)` entry point hands you `io`, a
  thread-safe gpa, a process-lifetime arena, and the environment map.
- Compiles in well under a second; the binary is self-contained (TLS included,
  no libcurl/openssl).
- The payoff is measurable. Same model, same endpoint, the Rust codegraff burns
  4.3× the memory and 23× the disk for an identical-speed turn. See [Why](#why)
  and `architecture.md` for the methodology.

Notes:

- UI/UX changes are tracked in [uxlog.md](uxlog.md): what changed, what it
  replaced, and the design reasoning (newest first).
- Anthropic requests use adaptive thinking; the assistant's full `content` array
  (including thinking blocks and signatures) is echoed back verbatim, as the API
  requires for tool-use loops.
- OpenAI tool arguments arrive as *stringified* JSON and are parsed before
  dispatch; tool results go back as `role: "tool"` messages.
- History lives in an arena per agent; per-request buffers use the gpa.
- Root requests **stream**: text deltas print live as the SSE events arrive (all
  three wire formats), then the buffered events are reassembled into the
  non-streaming response shape so the rest of the loop is unchanged. Subagents
  and compaction stay buffered. `max_tokens: 16000`.

</details>

<details>
<summary><strong>Status & roadmap</strong></summary>

<br/>

Honest list of what the harness still lacks, roughly in the order it hurts.

**Foundational:**
1. ~~**A public repo + signed release.**~~ **Done, v0.0.1.** The repo is public at
   [`justrach/codegraff`](https://github.com/justrach/codegraff), and releases ship
   a prebuilt **darwin-arm64 binary that is codesigned (Developer ID) and notarized
   by Apple**. The release workflow (`.github/workflows/release.yml`) cross-compiles
   the rest on every `v*` tag; `install.sh` prefers the prebuilt download over a
   source build, so `curl … | bash` now installs in one command with no toolchain.

**Later:**

2. Windows support (install.sh punts to WSL today).
3. Shell completions (zsh/bash) and a man page.
4. A config file for defaults (`--timing`/`--cost`/model) so flags don't have to
   be retyped.
5. Esc during *tool execution* (the interrupt currently lands at the next
   stream; a long-running bash call still runs to completion).
6. Honor `Retry-After` on 429s (the backoff is plain exponential today).

Recently shipped: **v0.1.0** · tagged GitHub release with prebuilt darwin/linux
binaries · bash output truncates at its 128 KB cap instead of failing the tool
call (`runCapped`: real exit code, `[truncated]` marker, memory stays flat while
the child streams gigabytes) · measured performance budgets + the Rust-graff
bake-off in [architecture.md](architecture.md) · 429/5xx retry with exponential
backoff (1s·2ⁿ capped at 8s, Esc cancels the wait, `retry` notes in the trace) ·
`--version` stamped from `git describe` at build time (`-Dversion=X.Y.Z`
overrides) · Esc coverage from the moment the request is sent, so no more `^[`
echo while a slow provider connects, and the interrupt lands before the first
token · bare Esc at the prompt clears the line · one-shot `-p` print mode ·
persistent approvals (`.harness/settings.json`) · plan mode (`/plan`) · `/clear`
· bare-`/` command menu · interactive `/resume` picker · context-% statusline.

</details>

---

## Coming soon

Active directions. See the **Status & roadmap** details above for the full list,
and the GitHub issues for what's in flight:

- **Sandboxes.** Run the agent's `bash`/file tools inside an isolated sandbox
  (ephemeral container / microVM) so untrusted or destructive steps can't touch
  the host. It's the natural next layer above today's cwd-confinement and
  permission gate, and the safe substrate for hands-off evolutionary runs.
- **Closing the evolution loop end-to-end:** a grounded judge, sync-back of
  fleet trajectories, and automatic promotion of winning agent variants.
- **Windows support, shell completions + man page, and a config file** for
  default flags/model.

---

## License

codegraff is licensed under a **modified GNU AGPL-3.0** (see [`LICENSE`](LICENSE)).
The public receives it under the AGPL-3.0, so network use triggers the Section 13
obligation to make Corresponding Source available to remote users. The authors
**Rach Pradhan (justrach)** and **Yu Xi Lim (yxlyx)** reserve full rights to use,
distribute, and offer it (and modified versions) as a private, proprietary, or
hosted/cloud product, free of those obligations.

A recipient's AGPL-3.0 licence is **perpetual and irrevocable unless they breach
it**: it can't be withdrawn at will, which is what makes open use safe to rely on.
Any **proprietary or commercial permission** to use codegraff *without* the AGPL's
copyleft is a separate thing, and exists only if **both authors grant it jointly in
writing**. Such a permission is **revocable at the authors' discretion at any
time**, and neither the provision of consultancy or other services nor any side
agreement grants it or makes it irrevocable. If it is revoked, the user falls back
to full AGPL compliance or must stop using codegraff. For commercial or proprietary
licensing, contact the authors.

---

<p align="center"><sub>Built in Zig 0.16 · <a href="LICENSE">AGPL-3.0 (modified)</a> · <a href="architecture.md">architecture.md</a> · <a href="uxlog.md">uxlog.md</a></sub></p>
