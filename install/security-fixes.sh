#!/bin/bash
# Fixes for October 2026's eMudhra CA key compromise and the malicious LiteLLM
# 1.107.0 release. install-tools.sh runs this before downloading anything and
# stops if it fails. Safe to rerun; anything a machine doesn't have (Homebrew,
# nvm, Docker, an env directory) is skipped. Sudo prompts when needed; declined
# or unavailable privileges leave the affected step for later. Runs under
# bash 3.2+.
#
# The steps run in this order (see main), each gated on the ones before:
# - Looks for LiteLLM 1.107.0 first, without starting Python or the runtimes
#   below, and stops at once on any trace of it: its package, startup hooks,
#   marker files, daemon or Docker image. A clean result covers only the
#   places it lists, not the whole machine.
# - Saves a trust store without the roots above the compromised intermediates,
#   or any certificate with one of their keys, as $DATA/configs/ca-bundle.pem:
#   a link to the system bundle when it's already clean, otherwise a filtered
#   copy. Every forged chain in install/emudhra-chains must fail to verify
#   against it, offline, for want of an issuer; otherwise nothing below
#   downloads anything, this fails and setup stops. .bashrc.d/10-ca-bundle.sh
#   points OpenSSL, curl and Python (requests, pip, uv) at it, with an empty
#   CA directory so the system's directory can't add the roots back. Delete
#   the file to go back to each tool's own store.
# - Upgrades the system's ca-certificates when it still has those roots and
#   sudo is available, prompting in a terminal when needed. The package manager
#   checks the package's signature, so this runs before the store is checked.
#   With a checked store, upgrades Homebrew's, and rebuilds its generated
#   bundle if the upgrade leaves it empty.
# - Lists Node, uv, Bun, Deno, pixi, conda, Claude Code and Java installs that
#   still trust the compromised intermediates. They keep their own roots, so
#   the bundle doesn't reach them.
# - With a checked store, updates Tailscale older than 1.104.2 where it's
#   already installed (see tailscale_update), and checks that the running
#   daemon is updated too.
# - Removes pip trusted-host settings, which turn off certificate checks for
#   an index, and with a checked store points npm at it.
# - Removes links on the PATH to missing files under /tmp, where any user
#   could create them.
# - Takes group and other access off credential files and the directories
#   that hold keys, tokens and agent transcripts, so other accounts on a shared
#   host can't read them.

