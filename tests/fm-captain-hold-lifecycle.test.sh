#!/usr/bin/env bash
# End-to-end tests for captain-held tasks: the one primitive behind "a decision
# is simply a task waiting on the captain", its completion gate, its recorded
# answers, the record-divergence guard over its two records, and the legacy
# compatibility for pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_terminal() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-terminal-reconcile.sh" "$@"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind"
}

use_manual_reader() {  # <home>
  local home=$1
  printf '%s\n' manual > "$home/config/backlog-backend"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'tasks-axi 0.0.0'
  exit 0
fi
exit 97
SH
  chmod +x "$home/fakebin/tasks-axi"
}

archive_done_task_in_home() {  # <home> <task-id> <prefix>
  local home=$1 id=$2 prefix=$3 filler
  for filler in $(seq 1 11); do
    tasks_in "$home" add "$prefix-filler-$filler" "$prefix filler $filler" >/dev/null
    tasks_in "$home" 'done' "$prefix-filler-$filler" >/dev/null
  done
  if tasks_in "$home" show "$id" --full >/dev/null 2>&1; then
    fail "$id did not cross the configured Done archive boundary"
  fi
}

run_cycle_bound_teardown_control() {  # <backend> <held-or-answered>
  local backend=$1 resolution=$2 home id call
  home=$(make_home "cycle-control-$backend-$resolution")
  id="sample-cycle-control-$backend-$resolution"
  call="$id-call"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "$id" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Exact cycle control\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "$call" \
    --reason "captain cycle control pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" "$call" >/dev/null
  if [ "$resolution" = answered ]; then
    printf 'Captain answered the exact persisted cycle.\n' > "$home/answer.txt"
    run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null
  fi
  [ "$backend" != manual ] || use_manual_reader "$home"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "$backend $resolution exact-cycle teardown failed: $(cat "$home/teardown.err")"
}

run_reused_cycle_teardown_refusal() {  # <backend>
  local backend=$1 home id call meta report custody saved_calls bad_calls before_meta before_report before_custody rc
  home=$(make_home "teardown-cycle-reuse-$backend")
  id="sample-cycle-reuse-$backend"
  call="$id-call"
  meta="$home/state/$id.meta"
  report="$home/data/$id/report.md"
  custody="$home/projects/missing-$id/custody.marker"
  mkdir -p "$home/data/$id" "$(dirname "$custody")"
  tasks_in "$home" add "$id" "$id" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Reused cycle teardown evidence\n' > "$report"
  printf 'custody retained\n' > "$custody"
  run_captain "$home" hold "$call" --title "$call" \
    --reason "captain original cycle pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" "$call" >/dev/null
  saved_calls=$(sed -n 's/^decision_call_cycles=//p' "$meta" | tail -1)
  [ -n "$saved_calls" ] || fail "$backend reuse fixture omitted the original cycle"
  tasks_in "$home" 'done' "$call" --no-prune >/dev/null
  archive_done_task_in_home "$home" "$call" "$id-archive"
  tasks_in "$home" add "$call" "$call replacement" >/dev/null
  run_captain "$home" hold "$call" --reason "captain replacement cycle pending" >/dev/null
  printf 'Captain answered only the replacement cycle.\n' > "$home/replacement-answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/replacement-answer.txt" >/dev/null

  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/treehouse.log"
exit 0
SH
  cat > "$home/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/tmux.log"
exit 0
SH
  chmod +x "$home/fakebin/treehouse" "$home/fakebin/tmux"
  [ "$backend" != manual ] || use_manual_reader "$home"

  before_meta=$(shasum -a 256 "$meta" | awk '{print $1}')
  before_report=$(shasum -a 256 "$report" | awk '{print $1}')
  before_custody=$(shasum -a 256 "$custody" | awk '{print $1}')
  for rc in 1 2; do
    if run_teardown "$home" "$id" > "$home/teardown-$rc.out" 2> "$home/teardown-$rc.err"; then
      fail "$backend teardown accepted a replacement answer for an archived unresolved cycle"
    fi
  done
  [ "$(shasum -a 256 "$meta" | awk '{print $1}')" = "$before_meta" ] \
    || fail "$backend refused teardown mutated captain attestation metadata"
  [ "$(shasum -a 256 "$report" | awk '{print $1}')" = "$before_report" ] \
    || fail "$backend refused teardown mutated the scout report"
  [ "$(shasum -a 256 "$custody" | awk '{print $1}')" = "$before_custody" ] \
    || fail "$backend refused teardown removed worktree custody"
  assert_no_grep 'return ' "$home/treehouse.log" \
    "$backend refused teardown returned the worktree"
  assert_no_grep 'kill-window' "$home/tmux.log" \
    "$backend refused teardown removed the endpoint"

  cp "$meta" "$meta.valid"
  awk '!/^decision_call_cycles=/' "$meta.valid" > "$meta"
  if run_captain "$home" verify "$id" > "$home/missing.out" 2> "$home/missing.err"; then
    fail "$backend verification accepted missing cycle inventory"
  fi
  cp "$meta.valid" "$meta"
  sed 's/^decision_call_cycles=.*/decision_call_cycles=not-json/' "$meta.valid" > "$meta"
  if run_captain "$home" verify "$id" > "$home/corrupt.out" 2> "$home/corrupt.err"; then
    fail "$backend verification accepted corrupt cycle inventory"
  fi
  cp "$meta.valid" "$meta"
  bad_calls=$(printf '%s\n' "$saved_calls" | jq -c --arg id "$call" \
    '. + [{id:$id,cycle:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}]')
  awk '!/^decision_call_cycles=/' "$meta.valid" > "$meta"
  printf 'decision_call_cycles=%s\n' "$bad_calls" >> "$meta"
  if run_captain "$home" verify "$id" > "$home/ambiguous.out" 2> "$home/ambiguous.err"; then
    fail "$backend verification accepted an unprovable additional cycle identity"
  fi
}

