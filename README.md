# CodeGraff

CodeGraff is the terminal-first coding agent stack. The public CLI is **Graff** and the command you run is `graff`.

The local workflow is built around:

| Tool | Purpose |
|---|---|
| `graff` | Agent CLI for prompts, shell integration, conversations, providers, logs, commits, and MCP |
| `codegraff` | Lightweight terminal UI for persistent agent sessions |
| `codedb` | Local code intelligence and MCP server integration |
| zsh `:` commands | Fast shell-native prompt routing to Graff |

```bash
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

## Contents

- [Install](#install)
- [Quickstart](#quickstart)
- [What changed in the Graff rename](#what-changed-in-the-graff-rename)
- [Shell `:` workflow](#shell--workflow)
- [Graff CLI](#graff-cli)
- [CodeGraff TUI](#codegraff-tui)
- [CodeDB and Codex integration](#codedb-and-codex-integration)
- [Agents](#agents)
- [Conversation management](#conversation-management)
- [Git helpers](#git-helpers)
- [Configuration](#configuration)
- [MCP](#mcp)
- [Legacy Forge compatibility](#legacy-forge-compatibility)
- [Development](#development)

## Install

Install the latest release:

```bash
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

The installer places the tools in `~/.local/bin` by default:

| Tool | Purpose |
|---|---|
| `graff` | Main agent CLI |
| `codegraff` | Terminal UI |
| `codedb` | Code intelligence CLI, daemon, and MCP server |
| `fzf` | Picker used by shell workflows |

Make sure `~/.local/bin` is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Then restart your shell or run:

```bash
exec zsh
```

## Quickstart

### 1. Check the CLI

```bash
graff --help
```

### 2. Configure provider credentials

```bash
graff provider login
```

### 3. Install the zsh integration

```bash
graff zsh setup
exec zsh
```

`graff setup` is also available as a short alias for `graff zsh setup`.

### 4. Send a prompt from your shell

```zsh
: explain this repository
```

If the `:` shortcut does not respond, reload the shell and retry:

```zsh
exec zsh
: hey there
```

## What changed in the Graff rename

The user-facing product is now consistently called **Graff**:

- CLI help, examples, logs, diagnostics, and installer output now use Graff/graff.
- Runtime-visible service identity, MCP client names, commit identity text, and provider display copy were updated to Graff where safe.
- The built-in provider id remains compatible, but provider lists now present it as Graff.
- Shell diagnostics and docs now describe the Graff workflow while preserving legacy setup detection.
- `architecture.md` documents the naming rules, compatibility boundaries, and attribution to the original ForgeCode foundation.

