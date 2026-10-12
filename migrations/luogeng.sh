#!/bin/bash
# Prepare luogeng storage. setup.sh owns the rest of machine setup.
# Preview by default; --apply makes the changes.
#
# luogeng's root disk, which holds /home and /tmp, is full, so everything big
# lives on /media/earmand. The old .bashrc used /media/earmand/.local itself as
# XDG_DATA_HOME and put it on PATH for a bare starship binary. 05-machines.sh
# now uses .local/share and .local/state there, like a home directory, and
# keeps TMPDIR on the drive.
set -e -o pipefail

case ${1:---dry-run} in
    --dry-run) apply=false ;;
    --apply) apply=true ;;
    *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2; }
[[ ${HOSTNAME%%.*} == luogeng ]] || { echo "This script is for luogeng." >&2; exit 1; }

storage=/media/earmand
backup=$storage/.local/state/configs/migration-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$
[[ -d $storage ]] || { echo "$storage is missing; is the drive mounted?" >&2; exit 1; }
marker=$storage/.local/state/configs/storage-layout-v1

step() {
    printf '  %s\n' "$*"
    if $apply; then "$@"; fi
}

echo "Storage layout in $storage:"
for dir in .local/share .local/state .cache tmp; do
    [[ -d $storage/$dir ]] || step mkdir -p "$storage/$dir"
done
# The historical moves run once; newly created .local entries stay put.
if [[ -f $marker ]]; then
    echo 'Storage layout already migrated.'
    exit 0
fi
# less's history is state, not data.
if [[ -f $storage/.local/lesshst ]]; then
    if [[ -e $storage/.local/state/lesshst || -L $storage/.local/state/lesshst ]]; then
        echo 'Both old and new less history exist. Reconcile them before rerunning setup.sh.' >&2
        exit 1
    fi
    step mv "$storage/.local/lesshst" "$storage/.local/state/lesshst"
fi
# Replaced by install-tools.sh's starship; kept in the backup, not deleted.
if [[ -f $storage/.local/starship ]]; then
    step mkdir -p "$backup"
    step mv "$storage/.local/starship" "$backup/starship"
fi
# Anything else directly in .local wasn't here when this script was written.
for entry in "$storage"/.local/* "$storage"/.local/.[!.]*; do
    case ${entry##*/} in share|state|.nvm|lesshst|starship|'*'|'.[!.]*') continue ;; esac
    echo "  Left in place, check by hand: $entry"
done

step mkdir -p "${marker%/*}"
step touch "$marker"
if ! $apply; then
    echo 'Preview only. setup.sh applies this storage migration before installing tools.'
fi
