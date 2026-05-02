# Architecture

CodeGraff is a terminal-first AI coding agent stack built in Rust. The public CLI is `graff`. The workspace contains 26 crates organized into a clean-architecture stack with strict separation between domain, application, services, repository, and infrastructure layers.

## High-level overview

Three binaries ship from this workspace:

| Binary | Crate | Purpose |
|---|---|---|
| `graff` | `forge_main` | Main agent CLI — prompts, conversations, providers, shell integration, MCP |
| `codegraff` | `codegraff-tui` | Lightweight terminal UI for persistent agent sessions |
| `codedb` | (separate repo) | Local code intelligence daemon and MCP server |

The local workflow is built around a zsh plugin that intercepts `: command` syntax, routes it to `graff`, and returns formatted output inline.

---

## Crate architecture

### Layer diagram

```
main.rs ──► forge_api (ForgeAPI) ──► forge_app (ForgeApp + Orchestrator)
                                        │
                         ┌──────────────┼──────────────┐
                    forge_services   forge_infra    forge_repo
                    (business logic)  (I/O impl)   (persistence)
                                        │
                                   forge_domain
                                   (pure types)
```

### Domain layer — `forge_domain`

`crates/forge_domain/src/lib.rs:1-119` — Pure domain types with zero infrastructure dependencies. Approximately 55 modules covering:

- **Agent system**: `Agent`, `AgentId`, `AgentInfo`, `ReasoningConfig` with effort levels (`crates/forge_domain/src/agent.rs:18-169`)
- **Conversations**: `Conversation`, `ConversationId`, `MetaData`, message compaction (`crates/forge_domain/src/conversation.rs:13-203`)
- **Context management**: `Context`, `ContextMessage`, token counting, attachment handling, model change detection (`crates/forge_domain/src/context.rs:41-433`)
- **Provider/model types**: `Provider`, `ProviderId`, `Model`, `ModelId`, `Parameters`, `InputModality` (`crates/forge_domain/src/provider.rs:17-370`, `crates/forge_domain/src/model.rs:11-85`)
- **Chat protocol**: `ChatRequest`, `ChatResponse`, `ChatResponseContent` (streaming + non-streaming)
- **Tool definitions**: `ToolDefinition`, `ToolCall`, tool schemas, tool order
- **Shell execution**: `CommandOutput` (`crates/forge_domain/src/shell.rs:3-14`)
- **File operations**: `File`, `ReadOutput`, `PatchOutput`, `SearchResult`, `Match`
- **MCP types**: `McpServerConfig`, MCP client/server abstractions
- **Skills and commands**: `Skill`, skill repository trait
- **Workspace**: CWD resolution, file discovery configs
- **Infrastructure ports**: Repository traits that `forge_repo` implements

Also provides the `ArcSender` type alias for tokio mpsc channels carrying `ChatResponse` results.

### Application layer — `forge_app`

`crates/forge_app/src/lib.rs:1-60` — The application orchestration layer. This is where business logic lives, separated from I/O.

**`ForgeApp<S>`** (`crates/forge_app/src/app.rs:47-50`) — Central application struct holding services and a `ToolRegistry`. Exposes methods for tool listing, model queries, and agent execution.

**`Orchestrator<S>`** (`crates/forge_app/src/orch.rs:20-30`) — The agent execution loop. Holds the `Conversation`, `Agent`, tool definitions, models, an error tracker, and a `Hook`. The main loop: construct context, send chat request, receive response, parse tool calls, dispatch tools via `ToolExecutor`, repeat. Supports up to 100 requests per turn by default.

**`AgentExecutor`** (`crates/forge_app/src/agent_executor.rs:16-19`) — Wraps agent execution with model selection, conversation compaction triggers, and post-turn hook invocation.

