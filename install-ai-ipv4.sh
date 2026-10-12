#!/bin/bash
# Install just the tested IPv4 launchers. No package upgrades or root access.
set -e
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { echo 'The IPv4 launchers require Linux/glibc.' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
data=${XDG_DATA_HOME:-$HOME/.local/share}/configs
bin=$HOME/.local/bin
command -v cc >/dev/null || { echo 'A C compiler (cc) is required.' >&2; exit 1; }
for cli in codex claude; do
    [[ -x $bin/$cli ]] || { echo "Missing $bin/$cli" >&2; exit 1; }
    LC_ALL=C ldd "$bin/$cli" 2>/dev/null | grep -q 'libc\.so' || {
        echo "IPv4 launcher needs a dynamically linked glibc binary: $bin/$cli" >&2
        exit 1
    }
    if [[ -e $bin/$cli-ipv4 && ! -L $bin/$cli-ipv4 ]]; then
        echo "Refusing to replace the existing file $bin/$cli-ipv4" >&2
        exit 1
    fi
done
snippet=$HOME/.bashrc.d/10-ai-ipv4.sh
if [[ -e $snippet && ! -L $snippet ]]; then
    echo "Refusing to replace the existing file $snippet" >&2
    exit 1
fi
mkdir -p "$data" "$bin" "$HOME/.bashrc.d"
temp=$(mktemp "$data/ai-ipv4.XXXXXX")
trap 'rm -f "$temp"' EXIT
cc -shared -fPIC -O2 -Wall -Wextra -Werror -o "$temp" "$repo/network/ai-ipv4.c" -ldl
chmod 755 "$temp"
mv -f "$temp" "$data/ai-ipv4.so"
for cli in codex claude; do
    ln -sfn "$repo/network/ai-ipv4" "$bin/$cli-ipv4"
done
ln -sfn "$repo/.bashrc.d/10-ai-ipv4.sh" "$snippet"

# Older, unshared Bash files may not load ~/.bashrc.d. Prepend only this one
# source line, with a backup, rather than replacing their shell configuration.
source_line='[ ! -r "$HOME/.bashrc.d/10-ai-ipv4.sh" ] || . "$HOME/.bashrc.d/10-ai-ipv4.sh"'
if ! grep -q '\.bashrc\.d/\*\.sh' "$HOME/.bashrc" 2>/dev/null &&
   ! grep -Fqx "$source_line" "$HOME/.bashrc" 2>/dev/null; then
    backup=${XDG_STATE_HOME:-$HOME/.local/state}/configs/bash-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
    mkdir -p "$backup"
    [[ ! -e $HOME/.bashrc ]] || cp -a "$HOME/.bashrc" "$backup/bashrc"
    if [[ -e $HOME/.bashrc ]]; then
        sed -i "1i$source_line" "$HOME/.bashrc"
    else
        printf '%s\n' "$source_line" > "$HOME/.bashrc"
    fi
fi
echo "Installed $bin/codex-ipv4 and $bin/claude-ipv4"
echo 'New Bash shells use them for codex and claude.'
echo 'For GUI/SSH launchers such as T3, set the executable to the corresponding absolute *-ipv4 path.'
