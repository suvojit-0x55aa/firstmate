#!/usr/bin/env bash
# Codex synchronous Stop continuation owner.
#
# Called by fm-turnend-guard.sh --codex after its primary-scope and need checks.
# A yielded tool session and an async hook cannot wake an idle Codex turn.
# Instead keep Stop open on the existing singleton arm, then return exit 2 for
# an actionable close or the quiet checkpoint deadline. Codex itself schedules
# the continuation; the next Stop starts/attaches the next cycle. No detached
# keeper, pane injection, or forge/backlog mutation lives here.
#
# FM_CODEX_WATCH_CHECKPOINT selects 1..180 seconds (default 180), below the
# tracked Stop hook's 240-second timeout so output and cleanup have headroom.
# The arm's delivery ledger recovers the attached synchronous Stop watcher's wake.
# Only the owning primary's ancestry may park; session replacement, away mode,
# loss of supervision need, and hook cancellation stand down without a rewake.
# Signals reap only this invocation's tracked arm child. Deliberate interruption
# therefore cannot leave an automatic successor behind.
# A .codex-stop.lock serializes invocations; the watcher singleton remains the
# only owner of watcher exclusivity. Wakes remain queued until handled and acked.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
fm_session_lock_owned_by_self "$STATE" || {
  printf 'Codex supervision cannot park without verified session ownership; reconcile the session lock before continuing.\n' >&2
  exit 2
}
OWNER=$(cat "$STATE/.lock")
OWNER_IDENTITY=$(fm_pid_identity "$OWNER")
[ -n "$OWNER_IDENTITY" ] || exit 2
session_generation_current() {
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$OWNER" ] \
    && [ "$(fm_pid_identity "$OWNER")" = "$OWNER_IDENTITY" ] \
    && [ ! -e "$STATE/.afk" ]
}
lock_holder_in_session() {
  local pid=$1 parent hops=0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$hops" -lt 32 ]; do
    if [ "$pid" = "$OWNER" ]; then
      [ "$(fm_pid_identity "$OWNER")" = "$OWNER_IDENTITY" ]
      return
    fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$parent" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$parent" != "$pid" ] || return 1
    pid=$parent
    hops=$((hops + 1))
  done
  return 1
}
BUDGET=${FM_CODEX_WATCH_CHECKPOINT:-180}
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=180 ;; esac
[ "$BUDGET" -le 180 ] || BUDGET=180
GRACE=${FM_GUARD_GRACE:-300}
LOCK="$STATE/.codex-stop.lock"
if ! fm_lock_try_acquire "$LOCK"; then
  LOCK_DEADLINE=$((SECONDS + 8))
  while :; do
    lock_holder_in_session "${FM_LOCK_HELD_PID:-}" && exit 0
    session_generation_current || exit 0
    [ "$SECONDS" -lt "$LOCK_DEADLINE" ] || {
      printf 'Codex supervision could not establish replacement Stop ownership; retry the native continuation.\n' >&2
      exit 2
    }
    sleep 0.1
    fm_lock_try_acquire "$LOCK" && break
  done
fi
ARM_PID=
ARM_IDENTITY=
STOP_RECORD_OWNED=0
CONTINUATION_READY=0
# shellcheck disable=SC2329 # Called by the EXIT cleanup handler.
arm_alive() {
  [ -n "$ARM_PID" ] && [ -n "$ARM_IDENTITY" ] \
    && [ "$(fm_pid_identity "$ARM_PID")" = "$ARM_IDENTITY" ]
}
OUT=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  local attempt=0
  trap - HUP INT TERM
  if arm_alive; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    # Cleanup is bounded even if an older watcher cannot interrupt a pane read.
    while arm_alive && [ "$attempt" -lt 50 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
    if arm_alive; then kill -KILL "$ARM_PID" 2>/dev/null || true; fi
    wait "$ARM_PID" 2>/dev/null || true
    attempt=0
    while [ -e "$STATE/.watch.lock/pid" ] && [ "$attempt" -lt 50 ]; do
      sleep 0.1
      attempt=$((attempt + 1))
    done
  fi
  if [ "$STOP_RECORD_OWNED" = 1 ] && [ "$CONTINUATION_READY" != 1 ]; then
    fm_codex_stop_record_clear "$STATE" "$OWNER" "$OWNER_IDENTITY" || true
  fi
  [ -z "$OUT" ] || rm -f "$OUT"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
if ! fm_codex_stop_successor_begin "$STATE" "$OWNER" "$OWNER_IDENTITY"; then
  printf 'Codex supervision rejected a duplicate or invalid Stop successor; reconcile the session generation before continuing.\n' >&2
  exit 2
fi
STOP_RECORD_OWNED=1
still_ours() {
  session_generation_current
}
# shellcheck source=/dev/null
[ ! -f "$CONFIG/x-mode.env" ] || . "$CONFIG/x-mode.env"
fm_supervision_needed "$STATE" "$GRACE" || exit 0
OUT=$(mktemp "$STATE/.codex-stop-output.XXXXXX") || exit 2
# Keep the arm in the native hook process group so Codex cancellation also
# reaps it when the hook shell receives SIGKILL and cannot run its EXIT trap.
{ "$SCRIPT_DIR/fm-watch-arm.sh" >"$OUT" 2>&1 & } 2>/dev/null
ARM_PID=$!
ARM_IDENTITY=$(fm_pid_identity "$ARM_PID")
START=$SECONDS
while kill -0 "$ARM_PID" 2>/dev/null; do
  still_ours || exit 0
  fm_supervision_needed "$STATE" "$GRACE" || exit 0
  [ $((SECONDS - START)) -lt "$BUDGET" ] || break
  sleep 1
done
still_ours || exit 0
fm_supervision_needed "$STATE" "$GRACE" || exit 0
if ! fm_codex_stop_handling_open "$STATE" "$OWNER" "$OWNER_IDENTITY" "$GRACE"; then
  printf 'Codex supervision could not persist its generation-bound handling successor.\n' >&2
  exit 2
fi
if grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT"; then
  grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" | head -8 >&2
elif kill -0 "$ARM_PID" 2>/dev/null; then
  printf 'checkpoint: quiet Codex supervision interval completed (%ss).\n' "$BUDGET" >&2
else
  printf 'Codex supervision cycle closed; inspect the durable wake queue and cycle result.\n' >&2
  tail -6 "$OUT" >&2
fi
printf 'Run bin/fm-wake-drain.sh, handle its work, and acknowledge only after handling. Keep quiet intervals silent. The next Stop owns the successor; do not launch a background watcher or finish assuming a yielded tool will wake you.\n' >&2
CONTINUATION_READY=1
exit 2
