# subagent sa-004-ca7d57ca

- label: codebase tour
- kind: workflow_task
- status: ok
- elapsed_ms: 178793
- tools: (none)

## task

Synthesize the reconnaissance results into a clear guided tour of the codebase for the user. Include: project purpose/stack, directory map, main execution flow, key modules, how to run/test, risks/hotspots, and recommended next exploration steps. Previous phase results:
### architecture map
## Verified architecture map

### Tech stack
- **Core CLI/agent:** Zig 0.16, built as a single `graff` executable; `build.zig` names the executable `graff` and points its root source at `src/main.zig` (`build.zig:42-49`). README describes it as “a minimal agentic coding harness in Zig 0.16,” using `std.http.Client`, `std.json`, and `std.Io` for HTTPS, JSON, and parallel tool/subagent execution (`README.md:4-5`, `README.md:25-28`).
- **Desktop GUI:** Tauri 2 + Rust backend + React/TypeScript/Vite frontend. The GUI package depends on React 19, Tauri API/plugin packages, Vite, TypeScript, Zustand, dockview, etc. (`gui/package.json:18-40`, `gui/package.json:42-60`); the Rust crate is `codegraff-gui`, edition 2024, with Tauri, Tokio, Diesel/SQLite, serde, reqwest/rustls, and portable-pty dependencies (`gui/src-tauri/Cargo.toml:7-20`, `gui/src-tauri/Cargo.toml:25-52`).
- **Monorepo/tooling:** root package is a Bun workspace covering `gui` and `packages/*` (`package.json:1-8`).
- **Reusable UI package:** `@codegraff/diffs` is a TypeScript package for lightweight diff/file-change rendering, exported for plain and React use (`packages/diffs/package.json:1-24`).

### Top-level directories / major areas
- **`src/`**: Zig CLI/agent implementation; `build.zig` compiles `src/main.zig` as `graff` (`build.zig:42-49`), and `src/mcp.zig` is a stdio MCP client (`src/mcp.zig:1-12`).
- **`gui/`**: Tauri desktop app with React frontend and Rust backend; frontend entry renders `App` (`gui/src/main.tsx:1-13`), Rust entry calls `codegraff_gui_lib::run()` (`gui/src-tauri/src/main.rs:4-6`).
- **`packages/diffs/`**: shared diff-rendering library consumed by the GUI via workspace dependency (`gui/package.json:18-21`, `packages/diffs/package.json:12-24`).
- **`sdk/` and `examples/`**: SDK/example support exists in the repo tree; README advertises “SDKs — TypeScript & Python” in the docs navigation (`README.md:30-41`). I did not deep-read these because the main runtime/GUI paths were more load-bearing.
- **`docs/`, `plans/`, `.github/`**: documentation, planning notes, and CI/release workflows observed in the repository tree (`codedb tree`, this run).

### Main entry points
- **CLI build/runtime entry:** `build.zig` configures build options, version stamping, telemetry endpoint, and installs the `graff` executable from `src/main.zig` (`build.zig:7-40`, `build.zig:42-51`). `src/main.zig` has `pub fn main(init: std.process.Init) !void` and parses CLI flags including `--yolo`, `--json`, `--schema`, `--model`, `--resume`, etc. (`src/main.zig:4307-4385`).
- **CLI protocol surfaces:** `src/main.zig` embeds a JSON stdio protocol for `--json`, including user/control requests and streamed event types like `text`, `reasoning`, `tool_call`, `tool_result`, `turn`, and `error` (`src/main.zig:79-111`). It also embeds an HTTP bridge schema for `graff serve` with `/healthz`, `/v1/schema`, session create/message/delete endpoints (`src/main.zig:114-128`).
- **GUI frontend entry:** `gui/src/main.tsx` imports styles and renders `<App />` inside React `StrictMode` (`gui/src/main.tsx:1-13`).
- **GUI Rust entry:** `gui/src-tauri/src/main.rs` calls `codegraff_gui_lib::run()` (`gui/src-tauri/src/main.rs:4-6`); `run()` builds the Tauri app, installs plugins, initializes app data/project store, manages `DesktopState`, registers invoke commands, and runs the Tauri context (`gui/src-tauri/src/lib.rs:49-85`, `gui/src-tauri/src/lib.rs:108-176`).

### Core modules
- **Zig agent loop (`src/main.zig`)**
  - `Agent` owns allocator/arena, shared HTTP client, provider, message history, MCP registry, approval/tracing state, system prompts, tool JSON variants, todo state, and runtime options (`src/main.zig:8163-8224`).
  - `Agent.runTurn()` repeatedly sends a model request, dispatches provider-specific response parsing for Anthropic/OpenAI/Responses, and returns once a final text is produced (`src/main.zig:8316-8335`).
  - `Agent.request()` builds provider body, optionally streams root requests, retries flaky HTTP failures, and emits JSON events for GUI/SDK clients (`src/main.zig:8337-8365`).
  - `Agent.runTools()` separates meta tools from external tools, gates/rejects tools, and runs external calls in parallel via `io.async(execTool, ...)`, then joins all futures (`src/main.zig:8807-8870`).
  - `execTool()` applies codedb/companion/hook gates, calls `execToolInner`, records tracing/telemetry/tool-use, and returns structured tool output (`src/main.zig:11809-11831`).
  - `execSubagent()` prevents nested subagents, validates prompt input, and delegates to `runSub()` (`src/main.zig:12484-12494`); `runSub()` creates a fresh `Agent` with fresh history but shared client/provider and runs it to completion (`src/main.zig:12512-12537`, `src/main.zig:12549-12587`).
  - `execWorkflow()` models workflows as sequential phases of parallel subagent tasks, capped at 5 phases and 8 tasks per phase, carrying previous phase results via `{{prev}}` or appended text (`src/main.zig:12594-12600`, `src/main.zig:12601-12617`, `src/main.zig:12635-12672`, `src/main.zig:12675-12698`).

- **MCP client (`src/mcp.zig`)**
  - `src/mcp.zig` is a minimal MCP client over stdio JSON-RPC: it spawns servers from `.mcp.json`, runs `initialize → initialized → tools/list`, exposes namespaced tools, and routes `tools/call` back to the server (`src/mcp.zig:1-12`, `src/mcp.zig:84-120`, `src/mcp.zig:229-323`, `src/mcp.zig:334-404`).
  - MCP access is serialized with a registry mutex because each server has one bidirectional stdio pipe (`src/mcp.zig:8-11`, `src/mcp.zig:355-360`).

- **GUI app shell/state**
  - `App` wraps the UI in `SessionProvider` and `DragDropProvider`, then renders `AppShell` (`gui/src/app/App.tsx:385-396`).
  - `AppShell` composes theme/sidebar/settings state, `ProjectSidebar`, settings panes, and `WorkspaceBoard` inside resizable panels (`gui/src/app/App.tsx:123-170`, `gui/src/app/App.tsx:265-379`).
  - `SessionProvider` is the main frontend orchestrator: it applies snapshots into `sessionStore`, bootstraps via `useSessionBootstrap`, opens workspace paths forwarded from the launcher, and exposes action methods through `SessionActionsContext` (`gui/src/app/SessionProvider.tsx:55-92`, `gui/src/app/SessionProvider.tsx:127-178`, `gui/src/app/SessionProvider.tsx:651-655`).
  - Prompt submission reads active workspace/conversation, appends attachments, clears draft/attachments, calls `desktopClient.sendPrompt`, then applies the returned snapshot (`gui/src/app/SessionProvider.tsx:563-619`).

- **Frontend desktop boundary (`gui/src/services/desktop/client.ts`)**
  - `desktop/client.ts` wraps Tauri `invoke` and `listen`, with a QA mock mode that replaces Tauri calls with deterministic fixtures (`gui/src/services/desktop/client.ts:1-10`, `gui/src/services/desktop/client.ts:56-60`, `gui/src/services/desktop/client.ts:266-319`, `gui/src/services/desktop/client.ts:321-336`).
  - It exports typed functions for workspace/session/prompt/provider/MCP/git/layout/terminal commands; e.g. `openWorkspace`, `getSessionSnapshot`, `sendPrompt`, `runSlashCommand`, MCP functions, provider auth, saved workspaces, and terminal event listeners (`gui/src/services/desktop/client.ts:338-457`, `gui/src/services/desktop/client.ts:529-590`, `gui/src/services/desktop/client.ts:691-800`).

- **Tauri command layer (`gui/src-tauri/src/commands.rs`)**
  - Commands are thin Tauri adapters that map frontend invocations to `DesktopState.manager` methods and convert errors with `format_error_chain` (`gui/src-tauri/src/commands.rs:20-22`, `gui/src-tauri/src/commands.rs:48-80`, `gui/src-tauri/src/commands.rs:155-180`).
  - The command layer also owns some local desktop/file/git helpers: file pickers, pasted image persistence/thumbnailing, workspace-confined file reads, `git clone`, GitHub project creation, and terminal commands (`gui/src-tauri/src/commands.rs:24-46`, `gui/src-tauri/src/commands.rs:252-292`, `gui/src-tauri/src/commands.rs:626-694`, `gui/src-tauri/src/commands.rs:839-958`, `gui/src-tauri/src/commands.rs:781-827`).

- **Desktop runtime adapter (`gui/src-tauri/src/runtime/simple.rs`)**
  - `RuntimeManager` coordinates GUI state, project registry, active `graff --json` sessions, and UI event emission (`gui/src-tauri/src/runtime/simple.rs:104-130`).
  - It maintains `RuntimeState` containing active workspace/conversation, conversations, model/provider selections, pending followups, and model catalog (`gui/src-tauri/src/runtime/simple.rs:51-73`).
  - Each conversation can own a persistent `GraffSession` child process, preserving context and KV cache across turns (`gui/src-tauri/src/runtime/simple.rs:85-97`).
  - `send_prompt()` creates/updates conversation state, queues concurrent prompts, emits snapshots, optionally generates a title, and drives `stream_turn()` (`gui/src-tauri/src/runtime/simple.rs:467-688`).
  - `stream_turn()` writes `{type:"user", text: prompt}` to the child, reads JSONL events, translates them into GUI messages/followups/tool rows/errors, emits snapshots during streaming, and releases session IO at turn end (`gui/src-tauri/src/runtime/simple.rs:690-1005`).
  - `acquire_session_io()` spawns a `graff --json` child on first use and sends live controls for agent, plan mode, effort, fast mode, and ultracode (`gui/src-tauri/src/runtime/simple.rs:1126-1203`).

- **Persistence (`gui/src-tauri/src/persistence/project_store.rs`)**
  - `ProjectStore` uses Diesel with SQLite, with a mutex around connections (`gui/src-tauri/src/persistence/project_store.rs:1-10`, `gui/src-tauri/src/persistence/project_store.rs:31-36`, `gui/src-tauri/src/persistence/project_store.rs:534-544`).
  - It stores opened projects, managed chat workspaces, conversation layouts, saved workspaces, and saved workspace layouts; tables are created/migrated in `init()` (`gui/src-tauri/src/persistence/project_store.rs:460-514`).
  - It supports project registration/listing, managed chat workspace creation, conversation layout save/load, and saved workspace CRUD (`gui/src-tauri/src/persistence/project_store.rs:71-148`, `gui/src-tauri/src/persistence/project_store.rs:286-323`, `gui/src-tauri/src/persistence/project_store.rs:325-458`).

## Data/control flow

### CLI flow
1. User runs `graff`; `build.zig` builds `src/main.zig` as the `graff` executable (`build.zig:42-51`), and `main()` parses CLI/session/model/protocol flags (`src/main.zig:4307-4385`).
2. A root `Agent` holds provider, messages, tools, registry, approvals, tracing, and state (`src/main.zig:8163-8224`).
3. `Agent.runTurn()` loops: build/post request → provider-specific step parsing → if model requests tools, execute them → continue until final text (`src/main.zig:8316-8335`).
4. External tools run concurrently via `io.async`; meta tools are handled inline, gated tools can be denied, and all futures are joined before result processing (`src/main.zig:8807-8870`).
5. Subagents/workflows are just tool execution paths that instantiate isolated child `Agent` loops or phase/task fan-outs (`src/main.zig:12484-12587`, `src/main.zig:12597-12698`).
6. MCP tools are discovered from `.mcp.json`, namespaced as `mcp__<server>__<tool>`, and invoked via JSON-RPC `tools/call` over server stdio (`src/mcp.zig:84-120`, `src/mcp.zig:298-323`, `src/mcp.zig:334-404`).

