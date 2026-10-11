#!/usr/bin/env bash
# Durable terminal-delivery owner, independent of notification acknowledgement.
# Usage: fm-terminal-reconcile.sh observe <id> <done|failed> [pr]
#        fm-terminal-reconcile.sh custody <id> <pr>
#        fm-terminal-reconcile.sh merged <id> <pr>
#        fm-terminal-reconcile.sh merge-observed <id> <pr>
#        fm-terminal-reconcile.sh local-landed <id> <commit>
#        fm-terminal-reconcile.sh default-landed <id> <commit>
#        fm-terminal-reconcile.sh retired <id> <normal|discard>
#        fm-terminal-reconcile.sh landing-proven <id>
#        fm-terminal-reconcile.sh completed-after <id> <receipt-key>
#        fm-terminal-reconcile.sh reconcile | report
#        fm-terminal-reconcile.sh manual-complete <receipt-key>
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
# and held/blocked tasks fail closed. manual-complete confirms an operator has
# updated a manual backlog, but only after the same delivery and decision guards.
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
select_record_path() {
  local id=$1 meta="$STATE/$1.meta"
  valid "$id" || return 2
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  INCARNATION=$(field "$meta" spawn_gen)
  [ -n "$INCARNATION" ] || INCARNATION="$(field "$meta" tasktmp)|$(field "$meta" worktree)|$(field "$meta" window)"
  KEY=$(printf '%s' "$id|$INCARNATION" | shasum -a 256 | awk '{print $1}')
  RECORD="$DIR/$KEY.json"
  [ ! -L "$RECORD" ] || return 1
}
supersede_prior_records() {
  local id=$1 current=$RECORD candidate
  for candidate in "$DIR"/*.json; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    [ "$candidate" != "$current" ] || continue
    jq -e --arg id "$id" \
      '.id == $id and .backlog != true and .reviewed != true and ((.superseded_by // "") == "")' \
      "$candidate" >/dev/null || continue
    RECORD=$candidate
    put --arg key "$KEY" '.superseded_by=$key' || { RECORD=$current; return 1; }
  done
  RECORD=$current
}
select_existing_record() {
  select_record_path "$1" || return $?
  [ -f "$RECORD" ]
}
select_record() {
  local id=$1 meta="$STATE/$1.meta" tmp
  select_record_path "$id" || return $?
  if [ -f "$RECORD" ]; then
    supersede_prior_records "$id"
    return $?
  fi
  tmp=$(mktemp "$DIR/.receipt.XXXXXX") || return 1
  jq -n --arg id "$id" --arg key "$KEY" --arg incarnation "$INCARNATION" \
    --arg kind "$(field "$meta" kind)" --arg mode "$(field "$meta" mode)" --arg pr "$(field "$meta" pr)" \
    --arg captain_keys "$(field "$meta" decision_keys)" \
    '{schema:"fm-terminal-delivery.v1",key:$key,id:$id,incarnation:$incarnation,kind:$kind,mode:$mode,state:"unknown",pr:$pr,merged:false,retired:false,discarded:false,backlog:false,refill:false,reviewed:false,superseded_by:"",captain_keys:$captain_keys}' > "$tmp" \
    && mv "$tmp" "$RECORD" \
    && supersede_prior_records "$id"
}
select_retired_record() {
  local id=$1 pr=$2 candidate found=
  valid "$id" || return 2
  for candidate in "$DIR"/*.json; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
    jq -e --arg id "$id" --arg pr "$pr" \
      '.id == $id and .retired == true and .reviewed != true and ((.superseded_by // "") == "") and (.pr == $pr or .pr == "")' \
      "$candidate" >/dev/null || continue
    [ -z "$found" ] || return 1
    found=$candidate
  done
  [ -n "$found" ] || return 1
  RECORD=$found
  KEY=${found##*/}
  KEY=${KEY%.json}
}
record_matches_current_incarnation() {
  local id meta incarnation
  id=$(jq -r .id "$RECORD") || return 1
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  incarnation=$(field "$meta" spawn_gen)
  [ -n "$incarnation" ] || incarnation="$(field "$meta" tasktmp)|$(field "$meta" worktree)|$(field "$meta" window)"
  [ "$incarnation" = "$(jq -r .incarnation "$RECORD")" ]
}
delivery_proven() {
  [ "$(jq -r .kind "$RECORD")" = scout ] && return 0
  if [ "$(jq -r .merged "$RECORD")" = true ] && [ -n "$(jq -r .pr "$RECORD")" ]; then
    return 0
  fi
  [ -n "$(jq -r '(.local_head // .default_head // empty)' "$RECORD")" ]
}
terminal_completed_after() {
  local id=$1 current=$2 next depth=0
  while [ "$depth" -lt 64 ]; do
    RECORD="$DIR/$current.json"
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
    jq -e --arg id "$id" --arg key "$current" \
      '.schema == "fm-terminal-delivery.v1" and .id == $id and .key == $key and .discarded != true' \
      "$RECORD" >/dev/null || return 1
    next=$(jq -r '.superseded_by // ""' "$RECORD") || return 1
    [ -n "$next" ] && valid "$next" && [ "$next" != "$current" ] || return 1
    RECORD="$DIR/$next.json"
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
    jq -e --arg id "$id" --arg key "$next" \
      '.schema == "fm-terminal-delivery.v1" and .id == $id and .key == $key and .discarded != true' \
      "$RECORD" >/dev/null || return 1
    if jq -e '.retired == true and .backlog == true and ((.superseded_by // "") == "")' \
      "$RECORD" >/dev/null && delivery_proven; then
      return 0
    fi
    current=$next
    depth=$((depth + 1))
  done
  return 1
}
captain_calls_resolved() {
  local id receipt captain_keys captain_key
  id=$(jq -r .id "$RECORD") || return 1
  receipt=$(jq -r .key "$RECORD") || return 1
  set -- "$id"
  captain_keys=$(jq -r '.captain_keys // ""' "$RECORD") || return 1
  while IFS= read -r captain_key; do
    [ -n "$captain_key" ] || continue
    set -- "$@" "$captain_key"
  done <<EOF
$(printf '%s\n' "$captain_keys" | tr ',' '\n')
EOF
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
    terminal-ready "$id" --receipt "$receipt" "${@:2}" >/dev/null 2>&1
}
reconcile_record() {
  local id pr state task snapshot retired discarded kind
  local -a args
  [ "$(jq -r .reviewed "$RECORD")" != true ] || return 0
  [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || return 0
  id=$(jq -r .id "$RECORD") || return 1
  record_matches_current_incarnation || return 0
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
    elif [ "$(jq -r .merged "$RECORD")" = true ] && [ -n "$pr" ]; then
      args=(--pr "$pr")
    elif delivery_proven; then :
    else
      # Remote reachability may permit safe custody teardown of an OPEN PR.
      # It does not prove delivery and must not close the backlog item.
      return 0
    fi
    captain_calls_resolved || return 0
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
case "$mode" in -h|--help) sed -n '2,29{s/^# \{0,1\}//;p;}' "$0"; exit 0;; esac
if [ "$mode" = completed-after ]; then
  [ "$#" -eq 3 ] && valid "$2" && valid "$3" || exit 2
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
  terminal_completed_after "$2" "$3"
  exit
fi
mkdir -p "$DIR" || exit 1
[ ! -L "$DIR" ] || exit 1
fm_lock_acquire_wait "$DIR/.lock" || exit 1
trap 'fm_lock_release "$DIR/.lock"' EXIT
case "$mode" in
  landing-proven)
    [ "$#" -eq 2 ] || exit 2
    select_existing_record "$2" || exit 1
    jq -e '.discarded != true and ((.superseded_by // "") == "")' "$RECORD" >/dev/null || exit 1
    delivery_proven || exit 1
    ;;
  observe|custody|merged|merge-observed|local-landed|default-landed|retired)
    [ "$#" -ge 3 ] || exit 2
    if [ "$mode" = merged ] || [ "$mode" = merge-observed ]; then
      if ! select_record "$2" && ! select_retired_record "$2" "$3"; then
        [ "$mode" = merge-observed ] && exit 0
        exit 1
      fi
    else
      select_record "$2" || exit $?
    fi
    case "$mode" in
      observe)
        case "$3" in done|failed) ;; *) exit 2;; esac
        put --arg state "$3" --arg pr "${4:-}" '.state=$state | if $pr!="" and .pr!=$pr then .pr=$pr | .merged=false | .custody=false | .backlog=false | .refill=false | .reviewed=false else . end' || exit 1 ;;
      custody) put --arg pr "$3" 'if .pr!=$pr then .pr=$pr | .merged=false | .custody=false | .backlog=false | .refill=false | .reviewed=false else . end' || exit 1 ;;
      merged|merge-observed) put --arg pr "$3" '.pr=$pr | .merged=true' || exit 1 ;;
      local-landed|default-landed)
        case "$3" in ''|*[!a-fA-F0-9]*) exit 2;; esac
        [ "${#3}" -eq 40 ] || [ "${#3}" -eq 64 ] || exit 2
        if [ "$mode" = local-landed ]; then
          put --arg head "$3" '.local_head=$head' || exit 1
        else
          put --arg head "$3" '.default_head=$head' || exit 1
        fi ;;
      retired)
        captain_keys=$(field "$STATE/$2.meta" decision_keys)
        case "$3" in
          normal) put --arg keys "$captain_keys" '.retired=true | .captain_keys=$keys' ;;
          discard) put --arg keys "$captain_keys" '.retired=true | .discarded=true | .captain_keys=$keys' ;;
          *) exit 2 ;;
        esac || exit 1 ;;
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
    manual=false
    fm_backlog_backend_manual "$CONFIG" && manual=true
    for RECORD in "$DIR"/*.json; do
      [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || continue
      jq -r --argjson manual "$manual" 'select(.reviewed!=true and ((.superseded_by // "") == "")) | "TERMINAL DELIVERY: \(.id) receipt=\(.key) state=\(.state) pr=\(.pr) merge_proven=\(.merged) default_landed=\((.local_head // .default_head // "") != "") teardown=\(.retired) backlog_done=\(.backlog) refill_pending=\(.refill) discard=\(.discarded)" + (if .refill then "\nEvaluate current ready work, dependencies and date gates, dispatch eligible work, then run bin/fm-terminal-reconcile.sh refill-reviewed \(.key)\n" + (.ready // "Ready-list refresh pending") elif $manual and .retired and (.discarded != true) and (.kind == "scout" or (.merged and .pr != "") or ((.local_head // .default_head // "") != "")) then "\nPreserve captain holds; after manually completing data/backlog.md, run bin/fm-terminal-reconcile.sh manual-complete \(.key)." else "\nPreserve captain holds; reconcile PR custody/merge proof and guarded teardown before closing backlog, then dispatch only work whose blockers are gone and date is due." end)' "$RECORD" || exit 1
    done ;;
  manual-complete)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    fm_backlog_backend_manual "$CONFIG" || exit 1
    RECORD="$DIR/$2.json"
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 1
    [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || exit 1
    record_matches_current_incarnation || exit 1
    jq -e '.retired and (.discarded != true)' "$RECORD" >/dev/null || exit 1
    delivery_proven || exit 1
    captain_calls_resolved || exit 1
    put --arg ready 'Manual backend: review data/backlog.md for current ready work, dependencies and date gates.' \
      '.backlog=true | .refill=true | .ready=$ready' ;;
  refill-reviewed)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    RECORD="$DIR/$2.json"
    [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || exit 1
    [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || exit 1
    jq -e '.backlog and .refill' "$RECORD" >/dev/null || exit 1
    put '.reviewed=true' ;;
  *) exit 2 ;;
esac
