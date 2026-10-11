#!/bin/bash
# Install the command-line tools these configs expect, or update them to their
# latest release. Each tool is unpacked under ${XDG_DATA_HOME:-~/.local/share}
# and linked into ~/.local/bin; the Codex fork goes under ~/.local/opt, nvm in
# ${NVM_DIR:-~/.nvm}, and Claude Code and Cursor where their installers put them.
# Safe to rerun: a tool already at its latest release isn't downloaded again.
# Shell startup files are never edited. Old copies elsewhere are left in place
# and listed at the end. Runs on Linux x86_64 and macOS arm64, under bash 3.2+.

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=linux triple=x86_64-unknown-linux-musl ;;
  Darwin/arm64) os=macos triple=aarch64-apple-darwin ;;
  *)
    echo "Unsupported platform: $(uname -s) $(uname -m). Only Linux x86_64 and macOS arm64 are supported." >&2
    exit 1
    ;;
esac

BIN=$HOME/.local/bin
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
export NVM_DIR=${NVM_DIR:-$HOME/.nvm}
BACKUP=${XDG_STATE_HOME:-$HOME/.local/state}/configs/tool-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
USER_PATH=$PATH
export PATH="$BIN:$PATH"
mkdir -p "$BIN" "$DATA" || exit 1
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

# Print the tag of a GitHub repo's latest release, read from the redirect of
# /releases/latest so it doesn't count against the API rate limit.
latest_tag() {
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest") || url=
  case $url in
    */releases/tag/?*) echo "${url##*/releases/tag/}" ;;
    *) fail "Could not find the latest release of $1" ;;
  esac
}

# Check FILE against its line in SUMS (or SUMS' only hash).
check_sha256() {
  want=$(awk -v f="${1##*/}" '{ sub(/\r$/, "") } NF == 1 || $2 == f || $2 == "*" f { print $1; exit }' "$2")
  if [ $os = macos ]; then got=$(shasum -a 256 "$1"); else got=$(sha256sum "$1"); fi
  [ -n "$want" ] && [ "${got%% *}" = "$want" ] || fail "Checksum mismatch for ${1##*/}"
}

# Move a real file at ~/.local/bin/NAME into the backup directory so a link
# can take its place. Symlinks are simply replaced.
set_aside() {
  if [ -e "$BIN/$1" ] && [ ! -L "$BIN/$1" ]; then
    mkdir -p "$BACKUP"
    mv "$BIN/$1" "$BACKUP/$1"
    echo "Moved the file $BIN/$1 to $BACKUP/"
    echo "$BACKUP/$1" >> "$TMP/moved"
  fi
}

# Link TARGET as ~/.local/bin/NAME.
link() {
  [ "$(readlink "$BIN/$2")" = "$1" ] && return
  set_aside "$2"
  ln -sfn "$1" "$BIN/$2"
}

