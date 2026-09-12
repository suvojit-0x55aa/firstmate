#!/usr/bin/env bash
# Arm a detection-only watch that wakes firstmate when a stuck task's quota
# provider resets, using bin/fm-procevent-when.sh as the condition->action
# primitive. This never drives task lifecycle - see bin/fm-quota-reset-
# notify.sh's own header for that boundary.
#
# The reset time this reads from quota-axi is account-wide, not per-task:
# every task stuck on the same account shares one binding window. This arm
# is still scoped per task (one watch named quota-reset-<task-id>) rather
# than fleet-wide, on purpose:
#   - the task-id is exactly the context the caller (stuck-crewmate-recovery,
#     investigating one specific stuck task) already has in hand;
#   - the epoch is resolved ONCE here and baked into the condition argv, so
#     polling never re-queries quota-axi - arming N stuck tasks costs N
#     one-time lookups at arm time, not N ongoing queries;
#   - a fleet-wide arm would need new machinery to discover and notify every
#     currently-stuck task at fire time, which is more moving parts, not
#     fewer, for a feature that must stay detection-only.
#
# Usage: fm-quota-reset-arm.sh <task-id> [--buffer-secs <secs>] [--provider <name>]
#   --buffer-secs <secs>  extra delay after the reported reset epoch, to
#                         absorb poll granularity (default: 60)
#   --provider <name>     quota-axi provider id, passed through to
#                         fm-quota-reset-epoch.sh (default: claude)
#   -h, --help            print this header and exit without arming anything
#
# The watch's give-up deadline is derived from the resolved target rather than
# left at fm-procevent-when.sh's default, which is measured from arming: a
# weekly window resetting further out than that default would otherwise expire
# the watch before its own target, waking firstmate with `never-true` and
# never detecting the real reset.
#
# Idempotent: if a watch for this task is already armed and has not fired,
# calling this again is a no-op. If a prior watch for this task fired and
# was left unretired (its captured result never marked handled, or its
# spec/trust/fired state never retired), this self-heals - marks the
# captured result handled and retires the leftover registration - then
# arms fresh, rather than silently reporting success without actually
# re-arming, or refusing forever.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,${/^set -u$/q; s/^# \{0,1\}//; p;}' "$0"; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

POLL_INTERVAL_SECS=120
BUFFER_DEFAULT_SECS=60
# Slack after the target for the stable-poll count, the action run, and clock
# skew, so the deadline only ever fires when the target itself went unmet.
DEADLINE_MARGIN_SECS=3600

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

TASK_ID=${1:-}
[ -n "$TASK_ID" ] || die "usage: fm-quota-reset-arm.sh <task-id> [--buffer-secs <secs>] [--provider <name>]"
shift

BUFFER_SECS=$BUFFER_DEFAULT_SECS
PROVIDER=claude
while [ $# -gt 0 ]; do
  case "$1" in
    --buffer-secs)
      [ $# -ge 2 ] || die "--buffer-secs requires a value"
      case "$2" in ''|*[!0-9]*) die "--buffer-secs must be a non-negative integer" ;; esac
      BUFFER_SECS=$2
      shift 2
      ;;
    --provider)
      [ $# -ge 2 ] || die "--provider requires a value"
      PROVIDER=$2
      shift 2
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

fm_task_id_path_safe "$TASK_ID" ||
  die "task-id must be path-safe (letters, digits, dot, dash, underscore, and not leading with a dot): $TASK_ID"

NAME="quota-reset-$TASK_ID"
SID="when-$NAME"

# The derived source id carries a fixed prefix, so refuse an over-long task-id
# by its own length here rather than letting fm-procevent-when.sh reject a
# name the caller never typed - after a quota-axi query has already been paid.
fm_procevent_source_id_valid "$SID" ||
  die "task-id must be at most $((64 - (${#SID} - ${#TASK_ID}))) characters, because the watch source id prefixes it with ${SID%"$TASK_ID"}: $TASK_ID"

# --- idempotency: leave a genuinely still-active watch untouched -----------
# A registration alone does not mean the watch is still live. A fire leaves a
# durable marker behind, and fm-procevent-when.sh's runner answers `ambiguous`
# without ever polling once that marker exists, so a spent watch must re-arm
# rather than report success.
FIRED="$STATE/when/$SID.fired"
row=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null | awk -v sid="$SID" '$1 == sid { print; found=1 } END { exit !found }')
if [ -n "$row" ]; then
  pending=$(printf '%s\n' "$row" | awk '{print $NF}')
  if [ "$pending" = 0 ] && [ ! -e "$FIRED" ] && [ ! -L "$FIRED" ]; then
    printf 'already armed: %s (task %s) - nothing to do\n' "$SID" "$TASK_ID"
    exit 0
  fi
  # Either a captured result is still pending or the watch already fired:
  # leftover from a prior cycle, not a live watch. Fall through to
  # resolve-and-self-heal below.
