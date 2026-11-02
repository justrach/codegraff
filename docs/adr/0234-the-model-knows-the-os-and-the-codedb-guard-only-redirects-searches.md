# 0234. The model knows the OS, and the codedb guard only redirects what codedb does better

Status: accepted 2026-10-02

## Context

Run against Claude Code on the same model and the same tasks, graff lost a
whole model call in every run of three of the coding tasks. None of those
calls did work the task asked for.

- **GNU syntax on BSD tools.** To fix one line the model wrote
  `sed -i 's/a/b/' file.py`. On macOS, BSD `sed` reads the script as the
  backup suffix and the file name as the script, fails with
  `invalid command code`, and the model tries again with `sed -i ''`. Nothing
  graff sends says which OS the commands run on. Claude Code's prompt names
  the platform, and there the model used its edit tool or BSD syntax.
- **The codedb guard refused edits.** The #626 guard blocks `grep`, `sed`,
  `cat` and the like on an indexed source file and points the model at
  codedb. It took `sed -i ''` for a read, so a correct in-place edit came back
  as an error and the model redid it with `edit_file`.
- **The guard refused small whole-file reads.** `cat utils.py; cat main.py`
  on two short files was refused too. The model then read them with
  `read_file`, which returns the same text one call later. codedb pays on
  searches and on files too big to read whole, not on a 40-line file.

## Decision

- The `shell` tool's description names the OS its commands run on: "on macOS
  (BSD tools: `sed -i ''`, no GNU-only flags)" in a macOS build, "on Linux" in
  a Linux build, and nothing elsewhere. The text is fixed per build, so the
  cached prefix does not change between turns.
- The codedb guard lets three shapes through (`codedb_guard_scope.zig`):
  - an in-place `sed` edit (`-i`, `-i ''`, `-i.bak`, `-Ei`, `--in-place`) in
    the command's first segment;
  - a plain whole-file read (`cat`, `head`, `tail`, `nl`, `wc`, `bat`) with no
    pipe, when every file it names exists and is at most 16 KiB, the size a
    tool result keeps inline before it becomes a handle;
  - a write-only `cat` (#1709): its first segment names no input file and
    sends stdout to a file, as in `cat > f <<'EOF'` or `cat >> f <<EOF`. An
    output redirection target is a destination, so its size never counts
    toward the read limit; a file operand or `<` input still makes it a read.

  Searches (`grep`, `rg`, `awk`, `sed` without `-i`, or a read piped into
  one) and reads of bigger files still go to codedb. Both checks run before
  the index probe, so a command they pass also skips the `codedb outline`
  subprocess.

Three other changes were measured on the same tasks and dropped. Sending no
reasoning effort on the default level, so that the model would not think,
made it take more calls and write more, and it was slower overall. Sending
low effort instead of medium was inside the run-to-run noise. Skipping the
startup scan for orphaned listeners saves its subprocesses on every
interactive start, but the gain is below what these runs can resolve, and
that scan belongs to the server lifecycle (#199). It is not changed here.

## Consequences

An in-place `sed` edit is a shell write like any other: the write guard of
ADR 0231 and `/rewind`'s file snapshots do not see it, as they never saw a
script that writes a file. A whole read of a 16 KiB file costs the same
context as `read_file`. A Windows build says nothing about its shell, as
before.

Revisit the OS clause if traces still show GNU-only syntax failing on macOS,
and the 16 KiB read limit if models start reading many small files one `cat`
at a time where one codedb query would do.
