#!/usr/bin/env bash
# Public Codex Stop behavior with real singleton watcher and process ownership.
# shellcheck disable=SC2016 # variables expand inside the fake harness child
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop)
ln -s /bin/bash "$TMP_ROOT/codex"
export TEST_CODEX="$TMP_ROOT/codex" TEST_ROOT="$ROOT"
cleanup_tests() {
  local result=$? file pid
  if [ "$result" -ne 0 ] && [ -n "${FM_CODEX_STOP_EVIDENCE:-}" ]; then
    mkdir -p "$FM_CODEX_STOP_EVIDENCE"
    cp -R "$TMP_ROOT" "$FM_CODEX_STOP_EVIDENCE/"
  fi
  for file in "$TMP_ROOT"/*/hook "$TMP_ROOT"/*/harness; do
    [ -f "$file" ] || continue
    pid=$(cat "$file")
    if ps -p "$pid" -o args= 2>/dev/null | grep -E 'fm-codex-stop|fm-turnend-guard' >/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  fm_test_cleanup
}
trap cleanup_tests EXIT


fixture() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/bin" "$dir/config"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}
run_stop() { # <home> [checkpoint]
  local home=$1
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CODEX_WATCH_CHECKPOINT="${2:-2}" \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 \
    FM_GUARD_GRACE="${FM_GUARD_GRACE:-3}" FM_BACKEND=tmux \
    "$TEST_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" > "$FM_HOME/harness"
      printf "{\"session_id\":\"fixture\",\"stop_hook_active\":true}" > "$FM_HOME/payload"
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload" > "$FM_HOME/out" 2>&1 &
      hook=$!
      printf "%s\n" "$hook" > "$FM_HOME/hook"
      if [ "${FM_CODEX_DUPLICATE:-0}" = 1 ]; then
        for _ in $(seq 1 100); do [ -s "$FM_HOME/state/.watch.lock/pid" ] && break; sleep 0.02; done
        "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload" > "$FM_HOME/duplicate" 2>&1
        printf "%s\n" "$?" > "$FM_HOME/duplicate-rc"
      fi
      wait "$hook"; rc=$?
      printf "%s\n" "$rc" > "$FM_HOME/rc"
      if [ "${FM_CODEX_REPEAT:-0}" = 1 ]; then
        jq -r .owner "$FM_HOME/state/.codex-stop.json" > "$FM_HOME/first-owner"
        "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload" > "$FM_HOME/repeat-out" 2>&1
        echo "$?" > "$FM_HOME/repeat-rc"
      fi
      # Keep the session alive while the caller examines its handling proof.
      while [ ! -f "$FM_HOME/release" ]; do sleep 0.1; done
    ' &
  HARNESS=$!
}
wait_file() {
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ] || fail "timeout waiting for $1"
}
finish() { touch "$1/release"; wait "$HARNESS"; }
assert_no_watcher() {
  local pid
  pid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null || true)
  # Cancellation during watcher initialization can retain a dead lock before
  # the watcher's cleanup trap exists. Prove process death, not file absence.
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  ps -p "$pid" -o pid= -o ppid= -o stat= -o args= > "$1/watcher-after-cleanup" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then fail "owned watcher $pid survived Stop cleanup: $(cat "$1/watcher-after-cleanup")"; fi
}

