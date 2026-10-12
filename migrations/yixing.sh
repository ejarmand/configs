#!/bin/bash
# Move yixing to the shared layout, then migrate Bash and install the tools.
# Preview by default; --apply makes the changes.
#
# yixing's data lives on /mnt/ultracube/earmand, whose .local was used directly
# as XDG_DATA_HOME, so each program's data sits in .local/<name>, with state in
# .local/state. 05-machines.sh now uses .local/share and .local/state there,
# like a home directory. This moves each .local/<name> into .local/share/<name>,
# except the directories that belong in .local itself. Check the preview
# first: this script was written without access to yixing.
set -e -o pipefail

case ${1:---dry-run} in
    --dry-run) apply=false ;;
    --apply) apply=true ;;
    *) echo "Usage: $0 [--dry-run|--apply]" >&2; exit 2 ;;
esac
[[ ${HOSTNAME%%.*} == yixing ]] || { echo "This script is for yixing." >&2; exit 1; }

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
storage=/mnt/ultracube/earmand
[[ -d $storage/.local ]] || { echo "$storage/.local is missing; is the drive mounted?" >&2; exit 1; }

step() {
    printf '  %s\n' "$*"
    if $apply; then "$@"; fi
}

echo "Storage layout in $storage:"
for dir in .local/share .local/state .cache; do
    [[ -d $storage/$dir ]] || step mkdir -p "$storage/$dir"
done
for entry in "$storage"/.local/* "$storage"/.local/.[!.]*; do
    [[ -e $entry ]] || continue
    name=${entry##*/}
    case $name in
        # Already in place, or part of .local's own layout (pip --user and
        # similar installers use bin, lib, include).
        share|state|bin|lib|include) continue ;;
        # Hidden entries, such as an old .nvm, may be referenced by path.
        .*) echo "  Left in place, check by hand: $entry"; continue ;;
    esac
    if [[ -e $storage/.local/share/$name ]]; then
        echo "  Left in place, $storage/.local/share/$name already exists: $entry"
    else
        step mv "$entry" "$storage/.local/share/$name"
    fi
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
    echo "Preview only. Run with --apply to migrate yixing."
fi