[ $# = 0 ] || { echo "Usage: $0" >&2; exit 2; }

CONFIGS_REPO=${BASH_SOURCE[0]%/*}/..
# The machine settings move the data directory to a storage drive on some
# hosts, so a run outside setup needs them too. Hostnames don't decide sudo access.
bashrc_prepend_path() { PATH="$1:$PATH"; }
if [ -r "$CONFIGS_REPO/.bashrc.d/05-machines.sh" ]; then
  # shellcheck source=../.bashrc.d/05-machines.sh
  . "$CONFIGS_REPO/.bashrc.d/05-machines.sh" || exit 1
fi

DATA=${XDG_DATA_HOME:-$HOME/.local/share}
BIN=$HOME/.local/bin
BUNDLE=$DATA/configs/ca-bundle.pem
# Empty on purpose: SSL_CERT_DIR points here so OpenSSL and Python don't also
# trust whatever the system's CA directory holds.
NO_CA_DIR=$DATA/configs/no-ca-dir
CHAINS=$CONFIGS_REPO/install/emudhra-chains
# The forged leaves are valid from 2026-10-22 13:14 to 2027-05-03; verifying
# as of 2026-10-23 keeps the check meaningful after they expire.
VERIFY_AT=1792713600
# Live hosts serving those chains, as a second check when they can be reached.
PROBES="dv-g3b-emudhra dv-g3b-aaa-emudhra dv-g3b-noct-emudhra dv-g3b-aaa-noct-emudhra"
# The roots above the compromised intermediates. Patched stores leave them out.
BAD_ROOTS='emSign Root TLS CA - G3|emSign ECC Root CA - G3|emSign Root CS CA - G3|AAA Certificate Services'
# SHA-256 of the eight compromised intermediates' public keys (base64).
BAD_KEYS="6+1kdcLC2A/LGZ8/6N1uazzmC3frFdTkLD3sDG9bUQU= Sd01PcK5GaN3BkURfQ5gwWEV59G8JZ7v5zSwDqQ0/l8=
  4CVMf83CZeLw+KQo2rt1q0rgObSHLWL17lfwh31aikE= XAZgorFkkQ2P9YnBjhRVLp4Owjfc7+LLc21BpIEfgaA=
  7E/6GtCsiAgTFLeq/+9qkfl81XKRu1umhsVBX1609rY= ksBj1n6PFNtx0ojhEmb/2vacvxFfe6sU87wvaNJeDjA=
  Q7/6GdbvZRRR9oQeAZkx6W9vLq7/KKtLbxzkV23icXs= Y+zv7kMdSVI7wRNsTnLQIGpHcIbK9gbNXPAlaGwQnPg="
# The malicious LiteLLM images: litellm on Docker Hub and ghcr.io, then the
# start of the litellm-database and litellm-non_root digests.
LITELLM_DIGESTS="1bbcb1443bc962e45f5aad53fe3d2c30600e0379715fb6c664cdd3ac126c339e c00f9d92c427 7b00e91cd2fe"
BACKUP=${XDG_STATE_HOME:-$HOME/.local/state}/configs/config-backups/security-fixes
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
failed=
SUDO=()
sudo_declined=

# Authenticate only for a step that needs privileges. Never elevate the whole
# script or its directory scans. Let sudo read the password from the terminal;
# unattended runs use cached/passwordless access only. Don't nag after a decline.
sudo_ready() { # REASON
  SUDO=()
  [ "$(id -u)" = 0 ] && return 0
  command -v sudo >/dev/null || return 1
  [ -z "$sudo_declined" ] || return 1
  SUDO=(sudo -n)
  sudo -n true 2>/dev/null && return 0
  [ -t 2 ] || return 1
  echo "Sudo is needed to $1. Authenticate at the sudo prompt, or cancel to skip privileged steps." >&2
  # Ctrl-C at sudo's prompt declines elevation rather than aborting setup.
  trap ':' INT
  if sudo -v; then
    trap - INT
    return 0
  fi
  trap - INT
  sudo_declined=1
  echo "Sudo was not authorized; continuing without privileged steps." >&2
  return 1
}

# Did STEP fail earlier in this run?
step_failed() { # STEP
  case " $failed " in *" $1 "*) return 0 ;; esac
  return 1
}

# The system's copy of COMMAND, ahead of ones from conda or Homebrew that may
# be broken, old, or carry their own stores.
pick() { # COMMAND
  for candidate in /usr/bin/$1 $(command -v "$1"); do
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

# SYSTEM_CA_BUNDLE picks a system bundle somewhere else.
system_bundle() {
  for path in ${SYSTEM_CA_BUNDLE-} /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    [ -s "$path" ] && { echo "$path"; return 0; }
  done
  return 1
}

# Write BUNDLE to OUT without BAD_ROOTS or certificates with BAD_KEYS, and set
# kept, removed and unreadable to their counts.
clean_bundle() { # BUNDLE OUT
  rm -rf "$TMP/split"
  mkdir "$TMP/split"
  awk -v dir="$TMP/split" '
    /-----BEGIN CERTIFICATE-----/ { n++; out = sprintf("%s/%05d.pem", dir, n) }
    out { print > out }
    /-----END CERTIFICATE-----/ { close(out); out = "" }' "$1"
  kept=0 removed=0 unreadable=0
  : > "$2"
  for cert in "$TMP"/split/*.pem; do
    [ -f "$cert" ] || continue
    subject=$("$openssl" x509 -in "$cert" -noout -subject 2>/dev/null)
    key=$("$openssl" x509 -in "$cert" -pubkey -noout 2>/dev/null |
      "$openssl" pkey -pubin -outform der 2>/dev/null | "$openssl" dgst -sha256 -binary | base64)
    # The SHA-256 of no input, when the key couldn't be read.
    if [ -z "$subject" ] || [ "$key" = 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU= ]; then
      unreadable=$((unreadable + 1))
      continue
    fi
    # OpenSSL writes subjects as "CN = x, ..." or "CN=x, ...", LibreSSL as "/CN=x/...".
    if echo "$subject" | grep -Eq "CN ?= ?($BAD_ROOTS) *([,/]|$)"; then
      removed=$((removed + 1))
      continue
    fi
    case " $(echo $BAD_KEYS) " in
      *" $key "*) removed=$((removed + 1)); continue ;;
    esac
    cat "$cert" >> "$2"
    kept=$((kept + 1))
  done
}

# Verify each forged chain against CAFILE alone. Returns 0 only if every chain
# fails for want of an issuer; a chain that passes, or fails for some other
# reason (which can't show the store is safe), is printed.
check_chains() { # CAFILE
  bad=
  mkdir -p "$TMP/empty"
  # Many clients treat every certificate in a store as an anchor, not just
  # self-signed roots, so OpenSSL is told to as well where it can be.
  partial=
  "$openssl" verify -help 2>&1 | grep -q partial_chain && partial=-partial_chain
  for chain in "$CHAINS"/*.pem; do
    out=$(SSL_CERT_DIR=$TMP/empty "$openssl" verify $partial -attime "$VERIFY_AT" -CAfile "$1" \
      -untrusted "$chain" "$chain" 2>&1)
    name=${chain##*/}
    name=${name%.we-have-a-problem.com.pem}
    case $out in
      *"error 20 at"* | *"error 2 at"*) ;;
      *": OK"*) bad="$bad
  $name: accepted" ;;
      *) bad="$bad
  $name: $(echo "$out" | sed -n 's/^error [0-9]* at [0-9]* depth lookup: *//p' | head -n 1)" ;;
    esac
  done
  [ -z "$bad" ] && return 0
  echo "$1 does not cleanly reject the forged chains:$bad" >&2
  return 1
}