test_teardown_verifies_persisted_call_cycles() {
  run_reused_cycle_teardown_refusal tasks
  run_reused_cycle_teardown_refusal manual
  run_cycle_bound_teardown_control tasks held
  run_cycle_bound_teardown_control manual answered
  pass "scout teardown verifies exact persisted captain-call cycles"
}

test_active_rehold_preserves_prior_cycle_evidence() {
  local home id call cycle_a cycle_b calls replay_calls unknown before
  home=$(make_home active-rehold-cycle)
  id=sample-active-rehold-origin
  call=sample-active-rehold-call
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "$id" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Active re-hold cycle evidence\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$call" --title "$call" \
    --reason "captain first cycle pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" "$call" >/dev/null
  cycle_a=$(sed -n 's/^decision_call_cycles=//p' "$home/state/$id.meta" \
    | tail -1 | jq -r --arg id "$call" '.[] | select(.id == $id) | .cycle')
  [ -n "$cycle_a" ] || fail "first active cycle was not persisted"
  printf 'Captain released the first authenticated cycle.\n' > "$home/first-answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/first-answer.txt" --release >/dev/null
  run_captain "$home" hold "$call" --reason "captain second cycle pending" >/dev/null
  cycle_b=$(run_captain "$home" normalize-inventory-cycles "$id" "$call" \
    | jq -r --arg id "$call" '.[] | select(.id == $id) | .cycle')
  [ -n "$cycle_b" ] && [ "$cycle_b" != "$cycle_a" ] \
    || fail "re-hold did not create a distinct current cycle"

  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion replay lost the resolved historical cycle"
  calls=$(sed -n 's/^decision_call_cycles=//p' "$home/state/$id.meta" | tail -1)
  printf '%s\n' "$calls" | jq -e --arg id "$call" --arg a "$cycle_a" --arg b "$cycle_b" '
    sort_by(.id,.cycle) == ([{id:$id,cycle:$a},{id:$id,cycle:$b}] | sort_by(.id,.cycle))
  ' >/dev/null || fail "completion replay did not retain both authenticated cycles"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "verification could not validate historical A and current held B independently"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "identical completion replay was not idempotent"
  replay_calls=$(sed -n 's/^decision_call_cycles=//p' "$home/state/$id.meta" | tail -1)
  [ "$replay_calls" = "$calls" ] || fail "completion replay changed the authenticated cycle inventory"

  if run_captain "$home" terminal-ready "$id" "$call:$cycle_b" \
    > "$home/held-ready.out" 2> "$home/held-ready.err"; then
    fail "terminal readiness treated current held cycle B as answered"
  fi
  unknown=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  if run_captain "$home" terminal-ready "$id" "$call:$unknown" \
    > "$home/unknown-ready.out" 2> "$home/unknown-ready.err"; then
    fail "terminal readiness accepted an unknown historical cycle"
  fi
  cp "$home/state/$id.meta" "$home/state/$id.meta.valid"
  before=$(shasum -a 256 "$home/state/$id.meta.valid" | awk '{print $1}')
  printf '%s\n' "$calls" | jq -c --arg id "$call" --arg cycle "$unknown" \
    '. + [{id:$id,cycle:$cycle}]' > "$home/calls.invalid"
  awk '!/^decision_call_cycles=/' "$home/state/$id.meta.valid" > "$home/state/$id.meta"
  printf 'decision_call_cycles=%s\n' "$(cat "$home/calls.invalid")" >> "$home/state/$id.meta"
  if run_captain "$home" verify "$id" > "$home/unknown-verify.out" 2> "$home/unknown-verify.err"; then
    fail "verification accepted an unknown persisted cycle"
  fi
  cp "$home/state/$id.meta.valid" "$home/state/$id.meta"
  [ "$(shasum -a 256 "$home/state/$id.meta" | awk '{print $1}')" = "$before" ] \
    || fail "unknown-cycle refusal did not preserve the valid attestation"

  printf 'Captain answered the current second cycle.\n' > "$home/second-answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/second-answer.txt" >/dev/null
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "completion replay rejected the genuine second-cycle answer"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "verification rejected the resolved historical and current cycles"
  run_captain "$home" terminal-ready "$id" "$call:$cycle_b" >/dev/null \
    || fail "terminal readiness rejected the genuine current-cycle answer"
  pass "active re-holds retain exact historical and current cycle evidence"
}

