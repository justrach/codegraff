#!/usr/bin/env bash
set -euo pipefail

# graff-harness installer. Prefers a prebuilt binary from the latest GitHub
# release; falls back to building from source with Zig. Styled after the
# codedb/codegraff installers.
#
#   curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash
#   # or, from a checkout:  ./install.sh
#
# Env overrides: HARNESS_REPO (source repo), HARNESS_DIR (install dir),
# HARNESS_BUILD=source (skip the release download and compile),
# HARNESS_NO_GRAFF=1 (skip the codedb/zigrep companion suite),
# HARNESS_NO_PATH=1 (do not append the install dir to ~/.zshrc / ~/.bashrc).
#
# Desktop app too (macOS Apple Silicon): add --desktop, or GRAFF_DESKTOP=1.
#   curl -fsSL https://raw.githubusercontent.com/justrach/codegraff/main/install.sh | bash -s -- --desktop
# It installs Harness.app from the latest Harness release's app tarball,
# checked against that release's manifest.json, into /Applications (or
# ~/Applications). GRAFF_DESKTOP_DIR overrides the destination.

REPO="${HARNESS_REPO:-https://github.com/justrach/codegraff}"
INSTALL_DIR="${HARNESS_DIR:-$HOME/bin}"
BIN="graff"
ZIG_VERSION="0.17.0-dev.813+2153f8143"

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'

detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      printf "\n  ${W}harness installer${N}\n\n"
      printf "  ${Y}Windows detected${N} — run this inside ${G}WSL2${N} instead.\n\n"
      exit 0 ;;
    *) printf "  ${R}unsupported OS: $os${N}\n" >&2; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="x86_64" ;;
    *) printf "  ${R}unsupported arch: $arch${N}\n" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

need_zig() {
  if ! command -v zig >/dev/null 2>&1; then
    printf "\n  ${R}error: zig not found${N} — harness needs Zig $ZIG_VERSION.\n"
    printf "  install it with: ${C}zigup $ZIG_VERSION${N}\n\n" >&2
    exit 1
  fi
  local v; v="$(zig version 2>/dev/null || echo '?')"
  case "$v" in
    "$ZIG_VERSION") ;; # exact reproducible toolchain
    *) printf "  ${Y}warning:${N} zig $v detected; harness targets $ZIG_VERSION — run 'zigup $ZIG_VERSION'.\n" ;;
  esac
  printf "  ${D}zig${N}       $v\n"
}

# Apple Silicon SIGKILLs a binary whose signature no longer matches the
# kernel cache for that path. Leave a notarized Developer ID alone (re-signing
# strips the staple). Do NOT Developer-ID-sign a local zig build: unnotarized
# Developer ID + hardened runtime is `SIGKILL (Code Signature Invalid)` once
# --yolo pages in more than --version. Ad-hoc is the correct local signature.
darwin_sign() {
  [ "$(uname -s)" = Darwin ] || return 0
  local bin="$1"
  [ -f "$bin" ] || return 0
  if codesign --verify --strict "$bin" >/dev/null 2>&1 \
    && codesign -dv --verbose=2 "$bin" 2>&1 | grep -q 'Authority=Developer ID Application'; then
    return 0
  fi
  codesign -s - --force --identifier graff "$bin" >/dev/null 2>&1 || true
}

