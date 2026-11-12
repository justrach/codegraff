# 0336. The REPL update notice reads a cache; the network never holds the banner

Status: accepted 2026-11-12

## Context

The interactive REPL banner called `version_status.checkLatest`, a blocking
GET of GitHub's latest-release endpoint, on every launch. There was no cache
and no time bound beyond the HTTP client's own. With the check on, the banner
phase took about 320–350 ms on a normal network (25–28 ms when the request
failed fast), the largest REPL startup cost. `-p`, ACP and `--json` already
skipped it; `GRAFF_NO_UPDATE_CHECK=1` disabled it.

## Decision

The banner notice is stale-while-revalidate (`src/update_check_cache.zig`),
the same shape as model catalogs ([0306](0306-model-catalogs-never-hold-startup.md)):

- The banner reads `~/.graff/update-check.json`
  (`{"v":1,"tag":"<release tag>","checked_ms":<unix ms>,"tried_ms":<unix ms>}`,
  `tried_ms` optional) and renders the notice from it. Boot makes no
  network call.
- When that file is missing, unreadable, a different `v`, holds an
  unparseable tag, or is 24 h old or more (or dated in the future), one
  detached thread refetches the tag and atomically rewrites the file. It has
  a private `Io` and allocator, nothing waits for it, and exit never joins
  it.
- The refresh first records `tried_ms`, keeping the cached tag, and only
  then sends the request. A success rewrites the file without `tried_ms`. A
  refresh that fails, hangs, or is cut off by exit therefore holds the
  following launches off for 30 minutes, not just until the next launch.
  When the file cannot be written at all, a process starts at most one
  refresh. The 24 h TTL still applies to successes.
- The file is untrusted input. Numbers outside i64, or that are not
  integers, fail the parse and the file reads as missing. Ages are computed
  with overflow checks: any i64 timestamp, including the extremes, reads as
  stale or as no back-off, never as a crash. A tag that is not a plain
  release tag (letters, digits, `.-+`, at most 64 bytes, three or four u32
  parts) never reaches the terminal.
- `GRAFF_NO_UPDATE_CHECK` reads no file and starts no thread.
- The notice wording and the version comparison (`version_status.compare`)
  are unchanged; a cached tag not newer than the running build shows nothing.
- `graff update` and `/version` still fetch live, and write the tag they see
  to the same file.

## Consequences

A new release shows its notice one launch late, and on the first launch
ever there is no notice. A machine that cannot reach the release endpoint
makes at most one request per 30 minutes. If HOME cannot be written, it
makes one per launch, the same as the old per-launch check. Revisit if the
notice must be same-launch accurate; that needs a bounded wait, not a
return to the blocking fetch.
