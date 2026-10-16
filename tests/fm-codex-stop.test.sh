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
  for file in "$TMP_ROOT"/*/sentinel-pid; do
    [ -f "$file" ] || continue
    kill -TERM "$(cat "$file")" 2>/dev/null || true
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
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL="${FM_POLL:-1}" \
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
  local i=0 limit=${2:-150}
  while [ ! -s "$1" ] && [ "$i" -lt "$limit" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ] || fail "timeout waiting for $1"
}
finish() { touch "$1/release"; wait "$HARNESS"; }

ack_watcher_cycle() {
  local state=$1 err sequence generation
  err="$state/.test-wake-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

run_bounded_watcher_cycle() {
  local home=$1 fakebin=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 3; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=1 \
      FM_CHECKS_PER_CYCLE=1 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      PATH="$fakebin:$PATH" "$ROOT/bin/fm-watch.sh"
}

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
  cp -R "$ROOT/bin/." "$dir/bin/"
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
case "${FM_CODEX_BOUNDED_WATCH:-0}:${FM_CHECKS_PER_CYCLE:-0}" in
  1:*[!0-9]*|1:0|1:) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
  1:*) printf 'fm-codex-bounded.v1\t%s\n' "$FM_CHECKS_PER_CYCLE" > "$lock/codex-bounded-capability" ;;
  *) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
esac
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
  cycles=$((cycles + 1))
  case "${FM_TEST_WATCH_MODE:-progress}" in
    stall) ;;
    late-stop)
      touch "$FM_HOME/state/.last-watcher-beat"
      if [ "$cycles" -ge 3 ]; then
        printf '%s\n' "$$" > "$FM_HOME/controlled-watcher-stopped"
        kill -STOP "$$"
      fi
      ;;
    pending-recovery)
      if [ "$cycles" -eq 1 ]; then
        . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
        fm_pending_reply_send_recovery "$FM_HOME/state" "$(cat "$FM_HOME/pending-corr")" || true
      fi
      touch "$FM_HOME/state/.last-watcher-beat"
      ;;
    pending-tick)
      if [ "$cycles" -eq 1 ]; then
        . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
        fm_pending_reply_tick "$FM_HOME/state" || true
        fm_wake_append check pending-tick 'check: pending reply tick completed'
      fi
      touch "$FM_HOME/state/.last-watcher-beat"
      ;;
    *) touch "$FM_HOME/state/.last-watcher-beat" ;;
  esac
done
WATCH
  chmod +x "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-watch.sh"
}

install_endpoint_inventory_tmux() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = list-windows ]; then
  session=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -t ]; then
      session=${2:-}
      break
    fi
    shift
  done
  for target in ${FM_TEST_EXISTING_TARGETS:-${FM_TEST_LIVE_TARGETS:-}}; do
    [ "${target%%:*}" = "$session" ] && printf '%s\n' "${target#*:}"
  done
  exit 0
fi
if [ "${1:-}" = capture-pane ]; then
  [ -z "${FM_TEST_CAPTURE_LOG:-}" ] || printf '%s\n' capture >> "$FM_TEST_CAPTURE_LOG"
  printf '%s\n' "${FM_TEST_CAPTURE:-retained endpoint}"
  exit 0
fi
if [ "${1:-}" = display-message ]; then
  target=
  format=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -t ]; then
      target=${2:-}
    fi
    case "$1" in
      *pane_current_command*) format=current-command ;;
      *pane_id*) format=existence ;;
    esac
    shift
  done
  case " ${FM_TEST_EXISTING_TARGETS:-${FM_TEST_LIVE_TARGETS:-}} " in
    *" $target "*)
      case " ${FM_TEST_EXISTENCE_PROBE_FAILURES:-} " in
        *" $target "*) [ "$format" != existence ] || exit 1 ;;
      esac
      if [ "$format" = current-command ]; then
        case " ${FM_TEST_LIVE_TARGETS:-} " in
          *" $target "*) printf 'codex\n' ;;
          *)
            case " ${FM_TEST_AMBIGUOUS_TARGETS:-} " in
              *" $target "*) printf 'python\n' ;;
              *) printf 'zsh\n' ;;
            esac
            ;;
        esac
      else
        printf '999999\n'
      fi
      exit 0
      ;;
  esac
fi
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
}

install_attached_watcher() {
  local dir=$1
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh,fm-watch-arm.sh,fm-backend.sh} "$dir/bin/"
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
case "${FM_CODEX_BOUNDED_WATCH:-0}:${FM_CHECKS_PER_CYCLE:-0}" in
  1:*[!0-9]*|1:0|1:) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
  1:*) printf 'fm-codex-bounded.v1\t%s\n' "$FM_CHECKS_PER_CYCLE" > "$lock/codex-bounded-capability" ;;
  *) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
esac
clean_watcher() {
  rm -rf "$lock"
}
trap clean_watcher EXIT
trap 'exit 0' HUP INT TERM
touch "$FM_HOME/state/.last-watcher-beat"
printf '%s\n' "$$" > "$FM_HOME/attached-watcher-ready"
sleep "${FM_SIGNAL_GRACE:-30}"
while :; do
  touch "$FM_HOME/state/.last-watcher-beat"
  sleep 1
done
WATCH
  chmod +x "$dir/bin/fm-watch.sh"
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
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh,fm-backend.sh} "$dir/bin/"
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
  FM_TEST_WATCH_MODE=stall FM_SIGNAL_GRACE=0 TEST_ROOT="$dir" run_stop "$dir" 2
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  wait_file "$dir/rc" 250
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
  FM_TEST_WATCH_MODE=late-stop FM_SIGNAL_GRACE=0 TEST_ROOT="$dir" run_stop "$dir" 4
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-stopped"
  wait_file "$dir/rc" 250
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
  printf '%s\n' 'working: initial signal state' > "$dir/state/complete.status"
  prime_status_seen "$dir/state" "$dir/state/complete.status"
  FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 run_stop "$dir" 45
  wait_file "$dir/state/.watch.lock/pid"
  printf '%s\n' 'done: complete cycle' > "$dir/state/complete.status"
  wait_file "$dir/rc" 450
  [ "$(cat "$dir/rc")" = 2 ] || fail 'complete watcher cycle lost its actionable wake'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'complete watcher cycle did not deliver its queued wake'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'complete watcher cycle was reported as stalled'
  [ -s "$dir/state/.wake-queue" ] || fail 'complete watcher cycle did not retain its actionable wake'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'complete watcher cycle remains live through signal coalescing'
}

test_attached_arm_uses_complete_cycle_grace() {
  local dir original_root=$TEST_ROOT watcher
  dir=$(fixture attached-complete-cycle)
  install_attached_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_SIGNAL_GRACE=30 \
    FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE=1 "$dir/bin/fm-watch.sh" &
  watcher=$!
  printf '%s\n' "$watcher" > "$dir/sentinel-pid"
  wait_file "$dir/attached-watcher-ready"
  sleep 2
  FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 TEST_ROOT="$dir" run_stop "$dir" 4
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 500
  [ "$(cat "$dir/rc")" = 2 ] || fail 'attached watcher did not request quiet renewal'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'attached arm rejected a healthy coalescing watcher'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'attached arm used the raw short guard grace'
  kill -0 "$watcher" 2>/dev/null || fail 'adapter cancelled an independently attached watcher'
  finish "$dir"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass 'attached arm shares the complete-cycle liveness grace'
}

test_attached_arm_rejects_unproven_bounded_mode() {
  local dir original_root=$TEST_ROOT watcher
  dir=$(fixture attached-unproven-bounded-mode)
  install_attached_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-watch.sh" &
  watcher=$!
  printf '%s\n' "$watcher" > "$dir/sentinel-pid"
  wait_file "$dir/attached-watcher-ready"
  TEST_ROOT="$dir" run_stop "$dir" 2
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'unproven attached watcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' 'unproven attached watcher omitted the refusal'
  assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'unproven attached watcher received bounded admission'
  kill -0 "$watcher" 2>/dev/null || fail 'bounded-capability refusal killed the independently owned watcher'
  finish "$dir"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass 'attached watcher needs live bounded-mode capability proof'
}

test_sequential_checks_fit_complete_cycle_bound() {
  local dir id
  dir=$(fixture sequential-checks)
  : > "$dir/state/task.meta"
  for id in first second; do
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 3' > "$dir/state/$id.check.sh"
    chmod 0700 "$dir/state/$id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
      || fail "could not register $id sequential check"
  done
  FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=2 FM_CHECK_TIMEOUT=4 run_stop "$dir" 4
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'sequential checks prevented quiet renewal'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'sequential checks were misclassified as a stalled watcher'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'sequential checks exceeded the computed cycle bound'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'sequential checks fit the computed watcher cycle bound'
}

test_sequential_task_classification_fits_complete_cycle_bound() {
  local dir id calls=0 i=0
  dir=$(fixture sequential-task-classification)
  cat > "$dir/slow-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s status\n' "$1" >> "$FM_HOME/classification-calls"
sleep 9
printf '%s runs\n' "$1" >> "$FM_HOME/classification-calls"
sleep 9
printf '%s\n' 'state: working · source: run-step · running'
SH
  chmod +x "$dir/slow-crew-state.sh"
  for id in first second third; do
    printf '%s\n' 'kind=ship' > "$dir/state/$id.meta"
    printf '%s\n' 'working: initial signal state' > "$dir/state/$id.status"
    prime_status_seen "$dir/state" "$dir/state/$id.status"
  done
  : > "$dir/classification-calls"
  FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 \
    FM_CREW_STATE_NM_TIMEOUT=10 FM_CREW_STATE_BIN="$dir/slow-crew-state.sh" \
    run_stop "$dir" 120
  wait_file "$dir/state/.watch.lock/pid"
  for id in first second third; do
    printf '%s\n' 'working: bounded classification changed' > "$dir/state/$id.status"
  done
  while [ "$i" -lt 1200 ]; do
    calls=$(wc -l < "$dir/classification-calls" 2>/dev/null || echo 0)
    [ "$calls" -ge 6 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$calls" -ge 6 ] || fail 'watcher did not run both bounded classification paths for three changed tasks'
  printf '%s\n' 'done: classification cycle complete' > "$dir/state/first.status"
  wait_file "$dir/rc" 750
  [ "$(cat "$dir/rc")" = 2 ] || fail 'sequential task classification lost its actionable wake'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'sequential task classification did not deliver its queued wake'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'sequential task classification exceeded the computed cycle bound'
  [ -s "$dir/state/.wake-queue" ] || fail 'sequential task classification did not retain its actionable wake'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'sequential task classification fits the computed watcher cycle bound'
}

test_retired_status_history_does_not_consume_cycle_budget() {
  local dir original_root=$TEST_ROOT id
  dir=$(fixture retired-status-history)
  install_controlled_watcher "$dir"
  printf '%s\n' 'window=fm-active:1.1' > "$dir/state/task.meta"
  for id in $(seq 1 15); do
    printf '%s\n' 'done: retained history' > "$dir/state/retired-$id.status"
    prime_status_seen "$dir/state" "$dir/state/retired-$id.status"
  done
  FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=300 TEST_ROOT="$dir" run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release retained-history fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'retained status history blocked the Codex Stop watcher'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'retained status history prevented watcher startup'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'retired status history consumed the active cycle budget'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'retired status history does not consume active cycle budget'
}

test_fresh_checks_do_not_consume_cycle_budget() {
  local dir original_root=$TEST_ROOT id
  dir=$(fixture fresh-check-history)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  for id in $(seq 1 12); do
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$dir/state/check-$id.check.sh"
    chmod 0700 "$dir/state/check-$id.check.sh"
  done
  touch "$dir/state/.last-check"
  FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 FM_CHECK_TIMEOUT=30 \
    TEST_ROOT="$dir" run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release fresh-check fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'fresh checks blocked the Codex Stop watcher'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'fresh checks prevented watcher startup'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'not-due checks consumed the active cycle budget'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'only due checks consume the active cycle budget'
}

test_large_stale_endpoint_inventory_does_not_consume_cycle_budget() {
  local dir original_root=$TEST_ROOT id existing
  dir=$(fixture stale-endpoint-inventory)
  install_controlled_watcher "$dir"
  install_endpoint_inventory_tmux "$dir"
  for id in $(seq 1 100); do
    printf 'window=fleet:dead-%s\n' "$id" > "$dir/state/dead-$id.meta"
  done
  printf '%s\n' 'window=fleet:live-a' > "$dir/state/live-a.meta"
  printf '%s\n' 'window=fleet:live-b' > "$dir/state/live-b.meta"
  printf '%s\n' 'window=fleet:live-c' > "$dir/state/live-c.meta"
  existing='fleet:live-a fleet:live-b fleet:live-c'
  for id in $(seq 1 10); do
    existing="$existing fleet:dead-$id"
  done
  for id in $(seq 1 12); do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/state/check-$id.check.sh"
    chmod 0700 "$dir/state/check-$id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "check-$id" >/dev/null \
      || fail "could not register stale-inventory check $id"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$existing" \
    FM_TEST_LIVE_TARGETS='fleet:live-a fleet:live-b fleet:live-c' \
    FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 TEST_ROOT="$dir" run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release stale-endpoint inventory fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'stale endpoint history blocked the Codex Stop watcher'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'stale endpoint history prevented watcher startup'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'absent historical endpoints consumed the live cycle budget'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'large stale endpoint history does not consume the live cycle budget'
}

test_small_live_endpoint_inventory_remains_bounded() {
  local dir id
  dir=$(fixture live-endpoint-inventory)
  install_endpoint_inventory_tmux "$dir"
  for id in first second; do
    printf 'window=fleet:%s\n' "$id" > "$dir/state/$id.meta"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:first fleet:second' \
    FM_TEST_LIVE_TARGETS='fleet:first' FM_TEST_AMBIGUOUS_TARGETS='fleet:second' \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=10 FM_CREW_STATE_NM_TIMEOUT=100 \
    FM_WORKTREE_WRITE_TIMEOUT=100 run_stop "$dir" 180
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'live endpoint work escaped the fixed Stop deadline'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'live endpoints were omitted from the cycle budget'
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'oversized live endpoint cycle started a watcher'
  finish "$dir"
  pass 'small live endpoint inventories remain conservatively bounded'
}

test_failed_existence_probe_is_conservatively_budgeted() {
  local dir
  dir=$(fixture uncertain-endpoint-inventory)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:uncertain' > "$dir/state/uncertain.meta"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:uncertain' \
    FM_TEST_LIVE_TARGETS='fleet:uncertain' FM_TEST_EXISTENCE_PROBE_FAILURES='fleet:uncertain' \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=10 FM_CREW_STATE_NM_TIMEOUT=200 \
    FM_WORKTREE_WRITE_TIMEOUT=200 run_stop "$dir" 4
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 2 ] || fail 'uncertain endpoint escaped the fixed Stop deadline'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'failed existence probe was treated as authoritative death'
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'uncertain endpoint inventory started an under-budgeted watcher'
  finish "$dir"
  pass 'failed existence probes remain conservatively budgeted'
}

test_many_dead_endpoints_take_cheap_watcher_path() {
  local dir id existing= key pane_hash
  dir=$(fixture retained-dead-endpoints)
  install_endpoint_inventory_tmux "$dir"
  cat > "$dir/slow-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/crew-state-calls"
sleep 1
printf '%s\n' 'state: stopped · source: pane · bare shell'
SH
  chmod +x "$dir/slow-crew-state.sh"
  pane_hash=$(hash_text 'retained dead pane')
  for id in $(seq 1 25); do
    printf 'window=fleet:dead-%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$id" \
      > "$dir/state/dead-$id.meta"
    if [ "$id" -lt 25 ]; then
      printf '%s\n' 'paused: retained completed worker' > "$dir/state/dead-$id.status"
    else
      printf '%s\n' 'working: agent exited without a terminal event' > "$dir/state/dead-$id.status"
    fi
    prime_status_seen "$dir/state" "$dir/state/dead-$id.status"
    key="fleet_dead-$id"
    printf '%s' "$pane_hash" > "$dir/state/.hash-$key"
    printf '%s\n' 1 > "$dir/state/.count-$key"
    existing="$existing fleet:dead-$id"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$existing" \
    FM_TEST_CAPTURE='retained dead pane' FM_CREW_STATE_BIN="$dir/slow-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_stop "$dir" 4
  wait_file "$dir/rc" 300
  [ "$(cat "$dir/rc")" = 2 ] || fail 'retained dead endpoint inventory escaped Stop supervision'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'retained dead endpoint inventory lost the required dead-worker notification'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'retained dead endpoints reached unbudgeted watcher work'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'retained dead endpoints recreated the admission refusal'
  grep -F "$(printf '\tstale\tfleet:dead-25\tstale: fleet:dead-25')" "$dir/state/.wake-queue" >/dev/null \
    || fail 'authoritatively dead worker did not retain its stale notification'
  [ ! -e "$dir/crew-state-calls" ] || fail 'authoritatively dead targets reached expensive crew-state classification'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'retained dead endpoints stay cheap and preserve notification'
}

test_dead_endpoint_preserves_inbox_escalation() {
  local dir rec
  dir=$(fixture dead-endpoint-inbox)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:dead-inbox' 'kind=ship' 'harness=grok' 'backend=tmux' \
    > "$dir/state/dead-inbox.meta"
  printf '%s\n' 'working: awaiting durable steer' > "$dir/state/dead-inbox.status"
  prime_status_seen "$dir/state" "$dir/state/dead-inbox.status"
  printf '%s' authoritatively-dead > "$dir/state/.stale-fleet_dead-inbox"
  rec=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" dead-inbox "respond to the captain"
  ' _ "$ROOT/bin" "$dir/state") || fail 'could not create dead-target inbox record'
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:dead-inbox' \
    FM_TEST_CAPTURE_LOG="$dir/capture-calls" FM_TASK_INBOX_GRACE_SECS=0 \
    FM_TASK_INBOX_RING_MAX=1 FM_SIGNAL_GRACE=0 run_stop "$dir" 10
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'dead-target inbox escalation escaped Stop supervision'
  grep -qF "unread firstmate instruction: $rec" "$dir/state/.wake-queue" \
    || fail 'dead-target inbox record did not escalate durably'
  [ ! -e "$dir/capture-calls" ] || fail 'dead-target inbox escalation captured the pane'
  [ "$(cat "$dir/state/dead-inbox.inbox/.escalated")" = 001.msg ] \
    || fail 'dead-target inbox escalation did not persist its dedup marker'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'dead endpoints retain inbox escalation without pane work'
}

test_dead_endpoint_migrates_matching_stale_marker() {
  local dir pane_hash
  dir=$(fixture dead-endpoint-marker-migration)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:dead-history' 'kind=ship' 'harness=grok' 'backend=tmux' \
    > "$dir/state/dead-history.meta"
  printf '%s\n' 'working: historical stopped worker' > "$dir/state/dead-history.status"
  prime_status_seen "$dir/state" "$dir/state/dead-history.status"
  pane_hash=$(hash_text 'historical dead pane')
  printf '%s' "$pane_hash" > "$dir/state/.stale-fleet_dead-history"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:dead-history' \
    FM_TEST_CAPTURE='historical dead pane' FM_TEST_CAPTURE_LOG="$dir/capture-calls" \
    FM_SIGNAL_GRACE=0 run_stop "$dir" 2
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'matching historical marker escaped Stop supervision'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'matching historical marker emitted another death wake'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'matching historical marker queued a duplicate death notification'
  [ "$(cat "$dir/state/.stale-fleet_dead-history")" = authoritatively-dead ] \
    || fail 'matching historical marker was not migrated'
  [ "$(wc -l < "$dir/capture-calls")" -eq 1 ] || fail 'historical marker migration was not a single cheap capture'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'matching historical death markers migrate without duplicate wakes'
}

test_due_custom_and_pr_checks_remain_bounded() {
  local dir id custom_runs pr_runs
  dir=$(fixture due-custom-and-pr-checks)
  mkdir "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/pr-check-runs"
printf '%s\n' OPEN
SH
  chmod +x "$dir/fakebin/gh"
  for id in $(seq 1 6); do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s\\n' 'custom-$id' >> \"\$FM_HOME/custom-check-runs\"" \
      > "$dir/state/a-custom-$id.check.sh"
    chmod 0700 "$dir/state/a-custom-$id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "a-custom-$id" >/dev/null \
      || fail "could not register due custom check fixture $id"
  done
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-pr-lib.sh"
    for number in $(seq 1 6); do
      id="m-pr-$number"
      url="https://github.com/example/project/pull/$number"
      printf "pr=%s\n" "$url" > "$2/$id.meta" || exit 1
      fm_pr_poll_prepare "$2" "$id" github "$url" github.com example/project \
        "$number" "$1/fm-pr-poll.sh" || exit 1
      fm_pr_poll_publish_prepared || exit 1
    done
  ' _ "$ROOT/bin" "$dir/state" || fail 'could not register due PR check fixture'
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' control >> \"\$FM_HOME/custom-check-runs\"" \
    "printf '%s\\n' ready" > "$dir/state/z-ready.check.sh"
  chmod 0700 "$dir/state/z-ready.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" z-ready >/dev/null \
    || fail 'could not register final due custom check fixture'
  PATH="$dir/fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=10 \
    FM_CHECK_TIMEOUT=30 run_stop "$dir" 180
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'bounded due custom and PR checks lost their actionable wake'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'due registered checks were still charged as one unbounded sweep'
  [ -s "$dir/state/.wake-queue" ] || fail 'bounded registered-check sweep lost its actionable result'
  custom_runs=$(wc -l < "$dir/custom-check-runs")
  pr_runs=$(wc -l < "$dir/pr-check-runs")
  [ "$custom_runs" -eq 7 ] || fail "bounded sweep ran $custom_runs of 7 custom checks"
  [ "$pr_runs" -eq 6 ] || fail "bounded sweep ran $pr_runs of 6 PR checks"
  [ ! -e "$dir/state/.check-sweep-cursor" ] || fail 'completed bounded check sweep retained its cursor'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'due custom and PR checks complete across bounded watcher cycles'
}

test_actionable_checks_resume_bounded_sweep() {
  local dir state rc
  dir=$(fixture actionable-check-resume)
  state="$dir/state"
  mkdir "$dir/fakebin"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' pr >> "$FM_HOME/check-runs"
printf '%s\n' MERGED
SH
  chmod +x "$dir/fakebin/gh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' recurring >> \"\$FM_HOME/check-runs\"" \
    "printf '%s\\n' ready" > "$state/a-recurring.check.sh"
  chmod 0700 "$state/a-recurring.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" a-recurring >/dev/null \
    || fail 'could not register recurring actionable check'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/fm-pr-lib.sh"
    url=https://github.com/example/project/pull/1
    printf "pr=%s\n" "$url" > "$2/b-pr.meta" || exit 1
    fm_pr_poll_prepare "$2" b-pr github "$url" github.com example/project 1 \
      "$1/fm-pr-poll.sh" || exit 1
    fm_pr_poll_publish_prepared
  ' _ "$ROOT/bin" "$state" || fail 'could not register merged PR poll'
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' tail >> \"\$FM_HOME/check-runs\"" > "$state/z-tail.check.sh"
  chmod 0700 "$state/z-tail.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" z-tail >/dev/null \
    || fail 'could not register trailing silent check'

  set +e
  run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "recurring actionable cycle failed: $(cat "$dir/watch-1.err")"
  [ "$(cat "$state/.check-sweep-cursor")" = a-recurring.check.sh ] \
    || fail 'recurring actionable check did not persist sweep progress'
  [ ! -e "$state/.last-check" ] || fail 'recurring actionable check delayed its incomplete sweep'
  ack_watcher_cycle "$state" >/dev/null || fail 'could not acknowledge recurring actionable wake'

  set +e
  run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged PR cycle failed: $(cat "$dir/watch-2.err")"
  [ ! -e "$state/b-pr.check.sh" ] || fail 'merged PR poll was not retired'
  [ "$(cat "$state/.check-sweep-cursor")" = b-pr.check.sh ] \
    || fail 'retired merged PR poll did not persist sweep progress'
  [ ! -e "$state/.last-check" ] || fail 'merged PR result delayed its incomplete sweep'
  ack_watcher_cycle "$state" >/dev/null || fail 'could not acknowledge merged PR wake'

  set +e
  run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-3.out" 2> "$dir/watch-3.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "trailing silent cycle ended unexpectedly: rc=$rc $(cat "$dir/watch-3.err")"
  [ "$(cat "$dir/check-runs")" = $'recurring\npr\ntail' ] \
    || fail "bounded sweep did not advance fairly: $(cat "$dir/check-runs")"
  [ ! -e "$state/.check-sweep-cursor" ] || fail 'completed resumed sweep retained its cursor'
  [ -e "$state/.last-check" ] || fail 'completed resumed sweep did not restore its cadence'
  pass 'actionable custom and merged checks resume bounded sweeps fairly'
}

test_due_remote_recovery_fits_cycle_budget() {
  local dir original_root=$TEST_ROOT corr
  dir=$(fixture due-remote-recovery)
  cp -R "$ROOT/bin/." "$dir/bin/"
  install_controlled_watcher "$dir"
  printf '%s\n' 'remote_host=fixture.invalid' > "$dir/state/remote-task.meta"
  corr=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 \
    FM_PENDING_REPLY_GRACE_SECS=0 bash -c '
      . "$1/fm-pending-reply-lib.sh"
      corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" remote-task "report status") || exit 1
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 900 || exit 1
      rec=$(fm_pending_reply_path "$FM_STATE_OVERRIDE" "$corr")
      fm_pending_reply_set "$rec" request_turn_completed_epoch 950 || exit 1
      fm_pending_reply_note_remote_channel_caught_up "$FM_STATE_OVERRIDE" remote-task 1000 || exit 1
      printf "%s" "$corr"
    ' _ "$dir/bin") || fail 'could not create due remote recovery fixture'
  printf '%s\n' "$corr" > "$dir/pending-corr"
  cat > "$dir/recovery-hook.sh" <<'SH'
#!/usr/bin/env bash
sleep 20
. "$TEST_ROOT/bin/fm-wake-lib.sh"
fm_wake_append check remote-recovery 'check: bounded remote recovery completed'
SH
  chmod +x "$dir/recovery-hook.sh"
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 FM_SEND_REMOTE_BUDGET=20 \
    FM_PENDING_REPLY_NOW=1000 FM_TEST_WATCH_MODE=pending-recovery \
    FM_PENDING_REPLY_SEND_HOOK='"$FM_HOME/recovery-hook.sh"' \
    TEST_ROOT="$dir" run_stop "$dir" 45
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 350
  [ "$(cat "$dir/rc")" = 2 ] || fail 'due remote recovery escaped Codex Stop supervision'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'due remote recovery did not deliver its wake'
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'due remote recovery exceeded the computed cycle budget'
  [ -s "$dir/state/.wake-queue" ] || fail 'due remote recovery wake was not retained'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'due remote recovery fits the computed watcher cycle budget'
}

test_codex_defers_remote_pending_reply_observation() {
  local dir original_root=$TEST_ROOT corr
  dir=$(fixture deferred-remote-observation)
  cp -R "$ROOT/bin/." "$dir/bin/"
  install_controlled_watcher "$dir"
  cat > "$dir/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/remote-observe-calls"
printf '%s\n' idle
SH
  chmod +x "$dir/bin/fm-on.sh"
  printf '%s\n' 'remote_host=fixture.invalid' 'harness=claude' 'window=fm-remote:1.1' \
    > "$dir/state/remote-task.meta"
  corr=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 \
    bash -c '
      . "$1/fm-pending-reply-lib.sh"
      corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" remote-task "report status") || exit 1
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000 || exit 1
      printf "%s" "$corr"
    ' _ "$dir/bin") || fail 'could not create remote observation fixture'
  [ -n "$corr" ] || fail 'remote observation fixture omitted its correlation'
  FM_PENDING_REPLY_NOW=1000 FM_TEST_WATCH_MODE=pending-tick TEST_ROOT="$dir" run_stop "$dir" 30
  TEST_ROOT=$original_root
  wait_file "$dir/rc"
  [ ! -e "$dir/remote-observe-calls" ] || fail 'Codex Stop synchronously observed a remote pending reply'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'deferred remote observation lost the local watcher wake'
  finish "$dir"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 \
    bash -c '. "$1/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2"' \
    _ "$dir/bin" "$dir/state"
  [ -s "$dir/remote-observe-calls" ] || fail 'default Claude pending-reply behavior stopped observing remote records'
  pass 'Codex defers remote observation while Claude default remains unchanged'
}

test_cycle_budget_scans_are_throttled() {
  local dir original_root=$TEST_ROOT scans
  dir=$(fixture throttled-cycle-scans)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import os


original_listdir = os.listdir


def tracked_listdir(path='.'):
    result = original_listdir(path)
    if path == '.' and os.path.samefile(os.getcwd(), os.path.join(os.environ['FM_HOME'], 'state')):
        with open(os.path.join(os.environ['FM_HOME'], 'cycle-budget-scans'), 'a') as stream:
            stream.write('scan\n')
    return result


os.listdir = tracked_listdir
PY
  PYTHONPATH="$dir/fault" FM_SIGNAL_GRACE=0 TEST_ROOT="$dir" run_stop "$dir" 4
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 200
  scans=$(wc -l < "$dir/cycle-budget-scans")
  [ "$scans" -le 12 ] || fail "cycle budget was rescanned $scans times during a four-second checkpoint"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'throttled cycle scans prevented quiet renewal'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'throttled cycle scans lost quiet renewal'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'cycle budget scans stay on the throttled probe boundary'
}

test_large_check_inventory_is_batched_before_transport_deadline() {
  local dir original_root=$TEST_ROOT id
  dir=$(fixture oversized-cycle)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  for id in $(seq 1 21); do
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 30' > "$dir/state/check-$id.check.sh"
    chmod 0700 "$dir/state/check-$id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "check-$id" >/dev/null \
      || fail "could not register oversized-cycle check $id"
  done
  FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 FM_CHECK_TIMEOUT=30 TEST_ROOT="$dir" \
    run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release large-check inventory fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'large registered-check inventory lost Codex Stop supervision'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'large registered-check inventory prevented watcher startup'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'large registered-check inventory was charged as one unbounded sweep'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'large registered-check inventories are admitted in bounded batches'
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

test_reaped_uncertain_group_is_not_signalled() {
  local dir original_root=$TEST_ROOT sentinel
  dir=$(fixture uncertain-arm-group)
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh,fm-backend.sh} "$dir/bin/"
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/uncertain-arm-pid"
exit 1
ARM
  chmod +x "$dir/bin/fm-watch-arm.sh"
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import os
import signal


original_killpg = os.killpg


def reused_group(group, signum):
    home = os.environ.get('FM_HOME', '')
    try:
        with open(os.path.join(home, 'uncertain-arm-pid')) as stream:
            arm = int(stream.read().strip())
    except (OSError, ValueError):
        return original_killpg(group, signum)
    if group != arm:
        return original_killpg(group, signum)
    with open(os.path.join(home, 'uncertain-group-signalled'), 'a') as stream:
        stream.write(str(signum) + '\n')
    if signum:
        with open(os.path.join(home, 'sentinel-pid')) as stream:
            os.kill(int(stream.read().strip()), signal.SIGTERM)


os.killpg = reused_group
PY
  sleep 60 & sentinel=$!
  printf '%s\n' "$sentinel" > "$dir/sentinel-pid"
  : > "$dir/state/task.meta"
  PYTHONPATH="$dir/fault" TEST_ROOT="$dir" run_stop "$dir" 15
  TEST_ROOT=$original_root
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'uncertain arm group allowed Stop to fail open'
  [ ! -e "$dir/uncertain-group-signalled" ] || fail 'adapter signalled a reaped group without identity-bound ownership'
  kill -0 "$sentinel" 2>/dev/null || fail 'adapter signalled the unrelated reused-group sentinel'
  kill -TERM "$sentinel"; wait "$sentinel" 2>/dev/null || true
  finish "$dir"
  pass 'reaped uncertain process groups remain untouched'
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

test_generation_change_rejects_continuation_commit() {
  local dir
  dir=$(fixture rejected-commit)
  append_wake "$dir/state" check rejected-commit 'check: retained event'
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import os
import socket


original_socket = socket.socket


class TrackingSocket(original_socket):
    def sendall(self, data, *args, **kwargs):
        result = super().sendall(data, *args, **kwargs)
        if b'"accepted": true' in data:
            with open(os.path.join(os.environ['FM_HOME'], 'state', '.lock'), 'w') as stream:
                stream.write('99999999\n')
            with open(os.path.join(os.environ['FM_HOME'], 'generation-replaced'), 'w') as stream:
                stream.write('yes\n')
        return result


socket.socket = TrackingSocket
PY
  PYTHONPATH="$dir/fault" run_stop "$dir"
  wait_file "$dir/generation-replaced"
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 0 ] || fail 'rejected continuation commit still requested a Codex turn'
  for _ in $(seq 1 60); do [ ! -e "$dir/state/.codex-stop.json" ] && break; sleep 0.1; done
  [ ! -e "$dir/state/.codex-stop.json" ] || fail 'rejected continuation commit retained handling ownership'
  [ -s "$dir/state/.wake-queue" ] || fail 'rejected continuation commit acknowledged queued work'
  finish "$dir"
  pass 'generation replacement rejects the continuation commit before exit 2'
}

test_outer_interruption_preserves_confirmed_commit() {
  local dir hook
  dir=$(fixture confirmed-commit-interruption)
  append_wake "$dir/state" check confirmed-commit 'check: retained event'
  mkdir "$dir/fault"
  cat > "$dir/fault/sitecustomize.py" <<'PY'
import os
import socket
import time


original_socket = socket.socket


class TrackingSocket(original_socket):
    def sendall(self, data, *args, **kwargs):
        result = super().sendall(data, *args, **kwargs)
        if b'"op": "commit"' in data:
            with open(os.path.join(os.environ['FM_HOME'], 'commit-sent'), 'w') as stream:
                stream.write('yes\n')
            time.sleep(5)
        return result


socket.socket = TrackingSocket
PY
  PYTHONPATH="$dir/fault" run_stop "$dir"
  wait_file "$dir/commit-sent"
  hook=$(cat "$dir/hook")
  kill -TERM "$hook"
  wait_file "$dir/rc" 100
  [ "$(cat "$dir/rc")" = 2 ] || fail 'outer interruption discarded a confirmed continuation commit'
  [ "$(jq -r .phase "$dir/state/.codex-stop.json")" = handling ] || fail 'confirmed continuation commit did not retain handling ownership'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" || fail 'confirmed interrupted commit did not remain healthy'
  [ -s "$dir/state/.wake-queue" ] || fail 'confirmed interrupted commit acknowledged queued work'
  finish "$dir"
  pass 'outer interruption preserves an owner-confirmed continuation commit'
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
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-hook-host-lib.sh,fm-backend.sh} "$dir/bin/"
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
test_attached_arm_uses_complete_cycle_grace
test_attached_arm_rejects_unproven_bounded_mode
test_sequential_checks_fit_complete_cycle_bound
test_sequential_task_classification_fits_complete_cycle_bound
test_retired_status_history_does_not_consume_cycle_budget
test_fresh_checks_do_not_consume_cycle_budget
test_large_stale_endpoint_inventory_does_not_consume_cycle_budget
test_small_live_endpoint_inventory_remains_bounded
test_failed_existence_probe_is_conservatively_budgeted
test_many_dead_endpoints_take_cheap_watcher_path
test_dead_endpoint_preserves_inbox_escalation
test_dead_endpoint_migrates_matching_stale_marker
test_due_custom_and_pr_checks_remain_bounded
test_actionable_checks_resume_bounded_sweep
test_due_remote_recovery_fits_cycle_budget
test_codex_defers_remote_pending_reply_observation
test_cycle_budget_scans_are_throttled
test_large_check_inventory_is_batched_before_transport_deadline
test_dead_arm_launcher_retires_owned_watcher_group
test_reaped_uncertain_group_is_not_signalled
test_final_source_wake_retains_continuation
test_cleanup_cancellation_revokes_handling
test_singleton

test_expired_successor_requires_replacement_generation
test_health_challenge_rejects_replaced_generation
test_post_accept_interruption_revokes_owner
test_generation_change_rejects_continuation_commit
test_outer_interruption_preserves_confirmed_commit
test_same_process_session_replacement_hands_off
test_uncertain_session_inert

test_identity_mismatch_fails_closed_and_reaps_owned_group

test_reused_or_uncertain_owner_is_reclaimed
test_native_continuation_commit_is_serialized
test_record_transition_fails_closed_and_recovers_identity
test_replacement_session_fails_closed_on_old_owner
test_record_mutation_interruption_clears_ownership
