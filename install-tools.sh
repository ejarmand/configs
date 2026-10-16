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

case "$#:${1-}" in
  0: | 1:--codex-sandbox | 1:--check-codex-sandbox) ;;
  *) echo "Usage: $0 [--codex-sandbox | --check-codex-sandbox]" >&2; exit 2 ;;
esac

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) os=linux triple=x86_64-unknown-linux-musl ;;
  Darwin/arm64) os=macos triple=aarch64-apple-darwin ;;
  *)
    echo "Unsupported platform: $(uname -s) $(uname -m). Only Linux x86_64 and macOS arm64 are supported." >&2
    exit 1
    ;;
esac

bashrc_prepend_path() { PATH="$1:$PATH"; }
CONFIGS_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=.bashrc.d/05-machines.sh
. "$CONFIGS_REPO/.bashrc.d/05-machines.sh" || exit 1

# These machines already use IPv4 for Codex; apply the same policy to Claude
# and Muse.
ai_ipv4=no
case ${HOSTNAME%%.*} in pandiero | tumba | quinto) ai_ipv4=yes ;; esac

BIN=$HOME/.local/bin
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
BACKUP=${XDG_STATE_HOME:-$HOME/.local/state}/configs/tool-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
USER_PATH=$PATH
export PATH="$BIN:$PATH"
if [ "${1-}" = --check-codex-sandbox ]; then
  /bin/bash "$CONFIGS_REPO/install/codex-sandbox.sh" check "$DATA/codex/codex-resources/bwrap"
  exit $?
fi
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

# Check the sandbox first, then offer one privileged setup step if needed.
codex_sandbox() {
  bwrap=$(/bin/bash "$CONFIGS_REPO/install/codex-sandbox.sh" ensure "$DATA/codex/codex-resources/bwrap") ||
    fail "Codex's sandbox is not configured"
  link "$bwrap" bwrap
}

