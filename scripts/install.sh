#!/bin/sh
# POSIX sh installer for CodeGraff and Forge.
# Usage:
#   curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh
# Optional:
#   sh install.sh v1.2.3
#   INSTALL_DIR="$HOME/.local/bin" sh install.sh

set -e

unset GREP_OPTIONS

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

REPO="${CODEGRAFF_REPO:-justrach/codegraff}"
VERSION="${1:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
TMP_DIR=""
DOWNLOADER=""

printf "${BLUE}Installing CodeGraff, Forge, and dependencies...${NC}\n"

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  printf "${RED}Error: curl or wget is required.${NC}\n" >&2
  exit 1
fi

download_file() {
  download_url="$1"
  download_output="$2"

  if [ "$DOWNLOADER" = "curl" ]; then
    if curl -fsSL -o "$download_output" "$download_url"; then
      return 0
    fi
    sleep 1
    curl -fsSL --http1.1 -o "$download_output" "$download_url"
  else
    wget -q -O "$download_output" "$download_url"
  fi
}

get_latest_version() {
  release_repo="$1"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL "https://api.github.com/repos/$release_repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
  else
    wget -qO- "https://api.github.com/repos/$release_repo/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
  fi
}

version_less_than() {
  _v1="${1#v}"; _v1="${_v1%%+*}"; _v1="${_v1%%-*}"
  _v2="${2#v}"; _v2="${_v2%%+*}"; _v2="${_v2%%-*}"

  IFS=. read -r _v1_major _v1_minor _v1_patch <<EOF
$_v1
EOF
  IFS=. read -r _v2_major _v2_minor _v2_patch <<EOF
$_v2
EOF

  _v1_major=${_v1_major:-0}; _v1_minor=${_v1_minor:-0}; _v1_patch=${_v1_patch:-0}
  _v2_major=${_v2_major:-0}; _v2_minor=${_v2_minor:-0}; _v2_patch=${_v2_patch:-0}

  if [ "$_v1_major" -lt "$_v2_major" ]; then return 0; fi
  if [ "$_v1_major" -gt "$_v2_major" ]; then return 1; fi
  if [ "$_v1_minor" -lt "$_v2_minor" ]; then return 0; fi
  if [ "$_v1_minor" -gt "$_v2_minor" ]; then return 1; fi
  if [ "$_v1_patch" -lt "$_v2_patch" ]; then return 0; fi
  return 1
}

prepend_to_path() {
  path_dir="$1"
  case ":$PATH:" in
    *":$path_dir:"*) ;;
    *) export PATH="$path_dir:$PATH" ;;
  esac
}

ensure_install_dir_shell_path() {
  export_line="export PATH=\"$INSTALL_DIR:\$PATH\""
  marker="# Added by CodeGraff installer"

  for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc_file" ]; then
      temp_rc=$(mktemp)
      grep -vF "$marker" "$rc_file" | grep -vF "$export_line" > "$temp_rc" || true
      {
        printf '%s\n' "$marker"
        printf '%s\n' "$export_line"
        cat "$temp_rc"
      } > "$temp_rc.new"
      mv "$temp_rc.new" "$rc_file"
      rm -f "$temp_rc"
    else
      {
        printf '%s\n' "$marker"
        printf '%s\n' "$export_line"
      } > "$rc_file"
    fi
  done
}

is_android() {
  if [ -n "${PREFIX:-}" ] && echo "$PREFIX" | grep -q "com.termux"; then return 0; fi
  if [ -n "${ANDROID_ROOT:-}" ] || [ -n "${ANDROID_DATA:-}" ]; then return 0; fi
  if [ -f "/system/build.prop" ]; then return 0; fi
  if command -v getprop >/dev/null 2>&1 && getprop ro.build.version.release >/dev/null 2>&1; then return 0; fi
  return 1
}

