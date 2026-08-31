#!/usr/bin/env bash
# Tier 1 of the internal eval set: every check here is deterministic, offline,
# and free. No provider calls, no network, no model in the loop. This is what
# the pre-push hook runs, so it has to stay honest and it has to stay fast:
# a warm fmt/reach/sdk subset is seconds; a post-src run rebuilds zig and
# the PTY pool (minutes, see #641).
#
# Tier 2 is the model-backed behavioral eval set (scripts/eval-tier2.py). It is
# deliberately NOT in the hook: it spends turns and it is slower.
#
#   scripts/eval-tier1.sh              run every check
#   scripts/eval-tier1.sh --list       show the check names
#   scripts/eval-tier1.sh --only sdk   run one check
#   scripts/eval-tier1.sh --only tui,tuiguard   run a comma-separated list (#641)
#
set -uo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
cd "$repo_root"

# git exports GIT_DIR (and friends) to hooks. Anything this script spawns —
# the test suite's git-fixture tests, graff itself in the sdk check — inherits
# them, and a child's `git init`/`git commit` in its OWN tmpdir then operates
# on THIS repo instead: `git init` re-marks the checkout bare (core.bare=true)
# and `git commit` lands a stray "fixture" commit on the current branch, with
# the tmpdir as the work tree. Scrub the hook environment so child git
# processes discover their repo from their cwd like they expect.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX

CHECKS=(fmt lines spec reach build tests tui tuiguard invariants sdk)

usage() {
  cat <<'EOF'
usage: scripts/eval-tier1.sh [--only <check[,check...]>] [--list]

checks, in order:
  fmt         zig fmt --check src build.zig
  lines       scripts/check-zig-lines.sh (600-line ceiling, AGENTS.md)
  spec        spec/conformance.py (kernel properties + fixture staleness)
  reach       every file that declares tests is reachable from the test root
  build       zig build
  tests       zig build test, and the suite count never shrinks
  tui         zig build tui-test (the TUI suite was ungated until the 2026-08 bug wave)
  tuiguard    real-binary pty probes: lifecycle invariants (tui-pty-guard.py)
              and virtual-screen checks (test-tui-screenstate.py)
  invariants  the named goal/loop/todo tests actually ran, not just compiled
  sdk         the committed SDKs match `graff --schema`
EOF
}

onlys=()
while (($#)); do
  case "$1" in
    --list) printf '%s\n' "${CHECKS[@]}"; exit 0 ;;
    --only)
      IFS=',' read -ra _parts <<< "${2:-}"
      onlys+=("${_parts[@]}")
      shift 2 || true
      ;;
    --only=*)
      IFS=',' read -ra _parts <<< "${1#--only=}"
      onlys+=("${_parts[@]}")
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'eval-tier1: unknown argument %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if ((${#onlys[@]} > 0)); then
  for only in "${onlys[@]}"; do
    [[ -n "$only" ]] || continue
    found=0
    for name in "${CHECKS[@]}"; do [[ $name == "$only" ]] && found=1; done
    if ((!found)); then
      printf 'eval-tier1: no check named %s (try --list)\n' "$only" >&2
      exit 2
    fi
  done
fi

