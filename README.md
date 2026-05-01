# Codegraff

Codegraff is an experimental agentic development harness built on top of ForgeCode.

This repository started as a fork of [ForgeCode](https://github.com/tailcallhq/forgecode), because ForgeCode was one of the strongest open-source terminal coding agents available: practical, fast, multi-provider, tool-oriented, and already shaped around real development workflows. I liked the tool a lot and wanted to use it as the foundation for a more opinionated harness that could evolve around my own tooling, my own research loops, and experiments in safer agent execution.

The goal is not to erase that history. The original ForgeCode contributors built the base that made this possible, and I am grateful for their work.

## Why this fork exists

ForgeCode already had the core pieces I wanted from a modern coding agent:

- a Rust implementation with a clean agent/application/domain split
- multi-provider model support
- conversation persistence and token usage accounting
- shell, file, MCP, and workspace tooling
- an interactive terminal workflow
- support for custom agents, commands, and skills
- a sandbox/worktree direction that is worth pushing further

Codegraff takes that foundation and starts steering it toward a separate agentic harness.

The main things I want to explore here are:

1. **A first-class TUI harness**
   
   Codegraff should grow into a dedicated terminal UI for agent work, not just a prompt loop. The current `codegraff` binary is the beginning of that: chat transcript, streaming output, tool cards, image paste support, markdown rendering, scrollback, cancellation, and on-demand usage stats.

2. **Code intelligence through CodeDB**
   
   CodeDB is intended to be a core part of the harness: a local code intelligence layer for fast repository structure lookup, symbol search, dependency inspection, and higher-quality context selection.

3. **Editing and codebase operations through Muonry**
   
   Muonry is another tool I want to integrate more deeply for structured code operations. The long-term direction is for the harness to choose stronger code-aware operations instead of relying only on generic text search and patching.

4. **Sandbox experimentation**
   
   I want Codegraff to become a good place to test safer agent execution: disposable worktrees, constrained runs, isolated experiments, and clearer control over what an agent is allowed to do.

5. **Better human control**
   
   The harness should make agent activity easier to inspect and interrupt: visible tool cards, collapsible outputs, usage stats on demand, `Esc` to stop active runs, and eventually richer session dashboards.

## Current status

This is still early. The repository is currently a ForgeCode-derived codebase with a new experimental TUI crate:

```text
crates/forge_tui/
```

The crate package and binary are named:

```text
codegraff
```

Run it with:

```bash
cargo run -p codegraff --bin codegraff
```

The original Forge CLI is still present and usable:

```bash
cargo run -p forge_main --bin forge
```

## What Codegraff can do today

The current Codegraff TUI can:

- start a Forge-backed conversation
- stream assistant responses
- render a scrollable chat transcript
- render tool calls as compact cards
- expand and collapse tool output
- paste image paths or clipboard images as attachments
- send image attachments through Forge's existing vision attachment pipeline
- render basic markdown with headings, lists, code blocks, quotes, links, and task lists
- stop an active agent run with `Esc`
- use `Shift+Enter` for multiline prompts
- show token/model/session usage only when requested with `/usage`

This is not the final UI. It is the first working slice of the separate harness.

## Where this is going

The long-term direction is for Codegraff to slowly become the main agentic harness in this repository.

Planned areas of evolution:

- a more polished TUI layout with better panes and keyboard navigation
- deeper CodeDB-backed repository awareness
- Muonry-backed structured edit operations
- stronger sandbox/worktree workflows
- richer session and conversation management
- better image rendering once the TUI stack can support it cleanly
- tool timelines, logs, and replayable agent traces
- safer defaults for high-impact shell and filesystem operations
- support for building custom harness flows on top of the Forge agent backend

In short: ForgeCode is the base; Codegraff is the harness direction.

## Relationship to ForgeCode

This project is derived from ForgeCode. ForgeCode was the reason this repository could move quickly: the agent architecture, provider support, terminal workflows, and persistence layers were already strong.

Codegraff will diverge where needed, but the original project deserves clear credit. Thank you to the ForgeCode maintainers and contributors for building the foundation.

## Licensing

The original project remains under its existing license terms.

The new Codegraff TUI folder is licensed separately under BSD-3-Clause:

```text
crates/forge_tui/LICENSE
```

## Development

Common commands:

```bash
# Check the Codegraff TUI crate
cargo check -p codegraff

# Run Codegraff tests
cargo test -p codegraff

# Run the Codegraff TUI
cargo run -p codegraff --bin codegraff

# Run the original Forge CLI from this checkout
cargo run -p forge_main --bin forge
```

## Notes for now

This README intentionally describes the new direction rather than presenting the project as a drop-in official ForgeCode distribution. The codebase still contains much of ForgeCode's original functionality, and that is by design: Codegraff is evolving from that foundation instead of starting from scratch.
