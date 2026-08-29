#!/usr/bin/env bash
# The pre-push gate. Runs tier 1 of the internal eval set (scripts/eval-tier1.sh):
# deterministic, offline, no model calls. Warm fmt/reach/sdk is seconds;
# a post-src run rebuilds zig and the tuiguard pool (minutes, see #641).
#
# Install it once:   scripts/install-hooks.sh
# Skip it once:      git push --no-verify
#                    GRAFF_SKIP_PREPUSH=1 git push
#
# git feeds us one line per ref being pushed on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
# We use that to leave doc-only pushes alone - there is no reason to compile the
# harness because someone fixed a typo in the README.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [[ -n "${GRAFF_SKIP_PREPUSH:-}" ]]; then
  printf 'pre-push: skipped (GRAFF_SKIP_PREPUSH is set)\n' >&2
  exit 0
fi

empty_sha=0000000000000000000000000000000000000000
changed=""
run_anyway=0
saw_ref=0

while read -r _local_ref local_sha _remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  saw_ref=1
  # Deleting a remote ref pushes nothing to check.
  [[ "$local_sha" == "$empty_sha" ]] && continue

  base="$remote_sha"
  if [[ "$remote_sha" == "$empty_sha" ]] || ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    # A brand-new branch, or a remote tip we do not have locally. Fall back to
    # the merge base with the default branch; if even that fails, do not guess -
    # run the checks.
    upstream=$(git rev-parse --verify --quiet origin/HEAD || git rev-parse --verify --quiet origin/main)
    base=$(git merge-base "$local_sha" "$upstream" 2>/dev/null || true)
  fi
  if [[ -z "$base" ]]; then
    run_anyway=1
    continue
  fi
  paths=$(git diff --name-only "$base" "$local_sha" 2>/dev/null) || { run_anyway=1; continue; }
  changed+=$'\n'"$paths"
done

if ((!saw_ref)); then
  exit 0
fi

changed=$(printf '%s\n' "$changed" | sed '/^$/d' | sort -u)

if ((!run_anyway)) && [[ -n "$changed" ]]; then
  # shellcheck disable=SC2086
  if python3 scripts/eval/tier1_invariants.py docs-only $changed; then
    printf 'pre-push: documentation-only push, tier 1 has nothing to check.\n'
    printf '          (%s file(s): %s)\n' \
      "$(printf '%s\n' "$changed" | wc -l | tr -d ' ')" \
      "$(printf '%s' "$changed" | tr '\n' ' ')"
    exit 0
  fi
fi

if ((!run_anyway)) && [[ -z "$changed" ]]; then
  printf 'pre-push: nothing new to push.\n'
  exit 0
fi

# The checks read the working tree, not the commits being pushed - that is what
# makes them fast and what makes the SDK-drift gate meaningful. Say so when the
# two differ, so a red result is never a mystery.
if ! git diff --quiet HEAD 2>/dev/null; then
  printf 'pre-push: note - your working tree differs from HEAD; tier 1 checks the tree.\n'
fi

printf 'pre-push: running tier 1 of the internal eval set (offline, no model calls)\n'
if bash scripts/eval-tier1.sh; then
  exit 0
fi

cat >&2 <<'EOF'

pre-push: BLOCKED. The failing check names are above, each with the one-liner
          that reruns only it.

          If this is an emergency and you know what you are pushing:
            git push --no-verify
EOF
exit 1