wanted() {
  if ((${#onlys[@]} == 0)); then return 0; fi
  local c=$1
  for only in "${onlys[@]}"; do [[ $only == "$c" ]] && return 0; done
  return 1
}

failed=()
warned=()
started=$SECONDS

# scripts/eval/tier1_invariants.py `count` exits with this when the suite has run
# far enough ahead of test_count_baseline that the floor guards nothing. Green,
# but say so out loud - that ratchet stalled 350 tests behind for months (#439).
RATCHET_STALLED=3

announce() { printf '\n\033[1m==> %s\033[0m  %s\n' "$1" "$2"; }
record_fail() {
  failed+=("$1")
  printf '\n  \033[31mFAILED\033[0m %s\n  rerun just this check: scripts/eval-tier1.sh --only %s\n' "$1" "$1"
}
record_warn() {
  warned+=("$1")
  printf '  \033[33mWARN\033[0m %s: %s\n' "$1" "$2"
}

# --- fmt ---------------------------------------------------------------
if wanted fmt; then
  announce fmt "zig fmt --check src build.zig"
  if zig fmt --check src build.zig; then
    printf '  formatting is clean\n'
  else
    printf '  the files above are unformatted.\n    fix: zig fmt src build.zig\n'
    record_fail fmt
  fi
fi

# --- lines -------------------------------------------------------------
if wanted lines; then
  announce lines "600-line ceiling on hand-written Zig (AGENTS.md)"
  if bash scripts/check-zig-lines.sh; then :; else
    printf '    fix: split the file above into focused sibling modules.\n'
    record_fail lines
  fi
fi

# --- spec --------------------------------------------------------------
if wanted spec; then
  announce spec "spec/conformance.py — kernel properties + fixture staleness"
  # The Zig leg of the corpus already gates via `tests` (the conformance tests
  # embed the fixtures); this closes the triangle's other side pre-push: the
  # executable model's properties, and that the committed fixtures match it.
  if python3 spec/conformance.py; then :; else
    printf '    a kernel drifted: ratchet the model (lean-proofs/ + spec/ref/) or the impl,\n'
    printf '    then regenerate fixtures: python3 spec/conformance.py --export\n'
    record_fail spec
  fi
fi

# --- reach -------------------------------------------------------------
if wanted reach; then
  announce reach "every declared test is actually COMPILED IN, not just imported"
  # tier1_invariants.py static modelled reachability as a textual @import graph,
  # which over-approximates what Zig analyses: it printed "every test file is
  # reachable" and exited 0 while 37 tests in 12 files were silently skipped.
  # test_reachability.py diffs declared names against the compiled binary
  # instead, so it cannot be fooled by an import Zig never follows.
  if python3 scripts/eval/test_reachability.py; then :; else
    record_fail reach
  fi
fi

# --- build -------------------------------------------------------------
build_ok=1
if wanted build; then
  announce build "zig build"
  if zig build; then
    printf '  zig-out/bin/graff is current\n'
  else
    build_ok=0
    record_fail build
  fi
fi

# The suite count and the SDK gate both need a working compile; skip rather
# than report a second, derived failure.
skip_dependent() {
  printf '\n  \033[33mskipped\033[0m %s (zig build failed above)\n' "$1"
}

# --- tests -------------------------------------------------------------
suite_count() {
  # `--summary all` prints "N/N tests passed" only when the run step actually
  # ran. A fully cached `zig build test` on zig 0.17 prints "Build Summary: 4/4
  # steps succeeded" and nothing else, so this comes back empty and the caller
  # falls back to artifact_count - it does NOT mean the build is red (#439).
  sed -n 's/.*Build Summary:.*; \([0-9][0-9]*\)\/[0-9][0-9]* tests passed.*/\1/p' <<<"$1" | tail -1
}

# The count off the compiled artifact instead of off the build summary: a test
# binary run with no arguments prints "All N tests passed." every time, cached
# build or not, and running it re-proves the suite besides. Pass the same
# -Dtest-filter values the build used so the right artifact is picked out of
# .zig-cache/o (see scripts/eval/tier1_test_binary.py).
artifact_count() {
  python3 scripts/eval/tier1_test_binary.py count "$@"
}

if wanted tests; then
  if ((!build_ok)); then
    skip_dependent tests
  else
    announce tests "zig build test, and the suite count never shrinks"
    out=$(zig build test --summary all 2>&1)
    status=$?
    printf '%s\n' "$out" | tail -4
    if ((status != 0)); then
      printf '    fix: the failing test names are above; rerun one with\n'
      printf '         zig build test -Dtest-filter="<part of the name>"\n'
      record_fail tests
    else
      count=$(suite_count "$out")
      if [[ -z "$count" ]]; then
        printf '  cached build; scanning the compiled artifact for the suite count\n'
        count=$(python3 scripts/eval/tier1_test_binary.py scan)
      fi
      if [[ -z "$count" ]]; then
        printf '  FAIL could not read the test count from the build summary or the test artifact\n'
        record_fail tests
      else
        python3 scripts/eval/tier1_invariants.py count --observed "$count"
        case $? in
          0) : ;;
          "$RATCHET_STALLED") record_warn tests "test_count_baseline is stale (see above)" ;;
          *) record_fail tests ;;
        esac
      fi
    fi
  fi
fi

# --- tui ---------------------------------------------------------------
if wanted tui; then
  if ((!build_ok)); then
    skip_dependent tui
  else
    announce tui "zig build tui-test — the TUI parser/render suite"
    out=$(zig build tui-test --summary all 2>&1)
    if (($? != 0)); then
      printf '%s\n' "$out" | tail -8
      record_fail tui
    else
      printf '%s\n' "$out" | sed -n 's/.*Build Summary: .*; \([0-9/]* tests passed.*\)/  \1/p' | tail -1
    fi
  fi
