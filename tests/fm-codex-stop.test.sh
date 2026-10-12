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
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" "$ROOT/bin/fm-codex-stop.sh"
}
run_stop_generation() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" \
    bash -c 'printf "%s\n" "$$" > "$1/state/.lock"; export FM_TEST_CODEX_OWNER=$$; exec "$2/bin/fm-codex-stop.sh"' \
    _ "$dir" "$ROOT"
}
run_stop_trappable() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}" \
    FM_TEST_CODEX_FINAL_MARKER="${FM_TEST_CODEX_FINAL_MARKER:-}" \
    FM_TEST_CODEX_FINAL_RELEASE="${FM_TEST_CODEX_FINAL_RELEASE:-}" \
    FM_TEST_REAL_GREP="${FM_TEST_REAL_GREP:-}" \
    FM_TEST_CODEX_HANDLING_MARKER="${FM_TEST_CODEX_HANDLING_MARKER:-}" \
    FM_TEST_CODEX_HANDLING_RELEASE="${FM_TEST_CODEX_HANDLING_RELEASE:-}" \
    FM_TEST_REAL_DATE="${FM_TEST_REAL_DATE:-}" \
    FM_TEST_CODEX_COMMIT_MARKER="${FM_TEST_CODEX_COMMIT_MARKER:-}" \
    FM_TEST_CODEX_COMMIT_RELEASE="${FM_TEST_CODEX_COMMIT_RELEASE:-}" \
    perl -e '$SIG{HUP}="DEFAULT"; $SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
      "$ROOT/bin/fm-codex-stop.sh"
}
freeze_configured_stop_runtime() {
  local dir=$1
  if [ -L "$dir/bin" ]; then
    rm "$dir/bin"
    cp -R "$ROOT/bin" "$dir/runtime-bin"
    ln -s "$dir/runtime-bin" "$dir/bin"
  fi
  mkdir -p "$dir/.codex"
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  printf 'PATH="%s/fakebin:$PATH"\nexport PATH\n' "$dir" > "$dir/configured-stop.bash-env"
}
run_configured_stop() {
  local dir=$1 command
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$dir/.codex/hooks.json")
  [ -n "$command" ] || fail 'configured Codex Stop command is missing'
  (
    cd "$dir" || exit 1
    export PATH="$dir/fakebin:$PATH"
    export BASH_ENV="$dir/configured-stop.bash-env"
    export FM_TEST_CODEX_OWNER=$$
    export FM_HOME="$dir"
    export FM_ROOT_OVERRIDE="$dir"
    export FM_PROCEVENT_CLAIM_ROOT="$dir/claims"
    export FM_POLL=1
    export FM_SIGNAL_GRACE=0
    export FM_CHECK_INTERVAL=999999
    export FM_ARM_CONFIRM_TIMEOUT=3
    export FM_CODEX_WATCH_CHECKPOINT="${TEST_BUDGET:-3}"
    export FM_GUARD_GRACE="${TEST_GRACE:-300}"
    export FM_TEST_CODEX_STANDDOWN_MARKER="${FM_TEST_CODEX_STANDDOWN_MARKER:-}"
    export FM_TEST_CODEX_STANDDOWN_RELEASE="${FM_TEST_CODEX_STANDDOWN_RELEASE:-}"
    printf '{"stop_hook_active":false,"turn_id":"configured-stop"}' | bash -c "$command"
  )
}
install_standdown_barrier() {
  local dir=$1
  cat >> "$dir/configured-stop.bash-env" <<'SH'
if [ -n "${FM_TEST_CODEX_STANDDOWN_MARKER:-}" ]; then
  set -T
  fm_test_codex_standdown_barrier() {
    local marker release n=0
    [ "$BASH_COMMAND" = 'fm_supervision_needed "$STATE" "$GRACE"' ] || return 0
    marker=$FM_TEST_CODEX_STANDDOWN_MARKER
    release=$FM_TEST_CODEX_STANDDOWN_RELEASE
    unset FM_TEST_CODEX_STANDDOWN_MARKER
    trap - DEBUG
    : > "$marker"
    while [ ! -e "$release" ] && [ "$n" -lt 500 ]; do
      sleep 0.01
      n=$((n + 1))
    done
    [ -e "$release" ] || exit 124
  }
  trap fm_test_codex_standdown_barrier DEBUG
fi
SH
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
install_handling_transition_barrier() {
  local dir=$1 real_date
  real_date=$(command -v date)
  cat > "$dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
record=${FM_HOME:?}/state/.codex-stop-health
if [ -n "${FM_TEST_CODEX_HANDLING_MARKER:-}" ] \
  && [ ! -e "$FM_TEST_CODEX_HANDLING_MARKER" ] \
  && grep -Fqx 'phase=watching' "$record" 2>/dev/null; then
  : > "$FM_TEST_CODEX_HANDLING_MARKER"
  n=0
  while [ ! -e "$FM_TEST_CODEX_HANDLING_RELEASE" ] && [ "$n" -lt 500 ]; do
    sleep 0.01
    n=$((n + 1))
  done
  [ -e "$FM_TEST_CODEX_HANDLING_RELEASE" ] || exit 124
fi
exec "$FM_TEST_REAL_DATE" "$@"
SH
  chmod +x "$dir/fakebin/date"
  printf '%s\n' "$real_date" > "$dir/real-date"
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
AWAIT_ARM_PID=
await_arm_child() {
  local owner=$1 n=0
  AWAIT_ARM_PID=
  while [ "$n" -lt 400 ]; do
    AWAIT_ARM_PID=$(ps -axo pid=,ppid=,command= | awk -v owner="$owner" \
      '$2 == owner && index($0, "fm-watch-arm.sh") > 0 { print $1; exit }')
    [ -z "$AWAIT_ARM_PID" ] || return 0
    sleep 0.01
    n=$((n + 1))
  done
  fail "timed out waiting for Stop owner $owner arm child"
}
await_output() {
  local path=$1 expected=$2 n=0
  while [ "$n" -lt 400 ]; do
    grep -Fq "$expected" "$path" 2>/dev/null && return 0
    sleep 0.01
    n=$((n + 1))
  done
  fail "timed out waiting for Stop output: $expected"
}
await_cleanup_wait() {
  local owner=$1 n=0
  while [ "$n" -lt 400 ]; do
    ps -axo ppid=,command= | awk -v owner="$owner" \
      '$1 == owner && $2 == "sleep" { found=1 } END { exit !found }' && return 0
    sleep 0.01
    n=$((n + 1))
  done
  fail "timed out waiting for Stop owner $owner cleanup wait"
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
transition_lock_write() {
  FM_HOME="$1" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_session_transition_lock_write "$2/state" "$3"' \
    _ "$ROOT" "$1" "$2"
}
transition_afk_write() {
  FM_HOME="$1" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_session_transition_afk_write "$2/state"' \
    _ "$ROOT" "$1"
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

test_cleanup_cancellation_revokes_handling() {
  local signal dir marker release stop_owner arm_pid rc guard replacement_pid replacement_identity
  for signal in HUP INT TERM; do
    dir=$(make_home "cleanup-cancel-$signal")
    install_final_barrier "$dir"
    marker="$dir/final.marker"
    release="$dir/final.release"
    TEST_BUDGET=1 FM_TEST_CODEX_FINAL_MARKER="$marker" \
      FM_TEST_CODEX_FINAL_RELEASE="$release" FM_TEST_REAL_GREP="$(cat "$dir/real-grep")" \
      run_stop_trappable "$dir" > "$dir/out" 2>&1 &
    STOP_PID=$!
    await_file "$marker"
    stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
    await_arm_child "$stop_owner"
    arm_pid=$AWAIT_ARM_PID
    kill -STOP "$arm_pid"
    : > "$release"
    await_output "$dir/out" 'Run bin/fm-wake-drain.sh'
    await_cleanup_wait "$stop_owner"
    assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
      "$signal cleanup cancellation fixture lost its handling claim before cancellation"
    kill -"$signal" "$stop_owner"
    kill -CONT "$arm_pid" 2>/dev/null || true
    rc=0
    wait "$STOP_PID" || rc=$?
    STOP_PID=
    expect_code 0 "$rc" "$signal cleanup cancellation returned a native continuation"
    assert_absent "$dir/state/.codex-stop-health" \
      "$signal cleanup cancellation preserved a false handling successor"
    assert_absent "$dir/state/.watch.lock/pid" \
      "$signal cleanup cancellation left its owned watcher alive"
    if kill -0 "$arm_pid" 2>/dev/null; then
      fail "$signal cleanup cancellation left its owned arm process alive"
    fi
    guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
      FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
    assert_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
      "public guard accepted the false handling state after $signal cleanup cancellation"
  done

  dir=$(make_home cleanup-continuation)
  rc=0
  TEST_BUDGET=1 run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'successful cleanup did not preserve native continuation exit'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'successful cleanup removed its required Stop successor'
  assert_grep 'successor_count=0' "$dir/state/.codex-stop-health" \
    'successful cleanup changed exactly-one successor state'

  dir=$(make_home cleanup-replacement-owner)
  install_final_barrier "$dir"
  marker="$dir/final.marker"
  release="$dir/final.release"
  TEST_BUDGET=1 FM_TEST_CODEX_FINAL_MARKER="$marker" \
    FM_TEST_CODEX_FINAL_RELEASE="$release" FM_TEST_REAL_GREP="$(cat "$dir/real-grep")" \
    run_stop_trappable "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$marker"
  stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
  await_arm_child "$stop_owner"
  arm_pid=$AWAIT_ARM_PID
  kill -STOP "$arm_pid"
  : > "$release"
  await_output "$dir/out" 'Run bin/fm-wake-drain.sh'
  await_cleanup_wait "$stop_owner"
  sleep 30 &
  STOP_PID_TWO=$!
  replacement_pid=$STOP_PID_TWO
  replacement_identity=$(FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$replacement_pid")
  printf '%s\n' "$replacement_pid" > "$dir/state/.lock"
  FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(( $(date +%s) + 300 ))" cleanup-replacement' \
    _ "$ROOT" "$dir" "$replacement_pid" "$replacement_identity"
  kill -TERM "$stop_owner"
  kill -CONT "$arm_pid" 2>/dev/null || true
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 0 "$rc" 'cleanup cancellation against replacement ownership returned continuation'
  assert_grep "generation_pid=$replacement_pid" "$dir/state/.codex-stop-health" \
    'cleanup cancellation cleared the replacement generation handling claim'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'cleanup cancellation changed the replacement generation phase'
  guard=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$replacement_pid \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_GUARD_GRACE=999 \
    FM_SUPERVISION_MODEL=stop-managed "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$guard" 'WATCHER DOWN - SUPERVISION IS OFF' \
    'public guard rejected the preserved replacement generation handling claim'
  kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  wait "$STOP_PID_TWO" 2>/dev/null || true
  STOP_PID_TWO=
  pass 'cleanup cancellation revokes only its owner handling successor'
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

test_handoff_revalidates_session_generation() {
  local boundary mutation dir marker release rc output replacement_pid replacement_identity replacement_before
  local handling_marker handling_release real_date final_marker final_release real_grep
  for boundary in handling final; do
    for mutation in unchanged replacement away; do
      dir=$(make_home "handoff-$boundary-$mutation")
      printf 'check: pending handoff work\n' > "$dir/state/.wake-queue"
      marker="$dir/$boundary.marker"
      release="$dir/$boundary.release"
      handling_marker=
      handling_release=
      real_date=
      final_marker=
      final_release=
      real_grep=
      case "$boundary" in
        handling)
          install_handling_transition_barrier "$dir"
          handling_marker=$marker
          handling_release=$release
          real_date=$(cat "$dir/real-date")
          ;;
        final)
          install_final_barrier "$dir"
          final_marker=$marker
          final_release=$release
          real_grep=$(cat "$dir/real-grep")
          ;;
      esac
      rc=0
      TEST_BUDGET=1 \
      FM_TEST_CODEX_HANDLING_MARKER="$handling_marker" \
      FM_TEST_CODEX_HANDLING_RELEASE="$handling_release" \
      FM_TEST_REAL_DATE="$real_date" \
      FM_TEST_CODEX_FINAL_MARKER="$final_marker" \
      FM_TEST_CODEX_FINAL_RELEASE="$final_release" \
      FM_TEST_REAL_GREP="$real_grep" \
        run_stop_trappable "$dir" > "$dir/out" 2>&1 &
      STOP_PID=$!
      await_file "$marker"
      case "$mutation" in
        unchanged) ;;
        away) transition_afk_write "$dir" ;;
        replacement)
          sleep 30 &
          STOP_PID_TWO=$!
          replacement_pid=$STOP_PID_TWO
          replacement_identity=$(FM_HOME="$dir" bash -c \
            '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$replacement_pid")
          transition_lock_write "$dir" "$replacement_pid"
          FM_HOME="$dir" bash -c \
            '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(( $(date +%s) + 300 ))" replacement-handoff' \
            _ "$ROOT" "$dir" "$replacement_pid" "$replacement_identity"
          replacement_before=$(cat "$dir/state/.codex-stop-health")
          ;;
      esac
      : > "$release"
      wait "$STOP_PID" || rc=$?
      STOP_PID=
      output=$(cat "$dir/out")
      if [ "$mutation" = unchanged ]; then
        expect_code 2 "$rc" "$boundary unchanged generation did not commit its continuation"
        assert_contains "$output" 'Run bin/fm-wake-drain.sh' \
          "$boundary unchanged generation omitted its continuation"
        assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
          "$boundary unchanged generation lost its handling claim"
      else
        expect_code 0 "$rc" "$boundary $mutation handoff revived an obsolete continuation"
        assert_not_contains "$output" 'Run bin/fm-wake-drain.sh' \
          "$boundary $mutation handoff emitted an obsolete continuation"
        if [ "$mutation" = replacement ]; then
          [ "$(cat "$dir/state/.codex-stop-health")" = "$replacement_before" ] \
            || fail "$boundary replacement handoff changed the successor generation claim"
          kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
          wait "$STOP_PID_TWO" 2>/dev/null || true
          STOP_PID_TWO=
        else
          assert_present "$dir/state/.afk" "$boundary away handoff removed away ownership"
          assert_absent "$dir/state/.codex-stop-health" \
            "$boundary away handoff retained the obsolete generation claim"
        fi
      fi
    done
  done
  pass 'Stop handoff commits only for the unchanged session generation'
}

test_native_continuation_commit_is_serialized() {
  local mutation dir marker release rc replacement_pid
  for mutation in away replacement; do
    dir=$(make_home "commit-$mutation")
    printf 'check: pending serialized continuation\n' > "$dir/state/.wake-queue"
    marker="$dir/commit.marker"
    release="$dir/commit.release"
    rc=0
    TEST_BUDGET=1 FM_TEST_CODEX_COMMIT_MARKER="$marker" FM_TEST_CODEX_COMMIT_RELEASE="$release" \
      run_stop_trappable "$dir" > "$dir/out" 2>&1 &
    STOP_PID=$!
    await_file "$marker"
    case "$mutation" in
      away)
        transition_afk_write "$dir" > "$dir/transition.out" 2>&1 &
        ;;
      replacement)
        replacement_pid=1
        transition_lock_write "$dir" "$replacement_pid" > "$dir/transition.out" 2>&1 &
        ;;
    esac
    STOP_PID_TWO=$!
    sleep 0.1
    kill -0 "$STOP_PID_TWO" 2>/dev/null \
      || fail "$mutation transition did not wait for native continuation commitment"
    case "$mutation" in
      away) assert_absent "$dir/state/.afk" 'away state changed before continuation commitment' ;;
      replacement) [ "$(cat "$dir/state/.lock")" = $$ ] \
        || fail 'session generation changed before continuation commitment' ;;
    esac
    : > "$release"
    wait "$STOP_PID" || rc=$?
    STOP_PID=
    expect_code 2 "$rc" "$mutation serialization changed the committed native continuation"
    wait "$STOP_PID_TWO" || fail "$mutation transition failed after continuation commitment"
    STOP_PID_TWO=
    case "$mutation" in
      away) assert_present "$dir/state/.afk" 'away transition did not follow committed continuation' ;;
      replacement)
        [ "$(cat "$dir/state/.lock")" = "$replacement_pid" ] \
          || fail 'replacement generation did not follow committed continuation'
        ;;
    esac
  done
  pass 'native continuation commitment serializes session and away transitions'
}