### Desktop GUI flow
1. React renders `App`, which mounts `SessionProvider`, drag/drop context, and `AppShell` (`gui/src/main.tsx:9-13`, `gui/src/app/App.tsx:385-396`).
2. `AppShell` displays sidebar/settings/workspace board and waits for session bootstrap before showing the main shell (`gui/src/app/App.tsx:253-263`, `gui/src/app/App.tsx:265-379`).
3. `SessionProvider` exposes UI actions and calls `desktopClient` methods; opening a workspace calls `desktopClient.openWorkspace`, applies the returned snapshot, and loads runtime/prompt metadata (`gui/src/app/SessionProvider.tsx:127-149`).
4. `desktopClient` converts frontend calls into Tauri invokes/listens, or mock responses under `VITE_CODEGRAFF_QA_MOCK=1` (`gui/src/services/desktop/client.ts:311-319`, `gui/src/services/desktop/client.ts:321-336`).
5. Tauri `commands.rs` maps invokes to `DesktopState.manager` methods (`gui/src-tauri/src/commands.rs:48-80`, `gui/src-tauri/src/commands.rs:155-180`).
6. `RuntimeManager.send_prompt()` updates conversation state, emits snapshots, then `stream_turn()` writes a JSON user event to the persistent `graff --json` child and translates streamed JSONL events back into GUI messages (`gui/src-tauri/src/runtime/simple.rs:467-688`, `gui/src-tauri/src/runtime/simple.rs:690-1005`).
7. UI receives live session updates through the Tauri emitter; `emit()` builds a snapshot and calls `emit_session_updated` (`gui/src-tauri/src/runtime/simple.rs:1074-1079`), while frontend listens via `listenSessionUpdates` (`gui/src/services/desktop/client.ts:752-756`).

## Inferred architecture
- The repo is effectively **two runtimes sharing one agent core**: terminal users talk directly to the Zig `graff` REPL/JSON/HTTP surfaces, while desktop users talk to a Tauri/Rust adapter that keeps long-lived `graff --json` child processes per conversation. This is inferred by combining the CLI `--json` schema (`src/main.zig:79-111`) with `RuntimeManager`’s persistent `GraffSession` design (`gui/src-tauri/src/runtime/simple.rs:85-97`) and child-session streaming (`gui/src-tauri/src/runtime/simple.rs:690-1005`).
- The GUI Rust layer is intentionally a **thin adapter**, not a replacement agent runtime: comments describe it as coordinating the copied desktop GUI with the Zig-native binary (`gui/src-tauri/src/runtime/simple.rs:104-105`), and many commands simply delegate to `state.manager` (`gui/src-tauri/src/commands.rs:48-80`, `gui/src-tauri/src/commands.rs:155-180`).

## 3 most load-bearing facts
1. The **agent core is `src/main.zig`**, compiled into `graff`, and it owns provider requests, tool execution, subagents, workflows, and JSON/HTTP protocols (`build.zig:42-49`, `src/main.zig:8316-8365`, `src/main.zig:8807-8870`).
2. The **desktop app does not reimplement the agent loop**; it spawns and streams from persistent `graff --json` child processes per conversation (`gui/src-tauri/src/runtime/simple.rs:85-97`, `gui/src-tauri/src/runtime/simple.rs:1126-1203`).
3. The **main UI state transition unit is a `SessionSnapshot`**: frontend actions call `desktopClient`, Tauri commands delegate to `RuntimeManager`, runtime emits snapshots, and frontend applies snapshots into `sessionStore` (`gui/src/app/SessionProvider.tsx:61-65`, `gui/src/services/desktop/client.ts:371-432`, `gui/src-tauri/src/runtime/simple.rs:1074-1079`).

## Open question
- `src/main.zig` is central and very large, but it was not indexed by `codedb` during this run; why is it absent from the codedb index despite being the root CLI source referenced by `build.zig`?

[subagent sa-003-995d48a9 · inspect: .graff/subagents/sa-003-995d48a9.md]

### build test config
## Verified repository build/run/test/lint/config map

### 1) Top-level project structure and package manager

- The repository is a mixed Zig CLI + Bun workspace + Tauri/Rust desktop app + SDKs repo. The root `package.json` is private, pins `bun@1.3.10`, and declares workspaces `gui` and `packages/*`; it has no root `scripts` block. (`package.json:1-9`)
- The main Zig build creates a single executable named `graff` from `src/main.zig`. (`build.zig:42-51`)
- The GUI is a separate Bun workspace package named `codegraff-gui`, also pinned to `bun@1.3.10`. (`gui/package.json:1-7`)
- The reusable diff renderer is a workspace package named `@codegraff/diffs`. (`packages/diffs/package.json:1-7`)

### 2) CLI / Zig build and run

**Build:**

```sh
zig build
```

- CI runs exactly `zig build`. (`.github/workflows/ci.yml:39-40`)
- The Zig build installs the `graff` artifact via `b.installArtifact(exe)`. (`build.zig:42-51`)

**Run from source:**

```sh
zig build run
# or
./zig-out/bin/graff
```

- `build.zig` defines a `run` step that runs the built executable. (`build.zig:53-56`)
- README documents `zig build run` and `./zig-out/bin/graff` as in-place alternatives. (`README.md:692-699`)

**Release/cross-compile:**

```sh
zig build -Doptimize=ReleaseSafe -Dtarget="$target" -Dversion="$VERSION" -Dtelemetry-endpoint="$TELEMETRY_ENDPOINT"
```

- Release CI runs that command for `aarch64-macos`, `x86_64-macos`, `x86_64-linux`, and `aarch64-linux`. (`.github/workflows/release.yml:24-33`)
- Release artifacts are tarballs containing `graff`, `README.md`, and `LICENSE`, plus `SHA256SUMS`. (`.github/workflows/release.yml:34-40`)
- Release is triggered by tags matching `v*`. (`.github/workflows/release.yml:6-8`)

**Versioning / build options:**

- `-Dversion=...` overrides the version string; otherwise `build.zig` derives it from `git describe --tags --always --dirty`, falling back to `0.1.0-dev`. (`build.zig:7-25`)
- `-Dtelemetry-endpoint=...` sets a baked-in default OTLP endpoint; passing `-Dtelemetry-endpoint=""` disables it. (`build.zig:26-37`)

### 3) CLI tests, formatting, and CI checks

**Unit tests:**

```sh
zig build test
zig build test --summary all
```

- `build.zig` defines a `test` step using `src/main.zig` as the test root. (`build.zig:58-69`)
- CI runs `zig build test --summary all`. (`.github/workflows/ci.yml:45-46`)
- README documents `zig build test` as the test suite. (`README.md:697-699`)

**Formatting/lint-equivalent for Zig:**

```sh
zig fmt --check src/main.zig src/mcp.zig build.zig
```

- CI enforces that exact `zig fmt --check` command. (`.github/workflows/ci.yml:42-43`)

**Protocol/JSON control test:**

```sh
python3 scripts/test-json-controls.py zig-out/bin/graff
```

- CI runs that exact command after building `graff`. (`.github/workflows/ci.yml:48-49`)

**SDK drift check:**

```sh
python3 sdk/generate.py --harness ./zig-out/bin/graff
git diff --exit-code sdk/
```

- CI regenerates SDKs with the built binary and fails if `sdk/` changes. (`.github/workflows/ci.yml:51-55`)

**CI toolchain assumption:**

- CI pins Zig to `0.16.0`. (`.github/workflows/ci.yml:34-37`)
- The installer also says the harness needs Zig 0.16 and warns on other versions. (`install.sh:41-51`)

### 4) CLI install flow and environment overrides

**Install latest release / fallback to source:**

```sh
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
# or from checkout:
./install.sh
```

- README documents the release installer command. (`README.md:56-64`)
- README says from a checkout run `./install.sh`, installing to `~/bin` by default, overridable by `HARNESS_DIR`. (`README.md:66-67`)
- `install.sh` defaults `HARNESS_REPO` to `https://github.com/justrach/codegraff`, `HARNESS_DIR` to `$HOME/bin`, and binary name to `graff`. (`install.sh:11-16`)
- `HARNESS_BUILD=source` skips release download and forces source build. (`install.sh:11-12`, `install.sh:171-175`)
- Source install runs:

```sh
zig build -Doptimize=ReleaseFast
```

  (`install.sh:149-152`)

- The installer creates a compatibility symlink from `harness` to `graff`. (`install.sh:179-181`)
- Optional companion suite install can be skipped with `HARNESS_NO_GRAFF=1`; optional `kuri` install is enabled with `HARNESS_WITH_KURI=1`. (`install.sh:183-207`, `install.sh:209-224`)

### 5) CLI runtime credentials/config assumptions

- API keys can be supplied by login, key storage, or environment variables; examples include `graff login`, `graff key set deepseek sk-...`, and `export DEEPSEEK_API_KEY=sk-...`. (`README.md:74-82`)
- Provider environment variables documented include `ANTHROPIC_API_KEY`, `CODEGRAFF_API_KEY`, `DEEPSEEK_API_KEY`, `OPENAI_API_KEY`, `MINIMAX_API_KEY`, `XIAOMI_API_KEY`, `KIMI_API_KEY`, `XAI_API_KEY`, and `ZAI_API_KEY`; Codex uses `~/.codex/auth.json`. (`README.md:219-228`)
- Stored keys live in macOS Keychain using service `simple-harness`; elsewhere in `0600` `~/.simple-harness-keys.json`; environment variables win. (`README.md:712-716`)
- `graff login` writes the Codegraff device-flow key to `~/.simple-harness-codegraff.json`; `graff login codex` writes `~/.codex/auth.json`. (`README.md:721-727`)

### 6) Telemetry/tracing assumptions

- The CLI writes `harness.trace.jsonl` in the current working directory when tracing is enabled, truncating it at startup for the current session. (`README.md:644-650`)
- Release telemetry can be opted out with `--no-telemetry` or `GRAFF_NO_TELEMETRY=1`; env endpoints `OTEL_EXPORTER_OTLP_ENDPOINT` or `GRAFF_OTEL_ENDPOINT` override the default. (`README.md:652-659`)
- **Important verified discrepancy:** `build.zig` currently bakes the telemetry endpoint by default for “release, source-install, and dev” builds unless `-Dtelemetry-endpoint=""` is passed. (`build.zig:26-37`) README says “Builds from source have no endpoint baked in” unless an env endpoint is set. (`README.md:656-659`) Those two statements conflict.

### 7) GUI / frontend build, dev, test, lint

The GUI package scripts are:

```sh
cd gui
bun run dev
bun run build
bun run lint
bun run preview
bun run tauri
bun test
```

- `dev` runs `bun run build:deps && vite`. (`gui/package.json:8-10`)
- `build:deps` runs `bun run --filter '@codegraff/diffs' build`. (`gui/package.json:10-12`)
- `build` runs `bun run build:deps && bun run gen:desktop-contracts && tsc -b && vite build`. (`gui/package.json:12`)
- `lint` runs `bun run build:deps && bun run gen:desktop-contracts && eslint .`. (`gui/package.json:13`)
- `test` runs `bun test`. (`gui/package.json:16`)
- `preview` runs `vite preview`; `tauri` delegates to the Tauri CLI. (`gui/package.json:14-15`)

**Desktop contract generation:**

```sh
cd gui
bun run gen:desktop-contracts
```

- This runs:

```sh
cargo run --quiet --manifest-path src-tauri/Cargo.toml --example generate_desktop_contracts
```

  (`gui/package.json:10`)

**Vite config:**

