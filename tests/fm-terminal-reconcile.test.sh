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
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
owner="$ROOT/bin/fm-terminal-reconcile.sh"
tx() { (cd "$FM_HOME" && tasks-axi "$@" --file "$FM_HOME/data/backlog.md"); }
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
run_preterminal_transferred_release_case() {
  local backend=$1 proof=$2 expected=$3
  local origin="preterminal-$backend-$proof-origin" call="preterminal-$backend-$proof-work"
  local origin_key call_key rc=0 backlog
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown preterminal transferred backend: $backend" ;;
  esac
  make_task "$origin"
  make_task "$call"
  hold_captain_task "$call"
  release_captain_task "$call"
  printf '%s\n' 'decisions_reviewed=1' "decision_keys=$call" >> "$FM_HOME/state/$origin.meta"
  "$owner" merged "$origin" https://github.com/o/r/pull/1
  origin_key=$("$owner" receipt-key "$origin")
  "$owner" retired "$origin" normal
  if [ "$backend" = manual ]; then
    tx 'done' "$origin" --no-prune --json >/dev/null
    "$owner" manual-complete "$origin_key" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend/$proof advanced the origin before transferred proof"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = false ] \
    || fail "$backend/$proof advanced the origin before transferred proof"
  case "$proof" in
    running) ;;
    presented)
      "$owner" observe "$call" done https://github.com/o/r/pull/1
      "$owner" report >/dev/null
      ;;
    undelivered)
      "$owner" custody "$call" https://github.com/o/r/pull/1
      "$owner" retired "$call" normal
      ;;
    discarded)
      "$owner" retired "$call" discard
      ;;
    delivered)
      "$owner" merged "$call" https://github.com/o/r/pull/1
      call_key=$("$owner" receipt-key "$call")
      "$owner" retired "$call" normal
      if [ "$backend" = manual ]; then
        tx 'done' "$call" --no-prune --json >/dev/null
        "$owner" manual-complete "$call_key"
        "$owner" manual-complete "$call_key"
      else
        "$owner" reconcile
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$call_key.json")" = true ] \
        || fail "$backend/$proof did not complete the released transferred receipt"
      ;;
    *) fail "unknown preterminal transferred proof: $proof" ;;
  esac
  rc=0
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$origin_key" >/dev/null 2>&1 || rc=$?
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  backlog=$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")
  case "$expected" in
    blocked)
      [ "$backlog" = false ] || fail "$backend/$proof advanced the referring origin"
      [ "$backend" != manual ] || [ "$rc" -ne 0 ] \
        || fail "$backend/$proof reported manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$origin_key" >/dev/null 2>&1 \
          && fail "$backend/$proof replay advanced the referring origin"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = false ] \
        || fail "$backend/$proof replay advanced the referring origin"
      ;;
    progressed)
      [ "$backlog" = true ] || fail "$backend/$proof did not advance the referring origin"
      [ "$backend" != manual ] || [ "$rc" -eq 0 ] \
        || fail "$backend/$proof refused manual completion"
      if [ "$backend" = manual ]; then
        "$owner" manual-complete "$origin_key"
      else
        "$owner" reconcile
      fi
      [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = true ] \
        || fail "$backend/$proof replay lost referring-origin progress"
      ;;
    *) fail "unknown preterminal transferred expectation: $expected" ;;
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

run_active_attestation_recovery_case() {
  local backend=$1 id="active-review-$1" call key record report
  call="$id-call"
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown active attestation backend: $backend" ;;
  esac
  make_unreviewed_task "$id"
  tx add "$call" "$call" --json >/dev/null
  tx hold "$call" --reason 'active captain review pending' --kind captain --json >/dev/null
  printf '%s\n' 'needs-decision [key=delivery]: choose active delivery treatment' \
    > "$FM_HOME/state/$id.status"
  "$owner" observe "$id" done https://github.com/o/r/pull/1
  key=$("$owner" receipt-key "$id")
  record="$FM_HOME/state/terminal-delivery/$key.json"
  report=$("$owner" report)
  assert_contains "$report" "fm-captain-hold.sh complete $id (" \
    "$backend active missing attestation omitted its metadata recovery command"
  assert_not_contains "$report" "complete $id --receipt" \
    "$backend active missing attestation emitted a retired-only receipt command"
  captain complete "$id" "$call" >/dev/null \
    || fail "$backend active emitted recovery command did not execute"
  assert_contains "$(tx show "$call")" 'held: yes' \
    "$backend active attestation erased its unresolved captain call"
  "$owner" retired "$id" normal
  jq -e --arg call "$call" \
    '.retired == true and .decisions_reviewed == true and .captain_keys == $call' \
    "$record" >/dev/null || fail "$backend active recovery did not become durable at retirement"
}