install_terminal_source() {
  local dir=$1 release=$2
  freeze_configured_stop_runtime "$dir"
  cat > "$dir/runtime-bin/fm-procevent-terminal-test.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  terminal) exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$dir/terminal-source.sh" <<'SH'
#!/usr/bin/env bash
release=$1
n=0
while [ ! -e "$release" ] && [ "$n" -lt 600 ]; do
  sleep 0.01
  n=$((n + 1))
done
[ -e "$release" ] || exit 1
printf 'terminal source completed\n'
SH
  chmod +x "$dir/runtime-bin/fm-procevent-terminal-test.sh" "$dir/terminal-source.sh"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$dir/bin/fm-procevent.sh" register terminal-test final-source \
      -- "$dir/terminal-source.sh" "$release" >/dev/null
}

append_test_wake() {
  local dir=$1 token=$2
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check "$2" "check: $3"' \
    _ "$ROOT" "$token" "$token" >/dev/null
}

test_public_stop_closes_source_retirement_race() {
  local dir marker release rc prompts
  dir=$(make_home public-source-retirement-race)
  rm "$dir/state/work.meta"
  freeze_configured_stop_runtime "$dir"
  install_standdown_barrier "$dir"
  mkdir -p "$dir/state/procevent"
  : > "$dir/state/procevent/racing-source.source"
  marker="$dir/standdown.marker"
  release="$dir/standdown.release"
  FM_TEST_CODEX_STANDDOWN_MARKER="$marker" \
    FM_TEST_CODEX_STANDDOWN_RELEASE="$release" TEST_BUDGET=12 TEST_GRACE=8 \
    run_configured_stop "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$marker"
  append_test_wake "$dir" retirement-race
  rm "$dir/state/procevent/racing-source.source"
  : > "$release"
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 2 "$rc" 'configured Stop stranded a wake published during source retirement'
  assert_grep 'retirement-race' "$dir/state/.wake-queue" \
    'source-retirement interleaving lost its durable queued wake'
  assert_absent "$dir/state/.watch.lock/pid" \
    'source-retirement interleaving armed a redundant watcher'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'source-retirement interleaving omitted its handling successor'
  assert_grep 'successor_count=0' "$dir/state/.codex-stop-health" \
    'source-retirement interleaving created duplicate successors'
  prompts=$(grep -Fc 'Run bin/fm-wake-drain.sh' "$dir/out" || true)
  [ "$prompts" = 1 ] || fail 'source-retirement interleaving emitted multiple continuations'
  pass 'public Codex Stop closes the terminal-source retirement race'
}