- Vite uses Tailwind, React, and Babel with React Compiler preset. (`gui/vite.config.ts:8-15`)
- Vite aliases `@` to `gui/src`. (`gui/vite.config.ts:16-20`)

**TypeScript config:**

- `tsc -b` builds references to `tsconfig.app.json` and `tsconfig.node.json`. (`gui/tsconfig.json:9-13`)
- App TS target is `es2023`, module `esnext`, bundler resolution, React JSX, `noEmit`, `noUnusedLocals`, `noUnusedParameters`, `erasableSyntaxOnly`, and `noFallthroughCasesInSwitch`. (`gui/tsconfig.app.json:2-29`)
- Node TS config includes only `vite.config.ts`. (`gui/tsconfig.node.json:17-23`)

**ESLint config:**

- ESLint ignores `dist`, `vendor/**`, `src-tauri/gen/**`, and `src-tauri/target/**`. (`gui/eslint.config.js:8-14`)
- It applies to `**/*.{ts,tsx}` and extends JS recommended, TypeScript recommended, React Hooks latest, and React Refresh Vite configs. (`gui/eslint.config.js:15-22`)
- It enforces `react-refresh/only-export-components`, allowing constant exports and `useSidebar`. (`gui/eslint.config.js:27-34`)

### 8) GUI / Tauri run and package flow

Likely commands:

```sh
cd gui
bun run tauri dev
bun run tauri build
```

Evidence:

- `gui/package.json` exposes `"tauri": "tauri"`. (`gui/package.json:14-15`)
- Tauri config says dev uses `devUrl` `http://localhost:5173`, and `beforeDevCommand` is `bun run dev`. (`gui/src-tauri/tauri.conf.json:6-10`)
- Tauri config says packaged frontend is `../dist`, and `beforeBuildCommand` is `bun run build`. (`gui/src-tauri/tauri.conf.json:6-10`)
- The bundle includes external binary `binaries/graff`, targets all bundle formats, and has macOS signing identity `Developer ID Application: Rachit Pradhan (WWP9DLJ27P)` with hardened runtime enabled. (`gui/src-tauri/tauri.conf.json:35-49`)

**Tauri/Rust assumptions:**

- The Rust crate is its own workspace root; the empty `[workspace]` prevents Cargo from walking up to a parent workspace. (`gui/src-tauri/Cargo.toml:1-5`)
- Rust package is `codegraff-gui` version `0.0.13`, edition `2024`, and requires Rust `1.92`. (`gui/src-tauri/Cargo.toml:7-16`)
- It uses Tauri `2.10.3` with `macos-private-api`. (`gui/src-tauri/Cargo.toml:39`)
- Tauri app identifier is `dev.codegraff.gui`; product name is `Codegraff`. (`gui/src-tauri/tauri.conf.json:1-5`)

**GUI runtime engine discovery:**

- The GUI spawns `graff --json --yolo --resume <conversation_id>`, optionally `--model <model>`, in the workspace directory. (`gui/src-tauri/src/runtime/simple.rs:2626-2649`)
- The GUI passes a login-shell environment into the spawned `graff`, explicitly to make shell-exported provider keys visible to GUI launches. (`gui/src-tauri/src/runtime/simple.rs:2641-2647`)
- That login-shell env is collected by running `$SHELL -ilc env`, defaulting `SHELL` to `/bin/zsh`, with a 4-second timeout. (`gui/src-tauri/src/runtime/simple.rs:2588-2613`)
- The GUI binary lookup order is: `CODEGRAFF_GUI_BINARY`, bundled sidecar next to current executable, `../../zig-out/bin/graff`, known install locations like `~/bin/graff`, `/opt/homebrew/bin/graff`, `/usr/local/bin/graff`, then bare `graff` on inherited `PATH`. (`gui/src-tauri/src/runtime/simple.rs:3240-3300`)
- If spawning fails, the GUI error tells the user to install the CLI or set `CODEGRAFF_GUI_BINARY`. (`gui/src-tauri/src/runtime/simple.rs:2652-2657`)

**Tauri debug bridge:**

- In debug builds only, the app starts `debug_bridge::DebugBridge`. (`gui/src-tauri/src/lib.rs:92-97`)
- The `scripts/tdev` helper talks to that dev-only bridge at `http://127.0.0.1:9233`. (`scripts/tdev:1-7`, `scripts/tdev:26`)
- `scripts/tdev` supports `health`, `eval`, `shot`, `click`, `type`, and `key`. (`scripts/tdev:9-15`, `scripts/tdev:37-75`)

### 9) Rust/Tauri tests

Verified but not wired into package scripts/CI:

- `gui/src-tauri/src/runtime/simple.rs` contains Rust `#[test]` declarations under a tests module. (`gui/src-tauri/src/runtime/simple.rs:4001-4259`)
- `gui/src-tauri/Cargo.toml` has `pretty_assertions` as a dev dependency. (`gui/src-tauri/Cargo.toml:54-56`)

**Inferred exact command:**

```sh
cargo test --manifest-path gui/src-tauri/Cargo.toml
```

This command is not found in CI or package scripts; it is inferred from the Cargo manifest and Rust tests.

### 10) Shared diff package build/test

```sh
cd packages/diffs
bun run build
bun test
```

- `@codegraff/diffs` build script is `tsc -p tsconfig.build.json`. (`packages/diffs/package.json:23-25`)
- Its test script is `bun test`. (`packages/diffs/package.json:23-26`)
- Its build emits declarations, declaration maps, source maps, and JS into `dist` from `src`, excluding `test`. (`packages/diffs/tsconfig.build.json:1-14`)
- Its TS config is strict, targets ES2022, uses bundler module resolution, React JSX, and `bun-types`. (`packages/diffs/tsconfig.json:2-16`)

### 11) SDK generation, validation, and publishing

**Regenerate SDKs locally:**

```sh
python3 sdk/generate.py --harness ./zig-out/bin/graff
# or
graff --schema | python3 sdk/generate.py
```

- SDK README documents both commands. (`sdk/README.md:13-18`)
- `sdk/generate.py` accepts `--schema`, `--harness`, or stdin; `--harness` runs `<binary> --schema`. (`sdk/generate.py:22-32`)
- SDKs are auto-generated and should not be hand-edited. (`sdk/README.md:1-5`)

**CI SDK validation:**

- Python smoke test imports `sdk/py/harness_sdk.py` and asserts `MODELS` and `TOOLS`. (`.github/workflows/ci.yml:15-16`)
- TS validation parses `sdk/ts/package.json` and uses Node’s experimental type stripping to import `sdk/ts/harness.ts`, checking `Harness`, `runAgent`, and `MODELS`. (`.github/workflows/ci.yml:18-25`)

**SDK package metadata:**

- Python SDK package is `codegraff`, version `0.3.1`, requires Python `>=3.8`, and uses setuptools. (`sdk/py/pyproject.toml:1-20`)
- TypeScript SDK package is `@codegraff/sdk`, version `0.3.1`, exports `harness.ts` and `remote.ts`, and requires Node `>=18`. (`sdk/ts/package.json:1-31`)

**Publish flow:**

- SDK publishing triggers on tags matching `sdk-v*`. (`.github/workflows/sdk.yml:6-8`)
- PyPI build uses Python `3.12`, rewrites `pyproject.toml` version from the tag, installs `build`, and runs `python3 -m build`. (`.github/workflows/sdk.yml:20-30`)
- npm publish uses Node `24`, updates package version from the tag, and runs `npm publish --access public`. (`.github/workflows/sdk.yml:35-44`)

### 12) Remote / edge example

**Local edge-worker smoke flow:**

```sh
harness serve --port 8926 --token edge-test
npx wrangler dev --port 8970
curl http://127.0.0.1:8970
curl -N 'http://127.0.0.1:8970/?q=run:%20echo%20hi'
```

- The edge-worker README documents those commands. (`examples/edge-worker/README.md:8-13`)
- `wrangler.toml` also documents the bridge and `wrangler dev` local check. (`examples/edge-worker/wrangler.toml:1-5`)
- Worker config sets `name = "harness-edge-worker"`, `main = "src/index.ts"`, compatibility date `2026-04-01`, and `BRIDGE_URL = "http://127.0.0.1:8926"`. (`examples/edge-worker/wrangler.toml:8-14`)
- For real deploy, the docs say front the bridge with TLS and store the token using `npx wrangler secret put BRIDGE_TOKEN`. (`examples/edge-worker/README.md:20-22`)

## Inferred / not directly wired

- `cd gui && bun run tauri dev` and `cd gui && bun run tauri build` are the likely desktop dev/package commands because the GUI exposes `"tauri": "tauri"` and Tauri config defines `beforeDevCommand`/`beforeBuildCommand`; I did not find these exact commands in CI. (`gui/package.json:14-15`, `gui/src-tauri/tauri.conf.json:6-10`)
- `cargo test --manifest-path gui/src-tauri/Cargo.toml` is the likely Rust/Tauri unit-test command because Rust tests and dev-dependencies exist, but it is not wired into the package scripts or GitHub Actions I inspected. (`gui/src-tauri/src/runtime/simple.rs:4001-4259`, `gui/src-tauri/Cargo.toml:54-56`)
- Dependency install is likely `bun install` at the repo root because the root package declares Bun workspaces and pins Bun, but there is no explicit install script. (`package.json:1-9`)

## 3 most load-bearing facts

1. **The authoritative CI path for the CLI is Zig 0.16.0 with `zig build`, `zig fmt --check src/main.zig src/mcp.zig build.zig`, `zig build test --summary all`, JSON protocol test, and SDK drift check.** (`.github/workflows/ci.yml:27-55`)
2. **The GUI build pipeline is `bun run build:deps && bun run gen:desktop-contracts && tsc -b && vite build`; lint runs the same presteps then `eslint .`; tests are `bun test`.** (`gui/package.json:8-17`)
3. **The desktop app depends on finding a usable `graff` binary, with `CODEGRAFF_GUI_BINARY` as the first override and bundled/installed/dev locations as fallbacks.** (`gui/src-tauri/src/runtime/simple.rs:3240-3300`)

## Open question

- **Which telemetry behavior is intended for source/dev builds?** `build.zig` says every build gets the default endpoint unless disabled with `-Dtelemetry-endpoint=""`, while README says source builds have no endpoint baked in unless env vars are set. (`build.zig:26-37`, `README.md:656-659`)

[subagent sa-002-e9970bea · inspect: .graff/subagents/sa-002-e9970bea.md]

### feature inventory
## Verified inventory of main product features / user-facing flows

### 1. Core product: `graff` agent harness (CLI/REPL + one-shot + JSON protocol)
- The repository’s primary CLI is `graff`, described as a minimal agentic coding harness that talks to Anthropic, OpenAI-compatible endpoints, and ChatGPT/Codex subscription credentials. `README.md:1-6`
- The harness loop sends user text to a model, executes model-requested tools in parallel, feeds results back, and repeats until the model stops. `README.md:17-28`
- User-facing install/run flows include `graff`, `graff --model ...`, `graff -p "prompt"` one-shot mode, login/key management, `--schema`, and JSON protocol mode. `README.md:279-300`
- The REPL exposes slash commands such as `/model`, `/plan`, `/key`, `/reasoning`, `/compact`, `/save`, `/resume`, `/todo`, `/mcp`, and `/help`. `README.md:317-346`
- The harness supports permission-gated tools (`bash`, file reads/writes/edits, MCP tools), plus modes such as `yolo`, `plan`, and `strict`. `README.md:364-398`
- The harness supports subagents and workflow fan-out, including an “ultracode” codeword that steers work into multi-agent workflow mode. `README.md:541-560`

### 2. Desktop GUI / Codegraff app shell
- The desktop app is a Tauri GUI over the `graff` agent CLI; README says the macOS desktop app installs a `codegraff` launcher and runs whatever `graff` is on `PATH`. `README.md:46-51`
- The React app boots through `SessionProvider`, `DragDropProvider`, and `AppShell`; `/success` is a special route for provider OAuth success UI. `gui/src/app/App.tsx:385-395`
- `AppShell` renders a resizable sidebar + content area, global theme toggle, sidebar toggle, new-chat trigger, settings panes, and the main `WorkspaceBoard`. `gui/src/app/App.tsx:265-379`
- The global Cmd/Ctrl+N shortcut calls the same `NewChatTrigger` flow as the button. `gui/src/app/App.tsx:235-250`
- The content switches between settings (`ProvidersSettingsPane`, `McpSettingsPane`, `GeneralSettingsPane`) and the workspace/chat board. `gui/src/app/App.tsx:359-375`

