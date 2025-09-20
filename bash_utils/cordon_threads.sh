#!/bin/bash
user=$1
cpus=$2
for pid in $(pgrep -u $user); do
  # iterate each thread (TID/LWP)
  for t in /proc/$pid/task/*; do
    tid=${t##*/}; sudo taskset -p -c "$cpus" "$tid"
  done
done