# Drop the binary onto a *fresh inode*: overwriting a running macOS binary in
# place gets the replacement SIGKILLed by the kernel's signature cache.
place_bin() {
  mkdir -p "$INSTALL_DIR"
  rm -f "$INSTALL_DIR/$BIN"
  install -m 0755 "$1" "$INSTALL_DIR/$BIN"
  darwin_sign "$INSTALL_DIR/$BIN"

  # Overwrite any *other* graff already on PATH (e.g. an older copy in
  # ~/.local/bin from the codegraff stack) so the binary we just installed
  # actually wins instead of being shadowed by a stale one earlier on PATH.
  # Fresh inode each time (rm then install) — same reason as above. Only
  # touch writable copies; never error on a protected/system path.
  oldifs="$IFS"; IFS=:
  for d in $PATH; do
    [ -n "$d" ] || continue
    [ "$d" = "$INSTALL_DIR" ] && continue
    if [ -f "$d/$BIN" ] && [ -w "$d/$BIN" ]; then
      if rm -f "$d/$BIN" && install -m 0755 "$1" "$d/$BIN" 2>/dev/null; then
        darwin_sign "$d/$BIN"
        printf "  ${D}│${N} %-10s ${G}✓${N} (overwrote stale $d/$BIN)\n" "replace"
      fi
    fi
  done
  IFS="$oldifs"
}

# Try the latest GitHub release for this platform. Plain curl is the fast path
# now that the repo is public; gh is only a fallback for private forks.
fetch_release() {
  local platform="$1" target asset tmpd
  case "$platform" in
    darwin-arm64)  target="aarch64-macos" ;;
    darwin-x86_64) target="x86_64-macos" ;;
    linux-arm64)   target="aarch64-linux" ;;
    linux-x86_64)  target="x86_64-linux" ;;
    *) return 1 ;;
  esac
  # graff-named assets first; harness-named for releases that predate the
  # rename (the tarball's inner dir/binary follow the asset name).
  local stem
  for stem in graff harness; do
    asset="$stem-$target.tar.gz"
    tmpd="$(mktemp -d)"
    # Public repo: plain curl is the fast path (no auth, and it can't hang the
    # way `gh release download` has been observed to on some machines). Fall
    # back to gh only if curl fails — e.g. a private fork — and gh is present.
    if curl -fsSL --max-time 60 "$REPO/releases/latest/download/$asset" -o "$tmpd/$asset" 2>/dev/null; then
      :
    elif command -v gh >/dev/null 2>&1 \
      && gh release download --repo "${REPO#https://github.com/}" --pattern "$asset" --dir "$tmpd" >/dev/null 2>&1; then
      :
    else
      rm -rf "$tmpd"; continue
    fi
    break
  done
  [ -f "$tmpd/$asset" ] || { rm -rf "$tmpd"; return 1; }
  tar -xzf "$tmpd/$asset" -C "$tmpd" 2>/dev/null || { rm -rf "$tmpd"; return 1; }
  # Locate the extracted binary. CI (release.yml) nests it under
  # graff-<target>/, but hand-repacked macOS tarballs (the local notarize
  # flow) ship it flat at the root. Handle both, then fall back to a search
  # so a future layout change can't silently break the install again.
  local binpath=""
  if [ -f "$tmpd/$stem" ]; then
    binpath="$tmpd/$stem"
  elif [ -f "$tmpd/$stem-$target/$stem" ]; then
    binpath="$tmpd/$stem-$target/$stem"
  else
    binpath="$(find "$tmpd" -type f -name "$stem" 2>/dev/null | head -1)"
  fi
  [ -n "$binpath" ] && [ -f "$binpath" ] || { rm -rf "$tmpd"; return 1; }
  place_bin "$binpath"
  rm -rf "$tmpd"
  # Fail closed: if the binary didn't actually land, return non-zero so the
  # caller falls back to a source build instead of falsely reporting success.
  # (set -e is suppressed inside the `if fetch_release` guard, so the install
  # error above does not abort on its own.)
  [ -x "$INSTALL_DIR/$BIN" ] || return 1
}