### 3. Session bootstrap, state, and live updates
- `SessionProvider` calls `useSessionBootstrap`, persists the latest active workspace path in local storage, and exposes session actions through context. `gui/src/app/SessionProvider.tsx:89-103`, `gui/src/app/SessionProvider.tsx:651-655`
- `useSessionBootstrap` subscribes to backend session-update events, gets an initial snapshot, tries to reopen the latest workspace, then falls back to creating a managed chat. `gui/src/hooks/useSessionBootstrap.ts:28-88`
- Cold-start and single-instance `codegraff <path>` flows are wired through `drainPendingOpen` and `open-workspace-path`; `SessionProvider` opens either pending or forwarded paths. `gui/src/app/SessionProvider.tsx:151-178`
- The Tauri backend stores cold-start CLI args in `PendingOpen`, emits `open-workspace-path` for second instances, and focuses the main window. `gui/src-tauri/src/lib.rs:53-63`, `gui/src-tauri/src/lib.rs:86-89`, `gui/src-tauri/src/lib.rs:197-200`

### 4. Sidebar flows: saved workspaces, managed chats, projects, settings
- `ProjectSidebar` has sections for saved “Workspaces”, standalone “Chats” / managed chats, and “Projects”. `gui/src/components/ProjectSidebar.tsx:244-423`
- Sidebar actions include opening a project folder, selecting chats, opening saved workspaces, starting new chats, archiving conversations/workspaces, and renaming/deleting saved workspaces. `gui/src/components/ProjectSidebar.tsx:74-85`, `gui/src/components/ProjectSidebar.tsx:103-148`
- In settings mode, the sidebar becomes a settings navigator with General, Providers, and MCP sections. `gui/src/components/ProjectSidebar.tsx:150-225`

### 5. New chat / onboarding / project setup
- `NewChatScreen` is the empty or draft conversation surface; it wires onboarding, provider setup, clone-repository dialog, quick-start project dialog, launch actions, and a prompt section. `gui/src/components/new-chat-screen/NewChatScreen.tsx:81-143`, `gui/src/components/new-chat-screen/NewChatScreen.tsx:259-303`
- The onboarding panel appears when there are no command results and setup is incomplete, based on provider/workspace state. `gui/src/components/new-chat-screen/NewChatScreen.tsx:192-200`
- Project setup supports “open folder”, “clone repository”, and “quick start” flows; the controller calls `pickDirectory`, `cloneRepository`, `quickStartProject`, and `openProject`. `gui/src/components/new-chat-screen/hooks/useNewChatScreenController.ts:149-190`, `gui/src/components/new-chat-screen/hooks/useNewChatScreenController.ts:197-251`
- Backend clone runs `git clone`; backend quick-start runs `gh repo create --clone --add-readme`, validates names, and returns the created directory path. `gui/src-tauri/src/commands.rs:839-884`, `gui/src-tauri/src/commands.rs:913-936`

### 6. Conversation/chat flow
- `ConversationPanel` chooses between `NewChatScreen`, a loading spinner, or the active chat thread + prompt composer. `gui/src/components/ConversationPanel.tsx:65-79`, `gui/src/components/ConversationPanel.tsx:93-127`
- The chat display uses `ChatThread` for messages and local command results, while `PromptComposer` handles followups, goal chips, plan/interrupt prompts, todos, and the prompt input. `gui/src/components/ConversationPanel.tsx:112-126`, `gui/src/components/PromptComposer.tsx:167-234`
- Existing chats and bound chat tiles submit prompts through `useConversationActions`; it appends file/image attachments into the prompt, supports Ultra mode injection, clears composer state, calls `desktopClient.sendPrompt`, and applies the returned snapshot. `gui/src/hooks/useConversationActions.ts:91-135`
- Draft/new-chat submission in `SessionProvider` does the same first-message flow, selecting agent `muse` for planning mode or `forge` otherwise. `gui/src/app/SessionProvider.tsx:563-627`

### 7. Prompt composer capabilities
- The prompt card supports slash-command autocomplete, model picker, reasoning-effort picker, Plan mode, Fast mode, Ultra mode, stop/send behavior, prompt history navigation, drag-drop attachments, and pasted image attachments. `gui/src/components/PromptInputCard.tsx:93-181`, `gui/src/components/PromptInputCard.tsx:199-327`, `gui/src/components/PromptInputCard.tsx:329-621`
- Pasted images are persisted through the Tauri `save_pasted_image` command, then classified as attachments. `gui/src/components/PromptInputCard.tsx:298-325`, `gui/src-tauri/src/commands.rs:252-269`
- Image thumbnails are generated by a backend `image_thumbnail` command that decodes/downscales/re-encodes images as JPEG data URLs. `gui/src-tauri/src/commands.rs:271-292`

### 8. Slash command flow
- The prompt composer first tries to route a draft as a slash command before sending it as a normal prompt. `gui/src/components/PromptComposer.tsx:73-78`
- `useCommandRouter` parses `/command args`, handles local UI commands such as plan/act, new chat, provider settings, MCP settings, delete/archive, compact, and routes other commands to `desktopClient.runSlashCommand`. `gui/src/hooks/useCommandRouter.ts:36-47`, `gui/src/hooks/useCommandRouter.ts:89-117`, `gui/src/hooks/useCommandRouter.ts:120-181`
- Commands needing free-form arguments are completed into the draft instead of immediately run. `gui/src/hooks/useCommandRouter.ts:15-25`, `gui/src/hooks/useCommandRouter.ts:184-217`
- Backend command inventory currently includes `/help`, `/agent`, `/goal`, `/loop`, `/bash`, `/compact`, `/workspace-status`, and `/ultracode`. `gui/src-tauri/src/runtime/simple.rs:450-465`
- Backend command execution handles agent status, persistent ultracode toggle, goal get/set/clear, autonomous `/loop`, conversation compaction, shell `/bash`, and workspace git status payloads. `gui/src-tauri/src/runtime/simple.rs:1236-1428`

### 9. Backend prompt execution / streaming
- Tauri command `send_prompt` forwards frontend prompt submissions to `DesktopState.manager.send_prompt`. `gui/src-tauri/src/commands.rs:155-165`
- `RuntimeManager.send_prompt` creates or selects a conversation, appends the user message, queues prompts if a request is already active, emits a snapshot, optionally auto-generates a title, and then streams the turn. `gui/src-tauri/src/runtime/simple.rs:470-688`
- `stream_turn` writes a JSON user line into a long-lived `graff` session, then maps streamed events into GUI message types: assistant text, reasoning, tool starts/results, followup requests, errors, and turn completion. `gui/src-tauri/src/runtime/simple.rs:692-1005`
- Runtime snapshots include active workspace/conversation, visible messages, active request IDs, todos, goal, followup, all conversation views, registered workspaces, and saved workspaces. `gui/src-tauri/src/runtime/simple.rs:2093-2215`

### 10. Workspace board / multi-chat layout
- `WorkspaceBoard` is a Dockview-based board that renders empty state, workspace draft, single chat, or saved-workspace multi-chat layouts. `gui/src/components/workspace-board/WorkspaceBoard.tsx:51-104`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:538-586`
- Dragging/adding a second chat converts a single-chat selection into a saved workspace by serializing Dockview layout and calling `createSavedWorkspace`. `gui/src/components/workspace-board/WorkspaceBoard.tsx:313-388`
- Saved workspace layouts are restored from saved JSON and persisted on layout changes. `gui/src/components/workspace-board/WorkspaceBoard.tsx:63-83`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:238-302`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:439-481`
- `ChatTile` is the inner Dockview layout for one chat; it hosts the conversation pane plus auxiliary preview, terminal, and changes panes. `gui/src/components/workspace-board/ChatTile.tsx:495-540`, `gui/src/components/workspace-board/ChatTile.tsx:729-781`
- Per-conversation layout is saved and restored with `saveConversationLayout` / `getConversationLayout`. `gui/src/components/workspace-board/ChatTile.tsx:147-162`, `gui/src/components/workspace-board/ChatTile.tsx:572-608`

### 11. Changes/diff/git flow
- The Changes pane derives file changes from conversation messages, resolves renderable diffs, shows additions/deletions, lets files open in an editor, and shows commit/push actions when git actions are available. `gui/src/components/workspace-board/ChangesPane.tsx:199-246`, `gui/src/components/workspace-board/ChangesPane.tsx:248-349`
- Git actions in session context include checkout branch, create branch, commit, push, and open workspace in a target app. `gui/src/app/SessionProvider.tsx:180-228`, `gui/src/app/SessionProvider.tsx:376-385`
- Backend git commands route through `RuntimeManager` for checkout/create/commit/push. `gui/src-tauri/src/commands.rs:536-582`

### 12. Terminal pane flow
- `ChatTile` can open/close terminal panes, add terminal tabs, restart terminals, and confirm destructive closing of multiple terminals. `gui/src/components/workspace-board/ChatTile.tsx:343-385`, `gui/src/components/workspace-board/ChatTile.tsx:451-481`, `gui/src/components/workspace-board/ChatTile.tsx:746-779`
- `useTerminalSession` creates a `WTerm`, subscribes to backend terminal output/exit/error events, opens a backend terminal, writes user input, resizes backend PTY size, and closes the backend terminal on cleanup. `gui/src/components/workspace-board/hooks/useTerminalSession.ts:148-235`, `gui/src/components/workspace-board/hooks/useTerminalSession.ts:253-272`
- Tauri terminal API commands route to `state.terminal_manager.open/write/resize/close`. `gui/src-tauri/src/commands.rs:781-827`

### 13. Provider setup/settings flow
- Providers settings lists/searches providers, shows configured/unconfigured state, opens setup dialogs, removes configured providers, and refreshes prompt settings after changes. `gui/src/components/providers-settings/ProvidersSettingsPane.tsx:62-132`, `gui/src/components/providers-settings/ProvidersSettingsPane.tsx:134-328`
- Provider setup supports multiple auth kinds: API key, device code, CLI login, and OAuth authorization code. `gui/src/components/providers-settings/ProviderSetupDialog.tsx:416-572`
- Provider setup starts auth through `startProviderAuth`, completes through `completeProviderAuth`, listens for OAuth callbacks, and auto-polls CLI login completion via `listProviders`. `gui/src/components/providers-settings/ProviderSetupDialog.tsx:128-165`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:167-207`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:209-276`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:304-330`
- Backend provider APIs are registered in Tauri and route to `RuntimeManager` methods. `gui/src-tauri/src/lib.rs:116-144`, `gui/src-tauri/src/commands.rs:95-141`

### 14. MCP settings flow
- MCP settings lists servers, reloads, imports JSON config, removes servers, and triggers login/logout when auth status is present. `gui/src/components/mcp-settings/McpSettingsPane.tsx:35-94`, `gui/src/components/mcp-settings/McpSettingsPane.tsx:96-275`
- MCP backend commands are exposed through the desktop client (`listMcpServers`, `importMcpConfig`, `removeMcpServer`, `reloadMcpServers`, `loginMcpServer`, `logoutMcpServer`). `gui/src/services/desktop/client.ts:529-567`
- Tauri routes these MCP commands to `RuntimeManager` methods. `gui/src-tauri/src/commands.rs:307-377`

### 15. General settings / theme flow
- General settings currently covers appearance mode and theme preset selection, persisted through `themeStore`. `gui/src/components/general-settings/GeneralSettingsPane.tsx:18-82`
- The app-level theme toggle is also exposed in the shell. `gui/src/app/App.tsx:51-77`, `gui/src/app/App.tsx:269-272`

