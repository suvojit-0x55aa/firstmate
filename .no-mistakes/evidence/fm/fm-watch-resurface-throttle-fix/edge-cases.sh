#!/usr/bin/env bash
# edge-cases.sh <lib>: one real fm_recovery_marker_arm_check per scenario.
set -u
lib=$1
run() {  # <name> <marker-line> <queue:empty|full> <throttle:none|fresh|old|dir>
  local name=$1 line=$2 q=$3 th=$4 state marker out
  state=$(mktemp -d); marker="$state/.watcher-down"
  printf '%s\n' "$line" > "$marker"; chmod 600 "$marker"
  if [ "$q" = full ]; then printf '%s\t1\tstale\tseed\tstale: seed\n' "$(date +%s)" > "$state/.wake-queue"; else : > "$state/.wake-queue"; fi
  case $th in
    fresh) date +%s > "$marker.acked-resurfaced" ;;
    old) date +%s > "$marker.acked-resurfaced"; touch -t 202001010000 "$marker.acked-resurfaced" ;;
    dir) mkdir "$marker.acked-resurfaced" ;;
  esac
  out=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_recovery_marker_arm_check "$2"; rc=$?; printf "rc=%s action=%s marker=%s" "$rc" "$FM_RECOVERY_MARKER_ACTION" "$(cut -d: -f1-2 "$2")"' _ "$lib" "$marker" 2>&1)
  printf '%-44s %s\n' "$name" "$out"
  rm -rf "$state"
}
run "acked, queue full, no cooldown marker"      acked:downtime:g.1.a full none
run "acked, queue full, cooldown fresh"          acked:downtime:g.1.a full fresh
run "acked, queue full, cooldown expired (2020)" acked:downtime:g.1.a full old
run "acked, queue full, cooldown path is a dir"  acked:downtime:g.1.a full dir
run "acked, queue empty, no cooldown marker"     acked:downtime:g.1.a empty none
run "pending:downtime, queue full, cd fresh"     pending:downtime:g.1.a full fresh
run "pending:handling, queue full, cd fresh"     pending:handling:g.1.a full fresh
run "announced, queue full, cd fresh"            announced:downtime:g.1.a full fresh
