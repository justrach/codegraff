<p align="center">
  <img src="docs/images/readme-workshop.png" alt="The CodeGraff workshop: a crew of rats in coral coats coordinating work. Small crew. Real work." width="960">
</p>

<h1 align="center">graff</h1>

<p align="center">
  <strong>An AI that actually does the work. Not just talks about it.</strong>
</p>

<p align="center">
  Install it on your Mac, Linux, or Windows machine, sign in with the AI
  subscription you <em>already have</em>, and hand it real tasks. graff writes
  and runs code, automates the boring stuff, digs through your files, researches
  the web, and runs its own experiments until the job is done.<br/>
  <strong>You don't chat with it. You give it work.</strong>
</p>

<p align="center">
  <img alt="macOS · Linux · Windows" src="https://img.shields.io/badge/macOS%20·%20Linux%20·%20Windows-555">
  <img alt="One binary, 3.7 MB" src="https://img.shields.io/badge/one%20binary-3.7%20MB-44cc11">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/dependencies-0-44cc11">
  <img alt="Built in Zig 0.17 dev" src="https://img.shields.io/badge/built%20in-Zig%200.17%20dev-f7a41d?logo=zig&logoColor=white">
</p>

<p align="center">
  <a href="https://trendshift.io/repositories/84216?utm_source=repository-badge&utm_medium=badge&utm_campaign=badge-repository-84216" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/84216" alt="justrach/codegraff | Trendshift" width="250" height="55"></a>
</p>

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

<p align="center"><sub>Prefer a window? Grab the <a href="#the-desktop-app">desktop app</a>. Then run <code>graff</code> and tell it what you need.</sub></p>

