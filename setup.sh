#!/bin/bash
# One entry point for initial setup and updates. Keep tool details in the installer.
set -e
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
case $(uname -s)/$(uname -m) in
    Linux/x86_64 | Darwin/arm64) ;;
    *) echo 'Supported platforms: Linux x86_64 and macOS arm64.' >&2; exit 1 ;;
esac
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
phase='machine settings'
trap 'status=$?; if [[ $status != 0 ]]; then echo "Setup stopped during $phase. Fix the error and rerun setup.sh." >&2; fi' EXIT
bashrc_prepend_path() { export PATH="$1:$PATH"; }
. "$repo/.bashrc.d/05-machines.sh"

phase='storage preparation'
case ${HOSTNAME%%.*} in
    luogeng | yixing) bash "$repo/migrations/${HOSTNAME%%.*}.sh" --apply ;;
esac
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}" \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "${XDG_CACHE_HOME:-$HOME/.cache}" "$NVM_DIR"

phase='tool installation'
bash "$repo/install-tools.sh"
phase='config linking'
bash "$repo/link.sh"
echo 'Setup complete. Open a new shell to load the configs.'
echo 'Login shells must source ~/.bashrc from ~/.profile or ~/.bash_profile; existing profiles were preserved.'