test_final_source_wake_retains_continuation() {
  local dir release rc marker stop_owner drain
  dir=$(make_home final-source-wake)
  rm "$dir/state/work.meta"
  release="$dir/source.release"
  install_terminal_source "$dir" "$release"
  TEST_BUDGET=12 run_stop "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_lock "$dir"
  : > "$release"
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 2 "$rc" 'terminal final source wake did not request native continuation'
  assert_absent "$dir/state/procevent/final-source.source" \
    'terminal final source remained registered after publishing its result'
  assert_grep 'procevent terminal-test final-source 1' "$dir/state/.wake-queue" \
    'terminal final source wake was not retained for handling'
  assert_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'terminal final source wake returned without its native continuation'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'terminal final source wake did not preserve exactly-one successor state'
  drain=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drain" 'procevent terminal-test final-source 1' \
    'terminal final source wake was not delivered to its handling turn'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$dir/bin/fm-procevent.sh" handled final-source 1 >/dev/null
  assert_present "$dir/state/procevent-inbox/final-source.1.handled" \
    'terminal final source handling was not durably acknowledged'

  dir=$(make_home pending-queue-only)
  rm "$dir/state/work.meta"
  append_test_wake "$dir" pending-only
  rc=0
  TEST_BUDGET=12 run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'pending queue without live sources did not request continuation'
  assert_grep 'pending-only' "$dir/state/.wake-queue" \
    'pending-queue continuation consumed durable work before handling'
  assert_absent "$dir/state/.watch.lock/pid" \
    'pending-queue continuation started a redundant watcher'

  dir=$(make_home empty-source-no-wake)
  rm "$dir/state/work.meta"
  rc=0
  TEST_BUDGET=1 run_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 0 "$rc" 'truly empty Stop requested a native continuation'
  assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'truly empty Stop emitted a continuation prompt'

  dir=$(make_home pending-queue-cancelled)
  rm "$dir/state/work.meta"
  append_test_wake "$dir" cancelled-pending
  install_final_barrier "$dir"
  marker="$dir/final.marker"
  FM_TEST_CODEX_FINAL_MARKER="$marker" FM_TEST_CODEX_FINAL_RELEASE="$dir/final.release" \
    FM_TEST_REAL_GREP="$(cat "$dir/real-grep")" run_stop_trappable "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$marker"
  stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
  kill -TERM "$stop_owner"
  : > "$dir/final.release"
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 0 "$rc" 'pending-queue cancellation returned a native continuation'
  assert_grep 'cancelled-pending' "$dir/state/.wake-queue" \
    'pending-queue cancellation consumed durable work'
  assert_absent "$dir/state/.codex-stop-health" \
    'pending-queue cancellation preserved a false handling successor'
  assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'pending-queue cancellation emitted a resurrection prompt'
  pass 'final-source and queued wakes retain exactly one cancellable continuation'
}

