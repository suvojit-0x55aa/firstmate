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
make_task manualheld
"$owner" merged manualheld https://github.com/o/r/pull/1
"$owner" retired manualheld normal
printf '%s\n' 'needs-decision [key=captain-call]: choose delivery treatment' > "$FM_HOME/state/manualheld.status"
manual_held_key=$(jq -r 'select(.id=="manualheld")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
"$owner" manual-complete "$manual_held_key" && fail 'manual completion bypassed a captain-held decision'
assert_contains "$("$owner" report | grep 'TERMINAL DELIVERY: manualheld')" 'backlog_done=false' 'captain-held manual receipt was completed'
pass 'manual completion preserves captain-held decisions'
make_task transferred
tx add transferred-call 'Choose transferred delivery' --json >/dev/null
tx hold transferred-call --reason 'captain delivery choice pending' --kind captain --json >/dev/null
printf '%s\n' 'decisions_reviewed=1' 'decision_keys=transferred-call' >> "$FM_HOME/state/transferred.meta"
printf '%s\n' \
  'needs-decision [key=delivery]: choose transferred delivery' \
  'captain-held [key=delivery]: tracked by transferred-call' \
  > "$FM_HOME/state/transferred.status"
"$owner" merged transferred https://github.com/o/r/pull/1
"$owner" retired transferred normal
rm "$FM_HOME/state/transferred.meta"
transferred_key=$(jq -r 'select(.id=="transferred")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
tx 'done' transferred --pr https://github.com/o/r/pull/1 --no-prune --json >/dev/null
"$owner" manual-complete "$transferred_key" && fail 'manual completion bypassed a transferred captain hold'
tx 'done' transferred-call --no-prune --json >/dev/null
"$owner" manual-complete "$transferred_key" && fail 'out-of-band close masqueraded as a recorded captain answer'
printf '%s\n' 'Captain chose the transferred delivery.' > "$FM_HOME/transferred-answer.txt"
FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" \
  FM_CONFIG_OVERRIDE="$FM_HOME/config" "$ROOT/bin/fm-captain-hold.sh" \
  answer transferred-call --decision-file "$FM_HOME/transferred-answer.txt" >/dev/null
"$owner" manual-complete "$transferred_key"
assert_contains "$("$owner" report | grep 'TERMINAL DELIVERY: transferred')" 'backlog_done=true' \
  'recorded captain answer did not release manual completion'
pass 'manual completion requires the transferred captain hold actual answer'
make_task manualopen
"$owner" retired manualopen normal
manual_open_key=$(jq -r 'select(.id=="manualopen")|.key' "$FM_HOME/state/terminal-delivery/"*.json)
"$owner" manual-complete "$manual_open_key" && fail 'manual completion treated unmerged custody as delivery'
printf '%s\n' tasks-axi > "$FM_HOME/config/backlog-backend"
"$owner" manual-complete "$manual_open_key" && fail 'manual completion ignored the backend opt-out boundary'
pass 'manual confirmation refuses unmerged custody and non-manual backends'
