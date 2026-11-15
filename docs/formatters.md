# Native formatters

Formatting is **off by default**. Opt in by editing the trusted project
`.harness/settings.json` yourself, then restart graff:

```json
{"formatters": true}
```

Missing, `false`, or a malformed top-level value disables the registry. An
object enables the built-ins and accepts per-name overrides or custom entries:

```json
{
  "formatters": {
    "prettier": false,
    "ruff": {"disabled": true},
    "project-format": {
      "command": ["./scripts/format-one", "{file}"],
      "extensions": [".ts", ".tsx"],
      "detect": ["package.json"],
      "timeout_ms": 1500
    }
  }
}
```

The registry is captured at trusted startup, not reloaded after model writes.
Selected workspaces and subagents inherit that policy. Settings are not loaded
from extra `--add-dir` roots or from a newly selected worktree. No formatter
instructions or tool schemas are added to the model's prompt.

## Selection

A successful native `write_file` or `edit_file` mutation runs at most one
formatter, while still holding its existing same-file lock. Single edits,
batched edits, and verified companion edit routes all use the same registry.
Edit verification runs **before** formatting: formatting cannot hide a splice
that failed to land. Read tools, shell writes, failed edits, and rejected writes
do not trigger formatting.

Custom entries match before built-ins, in settings order. Built-ins then match
in the order below. Extensions are case-insensitive suffixes, including the
leading dot. `disabled: true` or a built-in's `false` disables that entry.
An explicit invalid command/extensions override disables that entry instead of
falling back to the built-in command.

| Name | Extensions | Command and detection |
| --- | --- | --- |
| `zig` | `.zig`, `.zon` | Installed `zig fmt`; no project marker required. |
| `gofmt` | `.go` | Installed `gofmt -w`; no project marker required. |
| `rustfmt` | `.rs` | Installed `rustfmt --config skip_children=true`; requires `Cargo.toml`. Does not recursively format child modules. |
| `ruff` | `.py`, `.pyi` | Installed `ruff format`; requires `pyproject.toml`, `ruff.toml`, or `.ruff.toml`. |
| `prettier` | JS/TS, JSON, CSS/SCSS, HTML, Markdown/MDX, YAML, Vue, Svelte | Existing project `node_modules/.bin/prettier --write`; requires a Prettier config or `package.json`. |
| `biome` | JS/TS, JSON, CSS | Existing project `node_modules/.bin/biome format --write`; requires `biome.json` or `biome.jsonc`. |

Detection walks upward from the target's canonical directory and stops at its
native tool root. The nearest matching project with the required local binary
wins; missing built-ins are skipped. Prettier precedes Biome when both match;
disable Prettier to prefer Biome. The JS executable must resolve inside that
root; dependency links escaping the workspace are not run.

Custom commands take a nonempty argv array, never a shell command string.
`{file}` as a complete argument becomes the canonical absolute target path. If
absent, the file path is appended. Other arguments remain literal, including
spaces, dollar signs and shell metacharacters. Without `detect`, cwd is the
tool root; with `detect`, cwd is the nearest marker directory. Relative command
paths must stay inside the root. Bare commands use the installed PATH.

Graff never installs or downloads a formatter. Rustup automatic toolchain
installation is disabled in the formatter environment. It does not use `npx`, package
manager execution/download wrappers, or an implicit shell. Common package
manager and shell launchers are rejected as custom entry executables. Trusted
custom programs can themselves run arbitrary code: this is an opt-in execution
facility, not an OS sandbox, and should not be enabled for untrusted commands
or formatter plugins/configurations.

## Bounds and failure behavior

Each command defaults to a **2-second** timeout; positive `timeout_ms` is capped
at **10 seconds**. Captured stdout and stderr each have a **4 KiB** limit. The
owned process tree is terminated on timeout/cancellation. Formatting reads and
final-byte checks are bounded to **16 MiB**; larger files are left as written.
Formatter output is not copied into tool results.

A formatter spawn failure, nonzero exit, timeout, cancellation, excessive output,
or unreadable/oversized result restores the already verified **post-edit,
pre-format** bytes. The successful mutation remains successful, with an inline
formatter warning. File permissions are preserved. If a safe restoration is
impossible, the tool reports an error and explicitly says final bytes could
not be verified; read the file before continuing.

Formatting uses only the file scope already authorized by the native tool:
the selected workspace or an explicit existing extra root. In-root symlinks
are preserved; escaping or unresolved links are refused. Confinement is
rechecked before reading or restoring after the formatter. As with native
file tools, these are preflight checks, not atomic protection against a
concurrent malicious rename. The trusted subprocess itself is not sandboxed
against unrelated side effects.

The existing rewind snapshot remains the state **before the user's mutation**;
formatting does not create a second snapshot. Rewind therefore undoes both the
write/edit and its formatting. Byte counts and syntax notes use the final
formatted file bytes, or the restored verified bytes on a formatter failure.