test_public_stop_dispatches_pending_queue() {
  local dir release rc drain ack_through recovery_generation old_expiry now
  local stop_owner replacement_pid identity

  dir=$(make_home public-final-source-before-stop)
  rm "$dir/state/work.meta"
  release="$dir/source.release"
  install_terminal_source "$dir" "$release"
  : > "$release"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$dir/bin/fm-procevent.sh" start final-source >/dev/null
  assert_absent "$dir/state/procevent/final-source.source" \
    'terminal source did not retire before the configured Stop hook'
  assert_grep 'procevent terminal-test final-source 1' "$dir/state/.wake-queue" \
    'terminal source did not leave its durable wake before the configured Stop hook'
  rc=0
  TEST_BUDGET=12 TEST_GRACE=8 run_configured_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'configured Stop hook stranded a final-source wake'
  assert_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'configured Stop hook omitted the final-source continuation'
  assert_grep 'procevent terminal-test final-source 1' "$dir/state/.wake-queue" \
    'configured Stop hook consumed the final-source wake before handling'
  assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
    'configured Stop hook omitted its exactly-one successor state'
  old_expiry=$(sed -n 's/^expires_epoch=//p' "$dir/state/.codex-stop-health")
  drain=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" "$dir/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drain" 'procevent terminal-test final-source 1' \
    'configured Stop continuation did not deliver the final-source wake'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    "$dir/bin/fm-procevent.sh" handled final-source 1 >/dev/null
  ack_through=$(printf '%s\n' "$drain" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i <= NF; i++) if ($i == "--ack-through") print $(i + 1) }')
  recovery_generation=$(printf '%s\n' "$drain" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i <= NF; i++) if ($i == "--recovery-generation") print $(i + 1) }')
  [ -n "$ack_through" ] && [ -n "$recovery_generation" ] \
    || fail 'configured Stop continuation omitted its durable acknowledgement command'
  env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
    PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    FM_PROCEVENT_CLAIM_ROOT="$dir/claims" "$dir/bin/fm-wake-drain.sh" \
      --ack-through "$ack_through" --recovery-generation "$recovery_generation" >/dev/null
  rc=0
  TEST_BUDGET=1 TEST_GRACE=8 run_configured_stop "$dir" > "$dir/after-ack" 2>&1 || rc=$?
  expect_code 0 "$rc" 'configured Stop hook continued after final-source acknowledgement'
  assert_not_contains "$(cat "$dir/after-ack")" 'Run bin/fm-wake-drain.sh' \
    'configured Stop hook duplicated an acknowledged continuation'
  assert_absent "$dir/state/.codex-stop-health" \
    'configured empty successor left its handling claim pending'
  now=$(date +%s)
  if [ "$now" -le "$old_expiry" ]; then sleep "$((old_expiry - now + 1))"; fi
  : > "$dir/state/later-work.meta"
  rc=0
  TEST_BUDGET=1 TEST_GRACE=3 run_configured_stop "$dir" > "$dir/later-work" 2>&1 || rc=$?
  expect_code 2 "$rc" 'later work did not establish supervision after the old handling deadline'
  assert_not_contains "$(cat "$dir/later-work")" 'handling window expired' \
    'later work inherited the fulfilled handling deadline'

  dir=$(make_home public-pending-queue-only)
  rm "$dir/state/work.meta"
  freeze_configured_stop_runtime "$dir"
  append_test_wake "$dir" public-pending-only
  rc=0
  TEST_BUDGET=12 run_configured_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'configured Stop hook skipped a queue-only wake'
  assert_grep 'public-pending-only' "$dir/state/.wake-queue" \
    'configured queue-only continuation consumed durable work before handling'
  assert_absent "$dir/state/.watch.lock/pid" \
    'configured queue-only continuation started a redundant watcher'

  dir=$(make_home public-truly-empty)
  rm "$dir/state/work.meta"
  freeze_configured_stop_runtime "$dir"
  rc=0
  TEST_BUDGET=1 run_configured_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 0 "$rc" 'configured Stop hook continued from truly empty state'
  assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'configured Stop hook emitted a continuation without work or sources'

  dir=$(make_home public-expired-empty-successor)
  rm "$dir/state/work.meta"
  freeze_configured_stop_runtime "$dir"
  identity=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$dir" $$)
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$(date +%s)" expired-public' \
      _ "$dir" "$dir" $$ "$identity"
  rc=0
  TEST_BUDGET=1 run_configured_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'configured Stop hook ignored an expired missing successor'
  assert_contains "$(cat "$dir/out")" 'handling window expired before its required Stop successor' \
    'configured Stop hook hid the expired successor diagnosis'

  dir=$(make_home public-live-source)
  rm "$dir/state/work.meta"
  release="$dir/source.release"
  install_terminal_source "$dir" "$release"
  rc=0
  TEST_BUDGET=1 run_configured_stop "$dir" > "$dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" 'configured Stop hook skipped a live source'
  assert_present "$dir/state/procevent/final-source.source" \
    'configured Stop hook retired an unfinished live source'

  dir=$(make_home public-cancelled)
  freeze_configured_stop_runtime "$dir"
  TEST_BUDGET=12 run_configured_stop "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$dir/state/.codex-stop.lock/pid"
  stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
  await_arm_child "$stop_owner"
  kill -TERM "$stop_owner"
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 0 "$rc" 'configured Stop cancellation returned a continuation'
  assert_absent "$dir/state/.codex-stop-health" \
    'configured Stop cancellation preserved a false successor'
  assert_not_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' \
    'configured Stop cancellation emitted a resurrection prompt'

  dir=$(make_home public-replacement)
  rm "$dir/state/work.meta"
  release="$dir/source.release"
  install_terminal_source "$dir" "$release"
  TEST_BUDGET=12 run_configured_stop "$dir" > "$dir/out" 2>&1 &
  STOP_PID=$!
  await_file "$dir/state/.codex-stop.lock/pid"
  stop_owner=$(cat "$dir/state/.codex-stop.lock/pid")
  await_arm_child "$stop_owner"
  sleep 30 &
  STOP_PID_TWO=$!
  replacement_pid=$STOP_PID_TWO
  printf '%s\n' "$replacement_pid" > "$dir/state/.lock"
  : > "$release"
  rc=0
  wait "$STOP_PID" || rc=$?
  STOP_PID=
  expect_code 0 "$rc" 'configured Stop continued after session replacement'
  [ "$(cat "$dir/state/.lock")" = "$replacement_pid" ] \
    || fail 'configured Stop changed the replacement session owner'
  assert_absent "$dir/state/.codex-stop-health" \
    'configured Stop left a successor claim for the replaced session'
  kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  wait "$STOP_PID_TWO" 2>/dev/null || true
  STOP_PID_TWO=
  pass 'configured Codex Stop dispatches pending queues through one owner'
}