### 16. Desktop API boundary / route map
- The frontend desktop API boundary is `gui/src/services/desktop/client.ts`; all production calls go through `invokeCommand`, with QA mock mode swapping Tauri invocations for deterministic browser fixtures. `gui/src/services/desktop/client.ts:56-60`, `gui/src/services/desktop/client.ts:266-319`
- Frontend API functions map directly to Tauri command names for workspace/session/chat, slash commands, prompt settings, providers, MCP, git, external open/read-file, layouts, saved workspaces, and terminal operations. `gui/src/services/desktop/client.ts:338-802`
- Tauri registers the command surface with `tauri::generate_handler!`, covering the same product areas. `gui/src-tauri/src/lib.rs:108-174`
- Most Tauri command handlers are thin adapters that call `DesktopState.manager`; terminal handlers call `DesktopState.terminal_manager`; clone/quick-start and file/image helpers are implemented directly in `commands.rs`. `gui/src-tauri/src/commands.rs:48-827`

### 17. SDK / remote API product surface
- The repo includes generated TypeScript and Python SDKs over `graff --json`; README says `graff --schema` is the machine-readable interface used to generate SDKs. `README.md:402-411`
- SDK examples include Python `Harness` and TypeScript `Harness` / `runAgent`, with streamed event handling. `README.md:413-437`
- Remote clients exist for `graff serve`, including `@graff-new/sdk/remote` and Python `RemoteHarness`. `README.md:439-443`
- The `serve` mode exposes the same protocol over HTTP for clients that cannot spawn a local process, with NDJSON streaming and bearer-token support for non-loopback use. `README.md:735-746`

## Important components/services/routes and how they connect

```text
React UI
  App.tsx
    -> SessionProvider
      -> useSessionBootstrap
        -> desktopClient.listenSessionUpdates / getSessionSnapshot / createManagedChat
    -> ProjectSidebar
      -> useSessionActions
        -> desktopClient workspace/chat/saved-workspace APIs
    -> WorkspaceBoard
      -> Dockview layouts
      -> ChatTile
        -> ConversationPanel
          -> ChatThread + PromptComposer
            -> PromptInputCard
            -> useCommandRouter / useConversationActions
              -> desktopClient.sendPrompt / runSlashCommand / stopPrompt / settings APIs
        -> ChangesPane
          -> readWorkspaceFile/openPathInTarget/git actions
        -> TerminalPane/useTerminalSession
          -> terminal_open/write/resize/close + terminal events
    -> Settings panes
      -> ProvidersSettingsPane / ProviderSetupDialog
      -> McpSettingsPane
      -> GeneralSettingsPane

desktopClient.ts
  -> Tauri invoke(command_name)
  -> Tauri event listen(session-updated, provider OAuth callback, terminal output/exit/error)

Tauri Rust
  lib.rs generate_handler![...]
  -> commands.rs thin adapters
    -> runtime/simple.rs RuntimeManager for sessions, prompts, commands, providers, MCP, git, saved layouts
    -> terminal_manager for PTY sessions
    -> direct helpers for clone, quick-start, image/file helpers

graff runtime
  RuntimeManager.spawn/acquire session
  -> JSON stdin/stdout protocol with graff child
  -> streams text/tool/followup/error events into SessionSnapshot
```

Evidence for the frontend-to-backend boundary: `desktopClient.invokeCommand` wraps Tauri `invoke`, and all exported client functions call named backend commands. `gui/src/services/desktop/client.ts:311-319`, `gui/src/services/desktop/client.ts:338-802`  
Evidence for Tauri route registration: `generate_handler!` registers the desktop command surface. `gui/src-tauri/src/lib.rs:108-174`  
Evidence for session/prompt backend routing: `commands.rs` forwards `send_prompt`, `run_slash_command`, and many app actions to `state.manager`. `gui/src-tauri/src/commands.rs:155-180`, `gui/src-tauri/src/commands.rs:415-582`

## Inferred, but strongly supported

- The GUI is the main user-facing desktop product layer, while the Zig `graff` harness remains the core agent engine; this is inferred from README’s statement that the desktop app runs `graff` from `PATH` and from the Tauri runtime streaming through a `graff` session. `README.md:46-51`, `gui/src-tauri/src/runtime/simple.rs:692-707`
- Saved workspaces are a GUI construct for arranging multiple chat panels, not a core CLI concept; this is inferred from Dockview layout serialization and `ProjectStore` saved-workspace APIs being used by the GUI/Tauri layer. `gui/src/components/workspace-board/WorkspaceBoard.tsx:365-384`, `gui/src-tauri/src/runtime/simple.rs:2178-2188`
- The product’s “agent workbench” direction combines chat, code changes, terminals, git, providers, MCP, and multi-agent workflows into one desktop surface; this is inferred from the connected GUI panes and backend APIs rather than from a single product statement. `gui/src/components/workspace-board/ChatTile.tsx:495-540`, `gui/src/components/workspace-board/ChangesPane.tsx:279-349`, `gui/src/components/workspace-board/hooks/useTerminalSession.ts:148-235`, `gui/src/components/providers-settings/ProvidersSettingsPane.tsx:134-328`, `gui/src/components/mcp-settings/McpSettingsPane.tsx:96-275`

## 3 most load-bearing facts

1. **All desktop user flows cross one typed bridge:** `desktopClient.ts` exports the frontend API and maps directly to Tauri command names, while `lib.rs` registers the matching backend handlers. `gui/src/services/desktop/client.ts:338-802`, `gui/src-tauri/src/lib.rs:108-174`
2. **Conversation state is snapshot/event driven:** frontend bootstraps via `getSessionSnapshot` and `listenSessionUpdates`, while backend `RuntimeManager.snapshot` materializes workspaces, conversations, messages, todos, goals, followups, and saved workspaces. `gui/src/hooks/useSessionBootstrap.ts:28-88`, `gui/src-tauri/src/runtime/simple.rs:2093-2215`
3. **The main GUI product flow is chat-centric but workspace-aware:** `WorkspaceBoard` organizes one or many `ChatTile`s, each tile embeds conversation, changes, terminal, and layout persistence. `gui/src/components/workspace-board/WorkspaceBoard.tsx:51-104`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:313-388`, `gui/src/components/workspace-board/ChatTile.tsx:495-540`

## Open question

- Which layer should be considered the canonical “product” for roadmap/inventory purposes: the Zig CLI/SDK harness, the Tauri desktop app, or both as one combined Codegraff product? The README foregrounds the CLI harness while also documenting the desktop app as a major install path. `README.md:1-6`, `README.md:46-51`

[subagent sa-001-546805fc · inspect: .graff/subagents/sa-001-546805fc.md]

### risk hotspots
## Defensible findings

### 1) Unauthenticated localhost debug bridge can execute arbitrary JS in the Tauri webview  
**File:** `gui/src-tauri/src/debug_bridge.rs:91`, `gui/src-tauri/src/debug_bridge.rs:137`, `gui/src-tauri/src/debug_bridge.rs:188`, `gui/src-tauri/src/debug_bridge.rs:291`  
**Rationale:** In debug builds, the app starts an HTTP server on `127.0.0.1:9233` with no token/origin check. `POST /eval` accepts arbitrary `code`, interpolates it raw into a JS snippet, and evaluates it in the main Tauri webview. Responses include `Access-Control-Allow-Origin: *`.

**Breaking sequence:**
1. Developer runs a debug build of the GUI.
2. Attacker-controlled web page or local process sends `POST http://127.0.0.1:9233/eval` with body like `{"code":"window.__TAURI_INTERNALS__.invoke('open_external_url',{url:'https://attacker.example'})"}` or code that drives privileged app APIs exposed to the webview.
3. `handle_eval` embeds the supplied code at line 188 and calls `window.eval` at line 200.
4. The attacker’s code runs inside the desktop app context.

**Impact:** Localhost RCE-equivalent inside the debug app context. Debug-only reduces production risk, but it is still dangerous for developers because a browser page can target localhost services.

---

### 2) MCP requests can hang forever on a silent/broken server  
**File:** `src/mcp.zig:410`–`src/mcp.zig:428`  
**Rationale:** `request()` writes a JSON-RPC request, then loops on `takeDelimiter('\n')` until it sees a matching `id`. There is no timeout, cancellation, or child liveness check beyond EOF.

**Breaking sequence:**
1. Workspace contains `.mcp.json` with a server like:
   ```json
   {
     "mcpServers": {
       "bad": { "command": "sleep", "args": ["999999"] }
     }
   }
   ```
2. Registry startup calls `startServer()`.
3. `startServer()` calls `request(..., "initialize")` at `src/mcp.zig:286`.
4. `request()` blocks forever at `src/mcp.zig:422` because the process never writes a newline-delimited response.
5. Startup or `/mcp trust` never completes.

**Impact:** A malformed or hostile workspace MCP config can wedge the harness/GUI integration. This needs a request timeout and process cleanup path.

---

### 3) Malformed `.mcp.json` can crash instead of failing closed  
**File:** `src/mcp.zig:103`, `src/mcp.zig:111`, `src/mcp.zig:250`  
**Rationale:** Several JSON values are accessed as `.object` or `.string` without checking the active union tag.

**Breaking sequences:**
- If `.mcp.json` contains:
  ```json
  { "mcpServers": [] }
  ```
  then `parsed.object.get("mcpServers").object` at `src/mcp.zig:103` accesses `.object` on an array value.

- If `.mcp.json` contains:
  ```json
  { "mcpServers": { "x": [] } }
  ```
  then `entry.value_ptr.*.object` at `src/mcp.zig:111` accesses `.object` on an array value.

- If `.mcp.json` contains:
  ```json
  {
    "mcpServers": {
      "x": {
        "command": "node",
        "env": { "TOKEN": 123 }
      }
    }
  }
  ```
  then `e.value_ptr.*.string` at `src/mcp.zig:250` accesses `.string` on an integer value.

**Impact:** In safe builds this is a runtime panic; in unsafe/optimized contexts it risks undefined behavior. Workspace config is user-/repo-controlled, so this should be validated defensively and covered by malformed-config tests.

---

### 4) Predictable temp-file writes can follow attacker-created symlinks  
**File:** `gui/src-tauri/src/commands.rs:264`–`gui/src-tauri/src/commands.rs:267`  
**Rationale:** `save_pasted_image` writes to a predictable path under the shared temp directory: `codegraff-pasted/paste-<pid>-<counter>.<ext>`. It uses `std::fs::write`, which follows symlinks.

**Breaking sequence:**
1. Local attacker creates `/tmp/codegraff-pasted` if it does not already exist and makes it writable.
2. Attacker predicts or observes the GUI PID and creates a symlink such as:
   ```sh
   ln -s "$HOME/.zshrc" "/tmp/codegraff-pasted/paste-12345-0.png"
   ```
3. User pastes an image into the GUI.
4. `save_pasted_image` writes bytes to the symlink target at line 267.

**Impact:** Local same-user or same-machine file clobber. Use a private `tempfile`/`NamedTempFile`-style creation with `O_EXCL` and a per-user 0700 directory.

---

### 5) The debug screenshot endpoint uses a fixed temp filename  
**File:** `gui/src-tauri/src/debug_bridge.rs:249`–`gui/src-tauri/src/debug_bridge.rs:259`  
**Rationale:** `capture_screenshot` always writes the full-screen capture to `std::env::temp_dir().join("cg_debug_full.png")`.

**Breaking sequence:**
1. A local attacker pre-creates `/tmp/cg_debug_full.png` as a symlink to another writable user file.
2. Developer calls `GET http://127.0.0.1:9233/screenshot` while running a debug build.
3. `screencapture -x /tmp/cg_debug_full.png` writes through the symlink or overwrites the predictable file.

**Impact:** Local file clobber in debug builds, plus stale/racy screenshots when multiple app instances or requests run. Use a securely created unique temp file and delete it.

---

## Complexity hotspots / likely maintenance risks