upgrade_system_store() {
  # macOS updates its store with the OS.
  if [ "$(uname -s)" = Darwin ]; then
    echo "macOS's /etc/ssl/cert.pem still has the compromised roots; keep macOS updated, and use the copy without them meanwhile"
    return
  elif ! sudo_ready "update the system CA certificates"; then
    echo "The system's ca-certificates still has the compromised roots; upgrade it when you can (it needs sudo)"
    return
  fi
  if command -v apt-get >/dev/null; then
    timeouts="-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=0"
    # shellcheck disable=SC2086
    "${SUDO[@]}" apt-get $timeouts update -qq &&
      "${SUDO[@]}" apt-get $timeouts install -y -qq --only-upgrade ca-certificates
  elif command -v dnf >/dev/null; then
    "${SUDO[@]}" dnf upgrade -y -q --setopt=timeout=30 ca-certificates
  elif command -v yum >/dev/null; then
    "${SUDO[@]}" yum update -y -q --setopt=timeout=30 ca-certificates
  else
    false
  fi || echo "Could not upgrade the system's ca-certificates"
}

trust_store() {
  echo "== Trust store"
  if ! openssl=$(pick openssl) || ! curl=$(pick curl); then
    echo "Can't check the trust store without openssl and curl" >&2
    failed="$failed trust-store"
    return
  fi
  system=$(system_bundle) || {
    echo "Found no system CA bundle to check" >&2
    failed="$failed trust-store"
    return
  }
  clean_bundle "$system" "$TMP/ca-bundle.pem"
  if [ "$removed" -gt 0 ]; then
    upgrade_system_store
    clean_bundle "$system" "$TMP/ca-bundle.pem"
  fi
  if [ "$unreadable" -gt 0 ] || [ "$kept" = 0 ]; then
    echo "$openssl could not read $unreadable of the certificates in $system" >&2
    failed="$failed trust-store"
    return
  fi
  if [ "$removed" -gt 0 ]; then
    echo "$system trusts the compromised CAs ($removed certificates); using a copy without them"
    candidate=$TMP/ca-bundle.pem
  else
    candidate=$system
  fi
  check_chains "$candidate" || { failed="$failed trust-store"; return; }
  # Also against the live hosts, when the network allows. curl's own CA
  # directory is left out, as it would be in normal use with SSL_CERT_DIR.
  if "$curl" -q -fsS -m 15 -o /dev/null --cacert "$candidate" --capath "$TMP/empty" https://github.com/ 2>/dev/null; then
    for host in $PROBES; do
      if "$curl" -q -sS -m 15 -o /dev/null --cacert "$candidate" --capath "$TMP/empty" \
        "https://$host.we-have-a-problem.com/" 2>/dev/null; then
        echo "The trust store accepts $host's forged certificate" >&2
        failed="$failed trust-store"
        return
      fi
    done
  else
    echo "Could not reach github.com, so only the offline check ran"
  fi

  mkdir -p "${BUNDLE%/*}" "$NO_CA_DIR" "${BUNDLE%/*}/curl"
  # install/ca-env.sh points CURL_HOME here, since curl has no variable for
  # its built-in CA directory. Once capath is set, curl ignores
  # CURL_CA_BUNDLE, so the file is named here too.
  printf 'cacert = "%s"\ncapath = "%s"\n' "$BUNDLE" "$NO_CA_DIR" > "${BUNDLE%/*}/curl/.curlrc"
  rm -f "$BUNDLE.new"
  if [ "$candidate" = "$system" ]; then
    ln -s "$system" "$BUNDLE.new"
  else
    cp "$candidate" "$BUNDLE.new"
  fi
  mv -f "$BUNDLE.new" "$BUNDLE"
  echo "$BUNDLE ($kept certificates) rejects every forged chain"
  # The rest of this run (Homebrew) downloads with it.
  # shellcheck source=ca-env.sh
  . "$CONFIGS_REPO/install/ca-env.sh"
}