install_controlled_watcher() {
  local dir=$1
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh} "$dir/bin/"
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
child=
printf '%s\n' "$$" > "$FM_HOME/controlled-arm-pid"
stop_arm() {
  printf '%s\n' term > "$FM_HOME/controlled-arm-term"
  [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || true
  [ -z "$child" ] || wait "$child" 2>/dev/null || true
  exit 0
}
trap stop_arm HUP INT TERM
sleep "${FM_TEST_ARM_DELAY:-0}"
bash "$SCRIPT_DIR/fm-watch.sh" &
child=$!
wait "$child"
exit $?
ARM
  cat > "$dir/bin/fm-watch.sh" <<'WATCH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
lock="$FM_HOME/state/.watch.lock"
mkdir "$lock" || exit 1
identity=$(fm_pid_identity "$$") || exit 1
printf '%s\n' "$$" > "$lock/pid"
printf '%s\n' "$FM_HOME" > "$lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$lock/watcher-path"
printf '%s\n' "$identity" > "$lock/pid-identity"
clean_watcher() {
  rm -rf "$lock"
}
trap clean_watcher EXIT
trap 'exit 0' HUP INT TERM
touch "$FM_HOME/state/.last-watcher-beat"
date +%s > "$FM_HOME/controlled-watcher-ready"
cycles=0
while :; do
  sleep "${FM_POLL:-1}"
  case "${FM_TEST_WATCH_MODE:-progress}" in
    stall) ;;
    late-stop)
      cycles=$((cycles + 1))
      touch "$FM_HOME/state/.last-watcher-beat"
      if [ "$cycles" -ge 3 ]; then
        printf '%s\n' "$$" > "$FM_HOME/controlled-watcher-stopped"
        kill -STOP "$$"
      fi
      ;;
    *) touch "$FM_HOME/state/.last-watcher-beat" ;;
  esac
done
WATCH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-watch.sh"
}

test_initial_fork_failure_blocks_stop() {
  local dir
  dir=$(fixture fork-failure)
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import errno
import os


def fail_fork():
    with open(os.path.join(os.environ['FM_HOME'], 'fork-attempted'), 'w') as stream:
        stream.write('EAGAIN\n')
    raise OSError(errno.EAGAIN, 'injected fork failure')


os.fork = fail_fork
PY
  append_wake "$dir/state" check fork 'check: retained event'
  cp "$dir/state/.wake-queue" "$dir/queue-before"
  PYTHONPATH="$dir/fault" run_stop "$dir"
  wait_file "$dir/rc"
  finish "$dir"
  [ -s "$dir/fork-attempted" ] || fail 'fork failure was not injected'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'initial fork failure allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.' 'fork failure omitted owner-unavailable diagnostic'
  cmp "$dir/queue-before" "$dir/state/.wake-queue" || fail 'fork failure acknowledged queued work'
  [ ! -e "$dir/state/.codex-stop.json" ] || fail 'fork failure published ownership'
  assert_no_watcher "$dir"
  pass 'initial owner fork failure blocks Stop with a diagnostic and retains queued work'
}

test_python_bootstrap_failure_fails_closed() {
  local dir healthy_rc
  dir=$(fixture bootstrap-failure)
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import builtins
import os


original_import = builtins.__import__


def fail_fcntl(name, globals=None, locals=None, fromlist=(), level=0):
    if name == 'fcntl':
        with open(os.path.join(os.environ['FM_HOME'], 'bootstrap-attempted'), 'w') as stream:
            stream.write('ImportError\n')
        raise ImportError('injected fcntl import failure')
    return original_import(name, globals, locals, fromlist, level)


builtins.__import__ = fail_fcntl
PY
  append_wake "$dir/state" check bootstrap 'check: retained event'
  cp "$dir/state/.wake-queue" "$dir/queue-before"
  PYTHONPATH="$dir/fault" run_stop "$dir"
  wait_file "$dir/rc"
  finish "$dir"
  [ -s "$dir/bootstrap-attempted" ] || fail 'Python bootstrap failure was not injected'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'Python bootstrap failure allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.' 'Python bootstrap failure omitted owner-unavailable diagnostic'
  cmp "$dir/queue-before" "$dir/state/.wake-queue" || fail 'Python bootstrap failure acknowledged queued work'
  [ ! -e "$dir/state/.codex-stop.json" ] || fail 'Python bootstrap failure published ownership'
  assert_no_watcher "$dir"
  PYTHONPATH="$dir/fault" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-codex-stop.sh" --healthy "$dir/state" > "$dir/healthy-out" 2>&1
  healthy_rc=$?
  [ "$healthy_rc" = 1 ] || fail 'Python bootstrap failure changed the health-probe contract'
  pass 'Python bootstrap failure blocks Stop and leaves health unavailable'
}