build_from_source() {
  local src tmp=""
  need_zig
  # Source: build in place if we're in the repo, else clone it.
  if [ -f build.zig ] && grep -qE '"(graff|harness)"' build.zig 2>/dev/null; then
    src="$(pwd)"
    printf "  ${D}│${N} %-10s ${G}✓${N} (current checkout)\n" "source"
  else
    command -v git >/dev/null 2>&1 || { printf "  ${R}error: git not found${N}\n" >&2; exit 1; }
    tmp="$(mktemp -d)"; src="$tmp/codegraff"
    printf "  ${D}│${N} %-10s " "clone"
    git clone --depth 1 "$REPO" "$src" >/dev/null 2>&1 \
      && printf "${G}✓${N}\n" \
      || { printf "${R}failed${N}\n\n  ${R}could not clone $REPO${N} (private repo — check your GitHub access)\n\n" >&2; exit 1; }
  fi

  printf "  ${D}│${N} %-10s " "build"
  ( cd "$src" && zig build -Doptimize=ReleaseFast ) >/dev/null 2>&1 \
    && printf "${G}✓${N}\n" \
    || { printf "${R}failed${N}\n\n  ${R}zig build failed${N} — run it manually in $src to see the error\n\n" >&2; exit 1; }

  # post-rename checkouts build zig-out/bin/graff; older ones harness
  if [ -f "$src/zig-out/bin/graff" ]; then
    place_bin "$src/zig-out/bin/graff"
  else
    place_bin "$src/zig-out/bin/harness"
  fi
  [ -n "$tmp" ] && rm -rf "$tmp"
}

main() {
  local platform
  platform="$(detect_platform)"

  printf "\n  ${W}graff-harness${N} ${D}installer${N}\n\n"
  printf "  ${D}platform${N}  $platform\n"
  printf "  ${D}install${N}   $INSTALL_DIR\n\n"

  # Kick off the companion suite install in the background so it downloads in
  # parallel with the graff binary below — it's the slow part (a full curl|sh of
  # codedb-pro + the zigrep/zigread/zigpatch suite). Reaped before the summary.
  # Empty suite_pid = already present or opted out (HARNESS_NO_GRAFF) → nothing to wait on.
  # Tools installer = codegraff.com/install.sh; --max-time bounds it; override via GRAFF_SUITE_URL.
  GRAFF_SUITE_URL="${GRAFF_SUITE_URL:-https://codegraff.com/install.sh}"
  suite_pid=""; suite_log=""
  if [ -z "${HARNESS_NO_GRAFF:-}" ] && ! { command -v codedb-pro >/dev/null 2>&1 && command -v zigpatch >/dev/null 2>&1; }; then
    suite_log="$(mktemp)"
    ( curl -fsSL --max-time 120 "$GRAFF_SUITE_URL" | sh >/dev/null 2>&1 && echo ok || echo fail ) >"$suite_log" 2>&1 &
    suite_pid=$!
  fi

  if [ "${HARNESS_BUILD:-release}" != "source" ] && fetch_release "$platform"; then
    printf "  ${D}│${N} %-10s ${G}✓${N} (prebuilt release)\n" "download"
  else
    build_from_source
  fi

  printf "  ${D}│${N} %-10s ${G}✓${N}\n\n" "install"
  printf "  ${G}installed${N} ${D}→ $INSTALL_DIR/$BIN${N}\n"
  # Compat: the command used to be `harness` — the SDKs' fallback and old
  # shell habits keep working through a symlink.
  ln -sf "$INSTALL_DIR/$BIN" "$INSTALL_DIR/harness"

  # Reap the companion suite install that was kicked off in parallel at the top
  # of main() (muonry, zigrep/zigread/zigpatch, codedb — they back the @ picker,
  # the codedb tool, and zigpatch's atomic edit_file splices; the harness works
  # fully without it, premium paths just stay dormant). Skip with HARNESS_NO_GRAFF=1.
  if [ -z "${HARNESS_NO_GRAFF:-}" ]; then
    printf "  ${D}│${N} %-10s " "suite"
    if [ -z "$suite_pid" ]; then
      printf "${G}✓${N} (already present)\n"
    else
      wait "$suite_pid" 2>/dev/null || true
      if [ "$(cat "$suite_log" 2>/dev/null)" = ok ]; then
        printf "${G}✓${N} (muonry + zigrep suite)\n"
      else
        printf "${Y}skipped${N} ${D}(companion install unavailable — harness still fully functional)${N}\n"
      fi
      rm -f "$suite_log"
    fi
  fi

  ensure_path
  if [ "${GRAFF_NO_MCP:-}" != "1" ]; then
    "$INSTALL_DIR/$BIN" mcp install || printf 'MCP setup incomplete. Retry with: graff mcp install\n' >&2
  fi

  if [ -n "${GRAFF_DESKTOP:-}" ]; then
    install_desktop || true
    printf "\n  ${W}done!${N} run ${C}$BIN${N} in a terminal, or open ${C}Harness${N} from Applications\n\n"
    return 0
  fi
  if [ "$(uname -s)" = Darwin ]; then
    printf "\n  ${D}desktop app: re-run with${N} ${C}bash -s -- --desktop${N} ${D}to install Harness too${N}\n"
  fi
  printf "\n  ${W}done!${N} run ${C}$BIN${N} to start, or ${C}$BIN --help${N}\n\n"
}