run_retired_attestation_recovery_case() {
  local backend=$1 id="retired-review-$1" call key record report rc before after
  local forged=forged-recovery missing_key ambiguous="reused-review-$1" reused_call first_key second_key first_record second_record first_before
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

  make_task "$ambiguous"
  "$owner" merged "$ambiguous" https://github.com/o/r/pull/1
  "$owner" retired "$ambiguous" normal
  first_key=$(jq -r --arg id "$ambiguous" --arg incarnation "$ambiguous" \
    'select(.id==$id and .incarnation==$incarnation)|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  first_record="$FM_HOME/state/terminal-delivery/$first_key.json"
  if [ "$backend" = manual ]; then
    tx done "$ambiguous" --no-prune --json >/dev/null
    "$owner" manual-complete "$first_key"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  "$owner" refill-reviewed "$first_key"
  first_before=$(jq -cS . "$first_record")
  reused_call="$ambiguous-call"
  tx add "$reused_call" "$reused_call" --json >/dev/null
  tx hold "$reused_call" --reason 'reused incarnation captain review pending' --kind captain --json >/dev/null
  printf 'spawn_gen=%s-reused\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\n' \
    "$ambiguous" > "$FM_HOME/state/$ambiguous.meta"
  printf 'decision_keys=%s\n' "$reused_call" >> "$FM_HOME/state/$ambiguous.meta"
  "$owner" merged "$ambiguous" https://github.com/o/r/pull/1
  "$owner" retired "$ambiguous" normal
  second_key=$(jq -r --arg id "$ambiguous" --arg incarnation "$ambiguous-reused" \
    'select(.id==$id and .incarnation==$incarnation)|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  second_record="$FM_HOME/state/terminal-delivery/$second_key.json"
  [ "$first_key" != "$second_key" ] || fail "$backend reused-id fixture did not create a second incarnation"
  rm "$FM_HOME/state/$ambiguous.meta"
  if captain complete "$ambiguous" --receipt "$first_key" --none \
    > "$FM_HOME/$ambiguous-stale.out" 2> "$FM_HOME/$ambiguous-stale.err"; then
    fail "$backend metadata-free recovery accepted the historical completed receipt"
  fi
  if captain complete "$ambiguous" --receipt "$key" "$reused_call" \
    > "$FM_HOME/$ambiguous-wrong.out" 2> "$FM_HOME/$ambiguous-wrong.err"; then
    fail "$backend metadata-free recovery accepted another task's authenticated receipt"
  fi
  if captain complete "$ambiguous" --receipt "$second_key" --none \
    > "$FM_HOME/$ambiguous-none.out" 2> "$FM_HOME/$ambiguous-none.err"; then
    fail "$backend reused-id recovery erased its unresolved captain call"
  fi
  captain complete "$ambiguous" --receipt "$second_key" "$reused_call" >/dev/null \
    || fail "$backend explicit active reused-id receipt was not recoverable"
  captain complete "$ambiguous" --receipt "$second_key" "$reused_call" >/dev/null \
    || fail "$backend active reused-id receipt recovery was not idempotent"
  [ "$(jq -cS . "$first_record")" = "$first_before" ] \
    || fail "$backend reused-id recovery mutated the completed historical receipt"
  if [ "$backend" = manual ]; then
    rc=0
    "$owner" manual-complete "$second_key" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend unresolved reused-id call advanced manual completion"
  else
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$second_record")" = false ] \
    || fail "$backend unresolved reused-id call advanced reconciliation"
  answer_captain_task "$reused_call"
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$second_key"
    "$owner" manual-complete "$second_key"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$second_record")" = true ] \
    || fail "$backend active reused-id receipt did not complete after its genuine answer"
  [ "$(jq -cS . "$first_record")" = "$first_before" ] \
    || fail "$backend reused-id completion altered historical receipt A"
  pass "$backend retired captain attestation recovers active reused-id receipts exactly"
}

run_preserved_key_recovery_case() {
  local backend=$1 id="preserved-review-$1" call_a call_b key record before rc=0
  call_a="$id-call-a"
  call_b="$id-call-b"
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown preserved-key recovery backend: $backend" ;;
  esac
  make_unreviewed_task "$id"
  tx add "$call_a" "$call_a" --json >/dev/null
  tx add "$call_b" "$call_b" --json >/dev/null
  tx hold "$call_a" --reason 'first preserved captain call pending' --kind captain --json >/dev/null
  tx hold "$call_b" --reason 'second preserved captain call pending' --kind captain --json >/dev/null
  printf 'decision_keys=%s,%s\n' "$call_a" "$call_b" >> "$FM_HOME/state/$id.meta"
  printf '%s\n' 'done: implementation terminal' > "$FM_HOME/state/$id.status"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  rm "$FM_HOME/state/$id.meta"
  [ "$backend" != manual ] || tx done "$id" --no-prune --json >/dev/null
  before=$(jq -cS . "$record")
  if captain complete "$id" --receipt "$key" "$call_a" \
    > "$FM_HOME/$id-omitted.out" 2> "$FM_HOME/$id-omitted.err"; then
    fail "$backend retired attestation recovery dropped a preserved captain task"
  fi
  if captain complete "$id" --receipt "$key" --none \
    > "$FM_HOME/$id-none.out" 2> "$FM_HOME/$id-none.err"; then
    fail "$backend retired attestation recovery erased its preserved inventory"
  fi
  [ "$(jq -cS . "$record")" = "$before" ] \
    || fail "$backend rejected incomplete recovery mutated the terminal receipt"

  answer_captain_task "$call_a"
  assert_contains "$(tx show "$call_b" --full)" 'hold_kind: captain' \
    "$backend answering one preserved call released the other"
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$key" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend incomplete attestation advanced manual backlog completion"
  else
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$record")" = false ] \
    || fail "$backend answered subset advanced the preserved receipt"

  captain complete "$id" --receipt "$key" "$call_a" "$call_b" >/dev/null \
    || fail "$backend complete preserved inventory was rejected"
  captain complete "$id" --receipt "$key" "$call_a" "$call_b" >/dev/null \
    || fail "$backend preserved inventory replay was not idempotent"
  jq -e --arg a "$call_a" --arg b "$call_b" \
    '.decisions_reviewed == true and .captain_keys == ([$a,$b] | sort | join(","))' \
    "$record" >/dev/null || fail "$backend recovery did not retain every preserved captain task"
  if [ "$backend" = manual ]; then
    rc=0
    "$owner" manual-complete "$key" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend held preserved call advanced manual backlog completion"
  else
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$record")" = false ] \
    || fail "$backend held preserved call advanced the terminal receipt"

  answer_captain_task "$call_b"
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$key"
    "$owner" manual-complete "$key"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$record")" = true ] \
    || fail "$backend genuine answers did not unblock the complete preserved inventory"
  pass "$backend retired attestation recovery preserves and verifies every existing key"
}

run_normalized_inventory_case() {
  local backend=$1 id="normalized-inventory-$1" alias legacy exact key record rc=0
  alias="$id-choice"
  legacy="$id-decision-$alias"
  exact=$alias
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown normalized inventory backend: $backend" ;;
  esac
  make_unreviewed_task "$id"
  tx add "$legacy" "$legacy" --json >/dev/null
  captain hold "$legacy" --reason 'legacy captain identity pending' >/dev/null
  captain complete "$id" "$alias" >/dev/null
  [ "$(sed -n 's/^decision_keys=//p' "$FM_HOME/state/$id.meta" | tail -1)" = "$legacy" ] \
    || fail "$backend completion attestation retained a rebindable legacy alias"

  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$alias" >> "$FM_HOME/state/$id.meta"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  [ "$(jq -r .captain_keys "$record")" = "$legacy" ] \
    || fail "$backend retirement retained a rebindable legacy alias"
  rm "$FM_HOME/state/$id.meta"

  tx add "$exact" "$exact" --json >/dev/null
  captain hold "$exact" --reason 'unrelated exact-name captain task pending' >/dev/null
  answer_captain_task "$exact"
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$key" >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend exact-name collision advanced the original held captain call"
  else
    "$owner" reconcile
  fi
  [ "$(jq -r .backlog "$record")" = false ] \
    || fail "$backend exact-name collision rebound the preserved captain identity"

  answer_captain_task "$legacy"
  if [ "$backend" = manual ]; then
    "$owner" manual-complete "$key"
    "$owner" manual-complete "$key"
  else
    "$owner" reconcile
    "$owner" reconcile
  fi
  jq -e --arg legacy "$legacy" \
    '.backlog == true and .captain_keys == $legacy' "$record" >/dev/null \
    || fail "$backend canonical captain identity did not survive completion replay"
  pass "$backend terminal receipts preserve normalized captain identities"
}

