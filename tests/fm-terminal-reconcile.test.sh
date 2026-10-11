#!/usr/bin/env bash
# Delivery obligations survive notification acknowledgement and process restart.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi required'; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-terminal-reconcile)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
export FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT"
mkdir -p "$FM_HOME"/{state,config,data}
owner="$ROOT/bin/fm-terminal-reconcile.sh"
tx() { tasks-axi "$@" --file "$FM_HOME/data/backlog.md"; }
captain() {
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}
make_task() {
  tx add "$1" "$1" --start --json >/dev/null
  printf 'spawn_gen=%s\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' "$1" > "$FM_HOME/state/$1.meta"
}
make_unreviewed_task() {
  tx add "$1" "$1" --start --json >/dev/null
  printf 'spawn_gen=%s\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\n' "$1" > "$FM_HOME/state/$1.meta"
}
answer_captain_task() {
  local id=$1 answer_file="$FM_HOME/$1-answer.txt"
  printf 'Captain answered %s.\n' "$id" > "$answer_file"
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    answer "$id" --decision-file "$answer_file" >/dev/null
}
release_captain_task() {
  local id=$1 answer_file="$FM_HOME/$1-release.txt"
  printf 'Captain released %s.\n' "$id" > "$answer_file"
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    answer "$id" --decision-file "$answer_file" --release >/dev/null
}
release_captain_task_again() {
  local id=$1 answer_file="$FM_HOME/$1-release-again.txt"
  printf 'Captain released %s after resumed review.\n' "$id" > "$answer_file"
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    answer "$id" --decision-file "$answer_file" --release >/dev/null
}
hold_captain_task() {
  local id=$1
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    hold "$id" --reason 'captain release cycle pending' >/dev/null
}
run_terminal_captain_case() {
  local backend=$1 shape=$2 resolution=$3 expected=$4
  local id="gate-$backend-$shape-$resolution" call key rc=0 backlog
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown terminal captain matrix backend: $backend" ;;
  esac
  make_task "$id"
  case "$shape" in
    transferred)
      call="$id-call"
      tx add "$call" "$call" --json >/dev/null
      tx hold "$call" --reason 'captain delivery choice pending' --kind captain --json >/dev/null
      printf '%s\n' 'decisions_reviewed=1' "decision_keys=$call" >> "$FM_HOME/state/$id.meta"
      printf '%s\n' \
        'needs-decision [key=delivery]: choose delivery treatment' \
        "captain-held [key=delivery]: tracked by $call" > "$FM_HOME/state/$id.status"
      ;;
    origin)
      call=$id
      tx hold "$call" --reason 'captain delivery choice pending' --kind captain --json >/dev/null
      printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$FM_HOME/state/$id.meta"
      ;;
    reheld-origin)
      call=$id
      tx hold "$call" --reason 'first captain delivery choice pending' --kind captain --json >/dev/null
      release_captain_task "$call"
      tx hold "$call" --reason 'new captain delivery choice pending' --kind captain --json >/dev/null
      printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$FM_HOME/state/$id.meta"
      ;;
    resumed-origin)
      call=$id
      tx hold "$call" --reason 'captain delivery choice pending' --kind captain --json >/dev/null
      release_captain_task "$call"
      printf '%s\n' 'decisions_reviewed=1' 'decision_keys=' >> "$FM_HOME/state/$id.meta"
      "$owner" merged "$id" https://github.com/o/r/pull/1
      "$owner" retired "$id" normal
      printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
        "$id" > "$FM_HOME/state/$id.meta"
      ;;
    legacy)
      call="$id-decision-choice"
      tx add "$call" "$call" --json >/dev/null
      tx hold "$call" --reason 'legacy captain choice pending' --kind captain --json >/dev/null
      printf '%s\n' 'decisions_reviewed=1' 'decision_keys=choice' >> "$FM_HOME/state/$id.meta"
      printf '%s\n' \
        'needs-decision [key=choice]: choose legacy delivery treatment' \
        "captain-held [key=choice]: tracked by $call" > "$FM_HOME/state/$id.status"
      ;;
    *) fail "unknown terminal captain matrix shape: $shape" ;;
  esac
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  rm "$FM_HOME/state/$id.meta"
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  case "$resolution" in
    answered|current) answer_captain_task "$call" ;;
    *) tx 'done' "$call" --no-prune --json >/dev/null ;;
  esac
  if [ "$backend" = manual ]; then
    [ "$call" = "$id" ] || tx 'done' "$id" --no-prune --json >/dev/null
    set +e
    "$owner" manual-complete "$key"
    rc=$?
    set -e
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  backlog=$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")
  case "$expected" in
    blocked)
      [ "$backlog" = false ] || fail "$backend/$shape/$resolution advanced terminal backlog"
      [ "$backend" != manual ] || [ "$rc" -ne 0 ] \
        || fail "$backend/$shape/$resolution reported manual completion"
      ;;
    progressed)
      [ "$backlog" = true ] || fail "$backend/$shape/$resolution did not advance terminal backlog"
      [ "$backend" != manual ] || [ "$rc" -eq 0 ] \
        || fail "$backend/$shape/$resolution refused manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$key"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
        || fail "$backend/$shape/$resolution replay lost terminal progress"
      "$owner" refill-reviewed "$key"
      [ "$(jq -sr --arg id "$id" '[.[] | select(.id==$id and ((.superseded_by // "") == ""))] | length' \
        "$FM_HOME/state/terminal-delivery/"*.json)" = 1 ] \
        || fail "$backend/$shape/$resolution retained parallel active receipts"
      [ "$(jq -sr --arg id "$id" '[.[] | select(.id==$id and .backlog==true)] | length' \
        "$FM_HOME/state/terminal-delivery/"*.json)" = 1 ] \
        || fail "$backend/$shape/$resolution duplicated terminal completion"
      ;;
    *) fail "unknown terminal captain matrix expectation: $expected" ;;
  esac
}
run_transferred_release_resume_case() {
  local backend=$1 scenario=$2 expected=$3
  local id="release-$backend-$scenario" call old_key new_key key rc=0 backlog old_file tmp
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown transferred release backend: $backend" ;;
  esac
  make_task "$id"
  call="$id-work"
  make_task "$call"
  tx hold "$call" --reason 'captain released work pending resume' --kind captain --json >/dev/null
  printf '%s\n' 'decisions_reviewed=1' "decision_keys=$call" >> "$FM_HOME/state/$id.meta"
  "$owner" custody "$call" https://github.com/o/r/pull/1
  old_key=$(jq -r --arg id "$call" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  release_captain_task "$call"
  case "$scenario" in
    pre-resume) ;;
    stale-done) tx 'done' "$call" --no-prune --json >/dev/null ;;
    missing-proof)
      printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
        "$call" > "$FM_HOME/state/$call.meta"
      "$owner" custody "$call" https://github.com/o/r/pull/1
      "$owner" retired "$call" normal
      rm "$FM_HOME/state/$call.meta"
      tx 'done' "$call" --no-prune --json >/dev/null
      ;;
    new-success|unrelated)
      printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
        "$call" > "$FM_HOME/state/$call.meta"
      "$owner" merged "$call" https://github.com/o/r/pull/1
      "$owner" retired "$call" normal
      rm "$FM_HOME/state/$call.meta"
      new_key=$(jq -r --arg id "$call" \
        'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
        "$FM_HOME/state/terminal-delivery/"*.json)
      if [ "$backend" = manual ]; then
        tx 'done' "$call" --no-prune --json >/dev/null
        "$owner" manual-complete "$new_key"
      else
        "$owner" reconcile
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$new_key.json")" = true ] \
        || fail "$backend/$scenario did not complete transferred resumed work"
      if [ "$scenario" = unrelated ]; then
        old_file="$FM_HOME/state/terminal-delivery/$old_key.json"
        tmp="$old_file.tmp"
        jq '.superseded_by=""' "$old_file" > "$tmp"
        mv "$tmp" "$old_file"
      fi
      ;;
    *) fail "unknown transferred release scenario: $scenario" ;;
  esac
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  rm "$FM_HOME/state/$id.meta"
  key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    tx 'done' "$id" --no-prune --json >/dev/null
    set +e
    "$owner" manual-complete "$key"
    rc=$?
    set -e
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  backlog=$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")
  case "$expected" in
    blocked)
      [ "$backlog" = false ] || fail "$backend/$scenario advanced the referring origin"
      [ "$backend" != manual ] || [ "$rc" -ne 0 ] \
        || fail "$backend/$scenario reported manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$key" && fail "$backend/$scenario replay advanced the referring origin"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = false ] \
        || fail "$backend/$scenario replay advanced the referring origin"
      ;;
    progressed)
      [ "$backlog" = true ] || fail "$backend/$scenario did not advance the referring origin"
      [ "$backend" != manual ] || [ "$rc" -eq 0 ] \
        || fail "$backend/$scenario refused manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$key"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
        || fail "$backend/$scenario replay lost referring-origin progress"
      ;;
    *) fail "unknown transferred release expectation: $expected" ;;
  esac
}
run_terminal_identity_case() {
  local backend=$1 shape=$2 expected=$3
  local id="identity-$backend-$shape" call key rc=0 backlog
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown terminal identity backend: $backend" ;;
  esac
  make_task "$id"
  case "$shape" in
    self-unresolved)
      tx hold "$id" --reason 'origin captain call pending' --kind captain --json >/dev/null
      FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
        FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
        complete "$id" "$id" >/dev/null
      "$owner" merged "$id" https://github.com/o/r/pull/1
      "$owner" retired "$id" normal
      rm "$FM_HOME/state/$id.meta"
      tx 'done' "$id" --no-prune --json >/dev/null
      ;;
    self-resumed)
      tx hold "$id" --reason 'origin captain call pending' --kind captain --json >/dev/null
      FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
        FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
        complete "$id" "$id" >/dev/null
      "$owner" custody "$id" https://github.com/o/r/pull/1
      release_captain_task "$id"
      printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=%s\n' \
        "$id" "$id" > "$FM_HOME/state/$id.meta"
      "$owner" merged "$id" https://github.com/o/r/pull/1
      "$owner" retired "$id" normal
      rm "$FM_HOME/state/$id.meta"
      ;;
    legacy-alias)
      call="$id-decision-choice"
      make_task "$call"
      tx hold "$call" --reason 'legacy captain call pending' --kind captain --json >/dev/null
      FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
        FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
        complete "$id" "$call" choice >/dev/null
      answer_captain_task "$call"
      "$owner" merged "$id" https://github.com/o/r/pull/1
      "$owner" retired "$id" normal
      rm "$FM_HOME/state/$id.meta"
      ;;
    *) fail "unknown terminal identity shape: $shape" ;;
  esac
  key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    [ "$shape" = self-unresolved ] || tx 'done' "$id" --no-prune --json >/dev/null
    set +e
    "$owner" manual-complete "$key"
    rc=$?
    set -e
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  backlog=$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")
  case "$expected" in
    blocked)
      [ "$backlog" = false ] || fail "$backend/$shape advanced an unresolved origin"
      [ "$backend" != manual ] || [ "$rc" -ne 0 ] \
        || fail "$backend/$shape reported manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$key" && fail "$backend/$shape replay advanced an unresolved origin"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = false ] \
        || fail "$backend/$shape replay advanced an unresolved origin"
      ;;
    progressed)
      [ "$backlog" = true ] || fail "$backend/$shape did not advance terminal backlog"
      [ "$backend" != manual ] || [ "$rc" -eq 0 ] \
        || fail "$backend/$shape refused manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$key"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
        || fail "$backend/$shape replay lost terminal progress"
      ;;
    *) fail "unknown terminal identity expectation: $expected" ;;
  esac
}
run_cycle_answer_case() {
  local backend=$1 shape=$2 id="cycle-$1-$2" target inventory='' target_keys=''
  local cycle_two_key cycle_three_key origin_key
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown cycle-answer backend: $backend" ;;
  esac
  make_task "$id"
  case "$shape" in
    origin) target=$id ;;
    self-inventory) target=$id; inventory=$id; target_keys=$id ;;
    transferred) target="$id-work"; inventory=$target; make_task "$target" ;;
    legacy) target="$id-decision-choice"; inventory=choice; make_task "$target" ;;
    *) fail "unknown cycle-answer shape: $shape" ;;
  esac
  if [ -n "$inventory" ]; then
    printf '%s\n' 'decisions_reviewed=1' "decision_keys=$inventory" >> "$FM_HOME/state/$id.meta"
  fi
  hold_captain_task "$target"
  "$owner" custody "$target" https://github.com/o/r/pull/1
  release_captain_task "$target"
  printf 'spawn_gen=%s-cycle-two\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=%s\n' \
    "$target" "$target_keys" > "$FM_HOME/state/$target.meta"
  "$owner" custody "$target" https://github.com/o/r/pull/1
  hold_captain_task "$target"
  release_captain_task "$target"
  "$owner" merged "$target" https://github.com/o/r/pull/1
  "$owner" retired "$target" normal
  rm "$FM_HOME/state/$target.meta"
  cycle_two_key=$(jq -r --arg id "$target" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$cycle_two_key" \
      && fail "$backend/$shape reused an earlier answer in the current release cycle"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$cycle_two_key.json")" = false ] \
    || fail "$backend/$shape completed the just-released cycle"
  assert_contains "$(tx show "$target")" 'state: in_flight' \
    "$backend/$shape completed work from an earlier answer cycle"

  printf 'spawn_gen=%s-cycle-three\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=%s\n' \
    "$target" "$target_keys" > "$FM_HOME/state/$target.meta"
  "$owner" merged "$target" https://github.com/o/r/pull/1
  "$owner" retired "$target" normal
  rm "$FM_HOME/state/$target.meta"
  cycle_three_key=$(jq -r --arg id "$target" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    tx 'done' "$target" --no-prune --json >/dev/null
    "$owner" manual-complete "$cycle_three_key"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$cycle_three_key.json")" = true ] \
    || fail "$backend/$shape did not accept the later completed release cycle"

  if [ "$target" = "$id" ]; then
    origin_key=$cycle_three_key
  else
    "$owner" merged "$id" https://github.com/o/r/pull/1
    "$owner" retired "$id" normal
    rm "$FM_HOME/state/$id.meta"
    origin_key=$(jq -r --arg id "$id" \
      'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
      "$FM_HOME/state/terminal-delivery/"*.json)
    if [ "$backend" = manual ]; then
      tx 'done' "$id" --no-prune --json >/dev/null
      "$owner" manual-complete "$origin_key"
    else
      "$owner" reconcile
      "$owner" reconcile
    fi
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = true ] \
    || fail "$backend/$shape did not advance after the later terminal incarnation"
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$origin_key"
  else
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = true ] \
    || fail "$backend/$shape replay lost cycle-aware terminal progress"
}
run_attestation_case() {
  local backend=$1 terminal=$2 id="attestation-$1-$2" call key rc=0 report
  call="$id-call"
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown attestation backend: $backend" ;;
  esac
  make_unreviewed_task "$id"
  tx add "$call" "$call" --json >/dev/null
  tx hold "$call" --reason 'captain delivery choice pending' --kind captain --json >/dev/null
  printf '%s\n' \
    'needs-decision [key=delivery]: choose delivery treatment' \
    "$terminal: implementation terminal" > "$FM_HOME/state/$id.status"
  set +e
  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    complete "$id" --none > "$FM_HOME/$id-none.out" 2> "$FM_HOME/$id-none.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$backend/$terminal terminal status authorized an empty captain inventory"
  [ "$(sed -n 's/^decisions_reviewed=//p' "$FM_HOME/state/$id.meta" | tail -1)" != 1 ] \
    || fail "$backend/$terminal refused empty inventory still recorded an attestation"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  [ "$(jq -r '.decisions_reviewed // false' "$FM_HOME/state/terminal-delivery/$key.json")" = false ] \
    || fail "$backend missing inventory produced a reviewed receipt"
  if [ "$backend" = manual ]; then
    rc=0
    set +e
    "$owner" manual-complete "$key"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$backend missing inventory advanced manual completion"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = false ] \
    || fail "$backend missing inventory advanced backlog completion"
  report=$("$owner" report)
  assert_contains "$report" 'Captain-call inventory is not attested' \
    "$backend missing inventory was not visible"
  assert_contains "$report" "fm-captain-hold.sh complete $id" \
    "$backend missing inventory omitted its recovery owner"

  FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
    FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
    complete "$id" "$call" >/dev/null
  "$owner" retired "$id" normal
  [ "$(jq -r '.decisions_reviewed and .captain_keys == $call' --arg call "$call" \
    "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
    || fail "$backend receipt did not preserve the reviewed normalized inventory"
  answer_captain_task "$call"
  rm "$FM_HOME/state/$id.meta" "$FM_HOME/state/$id.status"
  if [ "$backend" = manual ]; then
    tx 'done' "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$key"
    "$owner" manual-complete "$key"
  else
    "$owner" reconcile
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
    || fail "$backend/$terminal reviewed inventory did not survive metadata deletion and replay"
}

run_retired_attestation_recovery_case() {
  local backend=$1 id="retired-review-$1" call key record report rc before after
  local forged=forged-recovery missing_key ambiguous="reused-review-$1" first_key second_key
  local fakebin="$FM_HOME/$id-fakebin"
  call="$id-call"
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown retired attestation backend: $backend" ;;
  esac
  make_unreviewed_task "$id"
  tx add "$call" "$call" --json >/dev/null
  tx hold "$call" --reason 'retired captain review pending' --kind captain --json >/dev/null
  printf '%s\n' \
    'needs-decision [key=delivery]: choose retired delivery treatment' \
    'done: implementation terminal' > "$FM_HOME/state/$id.status"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  rm "$FM_HOME/state/$id.meta"
  report=$("$owner" report)
  assert_contains "$report" "complete $id --receipt $key" \
    "$backend retired missing attestation omitted its exact recovery command"
  if captain complete "$id" "$call" > "$FM_HOME/$id-no-receipt.out" 2> "$FM_HOME/$id-no-receipt.err"; then
    fail "$backend retired attestation recovery accepted a missing receipt identity"
  fi
  if captain complete "$id" --receipt "$key" --none \
    > "$FM_HOME/$id-none.out" 2> "$FM_HOME/$id-none.err"; then
    fail "$backend retired attestation recovery erased an unresolved keyed call"
  fi
  if captain complete "$id" --receipt "$key" "$id-missing-call" \
    > "$FM_HOME/$id-missing-task.out" 2> "$FM_HOME/$id-missing-task.err"; then
    fail "$backend retired attestation recovery accepted missing captain-task evidence"
  fi

  jq --arg key "$forged" '.key=$key' "$record" \
    > "$FM_HOME/state/terminal-delivery/$forged.json"
  if captain complete "$id" --receipt "$forged" "$call" \
    > "$FM_HOME/$id-forged.out" 2> "$FM_HOME/$id-forged.err"; then
    fail "$backend retired attestation recovery accepted an unauthenticated receipt"
  fi
  rm "$FM_HOME/state/terminal-delivery/$forged.json"

  missing_key=$(printf '%s' "$id|||" | shasum -a 256 | awk '{print $1}')
  jq --arg key "$missing_key" '.key=$key | .incarnation="||"' "$record" \
    > "$FM_HOME/state/terminal-delivery/$missing_key.json"
  if captain complete "$id" --receipt "$missing_key" "$call" \
    > "$FM_HOME/$id-missing-identity.out" 2> "$FM_HOME/$id-missing-identity.err"; then
    fail "$backend retired attestation recovery accepted a receipt without incarnation identity"
  fi
  rm "$FM_HOME/state/terminal-delivery/$missing_key.json"

  before=$(jq -cS 'del(.captain_keys,.decisions_reviewed)' "$record")
  mkdir -p "$fakebin"
  cat > "$fakebin/mv" <<'EOF'
#!/usr/bin/env bash
target=
for arg in "$@"; do target=$arg; done
if [ -f "$FM_FAIL_MV_ONCE" ] && [ "$target" = "$FM_FAIL_MV_TARGET" ]; then
  rm "$FM_FAIL_MV_ONCE"
  /bin/mv "$@" || exit $?
  exit 42
fi
exec /bin/mv "$@"
EOF
  chmod +x "$fakebin/mv"
  : > "$FM_HOME/$id-fail-mv.once"
  rc=0
  PATH="$fakebin:$PATH" FM_FAIL_MV_ONCE="$FM_HOME/$id-fail-mv.once" \
    FM_FAIL_MV_TARGET="$record" captain complete "$id" --receipt "$key" "$call" \
    > "$FM_HOME/$id-interrupted.out" 2> "$FM_HOME/$id-interrupted.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "$backend retired attestation interruption did not surface"
  jq -e --arg call "$call" '.decisions_reviewed == true and .captain_keys == $call' \
    "$record" >/dev/null || fail "$backend interrupted attestation did not leave one durable receipt transition"
  grep -F 'captain-held [key=delivery]' "$FM_HOME/state/$id.status" >/dev/null 2>&1 \
    && fail "$backend interrupted attestation transferred status after reporting persistence failure"
  [ ! -e "$FM_HOME/state/$id.meta" ] \
    || fail "$backend retired attestation recovery recreated live metadata"
  after=$(jq -cS 'del(.captain_keys,.decisions_reviewed)' "$record")
  [ "$before" = "$after" ] \
    || fail "$backend retired attestation recovery changed delivery, backlog, or refill state"

  captain complete "$id" --receipt "$key" "$call" >/dev/null \
    || fail "$backend interrupted retired attestation did not replay"
  captain complete "$id" --receipt "$key" "$call" >/dev/null \
    || fail "$backend retired attestation replay was not idempotent"
  grep -F 'captain-held [key=delivery]: tracked by' "$FM_HOME/state/$id.status" >/dev/null \
    || fail "$backend retired attestation replay did not transfer the keyed call"
  answer_captain_task "$call"
  rm "$FM_HOME/state/$id.status"
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$key"
    "$owner" manual-complete "$key"
  else
    "$owner" reconcile
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$record")" = true ] \
    || fail "$backend exact retired attestation did not unblock reconciliation"

  make_unreviewed_task "$ambiguous"
  "$owner" merged "$ambiguous" https://github.com/o/r/pull/1
  "$owner" retired "$ambiguous" normal
  first_key=$(jq -r --arg id "$ambiguous" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  printf 'spawn_gen=%s-reused\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\n' \
    "$ambiguous" > "$FM_HOME/state/$ambiguous.meta"
  "$owner" merged "$ambiguous" https://github.com/o/r/pull/1
  "$owner" retired "$ambiguous" normal
  second_key=$(jq -r --arg id "$ambiguous" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  [ "$first_key" != "$second_key" ] || fail "$backend reused-id fixture did not create a second incarnation"
  rm "$FM_HOME/state/$ambiguous.meta"
  if captain complete "$ambiguous" --receipt "$second_key" --none \
    > "$FM_HOME/$ambiguous.out" 2> "$FM_HOME/$ambiguous.err"; then
    fail "$backend metadata-free recovery accepted an ambiguous reused task id"
  fi
  pass "$backend retired captain attestation recovers exact receipts and rejects ambiguity"
}

test_discard_review_acknowledgement() {
  local id=discarded key record report forged=forged-discard
  make_task "$id"
  "$owner" retired "$id" discard
  "$owner" reconcile
  assert_contains "$(tx show "$id")" 'state: in_flight' 'discard masqueraded as delivery'
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  jq -e '.discarded and (.reviewed != true) and (.backlog != true) and (.refill != true)' \
    "$record" >/dev/null || fail 'discard receipt did not remain presentation-actionable only'
  report=$("$owner" report)
  assert_contains "$report" "discard-reviewed $key" \
    'discard report omitted its explicit presentation acknowledgement'

  jq --arg key "$forged" '.key=$key | .reviewed=false' "$record" \
    > "$FM_HOME/state/terminal-delivery/$forged.json"
  if "$owner" discard-reviewed "$forged"; then
    fail 'discard acknowledgement accepted an unauthenticated receipt key'
  fi
  [ "$(jq -r .reviewed "$FM_HOME/state/terminal-delivery/$forged.json")" = false ] \
    || fail 'rejected unauthenticated discard receipt was mutated'
  rm "$FM_HOME/state/terminal-delivery/$forged.json"

  "$owner" discard-reviewed "$key"
  "$owner" discard-reviewed "$key"
  jq -e '.discarded and .reviewed and (.backlog != true) and (.refill != true)' \
    "$record" >/dev/null || fail 'discard acknowledgement inferred delivery or lost replay safety'
  assert_not_contains "$("$owner" report)" "TERMINAL DELIVERY: $id " \
    'acknowledged discard remained a presentation alert'
  assert_contains "$(tx show "$id")" 'state: in_flight' \
    'discard acknowledgement completed the backlog item'
  pass 'authenticated discard acknowledgement retires presentation only'
}

test_report_batches_receipts_at_scale() {
  local home="$TMP_ROOT/report-scale" dir fakebin real_jq out count reconcile_count i old_key=scale-release-old new_key=scale-release-new
  mkdir -p "$home/state/terminal-delivery" "$home/config" "$home/data" "$home/fakebin"
  dir="$home/state/terminal-delivery"
  printf '%s\n' manual > "$home/config/backlog-backend"
  for i in $(seq 1 108); do
    printf '{"schema":"fm-terminal-delivery.v1","key":"reviewed-%03d","id":"reviewed-%03d","incarnation":"reviewed-%03d","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/1","merged":true,"retired":true,"discarded":false,"backlog":true,"refill":false,"reviewed":true,"superseded_by":"","captain_keys":"","decisions_reviewed":true}\n' \
      "$i" "$i" "$i" > "$dir/reviewed-$(printf '%03d' "$i").json"
  done
  printf '%s\n' \
    '{"schema":"fm-terminal-delivery.v1","key":"active-missing","id":"active-missing","incarnation":"active-missing","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/2","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":false,"superseded_by":"","captain_keys":"","decisions_reviewed":false}' \
    > "$dir/active-missing.json"
  printf '%s\n' \
    '{"schema":"fm-terminal-delivery.v1","key":"active-ready","id":"active-ready","incarnation":"active-ready","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/3","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":false,"superseded_by":"","captain_keys":"","decisions_reviewed":true}' \
    > "$dir/active-ready.json"
  printf '{"schema":"fm-terminal-delivery.v1","key":"%s","id":"scale-release","incarnation":"old","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/4","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":true,"superseded_by":"%s","captain_keys":"","decisions_reviewed":true}\n' \
    "$old_key" "$new_key" > "$dir/$old_key.json"
  printf '{"schema":"fm-terminal-delivery.v1","key":"%s","id":"scale-release","incarnation":"new","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/4","merged":true,"retired":true,"discarded":false,"backlog":true,"refill":false,"reviewed":true,"superseded_by":"","captain_keys":"","decisions_reviewed":true}\n' \
    "$new_key" > "$dir/$new_key.json"

  real_jq=$(command -v jq)
  fakebin="$home/fakebin"
  cat > "$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$FM_JQ_COUNT" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" > "$FM_JQ_COUNT"
exec "$FM_REAL_JQ" "$@"
EOF
  chmod +x "$fakebin/jq"
  : > "$home/jq.count"
  out=$(PATH="$fakebin:$PATH" FM_REAL_JQ="$real_jq" FM_JQ_COUNT="$home/jq.count" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$owner" report)
  count=$(cat "$home/jq.count")
  [ "$count" = 1 ] || fail "scale report launched jq $count times"
  [ "$(printf '%s\n' "$out" | grep -c '^TERMINAL DELIVERY:' || true)" -eq 2 ] \
    || fail "scale report changed actionable receipt selection: $out"
  assert_contains "$out" 'TERMINAL DELIVERY: active-missing ' 'scale report lost missing-attestation receipt'
  assert_contains "$out" 'TERMINAL DELIVERY: active-ready ' 'scale report lost manual-ready receipt'
  assert_not_contains "$out" 'TERMINAL DELIVERY: reviewed-' 'scale report resurfaced permanently reviewed receipts'
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$owner" completed-after scale-release "$old_key" \
    || fail 'batched report discarded reviewed receipt history needed by successor proof'
  : > "$home/jq.count"
  PATH="$fakebin:$PATH" FM_REAL_JQ="$real_jq" FM_JQ_COUNT="$home/jq.count" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_BUDGET_SECS=10 \
    "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup >/dev/null
  reconcile_count=$(cat "$home/jq.count")
  [ "$reconcile_count" -le 24 ] \
    || fail "startup inactive reconciliation launched jq $reconcile_count times for reviewed history"
  assert_contains "$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$owner" report)" \
    'TERMINAL DELIVERY: active-missing ' \
    'startup reconciliation changed the actionable receipt set'
  pass 'terminal report and startup reconciliation batch parser work while preserving proof history'
}
case "${FM_TERMINAL_FOCUSED_TEST:-}" in
  '') ;;
  captain-attestation-report)
    for attestation_backend in auto manual; do
      for attestation_terminal in done failed; do
        run_attestation_case "$attestation_backend" "$attestation_terminal"
      done
    done
    test_report_batches_receipts_at_scale
    exit
    ;;
  review-contracts)
    for attestation_backend in auto manual; do
      for attestation_terminal in done failed; do
        run_attestation_case "$attestation_backend" "$attestation_terminal"
      done
    done
    test_discard_review_acknowledgement
    exit
    ;;
  retired-attestation-recovery)
    for attestation_backend in auto manual; do
      run_retired_attestation_recovery_case "$attestation_backend"
    done
    exit
    ;;
  *) fail "unknown focused terminal test: $FM_TERMINAL_FOCUSED_TEST" ;;