DESKTOP_REPO="${GRAFF_DESKTOP_REPO:-https://github.com/justrach/harness}"

# Install the desktop app (Harness) without a DMG: the release publishes the
# signed, notarized app as a tarball plus a manifest of SHA-256 sums.
install_desktop() {
  if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf "  ${D}│${N} %-10s ${Y}skipped${N} ${D}(one-line desktop install is macOS Apple Silicon only — see $DESKTOP_REPO/releases)${N}\n" "desktop"
    return 0
  fi
  local tmpd name sum got dest
  tmpd="$(mktemp -d)"
  printf "  ${D}│${N} %-10s " "desktop"
  if ! curl -fsSL --max-time 60 "$DESKTOP_REPO/releases/latest/download/manifest.json" -o "$tmpd/manifest.json"; then
    printf "${R}failed${N} ${D}(could not fetch the Harness release manifest)${N}\n"; rm -rf "$tmpd"; return 1
  fi
  name="$(grep -oE '"harness-[0-9.]+-macos-arm64-app\.tar\.gz"' "$tmpd/manifest.json" | head -1 | tr -d '"')"
  sum="$(sed -n "/\"$name\"/,/sha256/p" "$tmpd/manifest.json" | grep -oE '[0-9a-f]{64}' | head -1)"
  if [ -z "$name" ] || [ -z "$sum" ]; then
    printf "${R}failed${N} ${D}(no macOS app tarball in the release manifest)${N}\n"; rm -rf "$tmpd"; return 1
  fi
  if ! curl -fsSL --max-time 300 "$DESKTOP_REPO/releases/latest/download/$name" -o "$tmpd/$name"; then
    printf "${R}failed${N} ${D}(download of $name)${N}\n"; rm -rf "$tmpd"; return 1
  fi
  got="$(shasum -a 256 "$tmpd/$name" | cut -c1-64)"
  if [ "$got" != "$sum" ]; then
    printf "${R}failed${N} ${D}(checksum mismatch for $name — not installed)${N}\n"; rm -rf "$tmpd"; return 1
  fi
  tar -xzf "$tmpd/$name" -C "$tmpd" && [ -d "$tmpd/Harness.app" ] \
    && codesign --verify --deep --strict "$tmpd/Harness.app" >/dev/null 2>&1 || {
    printf "${R}failed${N} ${D}(the app did not unpack with a valid signature — not installed)${N}\n"; rm -rf "$tmpd"; return 1
  }
  dest="${GRAFF_DESKTOP_DIR:-/Applications}"
  if [ -z "${GRAFF_DESKTOP_DIR:-}" ] && [ ! -w "$dest" ]; then dest="$HOME/Applications"; fi
  mkdir -p "$dest"
  rm -rf "$dest/Harness.app"
  ditto "$tmpd/Harness.app" "$dest/Harness.app"
  rm -rf "$tmpd"
  printf "${G}✓${N} ${D}(Harness ${name#harness-} → $dest/Harness.app)${N}\n" | sed 's/-macos-arm64-app.tar.gz//'
  if pgrep -x Harness >/dev/null 2>&1; then
    printf "  ${Y}Harness is running${N} — quit and reopen it to use the new version.\n"
  fi
}

