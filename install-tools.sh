#!/bin/bash
# Install the command-line tools these configs expect, or update them to their
# latest release. Each tool is unpacked under ${XDG_DATA_HOME:-~/.local/share}
# and linked into ~/.local/bin; nvm goes in $NVM_DIR, and Claude Code and
# Cursor where their installers put them. The machine settings in
# .bashrc.d/05-machines.sh (storage-drive XDG dirs, NVM_DIR) are loaded first,
# so this works the same from a shell that hasn't read them.
# Safe to rerun: a tool already at its latest release isn't downloaded again.
# Shell startup files are never edited; on some hosts, one line is added to
# Codex's config.toml (see codex_ip_family). Old copies elsewhere are left in
# place and listed at the end. Runs on Linux x86_64 and macOS arm64, under
# bash 3.2+.

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=linux triple=x86_64-unknown-linux-musl ;;
  Darwin/arm64) os=macos triple=aarch64-apple-darwin ;;
  *)
    echo "Unsupported platform: $(uname -s) $(uname -m). Only Linux x86_64 and macOS arm64 are supported." >&2
    exit 1
    ;;
esac

bashrc_prepend_path() { PATH="$1:$PATH"; }
# shellcheck source=.bashrc.d/05-machines.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/.bashrc.d/05-machines.sh" || exit 1

BIN=$HOME/.local/bin
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
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