test_resolution_evidence_is_authenticated_before_lifecycle_progress() {
  local home id call cycle variant meta report before_meta before_report
  home=$(make_home resolution-authentication)
  id=sample-resolution-auth-origin
  call=sample-resolution-auth-call
  meta="$home/state/$id.meta"
  report="$home/data/$id/report.md"
  mkdir -p "$home/data/$id" "$home/projects/missing-$id"
  tasks_in "$home" add "$id" "$id" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Authenticated resolution evidence\n' > "$report"
  printf 'custody retained\n' > "$home/projects/missing-$id/custody.marker"
  run_captain "$home" hold "$call" --title "$call" \
    --reason "captain exact answer pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" "$call" >/dev/null
  cycle=$(sed -n 's/^decision_call_cycles=//p' "$meta" \
    | tail -1 | jq -r --arg id "$call" '.[] | select(.id == $id) | .cycle')
  printf 'Captain authenticated this exact answer.\n' > "$home/answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null
  tasks_in "$home" show "$call" --full | sed -n 's/^  body: //p' \
    | jq -r . > "$home/resolution.valid"

  run_captain "$home" verify "$id" >/dev/null \
    || fail "valid captain resolution failed durable verification"
  run_captain "$home" terminal-ready "$id" "$call:$cycle" >/dev/null \
    || fail "valid captain resolution failed terminal readiness"

  for variant in changed-answer unsupported-mode malformed-schema; do
    case "$variant" in
      changed-answer)
        sed 's/Captain authenticated this exact answer\./Captain text was altered after recording./' \
          "$home/resolution.valid" > "$home/resolution.invalid"
        ;;
      unsupported-mode)
        sed 's/^Resolution mode: answered$/Resolution mode: fabricated/' \
          "$home/resolution.valid" > "$home/resolution.invalid"
        ;;
      malformed-schema)
        sed '/^Decision digest:/d' "$home/resolution.valid" > "$home/resolution.invalid"
        ;;
    esac
    cmp -s "$home/resolution.valid" "$home/resolution.invalid" \
      && fail "$variant fixture did not alter the serialized resolution"
    tasks_in "$home" update "$call" --body-file "$home/resolution.invalid" --archive-body >/dev/null
    before_meta=$(shasum -a 256 "$meta" | awk '{print $1}')
    before_report=$(shasum -a 256 "$report" | awk '{print $1}')
    if run_captain "$home" verify "$id" \
      > "$home/$variant.verify.out" 2> "$home/$variant.verify.err"; then
      fail "$variant captain resolution passed durable verification"
    fi
    if run_captain "$home" terminal-ready "$id" "$call:$cycle" \
      > "$home/$variant.ready.out" 2> "$home/$variant.ready.err"; then
      fail "$variant captain resolution passed terminal readiness"
    fi
    if run_teardown "$home" "$id" \
      > "$home/$variant.teardown.out" 2> "$home/$variant.teardown.err"; then
      fail "$variant captain resolution authorized scout teardown"
    fi
    [ "$(shasum -a 256 "$meta" | awk '{print $1}')" = "$before_meta" ] \
      || fail "$variant refusal mutated captain attestation metadata"
    [ "$(shasum -a 256 "$report" | awk '{print $1}')" = "$before_report" ] \
      || fail "$variant refusal mutated the scout report"
    assert_present "$home/projects/missing-$id/custody.marker" \
      "$variant refusal removed worktree custody"
    [ ! -e "$home/treehouse.log" ] || assert_no_grep 'return ' "$home/treehouse.log" \
      "$variant refusal returned the worktree"
    [ ! -e "$home/tmux.log" ] || assert_no_grep 'kill-window' "$home/tmux.log" \
      "$variant refusal removed the endpoint"
    tasks_in "$home" update "$call" --body-file "$home/resolution.valid" --archive-body >/dev/null
  done

  run_captain "$home" verify "$id" >/dev/null \
    || fail "restored authentic resolution failed durable verification"
  run_captain "$home" terminal-ready "$id" "$call:$cycle" >/dev/null \
    || fail "restored authentic resolution failed terminal readiness"
  rm -f "$home/projects/missing-$id/custody.marker"
  rmdir "$home/projects/missing-$id"
  run_teardown "$home" "$id" >/dev/null \
    || fail "restored authentic resolution failed the valid teardown control"
  pass "captain resolution evidence is authenticated before lifecycle progress"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    sig=$(fm_wake_signal_sig "$3") || exit 1
    printf "%s" "$sig" > "$(fm_wake_signal_seen_path "$2" "$3")"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  grep -F 'captain-held [key=route]: tracked by sample-route-call' "$home/state/$id.status" >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out
  home=$(make_home release-work)
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body 'The widget plan body. Literal escape: \n. Unicode: café.' >/dev/null \
    || fail "could not create the held work item"
  run_captain "$home" hold sample-widget --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Go: ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Go: ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  run_captain "$home" hold sample-widget --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Go: ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

test_answer_identity_is_hold_cycle_scoped() {
  local home show records mismatch
  home=$(make_home answer-cycle)
  tasks_in "$home" add sample-cycle-work "Ship cycle-aware sample work" \
    --kind ship --repo sample --body 'Cycle-aware work body.' >/dev/null \
    || fail "could not create the cycle-aware held work"
  printf 'spawn_gen=sample-cycle-one\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-cycle-work.meta"
  run_captain "$home" hold sample-cycle-work --reason "captain cycle answer pending" >/dev/null \
    || fail "could not establish the first captain hold cycle"
  printf 'Captain repeats this exact release answer.\n' > "$home/cycle-answer.txt"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ -f "$FM_HOME/fail-unhold.once" ]; then
  rm -f -- "$FM_HOME/fail-unhold.once"
  exit 42
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  : > "$home/fail-unhold.once"
  if run_captain "$home" answer sample-cycle-work \
    --decision-file "$home/cycle-answer.txt" --release \
    > "$home/interrupted.out" 2> "$home/interrupted.err"; then
    fail "the interrupted release fixture did not interrupt after recording"
  fi
  show=$(tasks_in "$home" show sample-cycle-work --full)
  assert_contains "$show" 'held: yes' "the interrupted release lost the active hold"
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "the interrupted release did not write exactly one resolution"
  run_terminal "$home" merged sample-cycle-work https://github.com/o/r/pull/1
  run_captain "$home" answer sample-cycle-work \
    --decision-file "$home/cycle-answer.txt" --release >/dev/null \
    || fail "same-cycle release retry did not accept its first authenticated receipt"
  show=$(tasks_in "$home" show sample-cycle-work --full)
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "same-cycle retry duplicated the resolution record"

  printf 'spawn_gen=sample-cycle-two\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-cycle-work.meta"
  run_captain "$home" hold sample-cycle-work --reason "captain later cycle answer pending" >/dev/null \
    || fail "could not establish the later captain hold cycle"
  run_captain "$home" answer sample-cycle-work \
    --decision-file "$home/cycle-answer.txt" --release >/dev/null \
    || fail "the repeated answer was not recorded for the later hold cycle"
  show=$(tasks_in "$home" show sample-cycle-work --full)
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 2 ] || fail "the later hold cycle reused the historical resolution"
  run_captain "$home" answer sample-cycle-work \
    --decision-file "$home/cycle-answer.txt" --release >/dev/null \
    || fail "the later same-cycle replay was not idempotent"
  show=$(tasks_in "$home" show sample-cycle-work --full)
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 2 ] || fail "the later same-cycle replay duplicated its resolution"
  assert_contains "$show" 'state: queued' "the later release completed resumed work"
  assert_contains "$show" 'held: no' "the later release retained its hold"

  mismatch=sample-cycle-mismatch
  tasks_in "$home" add "$mismatch" "Reject a mismatched same-cycle receipt" \
    --kind ship --repo sample --start >/dev/null
  printf 'spawn_gen=%s-one\nkind=ship\nmode=no-mistakes\n' "$mismatch" \
    > "$home/state/$mismatch.meta"
  run_captain "$home" hold "$mismatch" --reason "captain mismatch answer pending" >/dev/null
  printf 'Captain approved the original incarnation.\n' > "$home/mismatch-answer.txt"
  : > "$home/fail-unhold.once"
  if run_captain "$home" answer "$mismatch" \
    --decision-file "$home/mismatch-answer.txt" --release \
    > "$home/mismatch-interrupted.out" 2> "$home/mismatch-interrupted.err"; then
    fail "the mismatched-incarnation fixture did not interrupt after recording"
  fi
  printf 'spawn_gen=%s-two\nkind=ship\nmode=no-mistakes\n' "$mismatch" \
    > "$home/state/$mismatch.meta"
  run_terminal "$home" merged "$mismatch" https://github.com/o/r/pull/2
  if run_captain "$home" answer "$mismatch" \
    --decision-file "$home/mismatch-answer.txt" --release \
    > "$home/mismatch-retry.out" 2> "$home/mismatch-retry.err"; then
    fail "a same-cycle release borrowed another terminal incarnation"
  fi
  printf 'Captain gave a different same-cycle answer.\n' > "$home/mismatch-drift.txt"
  if run_captain "$home" answer "$mismatch" \
    --decision-file "$home/mismatch-drift.txt" --release \
    > "$home/mismatch-drift.out" 2> "$home/mismatch-drift.err"; then
    fail "a different same-cycle answer replaced the recorded decision"
  fi
  show=$(tasks_in "$home" show "$mismatch" --full)
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "mismatched same-cycle retries duplicated the resolution record"
  assert_contains "$show" 'held: yes' "mismatched same-cycle retries released the held task"
  pass "captain answer identity is scoped to one durable hold cycle"
}

