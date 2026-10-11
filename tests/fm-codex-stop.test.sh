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
run_stop_trappable() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" \
    FM_TEST_CODEX_FINAL_MARKER="${FM_TEST_CODEX_FINAL_MARKER:-}" \
    FM_TEST_CODEX_FINAL_RELEASE="${FM_TEST_CODEX_FINAL_RELEASE:-}" \
    FM_TEST_REAL_GREP="${FM_TEST_REAL_GREP:-}" \
    perl -e '$SIG{HUP}="DEFAULT"; $SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
      "$ROOT/bin/fm-codex-stop.sh"
}
install_final_barrier() {
  local dir=$1 real_grep
  real_grep=$(command -v grep)
  cat > "$dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
matched=0
for arg in "$@"; do
  [ "$arg" != '^(signal:|stale:|check:|heartbeat($|:))' ] || matched=1
done
if [ "$matched" = 1 ] && [ -n "${FM_TEST_CODEX_FINAL_MARKER:-}" ]; then
  : > "$FM_TEST_CODEX_FINAL_MARKER"
  n=0
  while [ ! -e "$FM_TEST_CODEX_FINAL_RELEASE" ] && [ "$n" -lt 500 ]; do
    sleep 0.01
    n=$((n + 1))
  done
  [ -e "$FM_TEST_CODEX_FINAL_RELEASE" ] || exit 124
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$dir/fakebin/grep"
  printf '%s\n' "$real_grep" > "$dir/real-grep"
}
await_file() {
  local path=$1 n=0
  while [ "$n" -lt 400 ]; do
    [ ! -e "$path" ] || return 0
    sleep 0.01
    n=$((n + 1))
  done
  fail "timed out waiting for $path"
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

test_final_cancellation_revokes_handling() {
  local signal dir marker release stop_owner rc guard continuation_identity replacement_pid replacement_identity
  for signal in HUP INT TERM; do
    dir=$(make_home "final-cancel-$signal")
    install_final_barrier "$dir"
    marker="$dir/final.marker"
    release="$dir/final.release"
    rc=0
    TEST_BUDGET=1 FM_TEST_CODEX_FINAL_MARKER="$marker" \
      FM_TEST_CODEX_FINAL_RELEASE="$release" FM_TEST_REAL_GREP="$(cat "$dir/real-grep")" \
      run_stop_trappable "$dir" > "$dir/out" 2>&1 &
    STOP_PID=$!
    await_file "$marker"
    assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
      "$signal cancellation fixture did not reach persisted handling"
    stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
    kill -"$signal" "$stop_owner"
    : > "$release"
    wait "$STOP_PID" || rc=$?
    STOP_PID=
    expect_code 0 "$rc" "$signal cancellation did not override native continuation"
    assert_absent "$dir/state/.codex-stop-health" \
      "$signal cancellation preserved a false handling successor"
    assert_absent "$dir/state/.watch.lock/pid" \
      "$signal cancellation left its owned watcher alive"
    assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
      "$signal cancellation emitted a native continuation prompt"
    guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
      FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
    assert_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
      "public guard accepted the false handling state after $signal cancellation"
  done

  dir=$(make_home final-continuation)
  rc=0
  TEST_BUDGET=1 run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'ordinary final Stop did not schedule native continuation'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'ordinary native continuation lost its handling successor'
  continuation_identity=$(sed -n 's/^generation_identity=//p' "$dir/state/.codex-stop-health")
  [ -n "$continuation_identity" ] || fail 'ordinary native continuation lost its generation identity'
  guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
    'public guard rejected an ordinary native continuation handling window'

  dir=$(make_home final-replacement-owner)
  install_final_barrier "$dir"
  marker="$dir/final.marker"
  release="$dir/final.release"
  TEST_BUDGET=1 FM_TEST_CODEX_FINAL_MARKER="$marker" \
    FM_TEST_CODEX_FINAL_RELEASE="$release" FM_TEST_REAL_GREP="$(cat "$dir/real-grep")" \
    run_stop_trappable "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$marker"
  sleep 30 &
  STOP_PID_TWO=$!
  replacement_pid=$STOP_PID_TWO
  replacement_identity=$(FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$replacement_pid")
  printf '%s\n' "$replacement_pid" > "$dir/state/.lock"
  FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(( $(date +%s) + 300 ))" replacement' \
    _ "$ROOT" "$dir" "$replacement_pid" "$replacement_identity"
  stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
  kill -TERM "$stop_owner"
  : > "$release"
  wait "$STOP_PID" || true
  STOP_PID=
  assert_grep "generation_pid=$replacement_pid" "$dir/state/.codex-stop-health" \
    'cancelled predecessor cleared the replacement generation handling claim'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'cancelled predecessor changed the replacement generation phase'
  guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$replacement_pid \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
    'public guard rejected the preserved replacement generation handling claim'
  kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  wait "$STOP_PID_TWO" 2>/dev/null || true
  STOP_PID_TWO=
  pass 'final Stop cancellation revokes only its own false handling successor'
}

test_expired_successor_requires_replacement_generation() {
  local dir identity rc=0 guard old_pid replacement_pid
  dir=$(make_home expired-successor)
  old_pid=$$
  identity=$(FM_HOME="$dir" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' \
    _ "$ROOT" "$old_pid")
  FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(date +%s)" expired' \
    _ "$ROOT" "$dir" "$old_pid" "$identity"
  run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'expired successor must be rejected at the public Stop boundary'
  assert_contains "$(cat "$dir/out")" \
    'handling window expired before its required Stop successor' \
    'expired successor refusal omitted its actionable diagnosis'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'expired successor evidence was silently consumed'
  assert_grep 'successor_count=0' "$dir/state/.codex-stop-health" \
    'expired successor evidence changed its required successor count'
  assert_absent "$dir/state/.watch.lock/pid" 'expired successor refusal started a watcher'
  guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$old_pid \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
    'public guard accepted an expired Stop handling window'

  rc=0
  TEST_BUDGET=1 run_stop_generation "$dir" > "$dir/replacement" 2>&1 || rc=$?
  expect_code 2 "$rc" 'replacement generation did not establish its own successor'
  replacement_pid=$(sed -n 's/^generation_pid=//p' "$dir/state/.codex-stop-health")
  [ -n "$replacement_pid" ] && [ "$replacement_pid" != "$old_pid" ] \
    || fail 'replacement generation reused expired predecessor identity'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'replacement generation did not open a handling window'
  assert_grep 'successor_count=0' "$dir/state/.codex-stop-health" \
    'replacement generation did not require exactly one successor'
  pass 'expired Stop successor fails closed until a replacement generation'
}

test_afk_handoff_clears_owned_successor() {
  local timing dir identity expires rc output replacement_pid replacement_identity before
  for timing in before-deadline after-deadline; do
    dir=$(make_home "afk-handoff-$timing")
    identity=$(FM_HOME="$dir" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' \
      _ "$ROOT" $$)
    case "$timing" in
      before-deadline) expires=$(( $(date +%s) + 300 )) ;;
      after-deadline) expires=$(date +%s) ;;
    esac
    FM_HOME="$dir" bash -c \
      '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$5" afk-handoff' \
      _ "$ROOT" "$dir" $$ "$identity" "$expires"
    : > "$dir/state/.afk"
    rc=0
    run_stop "$dir" > "$dir/away.out" 2>&1 || rc=$?
    expect_code 0 "$rc" "$timing away handoff did not stand down cleanly"
    assert_absent "$dir/state/.codex-stop-health" \
      "$timing away handoff preserved its Stop successor claim"
    [ -e "$dir/state/.afk" ] || fail "$timing away handoff removed away supervision"
    rm "$dir/state/.afk"
    rc=0
    TEST_BUDGET=1 run_stop "$dir" > "$dir/return.out" 2>&1 || rc=$?
    expect_code 2 "$rc" "$timing return did not establish a new native continuation"
    output=$(cat "$dir/return.out")
    assert_not_contains "$output" 'handling window expired before its required Stop successor' \
      "$timing return consumed the pre-away Stop successor"
    assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
      "$timing return did not establish a fresh handling claim"
  done

  dir=$(make_home afk-handoff-replacement)
  sleep 30 &
  STOP_PID_TWO=$!
  replacement_pid=$STOP_PID_TWO
  replacement_identity=$(FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$replacement_pid")
  printf '%s\n' "$replacement_pid" > "$dir/state/.lock"
  FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(( $(date +%s) + 300 ))" afk-replacement' \
    _ "$ROOT" "$dir" "$replacement_pid" "$replacement_identity"
  : > "$dir/state/.afk"
  before=$(cat "$dir/state/.codex-stop-health")
  rc=0
  run_stop "$dir" > "$dir/replacement.out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'superseded generation did not refuse the replacement session lock'
  [ "$(cat "$dir/state/.codex-stop-health")" = "$before" ] \
    || fail 'away handoff cleared a replacement generation Stop claim'
  [ -e "$dir/state/.afk" ] || fail 'replacement generation check removed away supervision'
  kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  wait "$STOP_PID_TWO" 2>/dev/null || true
  STOP_PID_TWO=
  pass 'away handoff clears only its owned Stop successor claim'
}

case "${FM_CODEX_STOP_FOCUSED_TEST:-}" in
  expired-successor)
    test_expired_successor_requires_replacement_generation
    exit 0
    ;;
  final-cancellation)
    test_final_cancellation_revokes_handling
    exit 0
    ;;
  afk-handoff)
    test_afk_handoff_clears_owned_successor
    exit 0
    ;;
  '') ;;
  *) fail "unknown focused Codex Stop test: $FM_CODEX_STOP_FOCUSED_TEST" ;;
