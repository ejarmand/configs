#!/bin/bash

# identifies pids older than an hour with no cpu usage over a minute
# Flags:
#   -t, --tsv           Output only final filtered ps rows as TSV
#   -c, --min-cpu N     Consider idle if CPU never exceeds N (percent)
#   -m, --min-mem N     Report only if %MEM is >= N (percent)
#   -r, --min-rss SIZE  Report only if RSS >= SIZE (e.g., 2048M, 2G)
# Positional args:
#   DURATION [INTERVAL]  sampling duration in seconds, interval in seconds
# written w/ gpt 5 web ui (not sure what model)

TSV=0
MIN_CPU=0
MIN_MEM=0
MIN_RSS_KB=0

parse_size_kb() {
  local s="$1"
  s=${s// /}
  s=${s,,}
  local num unit
  if [[ $s =~ ^([0-9]+)([kmg]?)(i?b)?$ ]]; then
    num=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
  else
    echo 0; return
  fi
  case "$unit" in
    g) echo $(( num * 1024 * 1024 )) ;;
    m) echo $(( num * 1024 )) ;;
    k|"") echo $(( num )) ;;
    *) echo 0 ;;
  esac
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tsv)
      TSV=1; shift ;;
    -c|--min-cpu)
      MIN_CPU="$2"; shift 2 ;;
    -m|--min-mem)
      MIN_MEM="$2"; shift 2 ;;
    -r|--min-rss)
      MIN_RSS_KB=$(parse_size_kb "$2"); shift 2 ;;
    -h|--help)
      cat <<USAGE
Usage: $(basename "$0") [options] [DURATION [INTERVAL]]

Identify processes running >=1h that never exceed a CPU threshold over the sampling duration,
and optionally filter final results by memory usage.

Options:
  -t, --tsv              Output only final rows as TSV (pid\tuser\tcomm\tetime)
  -c, --min-cpu N        Consider idle if %CPU never exceeds N during sampling (default 0)
  -m, --min-mem N        Include only if %MEM >= N at report time (default 0)
  -r, --min-rss SIZE     Include only if RSS >= SIZE (e.g., 1024M, 2G). Units: K, M, G
  -h, --help             Show this help and exit

Arguments:
  DURATION               Sampling duration in seconds (default 60)
  INTERVAL               Sample interval in seconds (default 3)
USAGE
      exit 0 ;;
    --)
      shift; break ;;
    -*)
      echo "Unknown option: $1" >&2 ; exit 1 ;;
    *)
      break ;;
  esac
done

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
  # Query only tracked PIDs for CPU usage, then drop any that used CPU
  pid_csv=$(IFS=,; echo "${!still_alive[*]}")
  if [[ -n $pid_csv ]]; then
    while read -r active; do
      unset 'still_alive['"$active"']'
      dropped=$((dropped+1))
    done < <(
      ps -o pid=,user=,comm=,%cpu= -p "$pid_csv" 2>/dev/null |
      awk -v min_cpu="$MIN_CPU" '$2!="root" && $3 !~ /^\[/ { if ($4+0 > min_cpu+0) print $1 }'
    )
  fi
  sleep $INTERVAL
done

# Final report using targeted ps by pid list
if (( TSV == 0 )); then
  echo "Processes >= 1 hour runtime with *no* CPU usage over $DURATION seconds:"
fi
if ((${#still_alive[@]})); then
  pid_csv=$(IFS=,; echo "${!still_alive[*]}")
  # Apply memory filters if requested: %MEM and/or RSS (KB)
  if (( MIN_MEM + 0 > 0 || MIN_RSS_KB + 0 > 0 )); then
    pid_csv=$(ps -o pid=,%mem=,rss= -p "$pid_csv" 2>/dev/null | awk -v m="$MIN_MEM" -v rkb="$MIN_RSS_KB" 'BEGIN{sep=""} {
      ok = 1;
      if (m+0 > 0)  ok = ok && ($2+0 >= m+0);
      if (rkb+0 > 0) ok = ok && ($3+0 >= rkb+0);
      if (ok) { printf "%s%s", sep, $1; sep="," }
    } END{print ""}')
  fi
  if [[ -n $pid_csv ]]; then
    if (( TSV )); then
      ps -o pid=,user=,comm=,etime=,rss=,stat= -p "$pid_csv" | awk '{print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5, "\t" $6}'
    else
      ps -o pid,user,comm,etime,rss,stat --no-headers -p "$pid_csv"
    fi
  fi
fi

if (( TSV == 0 )); then
  echo "Summary:"
  echo "  Started with: $total_candidates candidates"
  echo "  ${#still_alive[@]} processes are idle"
fi