Compatibility names that users may already depend on still work. See [Legacy Forge compatibility](#legacy-forge-compatibility).

## Shell `:` workflow

The zsh plugin intercepts lines that start with `:` and routes them to `graff`. Normal shell commands still run normally.

```zsh
: summarize this repo                  # Send a prompt to the active agent
:new                                   # Start a fresh conversation
:new inspect the current git changes   # Start fresh and send a prompt
:agent forge                           # Switch to the implementation agent
:agent muse                            # Switch to the planning agent
:agent                                 # Pick an agent with fzf
:info                                  # Show current session details
:doctor                                # Diagnose shell/plugin setup
```

Useful checks:

```zsh
echo $_FORGE_PLUGIN_LOADED
bindkey '^M'
```

Expected binding:

```text
"^M" forge-accept-line
```

Some shell internals intentionally keep legacy Forge-compatible names, but the command that runs is `graff`.

## Graff CLI

Run an interactive session:

```bash
graff
```

Run one prompt and exit:

```bash
graff -p "summarize the current project"
```

Pipe a prompt:

```bash
echo "what changed in this diff?" | graff
```

Start in a specific directory:

```bash
graff -C /path/to/project
```

Use a specific agent:

```bash
graff --agent forge -p "fix the failing tests"
graff --agent muse -p "make an implementation plan"
```

Common commands:

```bash
graff info
graff doctor
graff zsh setup
graff logs
graff list agent
graff list model
graff list provider
graff provider login
graff conversation list
graff conversation resume <id>
graff commit --preview
graff suggest "find large log files"
```

## CodeGraff TUI

Start the lightweight terminal UI:

```bash
codegraff
```

From source:

```bash
cargo run -p codegraff-tui --bin codegraff
```

Use the TUI when you want a persistent terminal interface with tool cards, logs, cancellation, markdown rendering, attachments, and usage visibility.

## CodeDB and Codex integration

`codedb` provides local code intelligence. The CodeDB installer registers it with supported tools, including Codex, as an MCP-backed code intelligence source.

A working Codex registration looks like this in `~/.codex/config.toml`:

```toml
[mcp_servers.codedb]
command = "/Users/rachpradhan/bin/codedb"
args = ["mcp"]
```

Verify CodeDB:

```bash
codedb --help
```

Useful CodeDB commands:

```bash
codedb tree                         # Show file tree with language and symbol counts
codedb outline README.md            # List symbols in a file
codedb find <symbol>                # Find where a symbol is defined
codedb search "query text"          # Full-text search
codedb word <identifier>            # Exact word lookup
codedb hot                          # Recently modified files
codedb serve                        # Run HTTP daemon on :7719
codedb mcp                          # Run MCP server over stdio
codedb update                       # Self-update CodeDB
```

If Codex does not see CodeDB, rerun the CodeDB installer through the CodeGraff installer or add the `mcp_servers.codedb` block above to the Codex config.

## Agents

Built-in agents available through `graff` and the `:` workflow:

| Agent | Alias | Purpose | Modifies files? |
|---|---|---|---|
| `forge` | default implementation agent | Builds features, fixes bugs, edits files, runs tests | Yes |
| `muse` | planning agent | Analyzes structure and writes implementation plans | No |

Examples:

```zsh
: fix the failing tests
:agent forge
: update the zsh setup code
:agent muse
: plan a README cleanup
:agent
```

Project-local agent definitions live in `.forge/agents/`. The directory name is retained for compatibility with existing agent configuration.

Project-local instructions can be placed in:

```text
AGENTS.md
```

## Conversation management

```bash
graff conversation list
graff conversation new
graff conversation resume <id>
graff conversation clone <id>
graff conversation dump <id>
graff conversation compact <id>
graff conversation retry <id>
graff conversation rename <id> <name>
graff conversation delete <id>
graff conversation stats <id>
```

Shell shortcuts:

```zsh
:new
:conversation
:conversation <id>
:conversation -
:clone
:retry
:dump
:compact
```

## Git helpers

Generate a commit message and commit:

```bash
graff commit
```

Preview the commit message first:

```bash
graff commit --preview
```

Shell shortcuts:

```zsh
:commit
:commit-preview
```

## Configuration

Provider credentials should be configured interactively:

```bash
graff provider login
```

List providers and models:

```bash
graff list provider
graff list model
```

Provider, model, and MCP configuration should be managed with `graff` commands where possible.

Common environment variables:

```bash
FORGE_BIN=graff                    # zsh plugin backend command
NERD_FONT=1                        # enable Nerd Font prompt icons
```

## MCP

Manage MCP servers with `graff`:

```bash
graff mcp list
graff mcp import
graff mcp show
graff mcp remove
graff mcp reload
```

Project-local MCP config:

```text
.mcp.json
```

Global MCP config still uses the legacy-compatible config directory:

```text
~/.forge/.mcp.json
```

CodeDB can also run as an MCP server:

```bash
codedb mcp
```

## Legacy Forge compatibility

This repository descends from ForgeCode. Graff is the public product name going forward, while selected Forge names remain to preserve compatibility and to acknowledge the original foundation built by the main ForgeCode team.

Keep these legacy surfaces unless a backwards-compatible migration is planned:

- `FORGE_*` environment variables, including `FORGE_BIN`
- `.forge`, `.forge.toml`, and `~/.forge`
- internal crate, module, package, and type names such as `forge_main`, `ForgeConfig`, and `ForgeAPI`
- the built-in implementation agent id `forge`
- the VS Code marketplace extension id `ForgeCode.forge-vscode`
- legacy zsh setup markers used for migration
- generated, distribution, and untracked release artifacts

More detail lives in `architecture.md`.

## Development

Build the CLI:

```bash
cargo build -p forge_main
```

Run the CLI from source:

```bash
cargo run -p forge_main --bin graff
```

Run the TUI from source:

```bash
cargo run -p codegraff-tui --bin codegraff
```

Run focused zsh plugin tests:

```bash
cargo test -p forge_main zsh::plugin
```

Run crate checks:

```bash
cargo check -p forge_main
cargo clippy -p forge_main --all-targets -- -D warnings
```