**Evaluated on FrontierHarness tasks.** Graff includes a reproducible
[FrontierHarness evaluation runner](graff-evals/frontier-harness/README.md),
with recorded outcomes and explicit protocol differences. See
[how we measure it](#how-we-measure-it) for the public task suite, grading,
and the limits of comparisons with the published board.

## The desktop app

The current desktop preview uses Electron and embedded Chromium, with native
macOS window controls and SwiftUI Activity and computer-use panels. Coding
continues in `graff acp`; the window is a client of the same harness used by
the terminal.

[![CodeGraff's dark desktop, framed in cobalt with workshop artwork](docs/images/desktop-chat-studio.png)](docs/images/desktop-chat-dark.png)

Chat tabs, searchable model selection, effort and fast controls, collapsed tool
activity, and explicit working/finished/interrupted states keep the conversation
readable. Appearance includes White, Black, Website and the official CodeGraff
palette. Mention `$gui-theme` or `@gui-theme` in the GUI to create a custom theme.

[![CodeGraff Agents panel with local peers and a handoff request, on warm paper with the workshop crew](docs/images/desktop-agents-studio.png)](docs/images/desktop-agents-codegraff.png)

**Agents** brings Graff-to-Graff coordination into the GUI. See sessions in the
current workspace or across the laptop, their published tasks and activity,
and recent messages. Select a peer in the panel's composer to send a message
or handoff request. Delivery is queued to the recipient's next step; browsing
history does not consume their inbox. The optional profiler records anonymous
per-agent resource measurements, with identities and message contents excluded
from feedback exports. See the [Agents guide](docs/agents-panel.md).

[![CodeGraff's resizable Changes panel beside the conversation, framed in coral with a rat reviewing a proof](docs/images/desktop-review-studio.png)](docs/images/desktop-review-codegraff.png)

**Changes** shows local staged, unstaged and untracked edits, diffs, worktrees
and recent commits. Drag its divider to give the review more room. The browser
pane renders directly in Chromium and supports navigation, find, zoom and element
pins. Optional macOS computer use exposes native app inspection and input after
the user enables it and grants the operating system permissions.

*Presentation frames pair CodeGraff workshop artwork with unchanged GUI captures
and scripted demonstration content. Click a desktop image for the full-size UI.
No private conversation or workspace data is included.*

**Build and launch the preview** on Apple Silicon macOS 14+ with Bun, Zig and
Xcode command-line tools installed:

```sh
./script/build_and_run.sh
```

The development bundle contains the production UI, Chromium, Bun, graff and the
native bridge, and starts its own local server. It does not need a separate dev
server or Kuri. This Electron preview is signed locally; release notarization and
an Electron updater are separate distribution work. Previously published desktop
assets may still use the legacy shell; see the release notes before downloading.

**Profile and test without a model.** The Performance menu and desktop profiler
tool record bounded, local measurement reports. Startup paint timing, streaming
responsiveness, process resources and acceleration status are measured separately.
No reports are uploaded automatically. From `apps/native`:

```sh
bun run build
bun run test:desktop
bun run test:visual
bun run test:performance
```

The visual and performance scenarios use production GUI components with scripted
inputs and block engine/model API calls. See the [desktop guide](apps/native/electron/README.md)
and [visual test guide](apps/native/electron/VISUAL-TESTS.md) for scope and limitations.

## What can I ask it?

If you could do it at a computer, you can ask graff to do it for you:

- *"Build me a little app to track my workouts."* It writes it, runs it, and shows you.
- *"Turn this folder of messy CSVs into one clean spreadsheet."*
- *"Figure out why my site is slow, then fix it."*
- *"Scrape these five pages and summarize them."*
- *"Run an experiment: try three versions of this and tell me which scores best."*

It works in your real terminal, on your real files, with the real internet, and
it can spin up a team of sub-agents in parallel.

> **Don't write code?** You don't have to. Say what you want in plain English.

## Same model, fewer tokens

Same grok-4.6, same SuperGrok seat, same tasks. graff vs grok-build vs OpenCode.
Lower is better on every named axis. Full tables:
[graff-evals/hillclimb/baseline.md](graff-evals/hillclimb/baseline.md).

**12 shipped-PR fixtures** (`run-20260901-121759-composite` on 284, `--suite inhouse`):

| harness | pass | wall | calls | tokens | list$ | RSS |
|---|---:|---:|---:|---:|---:|---:|
| **graff** | **12/12** | **220s** | **53** | **234k** | **$0.32** | **8.7M** |
| grok-build | 12/12 | 490s | 60 | 1.12M | $1.07 | 155M |
| OpenCode | 12/12 | 235s | 77 | 675k | $0.68 | 1.0G |

Graff is the unique frontier on pass, wall, calls, tokens, list$, and RSS
on this remasure. (First-token is not scored — graff's `0.0s` is a boot
mark, not first model SSE. RSS is ReleaseSafe process peak.)

On the 3-task spine (exact-reply + file-ops + fix-fib) graff was **19.9s /
8 calls / $0.048** vs grok 32.3s / 8 / $0.147 and OpenCode 31.2s / 8 / $0.101.

Graff carries context through three steps: reuse the stable setup, run small
programs over the working context, and return focused results. That keeps the
next step supplied with useful information while reducing repeated input.

<p align="center">
  <img src="docs/images/readme-context-workshop.png" alt="A workshop rat examines a proof: stable context, small programs, and focused results keep useful context in the harness" width="960">
</p>

## Install

**Desktop (macOS Apple Silicon).** Download the latest signed, notarized
[release](https://github.com/justrach/codegraff/releases/latest), drag it to
Applications. First launch puts `graff` and `codegraff <path>` on your PATH.

**CLI (macOS · Linux · Windows).**

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

From a checkout: `./install.sh` (binary in `~/bin`; `HARNESS_NO_PATH=1` skips
PATH edits). Windows: unpack `graff-*-windows.tar.gz` from the latest release
and put `graff.exe` on `PATH`.

```sh
graff login                     # free codegraff key
graff login kimi                # Kimi Code OAuth
graff login codex               # ChatGPT / Codex (or reuse ~/.codex/auth.json)
graff key set deepseek sk-...   # any other provider
graff                           # REPL
graff --model grok-4.6          # pin a model
graff -p "how many TODOs in src/?"
```

`graff acp` is the [Agent Client Protocol](docs/embedding.md) spawn (Zed
External Agents). Recipe: [docs/acp-registry.md](docs/acp-registry.md).

## Why it's small

| metric | measured |
| --- | --- |
| binary | **~3 MB**, zero runtime deps |
| cold start | **~1.8 ms** |
| full agentic turn | **~12 MB** peak RSS |
| 8 parallel subagents | **+0.4 MB** each |
| fat tool output | one **4 KB** handle, whatever the result's size |

Same model, same endpoint, the older Rust codegraff used **4.3×** the memory
and **~14×** the disk for a dead-heat turn. Method:
[architecture.md](architecture.md).

## Script it

```python
from harness_sdk import Harness
with Harness(yolo=True, model="gpt-5.5") as h:
    print(h.ask("what is 2+2?"))
```

```ts
import { runAgent } from "@codegraff/sdk";
for await (const ev of runAgent({ prompt: "summarize README.md", yolo: true })) {
  if (ev.type === "text") process.stdout.write(ev.text);
}
```

`graff --json` / `graff --schema` generate the SDKs ([`sdk/`](sdk/)). Remote:
`graff serve`. Embedders: `--no-local-tools` + a sandbox MCP —
[Embedding graff](docs/embedding.md).

<details>
<summary><strong>CLI, slash commands, providers, permissions</strong></summary>

<br/>

```
graff [flags]                 REPL
graff -p "prompt"             one-shot (answer on stdout)
graff login [codegraff|codex|kimi]
graff key set <provider> <key>
graff mcp add <name> -- <cmd>
graff learn <command>
graff --schema

--model <name>   --yolo   --json   --no-local-tools
--subagent-model <name>   --max-model-calls N
```

One-shot has no human at the gate: pre-approve in `.harness/settings.json` or
pass `--yolo`. Full flag list: `graff --help`. Learning:
[docs/local-learning.md](docs/local-learning.md). Skills:
[docs/skills.md](docs/skills.md).

```
/model /models /clear /new /goal /loop /review /never
/plan /yolo /strict /effort /compact /rewind /btw
/skills /plugins /mcp /save /resume /sessions /help
```

Bare `/` is a filterable menu. Esc interrupts the turn. `/help` is the live
catalog.

| mode | what it does |
| --- | --- |
| default | ask before writes, MCP, and non-read-only bash |
| `--yolo` / `/yolo` | skip every prompt (CI, `-p`) |
| `/plan` | read-only explore |
| `/strict` | every message is a tool |

Providers: Anthropic, OpenAI, DeepSeek, xAI, Z.AI, Kimi, Codex (ChatGPT login),
Vercel, OpenRouter, MiniMax, Xiaomi, Groq, Cerebras, Mistral, plus one
workspace router in `.graff/.config.router`. `graff models refresh` pulls
catalogs. Claude-subscription OAuth is deliberately not supported.

</details>

## How we measure it

Two layers, under `graff-evals/`. They answer different questions and neither
of them is a leaderboard claim.

**Layer 1 — the in-house runner** (`run.py`, `harnesses.json`, `tasks/`). Every
task is one JSON file: fixture files, a prompt, and a deterministic shell
`check` that decides pass/fail inside a materialized sandbox. Held-out checks
live in `hidden/` and are injected through `$TASK_ROOT` after the harness exits,
so the agent never sees them. Most harnesses take `--model`, so the same task
set can be driven through different harnesses on one model, and each run records
wall time, first-output latency, peak RSS, CPU and token usage alongside the
verdict, as JSONL plus a summary table.

45 tasks in five suites — `core` (12, sequential single-file work), `rlm` (5,
scatter-gather across files), `swe` (6, multi-file bugfixes), `mcp` (10, a
fixture MCP bench), `inhouse` (12, bug shapes distilled from shipped PRs).
`--suite all` is `core+rlm+swe`; `mcp` and `inhouse` are opt-in. 25 harness
configurations are declared, covering this project's variants plus several other
CLI agents. A task that `requires` a capability a harness lacks is skipped, not
scored as a failure. Cost is recomputed from tokens at published list rates,
because a flat-rate subscription prints `$0.0000` and that is a plan, not a
price.

What this layer proves: that a change moved a measured number on a fixed,
deterministic task set. What it does not prove: anything about the live repo —
the `inhouse` fixtures are distilled shapes, not the codebase.

**Layer 2 — `frontier-harness/`.** It runs the same 30 tasks as
[FrontierHarness Eval](https://github.com/frontier-harness-eval/eval)
— 21 from Terminal-Bench 2.1 and 9 from DeepSWE — in Docker, under a protocol
that is deliberately not the same bench seat (see "What these runs are not"
below, and `PROTOCOL.md`). The board side is a pinned snapshot of the published
results, not a live query. TB tasks are graded by running the public
`tests/test_outputs.py` inside the task container after the agent exits — pass
is `pytest` exit 0. The 9 DeepSWE tasks the upstream pack treats as having a
hidden grader are scored out of band by `grade_swe.py` against the tests
`datacurve-ai/deep-swe` actually ships, using the same images and the same
`prepare`/`test.sh` protocol, reading the verifier's `reward.json`. A missing
`reward.json` is recorded as FAIL, never inferred. A competing agent is run
locally on the same images and the same tests.

### What these runs are not

- **Not same seat as the published board.** The later recorded runs used an
  eval-only system-prompt append (`BENCH_APPEND`, passed as
  `--append-system-prompt`). It is task-shaped coaching the board's harnesses did
  not get. It never touched the shipped prompt in `prompt_text.zig`, and an
  appended-prompt result must not be placed next to a board result as a peer.
  The honest number is the un-appended first pass.
- **Different model.** The published board is Kimi K3; the recorded runs are
  mostly a different model. To compare fairly: empty `BENCH_APPEND`, same model,
  TB-21 only, and say so.
- **Different runtime.** The official eval restores a prepared VM. We
  `docker run` the public image and, on stripped images, add a CA bundle and
  install pytest so TLS and the tests can run at all. That is infrastructure,
  not a hint, but it is not bit-identical.
- **Asymmetric cost columns.** The locally run competing agent logged no token
  events, so its list price is missing — a telemetry gap, not zero. It is also
  driven through its own CLI and its own runner, so it shares the images and the
  tests but not the harness path. The chart refuses to place a row with no cost
  data on the frontier.
- **Mixed-model harness rows are a different comparison.** Entries that run
  another agent on its own native default model are not points in a same-model
  series, and `mcp` is always run in one mode because the other is a different
  tool catalog.
- Some recorded misses are environmental — an agent wall-clock cap, a server
  that did not outlive the agent process, a leftover build artifact breaking a
  file-layout constraint — and are written up as such in `FAILURES.md`. On the
  DeepSWE side `apply_failed` is not excused: it is a real failure.

### Reproduce

```sh
cd graff-evals

./run.py --harness graff                       # core+rlm+swe; mcp/inhouse are opt-in
./run.py --harness graff,grok --model grok-4.6 # harness-vs-harness, same model
./run.py --harness grok --task fix-fib --reps 3
zig build && ./run.py --harness graff-dev      # the locally built binary
./run.py --interactive                         # pick a task, watch it live
```

Results land in `results/run-<stamp>.jsonl`; `.sandboxes/` keeps the last run's
working directories for post-mortems. Both are disposable.

```sh
cd graff-evals/frontier-harness
export FH_GRAFF_MODEL=grok-4.6   # or kimi-k3 + MOONSHOT_API_KEY

python3 fh_run.py --suite tb  -j 2 --fresh --out results.jsonl      # TB-21
python3 fh_run.py --suite swe -j 2 --out swe-results.jsonl          # DeepSWE patches
python3 grade_swe.py grok-4.6                                       # grade those patches
python3 plot_tb21.py
```

The competing agent has its own runner, `fh_exo.py`, and its own binary
(`EXO_BIN`); `fh_run.py` does not drive it.

This layer is not turnkey. It needs Docker, a Linux build of the binary, the
upstream task pack, the pinned terminal-bench tests and a clone of
`datacurve-ai/deep-swe`, staged where the scripts expect them — `PROTOCOL.md`
has the locations. Model selection is an environment variable. No credential is
committed here: the metered path reads its key from the environment, and the
subscription path copies an existing local credentials file into the task
container.

## Working on codegraff

```bash
scripts/install-hooks.sh          # once
scripts/eval-tier1.sh             # offline, ~20s warm
python3 scripts/eval-tier2.py     # model-backed, opt-in
```

Tier 1 is `zig fmt`, the 600-line ceiling, test reachability, `zig build test`
(suite count never shrinks), named goal/loop/todo invariants, and SDK drift.
Docs-only pushes skip it. In-house PR fixtures: `graff-evals/`
(`--suite inhouse`).

## License

**Modified GNU AGPL-3.0** ([`LICENSE`](LICENSE)). Network use triggers
Section 13. Authors **Rach Pradhan (justrach)** and **Yu Xi Lim (yxlyx)**
reserve the right to offer proprietary or hosted versions. A recipient's AGPL
licence is perpetual unless they breach it. Commercial permission without
copyleft exists only if **both authors grant it jointly in writing**, and is
revocable.

<p align="center"><sub>Built in Zig 0.17 dev · <a href="LICENSE">AGPL-3.0 (modified)</a> · <a href="architecture.md">architecture.md</a> · <a href="CHANGELOG.md">CHANGELOG</a> · <a href="uxlog.md">uxlog.md</a></sub></p>
