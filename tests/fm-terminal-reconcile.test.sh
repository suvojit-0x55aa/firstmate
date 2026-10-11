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
make_task() {
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
  key=$(jq -r --arg id "$id" 'select(.id==$id)|.key' "$FM_HOME/state/terminal-delivery/"*.json)
  if [ "$resolution" = answered ] || [ "$resolution" = current ]; then
    answer_captain_task "$call"
  else
    tx 'done' "$call" --no-prune --json >/dev/null
  fi
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
      ;;
    *) fail "unknown terminal captain matrix expectation: $expected" ;;
  esac
}
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
make_task discarded
"$owner" retired discarded discard
"$owner" reconcile
assert_contains "$(tx show discarded)" 'state: in_flight' 'discard masqueraded as delivery'
pass 'captain holds and explicit discard remain unresolved delivery obligations'
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
printf 'spawn_gen=localproof\nkind=ship\nmode=local-only\n' > "$FM_HOME/state/localproof.meta"
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
auto legacy unanswered blocked
auto legacy answered progressed
auto reheld-origin historical blocked
auto reheld-origin current progressed
manual transferred unanswered blocked
manual transferred answered progressed
manual origin unanswered blocked
manual origin answered progressed
manual legacy unanswered blocked
manual legacy answered progressed
manual reheld-origin historical blocked
manual reheld-origin current progressed
EOF
pass 'terminal captain matrix preserves unresolved calls and replays answered transitions'
make_task manualopen
"$owner" retired manualopen normal
manual_open_key=$(jq -r 'select(.id=="manualopen")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
"$owner" manual-complete "$manual_open_key" && fail 'manual completion treated unmerged custody as delivery'
printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend"
"$owner" manual-complete "$manual_open_key" && fail 'manual completion ignored the backend opt-out boundary'
pass 'manual confirmation refuses unmerged custody and non-manual backends'