# Persist $INSTALL_DIR on PATH so the next terminal finds `graff`.
# curl|sh often runs under bash while the login shell is zsh (macOS default),
# which is why people saw "graff: command not found" after a successful
# install — we only printed an export they never pasted. Write every rc that
# exists, and create ~/.zshrc / ~/.bashrc when that is the login shell.
# HARNESS_NO_PATH=1 skips. Idempotent via the marker comment.
ensure_path() {
  if [ -n "${HARNESS_NO_PATH:-}" ]; then
    printf "  ${D}PATH skipped (HARNESS_NO_PATH)${N}\n"
    return 0
  fi
  if [ -z "${HOME:-}" ]; then
    printf "  ${Y}HOME unset — could not persist PATH${N}\n"
    return 0
  fi

  local marker="# codegraff PATH (install.sh) — do not duplicate"
  local export_line="export PATH=\"${INSTALL_DIR}:\$PATH\""
  local fish_line="fish_add_path -m \"${INSTALL_DIR}\""
  local wrote=0
  local shell_name zshrc bashrc profile fishrc
  shell_name="$(basename "${SHELL:-sh}")"
  zshrc="${ZDOTDIR:-$HOME}/.zshrc"
  bashrc="$HOME/.bashrc"
  profile="$HOME/.profile"
  fishrc="$HOME/.config/fish/config.fish"

  append_rc() {
    local file="$1"
    local payload="$2"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
    if [ -f "$file" ] && grep -F "$marker" "$file" >/dev/null 2>&1; then
      return 0
    fi
    if ! printf "\n%s\n%s\n" "$marker" "$payload" >> "$file" 2>/dev/null; then
      return 0
    fi
    wrote=1
    printf "  ${D}│${N} %-10s ${G}✓${N} (PATH → %s)\n" "PATH" "$file"
  }

  case "$shell_name" in
    zsh)
      touch "$zshrc" 2>/dev/null || true
      append_rc "$zshrc" "$export_line"
      ;;
    bash)
      touch "$bashrc" 2>/dev/null || true
      append_rc "$bashrc" "$export_line"
      ;;
    fish)
      mkdir -p "$(dirname "$fishrc")" 2>/dev/null || true
      touch "$fishrc" 2>/dev/null || true
      append_rc "$fishrc" "$fish_line"
      ;;
    *)
      touch "$profile" 2>/dev/null || true
      append_rc "$profile" "$export_line"
      ;;
  esac

  if [ "$shell_name" != zsh ] && [ -f "$zshrc" ]; then
    append_rc "$zshrc" "$export_line"
  fi
  if [ "$shell_name" != bash ] && [ -f "$bashrc" ]; then
    append_rc "$bashrc" "$export_line"
  fi

  if [ "$wrote" = 1 ]; then
    printf "\n  ${Y}open a new terminal${N} or ${C}source${N} the rc file above — otherwise ${C}$BIN${N} is not on PATH yet.\n"
  else
    case ":$PATH:" in
      *":$INSTALL_DIR:"*) ;;
      *)
        printf "\n  ${Y}add to PATH:${N}\n"
        printf "  ${C}export PATH=\"$INSTALL_DIR:\$PATH\"${N}  ${D}(add to ~/.zshrc or ~/.bashrc)${N}\n"
        ;;
    esac
  fi
}

for arg in "$@"; do
  case "$arg" in
    --desktop) GRAFF_DESKTOP=1 ;;
  esac
done

if [ "${1:-}" = "--path-only" ]; then
  ensure_path
  exit 0
fi

main