fi

# --- resolve the target epoch once, up front --------------------------------
EPOCH=$("$SCRIPT_DIR/fm-quota-reset-epoch.sh" --provider "$PROVIDER") ||
  die "cannot resolve quota reset time from quota-axi for provider $PROVIDER; not arming"
TARGET=$((EPOCH + BUFFER_SECS))

NOW=$(date +%s)
DEADLINE_SECS=$((TARGET - NOW + DEADLINE_MARGIN_SECS))
[ "$DEADLINE_SECS" -ge "$DEADLINE_MARGIN_SECS" ] || DEADLINE_SECS=$DEADLINE_MARGIN_SECS

# --- self-heal helpers -------------------------------------------------------
# Both helpers print whatever their child printed. Retiring has several ways to
# refuse - unreadable ownership, an unconfirmable runner identity - and each
# leaves the leftover state in place, so the caller keeps that output and reads
# it back out when the retried arm still fails.
heal_leftover_registration() {
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$NAME" 2>&1
}

# Marks every unhandled captured result for this watch's source id handled.
# Safe to call when there is nothing pending (the loop body then never runs).
# Ownership is an exact comparison, never a prefix: a sibling task whose id
# extends this one after a dot owns its own results.
# A failed acknowledgement is remembered across the whole loop rather than
# left as the last iteration's status, so one failure among several still
# reaches the caller.
heal_unhandled_results() {
  local path status=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$(fm_procevent_result_source_id "$path")" = "$SID" ] || continue
    "$SCRIPT_DIR/fm-procevent.sh" handled "$SID" "$(fm_procevent_result_sequence "$path")" 2>&1 ||
      status=1
  done < <(fm_procevent_pending "$STATE")
  return "$status"
}

# Acknowledging a captured result is irreversible: once its handled marker
# exists the outcome can never be re-announced. So it only runs on a path that
# can actually re-arm - when retiring the leftover registration succeeded.
run_self_heal() {
  local retire_out results_out status=0
  retire_out=$(heal_leftover_registration) || {
    printf '%s\n' "$retire_out"
    return 1
  }
  results_out=$(heal_unhandled_results) || status=1
  printf '%s\n' "$retire_out"
  [ -z "$results_out" ] || printf '%s\n' "$results_out"
  return "$status"
}

try_arm() {
  "$SCRIPT_DIR/fm-procevent-when.sh" arm "$NAME" \
    --interval "$POLL_INTERVAL_SECS" \
    --deadline "$DEADLINE_SECS" \
    --condition "$SCRIPT_DIR/fm-time-reached.sh" "$TARGET" \
    --action "$SCRIPT_DIR/fm-quota-reset-notify.sh" "$TASK_ID"
}

HEAL_OUT=''
HEAL_STATUS=0
OUT=$(try_arm 2>&1)
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
  case "$OUT" in
    *"already exists or left state behind"*|*"an unhandled captured result exists for"*)
      HEAL_OUT=$(run_self_heal)
      HEAL_STATUS=$?
      OUT=$(try_arm 2>&1)
      STATUS=$?
      ;;
  esac
fi

if [ "$STATUS" -ne 0 ]; then
  [ "$HEAL_STATUS" -eq 0 ] ||
    die "cannot arm quota-reset watch for $TASK_ID: $OUT; the self-heal could not clear it either: $HEAL_OUT"
  die "cannot arm quota-reset watch for $TASK_ID: $OUT"
fi

# A heal that ran consumed durable state - retiring the leftover watch, and
# acknowledging any captured outcome nobody had read, which is irreversible.
# Say so before the arm line rather than leaving the caller with only success.
[ -z "$HEAL_OUT" ] ||
  printf 'self-healed leftover state for %s before re-arming:\n%s\n' "$SID" "$HEAL_OUT"
printf '%s\n' "$OUT"