run_completed_inventory_replay_case() {
  local backend=$1 id="completed-inventory-$1" original added key record before meta_before report_before rc=0
  original="$id-original"
  added="$id-added"
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown completed inventory backend: $backend" ;;
  esac
  make_task "$id"
  tx add "$original" "$original" --json >/dev/null
  captain hold "$original" --reason 'original captain call pending' >/dev/null
  captain complete "$id" "$original" >/dev/null
  answer_captain_task "$original"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$key"
  else
    "$owner" reconcile
  fi
  "$owner" refill-reviewed "$key"

  tx add "$added" "$added" --json >/dev/null
  captain hold "$added" --reason 'late captain call pending' >/dev/null
  before=$(jq -cS . "$record")
  meta_before=$(cat "$FM_HOME/state/$id.meta")
  report_before=$("$owner" report)
  if captain complete "$id" --receipt "$key" "$original" "$added" \
    > "$FM_HOME/$id-add.out" 2> "$FM_HOME/$id-add.err"; then
    fail "$backend completed receipt accepted a new invisible captain call"
  fi
  assert_contains "$(cat "$FM_HOME/$id-add.err")" 'active originating work' \
    "$backend completed receipt rejection omitted its existing-owner recovery route"
  [ "$(jq -cS . "$record")" = "$before" ] \
    || fail "$backend rejected completed-receipt mutation changed durable state"
  [ "$(cat "$FM_HOME/state/$id.meta")" = "$meta_before" ] \
    || fail "$backend rejected completed-receipt mutation changed live metadata"
  [ "$("$owner" report)" = "$report_before" ] \
    || fail "$backend rejected completed-receipt mutation changed presentation state"
  captain complete "$id" --receipt "$key" "$original" >/dev/null \
    || fail "$backend identical completed inventory replay was rejected"
  [ "$(jq -cS . "$record")" = "$before" ] \
    || fail "$backend identical completed inventory replay mutated its receipt"
  [ "$(cat "$FM_HOME/state/$id.meta")" = "$meta_before" ] \
    || fail "$backend identical completed inventory replay mutated live metadata"
  pass "$backend completed receipts accept only identical captain inventory replay"
}

