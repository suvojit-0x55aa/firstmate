#!/usr/bin/env bash

fm_supervision_registry_dir() {
  printf '%s/.active-supervision-v1\n' "$1"
}

fm_supervision_registry_generation_path() {
  printf '%s/.active-supervision-generation\n' "$1"
}

fm_supervision_registry_lock_path() {
  printf '%s/.active-supervision.lock\n' "$1"
}

fm_supervision_registry_task_valid() {
  case "$1" in ''|.*|*/*|*[$'\t\r\n']*) return 1 ;; esac
}

fm_supervision_registry_bump_locked() {
  local state=$1 path tmp token
  path=$(fm_supervision_registry_generation_path "$state")
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fi
  tmp=$(umask 077; mktemp "$state/.active-supervision-generation.XXXXXX") || return 1
  token="$(date +%s).${BASHPID:-$$}.${RANDOM}"
  ( umask 077; printf 'fm-active-supervision.v1\t%s\n' "$token" > "$tmp" ) \
    && mv -f -- "$tmp" "$path"
}

fm_supervision_registry_register() {
  local state=$1 task=$2 meta=${3:-$1/$2.meta} dir lock spawn_gen tmp
  fm_supervision_registry_task_valid "$task" || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -f "$(fm_supervision_registry_generation_path "$state")" ] \
    && [ ! -L "$(fm_supervision_registry_generation_path "$state")" ] \
    || fm_supervision_registry_recover "$state" || return 1
  dir=$(fm_supervision_registry_dir "$state")
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  [ ! -L "$dir" ] && mkdir -p -- "$dir" || { fm_lock_release "$lock"; return 1; }
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  [ -n "$spawn_gen" ] || spawn_gen=-
  tmp=$(umask 077; mktemp "$dir/.$task.tmp.XXXXXX") \
    || { fm_lock_release "$lock"; return 1; }
  if ( umask 077; printf 'fm-active-supervision-entry.v1\t%s\t%s\n' "$task" "$spawn_gen" > "$tmp" ) \
    && mv -f -- "$tmp" "$dir/$task" \
    && fm_supervision_registry_bump_locked "$state"; then
    fm_lock_release "$lock"
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  fm_lock_release "$lock"
  return 1
}

fm_supervision_registry_retire() {
  local state=$1 task=$2 dir lock
  fm_supervision_registry_task_valid "$task" || return 1
  [ -f "$(fm_supervision_registry_generation_path "$state")" ] \
    && [ ! -L "$(fm_supervision_registry_generation_path "$state")" ] \
    || fm_supervision_registry_recover "$state" || return 1
  dir=$(fm_supervision_registry_dir "$state")
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$dir/$task" ] || [ -L "$dir/$task" ]; then
    [ -f "$dir/$task" ] && [ ! -L "$dir/$task" ] \
      || { fm_lock_release "$lock"; return 1; }
    rm -f -- "$dir/$task" \
      && fm_supervision_registry_bump_locked "$state" \
      || { fm_lock_release "$lock"; return 1; }
  elif [ ! -f "$(fm_supervision_registry_generation_path "$state")" ]; then
    fm_supervision_registry_bump_locked "$state" \
      || { fm_lock_release "$lock"; return 1; }
  fi
  fm_lock_release "$lock"
}

fm_supervision_registry_recover() {
  local state=$1 generation dir lock candidates states endpoints meta task target backend route home verdict tmp spawn_gen
  generation=$(fm_supervision_registry_generation_path "$state")
  [ -f "$generation" ] && [ ! -L "$generation" ] && return 0
  [ ! -e "$generation" ] && [ ! -L "$generation" ] || return 1
  dir=$(fm_supervision_registry_dir "$state")
  [ ! -L "$dir" ] || return 1
  lock=$(fm_supervision_registry_lock_path "$state")
  fm_lock_acquire_wait "$lock" || return 1
  if [ -f "$generation" ] && [ ! -L "$generation" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  if [ -e "$generation" ] || [ -L "$generation" ]; then
    fm_lock_release "$lock"
    return 1
  fi
  if [ -d "$dir" ]; then
    for entry in "$dir"/*; do
      [ ! -e "$entry" ] && [ ! -L "$entry" ] || { fm_lock_release "$lock"; return 1; }
    done
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
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    route=local
    case "$target" in remote:*) route=remote ;; esac
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || route=remote
    home=$(fm_meta_get "$meta" home); [ -n "$home" ] || home=-
    printf '%s\t%s\t%s\t%s\t%s\n' "$backend" "$target" "$route" "$home" "$task" >> "$candidates"
  done
  if ! awk -F '\t' 'BEGIN { OFS="\t" } !seen[$1 SUBSEP $3 SUBSEP $2]++ { print $1, $2, $3, $4 }' "$candidates" \
      | fm_backend_agent_state_batch > "$endpoints"; then
    rm -f -- "$candidates" "$states" "$endpoints"
    fm_lock_release "$lock"
    return 1
  fi
  {
    cat "$endpoints"
    printf '__FM_REGISTRY_CANDIDATES__\n'
    cat "$candidates"
  } | awk -F '\t' '
    BEGIN { OFS="\t" }
    $0 == "__FM_REGISTRY_CANDIDATES__" { candidates=1; next }
    !candidates { verdict[$1 SUBSEP $4 SUBSEP $2]=$3; next }
    { key=$1 SUBSEP $3 SUBSEP $2; print $1, $2, verdict[key], $3, $4, $5 }
  ' > "$states" || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
  mkdir -p -- "$dir" || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
  while IFS="$(printf '\t')" read -r backend target verdict route home task; do
    case "$verdict" in dead|missing) continue ;; esac
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    tmp=$(umask 077; mktemp "$dir/.$task.tmp.XXXXXX") \
      || { rm -f -- "$candidates" "$states" "$endpoints"; fm_lock_release "$lock"; return 1; }
    spawn_gen=$(fm_meta_get "$meta" spawn_gen); [ -n "$spawn_gen" ] || spawn_gen=-
    ( umask 077; printf 'fm-active-supervision-entry.v1\t%s\t%s\n' "$task" "$spawn_gen" > "$tmp" ) \
      && mv -f -- "$tmp" "$dir/$task" \
      || { rm -f -- "$candidates" "$states" "$endpoints" "$tmp"; fm_lock_release "$lock"; return 1; }
  done < "$states"
  rm -f -- "$candidates" "$states" "$endpoints"
  fm_supervision_registry_bump_locked "$state" || { fm_lock_release "$lock"; return 1; }
  fm_lock_release "$lock"
}

fm_supervision_registry_generation() {
  local path protocol generation
  path=$(fm_supervision_registry_generation_path "$1")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS="$(printf '\t')" read -r protocol generation < "$path" || return 1
  [ "$protocol" = fm-active-supervision.v1 ] && [ -n "$generation" ] || return 1
  printf '%s\n' "$generation"
}

fm_supervision_registry_inventory() {
  local state=$1 expected=${2:-} generation after dir entry protocol task spawn_gen meta current
  generation=$(fm_supervision_registry_generation "$state") || return 1
  [ -z "$expected" ] || [ "$generation" = "$expected" ] || return 2
  dir=$(fm_supervision_registry_dir "$state")
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for entry in "$dir"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    IFS="$(printf '\t')" read -r protocol task spawn_gen < "$entry" || return 1
    [ "$protocol" = fm-active-supervision-entry.v1 ] || return 1
    fm_supervision_registry_task_valid "$task" || return 1
    [ "${entry##*/}" = "$task" ] || return 1
    meta="$state/$task.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    current=$(fm_meta_get "$meta" spawn_gen); [ -n "$current" ] || current=-
    [ "$current" = "$spawn_gen" ] || return 2
    printf '%s\n' "$meta"
  done
  after=$(fm_supervision_registry_generation "$state") || return 1
  [ "$generation" = "$after" ] || return 2
}
