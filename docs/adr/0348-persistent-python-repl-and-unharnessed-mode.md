# 0348. Persistent Stateful Python REPL (`python_repl`) and Opt-In `--unharnessed` Mode

Status: accepted 2026-11-16

## Context

One-shot `shell("python3 ...")` calls lose in-memory variables, parsed datasets, compiled helpers, and working directory state across turns, forcing models to re-read files and serialize intermediate results back to disk on every step. Meanwhile, `rlm` (ADR 0022) intentionally provides a constrained call-only script surface (`read_file`/`codedb`/`bash`/`subagent`) rather than full Python execution. At the same time, keeping the full native editing/search catalog by default preserves strict path/edit safety and minimum reliability on general software engineering tasks.

## Decision

1. **Persistent per-owner Python 3 worker (`src/python_repl.zig`, `src/python_repl_worker.py`):** Each owner (`root` or subagent worker ID) lazily spawns one persistent Python 3 child speaking newline-delimited JSON over dedicated non-inheritable (`CLOEXEC`) duplicated file descriptors (`proto_in`/`proto_out`). Before executing code, stdio fds `1`/`2` and `sys.stdout`/`sys.stderr` redirect into an unlinked per-call temporary capture file so subprocess and C-level fd writes capture without corrupting JSONL framing. The last expression statement evaluates via `ast.Expression`, binds `_`, and returns `repr()`, while POSIX `SIGALRM` + Zig `Io.Select` watchdogs bound hangs without dropping prior REPL globals on recoverable errors or `SystemExit`. Workspace switches automatically update `os.chdir` and `sys.path[0]`.
2. **Dual exposure — folded native `python_repl` + opt-in `--unharnessed` 1-tool mode:**
   - **`python_repl` in normal sessions:** Appended via `python_repl.catalogExtras()` and registered in `native_fold.folded`, keeping turn-1 tool schemas and the 64-cell `tool_catalog.json` cube unchanged until loaded (`load_tool_schemas`) or called.
   - **`--unharnessed` / `/unharnessed` (`src/unharnessed_mode.zig`):** Opt-in mode (`CLI > GRAFF_UNHARNESSED > .harness/settings.json`, default `false`) exposing ONLY the single `python` tool and a compact single-tool system prompt, bypassing `orchestrator_turn` handoff, with live toggle parity across CLI, REPL (`/unharnessed`), `--json` (`set_unharnessed`), and ACP (`configOptions` `id: "unharnessed"`).
3. **Uniform safety & lifecycle invariants:** Both `python_repl` and `python` are blocked by `--no-local-tools`, refused in `plan_mode` and read-only subagents, checked against `.harness/settings.json` hard policies (`tool.use`), serialized in mixed tool batches (`agent_tool_batch.isSequential`), and reset on `/clear`, `/new`, ACP `session/load`, or `reset: true`, with workers reaped on exit in `session_globals.release`.

## Consequences

- Normal `graff` sessions keep the existing turn-1 schema budget while unlocking persistent cross-turn Python state on demand via `python_repl`.
- Sessions launched with `--unharnessed` (or toggled via `/unharnessed on` / ACP) expose a clean 1-tool `python` loop with full auth, transport, approval, and trace parity.
- `--no-local-tools` continues to take precedence over unharnessed settings so host execution cannot be bypassed in embedder deployments.