test_discard_review_acknowledgement() {
  local id=discarded key record report forged=forged-discard
  local new_key new_record new_before
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

  printf 'spawn_gen=%s-next\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$id" > "$FM_HOME/state/$id.meta"
  "$owner" observe "$id" done https://github.com/o/r/pull/1
  new_key=$(jq -r --arg id "$id" 'select(.id==$id and .incarnation==($id+"-next"))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  [ -n "$new_key" ] || fail 'replacement incarnation did not create its own receipt'
  new_record="$FM_HOME/state/terminal-delivery/$new_key.json"
  new_before=$(jq -cS . "$new_record")
  [ -z "$(jq -r '.superseded_by // ""' "$record")" ] \
    || fail 'replacement incarnation superseded a pending discard review'
  report=$("$owner" report)
  assert_contains "$report" "discard-reviewed $key" \
    'replacement incarnation hid the pending discard review'

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
  assert_not_contains "$("$owner" report)" "receipt=$key " \
    'acknowledged discard remained a presentation alert'
  [ "$(jq -cS . "$new_record")" = "$new_before" ] \
    || fail 'discard acknowledgement mutated the replacement incarnation'
  assert_contains "$(tx show "$id")" 'state: in_flight' \
    'discard acknowledgement completed the backlog item'
  pass 'authenticated discard review survives task-id reuse and retires presentation only'
}

test_report_batches_receipts_at_scale() {
  local home="$TMP_ROOT/report-scale" dir fakebin real_jq out count reconcile_count i old_key=scale-release-old new_key=scale-release-new
  mkdir -p "$home/state/terminal-delivery" "$home/config" "$home/data" "$home/fakebin"
  dir="$home/state/terminal-delivery"
  printf '%s\n' manual > "$home/config/backlog-backend"
  for i in $(seq 1 108); do
    printf '{"schema":"fm-terminal-delivery.v1","key":"reviewed-%03d","id":"reviewed-%03d","incarnation":"reviewed-%03d","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/1","merged":true,"retired":true,"discarded":false,"backlog":true,"refill":false,"reviewed":true,"superseded_by":"","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":true}\n' \
      "$i" "$i" "$i" > "$dir/reviewed-$(printf '%03d' "$i").json"
  done
  printf '%s\n' \
    '{"schema":"fm-terminal-delivery.v1","key":"active-missing","id":"active-missing","incarnation":"active-missing","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/2","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":false,"superseded_by":"","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":false}' \
    > "$dir/active-missing.json"
  printf '%s\n' \
    '{"schema":"fm-terminal-delivery.v1","key":"active-ready","id":"active-ready","incarnation":"active-ready","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/3","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":false,"superseded_by":"","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":true}' \
    > "$dir/active-ready.json"
  printf '{"schema":"fm-terminal-delivery.v1","key":"%s","id":"scale-release","incarnation":"old","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/4","merged":true,"retired":true,"discarded":false,"backlog":false,"refill":false,"reviewed":true,"superseded_by":"%s","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":true}\n' \
    "$old_key" "$new_key" > "$dir/$old_key.json"
  printf '{"schema":"fm-terminal-delivery.v1","key":"%s","id":"scale-release","incarnation":"new","kind":"ship","mode":"no-mistakes","state":"done","pr":"https://github.com/o/r/pull/4","merged":true,"retired":true,"discarded":false,"backlog":true,"refill":false,"reviewed":true,"superseded_by":"","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":true}\n' \
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

test_reconcile_streams_history_past_argv_limit() {
  local original_home=$FM_HOME home="$TMP_ROOT/reconcile-argv-scale" dir fakebin real_jq
  local id=argv-scale-active key record argmax target total=0 i=0 padding name path count report
  FM_HOME=$home
  export FM_HOME
  mkdir -p "$home"/{state/terminal-delivery,config,data,fakebin}
  dir="$home/state/terminal-delivery"
  printf '%s\n' tasks-axi > "$home/config/backlog-backend"
  make_task "$id"
  "$owner" merged "$id" https://github.com/o/r/pull/1
  "$owner" retired "$id" normal
  key=$(jq -r --arg id "$id" 'select(.id==$id)|.key' "$dir/"*.json)
  record="$dir/$key.json"

  argmax=$(getconf ARG_MAX 2>/dev/null || printf 262144)
  target=$((argmax + argmax / 4))
  padding=$(printf '%160s' '' | tr ' ' x)
  while [ "$total" -lt "$target" ]; do
    name=$(printf 'reviewed-%06d-%s' "$i" "$padding")
    path="$dir/$name.json"
    printf '{"schema":"fm-terminal-delivery.v1","key":"%s","id":"history-%06d","incarnation":"history-%06d","kind":"ship","mode":"no-mistakes","state":"done","pr":"","merged":true,"retired":true,"discarded":false,"backlog":true,"refill":false,"reviewed":true,"superseded_by":"","captain_keys":"","origin_captain_cycle":"none","decisions_reviewed":true}\n' \
      "$name" "$i" "$i" > "$path"
    total=$((total + ${#path} + 1))
    i=$((i + 1))
  done

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
  report=$(PATH="$fakebin:$PATH" FM_REAL_JQ="$real_jq" FM_JQ_COUNT="$home/jq.count" \
    "$owner" report)
  [ "$(cat "$home/jq.count")" = 1 ] || fail 'argv-scale report did not use one bounded parser'
  assert_contains "$report" "TERMINAL DELIVERY: $id " \
    'argv-scale report lost its actionable active receipt'

  : > "$home/jq.count"
  PATH="$fakebin:$PATH" FM_REAL_JQ="$real_jq" FM_JQ_COUNT="$home/jq.count" \
    "$owner" reconcile
  count=$(cat "$home/jq.count")
  [ "$count" -le 30 ] || fail "argv-scale reconcile launched jq $count times"
  [ "$(jq -r .backlog "$record")" = true ] \
    || fail 'argv-scale reconcile did not advance the actionable active receipt'
  [ "$(find "$dir" -type f -name 'reviewed-*.json' | wc -l | tr -d ' ')" = "$i" ] \
    || fail 'argv-scale reconcile did not preserve retained receipt history'
  FM_HOME=$original_home
  export FM_HOME
  pass 'terminal report and reconciliation stream history beyond the argv limit'
}

test_reconcile_cursor_orders_streamed_candidates() {
  local original_home=$FM_HOME home="$TMP_ROOT/reconcile-cursor-order" dir fakebin
  local history_key history_record history_digest real_find real_tasks keys key_a key_b key_c
  local id_a id_b id_c record_a record_b record_c run
  FM_HOME=$home
  export FM_HOME
  mkdir -p "$home"/{state/terminal-delivery,config,data,fakebin}
  dir="$home/state/terminal-delivery"
  fakebin="$home/fakebin"
  printf '%s\n' tasks-axi > "$home/config/backlog-backend"

  make_task cursor-history
  "$owner" merged cursor-history https://github.com/o/r/pull/1
  "$owner" retired cursor-history normal
  "$owner" reconcile
  "$owner" reconcile
  history_key=$(jq -r 'select(.id=="cursor-history")|.key' "$dir/"*.json)
  "$owner" refill-reviewed "$history_key"
  history_record="$dir/$history_key.json"
  history_digest=$(shasum -a 256 "$history_record" | awk '{print $1}')

  for id in cursor-one cursor-two cursor-three; do
    make_task "$id"
    "$owner" merged "$id" https://github.com/o/r/pull/1
    "$owner" retired "$id" normal
  done
  keys=$(jq -r 'select(.id | startswith("cursor-") and . != "cursor-history")|.key' "$dir/"*.json | LC_ALL=C sort)
  key_a=$(printf '%s\n' "$keys" | sed -n '1p')
  key_b=$(printf '%s\n' "$keys" | sed -n '2p')
  key_c=$(printf '%s\n' "$keys" | sed -n '3p')
  [ -n "$key_a" ] && [ -n "$key_b" ] && [ -n "$key_c" ] \
    || fail 'cursor-order fixture did not create three authenticated candidates'
  record_a="$dir/$key_a.json"
  record_b="$dir/$key_b.json"
  record_c="$dir/$key_c.json"
  id_a=$(jq -r .id "$record_a")
  id_b=$(jq -r .id "$record_b")
  id_c=$(jq -r .id "$record_c")
  printf '%s\n' "$key_b.json" > "$dir/.cursor"

  real_find=$(command -v find)
  real_tasks=$(command -v tasks-axi)
  cat > "$fakebin/find" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "$FM_TEST_RECEIPT_DIR" ]; then
  cat "$FM_TEST_RECORD_B" "$FM_TEST_RECORD_A" "$FM_TEST_RECORD_C"
  exit 0
fi
exec "$FM_REAL_FIND" "$@"
EOF
  cat > "$fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = "$FM_TEST_FAIL_ID" ]; then
  exit 1
fi
exec "$FM_REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$fakebin/find" "$fakebin/tasks-axi"

  for run in 1 2; do
    if PATH="$fakebin:$PATH" FM_REAL_FIND="$real_find" FM_REAL_TASKS_AXI="$real_tasks" \
      FM_TEST_RECEIPT_DIR="$dir" FM_TEST_RECORD_A="$record_a" \
      FM_TEST_RECORD_B="$record_b" FM_TEST_RECORD_C="$record_c" FM_TEST_FAIL_ID="$id_b" \
      "$owner" reconcile; then
      fail "cursor-order reconcile $run did not surface the persistent middle failure"
    fi
    [ "$(jq -r .backlog "$record_a")" = true ] \
      || fail "cursor-order reconcile $run starved the candidate before the cursor"
    [ "$(jq -r .backlog "$record_c")" = true ] \
      || fail "cursor-order reconcile $run starved the candidate after the cursor"
    [ "$(jq -r .backlog "$record_b")" = false ] \
      || fail "cursor-order reconcile $run advanced the deliberately failing candidate"
    [ "$(shasum -a 256 "$history_record" | awk '{print $1}')" = "$history_digest" ] \
      || fail "cursor-order reconcile $run changed retained reviewed history"
    [ "$(cat "$dir/.cursor")" = "$key_b.json" ] \
      || fail "cursor-order reconcile $run did not return fairly to the failing candidate"
  done
  assert_contains "$(tx show "$id_a")" 'state: done' 'cursor-order reconcile did not complete the lower candidate'
  assert_contains "$(tx show "$id_c")" 'state: done' 'cursor-order reconcile did not complete the upper candidate'
  FM_HOME=$original_home
  export FM_HOME
  pass 'terminal reconciliation orders streamed candidates before cursor traversal'
}

run_archived_captain_answer_case() {
  local backend=$1 id="archived-answer-$1" call filler key backlog
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown archived captain-answer backend: $backend" ;;
  esac
  make_task "$id"
  call="$id-call"
  tx add "$call" "$call" --json >/dev/null
  hold_captain_task "$call"
  printf '%s\n' 'decisions_reviewed=1' "decision_keys=$call" >> "$FM_HOME/state/$id.meta"
  answer_captain_task "$call"
  for filler in $(seq 1 11); do
    tx add "$id-filler-$filler" "$id filler $filler" --json >/dev/null
    tx done "$id-filler-$filler" --json >/dev/null
  done
  if tx show "$call" --full >/dev/null 2>&1; then
    fail "$backend answered captain call did not cross the configured Done archive boundary"
  fi
  assert_present "$FM_HOME/data/done-archive.md" \
    "$backend Done pruning did not produce the configured captain-answer archive"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  rm "$FM_HOME/state/$id.meta"
  key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$key" >/dev/null
    "$owner" manual-complete "$key" >/dev/null
  else
    "$owner" reconcile >/dev/null
    "$owner" reconcile >/dev/null
  fi
  backlog=$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")
  [ "$backlog" = true ] || fail "$backend archived captain answer blocked origin reconciliation"
  ARCHIVED_CALL=$call
}

archive_done_task() {
  local id=$1 prefix=$2 filler
  for filler in $(seq 1 11); do
    tx add "$prefix-filler-$filler" "$prefix filler $filler" --json >/dev/null
    tx done "$prefix-filler-$filler" --json >/dev/null
  done
  if tx show "$id" --full >/dev/null 2>&1; then
    fail "$id did not cross the configured Done archive boundary"
  fi
}

run_archived_released_transfer_case() {
  local backend=$1 id="archived-release-$1" call old_key new_key origin_key
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown archived released-transfer backend: $backend" ;;
  esac
  make_task "$id"
  call="$id-work"
  make_task "$call"
  hold_captain_task "$call"
  printf '%s\n' 'decisions_reviewed=1' "decision_keys=$call" >> "$FM_HOME/state/$id.meta"
  "$owner" custody "$call" https://github.com/o/r/pull/1 >/dev/null
  old_key=$(jq -r --arg id "$call" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  release_captain_task "$call"
  printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$call" > "$FM_HOME/state/$call.meta"
  "$owner" merged "$call" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$call" normal >/dev/null
  rm "$FM_HOME/state/$call.meta"
  new_key=$(jq -r --arg id "$call" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  [ "$new_key" != "$old_key" ] || fail "$backend released transfer did not create a successor receipt"
  if [ "$backend" = manual ]; then
    tx done "$call" --no-prune --json >/dev/null
    "$owner" manual-complete "$new_key" >/dev/null
  else
    "$owner" reconcile >/dev/null
    "$owner" reconcile >/dev/null
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$new_key.json")" = true ] \
    || fail "$backend released transfer successor did not complete"
  archive_done_task "$call" "$id-transfer-archive"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  rm "$FM_HOME/state/$id.meta"
  origin_key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    "$owner" manual-complete "$origin_key" >/dev/null
    "$owner" manual-complete "$origin_key" >/dev/null
  else
    "$owner" reconcile >/dev/null
    "$owner" reconcile >/dev/null
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$origin_key.json")" = true ] \
    || fail "$backend archived released transfer blocked origin reconciliation"
}

test_archived_released_origin_requires_successor() {
  local id=archived-release-origin old_key new_key saved_backlog saved_archive report
  printf '%s\n' manual > "$FM_HOME/config/backlog-backend"
  make_task "$id"
  hold_captain_task "$id"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  old_key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  release_captain_task "$id"
  rm "$FM_HOME/state/$id.meta"
  tx done "$id" --no-prune --json >/dev/null
  archive_done_task "$id" "$id-archive"
  if "$owner" manual-complete "$old_key" >/dev/null 2>&1; then
    fail 'archived released origin accepted its stale release incarnation'
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$old_key.json")" = false ] \
    || fail 'stale archived origin advanced backlog state'
  jq -e '.origin_captain_cycle | test("^[0-9a-f]{64}$")' \
    "$FM_HOME/state/terminal-delivery/$old_key.json" >/dev/null \
    || fail 'released origin receipt did not preserve its exact captain cycle'

  saved_archive="$FM_HOME/data/done-archive.origin-evidence"
  cp "$FM_HOME/data/done-archive.md" "$saved_archive"
  : > "$FM_HOME/data/done-archive.md"
  if "$owner" manual-complete "$old_key" >/dev/null 2>&1; then
    fail 'missing archived origin evidence authorized stale-receipt manual completion'
  fi
  printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend"
  "$owner" reconcile >/dev/null
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$old_key.json")" = false ] \
    || fail 'missing archived origin evidence authorized automatic completion'
  printf '%s\n' manual > "$FM_HOME/config/backlog-backend"
  report=$("$owner" report)
  assert_contains "$report" 'restore the exact active or archived origin captain-cycle evidence' \
    'missing origin proof did not retain an actionable recovery path'

  cat > "$FM_HOME/data/done-archive.md" <<EOF
## Archived 2026-10-12T00:00:00Z
- [x] $id - corrupt released origin
  Resolution recorded by fm-captain-hold.
  Decision digest: 2222222222222222222222222222222222222222222222222222222222222222
  Resolution mode: released
  Hold cycle: corrupt
  Terminal receipt: $old_key
  Captain decision:
  Captain released the origin.
EOF
  if "$owner" manual-complete "$old_key" >/dev/null 2>&1; then
    fail 'corrupt archived origin cycle authorized manual completion'
  fi
  mv "$saved_archive" "$FM_HOME/data/done-archive.md"
  printf 'spawn_gen=%s-resumed\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$id" > "$FM_HOME/state/$id.meta"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  rm "$FM_HOME/state/$id.meta"
  new_key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  "$owner" manual-complete "$new_key" >/dev/null
  "$owner" manual-complete "$new_key" >/dev/null
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$new_key.json")" = true ] \
    || fail 'archived released origin did not accept its verified successor'

  saved_backlog="$FM_HOME/data/backlog.md.saved"
  mv "$FM_HOME/data/backlog.md" "$saved_backlog"
  mkdir "$FM_HOME/data/backlog.md"
  if captain terminal-ready "$id" --receipt "$new_key" >/dev/null 2>&1; then
    fail 'captain readiness treated an unreadable active backlog as authentic absence'
  fi
  rmdir "$FM_HOME/data/backlog.md"
  mv "$saved_backlog" "$FM_HOME/data/backlog.md"
}

run_ordinary_origin_obligation_case() {
  local backend=$1 id="ordinary-origin-$1" key saved_archive
  case "$backend" in
    auto) printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend" ;;
    manual) printf '%s\n' manual > "$FM_HOME/config/backlog-backend" ;;
    *) fail "unknown ordinary-origin backend: $backend" ;;
  esac
  make_task "$id"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  [ "$(jq -r .origin_captain_cycle "$FM_HOME/state/terminal-delivery/$key.json")" = none ] \
    || fail "$backend ordinary origin receipt did not durably prove no captain obligation"
  rm "$FM_HOME/state/$id.meta"
  if [ "$backend" = manual ]; then
    tx done "$id" --no-prune --json >/dev/null
    archive_done_task "$id" "$id-archive"
    saved_archive="$FM_HOME/data/done-archive.ordinary"
    cp "$FM_HOME/data/done-archive.md" "$saved_archive"
    : > "$FM_HOME/data/done-archive.md"
    "$owner" manual-complete "$key" >/dev/null
    "$owner" manual-complete "$key" >/dev/null
    mv "$saved_archive" "$FM_HOME/data/done-archive.md"
  else
    "$owner" reconcile >/dev/null
    "$owner" reconcile >/dev/null
  fi
  [ "$(jq -r .backlog "$FM_HOME/state/terminal-delivery/$key.json")" = true ] \
    || fail "$backend ordinary origin did not complete with durable no-obligation proof"
}

