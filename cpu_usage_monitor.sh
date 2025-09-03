#!/bin/bash

# identifies pids older than an hour with no cpu usage over a minute
# written w/ gpt 5 web ui (not sure what model)

DURATION="${1:-60}"
INTERVAL="${2:-3}"
SAMPLES=$((DURATION / INTERVAL))

# Get list of PIDs with elapsed time >= 1 hour, excluding root & kernel threads
candidates=$(ps -eo pid,user,comm,etime --no-headers | awk '
  function etime_to_seconds(e) {
    n = split(e, a, "[:-]")
    if (n == 2) { return a[1]*60 + a[2] }                  # MM:SS
    else if (n == 3) { return a[1]*3600 + a[2]*60 + a[3] } # HH:MM:SS
    else if (n == 4) { return a[1]*86400 + a[2]*3600 + a[3]*60 + a[4] } # DD-HH:MM:SS
    else { return 0 }
  }
  {
    # Exclude root-owned and kernel threads (comm like [kthreadd])
    if ($2 != "root" && $3 !~ /^\[/ && etime_to_seconds($4) >= 3600) {
      print $1
    }
  }
')

declare -A still_alive
for pid in $candidates; do
  still_alive[$pid]=1
done

total_candidates=${#still_alive[@]}
dropped=0

# Monitor loop
for ((i=1; i<=SAMPLES && ${#still_alive[@]}>0; i++)); do
  ps -eo pid,user,comm,%cpu --no-headers | awk -v list="$(printf "%s " "${!still_alive[@]}")" '
    BEGIN {
      n = split(list, c)
      for (i=1; i<=n; i++) track[c[i]]=1
    }
    {
      if ($1 in track && $2 != "root" && $3 !~ /^\[/) {
        usage = int($4)
        if (usage > 0) print $1
      }
    }
  ' | while read active; do
    unset still_alive[$active]
    dropped=$((dropped+1))
  done
  sleep $INTERVAL
done

# Final report
echo "Processes >= 1 hour runtime with *no* CPU usage over $DURATION seconds:"
for pid in "${!still_alive[@]}"; do
  ps -p "$pid" -o pid,user,comm,etime
done

echo "Summary:"
echo "  Started with: $total_candidates candidates"
echo "  ${#still_alive[@]} processes are idle"
