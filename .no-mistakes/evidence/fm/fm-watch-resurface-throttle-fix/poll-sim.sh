#!/usr/bin/env bash
# poll-sim.sh <fm-wake-lib.sh> <label> [cycles]
# Simulates the watcher poll loop: each cycle runs the real
# fm_recovery_marker_arm_check (what resurface_after_downtime calls). On
# 'recover' it prints the wake the watcher would emit, then the captain acks
# it via the real fm_recovery_marker_ack (what fm-wake-drain.sh does).
set -u
lib=$1 label=$2 cycles=${3:-10}
state=$(mktemp -d); marker="$state/.watcher-down"
printf 'acked:downtime:seed.1.aaa\n' > "$marker"; chmod 600 "$marker"
printf '%s\t1\tstale\tseed\tstale: seed (idle 999s)\n' "$(date +%s)" > "$state/.wake-queue"
export FM_STATE_OVERRIDE="$state"
unset FM_RECOVERY_MARKER_ACKED_RESURFACE_SECS
. "$lib"
echo "== $label: wake queue holds 1 throttled stale: entry; marker starts acked"
wakes=0
for i in $(seq 1 "$cycles"); do
  fm_recovery_marker_arm_check "$marker" || { echo "arm_check failed"; exit 1; }
  if [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
    wakes=$((wakes+1))
    fm_recovery_marker_read "$marker"; gen=${FM_RECOVERY_MARKER_TOKEN##*:}
    printf 'poll %2d: WAKE "check: rearm-resurface"  (marker=%s) -> captain acks\n' "$i" "$FM_RECOVERY_MARKER_TOKEN"
    fm_recovery_marker_ack "$marker" "$gen" || echo "  ack rc=$?"
  else
    printf 'poll %2d: quiet                            (marker=%s)\n' "$i" "$(cat "$marker")"
  fi
done
echo "== $label: $wakes rearm-resurface wake(s) in $cycles polls"
rm -rf "$state"