test_python_launch_failure_fails_closed() {
  local dir healthy_rc
  dir=$(fixture python-launch-failure)
  mkdir "$dir/fault-bin"
  cat > "$dir/fault-bin/python3" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "${1:-}" = - ]; then
  cat >/dev/null
  exit 0
fi
printf '%s\n' 'failed' > "$FM_HOME/python-launch-attempted"
exit 1
SH
  chmod +x "$dir/fault-bin/python3"
  append_wake "$dir/state" check python-launch 'check: retained event'
  cp "$dir/state/.wake-queue" "$dir/queue-before"
  PATH="$dir/fault-bin:$PATH" run_stop "$dir"
  wait_file "$dir/rc"
  finish "$dir"
  [ -s "$dir/python-launch-attempted" ] || fail 'broken Python interpreter was not invoked'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'broken Python interpreter allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'Firstmate Codex supervision: owner unavailable; inspect the Stop adapter and retry safely.' 'broken Python interpreter omitted owner-unavailable diagnostic'
  cmp "$dir/queue-before" "$dir/state/.wake-queue" || fail 'broken Python interpreter acknowledged queued work'
  [ ! -e "$dir/state/.codex-stop.json" ] || fail 'broken Python interpreter published ownership'
  assert_no_watcher "$dir"
  PATH="$dir/fault-bin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$ROOT/bin/fm-codex-stop.sh" --healthy "$dir/state" > "$dir/healthy-out" 2>&1
  healthy_rc=$?
  [ "$healthy_rc" = 1 ] || fail 'broken Python interpreter changed the health-probe contract'
  pass 'Python launch failure blocks Stop and leaves health unavailable'
}

test_public_stop_dispatches_pending_queue() {
  local dir need
  for need in yes no; do
    dir=$(fixture "pending-$need")
    [ "$need" != yes ] || : > "$dir/state/task.meta"
    append_wake "$dir/state" check fixture 'check: fixture ready'
    cp "$dir/state/.wake-queue" "$dir/queue-before"
    run_stop "$dir"
    wait_file "$dir/rc"
    [ "$(cat "$dir/rc")" = 2 ] || fail 'queued wake did not request native continuation'
    cmp "$dir/queue-before" "$dir/state/.wake-queue" || fail 'adapter acknowledged queued work'
    assert_contains "$(cat "$dir/out")" 'durable wake pending' 'missing delivery reason'
    assert_no_watcher "$dir"
    finish "$dir"
  done
  pass 'Codex Stop delivers queued work with or without remaining tasks, without acknowledgement'
}

test_quiet_renewal() {
  local dir
  dir=$(fixture quiet)
  : > "$dir/state/task.meta"
  run_stop "$dir" 3
  wait_file "$dir/state/.watch.lock/pid"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'quiet checkpoint did not request continuation'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'quiet renewal reason missing'
  assert_no_watcher "$dir"
  FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" || fail 'delivered handling interval is not healthy'
  finish "$dir"
  pass 'quiet checkpoint requests native renewal and leaves bounded handling proof'
}

test_wedged_arm_cannot_report_quiet_renewal() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture wedged-arm)
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh} "$dir/bin/"
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/wedged-arm"
trap 'printf "%s\n" term > "$FM_HOME/wedged-arm-term"; exit 0' TERM
while :; do sleep 1; done
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"
  : > "$dir/state/task.meta"
  TEST_ROOT="$dir" run_stop "$dir" 2
  TEST_ROOT=$original_root
  wait_file "$dir/wedged-arm"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'wedged watcher launcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'wedged watcher launcher omitted failure reason'
  assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'wedged watcher launcher reported quiet renewal'
  [ -s "$dir/wedged-arm-term" ] || fail 'wedged watcher launcher was not cancelled'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'wedged watcher launcher fails closed instead of reporting quiet renewal'
}