test_unknown_origin_obligation_recovers_through_captain_owner() {
  local id=unknown-origin-obligation key record report tmp saved_archive wrong_id wrong_key
  printf '%s\n' manual > "$FM_HOME/config/backlog-backend"
  make_task "$id"
  "$owner" merged "$id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$id" normal >/dev/null
  key=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  record="$FM_HOME/state/terminal-delivery/$key.json"
  rm "$FM_HOME/state/$id.meta"
  tx done "$id" --no-prune --json >/dev/null
  archive_done_task "$id" "$id-archive"
  saved_archive="$FM_HOME/data/done-archive.unknown-origin"
  cp "$FM_HOME/data/done-archive.md" "$saved_archive"
  tmp=$(mktemp "$FM_HOME/state/terminal-delivery/.unknown.XXXXXX")
  jq '.origin_captain_cycle="corrupt"' "$record" > "$tmp"
  mv "$tmp" "$record"
  if "$owner" manual-complete "$key" >/dev/null 2>&1; then
    fail 'corrupt receipt origin obligation authorized manual completion'
  fi
  report=$("$owner" report)
  assert_contains "$report" 'Origin captain-cycle evidence is unknown' \
    'corrupt origin obligation did not retain an actionable recovery path'

  : > "$FM_HOME/data/done-archive.md"
  if captain complete "$id" --receipt "$key" --none >/dev/null 2>&1; then
    fail 'missing archive-only origin evidence authorized receipt recovery'
  fi
  cat > "$FM_HOME/data/done-archive.md" <<EOF
## Archived 2026-10-12T00:00:00Z
- [x] $id - corrupt archived origin (hold-kind: captain)
  Captain hold opened by fm-captain-hold.
  Hold cycle: corrupt
  Captain hold marker end.
EOF
  if captain complete "$id" --receipt "$key" --none >/dev/null 2>&1; then
    fail 'corrupt archive-only origin evidence authorized receipt recovery'
  fi
  cat "$saved_archive" "$saved_archive" > "$FM_HOME/data/done-archive.md"
  if captain complete "$id" --receipt "$key" --none >/dev/null 2>&1; then
    fail 'ambiguous archive-only origin evidence authorized receipt recovery'
  fi
  cp "$saved_archive" "$FM_HOME/data/done-archive.md"
  wrong_id="$id-wrong-receipt"
  make_task "$wrong_id"
  "$owner" merged "$wrong_id" https://github.com/o/r/pull/1 >/dev/null
  "$owner" retired "$wrong_id" normal >/dev/null
  wrong_key=$(jq -r --arg id "$wrong_id" \
    'select(.id==$id and ((.superseded_by // "") == ""))|.key' \
    "$FM_HOME/state/terminal-delivery/"*.json)
  if captain complete "$id" --receipt "$wrong_key" --none >/dev/null 2>&1; then
    fail 'mismatched terminal receipt authorized archive-only origin recovery'
  fi
  captain complete "$id" --receipt "$key" --none >/dev/null
  [ "$(jq -r .origin_captain_cycle "$record")" = none ] \
    || fail 'archive-only recovery did not repair a corrupt origin obligation'
  tmp=$(mktemp "$FM_HOME/state/terminal-delivery/.unknown.XXXXXX")
  jq 'del(.origin_captain_cycle)' "$record" > "$tmp"
  mv "$tmp" "$record"
  if "$owner" manual-complete "$key" >/dev/null 2>&1; then
    fail 'legacy-unknown origin obligation authorized manual completion'
  fi
  report=$("$owner" report)
  assert_contains "$report" 'Origin captain-cycle evidence is unknown' \
    'legacy-unknown origin obligation did not retain an actionable recovery path'
  captain complete "$id" --receipt "$key" --none >/dev/null
  [ "$(jq -r .origin_captain_cycle "$record")" = none ] \
    || fail 'archive-only recovery did not repair a legacy origin obligation'
  "$owner" manual-complete "$key" >/dev/null
  "$owner" manual-complete "$key" >/dev/null
  [ "$(jq -r .backlog "$record")" = true ] \
    || fail 'authenticated archive-only recovery did not complete backlog state'
}

