#!/bin/bash
# Prepare yixing storage. setup.sh owns the rest of machine setup.
# Preview by default; --apply makes the changes.
#
# yixing's data lives on /mnt/ultracube/earmand, whose .local was used directly
# as XDG_DATA_HOME, so each program's data sits in .local/<name>, with state in
# .local/state. 05-machines.sh now uses .local/share and .local/state there,
# like a home directory. Recognized application data moves to .local/share;
# unknown and hidden entries stay in place. A marker prevents replaying these
# historical moves after the first successful migration.
set -e -o pipefail

case ${1:---dry-run} in
    --dry-run) apply=false ;;
    --apply) apply=true ;;
    *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2; }
[[ ${HOSTNAME%%.*} == yixing ]] || { echo "This script is for yixing." >&2; exit 1; }

storage=/mnt/ultracube/earmand
[[ -d $storage ]] || { echo "$storage is missing; is the drive mounted?" >&2; exit 1; }
marker=$storage/.local/state/configs/storage-layout-v1

step() {
    printf '  %s\n' "$*"
    if $apply; then "$@"; fi
}

echo "Storage layout in $storage:"
for dir in .local/share .local/state .cache; do
    [[ -d $storage/$dir ]] || step mkdir -p "$storage/$dir"
done
# The historical moves run once; newly created .local entries stay put.
if [[ -f $marker ]]; then
    echo 'Storage layout already migrated.'
    exit 0
fi
# Only recognized application data belonged in the old XDG_DATA_HOME.
# Unknown and hidden entries may have their own path contracts; leave them alone.
for name in nvim neovim codex opencode starship pixi uv ripgrep gh cursor-agent claude; do
    entry=$storage/.local/$name
    [[ -e $entry || -L $entry ]] || continue
    if [[ -e $storage/.local/share/$name || -L $storage/.local/share/$name ]]; then
        echo "Cannot migrate $entry: $storage/.local/share/$name already exists. Reconcile these before rerunning setup.sh." >&2
        exit 1
    fi
    step mv "$entry" "$storage/.local/share/$name"
done

for entry in "$storage"/.local/* "$storage"/.local/.[!.]*; do
    [[ -e $entry || -L $entry ]] || continue
    case ${entry##*/} in share|state|bin|lib|include) continue ;; esac
    echo "  Left in place, check by hand: $entry"
done

step mkdir -p "${marker%/*}"
step touch "$marker"
if ! $apply; then
    echo 'Preview only. setup.sh applies this storage migration before installing tools.'
fi
