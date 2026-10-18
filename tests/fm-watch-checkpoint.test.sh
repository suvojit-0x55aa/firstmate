#!/usr/bin/env bash
# Compatibility tests for the bounded foreground helper and native Codex succession.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-checkpoint)
CHECKPOINT_PID=

cleanup_checkpoint_test() {
  if [ -n "${CHECKPOINT_PID:-}" ] && kill -0 "$CHECKPOINT_PID" 2>/dev/null; then
    kill "$CHECKPOINT_PID" 2>/dev/null || true
    wait "$CHECKPOINT_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_checkpoint_test EXIT

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

test_quiet_checkpoint_exits_124_cleanly() {
  local home out err status
  home=$(make_home quiet)
  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 1 >"$out" 2>"$err" || status=$?
  expect_code 124 "$status" "quiet checkpoint exit"
  assert_contains "$(cat "$out")" "checkpoint: no actionable wake within 1s" "quiet checkpoint line missing"
  assert_absent "$home/state/.watch.lock/pid" "watch lock pid survived quiet checkpoint timeout"
  pass "quiet checkpoint exits 124 with a clean checkpoint line and no live lock"
}

test_signal_passes_through_and_exits_zero() {
  local home out err status drained
  home=$(make_home signal)
  out="$home/out.txt"
  err="$home/err.txt"
  (
    sleep 1
    printf 'done: synthetic wake\n' > "$home/state/demo.status"
  ) &
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 "$CHECKPOINT" --seconds 8 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "signal checkpoint exit"
  assert_contains "$(cat "$out")" "signal:" "signal wake was not passed through"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh")
  assert_contains "$drained" $'\tsignal\tdemo.status\t' "signal wake was not queued durably"
  pass "checkpoint passes through a real watcher wake and leaves the queue for drain"
}

test_registered_check_uses_preserved_watcher_environment() {
  local home out err status
  home=$(make_home check-env)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  cat > "$home/state/env-check.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'env check fired with FM_CHECK_INTERVAL=%s\n' "${FM_CHECK_INTERVAL:-missing}"
SH
  chmod 0700 "$home/state/env-check.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" env-check >/dev/null \
    || fail "could not register checkpoint custom check"
  status=0
  FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "check checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "check wake was not passed through"
  assert_contains "$(cat "$out")" "FM_CHECK_INTERVAL=1" "watcher environment was not preserved"
  pass "checkpoint preserves watcher environment for registered custom checks"
}

test_existing_singleton_watcher_is_not_success() {
  local home out err status
  home=$(make_home singleton)
  out="$home/out.txt"
  err="$home/err.txt"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$$" > "$home/state/.watch.lock/pid"
  status=0
  FM_HOME="$home" FM_GUARD_GRACE=300 "$CHECKPOINT" --seconds 5 >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "singleton checkpoint exit"
  assert_contains "$(cat "$out")" "watcher: already running" "singleton watcher output was not passed through"
  assert_contains "$(cat "$err")" "outside this foreground checkpoint" "singleton watcher failure was not explained"
  pass "checkpoint rejects an existing watcher singleton as unowned"
}

make_primary_home() {
  local name=$1 home
  home=$(make_home "$name")
  home=$(cd "$home" && pwd -P)
  cp -R "$ROOT/bin" "$home/bin"
  git init -q "$home"
  git -C "$home" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m init
  : > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

start_successor_checkpoint() {
  local home=$1 round=$2
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 "$home/bin/fm-watch-checkpoint.sh" --seconds 20 \
    > "$home/checkpoint-$round.out" 2> "$home/checkpoint-$round.err" &
  CHECKPOINT_PID=$!
}

wait_for_successor_lock() {
  local home=$1
  for _ in $(seq 1 100); do
    if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$1/state" "$1/bin/fm-watch.sh" 300 "$1"' \
      _ "$home" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  fail "successor checkpoint did not acquire the watcher lock"
}

wait_for_actionable_exit() {
  local home=$1 round=$2 status=0
  wait "$CHECKPOINT_PID" || status=$?
  CHECKPOINT_PID=
  expect_code 0 "$status" "actionable checkpoint $round exit"
  assert_contains "$(cat "$home/checkpoint-$round.out")" "signal:" \
    "actionable checkpoint $round did not surface its signal"
  assert_absent "$home/state/.watch.lock/pid" \
    "actionable checkpoint $round kept the watcher lock after surfacing"
}

drain_and_ack() {
  local home=$1 round=$2 sequence generation
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" \
    > "$home/drain-$round.out" 2> "$home/drain-$round.err" \
    || fail "wake drain $round failed"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$home/drain-$round.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$home/drain-$round.err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "wake drain $round did not publish an acknowledgement command"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$home/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" \
    > "$home/ack-$round.out" 2> "$home/ack-$round.err" \
    || fail "wake acknowledgement $round failed"
  [ ! -s "$home/state/.wake-queue" ] || fail "wake acknowledgement $round left a queued row"
}

# shellcheck disable=SC2016 # The fixture harness expands its own session environment.
run_codex_guard() {
  local home=$1
  [ -e "$home/codex" ] || ln -s /bin/bash "$home/codex"
  printf '%s' '{"session_id":"successor","stop_hook_active":true,"turn_id":"turn-successor-test"}' \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CODEX_WATCH_CHECKPOINT=2 \
      "$home/codex" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-turnend-guard.sh" --codex' 2>&1
}

assert_duplicate_refused() {
  local home=$1 round=$2 owner out status=0
  owner=$(cat "$home/state/.watch.lock/pid")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_GUARD_GRACE=300 \
    "$home/bin/fm-watch-checkpoint.sh" --seconds 2 2>&1) || status=$?
  expect_code 1 "$status" "duplicate checkpoint $round exit"
  assert_contains "$out" "watcher: already running" \
    "duplicate checkpoint $round did not report singleton ownership"
  [ "$(cat "$home/state/.watch.lock/pid")" = "$owner" ] \
    || fail "duplicate checkpoint $round replaced the live successor owner"
}

# shellcheck disable=SC2016 # The fixture harness owns expansion of its environment.
test_codex_turn_end_requires_a_successor_after_each_acknowledged_wake() {
  local home round harness out
  home=$(make_primary_home codex-successor)
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE"
  ' _ "$home/bin" || fail 'could not initialize the native successor registry'
  cat > "$home/state/task1.meta" <<EOF
window=firstmate:fm-task1
worktree=$home
project=$home
harness=codex
kind=ship
spawn_gen=fixture-task1
EOF
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_register \
      "$FM_STATE_OVERRIDE" task1 "$FM_STATE_OVERRIDE/task1.meta"
  ' _ "$home/bin" || fail 'could not register the native successor fixture task'
  ln -s /bin/bash "$home/codex"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CODEX_WATCH_CHECKPOINT=30 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 "$home/codex" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      for round in 1 2; do
        printf "{\"session_id\":\"successor\",\"stop_hook_active\":true}" | "$FM_HOME/bin/fm-turnend-guard.sh" --codex > "$FM_HOME/native-$round.out" 2>&1
        printf "%s\n" "$?" > "$FM_HOME/native-$round.rc"
        while [ ! -f "$FM_HOME/resume-$round" ]; do sleep 0.1; done
      done
    ' &
  harness=$!
  for round in 1 2; do
    wait_for_successor_lock "$home"
    assert_duplicate_refused "$home" "$round"
    printf 'done: synthetic consecutive wake %s\n' "$round" >> "$home/state/task1.status"
    for _ in $(seq 1 200); do [ -s "$home/native-$round.rc" ] && break; sleep 0.05; done
    [ -s "$home/native-$round.rc" ] || fail "native Stop $round did not return"
    expect_code 2 "$(cat "$home/native-$round.rc")" "native actionable continuation $round"
    out=$(cat "$home/native-$round.out")
    assert_contains "$out" 'Firstmate Codex supervision:' 'native wake feedback missing'
    [ -s "$home/state/.wake-queue" ] || fail "native Stop $round acknowledged the event"
    drain_and_ack "$home" "$round"
    touch "$home/resume-$round"
  done
  wait "$harness" || fail 'native successor fixture failed'
  pass "Codex continuity: two native actionable exits each preserve acknowledgement and reject a duplicate owner"
}

test_quiet_checkpoint_exits_124_cleanly
test_signal_passes_through_and_exits_zero
test_registered_check_uses_preserved_watcher_environment
test_existing_singleton_watcher_is_not_success
test_codex_turn_end_requires_a_successor_after_each_acknowledged_wake
