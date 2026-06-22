# subagent sa-006-5eefb3a1

- label: Ultracode interaction audit
- kind: workflow_task
- status: ok
- elapsed_ms: 215420
- tools: codedb,codedb,codedb,bash,bash,codedb,codedb,codedb,codedb,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash,bash

## task

Audit whether the ultracode changes could have removed or overwritten a TUI prompt badge format like `[gpt-5.5]({folder_name})`. Use codedb search/symbol/callers/outline first to locate ultracode prompt badge changes in `src/main.zig`, then inspect diffs/history if useful. Report whether ultracode caused the regression, and if so how; if not, identify the more likely culprit.

## report

I used codedb first:

- `codedb search ultracode` found the relevant docs/GUI/runtime hits and pointed to `src/main.zig`.
- `codedb outline src/main.zig` failed because `src/main.zig` is not indexed in codedb in this checkout, so I fell back to git/file inspection.

## Current TUI prompt format

Current `src/main.zig` prints the REPL prompt in `Agent.prompt` as:

- `src/main.zig:8248` for context-token prompt:
  ```zig
  "\n{s}[{s}{s}{s}{s}{s} · cwd {s}{s}{s} · {d}/{d}k tok ..."
  ```
- `src/main.zig:8255` for normal prompt:
  ```zig
  "\n{s}[{s}{s}{s}{s}{s} · cwd {s}{s}{s}{s}]{s} {s}›{s} "
  ```

So the current format is effectively:

```text
[gpt-5.5 · cwd /path/to/folder] ›
```

not:

```text
[gpt-5.5](folder_name) ›
```

## Did ultracode remove/overwrite `[gpt-5.5]({folder_name})`?

I do **not** see a defensible current-branch regression caused by the ultracode commits.

Concrete history:

1. `ba861df Add pwd command and show workspace folder` added the folder display to `Agent.prompt`, but it added it **inside the square brackets** with a middle-dot separator:
   ```diff
   - [{model...}]
   + [{model...} · {g_cwd_display}]
   ```
   It did not implement `[model](folder)`.

2. `00e281a fix: label cwd in repl prompt` changed that same display to include the literal label `cwd`:
   ```diff
   - [model · /path]
   + [model · cwd /path]
   ```

3. The current-branch ultracode TUI commits I inspected:
   - `529c65a feat: shine the ultracode codeword banner`
   - `b0a0de4 feat: shine the ultracode codeword on the input line too`
   - `9104c87 feat: wave the ultracode input shine across letters over time`
   - `91a7c2e feat: softer ultracode wave — gentler pulse + smooth interpolated hues`
   - `460a400 feat: /ultracode slash command for persistent ultracode mode`

   do **not** rewrite the prompt badge format in `Agent.prompt`. `460a400` adds `/ultracode`, `root.ultracode_mode`, JSON control handling, and codeword behavior, but the shown diff does not touch the prompt-printing hunk.

## Suspicious non-current ultracode branch

There is one ultracode-related commit in `--all` history that *would* be suspicious if someone were auditing a different branch:

- `904bfa8 feat: add ultracode mode and trajectory usage`

That commit rewrites `Agent.prompt` to add an ultracode flag and prompt-width bookkeeping. Its parent did **not** have the cwd prompt changes, so its prompt hunk has no folder/cwd display. However:

```text
git merge-base --is-ancestor 904bfa8 HEAD
# exit 1
```

So `904bfa8` is **not an ancestor of the current HEAD** I audited. It is not the cause of the current checkout’s prompt format.

## More likely culprit

If the expected format was specifically:

```text
[gpt-5.5]({folder_name})
```

then the likely culprit is not ultracode. The repo history I checked does not show that exact format ever existing in `src/main.zig`.

The current visible behavior is more directly explained by:

- `ba861df` introducing folder display as `[model · /path]`, and then
- `00e281a` changing it to `[model · cwd /path]`.

Those commits changed the prompt badge shape around the workspace display; ultracode did not.

## Verdict

No defensible defect found that current-branch ultracode changes removed or overwrote `[gpt-5.5]({folder_name})`. The more likely culprit is the folder-prompt work itself, especially `ba861df`/`00e281a`, which implemented/labeled cwd inside the bracketed badge rather than using a parenthesized folder suffix.