test_release_uses_existing_terminal_evidence_only() {
  local home id show key record replacement_id replacement_release_key replacement_key replacement_record
  local later_id old_key new_key
  home=$(make_home release-terminal-evidence)
  id=sample-preterminal-release
  tasks_in "$home" add "$id" "Ship after a live captain gate" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create the preterminal release fixture"
  printf 'spawn_gen=%s\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/1\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$id" > "$home/state/$id.meta"
  run_captain "$home" hold "$id" --reason "captain live release pending" >/dev/null \
    || fail "could not hold the live preterminal worker"
  printf 'Captain released the live worker to finish.\n' > "$home/preterminal-answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/preterminal-answer.txt" --release >/dev/null \
    || fail "could not release the live worker before its first receipt"
  run_captain "$home" answer "$id" --decision-file "$home/preterminal-answer.txt" --release >/dev/null \
    || fail "preterminal release replay was not idempotent"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" 'Terminal receipt: none' \
    "preterminal release did not record the absence of prior terminal evidence"
  assert_contains "$show" 'Terminal incarnation: ' \
    "preterminal release did not bind its future receipt identity"
  if run_terminal "$home" receipt-key "$id" > "$home/preterminal-key.out" 2> "$home/preterminal-key.err"; then
    fail "terminal owner reported a receipt before the first terminal event"
  fi
  run_terminal "$home" merged "$id" https://github.com/o/r/pull/1
  key=$(run_terminal "$home" receipt-key "$id") \
    || fail "terminal owner did not authenticate the first receipt"
  run_terminal "$home" retired "$id" normal
  run_terminal "$home" reconcile
  run_terminal "$home" reconcile
  record="$home/state/terminal-delivery/$key.json"
  jq -e '.backlog == true and .refill == true and .reviewed != true' "$record" >/dev/null \
    || fail "first same-incarnation receipt did not advance the preterminal release"
  assert_contains "$(tasks_in "$home" show "$id" --full)" 'state: done' \
    "preterminal release did not complete through terminal reconciliation"
  run_terminal "$home" refill-reviewed "$key"
  run_terminal "$home" refill-reviewed "$key"
  jq -e '.backlog == true and .refill == true and .reviewed == true' "$record" >/dev/null \
    || fail "preterminal release refill acknowledgement did not replay safely"

  replacement_id=sample-preterminal-replacement
  tasks_in "$home" add "$replacement_id" "Reject another incarnation after a live captain gate" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create the preterminal replacement fixture"
  printf 'spawn_gen=%s-one\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/3\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$replacement_id" > "$home/state/$replacement_id.meta"
  run_captain "$home" hold "$replacement_id" --reason "captain replacement release pending" >/dev/null \
    || fail "could not hold the preterminal replacement fixture"
  printf 'Captain released only this live incarnation.\n' > "$home/replacement-answer.txt"
  run_captain "$home" answer "$replacement_id" \
    --decision-file "$home/replacement-answer.txt" --release >/dev/null \
    || fail "could not release the original preterminal incarnation"
  replacement_release_key=$(run_terminal "$home" current-incarnation "$replacement_id") \
    || fail "terminal owner did not expose the released future incarnation"
  printf 'spawn_gen=%s-two\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/3\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$replacement_id" > "$home/state/$replacement_id.meta"
  run_terminal "$home" merged "$replacement_id" https://github.com/o/r/pull/3
  replacement_key=$(run_terminal "$home" receipt-key "$replacement_id") \
    || fail "terminal owner did not authenticate the replacement receipt"
  [ "$replacement_key" != "$replacement_release_key" ] \
    || fail "replacement fixture reused the released incarnation identity"
  run_terminal "$home" retired "$replacement_id" normal
  run_terminal "$home" reconcile
  run_terminal "$home" reconcile
  replacement_record="$home/state/terminal-delivery/$replacement_key.json"
  jq -e '.backlog != true and .refill != true' "$replacement_record" >/dev/null \
    || fail "replacement incarnation borrowed a preterminal captain release"
  assert_contains "$(tasks_in "$home" show "$replacement_id" --full)" 'state: in_flight' \
    "replacement incarnation advanced backlog using another incarnation's release"

  later_id=sample-postreceipt-release
  tasks_in "$home" add "$later_id" "Require a successor after terminal evidence" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create the post-receipt release fixture"
  printf 'spawn_gen=%s-one\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/2\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$later_id" > "$home/state/$later_id.meta"
  run_terminal "$home" merged "$later_id" https://github.com/o/r/pull/2
  old_key=$(run_terminal "$home" receipt-key "$later_id") \
    || fail "terminal owner did not expose the real pre-release receipt"
  run_captain "$home" hold "$later_id" --reason "captain post-receipt release pending" >/dev/null \
    || fail "could not hold the worker after terminal evidence"
  printf 'Captain required this terminal worker to resume.\n' > "$home/postreceipt-answer.txt"
  run_captain "$home" answer "$later_id" --decision-file "$home/postreceipt-answer.txt" --release >/dev/null \
    || fail "could not release the worker after terminal evidence"
  run_captain "$home" answer "$later_id" --decision-file "$home/postreceipt-answer.txt" --release >/dev/null \
    || fail "post-receipt release replay was not idempotent"
  show=$(tasks_in "$home" show "$later_id" --full)
  assert_contains "$show" "Terminal receipt: $old_key" \
    "release after terminal evidence lost its exact receipt identity"
  run_terminal "$home" retired "$later_id" normal
  run_terminal "$home" reconcile
  run_terminal "$home" reconcile
  jq -e '.backlog != true and .refill != true' \
    "$home/state/terminal-delivery/$old_key.json" >/dev/null \
    || fail "same-receipt stale evidence advanced a post-terminal release"
  assert_contains "$(tasks_in "$home" show "$later_id" --full)" 'state: in_flight' \
    "same-receipt stale evidence completed the resumed worker"

  printf 'spawn_gen=%s-two\nkind=ship\nmode=no-mistakes\npr=https://github.com/o/r/pull/2\ndecisions_reviewed=1\ndecision_keys=\n' \
    "$later_id" > "$home/state/$later_id.meta"
  run_terminal "$home" merged "$later_id" https://github.com/o/r/pull/2
  new_key=$(run_terminal "$home" receipt-key "$later_id") \
    || fail "terminal owner did not authenticate the successor receipt"
  [ "$new_key" != "$old_key" ] || fail "successor terminal incarnation reused stale receipt identity"
  run_terminal "$home" retired "$later_id" normal
  run_terminal "$home" reconcile
  run_terminal "$home" reconcile
  jq -e '.backlog == true and .refill == true' \
    "$home/state/terminal-delivery/$new_key.json" >/dev/null \
    || fail "verified successor receipt did not advance the released worker"
  pass "captain release requires a successor only after real terminal evidence"
}