test_late_watcher_gets_full_quiet_window() {
  local dir original_root=$TEST_ROOT ready finished
  dir=$(fixture late-watcher)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_TEST_ARM_DELAY=2 TEST_ROOT="$dir" run_stop "$dir" 2
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  ready=$(cat "$dir/controlled-watcher-ready")
  wait_file "$dir/rc"
  finished=$(date +%s)
  [ "$((finished - ready))" -ge 2 ] || fail 'late watcher startup consumed the quiet checkpoint'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'late healthy watcher did not request quiet renewal'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'late healthy watcher omitted quiet renewal reason'
  [ -s "$dir/controlled-arm-term" ] || fail 'late watcher arm was not cancelled'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'quiet checkpoint starts after verified watcher readiness'
}

test_stalled_watcher_cannot_complete_quiet_window() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture stalled-watcher)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_TEST_WATCH_MODE=stall TEST_ROOT="$dir" run_stop "$dir" 2
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'stalled watcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'stalled watcher omitted failure reason'
  assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'stalled watcher reported quiet renewal'
  [ -s "$dir/controlled-arm-term" ] || fail 'stalled watcher arm was not cancelled'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'quiet checkpoint requires watcher beacon progress'
}

test_late_stopped_watcher_cannot_complete_quiet_window() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture late-stopped-watcher)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_TEST_WATCH_MODE=late-stop TEST_ROOT="$dir" run_stop "$dir" 4
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-stopped"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'late stopped watcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'late stopped watcher omitted failure reason'
  assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'late stopped watcher reported quiet renewal'
  [ -s "$dir/controlled-arm-term" ] || fail 'late stopped watcher arm was not cancelled'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'post-deadline progress rejects a late stopped watcher'
}

test_complete_watcher_cycle_can_deliver_actionable_wake() {
  local dir
  dir=$(fixture complete-cycle)
  : > "$dir/state/task.meta"
  FM_SIGNAL_GRACE=4 FM_GUARD_GRACE=8 run_stop "$dir" 15
  wait_file "$dir/state/.watch.lock/pid"
  printf '%s\n' 'done: complete cycle' > "$dir/state/complete.status"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'complete watcher cycle lost its actionable wake'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'complete watcher cycle did not deliver its queued wake'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'complete watcher cycle was reported as stalled'
  [ -s "$dir/state/.wake-queue" ] || fail 'complete watcher cycle did not retain its actionable wake'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'complete watcher cycle remains live through signal coalescing'
}

test_dead_arm_launcher_retires_owned_watcher_group() {
  local dir original_root=$TEST_ROOT arm
  dir=$(fixture dead-arm-launcher)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  TEST_ROOT="$dir" run_stop "$dir" 15
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  wait_file "$dir/controlled-arm-pid"
  arm=$(cat "$dir/controlled-arm-pid")
  kill -KILL "$arm"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'dead arm launcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'dead arm launcher omitted failure reason'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'dead arm launcher retains cancellation of its owned watcher group'
}

test_final_source_wake_retains_continuation() {
  local dir
  dir=$(fixture final)
  : > "$dir/state/task.meta"
  run_stop "$dir" 15
  wait_file "$dir/state/.watch.lock/pid"
  append_wake "$dir/state" check final 'check: last source completed'
  rm "$dir/state/task.meta"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'final event was lost with its supervision source'
  [ -s "$dir/state/.wake-queue" ] || fail 'final event was acknowledged'
  finish "$dir"
  pass 'post-turn final wake survives loss of supervision need'
}

test_cleanup_cancellation_revokes_handling() {
  local dir kind hook
  for kind in TERM KILL afk replacement no-need; do
    printf 'case - cancellation %s\n' "$kind"
    dir=$(fixture "cancel-$kind")
    : > "$dir/state/task.meta"
    run_stop "$dir" 15
    wait_file "$dir/state/.watch.lock/pid"
    hook=$(cat "$dir/hook")
    case "$kind" in
      TERM|KILL) kill "-$kind" "$hook" ;;
      afk) touch "$dir/state/.afk" ;;
      replacement) printf '99999999\n' > "$dir/state/.lock" ;;
      no-need) rm "$dir/state/task.meta" ;;
    esac
    wait_file "$dir/rc"
    for _ in $(seq 1 80); do [ ! -e "$dir/state/.watch.lock" ] && break; sleep 0.1; done
    assert_no_watcher "$dir"
    for _ in $(seq 1 60); do [ ! -e "$dir/state/.codex-stop.json" ] && break; sleep 0.1; done
    [ ! -e "$dir/state/.codex-stop.json" ] || fail "$kind retained continuation proof"
    assert_not_contains "$(cat "$dir/out")" 'Firstmate Codex supervision:' "$kind delivered a continuation"
    finish "$dir"
  done
  pass 'cancellation, forced death, away mode, generation replacement and no need stand down'
}

