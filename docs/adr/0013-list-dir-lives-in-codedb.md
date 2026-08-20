# 0013. Directory listing is a codedb subcommand, not a catalog tool

Status: accepted 2026-08-20

## Context

grok-build's `list_dir` is a first-class tool: BFS, `.gitignore`, any folder,
10k-character cap, collapsed subtree summaries. graff already has `codedb`
for structural nav and tells the model to prefer it over bash `ls`. A new
always-on catalog entry would tax every turn — that is how the first #574
A/B lost.

`codedb ls` / `tree` are the **index**. They do not list an extra `--add-dir`
root or an unindexed tree.

## Decision

`codedb list_dir <path>` is implemented in-process in graff (no codedb
binary). Same PathConfine jail as `read_file`, including extra roots.
`.gitignore` and `.git/info/exclude` apply; `.git` is omitted; other
dotfiles stay visible. Output is BFS-budgeted at 10k characters.

Do not add a sibling `list_dir` tool unless an A/B shows the extra schema
bytes beat this subcommand.

## Consequences

- Folder listing no longer needs `bash ls` / `find` for confined trees.
- `codedb ls` / `tree` stay index queries.
- The model has to read the codedb description (or the prompt sentence) to
  find `list_dir`; that is the cost of not growing the catalog.