test_archived_captain_answers_remain_exact_terminal_evidence() {
  local auto_call manual_call
  run_archived_captain_answer_case auto
  auto_call=$ARCHIVED_CALL
  run_archived_captain_answer_case manual
  manual_call=$ARCHIVED_CALL
  captain terminal-ready archive-replay "$auto_call" \
    || fail "archived captain answer was not replay-stable"
  cat >> "$FM_HOME/data/done-archive.md" <<EOF

## Archived 2026-10-12T00:00:00Z
- [x] $auto_call - ambiguous reused identity (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
EOF
  if captain terminal-ready archive-ambiguous "$auto_call" >/dev/null 2>&1; then
    fail "ambiguous archived captain-answer identities were accepted"
  fi
  tx add "$manual_call" "$manual_call reused" --json >/dev/null
  hold_captain_task "$manual_call"
  if captain terminal-ready archive-reheld "$manual_call" >/dev/null 2>&1; then
    fail "a new active hold reused an archived captain answer"
  fi
  if captain terminal-ready archive-missing missing-captain-call >/dev/null 2>&1; then
    fail "missing captain-answer evidence was accepted"
  fi
  run_archived_released_transfer_case auto
  run_archived_released_transfer_case manual
  test_archived_released_origin_requires_successor
  run_ordinary_origin_obligation_case auto
  run_ordinary_origin_obligation_case manual
  test_unknown_origin_obligation_recovers_through_captain_owner
  pass 'archived captain answers and releases retain exact cycle-aware terminal evidence'
}
test_merge_observation_stays_bound_to_exact_receipt() {
  local id=merge-observed-reuse p1=https://github.com/o/r/pull/101 p2=https://github.com/o/r/pull/202
  local p3=https://github.com/o/r/pull/303 key_a key_b record_a record_b before_b current_key
  local ambiguous=merge-observed-ambiguous ambiguous_a ambiguous_b before_a before_ambiguous_b
  local early=merge-observed-early early_pr=https://github.com/o/r/pull/404 early_key early_record

  report_merge() {
    FM_HOME="$FM_HOME" bash -c \
      '. "$1"; fm_merge_outcome_report "$2" "$3" "$4" "$5" poll' \
      _ "$ROOT/bin/fm-merge-outcome-lib.sh" "$FM_HOME" "$FM_HOME/state" "$1" "$2"
  }

  make_task "$early"
  printf 'spawn_gen=%s\nkind=ship\nmode=no-mistakes\npr=%s\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$early" "$early_pr" > "$FM_HOME/state/$early.meta"
  report_merge "$early" "$early_pr" \
    || fail 'merge poll before first receipt did not persist exact current proof'
  early_key=$("$owner" receipt-key "$early")
  early_record="$FM_HOME/state/terminal-delivery/$early_key.json"
  jq -e --arg pr "$early_pr" '.pr == $pr and .merged == true and .retired == false' \
    "$early_record" >/dev/null || fail 'early merge poll did not create merged current receipt'
  [ -f "$FM_HOME/state/$early.pr-poll-merge-notified" ] \
    || fail 'early merge poll was not acknowledged after proof persisted'
  "$owner" retired "$early" normal
  rm "$FM_HOME/state/$early.meta"
  "$owner" reconcile
  "$owner" reconcile
  assert_contains "$(tx show "$early")" 'state: done' \
    'persisted early merge proof did not recover after metadata disappeared'

  make_task "$id"
  "$owner" observe "$id" done "$p1"
  key_a=$("$owner" receipt-key "$id")
  record_a="$FM_HOME/state/terminal-delivery/$key_a.json"
  "$owner" retired "$id" normal

  printf 'spawn_gen=%s-b\nkind=ship\nmode=no-mistakes\npr=%s\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$id" "$p2" > "$FM_HOME/state/$id.meta"
  "$owner" observe "$id" done "$p2"
  key_b=$("$owner" receipt-key "$id")
  record_b="$FM_HOME/state/terminal-delivery/$key_b.json"
  [ "$key_a" != "$key_b" ] || fail 'reused merge-observation fixture did not create a new incarnation'
  before_b=$(shasum -a 256 "$record_b" | awk '{print $1}')
  "$owner" landing-proven "$id" && fail 'unmerged replacement started with delivery proof'

  "$owner" merge-observed "$id" "$p1"
  [ "$(shasum -a 256 "$record_b" | awk '{print $1}')" = "$before_b" ] \
    || fail 'delayed P1 observation mutated replacement receipt B'
  jq -e --arg pr "$p2" '.pr == $pr and .merged == false and .retired == false and .backlog == false' \
    "$record_b" >/dev/null || fail 'delayed P1 observation changed B delivery or teardown state'
  jq -e --arg pr "$p1" '.pr == $pr and .merged == true and .retired == true' \
    "$record_a" >/dev/null || fail 'delayed P1 observation did not reconcile exact retired receipt A'
  "$owner" landing-proven "$id" && fail 'retired A merge proof authorized replacement B'
  assert_contains "$(tx show "$id")" 'state: in_flight' \
    'delayed P1 observation completed replacement B'
  current_key=$("$owner" receipt-key "$id")
  [ "$current_key" = "$key_b" ] || fail 'delayed P1 observation rebound current receipt identity'

  "$owner" merge-observed "$id" "$p1"
  jq -e --arg pr "$p1" '.pr == $pr and .merged == true' "$record_a" >/dev/null \
    || fail 'exact retired merge observation was not idempotent'
  if report_merge "$id" "$p3"; then
    fail 'absent merge observation was acknowledged instead of remaining retryable'
  fi
  [ ! -e "$FM_HOME/state/$id.pr-poll-merge-notified" ] \
    || fail 'absent merge observation committed its notification marker'
  [ "$(shasum -a 256 "$record_b" | awk '{print $1}')" = "$before_b" ] \
    || fail 'absent P3 evidence mutated current receipt B'

  "$owner" merge-observed "$id" "$p2"
  "$owner" merge-observed "$id" "$p2"
  jq -e --arg pr "$p2" '.pr == $pr and .merged == true' "$record_b" >/dev/null \
    || fail 'exact current P2 observation did not reconcile idempotently'
  "$owner" landing-proven "$id" || fail 'exact current P2 observation did not establish delivery proof'

  make_task "$ambiguous"
  "$owner" observe "$ambiguous" done "$p1"
  ambiguous_a=$("$owner" receipt-key "$ambiguous")
  "$owner" retired "$ambiguous" normal
  printf 'spawn_gen=%s-b\nkind=ship\nmode=no-mistakes\npr=%s\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$ambiguous" "$p1" > "$FM_HOME/state/$ambiguous.meta"
  "$owner" observe "$ambiguous" done "$p1"
  ambiguous_b=$("$owner" receipt-key "$ambiguous")
  before_a=$(shasum -a 256 "$FM_HOME/state/terminal-delivery/$ambiguous_a.json" | awk '{print $1}')
  before_ambiguous_b=$(shasum -a 256 "$FM_HOME/state/terminal-delivery/$ambiguous_b.json" | awk '{print $1}')
  if report_merge "$ambiguous" "$p1"; then
    fail 'ambiguous merge observation was acknowledged instead of remaining retryable'
  fi
  [ ! -e "$FM_HOME/state/$ambiguous.pr-poll-merge-notified" ] \
    || fail 'ambiguous merge observation committed its notification marker'
  [ "$(shasum -a 256 "$FM_HOME/state/terminal-delivery/$ambiguous_a.json" | awk '{print $1}')" = "$before_a" ] \
    && [ "$(shasum -a 256 "$FM_HOME/state/terminal-delivery/$ambiguous_b.json" | awk '{print $1}')" = "$before_ambiguous_b" ] \
    || fail 'ambiguous exact PR evidence mutated one reused incarnation'
  pass 'merge observations persist or retry only exact authenticated receipts'
}
test_supersession_preserves_unresolved_captain_inventory() {
  local id=supersession-inventory call=supersession-inventory-call
  local old_key new_key old_record new_record cycle valid_cycle pr=https://github.com/o/r/pull/505
  make_task "$id"
  tx add "$call" "$call" --json >/dev/null
  hold_captain_task "$id"
  hold_captain_task "$call"
  printf 'decision_keys=%s\ndecisions_reviewed=1\n' "$call" >> "$FM_HOME/state/$id.meta"
  "$owner" merged "$id" "$pr"
  "$owner" retired "$id" normal
  old_key=$("$owner" receipt-key "$id")
  old_record="$FM_HOME/state/terminal-delivery/$old_key.json"
  cycle=$(jq -r .origin_captain_cycle "$old_record")
  valid_cycle=$(printf '%s' "$cycle" | grep -Ec '^[0-9a-f]{64}$' || true)
  [ "$valid_cycle" -eq 1 ] || fail 'supersession fixture did not retain an exact origin hold cycle'
  release_captain_task "$id"
  rm "$FM_HOME/state/$id.meta"
  printf 'spawn_gen=%s-reused\nkind=ship\nmode=no-mistakes\npr=%s\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$id" "$pr" > "$FM_HOME/state/$id.meta"
  "$owner" observe "$id" done "$pr"
  new_key=$("$owner" receipt-key "$id")
  new_record="$FM_HOME/state/terminal-delivery/$new_key.json"
  [ "$old_key" != "$new_key" ] || fail 'supersession fixture did not create a replacement receipt'
  jq -e --arg key "$new_key" '.superseded_by == $key' "$old_record" >/dev/null \
    || fail 'replacement receipt did not supersede its exact predecessor'
  jq -e --arg call "$call" --arg cycle "$cycle" \
    '.captain_keys == $call and .origin_captain_cycle == $cycle' "$new_record" >/dev/null \
    || fail 'receipt supersession dropped unresolved captain inventory or cycle'
  "$owner" retired "$id" normal
  if captain complete "$id" --receipt "$new_key" --none >/dev/null 2>&1; then
    fail 'empty completion erased inherited unresolved captain inventory'
  fi
  jq -e --arg call "$call" --arg cycle "$cycle" \
    '.captain_keys == $call and .origin_captain_cycle == $cycle and .backlog == false' \
    "$new_record" >/dev/null || fail 'refused empty completion changed inherited evidence'
  assert_contains "$(tx show "$call")" 'held: yes' \
    'refused empty completion released the inherited captain call'
  answer_captain_task "$call"
  captain complete "$id" --receipt "$new_key" "$call" >/dev/null \
    || fail 'explicit inherited captain inventory was not recoverable'
  "$owner" reconcile
  "$owner" reconcile
  assert_contains "$(tx show "$id")" 'state: done' \
    'answered inherited captain inventory did not unblock replacement completion'
  pass 'receipt supersession preserves unresolved captain inventory and cycle'
}
case "${FM_TERMINAL_FOCUSED_TEST:-}" in
  '') ;;
  captain-attestation-report)
    for attestation_backend in auto manual; do
      run_active_attestation_recovery_case "$attestation_backend"
      for attestation_terminal in done failed; do
        run_attestation_case "$attestation_backend" "$attestation_terminal"
      done
      run_retired_attestation_recovery_case "$attestation_backend"
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
  discard-reuse)
    test_discard_review_acknowledgement
    exit
    ;;
  retired-attestation-recovery)
    for attestation_backend in auto manual; do
      run_retired_attestation_recovery_case "$attestation_backend"
    done
    test_reconcile_streams_history_past_argv_limit
    exit
    ;;
  preserved-key-recovery)
    for attestation_backend in auto manual; do
      run_preserved_key_recovery_case "$attestation_backend"
    done
    exit
    ;;
  inventory-contracts)
    for attestation_backend in auto manual; do
      run_normalized_inventory_case "$attestation_backend"
      run_completed_inventory_replay_case "$attestation_backend"
    done
    exit
    ;;
  cursor-order)
    test_reconcile_cursor_orders_streamed_candidates
    exit
    ;;
  preterminal-transfer)
    while read -r release_backend release_proof release_expected; do
      [ -n "$release_backend" ] || continue
      run_preterminal_transferred_release_case "$release_backend" "$release_proof" "$release_expected"
    done <<'EOF'