test_singleton() {
  local dir owner
  dir=$(fixture singleton)
  : > "$dir/state/task.meta"
  # Keep the first request watching until all duplicate assertions complete.
  # A three-second expiry can turn a delayed duplicate into a valid successor.
  FM_CODEX_DUPLICATE=1 run_stop "$dir" 30
  wait_file "$dir/state/.watch.lock/pid"
  wait_file "$dir/duplicate-rc"
  [ "$(cat "$dir/duplicate-rc")" = 0 ] || fail 'same-session duplicate did not defer'
  [ ! -s "$dir/duplicate" ] || fail 'same-session duplicate emitted a continuation'
  owner=$(jq -r .owner "$dir/state/.codex-stop.json")
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-codex-stop.sh" < "$dir/payload" > "$dir/competing" 2>&1
  [ "$(jq -r .owner "$dir/state/.codex-stop.json")" = "$owner" ] || fail 'competing session displaced owner'
  [ ! -s "$dir/competing" ] || fail 'competing session requested continuation'
  append_wake "$dir/state" check singleton 'check: singleton assertions complete'
  wait_file "$dir/rc"
  finish "$dir"
  pass 'competing session cannot displace the singleton Stop owner'
}


test_expired_successor_requires_replacement_generation() {
  local dir
  dir=$(fixture expiry)
  append_wake "$dir/state" check expiry 'check: expiry'
  FM_CODEX_HANDLING_GRACE=1 run_stop "$dir"
  wait_file "$dir/rc"
  sleep 2
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state"; then
    fail 'expired continuation still reports healthy'
  fi
  finish "$dir"
  # A successor in a new process must replace the old handling identity.
  rm "$dir/rc" "$dir/release"
  run_stop "$dir"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'new generation did not deliver retained event'
  [ "$(jq -r .session_pid "$dir/state/.codex-stop.json")" = "$(cat "$dir/harness")" ] || fail 'successor inherited old session identity'
  finish "$dir"
  pass 'expired handling proof fails closed; successor binds its own generation'
}

test_health_challenge_rejects_replaced_generation() {
  local dir
  dir=$(fixture health-replacement)
  append_wake "$dir/state" check health-replacement 'check: retained event'
  run_stop "$dir"
  wait_file "$dir/rc"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" || fail 'current generation did not report healthy'
  printf '99999999\n' > "$dir/state/.lock"
  if FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state"; then
    fail 'replaced generation retained healthy handling proof'
  fi
  finish "$dir"
  pass 'health challenge fails closed immediately after generation replacement'
}

test_post_accept_interruption_revokes_owner() {
  local dir
  dir=$(fixture post-accept-interruption)
  append_wake "$dir/state" check post-accept 'check: retained event'
  FM_CODEX_STOP_TEST_INTERRUPT_AFTER_ACCEPTED=1 run_stop "$dir"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 0 ] || fail 'post-accept interruption committed a continuation'
  for _ in $(seq 1 60); do [ ! -e "$dir/state/.codex-stop.json" ] && break; sleep 0.1; done
  [ ! -e "$dir/state/.codex-stop.json" ] || fail 'post-accept interruption retained healthy ownership'
  [ -s "$dir/state/.wake-queue" ] || fail 'post-accept interruption acknowledged queued work'
  finish "$dir"
  pass 'post-accept interruption revokes the owner before continuation commit'
}