test_answer_markers_cannot_replace_hold_cycle() {
  local home id show records forged_cycle
  home=$(make_home marker-shaped-answer)
  id=sample-marker-shaped-answer
  forged_cycle=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
  tasks_in "$home" add "$id" "Preserve marker-shaped captain words" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create the marker-shaped answer fixture"
  printf 'spawn_gen=%s-one\nkind=ship\nmode=no-mistakes\n' "$id" > "$home/state/$id.meta"
  run_captain "$home" hold "$id" --reason "captain marker-shaped answer pending" >/dev/null \
    || fail "could not establish the genuine hold cycle"
  cat > "$home/marker-answer.txt" <<EOF
Captain quoted this multi-line example and then approved the work:
Captain hold opened by fm-captain-hold.
Hold cycle: $forged_cycle
Captain hold marker end.

Keep the quoted marker exactly as written.
EOF
  run_captain "$home" answer "$id" --decision-file "$home/marker-answer.txt" --release >/dev/null \
    || fail "marker-shaped captain text replaced the genuine hold cycle"
  run_captain "$home" answer "$id" --decision-file "$home/marker-answer.txt" --release >/dev/null \
    || fail "marker-shaped answer retry did not use the genuine hold cycle"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "Hold cycle: $forged_cycle" \
    "marker-shaped captain words were not preserved exactly"
  assert_contains "$show" 'held: no' "marker-shaped answer left the work held"
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "marker-shaped answer retry duplicated its resolution"

  printf 'spawn_gen=%s-two\nkind=ship\nmode=no-mistakes\n' "$id" > "$home/state/$id.meta"
  run_captain "$home" hold "$id" --reason "captain ordinary re-hold answer pending" >/dev/null \
    || fail "could not establish a genuine later hold cycle"
  printf 'Captain approved the ordinary later release.\n' > "$home/ordinary-answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/ordinary-answer.txt" --release >/dev/null \
    || fail "ordinary answer after marker-shaped text did not use the later hold cycle"
  run_captain "$home" answer "$id" --decision-file "$home/ordinary-answer.txt" --release >/dev/null \
    || fail "ordinary later answer retry was not idempotent"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" 'Captain approved the ordinary later release.' \
    "ordinary later answer was not preserved"
  assert_contains "$show" 'Keep the quoted marker exactly as written.' \
    "genuine re-hold erased the earlier captain words"
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$records" = 2 ] || fail "genuine re-hold did not retain one resolution per cycle"
  pass "captain text cannot spoof structurally owned hold-cycle identity"
}

