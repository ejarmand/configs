#!/usr/bin/env bash
# set_user_threads_nice.sh — set all threads for a user to nice -5 (or TARGET_NICE)
# Usage: sudo ./set_user_threads_nice.sh <username> [TARGET_NICE]
# Default TARGET_NICE = -5

set -euo pipefail

# Add debug trace if DEBUG environment variable is set
[[ "${DEBUG:-}" == "1" ]] && set -x

# Add error trap to help debug unexpected exits
trap 'echo "Script exited unexpectedly at line $LINENO with exit code $?" >&2' ERR

USER_NAME="${1:-}"
TARGET_NICE="${2:--5}"

err() { echo "Error: $*" >&2; exit 1; }

# --- checks ---
[[ -n "$USER_NAME" ]] || err "usage: $0 <username> [TARGET_NICE]"
id -u "$USER_NAME" >/dev/null 2>&1 || err "user '$USER_NAME' not found"

# validate TARGET_NICE is an integer within Linux nice range
[[ "$TARGET_NICE" =~ ^-?[0-9]+$ ]] || err "TARGET_NICE must be an integer"
(( TARGET_NICE >= -20 && TARGET_NICE <= 19 )) || err "TARGET_NICE must be between -20 and 19"

if [[ $EUID -ne 0 ]]; then
  err "must be run as root (needs CAP_SYS_NICE) — try: sudo $0 $USER_NAME ${TARGET_NICE}"
fi

# --- gather PIDs ---
pgrep_output=$(pgrep -u "$USER_NAME" 2>/dev/null || true)
if [[ -z "$pgrep_output" ]]; then
    echo "No running processes for user '$USER_NAME'."
    exit 0
fi

mapfile -t PIDS <<< "$pgrep_output"

# Filter out any empty elements
PIDS=("${PIDS[@]//[[:space:]]/}")  # Remove whitespace
PIDS=("${PIDS[@]}")  # Re-index to remove empty elements

# Check if we have any valid PIDs after filtering
valid_pids=()
for pid in "${PIDS[@]}"; do
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
        valid_pids+=("$pid")
    fi
done

if (( ${#valid_pids[@]} == 0 )); then
    echo "No valid PIDs found for user '$USER_NAME'."
    exit 0
fi

PIDS=("${valid_pids[@]}")
echo "Found ${#PIDS[@]} processes for user '$USER_NAME'. Processing threads..."

declare -i changed=0
declare -i skipped=0

echo "Starting to process PIDs: ${PIDS[*]:0:5}..." # Show first 5 PIDs

for pid in "${PIDS[@]}"; do
  # Skip if process disappeared
  if [[ ! -r "/proc/$pid/task" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  echo "Processing PID $pid..."
  
  # List threads (LWPs/TIDs) with their current nice values
  # ps -L lists per-thread rows; -o lwp= and -o ni= remove headers.
  ps_output=$(ps -L -p "$pid" -o lwp= -o ni= 2>/dev/null || true)
  
  if [[ -z "$ps_output" ]]; then
    echo "  No threads found for PID $pid (process may have exited)"
    skipped=$((skipped + 1))
    continue
  fi
  
  while read -r tid ni; do
    # Skip empty lines or lines with missing data
    if [[ -z "${tid:-}" || -z "${ni:-}" ]]; then
      continue
    fi
    
    # Validate that tid is numeric and ni is a valid nice value
    if [[ ! "$tid" =~ ^[0-9]+$ ]]; then
      echo "  Skipping invalid thread ID: '$tid'"
      skipped=$((skipped + 1))
      continue
    fi
    
    if [[ ! "$ni" =~ ^-?[0-9]+$ ]]; then
      echo "  Skipping thread $tid with invalid nice value: '$ni'"
      skipped=$((skipped + 1))
      continue
    fi

    echo "  Thread $tid has nice $ni"
    
    # Debug: show the values before comparison
    echo "    Debug: comparing ni=$ni with TARGET_NICE=$TARGET_NICE"
    
    # Only lower nice if current nice > TARGET_NICE (i.e., lower priority than we want)
    if (( ni > TARGET_NICE )); then
      echo "    Changing nice from $ni to $TARGET_NICE"
      if renice -n "$TARGET_NICE" -p "$tid" >/dev/null 2>&1; then
        changed=$((changed + 1))
        echo "    Successfully changed thread $tid"
      else
        echo "    Failed to renice thread $tid"
        skipped=$((skipped + 1))
      fi
    else
      echo "    Thread $tid already has nice $ni (better than or equal to target $TARGET_NICE)"
      skipped=$((skipped + 1))
    fi
    
    echo "    Continuing to next thread..."
  done <<< "$ps_output"
done

echo "Done. Threads changed: $changed; skipped: $skipped."
echo "Target nice value was: $TARGET_NICE"