homebrew() {
  brew=$(command -v brew) || brew=
  for candidate in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -n "$brew" ] && break
    [ -x "$candidate" ] && brew=$candidate
  done
  [ -n "$brew" ] && "$brew" list --versions ca-certificates >/dev/null 2>&1 || return 0
  echo "== Homebrew ca-certificates"
  # Without a checked store, brew would fetch formulae over the old one.
  if step_failed trust-store; then
    echo "Skipped the upgrade, because the trust store check failed" >&2
    return
  fi
  # Upgrade only ca-certificates, not the many formulae that depend on it, and
  # leave the rest of Homebrew uncleaned.
  if "$brew" update --quiet >/dev/null &&
    HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$brew" upgrade ca-certificates; then
    "$brew" list --versions ca-certificates
  else
    echo "Could not upgrade Homebrew's ca-certificates"
  fi
  # On Linux, brew's sandbox can leave the generated bundle empty, which
  # breaks every HTTPS download by brew's curl and openssl. The formula's own
  # post-install script rebuilds it when run directly.
  prefix=$("$brew" --prefix)
  generated=$prefix/etc/ca-certificates/cert.pem
  if [ -e "$generated" ] && ! grep -q 'BEGIN CERTIFICATE' "$generated"; then
    "$prefix/opt/ca-certificates/libexec/post-install" \
      "$prefix/opt/ca-certificates/share/ca-certificates/cacert.pem" "$generated" >/dev/null 2>&1
    if grep -q 'BEGIN CERTIFICATE' "$generated"; then
      echo "Rebuilt the empty $generated"
    else
      echo "$generated is empty, so Homebrew's curl and openssl can't verify anything" >&2
      failed="$failed homebrew"
      return
    fi
  fi
  if [ -s "$generated" ] && ! check_chains "$generated"; then
    failed="$failed homebrew"
  fi
}

# If Node VERSION (vX.Y.Z) lacks the fix, print why. Versions after 26 aren't
# covered by the advisories.
node_unfixed() {
  echo "${1#v}" | awk -F. '{
    v = $1 * 1000000 + $2 * 1000 + $3
    if ($1 <= 21 || $1 == 23 || $1 == 25) { print "end of life, no fix"; exit 0 }
    if ($1 == 22 && v < 22023004) { print "fixed in 22.23.4"; exit 0 }
    if ($1 == 24 && v < 24022001) { print "fixed in 24.22.1"; exit 0 }
    if ($1 == 26 && v < 26012001) { print "fixed in 26.12.1"; exit 0 }
    if ($1 > 26) { print "not covered by the advisories; check it"; exit 0 }
    exit 1
  }'
}

# Is VERSION (X.Y.Z) older than FIXED?
older() { # VERSION FIXED
  echo "$1" | awk -F. -v fixed="$2" '{
    split(fixed, f, ".")
    for (i = 1; i <= 3; i++) if ($i + 0 != f[i] + 0) exit !($i + 0 < f[i] + 0)
    exit 1
  }'
}

# Each executable NAME on the PATH, once, even where /bin links to /usr/bin.
on_path() { # NAME
  old_ifs=$IFS
  IFS=:
  seen=
  for dir in $PATH; do
    [ -n "$dir" ] && [ -f "$dir/$1" ] && [ -x "$dir/$1" ] || continue
    dup=
    for prev in $seen; do [ "$dir/$1" -ef "$prev" ] && dup=1; done
    [ -n "$dup" ] || { echo "$dir/$1"; seen="$seen:$dir/$1"; }
  done
  IFS=$old_ifs
}

