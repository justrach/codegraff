# 0302. File tools allow symlinks that resolve inside their tool root

Status: accepted 2026-10-26

## Context

The native path guard rejected every symlink component, even when its target
stayed inside the checkout. Package-manager dependency links therefore caused
`read_file` and `codedb list_dir` to report a working-directory escape (#1748).
Lexical path validation alone cannot distinguish these links from real escapes.

## Decision

Keep lexical confinement, then inspect every path prefix, including the final
component. A symlink is allowed only when its canonical resolved target is
inside the canonical tool root, compared at a path-component boundary. Relative
paths use the selected agent workspace or cwd; explicitly allowed absolute paths
use their matching `--add-dir` root. Root ancestors may themselves be symlinked.

Dangling and cyclic links, unresolved link targets, and unexpected probe errors
fail closed. Ordinary missing components remain allowed so writes can create
new paths, including beneath an existing in-root directory link. A relative
path cannot use an extra root to escape its own workspace.

## Consequences

Dependency links work without weakening lexical traversal or genuine escape
denial. The shared predicate keeps native reads, listings, edits and writes on
the same policy. Listing a linked root does not make recursive listing follow
arbitrary symlink entries.

Canonicalizing the root adds a filesystem lookup to each check. This remains a
preflight guard followed by ordinary filesystem operations, not an atomic
sandbox against concurrent symlink replacement or rename; race-resistant
confinement would require handle-relative operations throughout the callers.