get_libc_info() {
  if [ -f "/lib/libc.musl-x86_64.so.1" ] || [ -f "/lib/libc.musl-aarch64.so.1" ]; then
    echo "musl"
    return
  fi

  libc_ls_binary=$(command -v ls 2>/dev/null || echo "/bin/ls")
  if command -v ldd >/dev/null 2>&1; then
    if ldd "$libc_ls_binary" 2>&1 | grep -q musl; then
      echo "musl"
      return
    fi

    libc_ldd_output=$(ldd --version 2>&1 | head -n 1 || true)
    if echo "$libc_ldd_output" | grep -qiF "musl"; then
      echo "musl"
      return
    fi

    libc_version=$(echo "$libc_ldd_output" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    if [ -z "$libc_version" ] && command -v getconf >/dev/null 2>&1; then
      libc_getconf_output=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
      libc_version=$(echo "$libc_getconf_output" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
    fi

    if [ -n "$libc_version" ]; then
      libc_major=$(echo "$libc_version" | cut -d. -f1)
      libc_minor=$(echo "$libc_version" | cut -d. -f2)
      libc_version_num=$((libc_major * 100 + libc_minor))
      if [ "$libc_version_num" -ge 239 ]; then
        echo "gnu"
      else
        echo "musl"
      fi
      return
    fi
  fi

  echo "gnu"
}

get_fzf_version() {
  fzf_cmd="${1:-}"
  if [ -n "$fzf_cmd" ] && [ -x "$fzf_cmd" ]; then
    "$fzf_cmd" --version 2>/dev/null | cut -d' ' -f1
  elif command -v fzf >/dev/null 2>&1; then
    fzf --version 2>/dev/null | cut -d' ' -f1
  fi
}

install_fzf() {
  existing_version=$(get_fzf_version)

  if echo "$OS" | grep -qE 'msys|mingw|cygwin|windows'; then
    fzf_binary="fzf.exe"
  else
    fzf_binary="fzf"
  fi

  managed_fzf_path="$INSTALL_DIR/$fzf_binary"
  managed_version=$(get_fzf_version "$managed_fzf_path")

  if [ -n "$managed_version" ] && ! version_less_than "$managed_version" "0.48.0"; then
    prepend_to_path "$INSTALL_DIR"
    printf "${GREEN}✓ fzf %s is already installed.${NC}\n" "$managed_version"
    return 0
  fi

  if [ -n "$existing_version" ] && ! version_less_than "$existing_version" "0.48.0"; then
    printf "${GREEN}✓ fzf %s is already installed.${NC}\n" "$existing_version"
    return 0
  fi

  printf "${BLUE}Installing fzf...${NC}\n"
  fzf_version=$(get_latest_version "junegunn/fzf")
  if [ -z "$fzf_version" ]; then
    printf "${YELLOW}Warning: could not determine latest fzf version; skipping.${NC}\n"
    return 1
  fi
  fzf_version="${fzf_version#v}"

  if [ "$OS" = "darwin" ]; then
    if [ "$ARCH" = "aarch64" ]; then
      fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-darwin_arm64.tar.gz"
    else
      fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-darwin_amd64.tar.gz"
    fi
  elif [ "$OS" = "linux" ]; then
    if is_android; then
      fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-android_arm64.tar.gz"
    elif [ "$ARCH" = "aarch64" ]; then
      fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-linux_arm64.tar.gz"
    else
      fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-linux_amd64.tar.gz"
    fi
  elif echo "$OS" | grep -qE 'msys|mingw|cygwin|windows'; then
    fzf_url="https://github.com/junegunn/fzf/releases/download/v${fzf_version}/fzf-${fzf_version}-windows_amd64.zip"
  else
    printf "${YELLOW}Warning: fzf is not supported on %s; skipping.${NC}\n" "$OS"
    return 1
  fi

  fzf_temp="$TMP_DIR/fzf-${fzf_version}"
  mkdir -p "$fzf_temp"

  if ! download_file "$fzf_url" "$fzf_temp/fzf_archive"; then
    printf "${YELLOW}Warning: failed to download fzf; skipping.${NC}\n"
    return 1
  fi

  if echo "$fzf_url" | grep -q '\.zip$'; then
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$fzf_temp/fzf_archive" -d "$fzf_temp"
    else
      printf "${YELLOW}Warning: unzip is required to install fzf on this platform.${NC}\n"
      return 1
    fi
  else
    tar -xzf "$fzf_temp/fzf_archive" -C "$fzf_temp"
  fi

  if [ -f "$fzf_temp/$fzf_binary" ]; then
    cp "$fzf_temp/$fzf_binary" "$managed_fzf_path"
  elif [ -f "$fzf_temp/fzf" ]; then
    cp "$fzf_temp/fzf" "$managed_fzf_path"
  else
    printf "${YELLOW}Warning: could not find fzf in downloaded archive.${NC}\n"
    return 1
  fi

  chmod +x "$managed_fzf_path"
  prepend_to_path "$INSTALL_DIR"
  installed_fzf_version=$(get_fzf_version "$managed_fzf_path")
  printf "${GREEN}✓ fzf %s installed.${NC}\n" "$installed_fzf_version"
}

install_codedb() {
  if command -v codedb >/dev/null 2>&1; then
    codedb_version=$(codedb --version 2>/dev/null || true)
    if [ -n "$codedb_version" ]; then
      printf "${GREEN}✓ codedb is already installed (%s)${NC}\n" "$codedb_version"
    else
      printf "${GREEN}✓ codedb is already installed${NC}\n"
    fi
    return 0
  fi

  if [ -x "$INSTALL_DIR/codedb" ]; then
    printf "${GREEN}✓ codedb is already installed at %s${NC}\n" "$INSTALL_DIR/codedb"
    prepend_to_path "$INSTALL_DIR"
    return 0
  fi

  if echo "$OS" | grep -qE 'msys|mingw|cygwin|windows'; then
    printf "${YELLOW}Warning: CodeDB install is currently Linux/macOS only. Use WSL2 on Windows.${NC}\n"
    return 0
  fi

  if ! command -v bash >/dev/null 2>&1; then
    printf "${YELLOW}Warning: bash is required for the CodeDB installer; skipping.${NC}\n"
    return 1
  fi

  printf "${BLUE}Installing CodeDB...${NC}\n"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -fsSL https://codedb.codegraff.com/install.sh | CODEDB_DIR="$INSTALL_DIR" bash
  else
    wget -qO- https://codedb.codegraff.com/install.sh | CODEDB_DIR="$INSTALL_DIR" bash
  fi
  prepend_to_path "$INSTALL_DIR"
}

install_release_binary() {
  tool="$1"
  binary_name="$2"
  asset_name="$3"
  temp_binary="$TMP_DIR/$binary_name"

  if [ "$VERSION" = "latest" ]; then
    download_urls="https://github.com/$REPO/releases/latest/download/$asset_name"
  else
    download_urls="https://github.com/$REPO/releases/download/$VERSION/$asset_name"
    case "$VERSION" in
      v*) ;;
      *) download_urls="$download_urls https://github.com/$REPO/releases/download/v$VERSION/$asset_name" ;;
    esac
  fi

  download_success=false
  for download_url in $download_urls; do
    printf "${BLUE}Downloading %s from %s...${NC}\n" "$tool" "$download_url"
    if download_file "$download_url" "$temp_binary"; then
      download_success=true
      break
    fi
  done

  if [ "$download_success" != "true" ]; then
    printf "${RED}Error: failed to download %s asset %s.${NC}\n" "$tool" "$asset_name" >&2
    return 1
  fi

  install_path="$INSTALL_DIR/$binary_name"
  mv "$temp_binary" "$install_path"
  chmod +x "$install_path"
  xattr -c "$install_path" 2>/dev/null || true
  printf "${GREEN}✓ %s installed to %s${NC}\n" "$tool" "$install_path"
}

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|x64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *)
    printf "${RED}Unsupported architecture: %s${NC}\n" "$ARCH" >&2
    exit 1
    ;;