test_same_process_session_replacement_hands_off() {
  local dir
  dir=$(fixture same-process-handoff)
  append_wake "$dir/state" check handoff 'check: retained event'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=2 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 FM_BACKEND=tmux \
    "$TEST_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      printf "%s\n" "$$" > "$FM_HOME/harness"
      printf "%s\n" "{\"session_id\":\"session-a\",\"stop_hook_active\":true}" > "$FM_HOME/payload-a"
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload-a" > "$FM_HOME/a-out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/a-rc"
      for _ in $(seq 1 50); do
        [ "$(jq -r .phase "$FM_HOME/state/.codex-stop.json" 2>/dev/null)" = handling ] && break
        sleep 0.1
      done
      jq -r .owner "$FM_HOME/state/.codex-stop.json" > "$FM_HOME/owner-a"
      printf "%s\n" "{\"session_id\":\"session-b\",\"stop_hook_active\":true}" > "$FM_HOME/payload-b"
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload-b" > "$FM_HOME/b1-out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/b1-rc"
      for _ in $(seq 1 50); do [ ! -e "$FM_HOME/state/.codex-stop.json" ] && break; sleep 0.1; done
      [ ! -e "$FM_HOME/state/.codex-stop.json" ] && printf "%s\n" yes > "$FM_HOME/a-revoked"
      sleep 0.1
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload-b" > "$FM_HOME/b2-out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/b2-rc"
      for _ in $(seq 1 50); do
        [ "$(jq -r .phase "$FM_HOME/state/.codex-stop.json" 2>/dev/null)" = handling ] && break
        sleep 0.1
      done
      jq -r .owner "$FM_HOME/state/.codex-stop.json" > "$FM_HOME/owner-b"
      jq -r .session_id "$FM_HOME/state/.codex-stop.json" > "$FM_HOME/session-b"
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload-b" > "$FM_HOME/b3-out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/b3-rc"
      while [ ! -f "$FM_HOME/release" ]; do sleep 0.1; done
    ' &
  HARNESS=$!
  wait_file "$dir/b3-rc"
  [ "$(cat "$dir/a-rc")" = 2 ] || fail 'original session did not establish handling ownership'
  [ "$(cat "$dir/b1-rc")" = 2 ] || fail 'replacement session did not receive bounded retry'
  assert_contains "$(cat "$dir/b1-out")" 'session generation changed; retry Stop' 'replacement session omitted retry reason'
  [ -s "$dir/a-revoked" ] || fail 'replacement session did not revoke the prior owner'
  [ "$(cat "$dir/b2-rc")" = 2 ] && [ "$(cat "$dir/b3-rc")" = 2 ] || fail 'replacement session could not repeat Stop after handoff'
  [ "$(cat "$dir/owner-a")" != "$(cat "$dir/owner-b")" ] || fail 'replacement session reused the prior owner'
  [ "$(cat "$dir/session-b")" = session-b ] || fail 'replacement owner retained the old session id'
  [ -s "$dir/state/.wake-queue" ] || fail 'session handoff acknowledged queued work'
  finish "$dir"
  pass 'same-process session replacement revokes and reacquires ownership'
}

test_uncertain_session_inert() {
  local dir pid
  for pid in '' 99999999 malformed; do
    dir=$(fixture "refused-$pid")
    : > "$dir/state/task.meta"
    printf '%s\n' "$pid" > "$dir/state/.lock"
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-turnend-guard.sh" --codex <<<'{"session_id":"refused"}' > "$dir/out" 2>&1
    [ ! -e "$dir/state/.codex-stop.lock" ] || fail 'unowned session claimed Stop'
    [ ! -e "$dir/state/.codex-stop.json" ] || fail 'unowned session published proof'
    [ ! -s "$dir/out" ] || fail 'unowned session emitted feedback'
  done
  pass 'dead, malformed and uncertain session owners remain inert'
}


test_identity_mismatch_fails_closed_and_reaps_owned_group() {
  local dir original_root=$TEST_ROOT arm watcher
  dir=$(fixture identity-change)
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh} "$dir/bin/"
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/arm-pid"
sleep 1
exec python3 - "$FM_HOME" <<'PY'
import os
import signal
import sys
import time

