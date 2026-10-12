#!/usr/bin/env bash
# Durable terminal-delivery owner, independent of notification acknowledgement.
# Usage: fm-terminal-reconcile.sh observe <id> <done|failed> [pr]
#        fm-terminal-reconcile.sh custody <id> <pr>
#        fm-terminal-reconcile.sh merged <id> <pr>
#        fm-terminal-reconcile.sh merge-observed <id> <pr>
#        fm-terminal-reconcile.sh local-landed <id> <commit>
#        fm-terminal-reconcile.sh default-landed <id> <commit>
#        fm-terminal-reconcile.sh retired <id> <normal|discard>
#        fm-terminal-reconcile.sh prepare-retirement <id>
#        fm-terminal-reconcile.sh landing-proven <id>
#        fm-terminal-reconcile.sh completed-after <id> <receipt-key>
#        fm-terminal-reconcile.sh completed-exact <id> <receipt-key>
#        fm-terminal-reconcile.sh current-incarnation <id>
#        fm-terminal-reconcile.sh receipt-key <id>
#        fm-terminal-reconcile.sh reconcile | report
#        fm-terminal-reconcile.sh manual-complete <receipt-key>
#        fm-terminal-reconcile.sh captain-review-state <id> <receipt-key>
#        fm-terminal-reconcile.sh captain-reviewed <id> <receipt-key> <captain-task-ids>
#        fm-terminal-reconcile.sh predecessor-reviewed <id> <receipt-key> (--none | <task-id>...)
#        fm-terminal-reconcile.sh backlog-reviewed <receipt-key>
#        fm-terminal-reconcile.sh discard-reviewed <receipt-key>
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
RECONCILE_CANDIDATES=
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
valid_spawn_incarnation() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$1" in *[A-Za-z0-9]*) return 0 ;; *) return 1 ;; esac
}
valid_legacy_incarnation() {
  local incarnation=$1 first second third extra
  case "$incarnation" in *$'\n'*|*$'\r'*) return 1 ;; esac
  IFS='|' read -r first second third extra <<EOF
$incarnation
EOF
  [ -z "$extra" ] || return 1
  [ "$incarnation" = "$first|$second|$third" ] || return 1
  printf '%s%s%s' "$first" "$second" "$third" | grep -q '[^[:space:]]'
}
current_metadata_incarnation() {
  local meta=$1 spawn_gen tasktmp worktree window
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    return 3
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 1
  spawn_gen=$(field "$meta" spawn_gen)
  if [ -n "$spawn_gen" ]; then
    valid_spawn_incarnation "$spawn_gen" || return 1
    INCARNATION=$spawn_gen
    INCARNATION_KIND=spawn
  else
    tasktmp=$(field "$meta" tasktmp)
    worktree=$(field "$meta" worktree)
    window=$(field "$meta" window)
    INCARNATION="$tasktmp|$worktree|$window"
    valid_legacy_incarnation "$INCARNATION" || return 1
    INCARNATION_KIND=legacy
  fi
}
backlog_task_record() {
  local id=$1 snapshot
  snapshot=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog-json 2>/dev/null) \
    || return 1
  printf '%s\n' "$snapshot" | jq -er --arg id "$id" '
    [.records[] | select(.structured == true and .id == $id)]
    | if length == 1 then .[0] else halt_error(1) end
  '
}
backlog_task_body() {
  backlog_task_record "$1" | jq -er '.body_lines | join("\n")'
}
backlog_task_evidence() {
  local record
  record=$(backlog_task_record "$1") || return 1
  printf '%s' "$record" | jq -cS . | shasum -a 256 | awk '{print $1}'
}
backlog_body_has_receipt() {
  local body=$1 key=$2 line
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "Firstmate terminal receipt: $key" ] || return 0
  done <<EOF
$body
EOF
  return 1
}
bind_backlog_receipt() {
  local id=$1 key=$2 body tmp task
  fm_tasks_axi_compatible || return 3
  body=$(backlog_task_body "$id") || return 1
  backlog_body_has_receipt "$body" "$key" && return 0
  tmp=$(mktemp "$DIR/.backlog-body.XXXXXX") || return 1
  if [ -n "$body" ]; then
    printf '%s\nFirstmate terminal receipt: %s\n' "$body" "$key" > "$tmp"
  else
    printf 'Firstmate terminal receipt: %s\n' "$key" > "$tmp"
  fi
  task=$(fm_run_timed 3 tasks-axi update "$id" --body-file "$tmp" \
    --file "$DATA/backlog.md" --json) || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  printf '%s' "$task" | jq -e '.ok == true' >/dev/null || return 1
  body=$(backlog_task_body "$id") || return 1
  backlog_body_has_receipt "$body" "$key"
}
prepare_backlog_identity() {
  local id=$1 key=$2
  BACKLOG_EVIDENCE=$(backlog_task_evidence "$id") || return 1
  BACKLOG_BINDING=false
  fm_backlog_backend_manual "$CONFIG" && return 0
  bind_backlog_receipt "$id" "$key" || return 1
  BACKLOG_EVIDENCE=$(backlog_task_evidence "$id") || return 1
  BACKLOG_BINDING=true
}
normalize_captain_keys() {
  local input=$1 key normalized=''
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    valid "$key" || return 1
    normalized="${normalized}${normalized:+ }$key"
  done <<EOF
$(printf '%s\n' "$input" | tr ',' '\n')
EOF
  printf '%s\n' "$normalized" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}
