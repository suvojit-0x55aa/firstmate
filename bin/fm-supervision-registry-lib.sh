#!/usr/bin/env bash

fm_supervision_registry_dir() { printf '%s/.active-supervision-v1\n' "$1"; }
fm_supervision_registry_generation_path() { printf '%s/.active-supervision-generation\n' "$1"; }
fm_supervision_registry_lock_path() { printf '%s/.active-supervision.lock\n' "$1"; }

fm_supervision_registry_task_valid() {
  case "$1" in ''|.*|*/*|*[$'\t\r\n']*) return 1 ;; esac
}

fm_supervision_registry_snapshot_header() {
  printf 'fm-active-supervision.v2\t%s.%s.%s\n' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

fm_supervision_registry_snapshot_valid() {
  local path=$1 protocol generation kind task spawn_gen phase
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS="$(printf '\t')" read -r protocol generation < "$path" || return 1
  [ "$protocol" = fm-active-supervision.v2 ] && [ -n "$generation" ] || return 1
  while IFS="$(printf '\t')" read -r kind task spawn_gen phase; do
    [ -n "$kind" ] || continue
    [ "$kind" = entry ] && fm_supervision_registry_task_valid "$task" \
      && [ -n "$spawn_gen" ] || return 1
    case "$phase" in pending|active) ;; *) return 1 ;; esac
  done < <(sed '1d' "$path")
}

fm_supervision_registry_generation() {
  local state=$1 path protocol generation lock rc=0
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  path=$(fm_supervision_registry_generation_path "$state")
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
  local path tmp ordered kind existing_task existing_spawn existing_phase spawn_gen header entries
  path=$(fm_supervision_registry_generation_path "$state")
  tmp=$(umask 077; mktemp "$state/.active-supervision-generation.XXXXXX") || return 1
  ordered="$tmp.ordered"
  fm_supervision_registry_snapshot_header > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if [ -f "$path" ]; then
    fm_supervision_registry_snapshot_valid "$path" || { rm -f -- "$tmp"; return 1; }
    while IFS="$(printf '\t')" read -r kind existing_task existing_spawn existing_phase; do
      [ "$kind" = entry ] || continue
      [ "$existing_task" = "$task" ] && continue
      printf 'entry\t%s\t%s\t%s\n' "$existing_task" "$existing_spawn" "$existing_phase" >> "$tmp" \
        || { rm -f -- "$tmp"; return 1; }
    done < <(sed '1d' "$path")
  fi
  if [ "$operation" = set ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || { rm -f -- "$tmp"; return 1; }
    spawn_gen=$(fm_meta_get "$meta" spawn_gen); [ -n "$spawn_gen" ] || spawn_gen=-
    printf 'entry\t%s\t%s\t%s\n' "$task" "$spawn_gen" "$phase" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  fi
  header=$(sed -n '1p' "$tmp")
  entries=$(sed '1d' "$tmp" | LC_ALL=C sort -t "$(printf '\t')" -k2,2)
  { printf '%s\n' "$header"; [ -z "$entries" ] || printf '%s\n' "$entries"; } > "$ordered" \
    && mv -f -- "$ordered" "$path" || { rm -f -- "$tmp" "$ordered"; return 1; }
  rm -f -- "$tmp"
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
  fm_supervision_registry_write_locked "$state" "$task" '' '' remove
  rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_supervision_registry_death_surfaced() {
  local state=$1 task=$2 meta=${3:-$1/$2.meta} receipt protocol incarnation receipt_task backend target
  local expected_incarnation expected_backend expected_target spawn_gen
  expected_backend=$(fm_backend_of_meta "$meta")
  expected_target=$(fm_backend_target_of_meta "$meta")
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ -n "$spawn_gen" ]; then
    expected_incarnation="spawn:$spawn_gen"
  else
    expected_incarnation=legacy:0
  fi
  if [ -d "$state/.death-notified-v3" ]; then
    while IFS= read -r receipt; do
      [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
      IFS="$(printf '\t')" read -r protocol incarnation receipt_task backend target < "$receipt" || continue
      case "$protocol" in fm-death-notified.v2|fm-death-notified.v3) ;; *) continue ;; esac
      [ "$receipt_task" = "$task" ] && [ "$incarnation" = "$expected_incarnation" ] \
        && [ "$backend" = "$expected_backend" ] && [ "$target" = "$expected_target" ] && return 0
    done < <(find "$state/.death-notified-v3" -type f 2>/dev/null)
  fi
  for receipt in "$state"/.death-notified-*; do
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || continue
    IFS="$(printf '\t')" read -r protocol incarnation receipt_task backend target < "$receipt" || continue
    [ "$protocol" = fm-death-notified.v2 ] && [ "$receipt_task" = "$task" ] \
      && [ "$incarnation" = "$expected_incarnation" ] && [ "$backend" = "$expected_backend" ] \
      && [ "$target" = "$expected_target" ] && return 0
  done
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
  fm_supervision_registry_snapshot_header > "$tmp" || { rm -f -- "$candidates" "$states" "$endpoints" "$tmp"; fm_lock_release "$lock"; return 1; }
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
  fm_supervision_registry_snapshot_valid "$path" || rc=1
  if [ "$rc" -eq 0 ]; then IFS="$(printf '\t')" read -r protocol generation < "$path" || rc=1; fi
  if [ "$rc" -eq 0 ] && [ -n "$expected" ] && [ "$generation" != "$expected" ]; then rc=2; fi
  out=
  while IFS="$(printf '\t')" read -r kind task spawn_gen phase; do
    [ "$rc" -eq 0 ] || break
    [ "$kind" = entry ] || continue
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

fm_supervision_registry_contains() {
  local state=$1 task=$2 expected=${3:-} path protocol generation kind entry_task spawn_gen phase lock rc=1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 2
  path=$(fm_supervision_registry_generation_path "$state")
  if ! fm_supervision_registry_snapshot_valid "$path"; then
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