- **`gui/src-tauri/src/runtime/simple.rs` — 4,499 lines.** This file owns runtime state, provider auth, model selection, MCP config, persistence, child-process sessions, git commands, and tests. The most failure-prone areas are:
  - session lifecycle / queued prompts: `send_prompt`, `stream_turn`, `send_control`, `acquire_session_io`;
  - provider credential detection and env bootstrapping;
  - persistence with best-effort ignored errors.
- **`gui/src/app/sessionStore.ts` — 924 lines.** Central client-side state with selection, drafts, attachments, request timing, view caching, and async request de-duplication. Race-prone; needs broad regression coverage.
- **`gui/src-tauri/src/commands.rs` — 959 lines.** Large Tauri command surface; security-sensitive functions live next to ordinary UI glue.
- **`gui/src/services/desktop/client.ts` — 802 lines.** Contains both real Tauri client and QA mock mode. Risk: mock drift from generated contracts.
- **`gui/src/components/providers-settings/ProviderSetupDialog.tsx` — 697 lines.** Complex provider auth state machine; likely needs more integration tests around failure/retry/cancel.
- **`src/mcp.zig` — MCP stdio client.** Small enough to reason about but currently has the most concrete robustness issues: no timeout and unsafe JSON shape assumptions.

---

## TODOs / stubs / cleanup

- `grep` did not find meaningful source TODO/FIXME comments beyond test fixtures and identifiers.
- There are explicit MVP/stub/no-op areas:
  - `gui/src-tauri/src/runtime/simple.rs:1442`–`1488`: workflow sync/query/draft paths are placeholders.
  - `gui/src-tauri/src/runtime/simple.rs:1634`–`1649`: MCP OAuth login/logout explicitly unsupported.
  - `gui/src-tauri/src/lib.rs:12`–`15`, `18`–`22`: copied bridge/persistence modules retained for future parity.
- Working tree has ignored runtime artifacts (`session-*.json`, `harness.trace.jsonl`, `harness.trajectory.jsonl`, `codedb.snapshot`, etc.) and untracked `.graff/` plus `apps/ios/build/...`. These are cleanup hazards even if ignored.

---

## Areas needing tests

1. **MCP malformed config tests** for non-object `mcpServers`, non-object server entries, non-string env values.
2. **MCP timeout tests** with a server that never responds or emits only notifications.
3. **Debug bridge security tests** asserting either disabled-by-default behavior or required auth token.
4. **Temp file safety tests** for pasted images: no symlink following, private directory permissions, unique paths.
5. **Runtime session lifecycle tests** around:
   - queued prompt order;
   - stop while streaming;
   - control messages during active runs;
   - dropped child and retry behavior.
6. **Provider auth retry/cancel tests** for the large settings dialog + runtime provider code.

---

## Verdict

**Most dangerous defect:** the unauthenticated debug bridge at `gui/src-tauri/src/debug_bridge.rs:91`/`137`/`188`, because any local process or reachable browser context can drive arbitrary JS execution inside a debug Tauri app with no shared secret or origin validation.

[subagent sa-000-f57b1da8 · inspect: .graff/subagents/sa-000-f57b1da8.md]

## report

# Guided tour of the Codegraff codebase

## 1. Project purpose and stack

### Verified

Codegraff is a mixed CLI + desktop agentic coding harness. The core product is the `graff` executable, described as “a minimal agentic coding harness in Zig 0.16” that talks to LLM providers, executes model-requested tools, and repeats until the model stops. The README describes the loop as model request → parallel tool execution → feed results back → continue. (`README.md:1-6`, `README.md:17-28`)

The repo has four major technology layers:

| Layer | Purpose | Stack / evidence |
|---|---|---|
| CLI agent core | Main `graff` runtime, tools, providers, JSON/HTTP protocol, subagents/workflows | Zig 0.16; `build.zig` builds executable `graff` from `src/main.zig`. (`build.zig:42-51`) |
| Desktop app | Tauri desktop GUI over the CLI runtime | Tauri 2 + Rust backend + React/TypeScript/Vite frontend. (`gui/package.json:18-60`, `gui/src-tauri/Cargo.toml:7-52`) |
| Shared UI package | Diff/file-change rendering used by GUI | `@codegraff/diffs` TypeScript package. (`packages/diffs/package.json:1-24`) |
| SDK / remote API | Generated TypeScript/Python SDKs and HTTP bridge clients | `graff --schema` is machine-readable interface used to generate SDKs. (`README.md:402-411`, `sdk/README.md:13-18`) |

The root repo is a Bun workspace covering `gui` and `packages/*`. (`package.json:1-9`)

### Inferred

The project is best understood as **one product with two primary front doors**:

1. Terminal users run `graff` directly.
2. Desktop users run the Tauri GUI, which spawns persistent `graff --json` child processes and translates their streamed events into GUI state.

This is inferred from the CLI JSON protocol definition in `src/main.zig` and the GUI runtime’s persistent `GraffSession` design. (`src/main.zig:79-111`, `gui/src-tauri/src/runtime/simple.rs:85-97`, `gui/src-tauri/src/runtime/simple.rs:690-1005`)

---

## 2. Directory map

### Top-level map

```text
.
├── build.zig                 # Zig build file for graff CLI
├── src/
│   ├── main.zig              # Core CLI/agent runtime
│   └── mcp.zig               # Minimal stdio MCP client
├── gui/
│   ├── package.json          # Bun/Vite/React/Tauri frontend scripts
│   ├── src/                  # React frontend
│   └── src-tauri/            # Rust/Tauri backend
├── packages/
│   └── diffs/                # Shared TypeScript diff renderer
├── sdk/
│   ├── generate.py           # SDK generator from graff --schema
│   ├── py/                   # Python SDK package
│   └── ts/                   # TypeScript SDK package
├── examples/
│   └── edge-worker/          # Remote bridge / Cloudflare Worker example
├── scripts/                  # Helper/test/dev scripts
├── docs/                     # Documentation
├── plans/                    # Planning notes
└── .github/workflows/        # CI, release, SDK publishing
```

### Key verified areas

- `src/` contains the Zig CLI/agent implementation; `build.zig` compiles `src/main.zig` as `graff`. (`build.zig:42-49`)
- `src/mcp.zig` implements a stdio MCP client. (`src/mcp.zig:1-12`)
- `gui/` contains the Tauri desktop app; frontend entry renders `<App />`, Rust entry calls `codegraff_gui_lib::run()`. (`gui/src/main.tsx:1-13`, `gui/src-tauri/src/main.rs:4-6`)
- `packages/diffs/` is a shared diff-rendering package consumed by the GUI. (`gui/package.json:18-21`, `packages/diffs/package.json:12-24`)
- `sdk/` contains generated TypeScript and Python SDKs; SDKs are generated from `graff --schema`. (`sdk/README.md:1-18`)
- `.github/workflows/ci.yml` validates the Zig CLI, formatting, JSON protocol, and SDK drift. (`.github/workflows/ci.yml:27-55`)

---

## 3. Main execution flow

## 3.1 CLI / agent flow

### Verified flow

1. `zig build` builds the executable named `graff` from `src/main.zig`. (`build.zig:42-51`)
2. `src/main.zig` exposes `pub fn main(init: std.process.Init) !void` and parses CLI flags such as `--yolo`, `--json`, `--schema`, `--model`, and `--resume`. (`src/main.zig:4307-4385`)
3. A root `Agent` owns allocator/arena, shared HTTP client, provider, message history, MCP registry, approval/tracing state, system prompts, tool JSON variants, todo state, and runtime options. (`src/main.zig:8163-8224`)
4. `Agent.runTurn()` loops through provider request/response handling until final text is produced. (`src/main.zig:8316-8335`)
5. `Agent.request()` builds provider-specific request bodies, streams where needed, retries flaky HTTP failures, and emits JSON events for clients. (`src/main.zig:8337-8365`)
6. If the model asks for tools, `Agent.runTools()` separates meta tools from external tools, gates/rejects tools as appropriate, runs external calls in parallel via `io.async`, and joins futures. (`src/main.zig:8807-8870`)
7. `execTool()` applies gates, calls `execToolInner`, records tracing/telemetry/tool-use, and returns structured tool output. (`src/main.zig:11809-11831`)
8. Subagents and workflows are implemented as tool execution paths. `execSubagent()` delegates to `runSub()`, which creates a fresh `Agent` with fresh history but shared client/provider. (`src/main.zig:12484-12587`)
9. `execWorkflow()` runs sequential phases of parallel subagent tasks, capped at 5 phases and 8 tasks per phase. (`src/main.zig:12594-12698`)

### CLI mental model

```text
user prompt
  -> graff main()
    -> Agent.runTurn()
      -> Agent.request()
        -> provider API call
      -> parse model response
      -> if tool calls:
           Agent.runTools()
             -> execTool()
             -> maybe MCP / bash / file / subagent / workflow
           feed tool results back
      -> final assistant text
```

## 3.2 MCP flow

### Verified flow

`src/mcp.zig` is a minimal MCP client over stdio JSON-RPC. It spawns servers from `.mcp.json`, runs `initialize → initialized → tools/list`, exposes namespaced tools, and routes `tools/call` back to the server. (`src/mcp.zig:1-12`, `src/mcp.zig:84-120`, `src/mcp.zig:229-323`, `src/mcp.zig:334-404`)

MCP tool names are namespaced as `mcp__<server>__<tool>`. (`src/mcp.zig:298-323`)

MCP access is serialized with a registry mutex because each server has one bidirectional stdio pipe. (`src/mcp.zig:8-11`, `src/mcp.zig:355-360`)

## 3.3 Desktop GUI flow

### Verified flow

1. React entrypoint renders `<App />`. (`gui/src/main.tsx:9-13`)
2. `App` wraps the UI in `SessionProvider` and `DragDropProvider`, then renders `AppShell`. (`gui/src/app/App.tsx:385-396`)
3. `AppShell` displays sidebar/settings/workspace board inside resizable panels. (`gui/src/app/App.tsx:265-379`)
4. `SessionProvider` bootstraps the session, subscribes to backend updates, opens forwarded workspace paths, and exposes action methods. (`gui/src/app/SessionProvider.tsx:55-92`, `gui/src/app/SessionProvider.tsx:127-178`, `gui/src/app/SessionProvider.tsx:651-655`)
5. Frontend actions call `desktopClient`, which wraps Tauri `invoke` and `listen`. (`gui/src/services/desktop/client.ts:311-319`, `gui/src/services/desktop/client.ts:338-802`)
6. Tauri registers backend commands with `tauri::generate_handler!`. (`gui/src-tauri/src/lib.rs:108-174`)
7. `commands.rs` mostly delegates to `DesktopState.manager` methods. (`gui/src-tauri/src/commands.rs:48-80`, `gui/src-tauri/src/commands.rs:155-180`)
8. `RuntimeManager.send_prompt()` creates/selects a conversation, appends the user message, queues concurrent prompts if necessary, emits snapshots, optionally generates a title, and streams the turn. (`gui/src-tauri/src/runtime/simple.rs:467-688`)
9. `stream_turn()` writes a JSON user line to a long-lived `graff --json` child process, reads JSONL events, and maps those events into GUI messages, reasoning, tool rows, followups, errors, and turn completion. (`gui/src-tauri/src/runtime/simple.rs:690-1005`)
10. The runtime emits `SessionSnapshot` updates back to the frontend. (`gui/src-tauri/src/runtime/simple.rs:1074-1079`, `gui/src/services/desktop/client.ts:752-756`)

### Desktop mental model

```text
React UI
  -> SessionProvider action
    -> desktopClient.invoke(...)
      -> Tauri command in commands.rs
        -> RuntimeManager
          -> persistent graff --json child process
            -> streamed JSONL events
          -> SessionSnapshot
      -> frontend applies snapshot to sessionStore
```

---

## 4. Key modules to know

## 4.1 Zig core

### `src/main.zig`

This is the center of gravity for the CLI runtime.

It contains:

- CLI parsing and modes such as `--json`, `--schema`, `--model`, `--resume`, and `--yolo`. (`src/main.zig:4307-4385`)
- JSON stdio protocol event schema, including `text`, `reasoning`, `tool_call`, `tool_result`, `turn`, and `error`. (`src/main.zig:79-111`)
- HTTP bridge schema for `graff serve`, including `/healthz`, `/v1/schema`, and session endpoints. (`src/main.zig:114-128`)
- `Agent` state and run loop. (`src/main.zig:8163-8335`)
- Provider request handling. (`src/main.zig:8337-8365`)
- Parallel tool execution. (`src/main.zig:8807-8870`)
- Subagents and workflows. (`src/main.zig:12484-12698`)

### `src/mcp.zig`

This is the MCP integration layer.

It:

- Reads `.mcp.json`.
- Spawns MCP server subprocesses.
- Performs JSON-RPC initialization.
- Lists server tools.
- Calls MCP tools through stdio.
- Serializes access with a mutex. (`src/mcp.zig:1-12`, `src/mcp.zig:84-120`, `src/mcp.zig:229-404`)

## 4.2 GUI frontend

### `gui/src/app/App.tsx`

Top-level shell. It wires:

- `SessionProvider`
- drag/drop context
- app shell
- sidebar/settings/workspace layout
- `/success` OAuth success route

Evidence: (`gui/src/app/App.tsx:123-170`, `gui/src/app/App.tsx:265-396`)

### `gui/src/app/SessionProvider.tsx`

Main frontend orchestrator. It:

- Applies backend snapshots into frontend state.
- Bootstraps sessions.
- Handles forwarded workspace paths.
- Exposes user actions.
- Submits prompts through `desktopClient.sendPrompt`.

Evidence: (`gui/src/app/SessionProvider.tsx:55-92`, `gui/src/app/SessionProvider.tsx:127-178`, `gui/src/app/SessionProvider.tsx:563-619`, `gui/src/app/SessionProvider.tsx:651-655`)

### `gui/src/services/desktop/client.ts`

Frontend/backend boundary. It:

- Wraps Tauri `invoke`.
- Wraps Tauri event `listen`.
- Supports QA mock mode through `VITE_CODEGRAFF_QA_MOCK=1`.
- Exports typed functions for workspaces, sessions, prompts, providers, MCP, git, layouts, saved workspaces, and terminals.

Evidence: (`gui/src/services/desktop/client.ts:56-60`, `gui/src/services/desktop/client.ts:266-336`, `gui/src/services/desktop/client.ts:338-802`)

### `gui/src/components/workspace-board/WorkspaceBoard.tsx`

Main multi-chat workspace surface. It:

- Uses Dockview layouts.
- Renders empty state, workspace draft, single chat, or saved multi-chat workspace.
- Converts multiple chats into saved workspaces.
- Persists/restores layouts.

Evidence: (`gui/src/components/workspace-board/WorkspaceBoard.tsx:51-104`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:313-388`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:439-481`, `gui/src/components/workspace-board/WorkspaceBoard.tsx:538-586`)

### `gui/src/components/workspace-board/ChatTile.tsx`

Per-chat workspace tile. It hosts:

- Conversation pane.
- Preview pane.
- Terminal pane.
- Changes pane.
- Per-conversation layout persistence.

Evidence: (`gui/src/components/workspace-board/ChatTile.tsx:495-540`, `gui/src/components/workspace-board/ChatTile.tsx:572-608`, `gui/src/components/workspace-board/ChatTile.tsx:729-781`)

## 4.3 GUI Rust backend

### `gui/src-tauri/src/lib.rs`

Tauri app setup. It:

- Initializes app data/project store.
- Manages `DesktopState`.
- Registers command handlers.
- Starts the app.
- Starts the debug bridge in debug builds only.

Evidence: (`gui/src-tauri/src/lib.rs:49-85`, `gui/src-tauri/src/lib.rs:92-97`, `gui/src-tauri/src/lib.rs:108-176`)

### `gui/src-tauri/src/commands.rs`

Tauri command adapter layer. It:

- Maps frontend commands to `RuntimeManager`.
- Implements some direct helpers: file pickers, pasted image persistence, thumbnails, workspace-confined file reads, `git clone`, GitHub quick-start, and terminal commands.

Evidence: (`gui/src-tauri/src/commands.rs:24-46`, `gui/src-tauri/src/commands.rs:48-80`, `gui/src-tauri/src/commands.rs:155-180`, `gui/src-tauri/src/commands.rs:252-292`, `gui/src-tauri/src/commands.rs:626-694`, `gui/src-tauri/src/commands.rs:781-958`)

### `gui/src-tauri/src/runtime/simple.rs`

Desktop runtime adapter. This is the GUI backend’s main state machine.

It owns:

- Runtime state.
- Project registry.
- Active conversations.
- Persistent `graff --json` child sessions.
- Prompt streaming.
- Snapshot emission.
- Provider auth.
- MCP config.
- Git operations.
- Saved workspaces/layouts.
- Tests.

Evidence: (`gui/src-tauri/src/runtime/simple.rs:51-130`, `gui/src-tauri/src/runtime/simple.rs:467-688`, `gui/src-tauri/src/runtime/simple.rs:690-1005`, `gui/src-tauri/src/runtime/simple.rs:1126-1203`, `gui/src-tauri/src/runtime/simple.rs:2093-2215`, `gui/src-tauri/src/runtime/simple.rs:4001-4259`)

### `gui/src-tauri/src/persistence/project_store.rs`

SQLite persistence layer. It:

- Uses Diesel with SQLite.
- Stores opened projects, managed chat workspaces, conversation layouts, saved workspaces, and saved workspace layouts.
- Creates/migrates tables in `init()`.

Evidence: (`gui/src-tauri/src/persistence/project_store.rs:1-10`, `gui/src-tauri/src/persistence/project_store.rs:31-36`, `gui/src-tauri/src/persistence/project_store.rs:460-544`)

## 4.4 Shared diff package

### `packages/diffs`

This package builds reusable diff/file-change rendering for plain and React use. It is consumed by the GUI through a workspace dependency. (`gui/package.json:18-21`, `packages/diffs/package.json:12-24`)

Build script is `tsc -p tsconfig.build.json`. (`packages/diffs/package.json:23-25`)

---

## 5. User-facing feature map

### CLI features

Verified CLI features include:

- REPL and one-shot prompt mode. (`README.md:279-300`)
- Model selection with `--model`. (`README.md:279-300`)
- Login/key management. (`README.md:74-82`, `README.md:219-228`)
- JSON protocol mode and schema generation. (`README.md:402-411`)
- Slash commands such as `/model`, `/plan`, `/key`, `/reasoning`, `/compact`, `/save`, `/resume`, `/todo`, `/mcp`, and `/help`. (`README.md:317-346`)
- Permission-gated tools, `yolo`, `plan`, and `strict` modes. (`README.md:364-398`)
- Subagents and workflow fan-out, including “ultracode”. (`README.md:541-560`)
- HTTP `serve` mode for remote clients, with NDJSON streaming and bearer-token support for non-loopback use. (`README.md:735-746`)

### Desktop features

Verified desktop flows include:

- Sidebar with saved workspaces, managed chats, projects, and settings. (`gui/src/components/ProjectSidebar.tsx:244-423`)
- New chat onboarding, provider setup, clone repository, quick-start project, and open folder flows. (`gui/src/components/new-chat-screen/NewChatScreen.tsx:81-143`, `gui/src/components/new-chat-screen/hooks/useNewChatScreenController.ts:149-251`)
- Prompt composer with slash-command autocomplete, model picker, reasoning effort picker, Plan mode, Fast mode, Ultra mode, stop/send, prompt history, drag/drop attachments, and pasted image attachments. (`gui/src/components/PromptInputCard.tsx:93-181`, `gui/src/components/PromptInputCard.tsx:199-621`)
- Conversation streaming into chat messages, reasoning, tools, followups, errors, and turn completion. (`gui/src-tauri/src/runtime/simple.rs:692-1005`)
- Multi-chat saved workspace layout through Dockview. (`gui/src/components/workspace-board/WorkspaceBoard.tsx:313-388`)
- Changes/diff/git actions. (`gui/src/components/workspace-board/ChangesPane.tsx:199-349`, `gui/src/app/SessionProvider.tsx:180-228`)
- Terminal panes backed by backend PTY sessions. (`gui/src/components/workspace-board/hooks/useTerminalSession.ts:148-272`, `gui/src-tauri/src/commands.rs:781-827`)
- Provider settings with API key, device code, CLI login, and OAuth authorization code flows. (`gui/src/components/providers-settings/ProviderSetupDialog.tsx:128-330`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:416-572`)
- MCP settings for listing, importing, removing, reloading, login, and logout. (`gui/src/components/mcp-settings/McpSettingsPane.tsx:35-275`, `gui/src/services/desktop/client.ts:529-567`)

---

## 6. How to run, build, and test

## 6.1 CLI

### Build

```sh
zig build
```

CI runs exactly this. (`.github/workflows/ci.yml:39-40`)

### Run from source

```sh
zig build run
# or
./zig-out/bin/graff
```

`build.zig` defines a `run` step, and the README documents both commands. (`build.zig:53-56`, `README.md:692-699`)

### Test

```sh
zig build test
zig build test --summary all
```

`build.zig` defines the test step using `src/main.zig` as the test root, and CI runs `zig build test --summary all`. (`build.zig:58-69`, `.github/workflows/ci.yml:45-46`)

### Format check

```sh
zig fmt --check src/main.zig src/mcp.zig build.zig
```

CI enforces this exact command. (`.github/workflows/ci.yml:42-43`)

### JSON protocol test

```sh
python3 scripts/test-json-controls.py zig-out/bin/graff
```

CI runs this after building `graff`. (`.github/workflows/ci.yml:48-49`)

### SDK drift check

```sh
python3 sdk/generate.py --harness ./zig-out/bin/graff
git diff --exit-code sdk/
```

CI regenerates SDKs and fails if generated SDK files change. (`.github/workflows/ci.yml:51-55`)

## 6.2 GUI frontend

From `gui/`:

```sh
bun run dev
bun run build
bun run lint
bun test
bun run preview
```

Verified scripts:

- `dev`: `bun run build:deps && vite`
- `build`: `bun run build:deps && bun run gen:desktop-contracts && tsc -b && vite build`
- `lint`: `bun run build:deps && bun run gen:desktop-contracts && eslint .`
- `test`: `bun test`
- `preview`: `vite preview`

Evidence: (`gui/package.json:8-17`)

### Desktop contract generation

```sh
cd gui
bun run gen:desktop-contracts
```

This runs:

```sh
cargo run --quiet --manifest-path src-tauri/Cargo.toml --example generate_desktop_contracts
```

Evidence: (`gui/package.json:10`)

## 6.3 Tauri desktop app

Likely commands:

```sh
cd gui
bun run tauri dev
bun run tauri build
```

This is inferred because `gui/package.json` exposes `"tauri": "tauri"`, and Tauri config defines `beforeDevCommand` as `bun run dev` and `beforeBuildCommand` as `bun run build`. (`gui/package.json:14-15`, `gui/src-tauri/tauri.conf.json:6-10`)

### Important runtime requirement

The desktop app must find a usable `graff` binary. Lookup order starts with `CODEGRAFF_GUI_BINARY`, then bundled sidecar, dev path `../../zig-out/bin/graff`, known install locations, and finally bare `graff` on `PATH`. (`gui/src-tauri/src/runtime/simple.rs:3240-3300`)

If spawning fails, the GUI error tells the user to install the CLI or set `CODEGRAFF_GUI_BINARY`. (`gui/src-tauri/src/runtime/simple.rs:2652-2657`)

The GUI spawns:

```text
graff --json --yolo --resume <conversation_id>
```

and optionally `--model <model>`, in the workspace directory. (`gui/src-tauri/src/runtime/simple.rs:2626-2649`)

## 6.4 Rust/Tauri tests

Inferred command:

```sh
cargo test --manifest-path gui/src-tauri/Cargo.toml
```

This is not wired into package scripts or CI, but Rust `#[test]` declarations exist and `pretty_assertions` is a dev dependency. (`gui/src-tauri/src/runtime/simple.rs:4001-4259`, `gui/src-tauri/Cargo.toml:54-56`)

## 6.5 Shared diff package

```sh
cd packages/diffs
bun run build
bun test
```

Build script is `tsc -p tsconfig.build.json`; test script is `bun test`. (`packages/diffs/package.json:23-26`)

## 6.6 SDKs

Regenerate SDKs locally:

```sh
python3 sdk/generate.py --harness ./zig-out/bin/graff
# or
graff --schema | python3 sdk/generate.py
```

Evidence: (`sdk/README.md:13-18`, `sdk/generate.py:22-32`)

---

## 7. Risks and hotspots

## 7.1 Security / robustness risks

### Debug bridge can execute arbitrary JS in debug builds

In debug builds, the GUI starts an HTTP debug bridge on `127.0.0.1:9233` with no token/origin check. `POST /eval` accepts arbitrary code, embeds it into a JS snippet, and evaluates it in the main Tauri webview. Responses include `Access-Control-Allow-Origin: *`. (`gui/src-tauri/src/debug_bridge.rs:91`, `gui/src-tauri/src/debug_bridge.rs:137`, `gui/src-tauri/src/debug_bridge.rs:188`, `gui/src-tauri/src/debug_bridge.rs:291`)

Impact: local process or malicious browser page can drive arbitrary JS execution inside a debug Tauri app context.

### MCP request can hang forever

`src/mcp.zig` writes a JSON-RPC request and loops on newline-delimited responses until it sees a matching `id`, with no timeout, cancellation, or child-liveness check beyond EOF. (`src/mcp.zig:410-428`)

Impact: a silent or broken MCP server from workspace `.mcp.json` can wedge startup or MCP operations.

### Malformed `.mcp.json` can crash

Several JSON values in `src/mcp.zig` are accessed as `.object` or `.string` without checking the active union tag. (`src/mcp.zig:103`, `src/mcp.zig:111`, `src/mcp.zig:250`)

Impact: malformed workspace-controlled config can cause runtime panic in safe builds and worse behavior in unsafe/optimized contexts.

### Predictable temp-file writes for pasted images

`save_pasted_image` writes to a predictable path under the shared temp directory: `codegraff-pasted/paste-<pid>-<counter>.<ext>`, using `std::fs::write`, which follows symlinks. (`gui/src-tauri/src/commands.rs:264-267`)

Impact: local same-user or same-machine file clobber risk.

### Debug screenshot uses fixed temp filename

The debug screenshot endpoint writes to `std::env::temp_dir().join("cg_debug_full.png")`. (`gui/src-tauri/src/debug_bridge.rs:249-259`)

Impact: local file clobber or stale/racy screenshot behavior in debug builds.

## 7.2 Complexity hotspots

### `gui/src-tauri/src/runtime/simple.rs`

Large, central Rust file around 4,499 lines. It owns runtime state, provider auth, model selection, MCP config, persistence, child-process sessions, git commands, and tests.

Most failure-prone areas:

- `send_prompt`
- `stream_turn`
- `send_control`
- `acquire_session_io`
- provider credential detection
- login-shell environment bootstrapping
- persistence with best-effort ignored errors

Evidence for scope: (`gui/src-tauri/src/runtime/simple.rs:51-130`, `gui/src-tauri/src/runtime/simple.rs:467-688`, `gui/src-tauri/src/runtime/simple.rs:690-1005`, `gui/src-tauri/src/runtime/simple.rs:1126-1203`, `gui/src-tauri/src/runtime/simple.rs:2093-2215`)

### `src/main.zig`

The Zig agent core is central and very large. It owns provider requests, tool execution, subagents, workflows, JSON protocol, HTTP protocol, and CLI parsing. (`src/main.zig:79-128`, `src/main.zig:4307-4385`, `src/main.zig:8163-8870`, `src/main.zig:12484-12698`)

### `gui/src/app/sessionStore.ts`

Central frontend state file around 924 lines. It manages selection, drafts, attachments, request timing, view caching, and async request de-duplication. This is likely race-prone and needs regression coverage.

### `gui/src-tauri/src/commands.rs`

Large Tauri command surface around 959 lines. Security-sensitive helpers live beside ordinary UI glue. Evidence for command surface and direct helpers: (`gui/src-tauri/src/commands.rs:24-46`, `gui/src-tauri/src/commands.rs:48-827`)

### `gui/src/services/desktop/client.ts`

Large frontend API boundary around 802 lines. It contains both production Tauri calls and QA mock mode, creating risk of mock/contract drift. (`gui/src/services/desktop/client.ts:266-319`, `gui/src/services/desktop/client.ts:338-802`)

### `gui/src/components/providers-settings/ProviderSetupDialog.tsx`

Complex provider auth state machine, including API keys, device code, CLI login, OAuth, polling, cancellation, and callbacks. (`gui/src/components/providers-settings/ProviderSetupDialog.tsx:128-330`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:416-572`)

## 7.3 Verified documentation/config discrepancy

`build.zig` currently bakes a telemetry endpoint by default unless `-Dtelemetry-endpoint=""` is passed. (`build.zig:26-37`)

README says source builds have no endpoint baked in unless an environment endpoint is set. (`README.md:656-659`)

These statements conflict.

---

## 8. Recommended next exploration steps

### 1. Trace one full CLI prompt in `src/main.zig`

Start with:

- CLI parsing: `src/main.zig:4307-4385`
- `Agent` fields: `src/main.zig:8163-8224`
- turn loop: `src/main.zig:8316-8335`
- request construction/streaming: `src/main.zig:8337-8365`
- tool execution: `src/main.zig:8807-8870`
- subagents/workflows: `src/main.zig:12484-12698`

Goal: understand the exact lifecycle of a model turn and how provider responses are normalized.

### 2. Trace one desktop prompt end-to-end

Follow:

```text
PromptComposer / SessionProvider
  -> desktopClient.sendPrompt
  -> commands.rs send_prompt
  -> RuntimeManager.send_prompt
  -> stream_turn
  -> graff --json child
  -> SessionSnapshot event
  -> frontend sessionStore
```

Key files:

- `gui/src/app/SessionProvider.tsx`
- `gui/src/services/desktop/client.ts`
- `gui/src-tauri/src/commands.rs`
- `gui/src-tauri/src/runtime/simple.rs`
- `gui/src/app/sessionStore.ts`

Evidence for this path: (`gui/src/app/SessionProvider.tsx:563-619`, `gui/src/services/desktop/client.ts:338-457`, `gui/src-tauri/src/commands.rs:155-165`, `gui/src-tauri/src/runtime/simple.rs:467-1005`)

### 3. Inspect the generated desktop contracts

The GUI build runs `gen:desktop-contracts` before TypeScript build/lint. (`gui/package.json:10-13`)

Next step: inspect the generated files under `gui/src-tauri/gen/**` and compare them with `desktopClient.ts` and `commands.rs` to understand how strongly typed the frontend/backend boundary is.

### 4. Audit MCP robustness

Focus on:

- `.mcp.json` parsing shape validation. (`src/mcp.zig:103`, `src/mcp.zig:111`, `src/mcp.zig:250`)
- request timeout/cancellation. (`src/mcp.zig:410-428`)
- process cleanup on failure.

This is a compact subsystem with concrete failure modes.

### 5. Explore provider auth from GUI to CLI

Follow:

- `ProvidersSettingsPane`
- `ProviderSetupDialog`
- `desktopClient` provider calls
- Tauri provider commands
- `RuntimeManager` provider methods
- CLI credential expectations from README

Evidence: (`gui/src/components/providers-settings/ProvidersSettingsPane.tsx:62-328`, `gui/src/components/providers-settings/ProviderSetupDialog.tsx:128-572`, `gui/src-services/desktop/client.ts:529-590`, `gui/src-tauri/src/commands.rs:95-141`, `README.md:219-228`)

### 6. Add or inspect tests around session lifecycle

High-value scenarios:

- queued prompt order
- stop while streaming
- child process death and retry
- control messages during active run
- snapshot consistency
- persisted layout save/load

Rust tests already exist in `runtime/simple.rs`, but are not wired into CI/package scripts. (`gui/src-tauri/src/runtime/simple.rs:4001-4259`)

---

## 9. Verified vs inferred summary

### Verified

- The core executable is `graff`, built from `src/main.zig`. (`build.zig:42-51`)
- The CLI agent loop lives in `src/main.zig` and owns provider calls, tools, subagents, workflows, and protocols. (`src/main.zig:8316-8870`, `src/main.zig:12484-12698`)
- The desktop app is Tauri 2 + Rust + React/TypeScript/Vite. (`gui/package.json:18-60`, `gui/src-tauri/Cargo.toml:7-52`)
- The GUI frontend talks to Rust through `desktopClient.ts` and Tauri commands. (`gui/src/services/desktop/client.ts:311-319`, `gui/src-tauri/src/lib.rs:108-174`)
- The GUI backend streams turns through persistent `graff --json` child processes. (`gui/src-tauri/src/runtime/simple.rs:85-97`, `gui/src-tauri/src/runtime/simple.rs:690-1005`)
- The main GUI state transition unit is `SessionSnapshot`. (`gui/src-tauri/src/runtime/simple.rs:1074-1079`, `gui/src-tauri/src/runtime/simple.rs:2093-2215`)
- CI validates Zig build/test/fmt, JSON controls, and SDK drift. (`.github/workflows/ci.yml:27-55`)

### Inferred

- The GUI is intentionally a thin adapter over the Zig runtime rather than a second implementation of the agent. This is inferred from the persistent `graff --json` child-session design and comments describing the Rust runtime as coordinating the copied desktop GUI with the Zig-native binary. (`gui/src-tauri/src/runtime/simple.rs:85-105`, `gui/src-tauri/src/runtime/simple.rs:690-1005`)
- Saved workspaces are a GUI-level multi-chat/layout concept rather than a core CLI concept. This is inferred from Dockview layout serialization and saved-workspace persistence in the GUI/Tauri layer. (`gui/src/components/workspace-board/WorkspaceBoard.tsx:365-384`, `gui/src-tauri/src/runtime/simple.rs:2178-2188`)
- The product direction is an agent workbench: chat, code changes, terminals, git, providers, MCP, and multi-agent workflows in one desktop surface. This is inferred from the connected GUI panes and backend APIs. (`gui/src/components/workspace-board/ChatTile.tsx:495-540`, `gui/src/components/workspace-board/ChangesPane.tsx:279-349`, `gui/src/components/workspace-board/hooks/useTerminalSession.ts:148-235`, `gui/src/components/providers-settings/ProvidersSettingsPane.tsx:134-328`, `gui/src/components/mcp-settings/McpSettingsPane.tsx:96-275`)

---

## 10. Three most load-bearing facts

1. **`src/main.zig` is the agent core.** It is compiled into `graff` and owns provider requests, tool execution, subagents, workflows, and JSON/HTTP protocols. (`build.zig:42-49`, `src/main.zig:8316-8365`, `src/main.zig:8807-8870`, `src/main.zig:12484-12698`)

2. **The desktop app does not reimplement the agent loop.** It spawns persistent `graff --json` child processes per conversation and translates streamed JSONL events into GUI state. (`gui/src-tauri/src/runtime/simple.rs:85-97`, `gui/src-tauri/src/runtime/simple.rs:690-1005`, `gui/src-tauri/src/runtime/simple.rs:1126-1203`)

3. **The frontend/backend desktop contract centers on snapshots and Tauri commands.** Frontend actions call `desktopClient`, Tauri commands delegate to `RuntimeManager`, the runtime emits `SessionSnapshot`s, and the frontend applies them into session state. (`gui/src/services/desktop/client.ts:338-802`, `gui/src-tauri/src/lib.rs:108-174`, `gui/src-tauri/src/runtime/simple.rs:1074-1079`, `gui/src-tauri/src/runtime/simple.rs:2093-2215`)

## Open question

Which telemetry behavior is intended for source/dev builds? `build.zig` bakes a telemetry endpoint by default unless `-Dtelemetry-endpoint=""` is passed, while the README says source builds have no endpoint baked in unless environment variables are set. (`build.zig:26-37`, `README.md:656-659`)
