# CodeGraff

CodeGraff is a fast, lightweight coding agent setup for focused terminal development. The working local flow is:

- `graff` — the agent CLI and zsh `:` backend
- `codegraff` — the lightweight terminal UI
- `codedb` — local code intelligence with Codex/MCP integration
- zsh `:` commands — the fastest way to send prompts from your shell

```bash
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

## Table of Contents

- [Install](#install)
- [Quickstart](#quickstart)
- [Shell `:` Workflow](#shell--workflow)
- [Graff CLI](#graff-cli)
- [CodeGraff TUI](#codegraff-tui)
- [CodeDB and Codex Integration](#codedb-and-codex-integration)

## Install

Install the latest release:

```bash
curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
```

The installer adds the tools to `~/.local/bin` by default:

| Tool | Purpose |
|---|---|
| `graff` | Agent CLI, one-shot prompts, shell plugin, conversations, commits, providers |
| `codegraff` | Lightweight terminal UI |
| `codedb` | Local code intelligence server and MCP integration |
| `fzf` | Picker used by shell workflows |

Make sure `~/.local/bin` is on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Or restart your shell after installation.

## Quickstart

### 1. Verify the CLI

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

`graff setup` is also available as a shorter alias for `graff zsh setup`.

### 4. Send a prompt from your shell

```zsh
: explain this repository
```

If `:` does nothing, the shell plugin has not been loaded in that terminal yet. Run:

```zsh
exec zsh
```

Then retry:

```zsh
: hey there
```

## Shell `:` Workflow

The zsh plugin intercepts lines that start with `:` and routes them to `graff`. Normal shell commands still run normally.

```zsh
: summarize this repo                 # Send a prompt to the active agent
:new                                  # Start a fresh conversation
:new inspect the current git changes   # Start fresh and send a prompt
:agent forge                         # Switch to the implementation agent
:agent muse                          # Switch to the planning agent
:agent                               # Pick an agent with fzf
:info                                 # Show current session details
:doctor                               # Diagnose shell/plugin setup
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

The shell integration still exposes some legacy-compatible names internally, but the command that runs is `graff`.

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

## CodeDB and Codex Integration

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

If Codex does not see CodeDB, rerun the CodeDB installer via the CodeGraff installer or add the `mcp_servers.codedb` block above to your Codex config.