# The fork's ip_family setting keeps Codex's connections to one IP family, for
# networks that drop long-lived connections over the other. These hosts use
# IPv4. A top-level key has to come before the first [table], so the line goes
# at the top of config.toml. An ip_family that's already set is left alone.
codex_ip_family() {
  [ "$ai_ipv4" = yes ] || return 0
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
  # The background server keeps running the binary that started it, and
  # clients such as T3 Code report its version, so move it onto this one.
  state=${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json
  # A new install has no state file yet.
  running=$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$state" 2>/dev/null) || running=
  pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$state" 2>/dev/null) || pid=
  if [ -n "$running" ] && [ "$running" != "$version" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    if "$DATA/opencode/cli/bin/opencode" service restart >/dev/null; then
      echo "Restarted opencode's background server ($running) on $version"
    else
      echo "Could not restart opencode's background server; it's still on $running"
    fi
  fi
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

  # Install after the native binary, including when it was already current.
  [ "$os" = linux ] && [ "$ai_ipv4" = yes ] || return 0
  dest=$DATA/configs/claude-ipv4
  mkdir -p "$dest"
  cc -shared -fPIC -O2 -Wall -Wextra -Werror -o "$TMP/ai-ipv4.so" "$CONFIGS_REPO/network/ai-ipv4.c" -ldl
  install -m 755 "$TMP/ai-ipv4.so" "$dest/ai-ipv4.so"
  install -m 755 "$CONFIGS_REPO/network/claude-ipv4" "$dest/claude-ipv4"
  link "$dest/claude-ipv4" claude-ipv4
  echo "Installed $BIN/claude-ipv4"
  "$BIN/claude-ipv4" --version
  t3_binary_path claudeAgent claude "$BIN/claude-ipv4"
}

# T3 starts providers itself and doesn't read the Bash functions, so point its
# Claude or Muse provider at the IPv4 launcher in ~/.t3/userdata/settings.json.
# The server reloads that file when it changes. Only an unset or native binary
# path is replaced; any other path is left alone.
t3_binary_path() { # INSTANCE COMMAND LAUNCHER
  python3 -I - "$HOME/.t3/userdata/settings.json" "$BIN" "$@" <<'PY'
import json, os, sys
path, bin_dir, instance_id, command, launcher = sys.argv[1:]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
instance = settings.setdefault("providerInstances", {}).setdefault(
    instance_id, {"driver": instance_id, "enabled": True})
config = instance.setdefault("config", {})
current = config.get("binaryPath", "")
if current == launcher:
    sys.exit()
if current not in ("", command, os.path.join(bin_dir, command)):
    print(f"Leaving T3's {instance_id} binary path {current} alone")
    sys.exit()
config["binaryPath"] = launcher
os.makedirs(os.path.dirname(path), exist_ok=True)
# Writing over it, rather than moving a new file in, keeps the file's
# permissions and any link to it.
text = json.dumps(settings, indent=2) + "\n"
with open(path, "w") as f:
    f.write(text)
print(f"Set T3's {instance_id} binary path to {launcher}")
PY
}

# ~/.local/bin/muse links to Muse Code's launcher, which updates itself and the
# binary next to it, following links to find that directory. The binary is
# large, so both live under $DATA. Install the launcher only when it's missing;
# its install mode downloads the binary and may print a sign-in link the first
# time.
install_muse() {
  dest=$DATA/muse/launcher
  # Earlier runs left the launcher and binary in ~/.local/bin.
  if [ -f "$BIN/muse" ] && [ ! -L "$BIN/muse" ] && [ ! -e "$dest/muse" ]; then
    mkdir -p "$dest"
    for file in "$BIN"/muse "$BIN"/muse-bin-* "$BIN"/.muse-*; do
      [ -e "$file" ] && mv "$file" "$dest/"
    done
    echo "Moved Muse Code from $BIN to $dest"
  fi
  if [ -x "$dest/muse" ]; then
    link "$dest/muse" muse
    echo "Muse Code is installed and updates itself"
  else
    curl -fsSL --proto '=https' -o "$TMP/muse" https://api.meta.ai/muse-launcher.sh
    bash -n "$TMP/muse" || fail "The Muse Code launcher download is not a valid script"
    mkdir -p "$dest"
    install -m 755 "$TMP/muse" "$dest/muse"
    link "$dest/muse" muse
    MUSE_LAUNCHER_INSTALL=1 "$BIN/muse"
    echo "Installed $BIN/muse"
  fi

  # Each Muse install keeps its own contributor mode setting, which lets Meta
  # use your content for product improvement. Keep it off, leaving the rest of
  # the file to Muse.
  python3 -I - "${XDG_CONFIG_HOME:-$HOME/.config}/muse/settings.json" <<'EOF' || fail "Could not turn off Muse contributor mode"
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {"schema_version": 1}
if settings.get("contributor_mode_enabled") is False:
    print("Muse contributor mode is off")
    sys.exit()
settings["contributor_mode_enabled"] = False
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path + ".tmp", "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
print(f"Turned off Muse contributor mode in {path}")
EOF

  # The IPv4 launcher relies on Bash 4's coproc and GNU readlink.
  [ "$os" = linux ] && [ "$ai_ipv4" = yes ] || return 0
  # Start the repo's proxy once, before replacing a working copy. It reports
  # its port and, with no grace period, exits at end of input.
  port=$(MUSE_IPV4_PROXY_GRACE=0 python3 -I "$CONFIGS_REPO/network/muse-ipv4-proxy.py" < /dev/null) || port=
  case $port in '' | *[!0-9]*) fail "The Muse IPv4 proxy needs a working python3" ;; esac
  dest=$DATA/configs/muse-ipv4
  mkdir -p "$dest"
  install -m 644 "$CONFIGS_REPO/network/muse-ipv4-proxy.py" "$dest/muse-ipv4-proxy.py"
  install -m 755 "$CONFIGS_REPO/network/muse-ipv4" "$dest/muse-ipv4"
  link "$dest/muse-ipv4" muse-ipv4
  echo "Installed $BIN/muse-ipv4"
  t3_binary_path muse muse "$BIN/muse-ipv4"
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

if [ "${1-}" = --codex-sandbox ]; then
  ( set -e; codex_sandbox )
  exit $?
fi

failed=
tools="neovim codex opencode starship pixi uv node rg gh claude muse cursor"
# 05-machines.sh sets this on hosts that shouldn't run agent CLIs.
[ -z "${CONFIGS_NO_AGENTS-}" ] || tools="neovim starship pixi uv node rg gh"
for tool in $tools; do
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