auto running blocked
auto presented blocked
auto undelivered blocked
auto discarded blocked
auto delivered progressed
manual running blocked
manual presented blocked
manual undelivered blocked
manual discarded blocked
manual delivered progressed
EOF
    exit
    ;;
  archived-captain-answer)
    test_archived_captain_answers_remain_exact_terminal_evidence
    exit
    ;;
  merge-observed-identity)
    test_merge_observation_stays_bound_to_exact_receipt
    exit
    ;;
  supersession-inventory)
    test_supersession_preserves_unresolved_captain_inventory
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
while read -r release_backend release_proof release_expected; do
  [ -n "$release_backend" ] || continue
  run_preterminal_transferred_release_case "$release_backend" "$release_proof" "$release_expected"
done <<'EOF'
auto running blocked
auto presented blocked
auto undelivered blocked
auto discarded blocked
auto delivered progressed
manual running blocked
manual presented blocked
manual undelivered blocked
manual discarded blocked
manual delivered progressed
EOF
pass 'preterminal transferred releases require exact delivered terminal evidence'
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
  run_active_attestation_recovery_case "$attestation_backend"
  for attestation_terminal in done failed; do
    run_attestation_case "$attestation_backend" "$attestation_terminal"
  done
done
pass 'terminal completion requires durable captain-call inventory attestation'
for attestation_backend in auto manual; do
  run_retired_attestation_recovery_case "$attestation_backend"
  run_preserved_key_recovery_case "$attestation_backend"
  run_normalized_inventory_case "$attestation_backend"
  run_completed_inventory_replay_case "$attestation_backend"
done
test_report_batches_receipts_at_scale
test_reconcile_streams_history_past_argv_limit
test_reconcile_cursor_orders_streamed_candidates
test_archived_captain_answers_remain_exact_terminal_evidence
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