**`services.rs`** (`crates/forge_app/src/services.rs:534-590`) — The `Services` trait, a composition of 25+ sub-traits:
- `ProviderService` — LLM provider management
- `ConversationService` — Conversation CRUD, compaction, stats
- `ShellService` — Command execution
- `FsReadService`, `FsWriteService`, `FsPatchService`, `FsRemoveService`, `FsUndoService`, `FsSearchService` — File system tools
- `McpService`, `McpConfigManager` — MCP server lifecycle
- `PolicyService` — Tool execution policies
- `TemplateService`, `AttachmentService`, `CustomInstructionsService` — Prompt construction
- `WorkspaceService`, `FileDiscoveryService` — Repository context
- `AuthService`, `ProviderAuthService` — Authentication
- `AgentRegistry` — Agent discovery and loading
- `SkillFetchService` — Skill resolution

**`infra.rs`** (`crates/forge_app/src/infra.rs:20-419`) — Infrastructure trait definitions:
- `EnvironmentInfra` — CWD, environment variables, config access
- `FileReaderInfra`, `FileWriterInfra`, `FileRemoverInfra`, `FileInfoInfra` — File I/O
- `CommandInfra` — Shell command execution
- `HttpInfra` — HTTP client with retry/streaming
- `McpClientInfra`, `McpServerInfra` — MCP transport
- `WalkerInfra`, `DirectoryReaderInfra` — File tree walking
- `KVStore` — Key-value persistence
- `OAuthHttpProvider`, `AuthStrategy`, `StrategyFactory` — OAuth flows
- `AgentRepository` — Agent file parsing and storage
- `GrpcInfra` — gRPC client for workspace sync

**Other application modules**: `dto/` (provider-specific request/response serialization, e.g. OpenAI, Anthropic), `system_prompt` (system prompt template construction), `user_prompt` (user prompt assembly), `transformers/` (message transformation pipeline), `fmt/` (output formatting for tool results), `tool_registry.rs`, `tool_executor.rs`, `tool_resolver.rs`.

### Services layer — `forge_services`

`crates/forge_services/src/forge_services.rs:44-87` — Concrete service implementations. `ForgeServices<R>` is parameterized over the repository layer and implements the full `Services` trait. Key modules:

- `agent_registry` — Discovers and loads agents from built-in and `.forge/agents/`
- `app_config` — Reads and manages `.forge.toml` configuration
- `provider_auth` — OAuth and API key authentication flows
- `provider_service` — Provider and model listing/discovery
- `conversation` — Conversation persistence and lifecycle
- `context_engine` — Context assembly from workspace, attachments, and agent config
- `discovery` — File discovery and workspace scanning
- `fd`, `fd_git`, `fd_walker` — File discovery implementations
- `mcp` — MCP server management (import, remove, reload)
- `policy` — Tool execution policy enforcement
- `tool_services` — Individual tool service implementations
- `template` — Template rendering for prompts
- `instructions` — Custom instruction loading from `AGENTS.md`
- `sync` — Workspace sync via gRPC

Also defines `IntoDomain` and `FromDomain` conversion traits (`crates/forge_services/src/lib.rs:40-56`).

### Repository layer — `forge_repo`

`crates/forge_repo/src/forge_repo.rs:41-53` — Persistence and data access. `ForgeRepo<I>` is parameterized over infrastructure and implements all repository traits. Uses Diesel ORM with SQLite for local state. Modules:

- `agent` — Agent file parsing (YAML frontmatter + Markdown body)
- `agent_definition` — Agent definition CRUD
- `conversation` — Conversation persistence
- `database` — Diesel schema, migrations, connection management
- `provider` — Provider and model storage
- `skill` — Skill persistence
- `context_engine` — Context serialization
- `fuzzy_search` — Fuzzy file/symbol search
- `fs_snap` — File system snapshots

Also includes protobuf-generated code via `tonic` for gRPC workspace server communication.

### Infrastructure layer — `forge_infra`

