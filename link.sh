#!/bin/bash
# Link managed configs. Back up replacements and leave unrelated files alone.
set -e -o pipefail
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bashrc_prepend_path() { export PATH="$1:$PATH"; }
. "$repo/.bashrc.d/05-machines.sh"
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
backup=${XDG_STATE_HOME:-$HOME/.local/state}/configs/config-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
umask 077

# The backup key is relative to either home/ or config/ because XDG_CONFIG_HOME
# can live outside HOME. A destination already pointing here needs no work.
link_config() {
    local source=$1 target=$2 key=$3
    [[ $target -ef $source ]] && return 0
    [[ -L $target && $(readlink "$target") == "$source" ]] && return 0
    prepare_directory "$(dirname -- "$target")" "${key%/*}"
    if [[ -e $target || -L $target ]]; then
        mkdir -p "$(dirname -- "$backup/$key")"
        mv -- "$target" "$backup/$key"
        printf 'Backed up %s to %s\n' "$target" "$backup/$key"
    fi
    mkdir -p "$(dirname -- "$target")"
    ln -s -- "$source" "$target"
    printf 'Linked %s\n' "$target"
}

# Materialize directory symlinks before touching their children so switching
# checkouts never writes into the old checkout. Keep local files such as locks.
prepare_directory() {
    local target=$1 key=$2 staging original child relative destination saved=$backup/directory-links/$2.link
    # HOME and XDG_CONFIG_HOME themselves may intentionally point elsewhere.
    if [[ $key != */* ]]; then mkdir -p "$target"; return; fi
    prepare_directory "$(dirname -- "$target")" "${key%/*}"
    if [[ -L $target || ( -e $target && ! -d $target ) ]]; then
        staging=$(mktemp -d "$(dirname -- "$target")/.configs-link.XXXXXX")
        if [[ -d $target ]]; then
            original=$(cd -- "$target" && pwd -P)
            cp -a "$target/." "$staging/"
            # Relative child links must keep resolving from the old directory.
            find "$staging" -type l -print0 | while IFS= read -r -d '' child; do
                destination=$(readlink "$child")
                [[ $destination != /* ]] || continue
                relative=${child#"$staging/"}
                rm -- "$child"
                ln -s -- "$original/$(dirname -- "$relative")/$destination" "$child"
            done
        fi
        mkdir -p "$(dirname -- "$saved")"
        mv -- "$target" "$saved"
        mv -- "$staging" "$target"
        printf 'Backed up %s to %s\n' "$target" "$saved"
    else
        mkdir -p "$target"
    fi
}

prepare_directory "$HOME/.bashrc.d" home/.bashrc.d
for source in "$repo"/.bashrc.d/*.sh "$repo/.bashrc"; do
    bash -n "$source"
    relative=${source#"$repo/"}
    link_config "$source" "$HOME/$relative" "home/$relative"
done
# Link only tracked Neovim files; local plugins and lazy-lock.json stay local.
git -C "$repo" ls-files -z -- nvim | while IFS= read -r -d '' relative; do
    link_config "$repo/$relative" "$config_home/$relative" "config/$relative"
done
link_config "$repo/starship.toml" "$config_home/starship.toml" config/starship.toml
for source in "$repo"/bin/*; do
    relative=.local/bin/${source##*/}
    link_config "$source" "$HOME/$relative" "home/$relative"
done
# setup.sh updates this checkout first. Reuse the config backup policy for skills.
skills_repo=${SKILLS_REPO:-$HOME/projects/skills}
if [[ -d $skills_repo ]]; then
    skills_repo=$(cd -- "$skills_repo" && pwd)
fi
for manifest in "$skills_repo"/skills/*/SKILL.md; do
    [[ -f $manifest ]] || continue
    skill=${manifest%/SKILL.md}
    for directory in .agents/skills .claude/skills; do
        relative=$directory/${skill##*/}
        link_config "$skill" "$HOME/$relative" "home/$relative"
    done
    for source in "$skill"/bin/*; do
        [[ -f $source && -x $source ]] || continue
        relative=.local/bin/${source##*/}
        link_config "$source" "$HOME/$relative" "home/$relative"
    done
done
# These files override Hyprkarl's defaults; they are not server or Mac configs.
if [[ $(uname -s) == Linux && -d ${HYPRKARL_PATH:-$HOME/.local/share/hyprkarl} ]]; then
    for relative in hypr/hyprland.local.lua uwsm/env.local ghostty/local.conf \
        xdg-terminals.list hyprkarl/apps/t3code.conf; do
        link_config "$repo/$relative" "$config_home/$relative" "config/$relative"
    done
fi