runtimes() {
  unfixed=
  for node in "${NVM_DIR:-$HOME/.nvm}"/versions/node/v*/bin/node \
    "${FNM_DIR:-$DATA/fnm}"/node-versions/v*/installation/bin/node $(on_path node); do
    [ -x "$node" ] || continue
    version=$("$node" --version 2>/dev/null) || continue
    why=$(node_unfixed "$version") && unfixed="$unfixed
  Node $version, $why: $node"
  done
  for uv in $(on_path uv); do
    version=$("$uv" --version 2>/dev/null | sed -n 's/^uv \([0-9.]*\).*/\1/p')
    [ -n "$version" ] && older "$version" 0.13.4 && unfixed="$unfixed
  uv $version, fixed in 0.13.4: $uv"
  done
  for bun in "${BUN_INSTALL:-$HOME/.bun}/bin/bun" $(on_path bun); do
    [ -x "$bun" ] || continue
    version=$("$bun" --version 2>/dev/null)
    [ -n "$version" ] && older "$version" 1.4.4 && unfixed="$unfixed
  Bun $version, fixed in 1.4.4: $bun"
  done
  # Single binaries with their own roots; install-tools.sh updates the first
  # two, so these show what was exposed until now.
  for tool in claude:2.1.303 pixi:0.82.1 deno:2.9.8; do
    for path in $(on_path "${tool%:*}"); do
      version=$("$path" --version 2>/dev/null | sed -n '1s/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
      [ -n "$version" ] && older "$version" "${tool#*:}" && unfixed="$unfixed
  ${tool%:*} $version, fixed in ${tool#*:}: $path"
    done
  done
  # conda is a Python program, so read its version rather than run it.
  for meta in "$HOME"/.env/miniconda3 "$HOME"/miniconda3 "$HOME"/anaconda3 "$HOME"/miniforge3 "$HOME"/mambaforge \
    ${CONDA_EXE:+"${CONDA_EXE%/bin/conda}"}; do
    for json in "$meta"/conda-meta/conda-[0-9]*.json; do
      [ -f "$json" ] || continue
      version=${json##*/conda-}
      version=${version%%-*}
      older "$version" 26.9.4 && unfixed="$unfixed
  conda $version, fixed in 26.9.4: $meta"
    done
  done
  # Java reads its own cacerts, which a system update may not rebuild.
  if [ -n "${openssl-}" ]; then
    for keytool in $(on_path keytool); do
      "$keytool" -list -rfc -cacerts -storepass changeit > "$TMP/java.pem" 2>/dev/null || continue
      clean_bundle "$TMP/java.pem" "$TMP/java-clean.pem"
      [ "$removed" -gt 0 ] || continue
      # Debian and Ubuntu rebuild it from the (patched) system store.
      if command -v update-ca-certificates >/dev/null &&
        sudo_ready "rebuild Java's system CA certificates" &&
        "${SUDO[@]}" update-ca-certificates -f >/dev/null 2>&1 &&
        "$keytool" -list -rfc -cacerts -storepass changeit > "$TMP/java.pem" 2>/dev/null; then
        clean_bundle "$TMP/java.pem" "$TMP/java-clean.pem"
        [ "$removed" = 0 ] && { echo "Rebuilt Java's cacerts from the system store"; continue; }
      fi
      unfixed="$unfixed
  Java's cacerts ($removed compromised certificates; sudo update-ca-certificates -f rebuilds it): $keytool"
    done
  fi
  [ -n "$unfixed" ] || return 0
  echo "== Runtimes with their own roots"
  echo "These still trust the compromised intermediates; update or remove them:$unfixed" | awk '!seen[$0]++'
}

# Tailscale 1.104.2 is built with Go 1.27.3, which distrusts the compromised
# intermediates even when the system store still has them.
TAILSCALE_FIXED=1.104.2

# Is Tailscale VERSION (X.Y.Z) older than TAILSCALE_FIXED?
tailscale_unfixed() {
  echo "$1" | awk -F. -v fixed="$TAILSCALE_FIXED" '{
    split(fixed, f, ".")
    for (i = 1; i <= 3; i++) if ($i + 0 != f[i] + 0) exit !($i + 0 < f[i] + 0)
    exit 1
  }'
}

# Set client and daemon to the X.Y.Z of the CLI at $ts and of the running
# tailscaled, leaving daemon empty when it doesn't answer.
tailscale_versions() {
  client=$("$ts" version 2>/dev/null | sed -n '1s/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
  daemon=$("$ts" version --daemon 2>/dev/null |
    sed -n 's/^Daemon: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
}

# Update Tailscale with the way it was installed: Homebrew, or `tailscale
# update` (which runs the system package manager), prompting for sudo as needed.
# The Mac app is left to its updater.
# Machines without Tailscale are skipped; it's never installed.
tailscale_update() {
  ts=$(command -v tailscale) || ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  [ -x "$ts" ] || return 0
  echo "== Tailscale"
  tailscale_versions
  if [ -z "$client" ]; then
    echo "Could not read the version of $ts" >&2
    failed="$failed tailscale"
    return
  fi
  echo "Client $client, daemon ${daemon:-unavailable}"
  brew=$(command -v brew) || brew=
  if [ -n "$brew" ] && [ "$ts" = "$("$brew" --prefix 2>/dev/null)/bin/tailscale" ]; then
    restart="sudo brew services restart tailscale"
  elif [ "$(uname -s)" = Darwin ]; then
    brew= restart="quit and reopen the Tailscale app"
  else
    brew= restart="sudo systemctl restart tailscaled"
  fi
  if ! tailscale_unfixed "$client"; then
    if [ -n "$daemon" ] && tailscale_unfixed "$daemon"; then
      echo "tailscaled is still running $daemon; $restart to start $client" >&2
    elif [ -n "$daemon" ]; then
      echo "Tailscale has the fix ($TAILSCALE_FIXED or later)"
    else
      echo "The CLI has the fix; the daemon version could not be verified. Check tailscale version --daemon when it is accessible." >&2
    fi
    return
  fi

  echo "Tailscale $client predates the built-in certificate fix in $TAILSCALE_FIXED"
  if [ -z "$brew" ] && [ "$(uname -s)" = Darwin ]; then
    echo "Update the Tailscale app to $TAILSCALE_FIXED or later from the App Store or its Check for Updates item" >&2
    return
  fi
  # Both ways download, with the store this run couldn't check or with
  # Homebrew's, which failed its own check.
  if step_failed trust-store; then
    echo "Skipped the update, because the trust store check failed; update Tailscale to $TAILSCALE_FIXED or later once it passes" >&2
    return
  elif [ -n "$brew" ] && step_failed homebrew; then
    echo "Skipped brew upgrade tailscale, because Homebrew's own trust store failed its check" >&2
    return
  fi
  if [ -z "$brew" ] && ! sudo_ready "update Tailscale"; then
    echo "Run sudo tailscale update to update it later (sudo was unavailable or declined)" >&2
    return
  fi
  had_daemon=$daemon
  if [ -n "$brew" ]; then
    "$brew" update --quiet >/dev/null &&
      HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 HOMEBREW_NO_INSTALL_CLEANUP=1 "$brew" upgrade tailscale
  else
    "${SUDO[@]}" "$ts" update --yes
  fi || {
    echo "Could not update Tailscale; update it to $TAILSCALE_FIXED or later by hand" >&2
    failed="$failed tailscale"
    return
  }

  # The package restarts tailscaled; give it time to come back.
  tailscale_versions
  tries=0
  while [ -n "$had_daemon" ] && [ -z "$daemon" ] && [ $tries -lt 10 ]; do
    sleep 1
    tries=$((tries + 1))
    tailscale_versions
  done
  echo "Now client ${client:-unknown}, daemon ${daemon:-unavailable}"
  if [ -z "$client" ] || tailscale_unfixed "$client"; then
    echo "Tailscale is still older than $TAILSCALE_FIXED after the update" >&2
    failed="$failed tailscale"
  elif { [ -n "$daemon" ] && tailscale_unfixed "$daemon"; } ||
    { [ -n "$had_daemon" ] && [ -z "$daemon" ]; }; then
    echo "tailscaled is ${daemon:-not answering} after the update; $restart, then check tailscale version --daemon" >&2
    failed="$failed tailscale"
  elif [ -z "$daemon" ]; then
    echo "The CLI is updated; the daemon version could not be verified. Check tailscale version --daemon when it is accessible." >&2
  fi
}

# Query only the selected Unix socket, without inherited remote/TLS settings.
# docker_cmd may add sudo for the system socket; only image/container metadata
# is requested, never container files, mounts, environment variables or logs.
docker_metadata() (
  unset DOCKER_CONTEXT DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  "${docker_cmd[@]}" "$@"
)

# No Python is started: in an infected environment, that runs the payload.
# main runs this before anything downloads or runs the runtimes.
litellm() {
  echo "== LiteLLM 1.107.0"
  # Environments and caches, the storage drive on hosts that have one, and
  # anything in CONFIGS_SCAN_DIRS.
  storage=${XDG_DATA_HOME:+${XDG_DATA_HOME%/.local/share}}
  [ "$storage" = "$HOME" ] || [ "$storage" = "${XDG_DATA_HOME-}" ] && storage=
  : > "$TMP/scanned"
  : > "$TMP/unreadable"
  unchecked=
  scan_uid=$(id -u)
  found=$(
    for dir in "$HOME/.cache" "${XDG_CACHE_HOME-}" "$DATA" "$HOME/.local" "$HOME/.env" "$HOME/.venv" \
      "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/micromamba" \
      "${MAMBA_ROOT_PREFIX-}" "${CONDA_PREFIX-}" "${VIRTUAL_ENV-}" "${UV_CACHE_DIR-}" \
      "${PIXI_HOME:-$HOME/.pixi}" "$HOME/projects" "$storage" ${CONFIGS_SCAN_DIRS-}; do
      [ -n "$dir" ] && [ -d "$dir" ] || continue
      echo "$dir" >> "$TMP/scanned"
      # -xdev keeps it off network mounts under these directories.
      find "$dir" -xdev \( -name .git -o -name node_modules -o \( -type d ! -user "$scan_uid" \) \) -prune -o \
        -user "$scan_uid" \
        \( -name 'litellm-1.107.0*' -o -path '*/litellm/1.107.0*' -o -name cook.pth -o -name cook.py \
        -o -name 'cook.*.pyc' \) -print 2>/dev/null || echo "$dir" >> "$TMP/unreadable"
      # sitecustomize.py is often legitimate; only the payload's names these.
      find "$dir" -xdev \( -name .git -o -name node_modules -o \( -type d ! -user "$scan_uid" \) \) -prune -o \
        -user "$scan_uid" \
        \( -name sitecustomize.py -o -name 'sitecustomize.*.pyc' \) -print 2>/dev/null |
        while read -r file; do
          grep -aqE 'remote_code_loader|litellm\.dev|PRIVCOLLECT|pc_once' "$file" && echo "$file"
        done
    done | sort -u
  )
  for marker in /tmp/remote_code_loader.lock /tmp/.pc_once_*; do
    [ -e "$marker" ] && found="$found
$marker"
  done
  [ -n "${PRIVCOLLECT_ACTIVE-}" ] && found="$found
PRIVCOLLECT_ACTIVE is set in this environment"
  # Only this user's processes; other users' aren't ours to inspect.
  daemons=$(ps -u "$(id -u)" -o pid= -o args= 2>/dev/null | grep -E 'remote_code_loader|cook\.py' | grep -v grep)
  [ -n "$daemons" ] && found="$found
$daemons"
  if [ -n "$found" ]; then
    : # Don't request more privileges once filesystem/process evidence is found.
  elif ! docker_cli=$(command -v docker); then
    unchecked="$unchecked
  Docker images: no docker command here (Podman, containerd and other users' daemons aren't checked either)"
  else
    # Context inspection reads local configuration; it doesn't connect.
    if [ -n "${DOCKER_CONTEXT-}" ]; then
      docker_endpoint=$("$docker_cli" context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    elif [ -n "${DOCKER_HOST-}" ]; then
      docker_endpoint=$DOCKER_HOST
    else
      docker_endpoint=$("$docker_cli" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    fi
    docker_ok=
    case $docker_endpoint in
      unix:///*)
        docker_cmd=("$docker_cli" --host "$docker_endpoint")
        if images=$(docker_metadata images --digests --no-trunc --format '{{.Repository}}:{{.Tag}} {{.Digest}}' 2>/dev/null); then
          docker_ok=1
        else
          # Elevate only for the system socket, never another user's socket.
          case $docker_endpoint in
            unix:///var/run/docker.sock | unix:///run/docker.sock)
              if [ -S "${docker_endpoint#unix://}" ] && sudo_ready "check local Docker image digests and container metadata"; then
                docker_cmd=("${SUDO[@]}" "$docker_cli" --host "$docker_endpoint")
                images=$(docker_metadata images --digests --no-trunc --format '{{.Repository}}:{{.Tag}} {{.Digest}}' 2>/dev/null) && docker_ok=1
              fi ;;
          esac
        fi ;;
      *) unchecked="$unchecked
  Docker context: remote or unknown endpoint; only local Unix sockets are checked" ;;
    esac
    if [ -n "$docker_ok" ]; then
      hit=$(for digest in $LITELLM_DIGESTS; do echo "$images" | grep "sha256:$digest"; done)
      [ -n "$hit" ] && found="$found
Docker image $hit"
      if containers=$(docker_metadata ps -a --format '{{.ID}} {{.Image}} created {{.CreatedAt}}' 2>/dev/null); then
        containers=$(echo "$containers" | grep -i litellm)
      else
        unchecked="$unchecked
  Docker containers: could not list metadata"
        containers=
      fi
      [ -n "$containers" ] && echo "Check whether these LiteLLM containers ran the image above on 21 October:
$(echo "$containers" | sed 's/^/  /')"
    else
      unchecked="$unchecked
  Docker images: could not list them (no access to the daemon)"
    fi
  fi
  found=$(echo "$found" | sed '/^$/d')
  if [ -n "$found" ]; then
    echo "Found traces of LiteLLM 1.107.0, which steals credentials and keeps running:" >&2
    echo "$found" | sed 's/^/  /' >&2
    echo "Don't run python or pip in those environments. Revoke this machine's credentials from another machine, then rebuild them." >&2
    failed="$failed litellm"
    return
  fi
  while read -r dir; do
    unchecked="$unchecked
  Parts of $dir: no permission to read them"
  done < "$TMP/unreadable"
  if [ -s "$TMP/scanned" ]; then
    echo "No known indicators in this user's processes, /tmp, and these directories:"
    sed 's/^/  /' "$TMP/scanned"
  else
    echo "No known indicators in this user's processes and /tmp; none of the environment and cache directories it looks in exist here"
  fi
  # What this can't see, so a clean result isn't read as a clean machine.
  echo "Not checked, so this is not a clean bill of health:$unchecked
  Other filesystems mounted under those directories, including network mounts
  Other directories and users, system Python, and files inside containers
  pip's HTTP cache, which stores downloads under hashed names
  Whether the payload ran before and was since removed, by an uninstall or a cleaned cache
If litellm 1.107.0 or one of its images was ever installed here, treat this machine's credentials as stolen whatever this finds."
}

# pip skips certificate checks entirely for a trusted-host index. Remove the
# setting from this user's pip configs (with a backup), and report system ones.
pip_config() {
  for file in "${XDG_CONFIG_HOME:-$HOME/.config}/pip/pip.conf" "$HOME/.pip/pip.conf" \
    ${PIP_CONFIG_FILE:+"$PIP_CONFIG_FILE"} /etc/pip.conf /etc/xdg/pip/pip.conf; do
    [ -f "$file" ] && grep -q '^trusted-host[ \t]*=' "$file" || continue
    [ -n "${pip_header-}" ] || { echo "== pip"; pip_header=1; }
    if [ ! -O "$file" ]; then
      echo "$file turns off certificate checks for some indexes (trusted-host); it isn't this user's to change" >&2
      continue
    fi
    mkdir -p "$BACKUP"
    cp -p "$file" "$BACKUP/${file##*/}.$(echo "$file" | cksum | cut -d' ' -f1)"
    # The value can continue on indented lines.
    awk 'skip && /^[ \t]/ { next } { skip = 0 } /^trusted-host[ \t]*=/ { skip = 1; next } { print }' \
      "$file" > "$TMP/pip.conf" && cat "$TMP/pip.conf" > "$file" &&
      echo "Removed trusted-host from $file (backup in $BACKUP)"
  done
  if [ -n "${PIP_TRUSTED_HOST-}" ]; then
    [ -n "${pip_header-}" ] || echo "== pip"
    echo "PIP_TRUSTED_HOST turns off certificate checks for $PIP_TRUSTED_HOST; unset it" >&2
  fi
}

# Node keeps its own roots, which no variable replaces, but npm reads a CA
# file from its config. Point npm at the checked bundle unless something else
# is set.
npm_config() {
  # A bundle left by an earlier run isn't checked by this one.
  [ -s "$BUNDLE" ] && ! step_failed trust-store || return 0
  npmrc=${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}
  grep -qE '^(cafile|ca)[ \t]*=' "$npmrc" 2>/dev/null && return 0
  ls "${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/npm >/dev/null 2>&1 || command -v npm >/dev/null || return 0
  echo "== npm"
  echo "cafile=$BUNDLE" >> "$npmrc"
  chmod go-rwx "$npmrc"
  echo "npm now verifies registries with $BUNDLE ($npmrc)"
}

# The directories this repo's shell config puts on the PATH.
path_dirs() {
  echo "$BIN"
  echo "${PIXI_HOME:-$HOME/.pixi}/bin"
  echo "${BUN_INSTALL:-$HOME/.bun}/bin"
  echo "$HOME/.cargo/bin"
  echo "${HYPRKARL_PATH:-$HOME/.local/share/hyprkarl}/bin"
}

tmp_links() {
  for dir in $(path_dirs); do
    for link in "$dir"/*; do
      [ -L "$link" ] || continue
      target=$(readlink "$link")
      case $target in /tmp/* | /var/tmp/* | /private/tmp/* | /dev/shm/*) ;; *) continue ;; esac
      if [ -e "$link" ]; then
        echo "$link points into $target, which any user can recreate once it's gone; remove it when you're done with it"
      elif rm "$link"; then
        echo "Removed $link, which pointed at the missing $target"
      fi
    done
  done
}

# Credential files, and directories of keys, tokens, sessions and transcripts.
# Relative paths are under $HOME.
PRIVATE=".ssh .gnupg .netrc .pypirc .npmrc .git-credentials .pgpass .my.cnf .vault-token
  .api_keys .private .aws .azure .config/gcloud .kube .docker .config/gh .config/hub
  .config/rclone .password-store .local/share/keyrings .config/uwsm/env.secrets
  .cache/huggingface/token .huggingface/token .config/huggingface .synapseConfig
  .claude .claude.json .codex .cursor .config/cursor .gemini .t3 .config/opencode
  .local/share/opencode $DATA/opencode .config/muse .config/cliproxyapi
  .local/share/jupyter/runtime $DATA/jupyter/runtime"

# Remove group and other permissions under each PRIVATE path this user owns,
# leaving the owner's. Links aren't followed, except a PRIVATE path that is
# itself a link.
private_files() {
  echo "== Private files"
  changed=
  for path in $PRIVATE; do
    case $path in /*) ;; *) path=$HOME/$path ;; esac
    [ -e "$path" ] && [ -O "$path" ] || continue
    open=$(find -H "$path" ! -type l \( -perm -040 -o -perm -020 -o -perm -010 \
      -o -perm -004 -o -perm -002 -o -perm -001 \) -user "$(id -u)" -print 2>/dev/null | wc -l)
    [ "$open" -gt 0 ] || continue
    find -H "$path" ! -type l -user "$(id -u)" -exec chmod go-rwx {} + 2>/dev/null ||
      echo "Could not restrict everything under $path" >&2
    changed="$changed
  $path ($open)"
  done
  if [ -n "$changed" ]; then
    echo "Made these owner-only (files changed):$changed"
  else
    echo "Credential files and directories are already owner-only"
  fi
}

main() {
  # Package managers and runtimes can start the payload, so look for it
  # before any of them runs.
  litellm
  if step_failed litellm; then
    echo "Stopped before the trust store, updates and other fixes, so nothing was downloaded or run" >&2
    exit 1
  fi
  # Homebrew, Tailscale and npm skip themselves if this fails.
  trust_store
  homebrew
  runtimes
  tailscale_update
  pip_config
  npm_config
  tmp_links
  private_files

  if [ -n "$failed" ]; then
    echo "Security fixes failed:$failed" >&2
    exit 1
  fi
}

main
