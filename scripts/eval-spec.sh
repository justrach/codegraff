#!/usr/bin/env bash
# Out-of-the-box check for the Lean conformance corpus.
# Offline, no provider calls. lake is used if present; Zig tests are opt-in.
#
#   scripts/eval-spec.sh           status + properties + fixtures
#   scripts/eval-spec.sh --lean    also lake build + graff-spec-report
#   scripts/eval-spec.sh --impl    also zig test -Dtest-filter=spec/
#   scripts/eval-spec.sh --all     lean + impl
set -euo pipefail
repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
cd "$repo_root"

lean=0 impl=0
for arg in "$@"; do
  case "$arg" in
    --lean) lean=1 ;;
    --impl) impl=1 ;;
    --all) lean=1; impl=1 ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *) echo "eval-spec: unknown argument $arg" >&2; exit 2 ;;
  esac
done

echo "==> status (triangles + floors)"
python3 spec/status.py

echo
echo "==> characterize (theorem vs example)"
python3 spec/characterize.py

echo
echo "==> conformance (properties + fixtures)"
python3 spec/conformance.py

if ((lean)); then
  if ! command -v lake >/dev/null; then
    echo "eval-spec: lake not on PATH (install elan / nb i elan-init)" >&2
    exit 1
  fi
  echo
  echo "==> lake build + graff-spec-report"
  (cd lean-proofs && lake build && lake exe graff-spec-report)
fi

if ((impl)); then
  echo
  echo "==> zig test spec/"
  zig build test --summary none -Dtest-filter="spec/"
fi
