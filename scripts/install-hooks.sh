#!/usr/bin/env bash
# Point git at the tracked hooks in .githooks/. One line, reversible, and it
# survives clones of this repo because the hooks are versioned with the code.
#
#   scripts/install-hooks.sh            install
#   scripts/install-hooks.sh --uninstall  go back to .git/hooks
set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)
cd "$repo_root"

if [[ "${1:-}" == "--uninstall" ]]; then
  git config --unset core.hooksPath || true
  printf 'hooks: uninstalled (core.hooksPath cleared, .git/hooks is live again)\n'
  exit 0
fi

git config core.hooksPath .githooks
chmod +x .githooks/* scripts/pre-push.sh scripts/eval-tier1.sh 2>/dev/null || true

cat <<'EOF'
hooks: installed - core.hooksPath now points at .githooks/

  pre-push  runs tier 1 of the internal eval set: zig fmt, the 600-line
            ceiling, test reachability, the unit suite and its count ratchet,
            the named goal/loop/todo invariants, and SDK drift. Offline, no
            model calls, ~20-30s warm. Doc-only pushes skip it entirely.

  skip once     git push --no-verify
                GRAFF_SKIP_PREPUSH=1 git push
  run by hand   scripts/eval-tier1.sh
  one check     scripts/eval-tier1.sh --only sdk
  uninstall     scripts/install-hooks.sh --uninstall

Note: setting core.hooksPath replaces .git/hooks wholesale. If you kept local
hooks there, copy them into .githooks/ first.
EOF