home = sys.argv[1]
watcher = os.fork()
if watcher == 0:
    def group_term(_signum, _frame):
        with open(os.path.join(home, 'watcher-group-term'), 'w') as stream:
            stream.write('term\n')
        os._exit(0)

    signal.signal(signal.SIGTERM, group_term)
    signal.signal(signal.SIGHUP, lambda _signum, _frame: os._exit(0))
    while True:
        signal.pause()

with open(os.path.join(home, 'watcher-pid'), 'w') as stream:
    stream.write(str(watcher) + '\n')

def cleanup(_signum, _frame):
    with open(os.path.join(home, 'arm-direct-term'), 'w') as stream:
        stream.write('term\n')
    for _ in range(10):
        if os.path.exists(os.path.join(home, 'watcher-group-term')):
            break
        time.sleep(0.05)
    try:
        os.kill(watcher, signal.SIGHUP)
    except ProcessLookupError:
        pass
    os.waitpid(watcher, 0)
    os._exit(0)

signal.signal(signal.SIGTERM, cleanup)
while True:
    signal.pause()
PY
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"
  : > "$dir/state/task.meta"
  TEST_ROOT="$dir" run_stop "$dir" 3
  TEST_ROOT=$original_root
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'identity mismatch did not return bounded failure'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'identity mismatch reported quiet success'
  arm=$(cat "$dir/arm-pid")
  watcher=$(cat "$dir/watcher-pid")
  [ -s "$dir/arm-direct-term" ] || fail 'adapter did not let its owned arm handle cancellation'
  [ ! -e "$dir/watcher-group-term" ] || fail 'adapter broadcast its initial cancellation to the owned process group'
  if kill -0 "$arm" 2>/dev/null; then fail 'adapter abandoned its identity-mismatched child group'; fi
  if kill -0 "$watcher" 2>/dev/null; then fail 'adapter abandoned the arm-owned watcher child'; fi
  finish "$dir"
  pass 'identity mismatch fails closed and lets the arm retire its owned watcher in order'
}

# The persisted record is an observation, never sufficient authority by itself.
test_reused_or_uncertain_owner_is_reclaimed() {
  local dir kind foreign
  for kind in dead reused uncertain expired; do
    dir=$(fixture "stale-$kind")
    sleep 60 & foreign=$!
    printf '{"owner":%s,"owner_identity":"unknown","session_pid":"%s","phase":"handling","deadline":9999999999,"token":"stale"}\n' "$foreign" "$foreign" > "$dir/state/.codex-stop.json"
    if "$ROOT/bin/fm-codex-stop.sh" --healthy "$dir/state"; then fail "$kind stale record was healthy"; fi
    append_wake "$dir/state" check stale 'check: retained event'
    run_stop "$dir"
    wait_file "$dir/rc"
    [ "$(cat "$dir/rc")" = 2 ] || fail "$kind record blocked successor"
    kill -0 "$foreign" || fail 'unrelated live process was signalled'
    kill -TERM "$foreign"; wait "$foreign" 2>/dev/null || true
    finish "$dir"
  done
  pass 'stale, reused and uncertain record identities cannot confer ownership or block successor'
}

test_native_continuation_commit_is_serialized() {
  local dir owner
  dir=$(fixture serialized)
  append_wake "$dir/state" check serialized 'check: serialized'
  FM_CODEX_REPEAT=1 run_stop "$dir"
  wait_file "$dir/repeat-rc"
  [ "$(cat "$dir/rc")" = 2 ] && [ "$(cat "$dir/repeat-rc")" = 2 ] || fail 'successor lost continuation'
  owner=$(cat "$dir/first-owner")
  [ "$(jq -r .owner "$dir/state/.codex-stop.json")" = "$owner" ] || fail 'successor introduced a second record writer'
  [ -s "$dir/state/.wake-queue" ] || fail 'successor acknowledged unhandled work'
  finish "$dir"
  pass 'one live owner serializes native response and successor handoff without acknowledging work'
}

