#!/usr/bin/env bash

fm_supervision_registry_dir() { printf '%s/.active-supervision-v1\n' "$1"; }
fm_supervision_registry_generation_path() { printf '%s/.active-supervision-generation\n' "$1"; }
fm_supervision_registry_lock_path() { printf '%s/.active-supervision.lock\n' "$1"; }
fm_supervision_registry_sequence_path() { printf '%s/.active-supervision-sequence\n' "$1"; }
fm_supervision_registry_incarnation_sequence_path() { printf '%s/.active-supervision-incarnation-sequence\n' "$1"; }
fm_supervision_registry_transaction_root() { printf '%s/.active-supervision-transactions-v1\n' "$1"; }

fm_supervision_registry_task_valid() {
  case "$1" in ''|.*|*/*|*[$'\t\r\n']*) return 1 ;; esac
}

# Canonical byte-preserving row encoder for ephemeral supervision inventories.
# Metadata values may contain ordinary backslashes and spaces, so rows are
# emitted field-by-field and never reconstructed through printf %b or eval.
# Tabs/newlines are the only forbidden bytes because this protocol is TSV.
fm_supervision_tsv_row() {
  local first=1 field
  [ "$#" -gt 0 ] || return 1
  for field in "$@"; do
    case "$field" in *[$'\t\r\n']*) return 1 ;; esac
    if [ "$first" -eq 1 ]; then
      printf '%s' "$field" || return 1
      first=0
    else
      printf '\t%s' "$field" || return 1
    fi
  done
  printf '\n'
}

# Allocate a durable, non-reusable worker incarnation while holding the same
# lifecycle lock that serializes registry publication.  The sequence survives
# process restarts and deliberately has no caller-selected/replay form.
fm_supervision_registry_allocate_incarnation() {  # <state> <task>
  local state=$1 task=$2 lock path current=0 protocol sequence tmp key rc=0
  [ "$#" -eq 2 ] || return 1
  fm_supervision_registry_task_valid "$task" || return 1
  mkdir -p "$state" || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_incarnation_sequence_path "$state")
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    IFS="$(printf '\t')" read -r protocol sequence < "$path" || rc=1
    [ "$protocol" = fm-supervision-incarnation.v1 ] || rc=1
    case "$sequence" in ''|*[!0-9]*) rc=1 ;; esac
    [ "$rc" -ne 0 ] || current=$sequence
  elif [ -e "$path" ] || [ -L "$path" ]; then
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    current=$((current + 1))
    tmp=$(umask 077; mktemp "$state/.active-supervision-incarnation-sequence.XXXXXX") || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    if ! printf 'fm-supervision-incarnation.v1\t%s\n' "$current" > "$tmp" \
      || ! mv -f -- "$tmp" "$path"; then
      rm -f -- "$tmp"
      rc=1
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    key=$(fm_supervision_registry_task_key "$task") || rc=1
    [ "$rc" -ne 0 ] || printf 'i%s.%s\n' "$current" "$key"
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_transaction_dir() {  # <state> <task>
  printf '%s/%s' "$(fm_supervision_registry_transaction_root "$1")" \
    "$(fm_supervision_registry_task_key "$2")"
}

fm_supervision_registry_remote_meta_valid() { # <meta> <task> <spawn> <phase> <backend> <target> <host>
  local meta=$1 task=$2 spawn_gen=$3 phase=$4 backend=$5 target=$6 host=$7
  local value worktree project remote_root remote_target
  [ "$(fm_backend_meta_exact_value "$meta" endpoint_task_id 2>/dev/null || true)" = "$task" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" spawn_gen 2>/dev/null || true)" = "$spawn_gen" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" window 2>/dev/null || true)" = "remote:$task" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" kind 2>/dev/null || true)" = secondmate ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" mode 2>/dev/null || true)" = secondmate ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" remote_host 2>/dev/null || true)" = "$host" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" remote_backend 2>/dev/null || true)" = herdr ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" remote_herdr_session 2>/dev/null || true)" = fm-remote ] || return 1
  worktree=$(fm_backend_meta_exact_value "$meta" worktree 2>/dev/null || true)
  project=$(fm_backend_meta_exact_value "$meta" project 2>/dev/null || true)
  remote_root=$(fm_backend_meta_exact_value "$meta" remote_root 2>/dev/null || true)
  [ -n "$worktree" ] && [ -n "$project" ] && [ "$project" = "$remote_root" ] || return 1
  [ "$(fm_backend_meta_exact_value "$meta" home 2>/dev/null || true)" = "$worktree" ] || return 1
  value=$(fm_backend_meta_exact_value "$meta" harness 2>/dev/null || true); [ -n "$value" ] || return 1
  remote_target=$(fm_backend_meta_exact_value "$meta" remote_target 2>/dev/null || true)
  case "$phase:$backend" in
    remote-unknown:remote) [ "$target" = "remote:$task" ] && [ "$remote_target" = unknown ] ;;
    created:remote-herdr) [ "$remote_target" = "$target" ] && [ "${target%%:*}" = fm-remote ] ;;
    *) return 1 ;;
  esac
}

fm_supervision_registry_staged_meta_valid() { # <meta> <task> <spawn> <phase> <backend> <target> <detail>
  local meta=$1 task=$2 spawn_gen=$3 phase=$4 backend=$5 target=$6 detail=$7 validated_target
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" spawn_gen)" = "$spawn_gen" ] || return 1
  case "$backend" in
    remote|remote-herdr)
      fm_supervision_registry_remote_meta_valid \
        "$meta" "$task" "$spawn_gen" "$phase" "$backend" "$target" "$detail"
      ;;
    *)
      fm_backend_validate_task_endpoint "$meta" "$task" >/dev/null 2>&1 || return 1
      [ "$FM_BACKEND_VALIDATED_BACKEND" = "$backend" ] || return 1
      validated_target=$FM_BACKEND_VALIDATED_TARGET
      if [ "$backend" = tmux ]; then
        [ "$validated_target" = "$detail" ]
      else
        [ "$validated_target" = "$target" ]
      fi
      ;;
  esac
}

fm_supervision_registry_transaction_write_locked() {  # <state> <task> <spawn> <owner-pid> <owner-identity> <phase> <backend> <target> <detail> [meta]
  local state=$1 task=$2 spawn_gen=$3 owner_pid=$4 owner_identity=$5 phase=$6
  local backend=$7 target=$8 detail=$9 meta=${10:-} root dir record tmp staged_tmp
  root=$(fm_supervision_registry_transaction_root "$state")
  dir=$(fm_supervision_registry_transaction_dir "$state" "$task") || return 1
  mkdir -p "$root" "$dir" || return 1
  if [ -n "$meta" ]; then
    fm_supervision_registry_staged_meta_valid \
      "$meta" "$task" "$spawn_gen" "$phase" "$backend" "$target" "$detail" || return 1
    staged_tmp="$dir/meta.tmp.${BASHPID:-$$}"
    if ! cp -p -- "$meta" "$staged_tmp" || ! chmod 0600 "$staged_tmp" \
      || ! mv -f -- "$staged_tmp" "$dir/meta"; then
      rm -f -- "$staged_tmp"
      return 1
    fi
  fi
  record="$dir/record"
  tmp="$dir/record.tmp.${BASHPID:-$$}"
  {
    printf 'fm-supervision-transaction.v2\n'
    printf 'task=%s\nspawn_gen=%s\nowner_pid=%s\n' "$task" "$spawn_gen" "$owner_pid"
    printf 'owner_identity=%s\nphase=%s\nbackend=%s\ntarget=%s\ndetail=%s\n' \
      "$owner_identity" "$phase" "$backend" "$target" "$detail"
    if [ -f "$dir/meta" ] && [ ! -L "$dir/meta" ]; then printf 'metadata=staged\n'; else printf 'metadata=none\n'; fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_supervision_registry_transaction_remove_locked() {  # <state> <task>
  local dir
  dir=$(fm_supervision_registry_transaction_dir "$1" "$2") || return 1
  [ ! -e "$dir" ] && [ ! -L "$dir" ] && return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  rm -f -- "$dir/record" "$dir/meta" || return 1
  rmdir "$dir"
}

fm_supervision_registry_transaction_meta_locked() {  # <state> <task> <spawn> <phase> <backend> <target>
  local dir record protocol task spawn owner_pid owner_identity phase backend target detail metadata
  dir=$(fm_supervision_registry_transaction_dir "$1" "$2") || return 1
  record="$dir/record"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  IFS= read -r protocol < "$record" || return 1
  case "$protocol" in fm-supervision-transaction.v1|fm-supervision-transaction.v2) ;; *) return 1 ;; esac
  task=$(fm_meta_get "$record" task); spawn=$(fm_meta_get "$record" spawn_gen)
  phase=$(fm_meta_get "$record" phase); backend=$(fm_meta_get "$record" backend)
  target=$(fm_meta_get "$record" target); metadata=$(fm_meta_get "$record" metadata)
  [ "$task" = "$2" ] && [ "$spawn" = "$3" ] && [ "$phase" = "$4" ] \
    && [ "$backend" = "$5" ] && [ "$target" = "$6" ] && [ "$metadata" = staged ] || return 1
  [ -f "$dir/meta" ] && [ ! -L "$dir/meta" ] || return 1
  fm_supervision_registry_staged_meta_valid \
    "$dir/meta" "$2" "$3" "$4" "$5" "$6" "$(fm_meta_get "$record" detail)" || return 1
  printf '%s\n' "$dir/meta"
}

fm_supervision_registry_snapshot_header() {
  local state=$1 sequence_path path current=0 snapshot_generation snapshot_sequence tmp
  sequence_path=$(fm_supervision_registry_sequence_path "$state")
  if [ -f "$sequence_path" ] && [ ! -L "$sequence_path" ]; then
    current=$(cat "$sequence_path" 2>/dev/null || true)
    case "$current" in ''|*[!0-9]*) return 1 ;; esac
  elif [ -e "$sequence_path" ] || [ -L "$sequence_path" ]; then
    return 1
  fi
  path=$(fm_supervision_registry_generation_path "$state")
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    IFS="$(printf '\t')" read -r _protocol snapshot_generation < "$path" || return 1
    case "$snapshot_generation" in
      g*)
        snapshot_sequence=${snapshot_generation#g}
        case "$snapshot_sequence" in ''|*[!0-9]*) snapshot_sequence=0 ;; esac
        [ "$snapshot_sequence" -le "$current" ] || current=$snapshot_sequence
        ;;
    esac
  fi
  current=$((current + 1))
  tmp=$(umask 077; mktemp "$state/.active-supervision-sequence.XXXXXX") || return 1
  if ! printf '%s\n' "$current" > "$tmp" || ! mv -f -- "$tmp" "$sequence_path"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf 'fm-active-supervision.v6\tg%s\n' "$current"
}

fm_supervision_registry_snapshot_valid() {
  local path=$1 protocol generation generation_sequence kind task field3 field4 field5 field6 field7 field8 field9
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS="$(printf '\t')" read -r protocol generation < "$path" || return 1
  case "$protocol" in fm-active-supervision.v2|fm-active-supervision.v3|fm-active-supervision.v4|fm-active-supervision.v5|fm-active-supervision.v6) ;; *) return 1 ;; esac
  [ -n "$generation" ] || return 1
  if [ "$protocol" = fm-active-supervision.v5 ] || [ "$protocol" = fm-active-supervision.v6 ]; then
    case "$generation" in g*) generation_sequence=${generation#g} ;; *) return 1 ;; esac
    case "$generation_sequence" in ''|*[!0-9]*) return 1 ;; esac
  fi
  while IFS="$(printf '\t')" read -r kind task field3 field4 field5 field6 field7 field8 field9; do
    [ -n "$kind" ] || continue
    fm_supervision_registry_task_valid "$task" || return 1
    case "$kind" in
      entry)
        [ -n "$field3" ] || return 1
        case "$field4" in pending|active) ;; *) return 1 ;; esac
        [ -z "$field5" ] || return 1
        ;;
      reservation)
        [ -n "$field3" ] || return 1
        case "$field4" in *[!0-9]*|'') return 1 ;; esac
        [ -n "$field5" ] || return 1
        case "$protocol" in
          fm-active-supervision.v2|fm-active-supervision.v3)
            [ -z "$field6$field7$field8$field9" ] || return 1
            ;;
          *)
            case "$field6" in reserved|created|remote-unknown) ;; *) return 1 ;; esac
            case "$field7$field8$field9" in *[$'\t\r\n']*) return 1 ;; esac
            [ -n "$field7" ] && [ -n "$field8" ] && [ -n "$field9" ] || return 1
            ;;
        esac
        ;;
      *) return 1 ;;
    esac
  done < <(sed '1d' "$path")
}

fm_supervision_registry_recover_reservation_meta_locked() {
  local state=$1 task=$2 spawn_gen=$3 phase=$4 backend=$5 target=$6 detail=$7
  local recovery_path=${8:-} meta tmp old kind worktree project
  meta="$state/$task.meta"
  tmp=$(umask 077; mktemp "$state/.$task.meta.recovery.XXXXXX") || return 1
  old=
  [ -f "$meta" ] && [ ! -L "$meta" ] && old=$meta
  if [ "$backend" = remote ] || [ "$backend" = remote-herdr ]; then
    {
      printf 'window=remote:%s\n' "$task"
      printf 'endpoint_task_id=%s\n' "$task"
      printf 'kind=secondmate\nmode=secondmate\nyolo=off\n'
      printf 'remote_host=%s\nremote_backend=herdr\n' "$detail"
      [ "$backend" != remote-herdr ] || printf 'remote_target=%s\n' "$target"
      printf 'spawn_gen=%s\n' "$spawn_gen"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    kind=$(fm_meta_get "$old" kind); [ -n "$kind" ] || kind=ship
    worktree=$(fm_meta_get "$old" worktree); [ -n "$worktree" ] || worktree=$recovery_path
    project=$(fm_meta_get "$old" project); [ -n "$project" ] || project=$recovery_path
    {
      if [ "$backend" = orca ]; then
        printf 'window=fm-%s\nterminal=%s\n' "$task" "$target"
        [ "$detail" = - ] || printf 'orca_worktree_id=%s\n' "$detail"
      else
        printf 'window=%s\n' "$target"
      fi
      printf 'endpoint_task_id=%s\nkind=%s\nspawn_gen=%s\n' "$task" "$kind" "$spawn_gen"
      [ "$backend" = tmux ] || printf 'backend=%s\n' "$backend"
      [ -z "$worktree" ] || [ "$worktree" = - ] || printf 'worktree=%s\n' "$worktree"
      [ -z "$project" ] || [ "$project" = - ] || printf 'project=%s\n' "$project"
    } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  if [ -n "$old" ]; then
    awk -F= '
      BEGIN { split("harness tasktmp model effort home projects", keys, " "); for (i in keys) keep[keys[i]]=1 }
      $1 in keep && !seen[$1]++ { print }
    ' "$old" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  mv -f -- "$tmp" "$meta"
}

fm_supervision_registry_remote_recovery() {
  local meta=$1 task=$2 host=$3 script_dir root parent_home data budget output parsed
  local remote_root remote_home
  remote_root=$(fm_backend_meta_exact_value "$meta" remote_root 2>/dev/null || true)
  remote_home=$(fm_backend_meta_exact_value "$meta" home 2>/dev/null || true)
  [ -n "$remote_root" ] && [ -n "$remote_home" ] || return 1
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  root=$(cd "$script_dir/.." && pwd) || return 1
  parent_home=${FM_HOME:-$root}
  data=${FM_DATA_OVERRIDE:-$parent_home/data}
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$script_dir/fm-timeout-lib.sh"
  budget=${FM_SEND_REMOTE_BUDGET:-30}
  case "$budget" in ''|*[!0-9]*|0) return 1 ;; esac
  output=$(FM_HOME="$parent_home" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$root}" \
    FM_DATA_OVERRIDE="$data" FM_ON_EXPECTED_REMOTE_HOST="$host" \
    FM_ON_EXPECTED_REMOTE_ROOT="$remote_root" FM_ON_EXPECTED_REMOTE_HOME="$remote_home" \
    fm_run_timed "$budget" "$script_dir/fm-on.sh" "$task" \
      fm-remote-secondmate-control.sh recovery "$task" 2>/dev/null) || return 1
  parsed=$(printf '%s\n' "$output" | awk -F= '
    BEGIN { OFS="\t" }
    {
      key=$1
      value=substr($0, length(key) + 2)
      if (key == "schema" || key == "state" || key == "backend" ||
          key == "target" || key == "herdr_session" || key == "harness") {
        if (++seen[key] > 1) exit 2
        field[key]=value
      } else if ($0 != "") exit 2
    }
    END {
      if (field["schema"] != "fm-remote-secondmate-recovery.v1" ||
          field["state"] !~ /^(alive|dead|missing|unreadable|unverified)$/) exit 2
      if (field["state"] == "alive" || field["state"] == "dead") {
        if (field["backend"] != "herdr" || field["target"] !~ /^fm-remote:.+/ ||
            field["herdr_session"] != "fm-remote" || field["harness"] == "") exit 2
      }
      print field["state"], field["target"], field["harness"]
    }
  ') || return 1
  printf '%s\n' "$parsed"
}

fm_supervision_registry_reconcile_locked() {
  local state=$1 path protocol generation kind task spawn_gen owner_pid owner_identity reservation_phase backend target detail meta current identity verdict
  local recovery_identity recovery_state recovery_path recovery_target transaction_meta recovery_result recovery_tmp
  local recovery_harness expected_harness
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_snapshot_valid "$path" || return 1
  IFS="$(printf '\t')" read -r protocol generation < "$path" || return 1
  while IFS="$(printf '\t')" read -r kind task spawn_gen owner_pid owner_identity reservation_phase backend target detail; do
    [ "$kind" = reservation ] || continue
    [ -n "$reservation_phase" ] || reservation_phase=reserved
    meta="$state/$task.meta"
    current=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      current=$(fm_meta_get "$meta" spawn_gen)
      [ -n "$current" ] || current=-
    fi
    identity=$(fm_pid_identity "$owner_pid" 2>/dev/null || true)
    [ -n "$identity" ] && [ "$identity" = "$owner_identity" ] && continue
    if [ "$current" = "$spawn_gen" ]; then
      fm_supervision_registry_write_locked "$state" "$task" "$meta" pending set || return 1
      continue
    fi
    case "$reservation_phase" in
      created|remote-unknown)
        verdict=unverified
        recovery_state=unverified
        recovery_path=-
        recovery_target=$target
        case "$backend:$target" in
          remote:remote:*)
            transaction_meta=$(fm_supervision_registry_transaction_meta_locked \
              "$state" "$task" "$spawn_gen" "$reservation_phase" "$backend" "$target" 2>/dev/null || true)
            [ -n "$transaction_meta" ] || return 1
            recovery_result=$(fm_supervision_registry_remote_recovery \
              "$transaction_meta" "$task" "$detail" 2>/dev/null) || continue
            IFS="$(printf '\t')" read -r verdict recovery_target recovery_harness <<EOF
$recovery_result
EOF
            if [ "$verdict" = missing ]; then
              fm_supervision_registry_write_locked "$state" "$task" '' '' cancel || return 1
              continue
            fi
            case "$verdict:$recovery_target" in
              alive:fm-remote:*|dead:fm-remote:*) ;;
              *) continue ;;
            esac
            case "$recovery_target" in *[$'\t\r\n']*) continue ;; esac
            expected_harness=$(fm_backend_meta_exact_value "$transaction_meta" harness 2>/dev/null || true)
            [ -n "$expected_harness" ] && [ "$recovery_harness" = "$expected_harness" ] || continue
            recovery_tmp=$(umask 077; mktemp "$state/.$task.meta.remote-recovery.XXXXXX") || return 1
            if ! awk -F= -v target="$recovery_target" '
                $1 == "remote_target" { if (++seen > 1) exit 2; print "remote_target=" target; next }
                { print }
                END { if (seen != 1) exit 2 }
              ' "$transaction_meta" > "$recovery_tmp" \
              || ! fm_supervision_registry_staged_meta_valid \
                "$recovery_tmp" "$task" "$spawn_gen" created remote-herdr "$recovery_target" "$detail" \
              || ! mv -f -- "$recovery_tmp" "$meta"; then
              rm -f -- "$recovery_tmp"
              return 1
            fi
            fm_supervision_registry_write_locked "$state" "$task" "$meta" pending set || return 1
            continue
            ;;
          remote-herdr:fm-remote:*) ;;
          tmux:@*)
            recovery_identity=$(fm_backend_reservation_identity "$backend" "$target" "$detail") \
              || recovery_identity=$'unverified\t-'
            IFS="$(printf '\t')" read -r recovery_state recovery_path <<EOF
$recovery_identity
EOF
            verdict=$(printf '%s\t%s\tlocal\t-\n' "$backend" "$detail" \
              | fm_backend_agent_state_batch 2>/dev/null \
              | awk -F '\t' 'NR == 1 { print $3 }') || verdict=unreadable
            [ -n "$verdict" ] || verdict=unreadable
            case "$recovery_state:$recovery_path:$verdict" in
              match:-:*) verdict=unverified ;;
              match:*:missing) verdict=unverified ;;
              match:*:*) recovery_target=$detail ;;
              unverified:*:missing) ;;
              *) verdict=unverified ;;
            esac
            ;;
          *)
            verdict=$(printf '%s\t%s\tlocal\t-\n' "$backend" "$target" \
              | fm_backend_agent_state_batch 2>/dev/null \
              | awk -F '\t' 'NR == 1 { print $3 }') || verdict=unreadable
            [ -n "$verdict" ] || verdict=unreadable
            ;;
        esac
        if [ "$verdict" = missing ]; then
          fm_supervision_registry_write_locked "$state" "$task" '' '' cancel || return 1
          continue
        fi
        if [ "$backend" = tmux ] && [ "$recovery_state" = match ] && [ "$verdict" = dead ]; then
          if fm_backend_retire_reservation "$backend" "$target"; then
            fm_supervision_registry_write_locked "$state" "$task" '' '' cancel || return 1
            continue
          fi
          verdict=unverified
          recovery_target=$target
          recovery_path=-
        fi
        transaction_meta=$(fm_supervision_registry_transaction_meta_locked \
          "$state" "$task" "$spawn_gen" "$reservation_phase" "$backend" "$target" 2>/dev/null || true)
        if [ -n "$transaction_meta" ]; then
          cp -p -- "$transaction_meta" "$meta" || return 1
          fm_supervision_registry_staged_meta_valid \
            "$meta" "$task" "$spawn_gen" "$reservation_phase" "$backend" "$target" "$detail" || return 1
        elif [ "$protocol" = fm-active-supervision.v6 ]; then
          return 1
        else
          fm_supervision_registry_recover_reservation_meta_locked \
            "$state" "$task" "$spawn_gen" "$reservation_phase" "$backend" "$recovery_target" "$detail" "$recovery_path" || return 1
        fi
        fm_supervision_registry_write_locked "$state" "$task" "$state/$task.meta" pending set || return 1
        continue
        ;;
    esac
    fm_supervision_registry_write_locked "$state" "$task" '' '' cancel || return 1
  done < <(sed '1d' "$path")
}

fm_supervision_registry_generation() {
  local state=$1 path protocol generation lock rc=0
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_reconcile_locked "$state" || rc=1
  fm_supervision_registry_snapshot_valid "$path" || rc=1
  if [ "$rc" -eq 0 ]; then
    IFS="$(printf '\t')" read -r protocol generation < "$path" || rc=1
  fi
  [ "$rc" -ne 0 ] || printf '%s\n' "$generation"
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_write_locked() {
  local state=$1 task=${2:-} meta=${3:-} phase=${4:-} operation=${5:-set}
  local owner_pid=${6:-} owner_identity=${7:-} reservation_phase=${8:-reserved}
  local reservation_backend=${9:--} reservation_target=${10:--} reservation_detail=${11:--}
  local path tmp ordered kind existing_task field3 field4 field5 field6 field7 field8 field9 spawn_gen header entries
  path=$(fm_supervision_registry_generation_path "$state")
  tmp=$(umask 077; mktemp "$state/.active-supervision-generation.XXXXXX") || return 1
  ordered="$tmp.ordered"
  fm_supervision_registry_snapshot_header "$state" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -f "$path" ]; then
    fm_supervision_registry_snapshot_valid "$path" || { rm -f -- "$tmp"; return 1; }
    while IFS="$(printf '\t')" read -r kind existing_task field3 field4 field5 field6 field7 field8 field9; do
      if [ "$existing_task" = "$task" ]; then
        case "$operation:$kind" in
          cancel:entry|reserve:entry) ;;
          *) continue ;;
        esac
      fi
      case "$kind" in
        entry) printf 'entry\t%s\t%s\t%s\n' "$existing_task" "$field3" "$field4" >> "$tmp" ;;
        reservation)
          [ -n "$field6" ] || { field6=reserved; field7=-; field8=-; field9=-; }
          printf 'reservation\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$existing_task" "$field3" "$field4" "$field5" "$field6" "$field7" "$field8" "$field9" >> "$tmp"
          ;;
      esac || { rm -f -- "$tmp"; return 1; }
    done < <(sed '1d' "$path")
  fi
  if [ "$operation" = set ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f -- "$tmp"; return 1; }
    spawn_gen=$(fm_meta_get "$meta" spawn_gen); [ -n "$spawn_gen" ] || spawn_gen=-
    printf 'entry\t%s\t%s\t%s\n' "$task" "$spawn_gen" "$phase" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  elif [ "$operation" = reserve ]; then
    printf 'reservation\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$task" "$meta" "$owner_pid" "$owner_identity" "$reservation_phase" \
      "$reservation_backend" "$reservation_target" "$reservation_detail" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  fi
  header=$(sed -n '1p' "$tmp")
  entries=$(sed '1d' "$tmp" | LC_ALL=C sort -t "$(printf '\t')" -k2,2)
  if ! { printf '%s\n' "$header"; [ -z "$entries" ] || printf '%s\n' "$entries"; } > "$ordered" \
    || ! mv -f -- "$ordered" "$path"; then
    rm -f -- "$tmp" "$ordered"
    return 1
  fi
  rm -f -- "$tmp"
  case "$operation" in set|cancel|remove)
    [ -z "$task" ] || fm_supervision_registry_transaction_remove_locked "$state" "$task" || return 1
    ;;
  esac
}

fm_supervision_registry_reserve() {
  local state=$1 task=$2 spawn_gen=$3 owner_pid=${4:-${BASHPID:-$$}} owner_identity=${5:-}
  local lock rc
  fm_supervision_registry_task_valid "$task" || return 1
  [ -n "$spawn_gen" ] || return 1
  [ -n "$owner_identity" ] || owner_identity=$(fm_pid_identity "$owner_pid") || return 1
  [ -f "$(fm_supervision_registry_generation_path "$state")" ] \
    || fm_supervision_registry_recover "$state" || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  fm_supervision_registry_reconcile_locked "$state" \
    && fm_supervision_registry_transaction_write_locked "$state" "$task" "$spawn_gen" \
      "$owner_pid" "$owner_identity" reserved - - - \
    && fm_supervision_registry_write_locked "$state" "$task" "$spawn_gen" '' reserve "$owner_pid" "$owner_identity"
  rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_mark_reservation() {
  local state=$1 task=$2 spawn_gen=$3 phase=$4 backend=$5 target=$6 detail=${7:--} staged_meta=${8:-}
  local lock path protocol generation kind entry_task entry_spawn owner_pid owner_identity rc=1
  case "$phase" in created|remote-unknown) ;; *) return 1 ;; esac
  case "$backend$target$detail" in *[$'\t\r\n']*) return 1 ;; esac
  [ -n "$backend" ] && [ -n "$target" ] && [ -n "$detail" ] || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  if fm_supervision_registry_snapshot_valid "$path"; then
    IFS="$(printf '\t')" read -r protocol generation < "$path" || protocol=
    [ "$protocol" != fm-active-supervision.v6 ] || [ -n "$staged_meta" ] || {
      fm_lock_release "$lock"
      return 1
    }
    while IFS="$(printf '\t')" read -r kind entry_task entry_spawn owner_pid owner_identity _old_phase _old_backend _old_target _old_detail; do
      [ "$kind" = reservation ] && [ "$entry_task" = "$task" ] && [ "$entry_spawn" = "$spawn_gen" ] || continue
      fm_supervision_registry_transaction_write_locked "$state" "$task" "$spawn_gen" \
        "$owner_pid" "$owner_identity" "$phase" "$backend" "$target" "$detail" "$staged_meta" \
        && fm_supervision_registry_write_locked "$state" "$task" "$spawn_gen" '' reserve \
          "$owner_pid" "$owner_identity" "$phase" "$backend" "$target" "$detail"
      rc=$?
      break
    done < <(sed '1d' "$path")
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_cancel_reservation() {
  local state=$1 task=$2 spawn_gen=$3 expected_phase=${4:-any}
  local lock path kind entry_task entry_spawn field4 field5 field6 field7 field8 field9 found=0 rc=0
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_snapshot_valid "$path" || rc=1
  if [ "$rc" -eq 0 ]; then
    while IFS="$(printf '\t')" read -r kind entry_task entry_spawn field4 field5 field6 field7 field8 field9; do
      [ "$kind" = reservation ] && [ "$entry_task" = "$task" ] && [ "$entry_spawn" = "$spawn_gen" ] || continue
      [ -n "$field6" ] || field6=reserved
      [ "$expected_phase" = any ] || [ "$expected_phase" = "$field6" ] || continue
      found=1
    done < <(sed '1d' "$path")
  fi
  [ "$rc" -ne 0 ] || [ "$found" -eq 0 ] \
    || fm_supervision_registry_write_locked "$state" "$task" '' '' cancel || rc=1
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_death_owner_id() {
  printf '%s\0%s\0%s' "$2" "$3" "$1" | od -An -v -tx1 | tr -d ' \n'
}

fm_supervision_death_state_path() {
  local state=$1 family=$2 encoded=$3 root path chunk
  root="$state/.$family-v3"
  path=$root
  while [ "${#encoded}" -gt 120 ]; do
    chunk=${encoded:0:120}
    path="$path/$chunk"
    encoded=${encoded:120}
  done
  printf '%s/%s' "$path" "${encoded:-00}"
}

fm_supervision_legacy_death_key() {
  printf '%s' "$1" | tr ':/' '__' | tr '.' '_'
}

fm_supervision_registry_set() {
  local state=$1 task=$2 meta=${3:-$1/$2.meta} phase=${4:-active} lock rc
  fm_supervision_registry_task_valid "$task" || return 1
  case "$phase" in pending|active) ;; *) return 1 ;; esac
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -f "$(fm_supervision_registry_generation_path "$state")" ] \
    || fm_supervision_registry_recover "$state" || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  fm_supervision_registry_reconcile_locked "$state" || { fm_lock_release "$lock"; return 1; }
  fm_supervision_registry_write_locked "$state" "$task" "$meta" "$phase" set
  rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_prepare() { fm_supervision_registry_set "$1" "$2" "${3:-$1/$2.meta}" pending; }
fm_supervision_registry_register() { fm_supervision_registry_set "$1" "$2" "${3:-$1/$2.meta}" active; }

fm_supervision_registry_retire() {
  local state=$1 task=$2 lock rc
  fm_supervision_registry_task_valid "$task" || return 1
  [ -f "$(fm_supervision_registry_generation_path "$state")" ] \
    || fm_supervision_registry_recover "$state" || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  fm_supervision_registry_reconcile_locked "$state" || { fm_lock_release "$lock"; return 1; }
  fm_supervision_registry_write_locked "$state" "$task" '' '' remove
  rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_death_surfaced() {
  local state=$1 task=$2 meta=${3:-$1/$2.meta} expected_incarnation expected_backend expected_target spawn_gen
  expected_backend=$(fm_backend_of_meta "$meta")
  expected_target=$(fm_backend_target_of_meta "$meta")
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ -n "$spawn_gen" ]; then
    expected_incarnation="spawn:$spawn_gen"
  else
    expected_incarnation=legacy:0
  fi
  fm_supervision_registry_death_surfaced_values \
    "$state" "$task" "$expected_backend" "$expected_target" "$expected_incarnation"
}

fm_supervision_registry_death_surfaced_values() { # <state> <task> <backend> <target> <incarnation>
  local state=$1 task=$2 expected_backend=$3 expected_target=$4 expected_incarnation=$5
  local receipt protocol incarnation receipt_task backend target owner_id legacy_key legacy parent tmp
  owner_id=$(fm_supervision_death_owner_id "$expected_target" "$task" "$expected_backend")
  receipt=$(fm_supervision_death_state_path "$state" death-notified "$owner_id")
  if [ -f "$receipt" ] && [ ! -L "$receipt" ]; then
    IFS="$(printf '\t')" read -r protocol incarnation receipt_task backend target < "$receipt" || protocol=
    case "$protocol" in fm-death-notified.v2|fm-death-notified.v3) ;; *) protocol= ;; esac
    [ -n "$protocol" ] && [ "$receipt_task" = "$task" ] \
      && [ "$incarnation" = "$expected_incarnation" ] && [ "$backend" = "$expected_backend" ] \
      && [ "$target" = "$expected_target" ] && return 0
  fi
  legacy_key=$(fm_supervision_legacy_death_key "$expected_target")
  legacy="$state/.death-notified-$legacy_key"
  [ -f "$legacy" ] && [ ! -L "$legacy" ] || return 1
  IFS="$(printf '\t')" read -r protocol incarnation receipt_task backend target < "$legacy" || return 1
  [ "$protocol" = fm-death-notified.v2 ] && [ "$receipt_task" = "$task" ] \
    && [ "$incarnation" = "$expected_incarnation" ] && [ "$backend" = "$expected_backend" ] \
    && [ "$target" = "$expected_target" ] || return 1
  parent=${receipt%/*}
  tmp="$receipt.tmp.${BASHPID:-$$}"
  if ! ( umask 077; mkdir -p "$parent" \
      && printf 'fm-death-notified.v3\t%s\t%s\t%s\t%s\n' \
        "$expected_incarnation" "$task" "$expected_backend" "$expected_target" > "$tmp" ) \
    || ! mv -f -- "$tmp" "$receipt" \
    || ! rm -f -- "$legacy"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Parse the endpoint fields used by registry recovery and admission in one
# pass.  Every emitted field is non-empty so shell TSV readers cannot collapse
# missing columns; endpoint presence and spawn incarnation are explicit to
# distinguish legitimate '-' values from absent metadata.
fm_supervision_registry_meta_facts() { # <meta> <task>
  local meta=$1 task=$2
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  fm_supervision_registry_task_valid "$task" || return 1
  LC_ALL=C awk -F= -v task="$task" '
    function assign(key, value) {
      if (key == "backend") backend=value
      else if (key == "terminal") terminal=value
      else if (key == "window") window=value
      else if (key == "remote_host") remote_host=value
      else if (key == "home") home=value
      else if (key == "kind") kind=value
      else if (key == "spawn_gen") { spawn=value; spawn_seen=1 }
    }
    {
      key=$1
      value=$0
      sub(/^[^=]*=/, "", value)
      assign(key, value)
    }
    END {
      if (backend == "") backend="tmux"
      target=(backend == "orca" && terminal != "") ? terminal : window
      if (target == "") { endpoint="absent"; target="-" } else endpoint="present"
      route=(target ~ /^remote:/ || remote_host != "") ? "remote" : "local"
      if (home == "") home="-"
      if (kind == "") kind="ship"
      incarnation=spawn_seen ? "spawn:" spawn : "legacy:0"
      if (!spawn_seen || spawn == "") spawn="-"
      values[1]=endpoint; values[2]=backend; values[3]=target; values[4]=route
      values[5]=home; values[6]=task; values[7]=kind; values[8]=spawn; values[9]=incarnation
      for (i=1; i<=9; i++) {
        if (values[i] == "" || values[i] ~ /[\t\r\n]/) exit 1
      }
      printf "%s", values[1]
      for (i=2; i<=9; i++) printf "\t%s", values[i]
      printf "\n"
    }
  ' "$meta"
}

fm_supervision_registry_recover() {
  local state=$1 path lock candidates states endpoints meta task target backend route home verdict tmp spawn_gen rc
  local facts endpoint owner_kind incarnation candidate_task surfaced filtered
  path=$(fm_supervision_registry_generation_path "$state")
  [ -f "$path" ] && fm_supervision_registry_snapshot_valid "$path" && return 0
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  if [ -f "$path" ]; then
    fm_supervision_registry_snapshot_valid "$path"; rc=$?
    fm_lock_release "$lock" || rc=1
    return "$rc"
  fi
  candidates=$(umask 077; mktemp "$state/.active-supervision-recovery.XXXXXX") \
    || { fm_lock_release "$lock"; return 1; }
  states=$(umask 077; mktemp "$state/.active-supervision-states.XXXXXX") \
    || { rm -f -- "$candidates"; fm_lock_release "$lock"; return 1; }
  endpoints=$(umask 077; mktemp "$state/.active-supervision-endpoints.XXXXXX") \
    || { rm -f -- "$candidates" "$states"; fm_lock_release "$lock"; return 1; }
  surfaced=$(umask 077; mktemp "$state/.active-supervision-surfaced.XXXXXX") \
    || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
  filtered=$(umask 077; mktemp "$state/.active-supervision-filtered.XXXXXX") \
    || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced"; fm_lock_release "$lock"; return 1; }
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    fm_supervision_registry_task_valid "$task" || continue
    facts=$(fm_supervision_registry_meta_facts "$meta" "$task") || continue
    IFS="$(printf '\t')" read -r endpoint backend target route home candidate_task owner_kind spawn_gen incarnation <<EOF
$facts
EOF
    [ "$endpoint" = present ] || continue
    fm_supervision_tsv_row \
      "$backend" "$target" "$route" "$home" "$candidate_task" "$spawn_gen" "$incarnation" \
      >> "$candidates" || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"; fm_lock_release "$lock"; return 1; }
  done
  if ! awk -F '\t' 'BEGIN { OFS="\t" } !seen[$1 SUBSEP $3 SUBSEP $2]++ { print $1, $2, $3, $4 }' "$candidates" \
      | fm_backend_agent_state_batch > "$endpoints"; then
    rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"; fm_lock_release "$lock"; return 1
  fi
  { cat "$endpoints"; printf '__FM_REGISTRY_CANDIDATES__\n'; cat "$candidates"; } | awk -F '\t' '
    BEGIN { OFS="\t" }
    $0 == "__FM_REGISTRY_CANDIDATES__" { candidates=1; next }
    !candidates { verdict[$1 SUBSEP $4 SUBSEP $2]=$3; next }
    { key=$1 SUBSEP $3 SUBSEP $2; print $1, $2, verdict[key], $3, $4, $5, $6, $7 }
  ' > "$states" || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"; fm_lock_release "$lock"; return 1; }
  rc=0
  while IFS="$(printf '\t')" read -r backend target verdict route home task spawn_gen incarnation; do
    case "$verdict" in dead|missing) ;; *) continue ;; esac
    if fm_supervision_registry_death_surfaced_values \
      "$state" "$task" "$backend" "$target" "$incarnation"; then
      fm_supervision_tsv_row "$backend" "$target" "$route" >> "$surfaced" \
        || { rc=1; break; }
    fi
  done < "$states"
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"
    fm_lock_release "$lock"
    return 1
  fi
  { cat "$surfaced"; printf '__FM_REGISTRY_STATES__\n'; cat "$states"; } | awk -F '\t' '
    BEGIN { OFS="\t" }
    $0 == "__FM_REGISTRY_STATES__" { states=1; next }
    !states { surfaced[$1 SUBSEP $3 SUBSEP $2]=1; next }
    {
      key=$1 SUBSEP $4 SUBSEP $2
      if (($3 == "dead" || $3 == "missing") && key in surfaced) next
      print
    }
  ' > "$filtered" || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"; fm_lock_release "$lock"; return 1; }
  mv -f -- "$filtered" "$states" \
    || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$filtered"; fm_lock_release "$lock"; return 1; }
  tmp=$(umask 077; mktemp "$state/.active-supervision-generation.XXXXXX") \
    || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced"; fm_lock_release "$lock"; return 1; }
  fm_supervision_registry_snapshot_header "$state" > "$tmp" || { rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$tmp"; fm_lock_release "$lock"; return 1; }
  rc=0
  while IFS="$(printf '\t')" read -r backend target verdict route home task spawn_gen incarnation; do
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    printf 'entry\t%s\t%s\tactive\n' "$task" "$spawn_gen" >> "$tmp" \
      || { rc=1; break; }
  done < "$states"
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$candidates" "$states" "$endpoints" "$surfaced" "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  rm -f -- "$candidates" "$states" "$endpoints" "$surfaced"
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; fm_lock_release "$lock"; return 1; }
  fm_lock_release "$lock"
}

fm_supervision_registry_inventory() {
  local state=$1 expected=${2:-} path protocol generation kind task spawn_gen phase meta current lock rc=0 out
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_reconcile_locked "$state" || rc=1
  fm_supervision_registry_snapshot_valid "$path" || rc=1
  if [ "$rc" -eq 0 ]; then IFS="$(printf '\t')" read -r protocol generation < "$path" || rc=1; fi
  if [ "$rc" -eq 0 ] && [ -n "$expected" ] && [ "$generation" != "$expected" ]; then rc=2; fi
  out=
  while IFS="$(printf '\t')" read -r kind task spawn_gen phase; do
    [ "$rc" -eq 0 ] || break
    [ "$kind" = entry ] || { rc=2; break; }
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rc=1; break; }
    current=$(fm_meta_get "$meta" spawn_gen); [ -n "$current" ] || current=-
    [ "$current" = "$spawn_gen" ] || { rc=2; break; }
    out="${out}${out:+$'\n'}${meta}"
  done < <(sed '1d' "$path")
  [ "$rc" -ne 0 ] || { [ -z "$out" ] || printf '%s\n' "$out"; }
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_task_key() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

fm_supervision_registry_snapshot_index() {
  local state=$1 expected=$2 index=$3 path protocol generation kind task spawn_gen phase meta current lock rc=0 key
  local target backend record_home route owner_kind facts endpoint candidate_task incarnation
  [ -d "$index" ] && [ ! -L "$index" ] || return 1
  mkdir "$index/tasks" || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_reconcile_locked "$state" || rc=1
  fm_supervision_registry_snapshot_valid "$path" || rc=1
  if [ "$rc" -eq 0 ]; then IFS="$(printf '\t')" read -r protocol generation < "$path" || rc=1; fi
  if [ "$rc" -eq 0 ] && [ -n "$expected" ] && [ "$generation" != "$expected" ]; then rc=2; fi
  : > "$index/inventory" || rc=1
  : > "$index/owners" || rc=1
  while IFS="$(printf '\t')" read -r kind task spawn_gen phase; do
    [ "$rc" -eq 0 ] || break
    [ "$kind" = entry ] || { rc=2; break; }
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rc=1; break; }
    facts=$(fm_supervision_registry_meta_facts "$meta" "$task") || { rc=1; break; }
    IFS="$(printf '\t')" read -r endpoint backend target route record_home candidate_task owner_kind current incarnation <<EOF
$facts
EOF
    [ "$candidate_task" = "$task" ] || { rc=2; break; }
    [ "$current" = "$spawn_gen" ] || { rc=2; break; }
    key=$(fm_supervision_registry_task_key "$task") || { rc=1; break; }
    printf '%s\n' "$task" > "$index/tasks/$key" || { rc=1; break; }
    printf '%s\n' "$meta" >> "$index/inventory" || { rc=1; break; }
    if [ "$endpoint" = present ]; then
      fm_supervision_tsv_row \
        "$backend" "$target" "$route" "$record_home" "$task" "$owner_kind" "$spawn_gen" \
        >> "$index/owners" || { rc=1; break; }
    fi
  done < <(sed '1d' "$path")
  [ "$rc" -ne 0 ] || printf '%s\n' "$generation" > "$index/generation" || rc=1
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_index_contains() {
  local index=$1 task=$2 key path
  fm_supervision_registry_task_valid "$task" || return 1
  [ -d "$index" ] && [ ! -L "$index" ] || return 2
  key=$(fm_supervision_registry_task_key "$task") || return 2
  path="$index/tasks/$key"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(cat "$path" 2>/dev/null || true)" = "$task" ] || return 2
}

fm_supervision_registry_contains() {
  local state=$1 task=$2 expected=${3:-} path protocol generation kind entry_task spawn_gen phase lock rc=1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 2
  path=$(fm_supervision_registry_generation_path "$state")
  if ! fm_supervision_registry_reconcile_locked "$state"; then
    rc=2
  elif ! fm_supervision_registry_snapshot_valid "$path"; then
    rc=2
  elif ! IFS="$(printf '\t')" read -r protocol generation < "$path"; then
    rc=2
  elif [ -n "$expected" ] && [ "$generation" != "$expected" ]; then
    rc=2
  else
    while IFS="$(printf '\t')" read -r kind entry_task spawn_gen phase; do
      [ "$kind" = entry ] || continue
      if [ "$entry_task" = "$task" ]; then rc=0; break; fi
    done < <(sed '1d' "$path")
  fi
  fm_lock_release "$lock" || rc=2
  return "$rc"
}