# Is ~/.local/bin/NAME a link into DIR?
ours() {
  case $(readlink "$BIN/$1" 2>/dev/null) in "$2"/*) return 0 ;; esac
  return 1
}

# release_install REPO TAG ASSET SUMS DEST STRIP NAME=PATH...
# Unpack ASSET from REPO's release TAG as the directory DEST, unless DEST already
# holds TAG. SUMS is the release's checksum file, or "" if it publishes none.
# STRIP=1 drops the archive's top-level folder. Each NAME=PATH links DEST/PATH
# into ~/.local/bin. The new copy is unpacked next to DEST and swapped in, so
# no files from the old version linger.
release_install() {
  repo=$1 tag=$2 asset=$3 sums=$4 dest=$5 strip=$6
  shift 6
  current=no
  [ "$(cat "$dest/.release-tag" 2>/dev/null)" = "$tag" ] && current=yes
  for pair in "$@"; do [ -x "$dest/${pair#*=}" ] || current=no; done

  if [ $current = yes ]; then
    echo "$repo $tag is already installed"
  else
    echo "Installing $repo $tag into $dest"
    # A DEST this script didn't create is kept as DEST.orig.
    if [ -e "$dest" ] && [ ! -e "$dest/.release-tag" ] && [ -e "$dest.orig" ]; then
      fail "$dest wasn't installed by this script and $dest.orig is taken; move one of them away"
    fi
    url=https://github.com/$repo/releases/download/$tag
    curl -fsSL -o "$TMP/$asset" "$url/$asset"
    if [ -n "$sums" ]; then
      curl -fsSL -o "$TMP/$sums" "$url/$sums"
      check_sha256 "$TMP/$asset" "$TMP/$sums"
    fi
    rm -rf "$dest.new"
    mkdir -p "$dest.new"
    case $asset in
      *.zip) unzip -q "$TMP/$asset" -d "$dest.new" ;;
      *) tar -xzf "$TMP/$asset" -C "$dest.new" ;;
    esac
    rm -f "$TMP/$asset"
    src=$dest.new
    [ "$strip" = 1 ] && src=$(echo "$dest.new"/*)
    [ -d "$src" ] || fail "Unexpected layout in $asset"
    for pair in "$@"; do
      [ -f "$src/${pair#*=}" ] || fail "$asset has no ${pair#*=}"
      chmod +x "$src/${pair#*=}"
    done
    echo "$tag" > "$src/.release-tag"

    if [ -e "$dest" ] && [ ! -e "$dest/.release-tag" ]; then
      mv "$dest" "$dest.orig"
      echo "Moved the existing $dest to $dest.orig"
      echo "$dest.orig" >> "$TMP/moved"
    fi
    rm -rf "$dest.old"
    if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
    mv "$src" "$dest"
    rm -rf "$dest.old" "$dest.new"
  fi
  for pair in "$@"; do link "$dest/${pair#*=}" "${pair%%=*}"; done
}

install_neovim() {
  # Not $DATA/nvim, which holds Neovim's plugins and state.
  if [ $os = linux ]; then asset=nvim-linux-x86_64.tar.gz; else asset=nvim-macos-arm64.tar.gz; fi
  tag=$(latest_tag neovim/neovim)
  release_install neovim/neovim "$tag" "$asset" "" "$DATA/neovim" 1 nvim=bin/nvim
}

install_codex() {
  # The fork has no macOS build, so the Mac gets upstream's full package.
  if [ $os = linux ]; then
    tag=$(latest_tag ejarmand/codex)
    release_install ejarmand/codex "$tag" codex-fork-x86_64-linux.tar.gz "" \
      "$HOME/.local/opt/codex-fork/current" 0 codex=codex
  else
    tag=$(latest_tag openai/codex)
    release_install openai/codex "$tag" codex-package-aarch64-apple-darwin.tar.gz codex-package_SHA256SUMS \
      "$DATA/codex" 0 codex=bin/codex
  fi
}

install_opencode() {
  # $DATA/opencode is opencode's own data (sessions, auth, and bin/ for the
  # language servers it downloads), so the binary gets cli/. The baseline
  # build is for CPUs without AVX2. The repo moved from sst/opencode.
  if [ $os = macos ]; then asset=opencode-darwin-arm64.zip
  elif grep -qw avx2 /proc/cpuinfo; then asset=opencode-linux-x64.tar.gz
  else asset=opencode-linux-x64-baseline.tar.gz
  fi
  tag=$(latest_tag anomalyco/opencode)
  release_install anomalyco/opencode "$tag" "$asset" "" "$DATA/opencode/cli" 0 opencode=opencode
}

install_starship() {
  tag=$(latest_tag starship/starship)
  asset=starship-$triple.tar.gz
  release_install starship/starship "$tag" "$asset" "$asset.sha256" "$DATA/starship" 0 starship=starship
}

install_pixi() {
  # Tools from `pixi global` stay in ${PIXI_HOME:-~/.pixi}/bin; only pixi moves.
  tag=$(latest_tag prefix-dev/pixi)
  asset=pixi-$triple.tar.gz
  release_install prefix-dev/pixi "$tag" "$asset" "$asset.sha256" "$DATA/pixi" 0 pixi=pixi
}

install_uv() {
  # $DATA/uv holds uv's tools and Pythons, so the binaries get bin/.
  tag=$(latest_tag astral-sh/uv)
  asset=uv-$triple.tar.gz
  release_install astral-sh/uv "$tag" "$asset" "$asset.sha256" "$DATA/uv/bin" 1 uv=uv uvx=uvx
}

install_node() {
  # nvm.sh breaks under set -e (and set -u), so errors are checked by hand here.
  set +e
  tag=$(latest_tag nvm-sh/nvm) || exit 1
  # shellcheck source=/dev/null
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  if [ "$(nvm --version 2>/dev/null)" = "${tag#v}" ]; then
    echo "nvm $tag is already installed in $NVM_DIR"
  else
    echo "Installing nvm $tag into $NVM_DIR"
    mkdir -p "$NVM_DIR"
    curl -fsSL -o "$TMP/nvm-install.sh" "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh" \
      || fail "Could not download nvm's installer"
    # PROFILE=/dev/null keeps it from editing shell startup files.
    PROFILE=/dev/null bash "$TMP/nvm-install.sh" || fail "nvm's installer failed"
    # shellcheck source=/dev/null
    . "$NVM_DIR/nvm.sh"
    [ "$(nvm --version 2>/dev/null)" = "${tag#v}" ] || fail "nvm $tag didn't load from $NVM_DIR"
  fi
  nvm install --lts || fail "nvm install --lts failed"
  nvm alias default 'lts/*' || fail "Could not make LTS nvm's default"
}

install_rg() {
  # Use a ripgrep from elsewhere if there is one; otherwise install and update ours.
  if ours rg "$DATA/ripgrep" || ! command -v rg >/dev/null; then
    tag=$(latest_tag BurntSushi/ripgrep)
    asset=ripgrep-$tag-$triple.tar.gz
    release_install BurntSushi/ripgrep "$tag" "$asset" "$asset.sha256" "$DATA/ripgrep" 1 rg=rg
  else
    echo "Leaving rg alone: $(command -v rg) was installed by something else"
  fi
}

install_gh() {
  # Same rule as rg. $DATA/gh holds gh's extensions, so the release gets cli/.
  if ours gh "$DATA/gh/cli" || ! command -v gh >/dev/null; then
    tag=$(latest_tag cli/cli)
    v=${tag#v}
    if [ $os = linux ]; then asset=gh_${v}_linux_amd64.tar.gz; else asset=gh_${v}_macOS_arm64.zip; fi
    release_install cli/cli "$tag" "$asset" "gh_${v}_checksums.txt" "$DATA/gh/cli" 1 gh=bin/gh
  else
    echo "Leaving gh alone: $(command -v gh) was installed by something else"
  fi
}

install_claude() {
  # The official installer verifies its download and links ~/.local/bin/claude.
  v=$(curl -fsSL https://downloads.claude.ai/claude-code-releases/latest) || fail "Could not find Claude Code's latest version"
  have=$("$BIN/claude" --version 2>/dev/null) || have=
  if [ -n "$v" ] && [ "${have%% *}" = "$v" ]; then
    echo "Claude Code $v is already installed"
  else
    set_aside claude
    curl -fsSL -o "$TMP/claude-install.sh" https://claude.ai/install.sh
    bash "$TMP/claude-install.sh"
  fi
}

install_cursor() {
  # The official installer pins its version in the script and links
  # ~/.local/bin/agent and cursor-agent, deleting whatever was there.
  curl -fsSL -o "$TMP/cursor-install.sh" https://cursor.com/install
  v=$(sed -n 's|.*downloads\.cursor\.com/lab/\([^/]*\)/.*|\1|p' "$TMP/cursor-install.sh" | head -n 1)
  have=$("$BIN/cursor-agent" --version 2>/dev/null) || have=
  if [ -n "$v" ] && [ "$have" = "$v" ]; then
    echo "Cursor CLI $v is already installed"
  else
    set_aside agent
    set_aside cursor-agent
    bash "$TMP/cursor-install.sh"
  fi
}

# List copies of these tools outside ~/.local/bin: on the PATH this script was
# started with, old install locations, and anything this run moved out of the
# way. They're left for manual cleanup.
other_copies() {
  names="nvim codex opencode starship pixi uv uvx node claude cursor-agent"
  ours rg "$DATA/ripgrep" && names="$names rg"
  ours gh "$DATA/gh/cli" && names="$names gh"
  bin_real=$(cd "$BIN" && pwd -P)
  nvm_real=$(cd "$NVM_DIR" 2>/dev/null && pwd -P) || nvm_real=$NVM_DIR
  seen=
  old_ifs=$IFS
  IFS=:
  for dir in $USER_PATH; do
    IFS=$old_ifs
    [ -n "$dir" ] || continue
    real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    case ":$seen:" in *":$real:"*) continue ;; esac
    seen="$seen:$real"
    [ "$real" = "$bin_real" ] && continue
    for name in $names; do
      # nvm's own Node is the one we manage.
      case $name/$real in node/"$nvm_real"/*) continue ;; esac
      [ -f "$real/$name" ] && [ -x "$real/$name" ] && echo "$real/$name"
    done
  done
  IFS=$old_ifs
  cat "$TMP/moved" 2>/dev/null
  for path in "$HOME/.opencode/bin/opencode" "$HOME/.codex/packages" "$NVM_DIR"/versions/node/*/bin/codex \
    "$NVM_DIR"/versions/node/*/bin/claude \
    "${PIXI_HOME:-$HOME/.pixi}/bin/pixi" "$HOME/.local/share/fnm" "$DATA/fnm" /usr/local/bin/starship \
    /home/linuxbrew/.linuxbrew/bin/starship /opt/homebrew/bin/starship; do
    [ -e "$path" ] && echo "$path"
  done
}

failed=
for tool in neovim codex opencode starship pixi uv node rg gh claude cursor; do
  echo
  echo "== $tool"
  # Each tool runs in its own subshell so one failure doesn't stop the rest.
  # Not `if (...)`: bash ignores set -e inside a condition.
  ( set -e; "install_$tool" )
  # shellcheck disable=SC2181
  [ $? = 0 ] || failed="$failed $tool"
done

echo
copies=$(other_copies | sort -u | sed 's/^/  /')
if [ -n "$copies" ]; then
  echo "Other copies of these tools, left in place (remove them by hand if unused):"
  echo "$copies"
fi
if [ -n "$failed" ]; then
  echo "Failed:$failed" >&2
  exit 1
fi
echo "All tools are up to date in $BIN"