test_rehold_cycle_is_interruption_safe() {
  local home show initial_cycle interrupted_cycle active_cycle replay_cycle records rc
  local first_show first_cycle first_replay first_records
  home=$(make_home rehold-interruption)
  tasks_in "$home" add sample-interrupted-work "Ship interruption-safe work" \
    --kind ship --repo sample --body 'Interruption-safe work body.' >/dev/null \
    || fail "could not create the interruption-safe work"
  printf 'spawn_gen=interruption-one\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-interrupted-work.meta"
  run_captain "$home" hold sample-interrupted-work --reason "captain first answer pending" >/dev/null \
    || fail "could not establish the initial hold cycle"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  initial_cycle=$(printf '%s\n' "$show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  [ -n "$initial_cycle" ] || fail "the initial hold did not persist its cycle"
  printf 'Captain approved the initial release.\n' > "$home/initial-answer.txt"
  run_captain "$home" answer sample-interrupted-work \
    --decision-file "$home/initial-answer.txt" --release >/dev/null \
    || fail "could not release the initial hold"

  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/tasks-axi.log"
if [ "${1:-}" = update ] && [ "${2:-}" != --help ] \
   && [ -f "$FM_HOME/fail-update-after.once" ]; then
  rm -f -- "$FM_HOME/fail-update-after.once"
  "$REAL_TASKS_AXI" "$@" || exit $?
  exit 42
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ] \
   && [ -f "$FM_HOME/fail-hold-after.once" ]; then
  rm -f -- "$FM_HOME/fail-hold-after.once"
  "$REAL_TASKS_AXI" "$@" || exit $?
  exit 43
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  : > "$home/tasks-axi.log"

  tasks_in "$home" add sample-first-interrupted-work "Ship first-cycle interruption-safe work" \
    --kind ship --repo sample --body 'First-cycle work body.' >/dev/null \
    || fail "could not create the first-cycle interruption fixture"
  printf 'spawn_gen=first-interruption\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-first-interrupted-work.meta"
  : > "$home/fail-update-after.once"
  rc=0
  run_captain "$home" hold sample-first-interrupted-work --reason "captain first-cycle answer pending" \
    > "$home/first-update-interruption.out" 2> "$home/first-update-interruption.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the first hold-cycle persistence interruption did not stop the hold command"
  first_show=$(tasks_in "$home" show sample-first-interrupted-work --full)
  assert_contains "$first_show" 'held: no' "the first-cycle interruption applied an unconfirmed hold"
  first_cycle=$(printf '%s\n' "$first_show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  [ -n "$first_cycle" ] || fail "the first-cycle interruption did not preserve its intent"
  if run_captain "$home" terminal-ready sample-first-interrupted-work \
    --receipt first-interrupted > "$home/first-ready.out" 2> "$home/first-ready.err"; then
    fail "an unmatched first hold-cycle intent authorized terminal readiness"
  fi
  run_captain "$home" hold sample-first-interrupted-work --reason "captain first-cycle answer pending" >/dev/null \
    || fail "the interrupted first hold-cycle did not retry safely"
  first_show=$(tasks_in "$home" show sample-first-interrupted-work --full)
  first_replay=$(printf '%s\n' "$first_show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  [ -n "$first_replay" ] && [ "$first_replay" != "$first_cycle" ] \
    || fail "the inactive first hold retry reused its unmatched cycle intent"
  first_records=$(printf '%s\n' "$first_show" | grep -o 'Captain hold opened by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ "$first_records" = 2 ] || fail "the first hold retry did not preserve distinct interruption history"
  printf 'Captain approved the first interrupted task.\n' > "$home/first-answer.txt"
  run_captain "$home" answer sample-first-interrupted-work \
    --decision-file "$home/first-answer.txt" >/dev/null \
    || fail "the genuine first-cycle answer was not accepted"
  run_captain "$home" terminal-ready sample-first-interrupted-work \
    --receipt first-answered >/dev/null \
    || fail "the genuine first-cycle answer did not authorize readiness"
  run_captain "$home" answer sample-first-interrupted-work \
    --decision-file "$home/first-answer.txt" >/dev/null \
    || fail "the genuine first-cycle answer replay failed"
  first_show=$(tasks_in "$home" show sample-first-interrupted-work --full)
  [ "$(printf '%s\n' "$first_show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the genuine first-cycle answer replay duplicated its resolution"

  printf 'spawn_gen=interruption-two\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-interrupted-work.meta"
  : > "$home/fail-update-after.once"
  rc=0
  run_captain "$home" hold sample-interrupted-work --reason "captain second answer pending" \
    > "$home/update-interruption.out" 2> "$home/update-interruption.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the cycle-persistence interruption did not stop the hold command"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  assert_contains "$show" 'held: no' "cycle persistence failure left the task actively held"
  interrupted_cycle=$(printf '%s\n' "$show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  [ -n "$interrupted_cycle" ] && [ "$interrupted_cycle" != "$initial_cycle" ] \
    || fail "the interrupted cycle persistence did not leave a distinct durable intent"
  if run_captain "$home" terminal-ready sample-interrupted-work \
    --receipt interrupted-update > "$home/update-ready.out" 2> "$home/update-ready.err"; then
    fail "a persisted cycle without its hold reused the historical answer"
  fi
  run_captain "$home" hold sample-interrupted-work --reason "captain second answer pending" >/dev/null \
    || fail "the cycle-persistence interruption did not retry safely"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  assert_contains "$show" 'held: yes' "the cycle-persistence retry did not establish the hold"
  if run_captain "$home" terminal-ready sample-interrupted-work \
    --receipt retried-update > "$home/retried-ready.out" 2> "$home/retried-ready.err"; then
    fail "the retried hold reused the historical answer"
  fi
  printf 'Captain approved the second release.\n' > "$home/second-answer.txt"
  run_captain "$home" answer sample-interrupted-work \
    --decision-file "$home/second-answer.txt" --release >/dev/null \
    || fail "could not release the retried hold"

  printf 'spawn_gen=interruption-three\nkind=ship\nmode=no-mistakes\n' \
    > "$home/state/sample-interrupted-work.meta"
  : > "$home/fail-hold-after.once"
  rc=0
  run_captain "$home" hold sample-interrupted-work --reason "captain final answer pending" \
    > "$home/hold-interruption.out" 2> "$home/hold-interruption.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "the hold-application interruption did not stop the hold command"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  assert_contains "$show" 'held: yes' "the hold-application interruption fixture did not apply the hold"
  active_cycle=$(printf '%s\n' "$show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  records=$(printf '%s\n' "$show" | grep -o 'Captain hold opened by fm-captain-hold\.' | wc -l | tr -d ' ')
  [ -n "$active_cycle" ] || fail "the interrupted active hold had no durable cycle"
  if run_captain "$home" terminal-ready sample-interrupted-work \
    --receipt interrupted-hold > "$home/hold-ready.out" 2> "$home/hold-ready.err"; then
    fail "the interrupted active hold reused the historical answer"
  fi
  run_captain "$home" hold sample-interrupted-work --reason "captain final answer pending" >/dev/null \
    || fail "the hold-application interruption did not retry safely"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  replay_cycle=$(printf '%s\n' "$show" | grep -Eo 'Hold cycle: [0-9a-f]{64}' | head -1 | awk '{print $3}')
  [ "$replay_cycle" = "$active_cycle" ] \
    || fail "an active same-cycle hold retry minted a different cycle"
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold opened by fm-captain-hold\.' | wc -l | tr -d ' ')" = "$records" ] \
    || fail "an active same-cycle hold retry duplicated its cycle record"

  tasks_in "$home" 'done' sample-interrupted-work >/dev/null \
    || fail "could not reproduce the out-of-band completion"
  if run_captain "$home" terminal-ready sample-interrupted-work \
    --receipt out-of-band > "$home/out-of-band-ready.out" 2> "$home/out-of-band-ready.err"; then
    fail "out-of-band completion reused a historical captain answer"
  fi
  printf 'Captain approved the final completed state.\n' > "$home/final-answer.txt"
  run_captain "$home" answer sample-interrupted-work \
    --decision-file "$home/final-answer.txt" >/dev/null \
    || fail "the genuine current answer was not accepted"
  run_captain "$home" terminal-ready sample-interrupted-work --receipt current-answer >/dev/null \
    || fail "the genuine current answer did not authorize terminal readiness"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  records=$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')
  run_captain "$home" answer sample-interrupted-work \
    --decision-file "$home/final-answer.txt" >/dev/null \
    || fail "the current answer replay was not accepted"
  show=$(tasks_in "$home" show sample-interrupted-work --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Resolution recorded by fm-captain-hold\.' | wc -l | tr -d ' ')" = "$records" ] \
    || fail "the current answer replay duplicated its resolution"
  pass "re-hold cycles survive persistence and application interruptions"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    [.backlog.records[] | select(.id == "sample-later-call")][0].captain_actionable == true
  ' >/dev/null || fail "a due deferral did not resurface as captain-actionable"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

test_terminal_resolution_mode_is_whitelisted() {
  local home id call pristine
  home=$(make_home resolution-mode-validation)
  id=sample-resolution-review
  call=sample-resolution-call
  tasks_in "$home" add "$id" "Review resolution validation" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the resolution validation origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  run_captain "$home" hold "$call" --title "Choose the resolution path" \
    --reason "captain resolution choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not create the resolution validation call"
  run_captain "$home" complete "$id" "$call" >/dev/null \
    || fail "could not attest the resolution validation inventory"
  printf 'Captain selected the supported path.\n' > "$home/answer.txt"
  run_captain "$home" answer "$call" --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not record the supported answered mode"
  run_captain "$home" terminal-ready "$id" "$call" >/dev/null \
    || fail "the supported answered mode did not authorize readiness"

  pristine="$home/backlog-pristine.md"
  cp "$home/data/backlog.md" "$pristine"
  sed -i.bak 's/Resolution mode: answered/Resolution mode: garbage/' "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.bak"
  if run_captain "$home" terminal-ready "$id" "$call" \
    > "$home/garbage.out" 2> "$home/garbage.err"; then
    fail "an unknown resolution mode authorized terminal readiness"
  fi

  cp "$pristine" "$home/data/backlog.md"
  sed -i.bak '/Resolution mode: answered/d' "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.bak"
  if run_captain "$home" terminal-ready "$id" "$call" \
    > "$home/missing.out" 2> "$home/missing.err"; then
    fail "a missing resolution mode authorized terminal readiness"
  fi
  cp "$pristine" "$home/data/backlog.md"
  run_captain "$home" terminal-ready "$id" "$call" >/dev/null \
    || fail "restoring the supported answered mode did not restore readiness"
  pass "terminal readiness accepts only supported captain resolution modes"
}

# A post-teardown visual review still uses the shared hold owner, while the
# completed receipt keeps its authenticated captain inventory immutable.
test_visual_review_uses_shared_completion_owner() {
  local home id json receipt before out
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null
  receipt=$(jq -r --arg id "$id" \
    'select(.id==$id and ((.superseded_by // "") == "")) | .key' \
    "$home/state/terminal-delivery/"*.json)
  before=$(jq -cS . "$home/state/terminal-delivery/$receipt.json")

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  if out=$(run_captain "$home" complete "$id" --receipt "$receipt" sample-layout-call 2>&1); then
    fail "post-teardown visual review changed a completed receipt's captain inventory"
  fi
  assert_contains "$out" 'keep its captain inventory unchanged' \
    "post-teardown visual review did not name the immutable receipt boundary"
  [ "$before" = "$(jq -cS . "$home/state/terminal-delivery/$receipt.json")" ] \
    || fail "rejected post-teardown review mutated the completed receipt"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review uses the shared hold owner without reopening completed receipt inventory"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_status_requires_explicit_resolution_or_transfer() {
  local home id before after resolved
  home=$(make_home terminal-decision-attestation)
  id=sample-terminal-transfer-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-prior-call --title "Choose the prior route" \
    --reason "prior captain route pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" sample-prior-call >/dev/null \
    || fail "could not establish the prior reviewed inventory"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete\n' \
    > "$home/state/$id.status"
  before=$(shasum -a 256 "$home/state/$id.meta" | awk '{print $1}')
  if run_captain "$home" complete "$id" --none \
    > "$home/done-none.out" 2> "$home/done-none.err"; then
    fail "a terminal done line authorized an incomplete historical inventory"
  fi
  after=$(shasum -a 256 "$home/state/$id.meta" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "refused terminal attestation mutated the prior inventory"
  if run_captain "$home" verify "$id" > "$home/done-verify.out" 2> "$home/done-verify.err"; then
    fail "verification ignored the raw unresolved decision after done"
  fi
  run_captain "$home" hold sample-current-call --title "Choose the current route" \
    --reason "current captain route pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" complete "$id" sample-current-call >/dev/null \
    || fail "terminal done decision could not transfer to current reviewed inventory"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "transferred terminal done decision did not verify"
  assert_grep 'decision_keys=sample-current-call,sample-prior-call' "$home/state/$id.meta" \
    "current terminal transfer replaced the prior inventory"

  resolved=sample-terminal-resolved-review
  mkdir -p "$home/data/$resolved"
  tasks_in "$home" add "$resolved" "Review a resolved terminal finding" \
    --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$resolved"
  printf 'needs-decision [key=route]: choose route A or route B\nfailed: review stopped\n' \
    > "$home/state/$resolved.status"
  if run_captain "$home" complete "$resolved" --none \
    > "$home/failed-none.out" 2> "$home/failed-none.err"; then
    fail "a terminal failed line authorized an unresolved empty inventory"
  fi
  printf 'resolved [key=route]: captain chose route A\n' >> "$home/state/$resolved.status"
  run_captain "$home" complete "$resolved" --none >/dev/null \
    || fail "an explicit keyed resolution did not authorize empty inventory"
  run_captain "$home" verify "$resolved" >/dev/null \
    || fail "explicitly resolved terminal failed decision did not verify"
  pass "terminal status cannot fabricate an empty or incomplete captain attestation"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[6]{uid,prompt,selector,tag,text}:
  "2","Membership: gold-only\n\nContext data:\n{\n  \"question\": \"sample-membership-call\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"sample-headline-call\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"question\": \"sample-gated-work\",\n  \"answer\": \"go\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"question\": \"sample-nonexistent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working when authentic
# cycle identity can be recorded: composed identities through the shim, fresh
# short decision-key intake, a concrete-origin binding, and the chat fallback.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A non-empty pre-collapse attestation without cycle identity cannot be
  # rebound through mutable current task state. Fresh short-key intake resolves
  # the legacy identity once and persists the authenticated cycle.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  if run_captain "$home" verify "$id" > "$home/legacy-verify.out" 2> "$home/legacy-verify.err"; then
    fail "legacy short-key metadata without hold-cycle identity verified"
  fi
  awk '!/^decisions_reviewed=/ && !/^decision_keys=/' "$home/state/$id.meta" \
    > "$home/state/$id.meta.tmp"
  mv "$home/state/$id.meta.tmp" "$home/state/$id.meta"
  run_captain "$home" complete "$id" keep-two pick-one >/dev/null \
    || fail "fresh legacy short-key intake did not persist composed identities"
  assert_grep 'decision_call_cycles=' "$home/state/$id.meta" \
    "fresh legacy short-key intake omitted authenticated cycles"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "authenticated legacy short-key inventory did not verify"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  if run_captain "$home" terminal-ready "$id" fourth-choice \
    > "$home/legacy-ready.out" 2> "$home/legacy-ready.err"; then
    fail "a cycle-less legacy resolution authorized a terminal transition"
  fi
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "a real captain answer did not recover the pre-collapse record"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer was not recorded under a current cycle"
  show=$(tasks_in "$home" show "$id-decision-fourth-choice" --full)
  assert_contains "$show" 'Resolution recorded by fm-captain-hold.' \
    "legacy recovery did not add the current owner's resolution"
  assert_contains "$show" 'Resolution mode: repaired' \
    "legacy recovery did not identify its out-of-band close"
  assert_contains "$show" 'Resolution recorded by fm-decision-hold.' \
    "legacy recovery discarded the historical resolution"
  run_captain "$home" terminal-ready "$id" fourth-choice >/dev/null \
    || fail "the cycle-aware legacy recovery did not authorize terminal readiness"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

case "${FM_CAPTAIN_HOLD_FOCUSED_TEST:-}" in
  release-boundaries)
    test_answer_identity_is_hold_cycle_scoped
    test_release_uses_existing_terminal_evidence_only
    test_answer_markers_cannot_replace_hold_cycle
    exit 0
    ;;
  rehold-interruption)
    test_rehold_cycle_is_interruption_safe
    exit 0
    ;;
  terminal-status-attestation)
    test_terminal_status_requires_explicit_resolution_or_transfer
    exit 0
    ;;
  resolution-mode-validation)
    test_terminal_resolution_mode_is_whitelisted
    test_out_of_band_close_is_recordable
    test_release_uses_existing_terminal_evidence_only
    exit 0
    ;;
  review-recovery)
    test_rehold_cycle_is_interruption_safe
    test_visual_review_uses_shared_completion_owner
    exit 0
    ;;
  teardown-cycle-identity)
    test_teardown_verifies_persisted_call_cycles
    test_legacy_identities_keep_working
    exit 0
    ;;
  active-rehold-cycle-evidence)
    test_active_rehold_preserves_prior_cycle_evidence
    run_reused_cycle_teardown_refusal tasks
    exit 0
    ;;
  resolution-authentication)
    test_resolution_evidence_is_authenticated_before_lifecycle_progress
    test_active_rehold_preserves_prior_cycle_evidence
    exit 0
    ;;
  '') ;;
  *) fail "unknown focused captain-hold test: $FM_CAPTAIN_HOLD_FOCUSED_TEST" ;;
esac

test_uninventoried_report_decision_refuses_completion
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_answer_identity_is_hold_cycle_scoped
test_release_uses_existing_terminal_evidence_only
test_answer_markers_cannot_replace_hold_cycle
test_rehold_cycle_is_interruption_safe
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_terminal_resolution_mode_is_whitelisted
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_status_requires_explicit_resolution_or_transfer
test_secondmate_hold_stays_in_authoritative_home
test_bound_channel_answers_close_at_answer_time
test_unbound_source_closes_no_hold
test_teardown_verifies_persisted_call_cycles
test_active_rehold_preserves_prior_cycle_evidence
test_resolution_evidence_is_authenticated_before_lifecycle_progress
test_legacy_identities_keep_working
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_legitimate_holds_produce_no_divergence_signal
