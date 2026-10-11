#!/usr/bin/env bash
# Durable terminal-delivery owner, independent of notification acknowledgement.
# Usage: fm-terminal-reconcile.sh observe <id> <done|failed> [pr]
#        fm-terminal-reconcile.sh merged <id> <pr>
#        fm-terminal-reconcile.sh local-landed <id> <commit>
#        fm-terminal-reconcile.sh retired <id> <normal|discard>
#        fm-terminal-reconcile.sh reconcile | report
#        fm-terminal-reconcile.sh refill-reviewed <receipt-key>
#
# observe is called by inactive recovery; merged only by the verified merge
# outcome owner; retired only after guarded teardown has removed the endpoint
# and worktree, before metadata deletion. These are evidence-producing entry
# points, not alternative merge or teardown commands. No forge calls or dispatch
# occur here. A PR-ready outcome never means landed, and discard never means done.
#
# state/terminal-delivery/<incarnation-hash>.json records independent presentation,
# PR custody, merge proof, teardown, backlog and refill stages. Presentation is
# owned by fm-inactive-reconcile.sh; acknowledging it never removes this ledger.
# Local tasks-axi mutations are idempotent, --no-prune retains replay evidence,
# and held/blocked tasks fail closed. Manual backlogs retain an actionable record.
# refill-reviewed is an explicit supervisor acknowledgement AFTER evaluating the
# current ready list, date gates and dependencies and dispatching eligible work.
# Queue wake acknowledgement alone cannot clear it. Reconcile is bounded, local,
# and replayed during recovery; report prints unresolved obligations every drain.
# shellcheck disable=SC2016 # jq program variables are intentionally literal.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DIR="$STATE/terminal-delivery"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
valid() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1;; esac; }
field() { sed -n "s/^$2=//p" "$1" | tail -1; }
put() {
  local tmp
  tmp=$(mktemp "$DIR/.receipt.XXXXXX") || return 1
  jq "$@" "$RECORD" > "$tmp" && mv -f "$tmp" "$RECORD" && return 0
  rm -f "$tmp"
  return 1
}
select_record() {
  local id=$1 meta="$STATE/$1.meta" incarnation tmp
  valid "$id" || return 2
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  incarnation=$(field "$meta" spawn_gen)
  [ -n "$incarnation" ] || incarnation="$(field "$meta" tasktmp)|$(field "$meta" worktree)|$(field "$meta" window)"
  KEY=$(printf '%s' "$id|$incarnation" | shasum -a 256 | awk '{print $1}')
  RECORD="$DIR/$KEY.json"
  [ ! -L "$RECORD" ] || return 1
  [ ! -f "$RECORD" ] || return 0
  tmp=$(mktemp "$DIR/.receipt.XXXXXX") || return 1
  jq -n --arg id "$id" --arg key "$KEY" --arg incarnation "$incarnation" \
    --arg kind "$(field "$meta" kind)" --arg mode "$(field "$meta" mode)" --arg pr "$(field "$meta" pr)" \
    '{schema:"fm-terminal-delivery.v1",key:$key,id:$id,incarnation:$incarnation,kind:$kind,mode:$mode,state:"unknown",pr:$pr,merged:false,retired:false,discarded:false,backlog:false,refill:false,reviewed:false}' > "$tmp" \
    && mv "$tmp" "$RECORD"
}
reconcile_record() {
  local id pr state task snapshot retired discarded kind incarnation meta
  local -a args
  [ "$(jq -r .reviewed "$RECORD")" != true ] || return 0
  id=$(jq -r .id "$RECORD") || return 1
  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    incarnation=$(field "$meta" spawn_gen)
    [ -n "$incarnation" ] || incarnation="$(field "$meta" tasktmp)|$(field "$meta" worktree)|$(field "$meta" window)"
    [ "$incarnation" = "$(jq -r .incarnation "$RECORD")" ] || return 0
  fi
  [ -z "$(status_open_decisions "$STATE/$id.status")" ] || return 0
  pr=$(jq -r .pr "$RECORD")
  retired=$(jq -r .retired "$RECORD")
  discarded=$(jq -r .discarded "$RECORD")
  [ "$discarded" != true ] || return 0
  fm_tasks_axi_backend_available "$CONFIG" || return 0
  # Read the backend's public current-state result; unknown schemas fail closed.
  snapshot=$(fm_run_timed 3 tasks-axi show "$id" --file "$DATA/backlog.md" 2>/dev/null) || return 0
  printf '%s\n' "$snapshot" | grep -Eq '^  state: (in_flight|done)$' || return 0
  printf '%s\n' "$snapshot" | grep -Fx '  held: no' >/dev/null || return 0
  printf '%s\n' "$snapshot" | grep -Fx '  blocked: no' >/dev/null || return 0
  if [ -n "$pr" ] && [ "$(jq -r '.custody // false' "$RECORD")" != true ]; then
    task=$(fm_run_timed 3 tasks-axi update "$id" --pr "$pr" --file "$DATA/backlog.md" --json) || return 1
    printf '%s' "$task" | jq -e '.ok == true' >/dev/null || return 1
    put '.custody=true' || return 1
  fi
  [ "$retired" = true ] || return 0
  if [ "$(jq -r .backlog "$RECORD")" != true ]; then
    kind=$(jq -r .kind "$RECORD")
    args=(--note 'Guarded teardown completed')
    if [ "$kind" = scout ]; then args=(--report "data/$id/report.md")
    elif [ -n "$pr" ]; then
      # Remote reachability may permit safe custody teardown of an OPEN PR.
      # It does not prove delivery and must not close the backlog item.
      [ "$(jq -r .merged "$RECORD")" = true ] || return 0
      args=(--pr "$pr")
    elif [ "$(jq -r .mode "$RECORD")" = local-only ]; then
      [ -n "$(jq -r '.local_head // empty' "$RECORD")" ] || return 0
    else return 0
    fi
    task=$(fm_run_timed 3 tasks-axi 'done' "$id" "${args[@]}" --no-prune --file "$DATA/backlog.md" --json) || return 1
    printf '%s' "$task" | jq -e '.ok == true and .task.state == "done"' >/dev/null || return 1
    put '.backlog=true | .refill=true' || return 1
  fi
  if [ "$(jq -r .reviewed "$RECORD")" != true ]; then
    state=$(fm_run_timed 3 tasks-axi ready --file "$DATA/backlog.md") || return 1
    put --arg ready "$state" '.ready=$ready' || return 1
  fi
}
mode=${1:-report}
case "$mode" in -h|--help) sed -n '2,23{s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
mkdir -p "$DIR" || exit 1
[ ! -L "$DIR" ] || exit 1
fm_lock_acquire_wait "$DIR/.lock" || exit 1
trap 'fm_lock_release "$DIR/.lock"' EXIT
case "$mode" in
  observe|merged|local-landed|retired)
    [ "$#" -ge 3 ] || exit 2
    select_record "$2" || exit $?
    case "$mode" in
      observe)
        case "$3" in done|failed) ;; *) exit 2;; esac
        put --arg state "$3" --arg pr "${4:-}" '.state=$state | if $pr!="" and .pr!=$pr then .pr=$pr | .merged=false | .custody=false | .backlog=false | .refill=false | .reviewed=false else . end' || exit 1 ;;
      merged) put --arg pr "$3" '.pr=$pr | .merged=true' || exit 1 ;;
      local-landed)
        case "$3" in ''|*[!a-fA-F0-9]*) exit 2;; esac
        [ "${#3}" -eq 40 ] || [ "${#3}" -eq 64 ] || exit 2
        put --arg head "$3" '.local_head=$head' || exit 1 ;;
      retired)
        case "$3" in normal) put '.retired=true';; discard) put '.retired=true | .discarded=true';; *) exit 2;; esac || exit 1 ;;
    esac
    # Producers record facts only; bounded recovery owns backend work.
    ;;
  reconcile)
    deadline=$((SECONDS+8))
    cursor=$(cat "$DIR/.cursor" 2>/dev/null || true)
    for range in after through; do
      for RECORD in "$DIR"/*.json; do
        [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || continue
        name=${RECORD##*/}
        if [ "$range" = after ]; then [[ "$name" > "$cursor" ]] || continue
        else [[ "$name" > "$cursor" ]] && continue
        fi
        [ "$SECONDS" -lt "$deadline" ] || exit 0
        # Publish before work so a persistently broken item cannot starve peers.
        cursor_tmp=$(mktemp "$DIR/.cursor.XXXXXX") || exit 1
        printf '%s\n' "$name" > "$cursor_tmp" && mv "$cursor_tmp" "$DIR/.cursor" || exit 1
        reconcile_record || exit 1
      done
    done ;;
  report)
    for RECORD in "$DIR"/*.json; do
      [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || continue
      jq -r 'select(.reviewed!=true) | "TERMINAL DELIVERY: \(.id) receipt=\(.key) state=\(.state) pr=\(.pr) merge_proven=\(.merged) teardown=\(.retired) backlog_done=\(.backlog) refill_pending=\(.refill) discard=\(.discarded)" + (if .refill then "\nEvaluate current ready work, dependencies and date gates, dispatch eligible work, then run bin/fm-terminal-reconcile.sh refill-reviewed \(.key)\n" + (.ready // "Ready-list refresh pending") else "\nPreserve captain holds; reconcile PR custody/merge proof and guarded teardown before closing backlog." end)' "$RECORD" || exit 1
    done ;;
  refill-reviewed)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    RECORD="$DIR/$2.json"
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 1
    jq -e '.backlog and .refill' "$RECORD" >/dev/null || exit 1
    put '.reviewed=true' ;;
  *) exit 2 ;;
esac
