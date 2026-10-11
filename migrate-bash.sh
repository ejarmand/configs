#!/bin/bash
# Link only Bash files. --apply backs up anything replaced; default is a preview.
set -e

case ${1:---dry-run} in
    --dry-run) apply=false ;;
    --apply) apply=true ;;
    *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2; }

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backup="${XDG_STATE_HOME:-$HOME/.local/state}/configs/bash-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
umask 077

if [[ -L $HOME/.bashrc.d || ( -e $HOME/.bashrc.d && ! -d $HOME/.bashrc.d ) ]]; then
    echo 'Migration needs a real ~/.bashrc.d directory to preserve local snippets.' >&2
    exit 1
fi

files=()
for source in "$repo"/.bashrc.d/*.sh "$repo/.bashrc"; do
    bash --noprofile --norc -n "$source"
    relative=${source#"$repo/"}
    if [[ -d $HOME/$relative ]]; then
        printf 'Cannot replace a directory: %s\n' "$HOME/$relative" >&2
        exit 1
    fi
    files+=("$relative")
done

for relative in "${files[@]}"; do
    target="$HOME/$relative"
    if [[ -L $target && $(readlink "$target") == "$repo/$relative" ]]; then
        continue
    fi
    if [[ -e $target || -L $target ]]; then
        printf 'Back up %s to %s\n' "$target" "$backup/$relative"
        if $apply; then
            mkdir -p "$(dirname -- "$backup/$relative")"
            cp -a -- "$target" "$backup/$relative"
        fi
    fi
    printf 'Link %s -> %s\n' "$target" "$repo/$relative"
    if $apply; then
        mkdir -p "$(dirname -- "$target")"
        ln -s -- "$repo/$relative" "$target.configs-link-$$"
        mv -f -- "$target.configs-link-$$" "$target"
    fi
done

if ! $apply; then
    echo 'Preview only. Run with --apply to migrate Bash.'
fi