# Check FILE against an npm integrity string (sha512-<base64>).
check_sha512() {
  want=$(printf %s "${2#sha512-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')
  if [ $os = macos ]; then got=$(shasum -a 512 "$1"); else got=$(sha512sum "$1"); fi
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

# Remove release_install's staging directory, however the tool's subshell ends.
# If the old copy was moved into it and DEST is missing, the old copy is moved
# back first; if that fails, the directory is kept and listed at the end.
end_swap() {
  if [ -e "$work/old" ] && [ ! -e "$dest" ] && ! mv "$work/old" "$dest"; then
    echo "$work" >> "$TMP/moved"
  else
    rm -rf "$work"
  fi
}

# release_install REPO TAG ASSET SUMS DEST STRIP NAME=PATH...
# Unpack ASSET from REPO's release TAG as the directory DEST, unless DEST already
# holds TAG. SUMS is the release's checksum file, or "" if it publishes none.
# STRIP=1 drops the archive's top-level folder. Each NAME=PATH links DEST/PATH
# into ~/.local/bin. The new copy is unpacked next to DEST and swapped in, so
# no files from the old version linger. Set BUILD to record something more
# specific than TAG, for a release that is rebuilt under the same tag. For a
# download that isn't a GitHub release, set BASE to the URL ASSET is under and
# INTEGRITY to its npm-style sha512.
release_install() {
  repo=$1 tag=$2 asset=$3 sums=$4 dest=$5 strip=$6
  shift 6
  build=${build:-$tag}
  base=${base:-https://github.com/$repo/releases/download/$tag}
  # A staging directory left by an interrupted run is listed at the end.
  for left in "$dest".install.??????; do [ ! -d "$left" ] || echo "$left" >> "$TMP/moved"; done
  current=no
  [ "$(cat "$dest/.release-tag" 2>/dev/null)" = "$build" ] && current=yes
  for pair in "$@"; do [ -x "$dest/${pair#*=}" ] || current=no; done

  if [ $current = yes ]; then
    echo "$repo $tag is already installed"
  else
    echo "Installing $repo $tag into $dest"
    # A DEST this script didn't create is kept as DEST.orig.
    if [ -e "$dest" ] && [ ! -e "$dest/.release-tag" ] && [ -e "$dest.orig" ]; then
      fail "$dest wasn't installed by this script and $dest.orig is taken; move one of them away"
    fi
    curl -fsSL -o "$TMP/$asset" "$base/$asset"
    if [ -n "$sums" ]; then
      curl -fsSL -o "$TMP/$sums" "$base/$sums"
      check_sha256 "$TMP/$asset" "$TMP/$sums"
    fi
    if [ -n "${integrity-}" ]; then check_sha512 "$TMP/$asset" "$integrity"; fi
    # Unpack into a directory unique to this run, next to DEST so the swap is a
    # rename. The old copy is moved into it too. The trap (local to this tool's
    # subshell) cleans it up even if the run is interrupted; no other path is
    # ever deleted.
    mkdir -p "${dest%/*}"
    work=$(mktemp -d "$dest.install.XXXXXX")
    trap end_swap EXIT
    # Bash 3.2 skips a subshell's EXIT trap when SIGTERM or SIGHUP kills it, so
    # those exit instead. Ctrl+C already runs the EXIT trap.
    trap 'exit 1' HUP TERM
    mkdir "$work/new"
    case $asset in
      *.zip) unzip -q "$TMP/$asset" -d "$work/new" ;;
      *) tar -xzf "$TMP/$asset" -C "$work/new" ;;
    esac
    rm -f "$TMP/$asset"
    src=$work/new
    [ "$strip" = 1 ] && src=$(echo "$work/new"/*)
    [ -d "$src" ] || fail "Unexpected layout in $asset"
    for pair in "$@"; do
      [ -f "$src/${pair#*=}" ] || fail "$asset has no ${pair#*=}"
      chmod +x "$src/${pair#*=}"
    done
    echo "$build" > "$src/.release-tag"

    if [ -e "$dest" ] && [ ! -e "$dest/.release-tag" ]; then
      mv "$dest" "$dest.orig"
      echo "Moved the existing $dest to $dest.orig"
      echo "$dest.orig" >> "$TMP/moved"
    fi
    if [ -e "$dest" ]; then mv "$dest" "$work/old"; fi
    # On failure the trap puts the old copy back.
    mv "$src" "$dest" || fail "Could not move the new copy into $dest"
    end_swap
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
    # Each push to the fork rebuilds and republishes fork-v<upstream version>
    # under the same tag, so the commit the tag points at tells builds apart.
    tag=$(latest_tag ejarmand/codex)
    sha=$(git ls-remote https://github.com/ejarmand/codex "refs/tags/$tag" | cut -f1)
    [ -n "$sha" ] || fail "Could not find the commit of ejarmand/codex $tag"
    build="$tag $sha"
    release_install ejarmand/codex "$tag" codex-fork-x86_64-linux.tar.gz "" "$DATA/codex" 0 codex=bin/codex
    codex_sandbox
    codex_ip_family
  else
    tag=$(latest_tag openai/codex)
    release_install openai/codex "$tag" codex-package-aarch64-apple-darwin.tar.gz codex-package_SHA256SUMS \
      "$DATA/codex" 0 codex=bin/codex
  fi
}

# Codex runs commands in a bwrap sandbox. It uses the first bwrap on PATH, or
# else the one in its package, with a warning at startup.
codex_sandbox() {
  if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    # Ubuntu 24.04+ strips capabilities from programs that create user
    # namespaces unless an AppArmor profile allows it, so the bundled bwrap
    # fails with "setting up uid map: Permission denied". Ubuntu has a profile
    # that allows it for its own bwrap, but not for the commands bwrap runs,
    # and doesn't load it by default. Nothing may shadow that bwrap on PATH.
    if ours bwrap "$DATA/codex"; then rm "$BIN/bwrap"; fi
    if ! /usr/bin/bwrap --ro-bind / / --unshare-user --unshare-net true 2>/dev/null; then
      echo "Installing Ubuntu's bwrap and its AppArmor profile so Codex can sandbox commands (needs sudo)"
      sudo apt-get install -y bubblewrap apparmor-profiles &&
        sudo install -m 644 /usr/share/apparmor/extra-profiles/bwrap-userns-restrict /etc/apparmor.d/ &&
        sudo apparmor_parser -r /etc/apparmor.d/bwrap-userns-restrict ||
        fail "Could not set up Ubuntu's bwrap"
    fi
  elif ours bwrap "$DATA/codex" || ! command -v bwrap >/dev/null; then
    # Linking the bundled one stops the warning. A distro bwrap is left alone.
    link "$DATA/codex/codex-resources/bwrap" bwrap
  fi
  bwrap --ro-bind / / --unshare-user --unshare-net true || fail "bwrap can't build Codex's sandbox"
}

# The fork's ip_family setting keeps Codex's connections to one IP family, for
# networks that drop long-lived connections over the other. These hosts use
# IPv4. A top-level key has to come before the first [table], so the line goes
# at the top of config.toml. An ip_family that's already set is left alone.
codex_ip_family() {
  case ${HOSTNAME%%.*} in pandiero | tumba | qinto) ;; *) return 0 ;; esac
  config=${CODEX_HOME:-$HOME/.codex}/config.toml
  current=$(awk '/^[[:space:]]*\[/ { exit } /^[[:space:]]*ip_family[[:space:]]*=/ { print; exit }' \
    "$config" 2>/dev/null) || current=
  if [ -z "$current" ]; then
    mkdir -p "${config%/*}"
    { echo 'ip_family = "ipv4"'; [ ! -e "$config" ] || cat "$config"; } > "$TMP/codex-config"
    # Writing over it, rather than moving a new file in, keeps the file's
    # permissions and any link to it.
    cat "$TMP/codex-config" > "$config"
    echo "Added ip_family = \"ipv4\" to $config"
  else
    case $current in *ipv4*) ;; *) echo "Leaving $config's $current alone" ;; esac
  fi
}

install_opencode() {
  # opencode v2 isn't on GitHub releases, which still carry v1. Like its own
  # installer (opencode.ai/v2/install), ask opencode.ai for the latest version
  # and npm package, then fetch that package's binary from npm.
  # $DATA/opencode is opencode's own data (sessions, auth), so the binary gets
  # cli/. The baseline build is for CPUs without AVX2.
  meta=$(curl -fsSL https://opencode.ai/update/api/latest/cli/npm) || fail "Could not ask opencode.ai for its latest version"
  version=$(echo "$meta" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
  scope=$(echo "$meta" | sed -n 's/.*"package":"\([^"]*\)".*/\1/p')
  [ -n "$version" ] && [ -n "$scope" ] || fail "Could not find opencode's latest version"
  scope=${scope%/cli}
  if [ $os = macos ]; then target=darwin-arm64
  elif grep -qw avx2 /proc/cpuinfo; then target=linux-x64
  else target=linux-x64-baseline
  fi
  pkg=$scope/cli-$target
  integrity=$(curl -fsSL "https://registry.npmjs.org/$scope%2fcli-$target/$version" |
    sed -n 's/.*"integrity":"\([^"]*\)".*/\1/p')
  [ -n "$integrity" ] || fail "Could not find $pkg $version on npm"
  base=https://registry.npmjs.org/$pkg/-
  release_install "$pkg" "v$version" "cli-$target-$version.tgz" "" "$DATA/opencode/cli" 1 opencode=bin/opencode
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
    # The installer downloads to ~/.claude/downloads. When the data directory
    # is elsewhere, point that into the cache so the download skips $HOME too.
    if [ "$DATA" != "$HOME/.local/share" ] && [ ! -e "$HOME/.claude/downloads" ]; then
      mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/claude-downloads" "$HOME/.claude"
      ln -s "${XDG_CACHE_HOME:-$HOME/.cache}/claude-downloads" "$HOME/.claude/downloads"
    fi
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
    # The installer always writes to ~/.local/share/cursor-agent. When the data
    # directory is elsewhere, point that path into it first.
    if [ "$DATA" != "$HOME/.local/share" ] && [ ! -e "$HOME/.local/share/cursor-agent" ]; then
      mkdir -p "$DATA/cursor-agent" "$HOME/.local/share"
      ln -s "$DATA/cursor-agent" "$HOME/.local/share/cursor-agent"
    fi
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
  # Copies a run made before the data directory or NVM_DIR moved.
  if [ "$DATA" != "$HOME/.local/share" ]; then
    for dir in neovim codex opencode/cli starship pixi uv/bin ripgrep gh/cli; do
      [ -e "$HOME/.local/share/$dir/.release-tag" ] && echo "$HOME/.local/share/$dir"
    done
  fi
  [ "$NVM_DIR" != "$HOME/.nvm" ] && [ -s "$HOME/.nvm/nvm.sh" ] && echo "$HOME/.nvm"
  for path in "$HOME/.local/opt/codex-fork" "$HOME/.opencode/bin/opencode" "$HOME/.codex/packages" "$NVM_DIR"/versions/node/*/bin/codex \
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