fi

# --- tuiguard ----------------------------------------------------------
if wanted tuiguard; then
  if ((!build_ok)); then
    skip_dependent tuiguard
  else
    announce tuiguard "18 PTY probes in a 4–8 process pool (#641 / #704 / #537)"
    # Original 17 plus #537's provider-free ESC-split regression.
    # Each owns its pty/tmp/mock; the pool is the wall-time win. Deadlines
    # (#704) are checked first so a wedged probe cannot hang pre-push.
    if python3 scripts/eval/test_tier1_tuiguard.py && python3 scripts/eval/tier1_tuiguard.py zig-out/bin/graff; then :; else
      record_fail tuiguard
    fi
  fi
fi

# --- invariants --------------------------------------------------------
if wanted invariants; then
  if ((!build_ok)); then
    skip_dependent invariants
  else
    announce invariants "the named goal/loop/todo tests are compiled into the suite"
    # #641: the unfiltered `tests` artifact already ran those names. Scanning
    # it avoids two filtered `zig build test` recompiles (~1–3 min cold).
    inv_ok=1
    if ! python3 scripts/eval/tier1_test_binary.py resolve >/dev/null 2>&1; then
      printf '  no test artifact yet; compiling the unfiltered suite once\n'
      if ! zig build test --summary all >/dev/null; then
        inv_ok=0
        record_fail invariants
      fi
    fi
    if ((inv_ok)); then
      if python3 scripts/eval/tier1_invariants.py invariants --scan; then :; else
        printf '    the required set (scripts/eval/tier1-manifest.json):\n'
        python3 scripts/eval/tier1_invariants.py list
        record_fail invariants
      fi
    fi
  fi
fi

# --- sdk ---------------------------------------------------------------
if wanted sdk; then
  if ((!build_ok)); then
    skip_dependent sdk
  else
    announce sdk "the committed SDKs match \`graff --schema\`"
    # The generator rewrites sdk/ IN PLACE, so running it over uncommitted work
    # there destroys it silently. Refuse instead: the check cannot tell a stale
    # commit from an edit in progress, and only one of those is safe to clobber.
    if [ -n "$(git status --porcelain -- sdk/)" ]; then
      printf '  sdk/ has uncommitted changes; skipping rather than overwriting them:\n'
      git status --porcelain -- sdk/ | sed 's/^/    /'
      printf '  commit or stash them, then rerun: scripts/eval-tier1.sh --only sdk\n'
      record_fail sdk
    # Generate against a PRISTINE HOME. graff --schema folds in the live model
    # catalogs cached under $HOME, so a machine that has talked to a provider
    # emits models CI has never heard of: the committed SDK then matched this
    # laptop and failed CI with a drift the local check called clean.
    elif sdk_home=$(mktemp -d) && HOME="$sdk_home" python3 sdk/generate.py --harness ./zig-out/bin/graff >/dev/null; then
      rm -rf "$sdk_home"
      if git diff --exit-code --stat -- sdk/; then
        printf '  sdk/ is in sync with the schema\n'
      else
        printf '\n  The generator just rewrote the files above, so the committed SDKs were\n'
        printf '  stale. They are regenerated in your working tree right now - review and\n'
        printf '  commit them:\n'
        printf '    git add sdk/ && git commit -m "chore(sdk): regenerate from the schema"\n'
        record_fail sdk
      fi
    else
      printf '  sdk/generate.py failed\n'
      record_fail sdk
    fi
  fi
fi

# --- verdict -----------------------------------------------------------
elapsed=$((SECONDS - started))
if ((${#warned[@]} > 0)); then
  printf '\n\033[33m%d warning(s)\033[0m: %s\n' "${#warned[@]}" "${warned[*]}"
fi
if ((${#failed[@]} == 0)); then
  printf '\n\033[32mtier 1 green\033[0m in %ss\n' "$elapsed"
  exit 0
fi
printf '\n\033[31mtier 1 red\033[0m in %ss - %d check(s) failed: %s\n' \
  "$elapsed" "${#failed[@]}" "${failed[*]}"
printf 'rerun one with: scripts/eval-tier1.sh --only <check>\n'
exit 1
