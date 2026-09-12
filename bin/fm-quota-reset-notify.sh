#!/usr/bin/env bash
# Wake action for a fired quota-reset watch: report that the task's quota
# should now be clear and point at the manual next steps.
#
# This script NEVER drives lifecycle - it must not call bin/fm-control.sh or
# any other command that interrupts, exits, or relaunches a crewmate. It is
# detection-only: it re-peeks the task's pane read-only for a human/firstmate
# to read, then names the commands firstmate would run by hand. Wiring this
# into fm-control.sh later is a deliberate, separate decision, not something
# this script may do on its own.
#
# Usage: fm-quota-reset-notify.sh <task-id> [lines=60]
#
# Test-only override:
#   FM_QUOTA_PEEK_OVERRIDE  command to run instead of fm-peek.sh (same argv:
#                           <task-id> <lines>)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

TASK_ID=${1:-}
LINES=${2:-60}
[ -n "$TASK_ID" ] || die "usage: fm-quota-reset-notify.sh <task-id> [lines=60]"

PEEK_CMD="${FM_QUOTA_PEEK_OVERRIDE:-$SCRIPT_DIR/fm-peek.sh}"

printf 'quota reset reached for task %s - re-peeked pane follows (read-only):\n' "$TASK_ID"
if ! "$PEEK_CMD" "$TASK_ID" "$LINES"; then
  printf '(peek failed - task endpoint may be gone; check with: bin/fm-crew-state.sh %s)\n' "$TASK_ID"
fi
printf -- '---\n'
printf 'This notice is detection-only and takes no action. To resume the task by hand:\n'
printf '  1. Check current state:  bin/fm-crew-state.sh %s\n' "$TASK_ID"
printf '  2. If it is still stuck on the cleared quota, relaunch it:  bin/fm-control.sh %s relaunch\n' "$TASK_ID"
