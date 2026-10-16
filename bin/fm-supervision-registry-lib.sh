#!/usr/bin/env bash

fm_supervision_registry_dir() { printf '%s/.active-supervision-v1\n' "$1"; }
fm_supervision_registry_generation_path() { printf '%s/.active-supervision-generation\n' "$1"; }
fm_supervision_registry_lock_path() { printf '%s/.active-supervision.lock\n' "$1"; }
fm_supervision_registry_sequence_path() { printf '%s/.active-supervision-sequence\n' "$1"; }

fm_supervision_registry_task_valid() {
  case "$1" in ''|.*|*/*|*[$'\t\r\n']*) return 1 ;; esac
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
  printf '%s\n' "$current" > "$tmp" && mv -f -- "$tmp" "$sequence_path" \
    || { rm -f -- "$tmp"; return 1; }
  printf 'fm-active-supervision.v5\tg%s\n' "$current"
}

fm_supervision_registry_snapshot_valid() {
  local path=$1 protocol generation generation_sequence kind task field3 field4 field5 field6 field7 field8 field9
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS="$(printf '\t')" read -r protocol generation < "$path" || return 1
  case "$protocol" in fm-active-supervision.v2|fm-active-supervision.v3|fm-active-supervision.v4|fm-active-supervision.v5) ;; *) return 1 ;; esac
  [ -n "$generation" ] || return 1
  if [ "$protocol" = fm-active-supervision.v5 ]; then
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

fm_supervision_registry_reconcile_locked() {
  local state=$1 path kind task spawn_gen owner_pid owner_identity reservation_phase backend target detail meta current identity verdict
  local recovery_identity recovery_state recovery_path recovery_target
  path=$(fm_supervision_registry_generation_path "$state")
  fm_supervision_registry_snapshot_valid "$path" || return 1
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
          remote:*|remote-herdr:*) ;;
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
        fm_supervision_registry_recover_reservation_meta_locked \
          "$state" "$task" "$spawn_gen" "$reservation_phase" "$backend" "$recovery_target" "$detail" "$recovery_path" || return 1
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
  { printf '%s\n' "$header"; [ -z "$entries" ] || printf '%s\n' "$entries"; } > "$ordered" \
    && mv -f -- "$ordered" "$path" || { rm -f -- "$tmp" "$ordered"; return 1; }
  rm -f -- "$tmp"
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
    && fm_supervision_registry_write_locked "$state" "$task" "$spawn_gen" '' reserve "$owner_pid" "$owner_identity"
  rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_mark_reservation() {
  local state=$1 task=$2 spawn_gen=$3 phase=$4 backend=$5 target=$6 detail=${7:--}
  local lock path kind entry_task entry_spawn owner_pid owner_identity old_phase old_backend old_target old_detail rc=1
  case "$phase" in created|remote-unknown) ;; *) return 1 ;; esac
  case "$backend$target$detail" in *[$'\t\r\n']*) return 1 ;; esac
  [ -n "$backend" ] && [ -n "$target" ] && [ -n "$detail" ] || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
  if fm_supervision_registry_snapshot_valid "$path"; then
    while IFS="$(printf '\t')" read -r kind entry_task entry_spawn owner_pid owner_identity old_phase old_backend old_target old_detail; do
      [ "$kind" = reservation ] && [ "$entry_task" = "$task" ] && [ "$entry_spawn" = "$spawn_gen" ] || continue
      fm_supervision_registry_write_locked "$state" "$task" "$spawn_gen" '' reserve \
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
  local state=$1 task=$2 meta=${3:-$1/$2.meta} receipt protocol incarnation receipt_task backend target
  local expected_incarnation expected_backend expected_target spawn_gen owner_id legacy_key
  expected_backend=$(fm_backend_of_meta "$meta")
  expected_target=$(fm_backend_target_of_meta "$meta")
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ -n "$spawn_gen" ]; then
    expected_incarnation="spawn:$spawn_gen"
  else
    expected_incarnation=legacy:0
  fi
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
  receipt="$state/.death-notified-$legacy_key"
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  IFS="$(printf '\t')" read -r protocol incarnation receipt_task backend target < "$receipt" || return 1
  [ "$protocol" = fm-death-notified.v2 ] && [ "$receipt_task" = "$task" ] \
    && [ "$incarnation" = "$expected_incarnation" ] && [ "$backend" = "$expected_backend" ] \
    && [ "$target" = "$expected_target" ] && return 0
  return 1
}

fm_supervision_registry_recover() {
  local state=$1 path lock candidates states endpoints meta task target backend route home verdict tmp spawn_gen rc
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
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    task=${meta##*/}; task=${task%.meta}
    fm_supervision_registry_task_valid "$task" || continue
    target=$(fm_backend_target_of_meta "$meta"); [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    route=local; case "$target" in remote:*) route=remote ;; esac
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || route=remote
    home=$(fm_meta_get "$meta" home); [ -n "$home" ] || home=-
    printf '%s\t%s\t%s\t%s\t%s\n' "$backend" "$target" "$route" "$home" "$task" >> "$candidates"
  done
  if ! awk -F '\t' 'BEGIN { OFS="\t" } !seen[$1 SUBSEP $3 SUBSEP $2]++ { print $1, $2, $3, $4 }' "$candidates" \
      | fm_backend_agent_state_batch > "$endpoints"; then
    rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1
  fi
  { cat "$endpoints"; printf '__FM_REGISTRY_CANDIDATES__\n'; cat "$candidates"; } | awk -F '\t' '
    BEGIN { OFS="\t" }
    $0 == "__FM_REGISTRY_CANDIDATES__" { candidates=1; next }
    !candidates { verdict[$1 SUBSEP $4 SUBSEP $2]=$3; next }
    { key=$1 SUBSEP $3 SUBSEP $2; print $1, $2, verdict[key], $3, $4, $5 }
  ' > "$states" || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
  tmp=$(umask 077; mktemp "$state/.active-supervision-generation.XXXXXX") \
    || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
  fm_supervision_registry_snapshot_header "$state" > "$tmp" || { rm -f -- "$candidates" "$states" "$endpoints" "$tmp"; fm_lock_release "$lock"; return 1; }
  while IFS="$(printf '\t')" read -r backend target verdict route home task; do
    meta="$state/$task.meta"
    case "$verdict" in dead|missing) fm_supervision_registry_death_surfaced "$state" "$task" "$meta" && continue ;; esac
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    spawn_gen=$(fm_meta_get "$meta" spawn_gen); [ -n "$spawn_gen" ] || spawn_gen=-
    printf 'entry\t%s\t%s\tactive\n' "$task" "$spawn_gen" >> "$tmp" \
      || { rm -f -- "$candidates" "$states" "$endpoints" "$tmp"; fm_lock_release "$lock"; return 1; }
  done < "$states"
  rm -f -- "$candidates" "$states" "$endpoints"
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
  while IFS="$(printf '\t')" read -r kind task spawn_gen phase; do
    [ "$rc" -eq 0 ] || break
    [ "$kind" = entry ] || { rc=2; break; }
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rc=1; break; }
    current=$(fm_meta_get "$meta" spawn_gen); [ -n "$current" ] || current=-
    [ "$current" = "$spawn_gen" ] || { rc=2; break; }
    key=$(fm_supervision_registry_task_key "$task") || { rc=1; break; }
    printf '%s\n' "$task" > "$index/tasks/$key" || { rc=1; break; }
    printf '%s\n' "$meta" >> "$index/inventory" || { rc=1; break; }
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
