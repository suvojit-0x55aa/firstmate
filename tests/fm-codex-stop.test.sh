#!/usr/bin/env bash
# Execute the synchronous Codex Stop owner against real watcher processes.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-stop)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
STOP_PID=
STOP_PID_TWO=
cleanup_test() {
  [ -z "$STOP_PID" ] || kill -TERM "$STOP_PID" 2>/dev/null || true
  [ -z "$STOP_PID" ] || wait "$STOP_PID" 2>/dev/null || true
  [ -z "$STOP_PID_TWO" ] || kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  [ -z "$STOP_PID_TWO" ] || wait "$STOP_PID_TWO" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_test EXIT
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/fakebin"
  ln -s "$ROOT/bin" "$dir/bin"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  : > "$dir/state/work.meta"
  printf '%s\n' $$ > "$dir/state/.lock"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for arg in "$@"; do
  [ "$previous" != -p ] || pid=$arg
  previous=$arg
done
if [ "$pid" = "$FM_TEST_CODEX_OWNER" ]; then
  case "$*" in *comm=*) echo codex; exit ;; *args=*) echo codex; exit ;; esac
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"
  printf '%s\n' "$dir"
}
run_stop() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" "$ROOT/bin/fm-codex-stop.sh"
}
run_stop_generation() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" \
    bash -c 'printf "%s\n" "$$" > "$1/state/.lock"; export FM_TEST_CODEX_OWNER=$$; exec "$2/bin/fm-codex-stop.sh"' \
    _ "$dir" "$ROOT"
}
await_lock() {
  local dir=$1 n=0
  while [ "$n" -lt 100 ]; do
    if FM_HOME="$dir" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$2/state" "$1/bin/fm-watch.sh" 300 "$2"' _ "$ROOT" "$dir"; then
      return 0
    fi
    sleep 0.05
    n=$((n+1))
  done
  fail 'Stop never acquired healthy identity-matched watcher ownership'
}

dir=$(make_home quiet)
rc=0
run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
expect_code 2 "$rc" 'quiet expiry must request native continuation'
assert_contains "$(cat "$dir/out")" 'checkpoint: quiet' 'quiet interval was silently abandoned'
assert_absent "$dir/state/.watch.lock/pid" 'quiet Stop left an owned watcher behind'
pass 'quiet expiry requests the next Codex turn rather than silently ending supervision'

dir=$(make_home signal)
TEST_BUDGET=12 run_stop "$dir" > "$dir/out" 2>&1 &
STOP_PID=$!
await_lock "$dir"
owner=$(cat "$dir/state/.watch.lock/pid")
rc=0
run_stop "$dir" > "$dir/duplicate" 2>&1 || rc=$?
expect_code 0 "$rc" 'duplicate Stop must attach to no second owner'
[ "$(cat "$dir/state/.watch.lock/pid")" = "$owner" ] || fail "duplicate replaced watcher: before=$owner after=$(cat "$dir/state/.watch.lock/pid") $(cat "$dir/out") / $(cat "$dir/duplicate")"
printf 'done: article PR ready\n' > "$dir/state/article.status"
rc=0
wait "$STOP_PID" || rc=$?
STOP_PID=
expect_code 2 "$rc" 'actionable return must request native continuation'
assert_contains "$(cat "$dir/out")" 'signal:' 'post-Stop event was not delivered'
assert_grep 'article.status' "$dir/state/.wake-queue" 'Stop consumed the durable event before handling'
drain=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
  "$ROOT/bin/fm-wake-drain.sh" 2>&1)
assert_not_contains "$drain" 'WATCHER DOWN - SUPERVISION IS OFF' \
  'public wake drain treated the fresh post-Stop handling window as a supervision lapse'
pass 'an event after Stop reaches continuation once; duplicate Stop preserves singleton ownership'

dir=$(make_home replacement-contention)
TEST_BUDGET=12 run_stop_generation "$dir" > "$dir/first" 2>&1 &
STOP_PID=$!
await_lock "$dir"
first_owner=$(cat "$dir/state/.codex-stop.lock/pid")
TEST_BUDGET=12 run_stop_generation "$dir" > "$dir/replacement" 2>&1 &
STOP_PID_TWO=$!
n=0
replacement_observed=0
while [ "$n" -lt 160 ]; do
  replacement_owner=$(cat "$dir/state/.codex-stop.lock/pid" 2>/dev/null || true)
  session_owner=$(cat "$dir/state/.lock" 2>/dev/null || true)
  if [ -n "$replacement_owner" ] && [ "$replacement_owner" != "$first_owner" ] \
    && [ "$replacement_owner" = "$session_owner" ] \
    && FM_HOME="$dir" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$2/state" "$1/bin/fm-watch.sh" 300 "$2"' _ "$ROOT" "$dir"; then
    replacement_observed=1
    break
  fi
  grep -Fq 'Run bin/fm-wake-drain.sh' "$dir/replacement" 2>/dev/null && break
  kill -0 "$STOP_PID_TWO" 2>/dev/null || break
  sleep 0.05
  n=$((n+1))
done
[ "$n" -lt 160 ] || fail "replacement Stop did not acquire supervision after predecessor contention: first=$(cat "$dir/first") replacement=$(cat "$dir/replacement") stop-owner=$(cat "$dir/state/.codex-stop.lock/pid" 2>/dev/null || true) session-owner=$(cat "$dir/state/.lock" 2>/dev/null || true)"
[ "$replacement_observed" -eq 0 ] || printf 'done: replacement article ready\n' > "$dir/state/replacement.status"
first_rc=0
wait "$STOP_PID" || first_rc=$?
STOP_PID=
replacement_rc=0
wait "$STOP_PID_TWO" || replacement_rc=$?
STOP_PID_TWO=
expect_code 0 "$first_rc" 'replaced predecessor must stand down'
expect_code 2 "$replacement_rc" 'replacement Stop must retain native continuation'
assert_contains "$(cat "$dir/replacement")" 'Run bin/fm-wake-drain.sh' \
  'replacement Stop ended blind after contention'
assert_absent "$dir/state/.watch.lock/pid" 'replacement contention left watcher ownership behind'
pass 'replacement Stop takes over after predecessor lock contention'

dir=$(make_home cancelled)
TEST_BUDGET=12 run_stop "$dir" > "$dir/out" 2>&1 &
STOP_PID=$!
await_lock "$dir"
# Target the public Stop process, not the test function wrapper.
stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
kill -TERM "$stop_owner"
wait "$STOP_PID" || true
STOP_PID=
sleep 1
assert_absent "$dir/state/.watch.lock/pid" 'deliberate stop left its watcher alive'
assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' 'deliberate stop emitted a resurrection prompt'
pass 'deliberate Stop cancellation reaps only its owned watcher and emits no continuation'

dir=$(make_home replacement)
TEST_BUDGET=12 run_stop "$dir" > "$dir/out" 2>&1 &
STOP_PID=$!
await_lock "$dir"
printf '999999\n' > "$dir/state/.lock"
wait "$STOP_PID" || true
STOP_PID=
assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' 'replaced session emitted a continuation'
assert_absent "$dir/state/.watch.lock/pid" 'replaced session retained watcher ownership'
pass 'session replacement stands down without touching the successor session'
