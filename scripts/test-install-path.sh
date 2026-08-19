#!/usr/bin/env bash
# Prove install.sh persists ~/bin (or HARNESS_DIR) onto the login shell PATH
# so a new terminal finds `graff` without a pasted export.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Login zsh: create ~/.zshrc and append PATH.
home1="$tmp/zsh"
mkdir -p "$home1/bin"
HOME="$home1" SHELL=/bin/zsh HARNESS_DIR="$home1/bin" bash "$INSTALLER" --path-only >/dev/null
grep -F 'codegraff PATH (install.sh) — do not duplicate' "$home1/.zshrc" >/dev/null || fail "zshrc missing marker"
grep -F "$home1/bin" "$home1/.zshrc" >/dev/null || fail "zshrc missing install dir"

# Idempotent: a second run does not duplicate the block.
HOME="$home1" SHELL=/bin/zsh HARNESS_DIR="$home1/bin" bash "$INSTALLER" --path-only >/dev/null
test "$(grep -c 'codegraff PATH (install.sh)' "$home1/.zshrc")" = 1 || fail "zshrc duplicated PATH block"

# curl|sh often runs under bash while the login shell is zsh — update both
# when ~/.zshrc already exists.
home2="$tmp/both"
mkdir -p "$home2"
printf '# existing zsh\n' > "$home2/.zshrc"
printf '# existing bash\n' > "$home2/.bashrc"
HOME="$home2" SHELL=/bin/bash HARNESS_DIR="$home2/bin" bash "$INSTALLER" --path-only >/dev/null
grep -F "$home2/bin" "$home2/.bashrc" >/dev/null || fail "bashrc missing install dir"
grep -F "$home2/bin" "$home2/.zshrc" >/dev/null || fail "existing zshrc not updated from bash installer"

# Opt-out.
home3="$tmp/skip"
mkdir -p "$home3"
HOME="$home3" SHELL=/bin/zsh HARNESS_NO_PATH=1 HARNESS_DIR="$home3/bin" bash "$INSTALLER" --path-only >/dev/null
test ! -e "$home3/.zshrc" || fail "HARNESS_NO_PATH still wrote zshrc"

# fish.
home4="$tmp/fish"
mkdir -p "$home4"
HOME="$home4" SHELL=/usr/bin/fish HARNESS_DIR="$home4/bin" bash "$INSTALLER" --path-only >/dev/null
grep -F 'fish_add_path' "$home4/.config/fish/config.fish" >/dev/null || fail "fish config missing fish_add_path"

printf 'ok\n'