esac

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
  linux)
    if is_android; then
      TARGET="$ARCH-linux-android"
    else
      LIBC_TYPE=$(get_libc_info)
      TARGET="$ARCH-unknown-linux-$LIBC_TYPE"
    fi
    TARGET_EXT=""
    FORGE_BINARY="graff"
    CODEGRAFF_BINARY="codegraff"
    ;;
  darwin)
    TARGET="$ARCH-apple-darwin"
    TARGET_EXT=""
    FORGE_BINARY="graff"
    CODEGRAFF_BINARY="codegraff"
    ;;
  msys*|mingw*|cygwin*|windows*)
    TARGET="$ARCH-pc-windows-msvc"
    TARGET_EXT=".exe"
    FORGE_BINARY="graff.exe"
    CODEGRAFF_BINARY="codegraff.exe"
    ;;
  *)
    printf "${RED}Unsupported operating system: %s${NC}\n" "$OS" >&2
    exit 1
    ;;
esac

printf "${BLUE}Detected platform: %s${NC}\n" "$TARGET"
mkdir -p "$INSTALL_DIR"
prepend_to_path "$INSTALL_DIR"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

install_release_binary "Graff" "$FORGE_BINARY" "graff-$TARGET$TARGET_EXT"
if [ "$TARGET" = "aarch64-linux-android" ]; then
  printf "${YELLOW}Warning: CodeGraff TUI release is not published for Android yet; skipping.${NC}\n"
else
  install_release_binary "CodeGraff" "$CODEGRAFF_BINARY" "codegraff-$TARGET$TARGET_EXT"
fi

ensure_install_dir_shell_path

printf "\n${BLUE}Installing dependencies...${NC}\n"
install_fzf || true
install_codedb || true

printf "\n${GREEN}Installation complete!${NC}\n"
printf "${BLUE}Tools installed: forge, codegraff, fzf, codedb${NC}\n"
printf "${YELLOW}Open a new terminal or restart your shell if commands are not immediately visible.${NC}\n"
