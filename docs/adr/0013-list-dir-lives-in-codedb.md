# 0013. Directory listing is a codedb subcommand, not a catalog tool

Status: accepted 2026-08-20

## Context

grok-build's `list_dir` is a first-class tool. graff already has `codedb`
for structural nav and tells the model to prefer it over bash `ls`. A new
always-on catalog entry would tax every turn — that is how the first #574
A/B lost. `codedb ls` / `tree` are the **index**; they do not list an
unindexed tree. The native `codedb` spawn also had no PathConfine, so
`codedb read /etc/passwd` bypassed the file-tool jail.

## Decision

`codedb list_dir <path>` is in-process (PathConfine, gitignore, 10k cap)
and works without the codedb binary. `codedb status` reports
`codedb.snapshot` without spawning. Path-bearing subcommands
(`read`/`outline`/`deps`/`file`) and escaping `glob` patterns use the same
cwd jail as `read_file`. `ls` / `tree` stay index queries.

Do not add a sibling graff `list_dir` catalog tool unless an A/B shows the
extra schema bytes beat this subcommand.

## Consequences

- Folder listing no longer needs `bash ls` / `find` for confined trees.
- The codedb guard redirects those shell commands even when the CLI is missing.
- A missing index is a status line, not a dead tool — `list_dir` still works.
- The model has to read the codedb description to find `list_dir`.