test_public_afk_handoff_clears_owned_successor() {
  local timing dir rc drain ack_through recovery_generation old_expiry now
  local replacement_pid replacement_identity replacement_before
  for timing in before after; do
    dir=$(make_home "public-afk-$timing")
    rm "$dir/state/work.meta"
    freeze_configured_stop_runtime "$dir"
    append_test_wake "$dir" "public-afk-$timing"
    rc=0
    TEST_BUDGET=12 TEST_GRACE=10 run_configured_stop "$dir" > "$dir/initial" 2>&1 || rc=$?
    expect_code 2 "$rc" "configured Stop did not create the $timing-away handling claim"
    assert_grep 'phase=handling' "$dir/state/.codex-stop-health" \
      "configured Stop omitted the $timing-away handling claim"
    old_expiry=$(sed -n 's/^expires_epoch=//p' "$dir/state/.codex-stop-health")
    drain=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
      PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
      FM_PROCEVENT_CLAIM_ROOT="$dir/claims" "$dir/bin/fm-wake-drain.sh" 2>&1)
    ack_through=$(printf '%s\n' "$drain" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i <= NF; i++) if ($i == "--ack-through") print $(i + 1) }')
    recovery_generation=$(printf '%s\n' "$drain" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i <= NF; i++) if ($i == "--recovery-generation") print $(i + 1) }')
    [ -n "$ack_through" ] && [ -n "$recovery_generation" ] \
      || fail "configured $timing-away continuation omitted its acknowledgement"
    env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT -u FM_SUPERVISION_MODEL \
      PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
      FM_PROCEVENT_CLAIM_ROOT="$dir/claims" "$dir/bin/fm-wake-drain.sh" \
        --ack-through "$ack_through" --recovery-generation "$recovery_generation" >/dev/null
    if [ "$timing" = after ]; then
      now=$(date +%s)
      if [ "$now" -le "$old_expiry" ]; then sleep "$((old_expiry - now + 1))"; fi
    fi
    : > "$dir/state/.afk"
    rc=0
    TEST_BUDGET=1 TEST_GRACE=10 run_configured_stop "$dir" > "$dir/away" 2>&1 || rc=$?
    expect_code 0 "$rc" "configured $timing-deadline away handoff did not retire its owned claim"
    assert_present "$dir/state/.afk" "configured $timing-deadline handoff removed away ownership"
    assert_absent "$dir/state/.codex-stop-health" \
      "configured $timing-deadline away handoff preserved its owned claim"
    assert_absent "$dir/state/.watch.lock/pid" \
      "configured $timing-deadline away handoff armed a watcher"
    rm "$dir/state/.afk"
    : > "$dir/state/later-work.meta"
    rc=0
    TEST_BUDGET=1 TEST_GRACE=3 run_configured_stop "$dir" > "$dir/later" 2>&1 || rc=$?
    expect_code 2 "$rc" "later work failed after the $timing-deadline away handoff"
    assert_not_contains "$(cat "$dir/later")" 'handling window expired' \
      "later work inherited the $timing-deadline away claim"
  done

  dir=$(make_home public-afk-replacement)
  rm "$dir/state/work.meta"
  freeze_configured_stop_runtime "$dir"
  sleep 30 &
  STOP_PID_TWO=$!
  replacement_pid=$STOP_PID_TWO
  replacement_identity=$(PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$dir" "$replacement_pid")
  printf '%s\n' "$replacement_pid" > "$dir/state/.lock"
  PATH="$dir/fakebin:$PATH" FM_TEST_CODEX_OWNER=$$ FM_HOME="$dir" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_codex_stop_record_write "$2/state" "$3" "$4" handling 0 "$5" public-afk-replacement' \
    _ "$dir" "$dir" "$replacement_pid" "$replacement_identity" "$(( $(date +%s) + 300 ))"
  replacement_before=$(cat "$dir/state/.codex-stop-health")
  : > "$dir/state/.afk"
  rc=0
  TEST_BUDGET=1 run_configured_stop "$dir" > "$dir/away" 2>&1 || rc=$?
  expect_code 2 "$rc" 'configured away handoff entered a replacement generation owner'
  [ "$(cat "$dir/state/.codex-stop-health")" = "$replacement_before" ] \
    || fail 'configured away handoff changed the replacement generation claim'
  assert_present "$dir/state/.afk" 'configured replacement isolation removed away ownership'
  assert_absent "$dir/state/.watch.lock/pid" \
    'configured replacement isolation armed a watcher'
  kill -TERM "$STOP_PID_TWO" 2>/dev/null || true
  wait "$STOP_PID_TWO" 2>/dev/null || true
  STOP_PID_TWO=
  pass 'configured Codex Stop retires only its owned claim during away handoff'
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
  cleanup-cancellation)
    test_cleanup_cancellation_revokes_handling
    exit 0
    ;;
  afk-handoff)
    test_afk_handoff_clears_owned_successor
    exit 0
    ;;
  handoff-generation)
    test_handoff_revalidates_session_generation
    test_native_continuation_commit_is_serialized
    exit 0
    ;;
  final-source-wake)
    test_public_stop_closes_source_retirement_race
    test_final_source_wake_retains_continuation
    exit 0
    ;;
  public-pending-queue)
    test_public_stop_dispatches_pending_queue
    exit 0
    ;;
  public-afk-handoff)
    test_public_afk_handoff_clears_owned_successor
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
test_final_source_wake_retains_continuation
test_public_stop_dispatches_pending_queue
test_public_afk_handoff_clears_owned_successor
test_cleanup_cancellation_revokes_handling
