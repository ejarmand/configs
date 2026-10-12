#!/bin/bash
# Move luogeng to the shared layout, then migrate Bash and install the tools.
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
[[ ${HOSTNAME%%.*} == luogeng ]] || { echo "This script is for luogeng." >&2; exit 1; }

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
storage=/media/earmand
backup=$storage/.local/state/configs/migration-backups/$(date -u +%Y%m%dT%H%M%SZ)
[[ -d $storage/.local ]] || { echo "$storage/.local is missing; is the drive mounted?" >&2; exit 1; }

step() {
    printf '  %s\n' "$*"
    if $apply; then "$@"; fi
}

echo "Storage layout in $storage:"
for dir in .local/share .local/state .cache tmp; do
    [[ -d $storage/$dir ]] || step mkdir -p "$storage/$dir"
done
# less's history is state, not data.
if [[ -f $storage/.local/lesshst && ! -e $storage/.local/state/lesshst ]]; then
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

echo
echo "Bash:"
bash "$repo/migrate-bash.sh" "${1:---dry-run}" | sed 's/^/  /'

echo
echo "Tools:"
if $apply; then
    # install-tools.sh reads 05-machines.sh itself, so the old .bashrc's
    # variables in this shell don't matter.
    bash "$repo/install-tools.sh"
    echo
    echo "Done. Open a new shell so the new .bashrc takes effect."
else
    echo "  bash $repo/install-tools.sh"
    echo
    echo "Preview only. Run with --apply to migrate luogeng."
fi
