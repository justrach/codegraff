#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
cd "$repo_root"

# Keep every checked-in Zig source below the agreed 700-line ceiling. Include
# untracked, non-ignored files locally so a newly split module is checked before
# it is staged; CI sees the same files once they are committed.
max_lines=699
failed=0

while IFS= read -r -d '' file; do
  lines=$(awk 'END { print NR }' "$file")
  if (( lines > max_lines )); then
    printf 'Zig source exceeds %d lines: %s (%d)\n' "$max_lines" "$file" "$lines" >&2
    failed=1
  fi
done < <(git ls-files -z --cached --others --exclude-standard -- '*.zig')

if (( failed != 0 )); then
  exit 1
fi

printf 'All Zig sources are at most %d lines.\n' "$max_lines"