esac
make_task article
"$owner" observe article 'done' https://github.com/o/r/pull/1
"$owner" reconcile
assert_contains "$(tx show article)" 'state: in_flight' 'PR ready must retain unmerged custody'
assert_contains "$("$owner" report)" 'merge_proven=false' 'lost PR custody obligation'
"$owner" retired article normal
rm "$FM_HOME/state/article.meta"
"$owner" reconcile
assert_contains "$(tx show article)" 'state: in_flight' 'safe retirement is not proof of merge'
pass 'PR custody and safe retirement never imply delivery'
make_task landed
"$owner" merged landed https://github.com/o/r/pull/1
"$owner" retired landed normal
rm "$FM_HOME/state/landed.meta"
"$owner" reconcile
"$owner" reconcile
assert_contains "$(tx show landed)" 'state: done' 'retired merged task stayed in flight'
key=$(jq -r 'select(.id=="landed")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
assert_contains "$("$owner" report)" 'refill_pending=true' 'backlog completion lost next action'
"$owner" refill-reviewed "$key"
assert_not_contains "$("$owner" report)" 'TERMINAL DELIVERY: landed ' 'reviewed refill was not retired'
pass 'replay after metadata deletion closes backlog once and retains refill until explicit review'
make_task held
"$owner" merged held https://github.com/o/r/pull/1
"$owner" retired held normal
tx hold held --reason 'captain answer pending' --kind captain --json >/dev/null
"$owner" reconcile
assert_contains "$(tx show held)" 'held: yes' 'terminal reconciliation cleared captain hold'
assert_contains "$(tx show held)" 'state: in_flight' 'held task was silently completed'
test_discard_review_acknowledgement
make_task replaced
"$owner" merged replaced https://github.com/o/r/pull/1
"$owner" retired replaced normal
printf 'spawn_gen=new-incarnation\nkind=ship\nmode=no-mistakes\n' > "$FM_HOME/state/replaced.meta"
"$owner" reconcile
assert_contains "$(tx show replaced)" 'state: in_flight' 'old receipt completed a replacement worker'
pass 'an old incarnation cannot complete a reused task id'
make_task replay
"$owner" merged replay https://github.com/o/r/pull/1
"$owner" retired replay normal
mkdir -p "$TMP_ROOT/fakebin"
real_tasks=$(command -v tasks-axi)
export FM_REAL_TASKS="$real_tasks" FM_REPLAY_MARKER="$TMP_ROOT/failed-once"
cat > "$TMP_ROOT/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
"$FM_REAL_TASKS" "$@" || exit $?
if [ "$1" = done ] && [ "$2" = replay ] && [ ! -e "$FM_REPLAY_MARKER" ]; then
  touch "$FM_REPLAY_MARKER"
  exit 1
fi
EOF
chmod +x "$TMP_ROOT/fakebin/tasks-axi"
PATH="$TMP_ROOT/fakebin:$PATH" "$owner" reconcile && fail 'fixture did not interrupt receipt publication'
assert_contains "$(tx show replay)" 'state: done' 'fixture failed before durable backlog transition'
"$owner" reconcile
assert_contains "$("$owner" report | grep 'TERMINAL DELIVERY: replay')" 'backlog_done=true' 'replay did not converge after interrupted publication'
pass 'backend success followed by lost receipt safely replays without losing refill'
make_task localproof
printf 'spawn_gen=localproof\nkind=ship\nmode=local-only\ndecisions_reviewed=1\ndecision_keys=\n' \
  > "$FM_HOME/state/localproof.meta"
"$owner" retired localproof normal
"$owner" reconcile
assert_contains "$(tx show localproof)" 'state: in_flight' 'custody teardown falsely proved local landing'
"$owner" local-landed localproof 0123456789012345678901234567890123456789
"$owner" reconcile
assert_contains "$(tx show localproof)" 'state: done' 'verified local landing did not advance backlog'
pass 'local-only delivery requires explicit landing proof as well as teardown'
make_task defaultproof
"$owner" retired defaultproof normal
"$owner" default-landed defaultproof 1123456789012345678901234567890123456789
rm "$FM_HOME/state/defaultproof.meta"
"$owner" reconcile
assert_contains "$(tx show defaultproof)" 'state: done' 'verified default-branch landing did not advance backlog'
pass 'authenticated default-branch delivery survives metadata deletion'
make_task exactproof
"$owner" default-landed exactproof 2123456789012345678901234567890123456789
"$owner" landing-proven exactproof
proof_count=$(find "$FM_HOME/state/terminal-delivery" -type f -name '*.json' | wc -l | tr -d ' ')
printf 'spawn_gen=exactproof-replacement\nkind=ship\nmode=no-mistakes\n' > "$FM_HOME/state/exactproof.meta"
"$owner" landing-proven exactproof && fail 'mismatched incarnation reused prior landing proof'
[ "$(find "$FM_HOME/state/terminal-delivery" -type f -name '*.json' | wc -l | tr -d ' ')" = "$proof_count" ] \
  || fail 'landing proof query created a replacement receipt'
make_task custodyproof
"$owner" custody custodyproof https://github.com/o/r/pull/1
"$owner" landing-proven custodyproof && fail 'PR custody was accepted as landing proof'
pass 'landing proof lookup is exact-incarnation, read-only, and custody-safe'
printf '%s\n' manual > "$FM_HOME/config/backlog-backend"
make_task manualdone
"$owner" merged manualdone https://github.com/o/r/pull/1
"$owner" retired manualdone normal
rm "$FM_HOME/state/manualdone.meta"
manual_key=$(jq -r 'select(.id=="manualdone")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
assert_contains "$("$owner" report)" "manual-complete $manual_key" 'manual backend omitted its completion confirmation'
tx 'done' manualdone --pr https://github.com/o/r/pull/1 --no-prune --json >/dev/null
"$owner" manual-complete "$manual_key"
"$owner" manual-complete "$manual_key"
assert_contains "$("$owner" report | grep 'TERMINAL DELIVERY: manualdone')" 'backlog_done=true' 'manual completion was not recorded idempotently'
"$owner" refill-reviewed "$manual_key"
"$owner" refill-reviewed "$manual_key"
assert_not_contains "$("$owner" report)" 'TERMINAL DELIVERY: manualdone ' 'manual refill confirmation was not idempotent'
pass 'manual completion and refill confirmation replay safely'
while read -r matrix_backend matrix_shape matrix_resolution matrix_expected; do
  [ -n "$matrix_backend" ] || continue
  run_terminal_captain_case "$matrix_backend" "$matrix_shape" "$matrix_resolution" "$matrix_expected"
done <<'EOF'
auto transferred unanswered blocked
auto transferred answered progressed
auto origin unanswered blocked
auto origin answered progressed
auto origin released blocked
auto resumed-origin resumed progressed
auto legacy unanswered blocked
auto legacy answered progressed
auto reheld-origin historical blocked
auto reheld-origin current progressed
manual transferred unanswered blocked
manual transferred answered progressed
manual origin unanswered blocked
manual origin answered progressed
manual origin released blocked
manual resumed-origin resumed progressed
manual legacy unanswered blocked
manual legacy answered progressed
manual reheld-origin historical blocked
manual reheld-origin current progressed
EOF
pass 'terminal captain matrix preserves unresolved calls and replays answered transitions'
while read -r release_backend release_scenario release_expected; do
  [ -n "$release_backend" ] || continue
  run_transferred_release_resume_case "$release_backend" "$release_scenario" "$release_expected"
done <<'EOF'
auto pre-resume blocked
auto stale-done blocked
auto missing-proof blocked
auto unrelated blocked
auto new-success progressed
manual pre-resume blocked
manual stale-done blocked
manual missing-proof blocked
manual unrelated blocked
manual new-success progressed
EOF
pass 'transferred releases require their own later verified terminal incarnation'
while read -r identity_backend identity_shape identity_expected; do
  [ -n "$identity_backend" ] || continue
  run_terminal_identity_case "$identity_backend" "$identity_shape" "$identity_expected"
done <<'EOF'
auto self-unresolved blocked
auto self-resumed progressed
auto legacy-alias progressed
manual self-unresolved blocked
manual self-resumed progressed
manual legacy-alias progressed
EOF
pass 'terminal inventory normalizes origin identity and legacy aliases'
while read -r cycle_backend cycle_shape; do
  [ -n "$cycle_backend" ] || continue
  run_cycle_answer_case "$cycle_backend" "$cycle_shape"
done <<'EOF'
auto origin
auto self-inventory
auto transferred
auto legacy
manual origin
manual self-inventory
manual transferred
manual legacy
EOF
pass 'terminal reconciliation binds repeated answers to the current hold cycle'
for attestation_backend in auto manual; do
  for attestation_terminal in done failed; do
    run_attestation_case "$attestation_backend" "$attestation_terminal"
  done
done
pass 'terminal completion requires durable captain-call inventory attestation'
for attestation_backend in auto manual; do
  run_retired_attestation_recovery_case "$attestation_backend"
done
test_report_batches_receipts_at_scale
for identityless_backend in auto manual; do
  printf '%s\n' "$([ "$identityless_backend" = auto ] && printf tasks-axi || printf manual)" \
    > "$FM_HOME/config/backlog-backend"
  identityless_id="identityless-$identityless_backend"
  make_task "$identityless_id"
  tx hold "$identityless_id" --reason 'first captain review pending' --kind captain --json >/dev/null
  release_captain_task "$identityless_id"
  printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$identityless_id" > "$FM_HOME/state/$identityless_id.meta"
  tx hold "$identityless_id" --reason 'new captain review pending' --kind captain --json >/dev/null
  "$owner" merged "$identityless_id" https://github.com/o/r/pull/1
  "$owner" retired "$identityless_id" normal
  rm "$FM_HOME/state/$identityless_id.meta"
  release_captain_task_again "$identityless_id"
  identityless_key=$(jq -r --arg id "$identityless_id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$identityless_backend" = manual ]; then
    "$owner" manual-complete "$identityless_key" \
      && fail 'identity-less newest release advanced manual completion'
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$identityless_key.json")" = false ] \
    || fail "$identityless_backend identity-less newest release advanced terminal backlog"
  assert_contains "$(tx show "$identityless_id")" 'state: in_flight' \
    "$identityless_backend identity-less newest release completed resumed work"
done
pass 'newest identity-less release cannot borrow an older receipt'
make_task manualopen
"$owner" retired manualopen normal
manual_open_key=$(jq -r 'select(.id=="manualopen")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
"$owner" manual-complete "$manual_open_key" && fail 'manual completion treated unmerged custody as delivery'
printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend"
"$owner" manual-complete "$manual_open_key" && fail 'manual completion ignored the backend opt-out boundary'
pass 'manual confirmation refuses unmerged custody and non-manual backends'
