#!/usr/bin/env bash

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_check_index_root() { printf '%s/.registered-checks-v1\n' "$1"; }

fm_check_index_recover() { # <state>
  local state=$1 root ready check id marker tmp protocol ready_valid=0
  root=$(fm_check_index_root "$state")
  ready="$root/.ready"
  if [ -f "$ready" ] && [ ! -L "$ready" ]; then
    IFS= read -r protocol < "$ready" || return 1
    [ "$protocol" = fm-registered-checks.v1 ] || return 1
    ready_valid=1
  fi
  [ ! -e "$root" ] || { [ -d "$root" ] && [ ! -L "$root" ]; } || return 1
  mkdir -p "$root" || return 1
  for check in "$state"/*.check.sh; do
    [ -f "$check" ] && [ ! -L "$check" ] || continue
    id=${check##*/}; id=${id%.check.sh}
    fm_pr_task_id_valid "$id" || continue
    if [ "$ready_valid" -eq 1 ] && [ "$id" != x-watch ] \
      && [ ! -f "$state/$id.check-trust" ] \
      && [ ! -f "$state/$id.pr-poll-registration" ]; then
      continue
    fi
    marker="$root/$id"
    tmp="$root/.$id.tmp.${BASHPID:-$$}"
    if ! ( umask 077; printf '%s\n' "$id.check.sh" > "$tmp" ) \
      || ! mv -f -- "$tmp" "$marker"; then
      rm -f -- "$tmp"
      return 1
    fi
  done
  if [ "$ready_valid" -eq 0 ]; then
    tmp="$root/.ready.tmp.${BASHPID:-$$}"
    if ! ( umask 077; printf 'fm-registered-checks.v1\n' > "$tmp" ) \
      || ! mv -f -- "$tmp" "$ready"; then
      rm -f -- "$tmp"
      return 1
    fi
  fi
}

fm_check_index_register() { # <state> <id>
  local state=$1 id=$2 root marker tmp
  fm_pr_task_id_valid "$id" || return 1
  fm_check_index_recover "$state" || return 1
  root=$(fm_check_index_root "$state")
  marker="$root/$id"
  tmp="$root/.$id.tmp.${BASHPID:-$$}"
  if ! ( umask 077; printf '%s\n' "$id.check.sh" > "$tmp" ) \
    || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_check_index_remove() { # <state> <id>
  local root marker
  root=$(fm_check_index_root "$1")
  marker="$root/$2"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || rm -f -- "$marker"
}

fm_check_index_inventory() { # <state>
  local state=$1 root marker id value check
  fm_check_index_recover "$state" || return 1
  root=$(fm_check_index_root "$state")
  for marker in "$root"/*; do
    [ -f "$marker" ] && [ ! -L "$marker" ] || continue
    id=${marker##*/}
    fm_pr_task_id_valid "$id" || continue
    IFS= read -r value < "$marker" || continue
    [ "$value" = "$id.check.sh" ] || continue
    check="$state/$value"
    [ -f "$check" ] && [ ! -L "$check" ] || continue
    printf '%s\n' "$check"
  done | LC_ALL=C sort
}

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}