`crates/forge_infra/src/lib.rs:1-27` — Concrete I/O implementations:
- `forge_infra` — Central `ForgeInfra` struct composing all infra implementations
- `executor` — `ForgeCommandExecutorService` for shell command execution
- `env` — `ForgeEnvironmentInfra` for environment variable access
- `http` — HTTP client with retry, streaming, and header sanitization
- `mcp_client`, `mcp_server` — MCP transport over stdio and SSE
- `grpc` — gRPC client for workspace server
- `kv_storage` — `CacacheStorage` for content-addressed cache
- `walker` — File tree traversal
- `fs_read`, `fs_write`, `fs_remove`, `fs_create_dirs`, `fs_meta`, `fs_read_dir` — File system operations
- `auth` — Authentication strategy implementations
- `console` — `StdConsoleWriter` for terminal I/O
- `inquire` — Interactive prompts

### API facade — `forge_api`

`crates/forge_api/src/forge_api.rs:24-27` — The public API entry point. `ForgeAPI<S, F>` is generic over services and infrastructure:

```rust
pub struct ForgeAPI<S, F> {
    services: Arc<S>,
    infra: Arc<F>,
}
```

The concrete initialization (`crates/forge_api/src/forge_api.rs:44-56`) wires up the full stack:

```
ForgeInfra → ForgeRepo → ForgeServices → ForgeAPI
```

Implements the `API` trait with methods: `discover()`, `get_tools()`, `get_models()`, `get_all_provider_models()`, `get_skills_internal()`, and agent/conversation operations.

### CLI and UI — `forge_main`

`crates/forge_main/src/main.rs:48-129` — The binary entrypoint. Flow:

1. Parse CLI args via `clap` (supports piped stdin, `--prompt`, `--agent`, `--directory`, sandbox worktrees, and ~20 subcommands)
2. Enable ANSI/VT processing on Windows
3. Install rustls crypto provider
4. Set panic hook for formatted error display
5. Read `.forge.toml` config at startup
6. Resolve working directory (supports sandbox worktrees and `-C` flag)
7. Initialize `UI` which bootstraps the `ForgeAPI` stack
8. Run the UI event loop

**`ui.rs`** (`crates/forge_main/src/ui.rs:105-117`, ~5000 lines) — The interactive session driver: renders prompts, manages the conversation loop, delegates to `ForgeApp` for chat, formats tool outputs, handles stream rendering.

**`cli.rs`** (`crates/forge_main/src/cli.rs:15-68`, ~1929 lines) — Complete CLI argument definitions with ~77 unit tests covering all subcommand parsing.

**Other modules**: `zsh/` (shell plugin and setup), `editor/` (external editor integration), `completer/` (tab completion), `highlighter/` (syntax highlighting), `stream_renderer/` (streaming markdown to terminal), `logs/`, `info/`, `model/`, `porcelain/` (machine-readable output), `banner/`, `vscode/` (extension installation), `update/`.

### TUI — `codegraff-tui`

`crates/codegraff-tui/src/main.rs` — A single 208K Rust file implementing a terminal UI with tool cards, logs, cancellation, markdown rendering, attachments, and usage visibility. Also includes `text.rs`, `terminal.rs`, `tool_card.rs`, and `logging.rs`.

### Utility crates

| Crate | Purpose |
|---|---|
| `forge_fs` | File system abstraction with consistent error handling (`crates/forge_fs/src/lib.rs:26-36`) |
| `forge_config` | Configuration structs (`ForgeConfig`) parsed from `.forge.toml` |
| `forge_embed` | Compile-time embedding of `.forge/` templates via `include_dir` |
| `forge_stream` | Streaming utilities for async byte streams |
| `forge_markdown_stream` | Streaming markdown-to-terminal rendering with table support |
| `forge_display` | Diff display and formatting |
| `forge_template` | Template engine for prompt and system message construction |
| `forge_walker` | File tree walking with gitignore support |
| `forge_tracker` | Analytics and telemetry (PostHog) |
| `forge_tool_macros` | Procedural macros for tool definition derive |
| `forge_spinner` | Terminal spinner utilities |
| `forge_snaps` | Snapshot testing helpers |
| `forge_select` | Fuzzy picker widget (`ForgeWidget` based on `nucleo`) |
| `forge_json_repair` | JSON repair for malformed LLM outputs |
| `forge_eventsource` | Server-Sent Events client |
| `forge_eventsource_stream` | SSE event streaming |
| `forge_test_kit` | Test utilities and fixtures |
| `forge_ci` | CI helper utilities |

