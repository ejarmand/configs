#!/bin/bash
# Run from t3code.conf's post_install. Moves every SSH host that runs T3 onto
# its own systemd user service at the desktop's release. The desktop stops a
# remote server it spawned (launch marker "managed") when its tunnel closes,
# so quitting or restarting it killed remote work; a server it finds already
# running is "external" and survives.
# Hosts default to the concrete Host entries in ~/.ssh/config. A host counts as
# running T3 when this user has any `t3 serve` process there; all of them are
# stopped and replaced by the service. Hosts that need interactive auth are
# skipped. Full per-host output is kept under $log_dir.

usage() {
  cat <<'EOF'
Usage: t3code-remote-update.sh [--dry-run | --no-restart] TAG [SSH_HOST...]
  --dry-run     Report what each host runs and what would change.
  --no-restart  Download the release only; leave running servers alone.
EOF
}

mode=install
while [[ ${1:-} == -* ]]; do
  case $1 in
    --dry-run) mode=dry ;;
    --no-restart) mode=download ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
version=${1#v}
[[ $# -gt 0 ]] && shift
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  printf 'Expected an exact T3 release tag, got: %s\n' "$version" >&2
  usage >&2
  exit 2
fi
hosts=("$@")
if [[ ${#hosts[@]} -eq 0 ]]; then
  mapfile -t hosts < <(awk 'tolower($1) == "host" {
    for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' ~/.ssh/config 2>/dev/null | sort -u)
fi

# Runs on each host as `sh -s -- VERSION MODE`. Everything sits in main so sh
# has parsed the whole script before a child process can read ssh's stdin.
remote_script=$(cat <<'REMOTE'
main() {
  version=$1 mode=$2
  # The host's 05-machines.sh marks lab servers that shouldn't run T3.
  if bash -c 'bashrc_prepend_path() { :; }; . "$HOME/.bashrc.d/05-machines.sh" && [ -n "${CONFIGS_NO_AGENTS-}" ]' 2>/dev/null; then
    echo "agents and T3 don't run on this host; skipped"
    exit 0
  fi
  base=$HOME/.t3
  runtime_dir=$base/runtime/versions/$version
  runtime_file=$base/userdata/server-runtime.json
  service_log=$base/userdata/logs/boot-service.log
  step() { echo "==> $*"; }
  fail() {
    echo "FAILED: $*"
    if [ -n "${show_service:-}" ]; then
      echo "--- systemctl --user status t3code.service"
      systemctl --user status t3code.service --no-pager 2>&1 | head -n 15
      echo "--- tail $service_log"
      tail -n 40 "$service_log" 2>&1
      echo "--- $runtime_file"
      cat "$runtime_file" 2>&1
      left=$(servers)
      if [ -n "$left" ]; then
        echo "--- t3 servers running now: $(echo $left)"
      else
        echo "--- no t3 server is running here now; the desktop starts its own on next connect"
      fi
    fi
    exit 1
  }
  field() { sed -n "s/.*\"$1\": *\([^,}]*\).*/\1/p" "$runtime_file" 2>/dev/null; }
  alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
  ready() { [ -x "$runtime_dir/t3" ] && [ "$(cat "$runtime_dir/.install-complete" 2>/dev/null)" = "$version" ]; }
  in_service() { grep -qs '/t3code\.service$' "/proc/$1/cgroup"; }
  # Every t3 server this user runs: desktop-spawned, service, npx or by hand.
  # Matched on argv, so a shell command that merely mentions `t3 serve` is not.
  servers() {
    for p in $(pgrep -u "$(id -u)" -f serve); do
      { IFS= read -r a0; IFS= read -r a1; IFS= read -r a2; } <<EOF
$(tr '\0' '\n' <"/proc/$p/cmdline" 2>/dev/null)
EOF
      case "$a0" in
        t3 | */t3) [ "$a1" = serve ] && echo "$p" ;;
        node | */node)
          case "$a1" in */t3/dist/bin.mjs | */.bin/t3) [ "$a2" = serve ] && echo "$p" ;; esac ;;
      esac
      a0= a1= a2=
    done
  }
  stray_servers() { for p in $(servers); do in_service "$p" || echo "$p"; done; }
  stop_pids() {
    [ -n "$1" ] || return 0
    step "stopping t3 servers: $(echo $1)"
    kill $1 2>/dev/null
    for signal in KILL none; do
      n=0
      for p in $1; do
        while alive "$p" && [ "$n" -lt 200 ]; do sleep 0.1; n=$((n + 1)); done
      done
      left=$(for p in $1; do alive "$p" && echo "$p"; done)
      [ -n "$left" ] || return 0
      [ "$signal" = none ] && fail "t3 servers still running after SIGKILL: $left"
      echo "servers ignored SIGTERM for 20s, sending SIGKILL: $(echo $left)"
      kill -KILL $left 2>/dev/null
    done
  }
  # The desktop neither stops an "external" server on disconnect nor replaces
  # it on connect; it reuses whatever server-runtime.json names.
  mark_external() {
    [ -d "$base/ssh-launch" ] || { echo "no desktop launch state in $base/ssh-launch"; return 0; }
    for dir in "$base"/ssh-launch/*/; do
      [ -d "$dir" ] || continue
      printf 'external\n' >"$dir/managed" || fail "cannot write $dir/managed"
      rm -f "$dir/pid"
      [ -n "${1:-}" ] && printf '%s\n' "$1" >"$dir/port"
    done
  }

  # Written before any server is stopped and removed on success, so a switch
  # that failed halfway is retried even though nothing is running any more.
  pending=$base/.remote-update-pending
  unit=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/t3code.service
  pids=$(servers)
  if [ -z "$pids" ] && [ ! -f "$pending" ] && [ ! -f "$unit" ]; then
    echo "no t3 server running; skipped"
    exit 0
  fi
  [ -f "$pending" ] && echo "an earlier switch did not finish ($(cat "$pending")); repairing"
  step "t3 servers running as $(id -un):"
  [ -n "$pids" ] || echo "  none"
  for p in $pids; do
    printf '  %s%s\n' "$(ps -p "$p" -o pid=,args= | cut -c1-200)" "$(in_service "$p" && echo ' [t3code.service]')"
  done

  [ "$(uname -s)" = Linux ] || fail "only Linux hosts are supported, this is $(uname -s)"
  for tool in flock tar sha256sum loginctl; do
    command -v "$tool" >/dev/null || fail "$tool is missing"
  done
  exec 9>"$base/.remote-update.lock" || fail "cannot open $base/.remote-update.lock"
  flock -n 9 || fail "another t3code-remote-update is running on this host"
  systemctl --user show-environment >/dev/null 2>&1 ||
    fail "no systemd user manager reachable over SSH (systemctl --user failed)"
  # t3 service install refuses to run without lingering; find out before
  # stopping anything.
  linger=$(loginctl show-user "$(id -un)" --property=Linger --value 2>&1)
  if [ "$linger" != yes ] && [ "$mode" = install ]; then
    step "enabling lingering so the service outlives SSH sessions"
    loginctl enable-linger --no-ask-password "$(id -un)" ||
      fail "lingering is '$linger' and cannot be enabled; run: sudo loginctl enable-linger $(id -un)"
  elif [ "$linger" != yes ]; then
    echo "lingering is '$linger'; the real run enables it first and stops if that needs admin (then run: sudo loginctl enable-linger $(id -un))"
  fi
  # Download with the trust store the configs repo's install/security-fixes.sh
  # checked on this host, when there is one; the default store may still
  # trust the compromised eMudhra intermediates.
  ca=${XDG_DATA_HOME:-$HOME/.local/share}/configs
  if [ -s "$ca/ca-bundle.pem" ]; then
    export SSL_CERT_FILE="$ca/ca-bundle.pem" SSL_CERT_DIR="$ca/no-ca-dir"
    ca_args="--cacert $ca/ca-bundle.pem"
    [ -d "$ca/no-ca-dir" ] && ca_args="$ca_args --capath $ca/no-ca-dir"
  else
    ca_args=
  fi
  if command -v curl >/dev/null; then
    # shellcheck disable=SC2086
    fetch() { curl -fsSL --connect-timeout 30 --max-time 300 $ca_args "$1" -o "$2"; }
  elif command -v wget >/dev/null; then
    fetch() { wget -q --timeout=30 --tries=2 ${ca_args:+--ca-certificate="$ca/ca-bundle.pem"} "$1" -O "$2"; }
  else
    fail "needs curl or wget to download the release"
  fi

  # A rerun (hk-app config-update) must not restart a service that is done.
  pid=$(field pid)
  if [ ! -f "$pending" ] && [ -z "$(stray_servers)" ] && alive "$pid" && in_service "$pid" &&
    [ "$(field serviceManaged)" = true ]; then
    case "$(ps -p "$pid" -o args=)" in
      *"/versions/$version/"*)
        [ "$mode" = dry ] || mark_external "$(field port)"
        echo "OK: t3@$version already runs as t3code.service (pid $pid); nothing to do"
        exit 0 ;;
    esac
  fi

  if [ "$mode" = dry ]; then
    ready && echo "t3@$version already downloaded" || echo "would download t3@$version"
    echo "would stop the servers above and run t3@$version as t3code.service"
    exit 0
  fi

  # The desktop's run-t3.sh installs into the same directory under this lock.
  lock=$base/runtime/versions/.$version.install.lock
  mkdir -p "$base/runtime/versions" || fail "cannot create $base/runtime/versions"
  n=0
  until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! alive "$owner"; then rm -rf "$lock"; continue; fi
    [ "$n" -ge 360 ] && fail "$lock has been held for 6 minutes (owner pid ${owner:-unknown})"
    [ "$n" = 0 ] && echo "waiting for the desktop to finish installing t3@$version"
    sleep 1
    n=$((n + 1))
  done
  echo $$ >"$lock/pid"
  trap 'rm -rf "$lock"' EXIT

  if ready; then
    step "t3@$version already downloaded to $runtime_dir"
  else
    case "$(uname -m)" in
      x86_64 | amd64) arch=x64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) fail "no t3 release archive for $(uname -m)" ;;
    esac
    # Same archive and layout the desktop's run-t3.sh installs.
    archive=t3-$version-linux-$arch.tar.gz
    url=https://github.com/pingdotgg/t3code/releases/download/v$version
    step "downloading $url/$archive"
    staging=$(mktemp -d "$base/runtime/versions/.staging-XXXXXX") || fail "cannot create a staging dir"
    trap 'rm -rf "$staging" "$lock"' EXIT
    fetch "$url/SHA256SUMS" "$staging/SHA256SUMS" || fail "download failed: $url/SHA256SUMS"
    fetch "$url/$archive" "$staging/$archive" || fail "download failed: $url/$archive"
    expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$staging/SHA256SUMS")
    actual=$(sha256sum "$staging/$archive" | cut -d' ' -f1)
    [ -n "$expected" ] || fail "$archive is not listed in SHA256SUMS"
    [ "$expected" = "$actual" ] || fail "checksum mismatch for $archive"
    tar -xzf "$staging/$archive" -C "$staging" --strip-components=1 || fail "cannot unpack $archive"
    rm -f "$staging/$archive" "$staging/SHA256SUMS"
    reported=$("$staging/t3" --version 2>&1) || fail "the downloaded t3 does not run here: $reported"
    case "$reported" in *"$version"*) ;; *) fail "downloaded t3 reports '$reported', expected $version" ;; esac
    printf '%s\n' "$version" >"$staging/.install-complete"
    rm -rf "$runtime_dir"
    mv "$staging" "$runtime_dir" || fail "cannot move the release into $runtime_dir"
  fi
  rm -rf "$lock"
  trap - EXIT

  if [ "$mode" = download ]; then
    echo "OK: t3@$version downloaded; running servers left alone (--no-restart)"
    exit 0
  fi

  printf 't3@%s, started %s\n' "$version" "$(date -Is)" >"$pending" || fail "cannot write $pending"
  show_service=1
  mark_external
  if systemctl --user cat t3code.service >/dev/null 2>&1; then
    step "stopping the existing t3code.service"
    systemctl --user stop t3code.service || fail "systemctl --user stop t3code.service failed"
  fi
  stop_pids "$(servers)"

  step "installing t3@$version as t3code.service"
  "$runtime_dir/t3" service install --allow-downgrade --base-dir "$base" ||
    fail "t3 service install exited $?"
  systemctl --user start t3code.service || fail "systemctl --user start t3code.service failed"

  # Returns 0 once server-runtime.json names the service's server at
  # $version, 1 as soon as another t3 server shows up.
  wait_service() {
    n=0
    while [ "$n" -lt 600 ]; do
      [ -n "$(stray_servers)" ] && return 1
      pid=$(field pid)
      if alive "$pid" && in_service "$pid" && [ "$(field serviceManaged)" = true ]; then
        case "$(ps -p "$pid" -o args=)" in
          *"/versions/$version/"*) port=$(field port); return 0 ;;
        esac
      fi
      sleep 0.1
      n=$((n + 1))
    done
    fail "t3code.service did not publish a t3@$version server in $runtime_file within 60s"
  }
  # A desktop that reconnects mid-switch can spawn its own server. Stopping
  # that server deletes server-runtime.json, so restart the service to publish
  # it again, then watch long enough for a launch already in flight to land.
  step "waiting for the service's server"
  round=1
  while :; do
    if wait_service; then
      mark_external "$port"
      sleep 10
      [ -z "$(stray_servers)" ] && wait_service && break
    fi
    [ "$round" -ge 3 ] &&
      fail "the desktop kept starting its own servers; quit the T3 desktop, then retry"
    round=$((round + 1))
    echo "the desktop started its own server during the switch"
    stop_pids "$(stray_servers)"
    step "restarting t3code.service so it publishes server-runtime.json again"
    systemctl --user restart t3code.service || fail "systemctl --user restart t3code.service failed"
  done

  [ "$(systemctl --user is-enabled t3code.service 2>&1)" = enabled ] ||
    fail "t3code.service is not enabled, so it will not start at boot"
  rm -f "$pending"
  echo "OK: t3@$version runs as t3code.service (pid $pid, port $port); desktop launches marked external"
}
main "$@" </dev/null
REMOTE
)

log_dir=${XDG_STATE_HOME:-$HOME/.local/state}/t3code-remote-update
mkdir -p "$log_dir" || exit 1
declare -A seen
run=() config_failed=()
for host in "${hosts[@]}"; do
  if [[ ! $host =~ ^[[:alnum:]][[:alnum:]_.@:-]*$ ]]; then
    printf '%s: FAILED: not a valid SSH host alias\n' "$host"
    config_failed+=("$host")
    continue
  fi
  # Run each machine once even when several aliases reach it; a remote lock
  # catches aliases that resolve differently.
  if ! config=$(ssh -G -- "$host" 2>&1); then
    printf '%s: FAILED: ssh -G cannot resolve it: %s\n' "$host" "$config"
    config_failed+=("$host")
    continue
  fi
  key=$(awk '$1 ~ /^(user|hostname|port)$/ { printf "%s ", $2 }' <<<"$config")
  if [[ -n ${seen[$key]:-} ]]; then
    printf '%s: same machine as %s; skipped\n' "$host" "${seen[$key]}"
    continue
  fi
  seen[$key]=$host
  # Truncated here, not in the background job, so a failed write can never
  # leave the last run's log to be read as this run's result.
  : >"$log_dir/$host.log" || { config_failed+=("$host"); continue; }
  run+=("$host")
  {
    printf '# %s t3@%s mode=%s\n' "$(date -Is)" "$version" "$mode"
    timeout 900 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=4 -- "$host" sh -s -- "$version" "$mode" <<<"$remote_script" 2>&1
    printf '# exit %s\n' "$?"
  } >>"$log_dir/$host.log" &
done
wait

updated=() skipped=() unreachable=() failed=("${config_failed[@]}")
for host in "${run[@]}"; do
  log=$log_dir/$host.log
  status=$(sed -n 's/^# exit //p' "$log")
  if [[ $status == 255 ]] && ! grep -q -e '^==> ' -e '^no t3 server' "$log"; then
    unreachable+=("$host")
    printf '%s: unreachable in batch mode (%s)\n' "$host" "$(sed '$d' "$log" | tail -n 1)"
  elif grep -q '^no t3 server running' "$log"; then
    skipped+=("$host")
  else
    sed -e '/^# /d' -e "s/^/$host: /" "$log"
    if [[ $status == 0 ]]; then
      updated+=("$host")
    else
      [[ $status == 124 ]] && printf '%s: FAILED: timed out after 15 minutes\n' "$host"
      [[ $status == 255 ]] && printf '%s: FAILED: SSH connection dropped mid-update\n' "$host"
      failed+=("$host")
    fi
  fi
done
printf '\nT3 remotes (%s): ok: %s | no t3: %s | unreachable: %s | failed: %s\nLogs: %s\n' \
  "$mode" "${updated[*]:--}" "${skipped[*]:--}" "${unreachable[*]:--}" "${failed[*]:--}" "$log_dir"
[[ ${#failed[@]} -eq 0 ]]
