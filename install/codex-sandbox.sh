#!/bin/bash
# Check as the invoking user; perform only the system setup in a sudo subcommand.
set -e

fail() { echo "$*" >&2; exit 1; }
usage() {
  echo "Usage: $0 {check|ensure|setup} BUNDLED_BWRAP" >&2
  exit 2
}
[ $# = 2 ] || usage
mode=$1
case $mode in check | ensure | setup) ;; *) usage ;; esac
[ "$(uname -s)" = Linux ] || fail "Codex's bubblewrap setup applies to Linux only"
[ -f "$2" ] && [ -x "$2" ] || fail "Missing Codex's bundled bwrap: $2"
source_bwrap=$(readlink -f "$2")
script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/codex-sandbox.sh
PATH="$PATH:/usr/sbin:/sbin"
export PATH

restricted=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null) || restricted=0
helper=$source_bwrap
template=/usr/share/apparmor/extra-profiles/bwrap-userns-restrict
profile=/etc/apparmor.d/codex-bwrap
if [ "$restricted" = 1 ]; then helper=/usr/local/lib/codex/bwrap; fi

missing_packages() {
  missing=
  for package in apparmor apparmor-profiles; do
    if [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" != 'install ok installed' ]; then
      missing="$missing $package"
    fi
  done
}

render_profile() {
  # Keep Ubuntu's child capability restrictions and use distinct profile names.
  sed -e 's/\bunpriv_bwrap\b/unpriv_codex_bwrap/g' \
      -e 's/\bbwrap\b/codex-bwrap/g' \
      -e 's|/usr/bin/codex-bwrap|/usr/local/lib/codex/bwrap|g' "$template"
}

check() {
  ready=yes
  if [ "$restricted" = 1 ]; then
    missing_packages
    if [ -n "$missing" ]; then
      echo "Missing required packages:$missing"
      ready=no
    fi
    if [ ! -r "$template" ] || ! command -v apparmor_parser >/dev/null; then
      echo "AppArmor's bwrap profile or compiler is missing."
      ready=no
    fi
    if ! cmp -s "$source_bwrap" "$helper" ||
       [ "$(stat -c '%u:%g:%a' "$helper" 2>/dev/null)" != 0:0:755 ] ||
       [ "$(stat -c '%u:%g:%a' "${helper%/*}" 2>/dev/null)" != 0:0:755 ]; then
      echo "Protected bundled helper is missing, outdated, or has incorrect ownership: $helper"
      ready=no
    fi
    if [ ! -r "$template" ] || [ ! -r "$profile" ] || ! cmp -s <(render_profile) "$profile" ||
       [ "$(stat -c '%u:%g:%a' "$profile" 2>/dev/null)" != 0:0:644 ]; then
      echo "AppArmor profile is missing, outdated, or has incorrect ownership: $profile"
      ready=no
    fi
  fi
  [ "$ready" = yes ] || return 1
  # A successful exec alone does not establish that the child profile is loaded.
  if ! error=$("$helper" --ro-bind / / --unshare-user --unshare-net /bin/sh -c '
    if [ "$1" = 1 ]; then
      case $(cat /proc/self/attr/current) in
        "codex-bwrap//&unpriv_codex_bwrap (enforce)") ;;
        *) echo "Expected Codex AppArmor child profile is not enforced." >&2; exit 1 ;;
      esac
    fi
  ' sh "$restricted" 2>&1); then
    echo "Sandbox smoke test failed: $error"
    return 1
  fi
  echo "Sandbox configured: $helper"
}

setup() {
  [ "$EUID" = 0 ] || fail "Run the setup subcommand with sudo."
  # Do not inherit user launchers while installing system files.
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  export PATH
  [ "$restricted" = 1 ] || fail "This host does not need privileged sandbox setup."
  missing_packages
  if [ -n "$missing" ]; then
    apt-get install -y $missing || fail "Could not install the required AppArmor packages."
  fi
  [ -r "$template" ] && command -v apparmor_parser >/dev/null ||
    fail "AppArmor's bwrap profile or compiler is missing."
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  render_profile > "$work/codex-bwrap"
  apparmor_parser -Q -K "$work/codex-bwrap"
  install -d -o root -g root -m 755 "${helper%/*}"
  install -o root -g root -m 755 "$source_bwrap" "$helper"
  install -o root -g root -m 644 "$work/codex-bwrap" "$profile"
  apparmor_parser -r "$profile"
}

case $mode in
  check) check ;;
  setup) setup ;;
  ensure)
    if ! check >&2; then
      # On unrestricted hosts the bundled helper should work without sudo.
      [ "$restricted" = 1 ] || fail "The bundled helper failed; no AppArmor setup is needed on this host."
      echo "Setup will install missing AppArmor packages, copy Codex's bundled helper, and load its profile." >&2
      printf 'Set up the Codex sandbox with sudo? [y/N] ' >&2
      read -r answer || answer=
      case $answer in
        y | Y | yes | YES | Yes)
          sudo /bin/bash "$script" setup "$source_bwrap" >&2
          check >&2 || fail "Sandbox setup completed, but its check still fails."
          ;;
        *)
          printf '\nSandbox setup skipped. Run: sudo bash %q setup %q\n' "$script" "$source_bwrap" >&2
          exit 1
          ;;
      esac
    fi
    # The caller owns user-level links and backups. Only this path goes to stdout.
    printf '%s\n' "$helper"
    ;;
esac