esac

dir=$(make_home quiet)
rc=0
run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
expect_code 2 "$rc" 'quiet expiry must request native continuation'
assert_contains "$(cat "$dir/out")" 'checkpoint: quiet' 'quiet interval was silently abandoned'
assert_absent "$dir/state/.watch.lock/pid" 'quiet Stop left an owned watcher behind'
assert_grep 'phase=handling' "$dir/state/.codex-stop-health" 'quiet Stop omitted its handling successor record'
assert_grep 'successor_count=0' "$dir/state/.codex-stop-health" 'quiet Stop did not require exactly one successor'
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

dir=$(make_home duplicate-successor)
identity=$(FM_HOME="$dir" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" $$)
FM_HOME="$dir" bash -c \
  '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 2 "$(( $(date +%s) + 300 ))" duplicate' \
  _ "$ROOT" "$dir" $$ "$identity"
rc=0
run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
expect_code 2 "$rc" 'duplicate successor evidence must be rejected'
assert_contains "$(cat "$dir/out")" 'rejected a duplicate or invalid Stop successor' \
  'duplicate successor refusal omitted its public diagnosis'
assert_absent "$dir/state/.watch.lock/pid" 'duplicate successor refusal started a watcher'
pass 'public Stop rejects duplicate successor evidence before arming'
test_expired_successor_requires_replacement_generation
test_afk_handoff_clears_owned_successor