resolve_captain_keys() {
  local origin=$1 input=$2 key
  local -a args
  args=("$origin")
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    valid "$key" || return 1
    args+=("$key")
  done <<EOF
$(printf '%s\n' "$input" | tr ',' '\n')
EOF
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
    normalize-inventory "${args[@]}"
}
origin_captain_obligation() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
    origin-obligation "$1"
}
valid_origin_captain_cycle() {
  [ "$1" = none ] && return 0
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}
receipt_captain_obligations() {
  local record=$1
  jq -ce '
    def valid_cycle: . == "none" or (type == "string" and test("^[0-9a-f]{64}$"));
    def valid_keys: type == "string" and (split(",") | all(test("^[A-Za-z0-9._-]+$") or . == ""));
    def normalized_keys:
      split(",") | map(select(length > 0)) | unique | join(",");
    (if has("captain_obligations") then
       .captain_obligations
       | select(type == "array" and length > 0)
     else
       select((.captain_keys | type) == "string")
       | select(.origin_captain_cycle | valid_cycle)
       | [{receipt:.key,origin_cycle:.origin_captain_cycle,captain_keys:.captain_keys,origin_resolved:false}]
     end)
    | select(all(
        type == "object" and
        (.receipt | type == "string" and test("^[0-9a-f]{64}$")) and
        (.origin_cycle | valid_cycle) and
        (.captain_keys | valid_keys) and
        (.origin_resolved | type == "boolean")
      ))
    | sort_by(.receipt,.origin_cycle)
    | group_by([.receipt,.origin_cycle])
    | select(all(.[]; (map(.origin_resolved) | unique | length) == 1))
    | map({
        receipt:.[0].receipt,
        origin_cycle:.[0].origin_cycle,
        captain_keys:(map(.captain_keys) | join(",") | normalized_keys),
        origin_resolved:.[0].origin_resolved
      })
  ' "$record"
}
set_current_captain_obligation() {
  local keys=$1 cycle=$2 reviewed=${3:-} obligations merged current_receipt
  case "$reviewed" in ''|true|false) ;; *) return 1 ;; esac
  valid_origin_captain_cycle "$cycle" || return 1
  current_receipt=$(jq -r .key "$RECORD") || return 1
  valid "$current_receipt" || return 1
  if obligations=$(receipt_captain_obligations "$RECORD"); then
    :
  else
    jq -e 'has("captain_obligations") | not' "$RECORD" >/dev/null || return 1
    obligations='[]'
  fi
  obligations=$(printf '%s\n' "$obligations" | jq -ce \
    --arg receipt "$current_receipt" --arg keys "$keys" --arg cycle "$cycle" '
      ([.[] | select(.receipt == $receipt and .origin_cycle == $cycle)] | length) as $matches
      | ([.[] | select(.receipt == $receipt and .origin_cycle == "none" and .origin_resolved == false)]) as $absence
      | ([.[] | select(.receipt != $receipt and .origin_cycle == "none" and .origin_resolved == false)] | length) as $foreign_absence
      | ([.[] | select(.origin_cycle == $cycle and .origin_resolved == true)]) as $resolved_cycle
      | if $matches == 1 then
          if $cycle != "none" and ($absence | length) > 0 then
            error("unresolved origin absence conflicts with current captain cycle")
          else
            map(if .receipt == $receipt and .origin_cycle == $cycle
                then if .origin_resolved == false
                     then .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
                     else error("current captain obligation is already resolved") end
                else . end)
          end
        elif $matches == 0 then
          if $cycle != "none" and ($resolved_cycle | length) == 1 then
            map(if .origin_cycle == $cycle and .origin_resolved == true
                then .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
                else . end)
          elif $cycle != "none" and ($resolved_cycle | length) > 1 then
            error("ambiguous resolved captain obligation")
          elif $cycle != "none" and $foreign_absence > 0 then
            error("origin absence receipt identity is unauthenticated")
          elif $cycle != "none" and ($absence | length) == 1 then
            ([($absence[0].captain_keys),$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(",")) as $transitioned_keys
            | map(if .receipt == $receipt and .origin_cycle == "none" and .origin_resolved == false
                  then .origin_resolved=true else . end)
            + [{receipt:$receipt,origin_cycle:$cycle,captain_keys:$transitioned_keys,origin_resolved:false}]
          elif ($absence | length) > 1 then
            error("ambiguous origin absence obligation")
          else
            . + [{receipt:$receipt,origin_cycle:$cycle,captain_keys:$keys,origin_resolved:false}]
          end
        else error("ambiguous current captain obligation") end
    ') || return 1
  merged=$(printf '%s\n' "$obligations" | jq -r 'map(.captain_keys) | join(",")') || return 1
  merged=$(normalize_captain_keys "$merged") || return 1
  if [ -n "$reviewed" ]; then
    put --arg keys "$merged" --arg cycle "$cycle" --argjson obligations "$obligations" \
      --argjson reviewed "$reviewed" \
      '.captain_keys=$keys | .origin_captain_cycle=$cycle | .captain_obligations=$obligations | .decisions_reviewed=$reviewed'
  else
    put --arg keys "$merged" --arg cycle "$cycle" --argjson obligations "$obligations" \
      '.captain_keys=$keys | .origin_captain_cycle=$cycle | .captain_obligations=$obligations'
  fi
}
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
  current_metadata_incarnation "$meta" || return 1
  KEY=$(printf '%s' "$id|$INCARNATION" | shasum -a 256 | awk '{print $1}')
  RECORD="$DIR/$KEY.json"
  [ ! -L "$RECORD" ] || return 1
}
supersede_prior_records() {
  local id=$1 current=$RECORD candidate prior_keys prior_cycle prior_receipt prior_resolved
  local inherited_keys current_cycle obligations prior_obligations entry existing
  local -a candidates=()
  jq -e '.captain_keys | type == "string"' "$current" >/dev/null || return 1
  inherited_keys=$(normalize_captain_keys "$(jq -r .captain_keys "$current")") || return 1
  current_cycle=$(jq -r '.origin_captain_cycle // ""' "$current") || return 1
  valid_origin_captain_cycle "$current_cycle" || return 1
  obligations=$(receipt_captain_obligations "$current") || return 1
  for candidate in "$DIR"/*.json; do
    receipt_path_authenticated "$candidate" || continue
    [ "$candidate" != "$current" ] || continue
    jq -e --arg id "$id" \
      '.id == $id and .discarded != true and .backlog != true and .reviewed != true and ((.superseded_by // "") == "")' \
      "$candidate" >/dev/null || continue
    jq -e '.decisions_reviewed == true and (.captain_keys | type == "string")' \
      "$candidate" >/dev/null || return 1
    prior_keys=$(normalize_captain_keys "$(jq -r .captain_keys "$candidate")") || return 1
    inherited_keys=$(normalize_captain_keys "$inherited_keys,$prior_keys") || return 1
    prior_obligations=$(receipt_captain_obligations "$candidate") || return 1
    while IFS='|' read -r prior_receipt prior_cycle prior_keys prior_resolved; do
      [ -n "$prior_receipt" ] || continue
      existing=$(printf '%s\n' "$obligations" | jq -r --arg receipt "$prior_receipt" --arg cycle "$prior_cycle" \
        '[.[] | select(.receipt == $receipt and .origin_cycle == $cycle)] | length') || return 1
      if [ "$existing" -gt 0 ]; then
        obligations=$(printf '%s\n' "$obligations" | jq -ce \
          --arg receipt "$prior_receipt" --arg cycle "$prior_cycle" --arg keys "$prior_keys" '
          map(if .receipt == $receipt and .origin_cycle == $cycle
              then .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
              else . end)
        ') || return 1
        continue
      fi
      existing=$(printf '%s\n' "$obligations" | jq -r --arg cycle "$prior_cycle" \
        '[.[] | select(.origin_cycle == $cycle and .origin_resolved == false)] | length') || return 1
      [ "$existing" -le 1 ] || return 1
      if [ "$existing" -gt 0 ]; then
        if [ "$prior_cycle" != none ]; then
          if [ "$prior_resolved" = true ] ||
            FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
              FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
              terminal-ready "$id" --receipt "$prior_receipt" --origin-cycle "$prior_cycle" \
              --origin-resolved >/dev/null 2>&1; then
            obligations=$(printf '%s\n' "$obligations" | jq -ce \
              --arg receipt "$prior_receipt" --arg cycle "$prior_cycle" --arg keys "$prior_keys" '
              map(if .origin_cycle == $cycle and .origin_resolved == false
                  then .receipt=$receipt
                    | .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
                    | .origin_resolved=true
                  else . end)
            ') || return 1
          else
            obligations=$(printf '%s\n' "$obligations" | jq -ce --arg cycle "$prior_cycle" --arg keys "$prior_keys" '
              map(if .origin_cycle == $cycle and .origin_resolved == false
                  then .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
                  else . end)
            ') || return 1
          fi
        else
          obligations=$(printf '%s\n' "$obligations" | jq -ce --arg cycle "$prior_cycle" --arg keys "$prior_keys" '
            map(if .origin_cycle == $cycle and .origin_resolved == false
                then .captain_keys=([.captain_keys,$keys] | join(",") | split(",") | map(select(length > 0)) | unique | join(","))
                else . end)
          ') || return 1
        fi
        continue
      fi
      if [ "$prior_resolved" != true ] && [ "$prior_cycle" != none ]; then
        FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
          FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
          terminal-ready "$id" --receipt "$prior_receipt" --origin-cycle "$prior_cycle" \
          --origin-resolved >/dev/null 2>&1 || return 1
      fi
      entry=$(jq -cn --arg receipt "$prior_receipt" --arg cycle "$prior_cycle" --arg keys "$prior_keys" \
        '{receipt:$receipt,origin_cycle:$cycle,captain_keys:$keys,origin_resolved:true}') || return 1
      obligations=$(printf '%s\n' "$obligations" | jq -ce --argjson entry "$entry" '. + [$entry]') || return 1
    done <<EOF
$(printf '%s\n' "$prior_obligations" | jq -r '.[] | [.receipt,.origin_cycle,.captain_keys,(.origin_resolved|tostring)] | join("|")')
EOF
    candidates+=("$candidate")
  done
  RECORD=$current
  put --arg keys "$inherited_keys" --argjson obligations "$obligations" \
    '.captain_keys=$keys | .captain_obligations=$obligations' || return 1
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    RECORD=$candidate
    put --arg key "$KEY" '.superseded_by=$key' || { RECORD=$current; return 1; }
  done
  RECORD=$current
}
select_existing_record() {
  select_record_path "$1" || return $?
  receipt_path_authenticated "$RECORD"
}
receipt_path_authenticated() {
  local candidate=$1 name key id incarnation incarnation_kind expected
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  name=${candidate##*/}
  case "$name" in *.json) key=${name%.json} ;; *) return 1 ;; esac
  valid "$key" || return 1
  jq -e --arg key "$key" \
    '.schema == "fm-terminal-delivery.v1" and .key == $key and (.id | type == "string" and length > 0) and (.incarnation | type == "string" and length > 0 and . != "||") and ((.incarnation_kind // "") | . == "" or . == "spawn" or . == "legacy") and ((.backlog_binding // false) | type == "boolean") and ((.backlog_attested // false) | type == "boolean") and ((.backlog_evidence // "") | type == "string")' \
    "$candidate" >/dev/null || return 1
  id=$(jq -r .id "$candidate")
  incarnation=$(jq -r .incarnation "$candidate")
  incarnation_kind=$(jq -r '.incarnation_kind // ""' "$candidate")
  valid "$id" || return 1
  if [ -z "$incarnation_kind" ]; then
    case "$incarnation" in *'|'*) incarnation_kind=legacy ;; *) incarnation_kind=spawn ;; esac
  fi
  if [ "$incarnation_kind" = spawn ]; then
    valid_spawn_incarnation "$incarnation" || return 1
  else
    valid_legacy_incarnation "$incarnation" || return 1
  fi
  expected=$(printf '%s' "$id|$incarnation" | shasum -a 256 | awk '{print $1}')
  [ "$expected" = "$key" ] || return 1
  if jq -e 'has("captain_obligations")' "$candidate" >/dev/null; then
    receipt_captain_obligations "$candidate" >/dev/null
  fi
}
select_authenticated_receipt_key() {
  local key=$1
  valid "$key" || return 2
  RECORD="$DIR/$key.json"
  receipt_path_authenticated "$RECORD"
}
select_captain_review_receipt() {
  local id=$1 key=$2 meta="$STATE/$1.meta" incarnation expected candidate active_key= count=0 metadata_status
  select_authenticated_receipt_key "$key" || return $?
  jq -e --arg id "$id" \
    '.id == $id and .incarnation != "||" and .retired == true and .discarded != true and ((.superseded_by // "") == "")' \
    "$RECORD" >/dev/null || return 1
  if current_metadata_incarnation "$meta"; then
    incarnation=$INCARNATION
    expected=$(printf '%s' "$id|$incarnation" | shasum -a 256 | awk '{print $1}')
    [ "$expected" = "$key" ] || return 1
    return 0
  else
    metadata_status=$?
  fi
  [ "$metadata_status" -eq 3 ] || return 1
  for candidate in "$DIR"/*.json; do
    receipt_path_authenticated "$candidate" || continue
    jq -e --arg id "$id" \
      '.id == $id and .retired == true and .discarded != true and .reviewed != true and ((.superseded_by // "") == "")' \
      "$candidate" >/dev/null || continue
    count=$((count + 1))
    active_key=${candidate##*/}
    active_key=${active_key%.json}
  done
  [ "$count" -eq 1 ] && [ "$active_key" = "$key" ]
}
select_predecessor_review_receipt() {
  local id=$1 key=$2 meta="$STATE/$1.meta" current current_key superseded
  select_record_path "$id" || return $?
  current=$RECORD
  current_key=$KEY
  [ "$current_key" != "$key" ] || return 1
  receipt_path_authenticated "$current" || return 1
  jq -e --arg id "$id" \
    '.id == $id and .discarded != true and .reviewed != true and ((.superseded_by // "") == "")' \
    "$current" >/dev/null || return 1
  select_authenticated_receipt_key "$key" || return $?
  jq -e --arg id "$id" \
    '.id == $id and .incarnation != "||" and .retired != true and .discarded != true and .backlog != true and .refill != true and .reviewed != true' \
    "$RECORD" >/dev/null || return 1
  superseded=$(jq -r '.superseded_by // ""' "$RECORD") || return 1
  [ -z "$superseded" ] || [ "$superseded" = "$current_key" ] || return 1
  PREDECESSOR_CURRENT_KEY=$current_key
}
select_record() {
  local id=$1 meta="$STATE/$1.meta" tmp captain_keys origin_captain_cycle decisions_reviewed=false
  local backlog_binding=false backlog_evidence=
  select_record_path "$id" || return $?
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    receipt_path_authenticated "$RECORD" || return 1
    supersede_prior_records "$id"
    return $?
  fi
  captain_keys=$(resolve_captain_keys "$id" "$(field "$meta" decision_keys)") || return 1
  origin_captain_cycle=$(origin_captain_obligation "$id") || return 1
  valid_origin_captain_cycle "$origin_captain_cycle" || return 1
  [ "$(field "$meta" decisions_reviewed)" != 1 ] || decisions_reviewed=true
  prepare_backlog_identity "$id" "$KEY" || return 1
  backlog_binding=$BACKLOG_BINDING
  backlog_evidence=$BACKLOG_EVIDENCE
  tmp=$(mktemp "$DIR/.receipt.XXXXXX") || return 1
  jq -n --arg id "$id" --arg key "$KEY" --arg incarnation "$INCARNATION" \
    --arg incarnation_kind "$INCARNATION_KIND" --argjson backlog_binding "$backlog_binding" \
    --arg backlog_evidence "$backlog_evidence" \
    --arg kind "$(field "$meta" kind)" --arg mode "$(field "$meta" mode)" --arg pr "$(field "$meta" pr)" \
    --arg captain_keys "$captain_keys" --arg origin_captain_cycle "$origin_captain_cycle" \
    --argjson decisions_reviewed "$decisions_reviewed" \
    '{schema:"fm-terminal-delivery.v1",key:$key,id:$id,incarnation:$incarnation,incarnation_kind:$incarnation_kind,backlog_binding:$backlog_binding,backlog_attested:false,backlog_evidence:$backlog_evidence,kind:$kind,mode:$mode,state:"unknown",pr:$pr,merged:false,retired:false,discarded:false,backlog:false,refill:false,reviewed:false,superseded_by:"",captain_keys:$captain_keys,origin_captain_cycle:$origin_captain_cycle,captain_obligations:[{receipt:$key,origin_cycle:$origin_captain_cycle,captain_keys:$captain_keys,origin_resolved:false}],decisions_reviewed:$decisions_reviewed}' > "$tmp" \
    && mv "$tmp" "$RECORD" \
    && supersede_prior_records "$id"
}
select_retired_record() {
  local id=$1 pr=$2 candidate found= count=0
  valid "$id" || return 2
  for candidate in "$DIR"/*.json; do
    receipt_path_authenticated "$candidate" || continue
    jq -e --arg id "$id" --arg pr "$pr" \
      '.id == $id and ((.superseded_by // "") == "") and (.pr == $pr or .pr == "")' \
      "$candidate" >/dev/null || continue
    count=$((count + 1))
    found=$candidate
  done
  [ "$count" -eq 1 ] || return 1
  jq -e '.retired == true and .reviewed != true and .discarded != true' "$found" >/dev/null || return 1
  RECORD=$found
  KEY=${found##*/}
  KEY=${KEY%.json}
}
select_merge_observation_record() {
  local id=$1 pr=$2 meta="$STATE/$1.meta" current= candidate found= count=0
  local current_pr_matches=0 current_missing=0
  valid "$id" || return 2
  [ -n "$pr" ] || return 2
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    select_record_path "$id" || return 1
    current=$RECORD
    [ "$(field "$meta" pr)" != "$pr" ] || current_pr_matches=1
    if [ -e "$current" ] || [ -L "$current" ]; then
      receipt_path_authenticated "$current" || return 1
      if [ "$current_pr_matches" -eq 1 ]; then
        jq -e --arg id "$id" --arg pr "$pr" '.id == $id and .pr == $pr' \
          "$current" >/dev/null || return 1
      fi
    else
      current_missing=1
    fi
  fi
  for candidate in "$DIR"/*.json; do
    receipt_path_authenticated "$candidate" || continue
    jq -e --arg id "$id" --arg pr "$pr" '.id == $id and .pr == $pr' \
      "$candidate" >/dev/null || continue
    if [ "$candidate" = "$current" ]; then
      [ "$current_pr_matches" -eq 1 ] || continue
    else
      jq -e '.retired == true' "$candidate" >/dev/null || continue
    fi
    count=$((count + 1))
    found=$candidate
  done
  if [ "$current_pr_matches" -eq 1 ] && [ "$current_missing" -eq 1 ]; then
    [ "$count" -eq 0 ] || return 1
    select_record "$id" || return $?
    receipt_path_authenticated "$RECORD" || return 1
    jq -e --arg id "$id" --arg pr "$pr" '.id == $id and .pr == $pr' \
      "$RECORD" >/dev/null || return 1
    return 0
  fi
  [ "$count" -eq 1 ] || return 1
  RECORD=$found
  KEY=${found##*/}
  KEY=${KEY%.json}
}
record_is_unique_unsuperseded() {
  local id candidate count=0 found=
  id=$(jq -r .id "$RECORD") || return 1
  for candidate in "$DIR"/*.json; do
    receipt_path_authenticated "$candidate" || continue
    jq -e --arg id "$id" \
      '.id == $id and ((.superseded_by // "") == "")' \
      "$candidate" >/dev/null || continue
    count=$((count + 1))
    found=$candidate
  done
  [ "$count" -eq 1 ] && [ "$found" = "$RECORD" ]
}
record_backlog_identity_matches() {
  local id body evidence expected
  id=$(jq -r .id "$RECORD") || return 1
  record_is_unique_unsuperseded || return 1
  if jq -e '.backlog_binding == true' "$RECORD" >/dev/null; then
    body=$(backlog_task_body "$id") || return 1
    backlog_body_has_receipt "$body" "$(jq -r .key "$RECORD")"
    return $?
  fi
  jq -e '.backlog_attested == true' "$RECORD" >/dev/null || return 1
  expected=$(jq -r '.backlog_evidence // ""' "$RECORD") || return 1
  [ -n "$expected" ] || return 1
  evidence=$(backlog_task_evidence "$id") || return 1
  [ "$evidence" = "$expected" ]
}
record_matches_current_incarnation() {
  local id meta incarnation metadata_status
  id=$(jq -r .id "$RECORD") || return 1
  meta="$STATE/$id.meta"
  if current_metadata_incarnation "$meta"; then
    incarnation=$INCARNATION
  else
    metadata_status=$?
    [ "$metadata_status" -eq 3 ] && record_backlog_identity_matches && return 0
    return 1
  fi
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
    select_authenticated_receipt_key "$current" || return 1
    jq -e --arg id "$id" --arg key "$current" \
      '.id == $id and .key == $key and .discarded != true' \
      "$RECORD" >/dev/null || return 1
    next=$(jq -r '.superseded_by // ""' "$RECORD") || return 1
    [ -n "$next" ] && valid "$next" && [ "$next" != "$current" ] || return 1
    select_authenticated_receipt_key "$next" || return 1
    jq -e --arg id "$id" --arg key "$next" \
      '.id == $id and .key == $key and .discarded != true' \
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
terminal_completed_exact() {
  local id=$1 key=$2
  select_authenticated_receipt_key "$key" || return $?
  jq -e --arg id "$id" --arg key "$key" \
    '.id == $id and .key == $key and .retired == true and .discarded != true and .backlog == true and ((.superseded_by // "") == "")' \
    "$RECORD" >/dev/null || return 1
  delivery_proven
}
captain_calls_resolved() {
  local id obligations obligation_receipt captain_keys captain_key origin_captain_cycle origin_resolved
  jq -e '.decisions_reviewed == true' "$RECORD" >/dev/null || return 1
  id=$(jq -r .id "$RECORD") || return 1
  obligations=$(receipt_captain_obligations "$RECORD") || return 1
  while IFS='|' read -r obligation_receipt origin_captain_cycle captain_keys origin_resolved; do
    [ -n "$obligation_receipt" ] || continue
    set -- "$id" --receipt "$obligation_receipt" --origin-cycle "$origin_captain_cycle"
    [ "$origin_resolved" != true ] || set -- "$@" --origin-resolved
    while IFS= read -r captain_key; do
      [ -n "$captain_key" ] || continue
      set -- "$@" "$captain_key"
    done <<EOF
$(printf '%s\n' "$captain_keys" | tr ',' '\n')
EOF
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
      terminal-ready "$@" >/dev/null 2>&1 || return 1
  done <<EOF
$(printf '%s\n' "$obligations" | jq -r '.[] | [.receipt,.origin_cycle,.captain_keys,(.origin_resolved|tostring)] | join("|")')
EOF
}
reconcile_record() {
  local id pr state task snapshot retired discarded kind
  local -a args
  [ "$(jq -r .reviewed "$RECORD")" != true ] || return 0
  [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || return 0
  [ "$(jq -r .backlog "$RECORD")" != true ] || return 0
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
if [ "$mode" = completed-after ] || [ "$mode" = completed-exact ] \
  || [ "$mode" = current-incarnation ] || [ "$mode" = receipt-key ]; then
  if [ "$mode" = completed-after ]; then
    [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
    [ "$#" -eq 3 ] && valid "$2" && valid "$3" || exit 2
    terminal_completed_after "$2" "$3"
  elif [ "$mode" = completed-exact ]; then
    [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
    [ "$#" -eq 3 ] && valid "$2" && valid "$3" || exit 2
    terminal_completed_exact "$2" "$3"
  else
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    [ ! -L "$STATE/$2.meta" ] || exit 1
    [ -e "$STATE/$2.meta" ] || exit 3
    select_record_path "$2" || exit 1
    if [ "$mode" = current-incarnation ]; then
      printf '%s\n' "$KEY"
      exit
    fi
    [ -e "$DIR" ] || exit 3
    [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
    [ -e "$RECORD" ] || exit 3
    receipt_path_authenticated "$RECORD" || exit 1
    printf '%s\n' "$KEY"
  fi
  exit
fi
mkdir -p "$DIR" || exit 1
[ ! -L "$DIR" ] || exit 1
fm_lock_acquire_wait "$DIR/.lock" || exit 1
terminal_reconcile_cleanup() {
  [ -z "$RECONCILE_CANDIDATES" ] || rm -f "$RECONCILE_CANDIDATES"
  fm_lock_release "$DIR/.lock"
}
trap terminal_reconcile_cleanup EXIT
case "$mode" in
  landing-proven)
    [ "$#" -eq 2 ] || exit 2
    select_existing_record "$2" || exit 1
    jq -e '.discarded != true and ((.superseded_by // "") == "")' "$RECORD" >/dev/null || exit 1
    delivery_proven || exit 1
    ;;
  observe|custody|merged|merge-observed|local-landed|default-landed|prepare-retirement|retired)
    if [ "$mode" = prepare-retirement ]; then
      [ "$#" -eq 2 ] || exit 2
    else
      [ "$#" -ge 3 ] || exit 2
    fi
    if [ "$mode" = merge-observed ]; then
      select_merge_observation_record "$2" "$3" || exit $?
    elif [ "$mode" = merged ]; then
      if [ -e "$STATE/$2.meta" ] || [ -L "$STATE/$2.meta" ]; then
        select_record "$2" || exit $?
      else
        select_retired_record "$2" "$3" || exit $?
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
      prepare-retirement)
        origin_captain_cycle=$(origin_captain_obligation "$2") || exit 1
        valid_origin_captain_cycle "$origin_captain_cycle" || exit 1
        retirement_decision_keys=$(field "$STATE/$2.meta" decision_keys)
        decisions_reviewed=false
        [ "$(field "$STATE/$2.meta" decisions_reviewed)" != 1 ] || decisions_reviewed=true
        if jq -e --arg raw "$retirement_decision_keys" --arg cycle "$origin_captain_cycle" --argjson reviewed "$decisions_reviewed" \
          '.retirement_prepared == true and (.retirement_decision_keys // "") == $raw and .origin_captain_cycle == $cycle and .decisions_reviewed == $reviewed' \
          "$RECORD" >/dev/null; then
          :
        else
          captain_keys=$(resolve_captain_keys "$2" "$retirement_decision_keys") || exit 1
          set_current_captain_obligation "$captain_keys" "$origin_captain_cycle" || exit 1
          put --arg raw "$retirement_decision_keys" --argjson reviewed "$decisions_reviewed" \
            '.decisions_reviewed=$reviewed | .retirement_prepared=true | .retirement_decision_keys=$raw' \
            || exit 1
        fi ;;
      retired)
        origin_captain_cycle=$(origin_captain_obligation "$2") || exit 1
        valid_origin_captain_cycle "$origin_captain_cycle" || exit 1
        retirement_decision_keys=$(field "$STATE/$2.meta" decision_keys)
        decisions_reviewed=false
        [ "$(field "$STATE/$2.meta" decisions_reviewed)" != 1 ] || decisions_reviewed=true
        if jq -e --arg raw "$retirement_decision_keys" --arg cycle "$origin_captain_cycle" --argjson reviewed "$decisions_reviewed" \
          '.retirement_prepared == true and (.retirement_decision_keys // "") == $raw and .origin_captain_cycle == $cycle and .decisions_reviewed == $reviewed' \
          "$RECORD" >/dev/null; then
          captain_keys=$(jq -r '.captain_keys // ""' "$RECORD") || exit 1
        else
          captain_keys=$(resolve_captain_keys "$2" "$retirement_decision_keys") || exit 1
          set_current_captain_obligation "$captain_keys" "$origin_captain_cycle" || exit 1
        fi
        case "$3" in
          normal) put --argjson reviewed "$decisions_reviewed" \
            '.retired=true | .decisions_reviewed=$reviewed' ;;
          discard) put --argjson reviewed "$decisions_reviewed" \
            '.retired=true | .discarded=true | .decisions_reviewed=$reviewed' ;;
          *) exit 2 ;;
        esac || exit 1 ;;
    esac
    # Producers record facts only; bounded recovery owns backend work.
    ;;
  reconcile)
    deadline=$((SECONDS+8))
    cursor=$(cat "$DIR/.cursor" 2>/dev/null || true)
    RECONCILE_CANDIDATES=$(mktemp "$DIR/.candidates.XXXXXX") || exit 1
    find "$DIR" -type f -name '*.json' -exec cat {} + | jq -r '
      select(.reviewed != true and ((.superseded_by // "") == "") and .discarded != true)
      | .key
      | select(type == "string")
    ' | LC_ALL=C sort -u > "$RECONCILE_CANDIDATES" || exit 1
    for range in after through; do
      while IFS= read -r KEY || [ -n "$KEY" ]; do
        valid "$KEY" || continue
        RECORD="$DIR/$KEY.json"
        receipt_path_authenticated "$RECORD" || continue
        name="$KEY.json"
        if [ "$range" = after ]; then [[ "$name" > "$cursor" ]] || continue
        else [[ "$name" > "$cursor" ]] && continue
        fi
        [ "$SECONDS" -lt "$deadline" ] || exit 0
        # Publish before work so a persistently broken item cannot starve peers.
        cursor_tmp=$(mktemp "$DIR/.cursor.XXXXXX") || exit 1
        printf '%s\n' "$name" > "$cursor_tmp" && mv "$cursor_tmp" "$DIR/.cursor" || exit 1
        reconcile_record || exit 1
      done < "$RECONCILE_CANDIDATES"
    done ;;
  report)
    manual=false
    fm_backlog_backend_manual "$CONFIG" && manual=true
    report_records=()
    for RECORD in "$DIR"/*.json; do
      [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || continue
      report_records+=("$RECORD")
    done
    [ "${#report_records[@]}" -eq 0 ] || {
      for RECORD in "${report_records[@]}"; do
        while IFS= read -r receipt_line || [ -n "$receipt_line" ]; do
          printf '%s\n' "$receipt_line"
        done < "$RECORD"
      done
    } | jq -r --argjson manual "$manual" '
      def valid_origin_cycle:
        (.origin_captain_cycle | type) == "string" and
        (.origin_captain_cycle == "none" or (.origin_captain_cycle | test("^[0-9a-f]{64}$")));
      select(.reviewed!=true and ((.superseded_by // "") == "")) |
      "TERMINAL DELIVERY: \(.id) receipt=\(.key) state=\(.state) pr=\(.pr) merge_proven=\(.merged) default_landed=\((.local_head // .default_head // "") != "") teardown=\(.retired) backlog_done=\(.backlog) refill_pending=\(.refill) discard=\(.discarded) captain_reviewed=\(.decisions_reviewed // false) backlog_bound=\(.backlog_binding // false) backlog_attested=\(.backlog_attested // false)" +
      (if .refill then
        "\nEvaluate current ready work, dependencies and date gates, dispatch eligible work, then run bin/fm-terminal-reconcile.sh refill-reviewed \(.key)\n" + (.ready // "Ready-list refresh pending")
      elif .discarded == true then
        "\nReview the authenticated discard, then run bin/fm-terminal-reconcile.sh discard-reviewed \(.key). This retires presentation without marking delivery or backlog complete."
      elif (valid_origin_cycle | not) then
        "\nOrigin captain-cycle evidence is unknown. Restore the exact active or archived origin record, then run bin/fm-captain-hold.sh complete \(.id) --receipt \(.key) (--none | <task-id>...) to authenticate it before completion."
      elif (.decisions_reviewed // false) != true then
        "\nCaptain-call inventory is not attested. Review every captain call, then run " +
        (if .retired == true then
          "bin/fm-captain-hold.sh complete \(.id) --receipt \(.key)"
        else
          "bin/fm-captain-hold.sh complete \(.id) (--none | <task-id>...). If this exact receipt is a retained predecessor, run bin/fm-terminal-reconcile.sh predecessor-reviewed \(.id) \(.key)"
        end) + " (--none | <task-id>...)."
      elif $manual and .retired and (.discarded != true) and (.kind == "scout" or (.merged and .pr != "") or ((.local_head // .default_head // "") != "")) then
        "\nPreserve captain holds; after manually completing data/backlog.md, run bin/fm-terminal-reconcile.sh manual-complete \(.key). If it refuses, restore the exact task-incarnation metadata and active or archived origin captain-cycle evidence, then retry."
      elif .retired and (.discarded != true) and (.backlog_binding // false) != true and (.backlog_attested // false) != true then
        "\nBacklog identity needs exact receipt review. Verify the current backlog row belongs to this incarnation, then run bin/fm-terminal-reconcile.sh backlog-reviewed \(.key); restore exact task metadata instead if identity is uncertain."
      else
        "\nPreserve captain holds; reconcile PR custody/merge proof and guarded teardown before closing backlog, then dispatch only work whose blockers are gone and date is due."
      end)
    ' || exit 1 ;;
  manual-complete)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    fm_backlog_backend_manual "$CONFIG" || exit 1
    select_authenticated_receipt_key "$2" || exit 1
    [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || exit 1
    jq -e '.backlog != true' "$RECORD" >/dev/null || exit 0
    jq -e '.retired and (.discarded != true)' "$RECORD" >/dev/null || exit 1
    delivery_proven || exit 1
    captain_calls_resolved || exit 1
    id=$(jq -r .id "$RECORD") || exit 1
    meta="$STATE/$id.meta"
    if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
      record_is_unique_unsuperseded || exit 1
      backlog_record=$(backlog_task_record "$id") || exit 1
      [ "$(printf '%s\n' "$backlog_record" | jq -r .state)" = done ] || exit 1
      backlog_evidence=$(printf '%s' "$backlog_record" | jq -cS . | shasum -a 256 | awk '{print $1}') || exit 1
      put --arg ready 'Manual backend: review data/backlog.md for current ready work, dependencies and date gates.' \
        --arg evidence "$backlog_evidence" \
        '.backlog_attested=true | .backlog_evidence=$evidence | .backlog=true | .refill=true | .ready=$ready' \
        || exit 1
    else
      record_matches_current_incarnation || exit 1
      put --arg ready 'Manual backend: review data/backlog.md for current ready work, dependencies and date gates.' \
        '.backlog=true | .refill=true | .ready=$ready' || exit 1
    fi ;;
  backlog-reviewed)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    select_authenticated_receipt_key "$2" || exit 1
    jq -e '.retired == true and .discarded != true and .backlog != true and ((.superseded_by // "") == "")' \
      "$RECORD" >/dev/null || exit 1
    id=$(jq -r .id "$RECORD") || exit 1
    meta="$STATE/$id.meta"
    [ ! -e "$meta" ] && [ ! -L "$meta" ] || exit 1
    record_is_unique_unsuperseded || exit 1
    backlog_evidence=$(backlog_task_evidence "$id") || exit 1
    put --arg evidence "$backlog_evidence" \
      '.backlog_attested=true | .backlog_evidence=$evidence' || exit 1 ;;
  captain-review-state)
    [ "$#" -eq 3 ] && valid "$2" && valid "$3" || exit 2
    select_captain_review_receipt "$2" "$3" || exit 1
    jq -c '{captain_keys:(.captain_keys // ""),origin_captain_cycle:(.origin_captain_cycle // ""),decisions_reviewed:(.decisions_reviewed == true),complete:(.backlog == true or .refill == true or .reviewed == true)}' \
      "$RECORD" ;;
  captain-reviewed)
    [ "$#" -eq 4 ] && valid "$2" && valid "$3" || exit 2
    select_captain_review_receipt "$2" "$3" || exit 1
    captain_keys=$(resolve_captain_keys "$2" "$4") || exit 1
    origin_captain_cycle=$(origin_captain_obligation "$2") || exit 1
    valid_origin_captain_cycle "$origin_captain_cycle" || exit 1
    previous_keys=$(normalize_captain_keys "$(jq -r '.captain_keys // ""' "$RECORD")") || exit 1
    previous_origin_captain_cycle=$(jq -r '.origin_captain_cycle // ""' "$RECORD") || exit 1
    if jq -e '.backlog == true or .refill == true or .reviewed == true' "$RECORD" >/dev/null; then
      if [ "$captain_keys" != "$previous_keys" ]; then
        printf 'Terminal receipt %s is complete; keep its captain inventory unchanged and register new calls against active originating work through fm-captain-hold.sh hold/complete.\n' "$3" >&2
        exit 1
      fi
      if ! valid_origin_captain_cycle "$previous_origin_captain_cycle" \
        || [ "$previous_origin_captain_cycle" != "$origin_captain_cycle" ]; then
        printf 'Terminal receipt %s is complete; keep its origin captain-cycle evidence unchanged.\n' "$3" >&2
        exit 1
      fi
      exit 0
    fi
    combined_keys=$(normalize_captain_keys "$previous_keys,$captain_keys") || exit 1
    [ "$combined_keys" = "$captain_keys" ] || exit 1
    if [ "$(jq -r '.decisions_reviewed // false' "$RECORD")" = true ]; then
      set_current_captain_obligation "$captain_keys" "$origin_captain_cycle"
      exit
    fi
    jq -e '.backlog != true and .refill != true and .reviewed != true' \
      "$RECORD" >/dev/null || exit 1
    set_current_captain_obligation "$captain_keys" "$origin_captain_cycle" true ;;
  predecessor-reviewed)
    [ "$#" -ge 4 ] && valid "$2" && valid "$3" || exit 2
    predecessor_id=$2
    predecessor_key=$3
    shift 3
    predecessor_supplied=
    if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
      :
    else
      for predecessor_entry in "$@"; do
        [ "$predecessor_entry" != --none ] || exit 2
        valid "$predecessor_entry" || exit 2
        predecessor_supplied="${predecessor_supplied}${predecessor_supplied:+,}$predecessor_entry"
      done
    fi
    select_predecessor_review_receipt "$predecessor_id" "$predecessor_key" || exit 1
    previous_keys=$(normalize_captain_keys "$(jq -r '.captain_keys // ""' "$RECORD")") || exit 1
    captain_keys=$(resolve_captain_keys "$predecessor_id" "$predecessor_supplied") || exit 1
    combined_keys=$(normalize_captain_keys "$previous_keys,$captain_keys") || exit 1
    [ "$combined_keys" = "$captain_keys" ] || exit 1
    predecessor_superseded=$(jq -r '.superseded_by // ""' "$RECORD") || exit 1
    if [ -n "$predecessor_superseded" ]; then
      [ "$captain_keys" = "$previous_keys" ] || exit 1
      [ "$(jq -r '.decisions_reviewed // false' "$RECORD")" = true ] || exit 1
      exit 0
    fi
    origin_captain_cycle=$(jq -r '.origin_captain_cycle // ""' "$RECORD") || exit 1
    valid_origin_captain_cycle "$origin_captain_cycle" || exit 1
    set_current_captain_obligation "$captain_keys" "$origin_captain_cycle" true || exit 1
    select_record "$predecessor_id" || exit 1
    [ "$KEY" = "$PREDECESSOR_CURRENT_KEY" ] || exit 1 ;;
  discard-reviewed)
    [ "$#" -eq 2 ] || exit 2
    select_authenticated_receipt_key "$2" || exit 1
    [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || exit 1
    jq -e '.retired and .discarded and (.backlog != true) and (.refill != true)' \
      "$RECORD" >/dev/null || exit 1
    put '.reviewed=true' ;;
  refill-reviewed)
    [ "$#" -eq 2 ] && valid "$2" || exit 2
    select_authenticated_receipt_key "$2" || exit 1
    [ -z "$(jq -r '.superseded_by // ""' "$RECORD")" ] || exit 1
    jq -e '.backlog and .refill' "$RECORD" >/dev/null || exit 1
    put '.reviewed=true' ;;
  *) exit 2 ;;
esac