test_record_transition_fails_closed_and_recovers_identity() {
  local dir
  dir=$(fixture record-refused)
  mkdir "$dir/state/.codex-stop.json"
  append_wake "$dir/state" check record 'check: record'
  run_stop "$dir"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'record refusal allowed blind Stop'
  if "$ROOT/bin/fm-codex-stop.sh" --healthy "$dir/state"; then fail 'failed publication was healthy'; fi
  [ -s "$dir/state/.wake-queue" ] || fail 'failed publication consumed wake'
  finish "$dir"
  rmdir "$dir/state/.codex-stop.json"
  rm "$dir/rc" "$dir/release"
  run_stop "$dir"
  wait_file "$dir/rc"
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'successor failed to recover after refused publication'
  finish "$dir"
  pass 'record refusal fails closed and releases exclusion for a later successor'
}

test_replacement_session_fails_closed_on_old_owner() {
  local dir old_harness owner replacement
  dir=$(fixture replacement-owner)
  : > "$dir/state/task.meta"
  run_stop "$dir" 15
  old_harness=$HARNESS
  wait_file "$dir/state/.watch.lock/pid"
  owner=$(jq -r .owner "$dir/state/.codex-stop.json")
  kill -STOP "$owner"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=2 "$TEST_CODEX" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex <<< "{\"session_id\":\"replacement\"}" > "$FM_HOME/replacement-out" 2>&1
    echo "$?" > "$FM_HOME/replacement-rc"
  ' & replacement=$!
  wait_file "$dir/replacement-rc"
  wait "$replacement"
  [ "$(cat "$dir/replacement-rc")" = 2 ] || fail 'new session trusted frozen old owner'
  kill -CONT "$owner"
  wait_file "$dir/rc"
  HARNESS=$old_harness
  finish "$dir"
  pass 'a replacement generation cannot inherit an old frozen owner'
}

test_record_mutation_interruption_clears_ownership() {
  local dir owner
  dir=$(fixture dead-owner)
  append_wake "$dir/state" check dead 'check: dead owner'
  run_stop "$dir"
  wait_file "$dir/rc"
  owner=$(jq -r .owner "$dir/state/.codex-stop.json")
  cp "$dir/state/.codex-stop.json" "$dir/before"
  kill -KILL "$owner"
  if "$ROOT/bin/fm-codex-stop.sh" --healthy "$dir/state"; then fail 'killed owner left healthy proof'; fi
  cmp "$dir/before" "$dir/state/.codex-stop.json" || fail 'health reader mutated orphan state'
  finish "$dir"
  rm "$dir/rc" "$dir/release"
  run_stop "$dir"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'kernel exclusion survived owner death'
  [ "$(jq -r .owner "$dir/state/.codex-stop.json")" != "$owner" ] || fail 'successor reused dead owner'
  finish "$dir"
  pass 'owner death revokes health without an orphan record writer; kernel releases successor exclusion'
}

test_initial_fork_failure_blocks_stop
test_python_bootstrap_failure_fails_closed
test_python_launch_failure_fails_closed
test_public_stop_dispatches_pending_queue
test_quiet_renewal
test_wedged_arm_cannot_report_quiet_renewal
test_late_watcher_gets_full_quiet_window
test_stalled_watcher_cannot_complete_quiet_window
test_late_stopped_watcher_cannot_complete_quiet_window
test_complete_watcher_cycle_can_deliver_actionable_wake
test_dead_arm_launcher_retires_owned_watcher_group
test_final_source_wake_retains_continuation
test_cleanup_cancellation_revokes_handling
test_singleton

test_expired_successor_requires_replacement_generation
test_health_challenge_rejects_replaced_generation
test_post_accept_interruption_revokes_owner
test_same_process_session_replacement_hands_off
test_uncertain_session_inert

test_identity_mismatch_fails_closed_and_reaps_owned_group

test_reused_or_uncertain_owner_is_reclaimed
test_native_continuation_commit_is_serialized
test_record_transition_fails_closed_and_recovers_identity
test_replacement_session_fails_closed_on_old_owner
test_record_mutation_interruption_clears_ownership