---

## Initialization flow

1. `main()` calls `run()` (`crates/forge_main/src/main.rs:48-129`)
2. CLI args parsed, stdin piped input detected
3. `ForgeConfig::read()` loads `.forge.toml`
4. Working directory resolved (supports sandbox worktrees)
5. `UI::init()` creates the concrete stack:
   - `ForgeInfra::new(cwd, config)` — environment, file system, HTTP, command executor
   - `ForgeRepo::new(infra)` — Diesel DB, agent parsing, persistence
   - `ForgeServices::new(repo)` — all service implementations
   - `ForgeAPI::new(services, repo)` — public API facade
6. `ui.run()` starts the interactive session loop

---

## Architectural patterns

### Generic over infrastructure

All services and repositories take a single generic type parameter (`S` for services, `I` or `R` for infrastructure/repository). Trait objects (`Box<dyn>`) are never used for core dependencies.

```rust
pub struct ForgeApp<S> { services: Arc<S>, ... }
pub struct ForgeRepo<I> { infra: Arc<I>, ... }
pub struct ForgeServices<R> { repo: Arc<R>, ... }
```

### Arc-based sharing

Infrastructure and services are wrapped in `Arc<T>` for cheap cloning and shared ownership across components.

### Constructor without bounds

`new()` methods have no trait bounds. Bounds go on the methods that need them:

```rust
impl<S> Orchestrator<S> {
    pub fn new(services: Arc<S>, ...) -> Self { ... }
}
impl<S: AgentService + EnvironmentInfra> Orchestrator<S> {
    pub async fn run(&mut self) -> Result<()> { ... }
}
```

### Composed trait bounds

When a method needs multiple infrastructure capabilities, the `+` operator composes them into a single bound rather than adding separate type parameters:

```rust
impl<F: FileReader + Environment> FileService<F> {
    pub async fn read_with_validation(&self, path: &Path) -> Result<String> { ... }
}
```

### Tuple struct pattern for single-dependency services

```rust
pub struct FileService<F>(Arc<F>);
```

### No service-to-service dependencies

Services depend on infrastructure traits or repositories, never on other services directly. This prevents circular dependencies and keeps the graph acyclic.

---

## Provider integration

Built-in providers are defined as an enum `ProviderType` in `crates/forge_domain/src/provider.rs:17-23` and a static list of `Provider` structs. Each provider specifies:

- Chat completions URL
- Model listing URL  
- Authentication types (API key, OAuth, AWS IAM, Google Cloud, etc.)
- Default headers and query parameters
- Input modality support (text, image)
- Native tool calling support

The `ProviderId` struct (`crates/forge_domain/src/provider.rs:44-162`) handles parsing from strings (e.g., `"codex"`, `"fireworks"`, `"vertex-ai:us-central1"`), display name formatting, and URL construction.

Model listing is provider-specific: some use `/models` endpoints (OpenAI-compatible), others use hardcoded lists, and some support dynamic discovery. The `AnyProvider` enum (`crates/forge_domain/src/provider.rs:288-291`) provides a unified interface for all provider-specific logic.

DTO serialization lives in `crates/forge_app/src/dto/` with per-provider modules (OpenAI format, Anthropic format, etc.).

---

## Agent system

Two built-in agents ship with the system:

| Agent ID | Alias | Purpose | Modifies files? |
|---|---|---|---|
| `forge` | default implementation agent | Builds features, fixes bugs, edits files, runs tests | Yes |
| `muse` | planning agent | Analyzes structure and writes implementation plans | No |

Custom agents are defined as `.md` files in `.forge/agents/` with YAML frontmatter:

- `id`, `title`, `description` — identity
- `reasoning` — reasoning config (effort, max_tokens, summary)
- `tools` — tool allow/deny lists
- `user_prompt` — custom user prompt template

The agent parser (`crates/forge_repo/src/agent.rs`) uses `gray_matter` for YAML frontmatter extraction and supports runtime variable substitution in prompts.

Agent loading chain: `AgentRegistry` (services) → `AgentRepository` (repo) → `forge_repo::agent` (parser) → `.forge/agents/*.md` (files).

---

## Tool system

Tools are defined through the `forge_tool_macros` proc-macro crate. The `ToolRegistry` in `forge_app` maps tool names to their implementations. The `ToolExecutor` dispatches tool calls during the orchestration loop.

Supported tools include:
- **File system**: `fs_read`, `fs_write`, `fs_patch`, `fs_remove`, `fs_search`, `fs_undo`, `fs_create`
- **Shell**: `shell` (command execution with timeout)
- **Network**: `fetch` (HTTP GET with markdown conversion)
- **Task management**: `todo_write`, `todo_read`
- **Agent delegation**: `task` (sub-agent spawning)
- **Planning**: `plan_create` (muse agent)
- **MCP**: external tools from configured MCP servers
- **Skills**: `skill` (skill invocation)

Tool output formatting is handled by `forge_app/src/fmt/` with per-tool formatters for consistent terminal rendering.

---

## MCP integration

The system acts as both an MCP client and server:

- **MCP client** (`forge_infra/src/mcp_client.rs`) — Connects to external MCP servers over stdio and SSE transports. Supports server registration, tool discovery, and tool invocation.
- **MCP server** — `codedb mcp` runs a code intelligence MCP server over stdio that other tools (e.g., Codex) can consume.
- **Config files** — `.mcp.json` (project-local) and `~/.forge/.mcp.json` (global) define MCP server configurations.

Management commands: `graff mcp list`, `graff mcp import`, `graff mcp remove`, `graff mcp reload`, `graff mcp show`.

---

## Shell integration

The zsh plugin lives in `shell-plugin/` and `crates/forge_main/src/zsh/`. It intercepts lines starting with `:` and routes them to `graff`.

Shell commands:
- `: prompt` — send prompt to active agent
- `:new` — start fresh conversation
- `:agent <id>` — switch agent
- `:commit` — generate commit message
- `:conversation`, `:clone`, `:retry`, `:dump`, `:compact` — conversation management
- `:info`, `:doctor` — diagnostics

Plugin files: `forge.plugin.zsh`, `forge.setup.zsh`, `forge.theme.zsh`, `keyboard.zsh`, `doctor.zsh`, and shared utilities in `lib/`.

---

## Configuration

Config is read from `.forge.toml` at startup via `forge_config::ForgeConfig`. Environment variables:

- `FORGE_BIN` — path to the `graff` binary (for zsh plugin)
- `FORGE_CONFIG` — override config file location
- `NERD_FONT` — enable Nerd Font prompt icons

Legacy paths (`.forge`, `~/.forge`, `~/forge`) are still resolved for backwards compatibility.

---

## Data flow during a prompt

1. User sends a prompt (via CLI, zsh `:`, or TUI)
2. `UI` passes it to `ForgeApp`
3. `ForgeApp` creates an `Orchestrator` with the `Conversation`, `Agent`, and services
4. Orchestrator loop:
   a. Assembles `Context` from conversation history, system prompt, workspace info, custom instructions, and agent configuration
   b. Selects the model from agent/provider config
   c. Sends `ChatRequest` via `ProviderService`
   d. Receives streaming `ChatResponse` (may contain text and/or tool calls)
   e. If tool calls present: dispatches to `ToolExecutor` → runs tool → adds tool result to context → loops
   f. If text response: checks for follow-up questions → renders to terminal
5. Conversation is persisted via `ConversationService` → `ForgeRepo` → Diesel/SQLite

---

## Database

`forge_repo` uses Diesel ORM with SQLite (`crates/forge_repo/src/database/`). Schema includes tables for conversations, messages, providers, models, agents, and skills. Migrations are managed through Diesel's migration system. The `diesel.toml` at the repo root configures the schema file location.

gRPC workspace sync uses protobuf definitions in `forge_repo/proto/` compiled via `tonic` for communication with a remote workspace server.

---

## Naming and legacy Forge compatibility

Graff is the user-facing product name for the CLI and related tooling. New product copy, help text, installer output, diagnostics, and user-visible service messages should use **Graff** or `graff`.

Some Forge names intentionally remain in the architecture for compatibility, migration safety, and attribution to the original team that built the system. Do not rename these surfaces unless a migration plan explicitly preserves existing users, configs, scripts, extensions, and agent workflows.

### Compatibility surfaces that intentionally keep Forge names

- `FORGE_*` environment variables, including `FORGE_BIN`, remain supported. The shell integration currently maps `FORGE_BIN` to the `graff` executable by default, so existing shell setups can continue to work without renaming user environment variables.
- `.forge`, `.forge.toml`, and `~/.forge` remain the canonical compatibility paths. The config reader still resolves `FORGE_CONFIG`, then the legacy `~/forge` directory when present, and finally `~/.forge`.
- Internal crate, module, package, and type names such as `forge_main`, `ForgeConfig`, and `ForgeAPI` remain internal architecture names. They are not product copy and should not be renamed as part of user-facing branding cleanup.
- The built-in implementation agent id remains `forge`. This preserves existing commands such as `:agent forge`, config files, slash-command aliases, and workflows that target the default implementation agent.
- The VS Code marketplace extension id remains `ForgeCode.forge-vscode`. Marketplace identifiers are externally registered integration ids and should remain stable even when UI copy says Graff.
- Legacy zsh setup markers such as `# >>> forge initialize >>>` and `# <<< forge initialize <<<` remain recognized for migration. New setup blocks should use Graff markers, but old markers must continue to be detected and upgraded safely.
- Generated, distribution, and untracked release artifacts may still contain historical Forge references. Treat these as build or release outputs unless they are regenerated from source as part of a release process.

### Attribution

The codebase descends from ForgeCode, and some Forge naming remains as a deliberate acknowledgement of the main team that originally built the foundation. Graff should be the public product name going forward, while retained Forge identifiers document lineage, preserve compatibility, and avoid unnecessary churn in stable internal APIs.

### Guideline for future changes

When adding or editing user-facing text, prefer Graff. When touching existing Forge identifiers, first decide whether the string is product copy or a stable compatibility surface. Product copy should become Graff; stable compatibility surfaces should remain Forge unless the change includes a backwards-compatible migration.

---

## Key external dependencies

| Dependency | Usage |
|---|---|
| `tokio` | Async runtime (multi-threaded, with fs/process/signal) |
| `clap` | CLI argument parsing |
| `tonic` / `prost` | gRPC client and protobuf codegen |
| `diesel` | SQLite ORM for local state |
| `reqwest` | HTTP client for provider APIs |
| `rmcp` | MCP client/server transport |
| `serde` / `serde_json` | Serialization |
| `handlebars` | Template rendering for prompts |
| `syntect` | Syntax highlighting |
| `reedline` | Line editing in interactive mode |
| `tracing` | Structured logging |
| `gix` | Git operations |
| `nucleo` | Fuzzy matching |
| `gray_matter` | YAML frontmatter parsing |
| `async-openai` | OpenAI-compatible API types |
