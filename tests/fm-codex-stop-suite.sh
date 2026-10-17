#!/usr/bin/env bash
# Shared public Codex Stop cases with real singleton watcher and process ownership.
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
  local home=$1 fixture_tasks='' fixture_task snapshot
  # Legacy fixtures used an empty .meta merely as a boolean.  The production
  # predicate now (correctly) treats a valid empty active snapshot as idle, so
  # make those fixtures real recoverable task records instead of relying on the
  # retained-metadata archive as liveness evidence.
  for fixture_meta in "$home/state"/*.meta; do
    [ -f "$fixture_meta" ] || continue
    [ -s "$fixture_meta" ] && continue
    fixture_task=${fixture_meta##*/}; fixture_task=${fixture_task%.meta}
    fixture_tasks="${fixture_tasks}${fixture_tasks:+$'\n'}$fixture_task"
    {
      printf 'window=firstmate:fm-%s\n' "$fixture_task"
      printf 'worktree=%s\nproject=%s\n' "$home" "$home"
      printf 'harness=codex\nkind=ship\nspawn_gen=fixture-%s\n' "$fixture_task"
    } > "$fixture_meta"
  done
  snapshot="$home/state/.active-supervision-generation"
  if [ -n "$fixture_tasks" ] && [ ! -e "$snapshot" ]; then
    printf 'fm-active-supervision.v6\tg1\n' > "$snapshot"
    while IFS= read -r fixture_task; do
      [ -n "$fixture_task" ] || continue
      printf 'entry\t%s\tfixture-%s\tactive\n' "$fixture_task" "$fixture_task" >> "$snapshot"
    done <<EOF
$fixture_tasks
EOF
  fi
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CODEX_WATCH_CHECKPOINT="${2:-2}" \
    FM_CHECK_INTERVAL="${FM_CHECK_INTERVAL:-999999}" FM_HEARTBEAT=999999 FM_POLL="${FM_POLL:-1}" \
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
        if [ -n "${FM_CODEX_REPEAT_PAUSE_FILE:-}" ]; then
          printf "%s\n" paused > "$FM_CODEX_REPEAT_PAUSE_FILE"
          while [ ! -f "$FM_CODEX_REPEAT_PAUSE_FILE.release" ]; do sleep 0.02; done
        fi
        "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex < "$FM_HOME/payload" > "$FM_HOME/repeat-out" 2>&1
        echo "$?" > "$FM_HOME/repeat-rc"
      fi
      # Keep the session alive while the caller examines its handling proof.
      while [ ! -f "$FM_HOME/release" ]; do sleep 0.1; done
    ' &
  HARNESS=$!
}

initialize_empty_active_supervision_registry() { # <home>
  FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" || fail 'could not initialize an empty active supervision registry'
}

register_active_supervision_tasks() { # <home> <task>...
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" FM_TEST_ACTIVE_TASKS="$*" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    for task in $FM_TEST_ACTIVE_TASKS; do
      fm_supervision_registry_register \
        "$FM_STATE_OVERRIDE" "$task" "$FM_STATE_OVERRIDE/$task.meta" || exit 1
    done
  ' _ "$ROOT/bin" || fail 'could not register the active supervision fixture tasks'
}

wait_file() {
  local i=0 limit=${2:-150}
  while [ ! -s "$1" ] && [ "$i" -lt "$limit" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ] || fail "timeout waiting for $1"
}
wait_absent() {
  local i=0 limit=${2:-150}
  while { [ -e "$1" ] || [ -L "$1" ]; } && [ "$i" -lt "$limit" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "timeout waiting for $1 to disappear"
}
monotonic_seconds() {
  python3 -c 'import time; print(int(time.monotonic()))'
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
  local home=$1 fakebin=$2 deadline_ns
  if [ ! -f "$home/state/.active-supervision-generation" ]; then
    PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin" || fail 'could not initialize the active supervision fixture registry'
  fi
  deadline_ns=$(python3 -c 'import time; print(time.monotonic_ns() + 120_000_000_000)') \
    || fail 'could not allocate a bounded watcher lease deadline'
  perl -e 'my $timeout=shift @ARGV; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm $timeout; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    "${FM_TEST_BOUNDED_WATCH_TIMEOUT:-3}" \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=1 \
      FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE="${FM_TEST_CHECKS_PER_CYCLE:-1}" \
      FM_CODEX_LEASE_DEADLINE_NS="$deadline_ns" \
      FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION=1 \
      FM_WATCH_HANDLING_SUCCESSOR="${FM_TEST_WATCH_HANDLING_SUCCESSOR:-0}" \
      FM_POLL="${FM_TEST_WATCH_POLL:-0.02}" FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      PATH="$fakebin:$PATH" "$ROOT/bin/fm-watch.sh"
}

death_receipt_count() {
  local root="$1/state/.death-notified-v3"
  [ -d "$root" ] || { printf '0\n'; return; }
  find "$root" -type f | wc -l | tr -d ' '
}

death_receipt_contents() {
  local root="$1/state/.death-notified-v3"
  [ -d "$root" ] || return 0
  find "$root" -type f -exec cat {} \;
}

write_exact_death_receipt() {
  local state=$1 task=$2 target=$3 backend=$4 spawn_gen=$5
  FM_STATE_OVERRIDE="$state" FM_TEST_TASK="$task" FM_TEST_TARGET="$target" \
    FM_TEST_BACKEND="$backend" FM_TEST_SPAWN_GEN="$spawn_gen" bash -c '
      . "$1/fm-supervision-registry-lib.sh"
      owner=$(fm_supervision_death_owner_id "$FM_TEST_TARGET" "$FM_TEST_TASK" "$FM_TEST_BACKEND") || exit 1
      receipt=$(fm_supervision_death_state_path "$FM_STATE_OVERRIDE" death-notified "$owner") || exit 1
      mkdir -p "${receipt%/*}" || exit 1
      printf "fm-death-notified.v3\tspawn:%s\t%s\t%s\t%s\n" \
        "$FM_TEST_SPAWN_GEN" "$FM_TEST_TASK" "$FM_TEST_BACKEND" "$FM_TEST_TARGET" > "$receipt"
    ' _ "$ROOT/bin"
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
  if is_live_non_zombie "$pid"; then fail "owned watcher $pid survived Stop cleanup: $(cat "$1/watcher-after-cleanup")"; fi
}

assert_no_watch_owner_dirs() {
  local owner
  for owner in "$1/state"/.watch.lock.owner.*; do
    [ ! -e "$owner" ] && [ ! -L "$owner" ] || fail "watcher lock owner directory survived release: $owner"
  done
}

install_controlled_watcher() {
  local dir=$1
  cp -R "$ROOT/bin/." "$dir/bin/"
  cat > "$dir/bin/fm-watch-arm.sh" <<'ARM'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
child=
FM_WATCH_ARM_OWNER_PID=${BASHPID:-$$}
FM_WATCH_ARM_OWNER_IDENTITY=$(fm_pid_identity "$FM_WATCH_ARM_OWNER_PID") || exit 1
export FM_WATCH_ARM_OWNER_PID FM_WATCH_ARM_OWNER_IDENTITY
printf '%s\n' "$FM_WATCH_ARM_OWNER_PID" > "$FM_HOME/controlled-arm-pid"
printf '%s\n' "$FM_WATCH_ARM_OWNER_PID" >> "$FM_HOME/controlled-arm-starts"
if [ -n "${FM_CODEX_CHECK_BATCH_LEASE:-}" ]; then
  printf 'fm-codex-arm-launch.v1\t%s\t%s\t%s\tpending\n' \
    "$FM_CODEX_CHECK_BATCH_LEASE" "$FM_WATCH_ARM_OWNER_PID" \
    "$FM_WATCH_ARM_OWNER_IDENTITY" > "$FM_HOME/state/.codex-arm-owner.tmp" || exit 1
  mv -f "$FM_HOME/state/.codex-arm-owner.tmp" "$FM_HOME/state/.codex-arm-owner" || exit 1
fi
stop_arm() {
  printf '%s\n' term > "$FM_HOME/controlled-arm-term"
  sleep "${FM_TEST_ARM_TERM_DELAY:-0}"
  printf '%s\n' done > "$FM_HOME/controlled-arm-term-delay-done"
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
watcher_pid=${BASHPID:-$$}
identity=$(fm_pid_identity "$watcher_pid") || exit 1
if [ -n "${FM_WATCH_ARM_OWNER_PID:-}" ]; then
  IFS="$(printf '\t')" read -r launch_protocol launch_lease launch_owner_pid \
    launch_owner_identity launch_phase < "$FM_HOME/state/.codex-arm-owner" || exit 1
  [ "$launch_protocol" = fm-codex-arm-launch.v1 ] \
    && [ "$launch_lease" = "$FM_CODEX_CHECK_BATCH_LEASE" ] \
    && [ "$launch_owner_pid" = "$FM_WATCH_ARM_OWNER_PID" ] \
    && [ "$launch_owner_identity" = "$FM_WATCH_ARM_OWNER_IDENTITY" ] \
    && [ "$launch_phase" = pending ] || exit 1
  printf 'fm-codex-arm-launch.v1\t%s\t%s\t%s\tspawned\t%s\t%s\n' \
    "$FM_CODEX_CHECK_BATCH_LEASE" "$FM_WATCH_ARM_OWNER_PID" \
    "$FM_WATCH_ARM_OWNER_IDENTITY" "$watcher_pid" "$identity" \
    > "$FM_HOME/state/.codex-arm-owner.tmp" || exit 1
  mv -f "$FM_HOME/state/.codex-arm-owner.tmp" "$FM_HOME/state/.codex-arm-owner" || exit 1
fi
mkdir "$lock" || exit 1
printf '%s\n' "$watcher_pid" > "$lock/pid"
printf '%s\n' "$FM_HOME" > "$lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$lock/watcher-path"
printf '%s\n' "$identity" > "$lock/pid-identity"
case "${FM_CODEX_BOUNDED_WATCH:-0}:${FM_CHECKS_PER_CYCLE:-0}" in
  1:*[!0-9]*|1:0|1:) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
  1:*)
    [ "${FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION:-0}" = 1 ] \
      && remote_observation=deferred || remote_observation=inline
    batch_lease=${FM_CODEX_CHECK_BATCH_LEASE:-watcher-$$}
    printf 'fm-codex-bounded.v10\tchecks-per-cycle=%s\tcheck-timeout=%s\tcheck-kill-grace=%s\tcheck-reap-allowance=%s\tcheck-interval=%s\tpoll=%s\tsignal-grace=%s\tcrew-state-timeout=%s\tworktree-write-timeout=%s\tremote-send-timeout=%s\tinactive-reconcile-budget=%s\tadmission-guard-grace=%s\tremote-observation=%s\tinventory=active-registry-v7\tcheck-batch-handoff=resume-owner-cycle-v5\tcheck-batch-lease=%s\n' \
      "$FM_CHECKS_PER_CYCLE" "${FM_CHECK_TIMEOUT:-30}" "${FM_CHECK_KILL_GRACE:-1}" "${FM_CHECK_REAP_ALLOWANCE:-1}" "${FM_CHECK_INTERVAL:-300}" \
      "${FM_POLL:-15}" "${FM_SIGNAL_GRACE:-30}" "${FM_CREW_STATE_NM_TIMEOUT:-10}" \
      "${FM_WORKTREE_WRITE_TIMEOUT:-10}" "${FM_SEND_REMOTE_BUDGET:-30}" \
      "${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}" \
      "${FM_CODEX_ADMISSION_GUARD_GRACE:-${FM_GUARD_GRACE:-300}}" "$remote_observation" "$batch_lease" \
      > "$lock/codex-bounded-capability"
    if [ -n "${FM_WATCH_ARM_OWNER_PID:-}" ]; then
      printf 'fm-codex-arm-owner.v1\t%s\t%s\t%s\t%s\t%s\n' \
        "$batch_lease" "$FM_WATCH_ARM_OWNER_PID" "$FM_WATCH_ARM_OWNER_IDENTITY" \
        "$watcher_pid" "$identity" > "$lock/codex-arm-ownership"
    fi
    ;;
  *) printf 'fm-watch.v1\tunbounded\n' > "$lock/codex-bounded-capability" ;;
esac
clean_watcher() {
  rm -rf "$lock"
}
trap clean_watcher EXIT
trap 'exit 0' HUP INT TERM
touch "$FM_HOME/state/.last-watcher-beat"
printf '%s\n' "${FM_CHECKS_PER_CYCLE:-0}" > "$FM_HOME/controlled-check-limit"
python3 -c 'import time; print(int(time.monotonic()))' > "$FM_HOME/controlled-watcher-ready"
cycles=0
batch_sequence=1
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
    heartbeat-only)
      touch "$FM_HOME/state/.last-watcher-beat"
      ;;
    *)
      touch "$FM_HOME/state/.last-watcher-beat"
      if [ -n "${batch_lease:-}" ]; then
        printf '%s\n' "$batch_sequence" > "$lock/codex-check-batch-sequence"
        printf 'fm-codex-check-batch.v1\t%s\t%s\n' "$batch_lease" "$batch_sequence" \
          > "$lock/codex-check-batch-boundary"
        next_sequence=$((batch_sequence + 1))
        request=$(cat "$lock/codex-check-batch-resume" 2>/dev/null || true)
        request_prefix=$(printf '%s' "$request" | cut -f1-3)
        case "$request_prefix" in
          "$(printf 'fm-codex-check-batch.v4\t%s\t%s' "$batch_lease" "$next_sequence")"|\
          "$(printf 'fm-codex-check-batch.v5\t%s\t%s' "$batch_lease" "$next_sequence")")
            batch_sequence=$next_sequence
            printf '%s\n' "$batch_sequence" > "$lock/codex-check-batch-sequence"
            rm -f "$lock/codex-check-batch-resume" "$lock/codex-check-batch-boundary"
            ;;
        esac
      fi
      ;;
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
[ -z "${FM_TEST_BACKEND_PROBE_LOG:-}" ] || printf 'tmux\t%s\n' "${1:-}" >> "$FM_TEST_BACKEND_PROBE_LOG"
if [ "${1:-}" = list-windows ]; then
  session=
  all=0
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -t ]; then
      session=${2:-}
      break
    fi
    [ "$1" != -a ] || all=1
    shift
  done
  [ -z "${FM_TEST_INVENTORY_LOG:-}" ] || { [ "$all" -eq 1 ] && printf '%s\n' all || printf '%s\n' "$session"; } >> "$FM_TEST_INVENTORY_LOG"
  if [ "$all" -eq 0 ]; then
    case " ${FM_TEST_INVENTORY_FAILURES:-} " in
      *" $session "*) printf '%s\n' 'inventory unavailable' >&2; exit 71 ;;
    esac
  fi
  for target in ${FM_TEST_EXISTING_TARGETS:-${FM_TEST_LIVE_TARGETS:-}}; do
    if [ "$all" -eq 1 ]; then
      printf '%s\t%s\n' "$target" "${target#*:}"
      continue
    fi
    if [ "${target%%:*}" = "$session" ]; then
      command=zsh
      case " ${FM_TEST_LIVE_TARGETS:-} " in *" $target "*) command=codex ;; esac
      case " ${FM_TEST_AMBIGUOUS_TARGETS:-} " in *" $target "*) command=python ;; esac
      printf '%s\t/dev/fm-test-no-tty\t%s\n' "${target#*:}" "$command"
    fi
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
      *window_id*) format=reservation ;;
      *pane_current_command*) format=current-command ;;
      *pane_id*) format=existence ;;
    esac
    shift
  done
  if [ "$format" = reservation ]; then
    for reservation in ${FM_TEST_TMUX_RESERVATIONS:-}; do
      stable=${reservation%%=*}
      remainder=${reservation#*=}
      detail=${remainder%%=*}
      path=${remainder#*=}
      if [ "$target" = "$stable" ]; then
        printf '%s\t%s\t%s\n' "$stable" "$detail" "$path"
        exit 0
      fi
    done
    exit 1
  fi
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
if [ "${1:-}" = kill-window ]; then
  [ -z "${FM_TEST_TMUX_KILL_LOG:-}" ] || printf '%s\n' "${3:-}" >> "$FM_TEST_TMUX_KILL_LOG"
  exit 0
fi
exit 1
SH
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -axo ]; then
  [ -z "${FM_TEST_BACKEND_PROBE_LOG:-}" ] || printf 'ps\tsnapshot\n' >> "$FM_TEST_BACKEND_PROBE_LOG"
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/ps"
}

install_endpoint_inventory_herdr() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_HERDR_PROBE_LOG:-}" ] || printf 'herdr\t%s\t%s\n' "${1:-}" "${2:-}" >> "$FM_TEST_HERDR_PROBE_LOG"
if [ "${1:-}" = pane ] && [ "${2:-}" = list ]; then
  session=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --session ]; then
      session=${2:-}
      break
    fi
    shift
  done
  printf '{"result":{"panes":['
  separator=
  for target in ${FM_TEST_HERDR_EXISTING_TARGETS:-}; do
    if [ "${target%%:*}" = "$session" ]; then
      pane=${target#*:}
      agent_status=unknown
      case " ${FM_TEST_HERDR_LIVE_TARGETS:-} " in *" $target "*) agent_status=working ;; esac
      printf '%s{"pane_id":"%s","tab_id":"tab-%s","agent_status":"%s"}' \
        "$separator" "$pane" "$pane" "$agent_status"
      separator=,
    fi
  done
  printf ']}}\n'
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/herdr"
}

install_attached_watcher() {
  local dir=$1
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-supervision-registry-lib.sh,fm-pending-reply-lib.sh,fm-task-inbox-lib.sh,fm-hook-host-lib.sh,fm-watch-arm.sh,fm-backend.sh,fm-pr-lib.sh,fm-check-lib.sh} "$dir/bin/"
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
  1:*)
    [ "${FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION:-0}" = 1 ] \
      && remote_observation=deferred || remote_observation=inline
    batch_lease=${FM_CODEX_CHECK_BATCH_LEASE:-watcher-$$}
    printf 'fm-codex-bounded.v10\tchecks-per-cycle=%s\tcheck-timeout=%s\tcheck-kill-grace=%s\tcheck-reap-allowance=%s\tcheck-interval=%s\tpoll=%s\tsignal-grace=%s\tcrew-state-timeout=%s\tworktree-write-timeout=%s\tremote-send-timeout=%s\tinactive-reconcile-budget=%s\tadmission-guard-grace=%s\tremote-observation=%s\tinventory=active-registry-v7\tcheck-batch-handoff=resume-owner-cycle-v5\tcheck-batch-lease=%s\n' \
      "$FM_CHECKS_PER_CYCLE" "${FM_CHECK_TIMEOUT:-30}" "${FM_CHECK_KILL_GRACE:-1}" "${FM_CHECK_REAP_ALLOWANCE:-1}" "${FM_CHECK_INTERVAL:-300}" \
      "${FM_POLL:-15}" "${FM_SIGNAL_GRACE:-30}" "${FM_CREW_STATE_NM_TIMEOUT:-10}" \
      "${FM_WORKTREE_WRITE_TIMEOUT:-10}" "${FM_SEND_REMOTE_BUDGET:-30}" \
      "${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}" \
      "${FM_CODEX_ADMISSION_GUARD_GRACE:-${FM_GUARD_GRACE:-300}}" "$remote_observation" "$batch_lease" \
      > "$lock/codex-bounded-capability"
    ;;
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
if [ -n "${batch_lease:-}" ]; then
  batch_sequence=1
  printf '%s\n' 1 > "$lock/codex-check-batch-sequence"
  printf 'fm-codex-check-batch.v1\t%s\t1\n' "$batch_lease" > "$lock/codex-check-batch-boundary"
fi
while :; do
  touch "$FM_HOME/state/.last-watcher-beat"
  if [ -n "${batch_lease:-}" ]; then
    next_sequence=$((batch_sequence + 1))
    request=$(cat "$lock/codex-check-batch-resume" 2>/dev/null || true)
    request_prefix=$(printf '%s' "$request" | cut -f1-3)
    case "$request_prefix" in
      "$(printf 'fm-codex-check-batch.v4\t%s\t%s' "$batch_lease" "$next_sequence")"|\
      "$(printf 'fm-codex-check-batch.v5\t%s\t%s' "$batch_lease" "$next_sequence")")
        batch_sequence=$next_sequence
        printf '%s\n' "$batch_sequence" > "$lock/codex-check-batch-sequence"
        rm -f "$lock/codex-check-batch-resume" "$lock/codex-check-batch-boundary"
        printf 'fm-codex-check-batch.v1\t%s\t%s\n' "$batch_lease" "$batch_sequence" \
          > "$lock/codex-check-batch-boundary"
        ;;
    esac
  fi
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
  assert_no_watch_owner_dirs "$dir"
  FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" bash -c '. "$1"; fm_codex_stop_handling_healthy "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state" || fail 'delivered handling interval is not healthy'
  finish "$dir"
  pass 'quiet checkpoint requests native renewal and leaves bounded handling proof'
}

test_wedged_arm_cannot_report_quiet_renewal() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture wedged-arm)
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-supervision-registry-lib.sh,fm-pending-reply-lib.sh,fm-task-inbox-lib.sh,fm-hook-host-lib.sh,fm-backend.sh,fm-pr-lib.sh,fm-check-lib.sh} "$dir/bin/"
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
  finished=$(monotonic_seconds)
  [ "$((finished - ready))" -ge 2 ] || fail 'late watcher startup consumed the quiet checkpoint'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'late healthy watcher did not request quiet renewal'
  assert_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' 'late healthy watcher omitted quiet renewal reason'
  [ -s "$dir/controlled-arm-term" ] || fail 'late watcher arm was not cancelled'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'quiet checkpoint starts after verified watcher readiness'
}

test_admission_time_preserves_arm_confirmation() {
  local dir original_root=$TEST_ROOT mode id limit baseline_limit delayed_limit started elapsed
  for mode in baseline delayed; do
    dir=$(fixture "admission-$mode")
    install_controlled_watcher "$dir"
    : > "$dir/state/task.meta"
    for id in $(seq 1 600); do
      printf '%s\n' ':' > "$dir/state/check-$id.check.sh"
    done
    if [ "$mode" = delayed ]; then
      mkdir "$dir/admission-fault"
      cat > "$dir/admission-fault/sitecustomize.py" <<'PY'
import os
import subprocess
import time

original_popen = subprocess.Popen


def delayed_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    marker = os.environ.get('FM_TEST_ADMISSION_MARKER', '')
    if (marker and isinstance(command, list) and len(command) > 2 and
            'budget-window' in command[2] and not os.path.exists(marker)):
        with open(marker, 'x', encoding='utf-8') as stream:
            stream.write('started\n')
        time.sleep(float(os.environ.get('FM_TEST_ADMISSION_DELAY', '0')))
        with open(marker + '.done', 'w', encoding='utf-8') as stream:
            stream.write('done\n')
    return original_popen(*args, **kwargs)


subprocess.Popen = delayed_popen
PY
      started=$(monotonic_seconds)
      PYTHONPATH="$dir/admission-fault" FM_TEST_ADMISSION_MARKER="$dir/admission-delay" \
        FM_TEST_ADMISSION_DELAY=5 FM_TEST_ARM_DELAY=2 FM_ARM_CONFIRM_TIMEOUT=3 \
        FM_CHECK_TIMEOUT=1 FM_SIGNAL_GRACE=0 TEST_ROOT="$dir" run_stop "$dir" 10
    else
      FM_TEST_ARM_DELAY=2 FM_ARM_CONFIRM_TIMEOUT=3 FM_CHECK_TIMEOUT=1 FM_SIGNAL_GRACE=0 \
        TEST_ROOT="$dir" run_stop "$dir" 10
    fi
    TEST_ROOT=$original_root
    wait_file "$dir/controlled-watcher-ready" 200
    limit=$(cat "$dir/controlled-check-limit")
    append_wake "$dir/state" check release "check: release $mode admission fixture"
    wait_file "$dir/rc" 200
    [ "$(cat "$dir/rc")" = 2 ] || fail "$mode admission run escaped Stop supervision"
    assert_contains "$(cat "$dir/out")" 'durable wake pending' "$mode admission run lost its wake"
    assert_not_contains "$(cat "$dir/out")" 'watcher failed' "$mode admission run shortened arm confirmation"
    if [ "$mode" = delayed ]; then
      delayed_limit=$limit
      elapsed=$(( $(monotonic_seconds) - started ))
      [ -s "$dir/admission-delay.done" ] || fail 'delayed admission did not execute'
      [ "$elapsed" -lt 20 ] || fail 'delayed admission escaped the bounded Stop window'
    else
      baseline_limit=$limit
    fi
    assert_no_watcher "$dir"
    finish "$dir"
  done
  [ "$delayed_limit" -lt "$baseline_limit" ] \
    || fail 'admission time was not debited from the watcher cycle budget'
  pass 'admission preserves arm confirmation and consumes cycle budget'
}

test_recurring_probe_honors_transport_deadline() {
  local dir original_root=$TEST_ROOT started elapsed
  dir=$(fixture recurring-probe-deadline)
  install_controlled_watcher "$dir"
  install_endpoint_inventory_tmux "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/probe-fault"
  cat > "$dir/probe-fault/sitecustomize.py" <<'PY'
import os
import subprocess
import time

original_popen = subprocess.Popen


def delayed_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    marker = os.environ.get('FM_TEST_RECURRING_PROBE_MARKER', '')
    if marker and isinstance(command, list) and len(command) > 2 and 'remote-recovery' in command[2]:
        count = 0
        try:
            with open(marker, encoding='utf-8') as stream:
                count = int(stream.read().strip())
        except (FileNotFoundError, ValueError):
            pass
        count += 1
        with open(marker, 'w', encoding='utf-8') as stream:
            stream.write(str(count) + '\n')
        if count == 2:
            time.sleep(16)
            with open(marker + '.done', 'w', encoding='utf-8') as stream:
                stream.write('done\n')
    return original_popen(*args, **kwargs)


subprocess.Popen = delayed_popen
PY
  started=$(monotonic_seconds)
  # A proven live owner conservatively charges its crew-state and worktree
  # paths. Leave enough transport budget for that first real cycle so the
  # injected delay lands on the recurring admission probe this case exercises.
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='firstmate:fm-task' \
    FM_TEST_LIVE_TARGETS='firstmate:fm-task' \
    PYTHONPATH="$dir/probe-fault" FM_TEST_RECURRING_PROBE_MARKER="$dir/recurring-probe" \
    FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=80 FM_ARM_CONFIRM_TIMEOUT=1 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 \
    FM_POLL=0.05 TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  # The injected recurring probe itself sleeps for 16 seconds.  Give the
  # harness enough time to observe its completion; the elapsed assertion below
  # remains the stricter product deadline.
  wait_file "$dir/rc" 300
  elapsed=$(( $(monotonic_seconds) - started ))
  [ -s "$dir/recurring-probe.done" ] || fail 'recurring cycle probe delay did not execute'
  [ "$(cat "$dir/rc")" = 2 ] || fail 'slow recurring cycle probe allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
    'slow recurring cycle probe lost the supervision-budget refusal'
  assert_not_contains "$(cat "$dir/out")" 'owner unavailable' \
    'slow recurring cycle probe fell through to the generic transport failure'
  [ "$elapsed" -lt 26 ] || fail 'slow recurring cycle probe overran its fixed transport reserve'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'recurring cycle probes preserve the fixed transport reserve'
}

test_idle_probe_wins_at_terminal_reserve() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture idle-at-terminal-reserve)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/idle-boundary-fault"
  cat > "$dir/idle-boundary-fault/sitecustomize.py" <<'PY'
import os
import subprocess
import time

original_popen = subprocess.Popen


def delayed_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    home = os.environ.get('FM_HOME', '')
    trigger = os.path.join(home, 'idle-boundary-trigger')
    done = os.path.join(home, 'idle-boundary-delay-done')
    if (os.path.exists(trigger) and not os.path.exists(done) and
            isinstance(command, list) and len(command) > 2 and
            'fm_supervision_needed' in command[2]):
        # Let the authoritative no-work result arrive as the controller enters
        # its terminal reserve. The result is still conclusive and must outrank
        # a synthesized deadline refusal.
        time.sleep(20)
        with open(done, 'w', encoding='utf-8') as stream:
            stream.write('done\n')
    return original_popen(*args, **kwargs)


subprocess.Popen = delayed_popen
PY
  PYTHONPATH="$dir/idle-boundary-fault" FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=55 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    FM_CREW_STATE_NM_TIMEOUT=1 FM_WORKTREE_WRITE_TIMEOUT=1 FM_SEND_REMOTE_BUDGET=1 \
    FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 FM_POLL=0.05 \
    TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready" 150
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" task
  ' _ "$ROOT/bin" || fail 'boundary fixture could not retire active ownership'
  rm "$dir/state/task.meta"
  : > "$dir/idle-boundary-trigger"
  wait_file "$dir/rc" 250
  [ -s "$dir/idle-boundary-delay-done" ] || fail 'boundary idle probe delay did not execute'
  [ "$(cat "$dir/rc")" = 0 ] || fail 'conclusive idle probe at the terminal reserve was discarded'
  assert_not_contains "$(cat "$dir/out")" 'Firstmate Codex supervision:' \
    'conclusive idle probe at the terminal reserve emitted a continuation'
  for _ in $(seq 1 80); do [ ! -e "$dir/state/.watch.lock" ] && break; sleep 0.1; done
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'conclusive idle probe outranks terminal reserve refusal'
}

test_registry_turnover_refreshes_budget_refusal() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture registry-turnover-budget)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/registry-turnover-fault"
  cat > "$dir/registry-turnover-fault/sitecustomize.py" <<'PY'
import json
import os
import subprocess

original_popen = subprocess.Popen


def owner_phase(home):
    try:
        with open(os.path.join(home, 'state', '.codex-stop.json'), encoding='utf-8') as stream:
            return json.load(stream).get('phase', '')
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return ''


def run_retirement(home):
    body = '''
. "$1/fm-wake-lib.sh"
. "$1/fm-backend.sh"
. "$1/fm-supervision-registry-lib.sh"
fm_supervision_registry_retire "$FM_STATE_OVERRIDE" task
'''
    environment = os.environ.copy()
    environment['FM_STATE_OVERRIDE'] = os.path.join(home, 'state')
    process = original_popen(
        ['bash', '-c', body, 'registry-turnover', os.path.join(home, 'bin')],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    _stdout, stderr = process.communicate()
    if process.returncode != 0:
        raise RuntimeError('could not retire turnover fixture: ' + stderr)
    try:
        os.unlink(os.path.join(home, 'state', 'task.meta'))
    except FileNotFoundError:
        pass
    with open(os.path.join(home, 'registry-turnover-retired'), 'w', encoding='utf-8') as stream:
        stream.write('done\n')


class RetiringNeedProbe:
    def __init__(self, process, home):
        self.process = process
        self.home = home

    def __getattr__(self, name):
        return getattr(self.process, name)

    def communicate(self, *args, **kwargs):
        result = self.process.communicate(*args, **kwargs)
        marker = os.path.join(self.home, 'registry-turnover-retired')
        with open(os.path.join(self.home, 'registry-turnover-needed.log'), 'a',
                  encoding='utf-8') as stream:
            stream.write(str(self.process.returncode) + '\n')
        if not os.path.exists(marker):
            run_retirement(self.home)
        return result


def turnover_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    home = os.environ.get('FM_HOME', '')
    trigger = os.path.join(home, 'registry-turnover-trigger')
    retired = os.path.join(home, 'registry-turnover-retired')
    admission_failed = os.path.join(home, 'registry-turnover-admission-failed')
    if (os.path.exists(trigger) and os.path.exists(retired) and
            not os.path.exists(admission_failed) and isinstance(command, list) and
            len(command) > 2 and 'remote-recovery' in command[2]):
        with open(admission_failed, 'w', encoding='utf-8') as stream:
            stream.write('done\n')
        replacement = ['bash', '-c', 'exit 1']
        if args:
            args = (replacement, *args[1:])
        else:
            kwargs['args'] = replacement
        return original_popen(*args, **kwargs)
    process = original_popen(*args, **kwargs)
    if (os.path.exists(trigger) and owner_phase(home) == 'preflighting' and
            isinstance(command, list) and len(command) > 2 and
            'fm_supervision_needed' in command[2]):
        return RetiringNeedProbe(process, home)
    return process


subprocess.Popen = turnover_popen
PY
  : > "$dir/registry-turnover-trigger"
  PYTHONPATH="$dir/registry-turnover-fault" FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=55 \
    FM_ARM_CONFIRM_TIMEOUT=1 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    FM_CREW_STATE_NM_TIMEOUT=1 FM_WORKTREE_WRITE_TIMEOUT=1 FM_SEND_REMOTE_BUDGET=1 \
    FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 FM_POLL=0.05 \
    TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 250
  [ -s "$dir/registry-turnover-retired" ] \
    || fail 'turnover fixture did not retire ownership after the prior need probe'
  [ -s "$dir/registry-turnover-admission-failed" ] \
    || fail 'turnover fixture did not invalidate the admission inventory scan'
  [ "$(tail -1 "$dir/registry-turnover-needed.log")" = 1 ] \
    || fail 'turnover refusal did not complete a fresh authoritative idle probe'
  [ "$(cat "$dir/rc")" = 0 ] \
    || fail 'stale pre-turnover need result converted an empty inventory into a budget refusal'
  assert_not_contains "$(cat "$dir/out")" 'Firstmate Codex supervision:' \
    'empty inventory after admission turnover emitted a continuation'
  for _ in $(seq 1 80); do [ ! -e "$dir/state/.watch.lock" ] && break; sleep 0.1; done
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'registry turnover refreshes supervision need before a budget refusal'
}

test_identity_and_cleanup_phases_preserve_transport_reserve() {
  local mode dir original_root=$TEST_ROOT started elapsed transport_timeout
  for mode in arm-identity active-cycle finish-identity cancel; do
    dir=$(fixture "transport-reserve-$mode")
    install_controlled_watcher "$dir"
    : > "$dir/state/task.meta"
    mkdir "$dir/deadline-fault"
    cat > "$dir/deadline-fault/sitecustomize.py" <<'PY'
import os
import subprocess
import time

original_popen = subprocess.Popen


def read_value(path):
    try:
        with open(path, encoding='utf-8') as stream:
            return stream.read().strip()
    except FileNotFoundError:
        return ''


def mark(path):
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write('hit\n')


def delayed_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    home = os.environ.get('FM_HOME', '')
    mode = os.environ.get('FM_TEST_DEADLINE_MODE', '')
    if isinstance(command, list) and len(command) > 2:
        body = command[2]
        target = command[-1]
        session_pid = read_value(os.path.join(home, 'state', '.lock'))
        marker = os.path.join(home, 'deadline-identity-hit')
        if 'fm_pid_identity' in body and not os.path.exists(marker):
            if mode == 'arm-identity':
                arm_pid_path = os.path.join(home, 'controlled-arm-pid')
                expires = time.monotonic() + 0.5
                while not os.path.exists(arm_pid_path) and time.monotonic() < expires:
                    time.sleep(0.01)
                if target == read_value(arm_pid_path):
                    mark(marker)
                    time.sleep(22)
            elif (mode == 'active-cycle' and target == session_pid and
                  os.path.exists(os.path.join(home, 'controlled-watcher-ready'))):
                mark(marker)
                time.sleep(22)
            elif (mode == 'finish-identity' and target == session_pid and
                  os.path.exists(os.path.join(home, 'controlled-arm-term'))):
                mark(marker)
                time.sleep(2)
        probe_marker = os.path.join(home, 'deadline-cycle-probe')
        if mode in ('finish-identity', 'cancel') and 'remote-recovery' in body:
            count = 0
            try:
                count = int(read_value(probe_marker))
            except ValueError:
                pass
            count += 1
            with open(probe_marker, 'w', encoding='utf-8') as stream:
                stream.write(str(count) + '\n')
            if count == 2:
                time.sleep(22)
                mark(probe_marker + '.done')
    return original_popen(*args, **kwargs)


subprocess.Popen = delayed_popen
PY
    started=$(monotonic_seconds)
    if [ "$mode" = cancel ]; then
      term_delay=2.5
      transport_timeout=85
    else
      term_delay=0
      transport_timeout=90
    fi
    # run_stop now registers a real live owner. Preserve this reserve fixture's
    # original geometry by adding exactly that owner's conservative 20-second
    # crew-state plus 10-second worktree-write charge.
    PYTHONPATH="$dir/deadline-fault" FM_TEST_DEADLINE_MODE="$mode" \
      FM_TEST_ARM_TERM_DELAY="$term_delay" FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT="$transport_timeout" \
      FM_ARM_CONFIRM_TIMEOUT=1 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
      FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 FM_POLL=0.05 \
      TEST_ROOT="$dir" run_stop "$dir" 1
    TEST_ROOT=$original_root
    # finish-identity deliberately stacks the 22-second recurring probe with
    # a 2-second cleanup identity probe.  A 25-second observation ceiling left
    # less than one second for startup, cancellation, and reap on clean Linux.
    # Let the explicit sub-40-second assertion below own the semantic bound.
    wait_file "$dir/rc" 450
    elapsed=$(( $(monotonic_seconds) - started ))
    [ "$(cat "$dir/rc")" = 2 ] || fail "$mode reserve path allowed Stop to fail open"
    assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
      "$mode reserve path lost the supervision-budget refusal"
    assert_not_contains "$(cat "$dir/out")" 'owner unavailable' \
      "$mode reserve path fell through to the generic transport failure"
    case "$mode" in
      arm-identity|active-cycle|finish-identity)
        [ -s "$dir/deadline-identity-hit" ] || fail "$mode identity delay did not execute"
        ;;
      cancel)
        [ -s "$dir/controlled-arm-term-delay-done" ] || fail 'cancel cleanup delay did not execute'
        ;;
    esac
    [ "$elapsed" -lt 40 ] || fail "$mode reserve path overran the fixed transport allowance"
    assert_no_watcher "$dir"
    finish "$dir"
  done
  pass 'identity and near-reserve cleanup finish before refusal commit'
}

test_registry_retirement_preserves_conclusive_generation_change() {
  local dir original_root=$TEST_ROOT
  dir=$(fixture retired-generation-cleanup)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  mkdir "$dir/retired-generation-fault"
  cat > "$dir/retired-generation-fault/sitecustomize.py" <<'PY'
import os
import subprocess

original_popen = subprocess.Popen


def read_value(path):
    try:
        with open(path, encoding='utf-8') as stream:
            return stream.read().strip()
    except FileNotFoundError:
        return ''


def generation_probe_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    home = os.environ.get('FM_HOME', '')
    trigger = os.path.join(home, 'retired-generation-trigger')
    if (os.path.exists(trigger) and isinstance(command, list) and len(command) > 2 and
            'fm_pid_identity' in command[2] and
            command[-1] == read_value(os.path.join(home, 'state', '.lock'))):
        count_path = os.path.join(home, 'retired-generation-probes')
        try:
            count = int(read_value(count_path))
        except ValueError:
            count = 0
        count += 1
        with open(count_path, 'w', encoding='utf-8') as stream:
            stream.write(str(count) + '\n')
        # The recurring probe conclusively observes a replaced session. If the
        # controller unnecessarily probes again after watcher cleanup, make
        # that second observation indeterminate so the regression fails.
        replacement = ['bash', '-c', 'exit 1' if count == 1 else 'sleep 30']
        if args:
            args = (replacement, *args[1:])
        else:
            kwargs['args'] = replacement
    return original_popen(*args, **kwargs)


subprocess.Popen = generation_probe_popen
PY
  # This fixture has no remote recovery work. Keep its shortened transport
  # lease internally consistent: the admission probe reserves the configured
  # remote-send bound before it can launch, while the regression begins only
  # after a watcher has been established.
  PYTHONPATH="$dir/retired-generation-fault" FM_TEST_ARM_TERM_DELAY=2.5 \
    FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=55 FM_ARM_CONFIRM_TIMEOUT=1 \
    FM_SEND_REMOTE_BUDGET=1 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 \
    FM_POLL=0.05 TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready" 150
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" task
  ' _ "$ROOT/bin" || fail 'retirement fixture could not retire active ownership'
  rm "$dir/state/task.meta"
  : > "$dir/retired-generation-trigger"
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/retired-generation-probes")" = 1 ] \
    || fail 'conclusive generation change was discarded and probed again after cleanup'
  [ -s "$dir/controlled-arm-term-delay-done" ] \
    || fail 'generation-change fixture did not consume its cleanup allowance'
  [ "$(cat "$dir/rc")" = 0 ] || fail 'proven generation change after registry retirement did not exit silently'
  assert_not_contains "$(cat "$dir/out")" 'Firstmate Codex supervision:' \
    'proven generation change after registry retirement emitted a continuation'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'registry retirement retains conclusive generation change across cleanup'
}

test_persistent_identity_timeout_fails_closed() {
  local mode dir original_root=$TEST_ROOT arm watcher phase
  for mode in recurring finish finally cancel; do
    dir=$(fixture "persistent-identity-$mode")
    install_controlled_watcher "$dir"
    : > "$dir/state/task.meta"
    mkdir "$dir/identity-fault"
    cat > "$dir/identity-fault/sitecustomize.py" <<'PY'
import os
import subprocess

original_popen = subprocess.Popen
original_pread = os.pread


def read_value(path):
    try:
        with open(path, encoding='utf-8') as stream:
            return stream.read().strip()
    except FileNotFoundError:
        return ''


def record_timeout(home):
    path = os.path.join(home, 'identity-timeout-count')
    try:
        count = int(read_value(path))
    except ValueError:
        count = 0
    with open(path, 'w', encoding='utf-8') as stream:
        stream.write(str(count + 1) + '\n')


def timed_out_popen(*args, **kwargs):
    command = args[0] if args else kwargs.get('args', [])
    home = os.environ.get('FM_HOME', '')
    mode = os.environ.get('FM_TEST_IDENTITY_TIMEOUT_MODE', '')
    if isinstance(command, list) and len(command) > 2 and 'fm_pid_identity' in command[2]:
        target = command[-1]
        session_pid = read_value(os.path.join(home, 'state', '.lock'))
        timeout = False
        if mode == 'recurring':
            timeout = (target == session_pid and
                       os.path.exists(os.path.join(home, 'controlled-watcher-ready')))
        elif mode == 'finish':
            timeout = (target == session_pid and
                       os.path.exists(os.path.join(home, 'controlled-arm-term')))
        elif mode == 'finally':
            timeout = (target == session_pid and
                       os.path.exists(os.path.join(home, 'finally-timeout-active')))
        elif mode == 'cancel':
            timeout = (target != session_pid and
                       os.path.exists(os.path.join(home, 'cancel-timeout-active')))
        if timeout:
            record_timeout(home)
            replacement = ['bash', '-c', 'sleep 30']
            if args:
                args = (replacement, *args[1:])
            else:
                kwargs['args'] = replacement
    return original_popen(*args, **kwargs)


def failed_pread(fd, length, offset):
    home = os.environ.get('FM_HOME', '')
    marker = os.path.join(home, 'finally-timeout-active')
    if (os.environ.get('FM_TEST_IDENTITY_TIMEOUT_MODE') == 'finally' and
            os.path.exists(os.path.join(home, 'controlled-watcher-ready')) and
            not os.path.exists(marker)):
        with open(marker, 'w', encoding='utf-8') as stream:
            stream.write('active\n')
        raise OSError('forced terminal identity uncertainty')
    return original_pread(fd, length, offset)


subprocess.Popen = timed_out_popen
os.pread = failed_pread
PY
    PYTHONPATH="$dir/identity-fault" FM_TEST_IDENTITY_TIMEOUT_MODE="$mode" \
      FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=60 FM_ARM_CONFIRM_TIMEOUT=1 \
      FM_SEND_REMOTE_BUDGET=1 \
      FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 \
      FM_POLL=0.05 TEST_ROOT="$dir" run_stop "$dir" 1
    TEST_ROOT=$original_root
    wait_file "$dir/controlled-watcher-ready" 150
    case "$mode" in
      finish)
        append_wake "$dir/state" check identity-timeout 'check: identity timeout finish'
        ;;
      cancel)
        phase=
        for _ in $(seq 1 100); do
          phase=$(jq -r .phase "$dir/state/.codex-stop.json" 2>/dev/null || true)
          [ "$phase" = watching ] && break
          sleep 0.1
        done
        [ "$phase" = watching ] || fail 'cancel timeout fixture never established watcher proof'
        printf '%s\n' active > "$dir/cancel-timeout-active"
        arm=$(cat "$dir/controlled-arm-pid")
        kill -KILL "$arm"
        ;;
    esac
    wait_file "$dir/rc" 300
    [ -s "$dir/identity-timeout-count" ] || fail "$mode persistent identity timeout did not execute"
    [ "$(cat "$dir/rc")" = 2 ] || fail "$mode identity uncertainty allowed Stop to succeed"
    assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
      "$mode identity uncertainty lost the supervision-budget refusal"
    assert_not_contains "$(cat "$dir/out")" 'owner unavailable' \
      "$mode identity uncertainty fell through to generic owner-unavailable"
    if [ "$mode" = cancel ]; then
      watcher=$(cat "$dir/state/.watch.lock/pid" 2>/dev/null || true)
      [ -z "$watcher" ] || kill -TERM "$watcher" 2>/dev/null || true
    else
      assert_no_watcher "$dir"
    fi
    finish "$dir"
  done
  pass 'persistent identity uncertainty preserves the specific Stop refusal'
}

test_terminal_error_generation_tristate() {
  local mode dir original_root=$TEST_ROOT
  for mode in current changed; do
    dir=$(fixture "terminal-error-$mode")
    install_controlled_watcher "$dir"
    : > "$dir/state/task.meta"
    mkdir "$dir/terminal-fault"
    cat > "$dir/terminal-fault/sitecustomize.py" <<'PY'
import os


original_pread = os.pread


def failed_pread(fd, length, offset):
    home = os.environ.get('FM_HOME', '')
    marker = os.path.join(home, 'terminal-error-triggered')
    if (os.path.exists(os.path.join(home, 'controlled-watcher-ready')) and
            not os.path.exists(marker)):
        with open(marker, 'w', encoding='utf-8') as stream:
            stream.write('active\n')
        if os.environ.get('FM_TEST_TERMINAL_ERROR_GENERATION') == 'changed':
            with open(os.path.join(home, 'state', '.lock'), 'w', encoding='utf-8') as stream:
                stream.write('99999999\n')
        raise OSError('forced terminal controller error')
    return original_pread(fd, length, offset)


os.pread = failed_pread
PY
    PYTHONPATH="$dir/terminal-fault" FM_TEST_TERMINAL_ERROR_GENERATION="$mode" \
      FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=60 FM_ARM_CONFIRM_TIMEOUT=1 \
      FM_SEND_REMOTE_BUDGET=1 \
      FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_GUARD_GRACE=1 FM_SIGNAL_GRACE=0 \
      FM_POLL=0.05 TEST_ROOT="$dir" run_stop "$dir" 1
    TEST_ROOT=$original_root
    wait_file "$dir/terminal-error-triggered" 150
    wait_file "$dir/rc" 150
    if [ "$mode" = current ]; then
      [ "$(cat "$dir/rc")" = 2 ] || fail 'current-generation terminal error allowed Stop to succeed'
      assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
        'current-generation terminal error lost the specific refusal'
      assert_not_contains "$(cat "$dir/out")" 'owner unavailable' \
        'current-generation terminal error fell through to generic owner-unavailable'
    else
      [ "$(cat "$dir/rc")" = 0 ] || fail 'proven generation change did not remain benign'
      assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
        'proven generation change emitted a stale refusal'
    fi
    assert_no_watcher "$dir"
    finish "$dir"
  done
  pass 'terminal errors distinguish current uncertain and changed generations'
}

test_current_generation_failure_episode_is_bounded() {
  local dir original_root=$TEST_ROOT first_arm_count
  dir=$(fixture bounded-failure-episode)
  install_controlled_watcher "$dir"
  printf '%s\n' 'kind=ship' 'harness=codex' 'spawn_gen=failure-episode-1' \
    > "$dir/state/task.meta"
  initialize_empty_active_supervision_registry "$dir"
  register_active_supervision_tasks "$dir" task
  FM_CODEX_REPEAT=1 FM_CODEX_REPEAT_PAUSE_FILE="$dir/repeat-paused" \
    FM_TEST_WATCH_MODE=stall FM_SIGNAL_GRACE=0 \
    TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/repeat-paused" 350
  [ "$(jq -r .phase "$dir/state/.codex-stop.json")" = handling ] \
    || fail 'first current-generation watcher failure did not enter bounded handling'
  cp "$dir/state/.codex-stop-failure-episode.json" "$dir/first-failure-episode"
  first_arm_count=$(wc -l < "$dir/controlled-arm-starts")
  [ "$first_arm_count" -eq 1 ] || fail 'first failure episode launched an unexpected arm count'
  touch "$dir/repeat-paused.release"
  wait_file "$dir/repeat-rc" 350
  [ "$(cat "$dir/rc")" = 2 ] || fail 'first current-generation watcher failure was not surfaced'
  [ "$(cat "$dir/repeat-rc")" = 0 ] \
    || fail 'unchanged current-generation watcher failure surfaced more than once'
  assert_contains "$(cat "$dir/out")" 'watcher failed' \
    'first current-generation failure lost its durable diagnostic'
  [ ! -s "$dir/repeat-out" ] \
    || fail 'deduplicated current-generation failure emitted a second continuation'
  [ "$(wc -l < "$dir/controlled-arm-starts")" -eq 1 ] \
    || fail 'deduplicated current-generation failure launched another watcher arm'
  wait_absent "$dir/state/.codex-stop.json"
  cmp "$dir/first-failure-episode" "$dir/state/.codex-stop-failure-episode.json" \
    || fail 'deduplicated current-generation failure replaced its durable episode'
  [ "$(jq -r .protocol "$dir/state/.codex-stop-failure-episode.json")" = fm-codex-stop-failure.v1 ] \
    || fail 'current-generation failure episode was not recorded durably'
  finish "$dir"

  dir=$(fixture regenerated-failure-episode)
  install_controlled_watcher "$dir"
  printf '%s\n' 'kind=ship' 'harness=codex' 'spawn_gen=failure-episode-2' \
    > "$dir/state/task.meta"
  initialize_empty_active_supervision_registry "$dir"
  register_active_supervision_tasks "$dir" task
  FM_CODEX_REPEAT=1 FM_CODEX_REPEAT_PAUSE_FILE="$dir/repeat-paused" \
    FM_TEST_WATCH_MODE=stall FM_SIGNAL_GRACE=0 TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/repeat-paused" 250
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" task "$FM_STATE_OVERRIDE/task.meta"
  ' _ "$ROOT/bin" || fail 'could not advance the active snapshot generation'
  touch "$dir/repeat-paused.release"
  wait_file "$dir/repeat-rc" 350
  [ "$(cat "$dir/rc")" = 2 ] && [ "$(cat "$dir/repeat-rc")" = 2 ] \
    || fail 'a changed active generation did not receive one new failure episode'
  assert_contains "$(cat "$dir/repeat-out")" 'watcher failed' \
    'changed generation incorrectly inherited the prior failure suppression'
  [ "$(wc -l < "$dir/controlled-arm-starts")" -eq 2 ] \
    || fail 'changed generation did not launch exactly one new watcher arm'
  finish "$dir"
  pass 'current-generation Stop failures surface once per unchanged episode'
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
  printf '%s\n' 'working: initial signal state' > "$dir/state/task.status"
  prime_status_seen "$dir/state" "$dir/state/task.status"
  FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 run_stop "$dir" 45
  wait_file "$dir/state/.watch.lock/pid"
  printf '%s\n' 'done: complete cycle' > "$dir/state/task.status"
  wait_file "$dir/rc" 450
  [ "$(cat "$dir/rc")" = 2 ] || fail 'complete watcher cycle lost its actionable wake'
  case $(cat "$dir/out") in
    *'watcher delivered an actionable wake'*|*'durable wake pending'*) ;;
    *) fail 'complete watcher cycle did not deliver its actionable wake' ;;
  esac
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
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_POLL=1 FM_SIGNAL_GRACE=30 \
    FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=300 FM_CODEX_BOUNDED_WATCH=1 \
    FM_CHECKS_PER_CYCLE=1 FM_CODEX_ADMISSION_GUARD_GRACE=10 \
    FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION=1 \
    "$dir/bin/fm-watch.sh" &
  watcher=$!
  printf '%s\n' "$watcher" > "$dir/sentinel-pid"
  wait_file "$dir/attached-watcher-ready"
  sleep 2
  FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 FM_CHECK_TIMEOUT=300 \
    TEST_ROOT="$dir" run_stop "$dir" 4
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

test_attached_arm_rejects_mismatched_bounded_runtime() {
  local dir original_root=$TEST_ROOT watcher mode watcher_timeout watcher_defer watcher_guard
  for mode in check-timeout remote-observation guard-grace; do
    dir=$(fixture "attached-mismatched-$mode")
    install_attached_watcher "$dir"
    : > "$dir/state/task.meta"
    watcher_timeout=300
    watcher_defer=1
    watcher_guard=3
    if [ "$mode" = remote-observation ]; then
      watcher_defer=0
    elif [ "$mode" = guard-grace ]; then
      watcher_guard=300
    fi
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_POLL=1 FM_SIGNAL_GRACE=30 \
      FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT="$watcher_timeout" \
      FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE=1 \
      FM_CODEX_ADMISSION_GUARD_GRACE="$watcher_guard" \
      FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION="$watcher_defer" \
      "$dir/bin/fm-watch.sh" &
    watcher=$!
    printf '%s\n' "$watcher" > "$dir/sentinel-pid"
    wait_file "$dir/attached-watcher-ready"
    if [ "$mode" = check-timeout ]; then
      FM_SIGNAL_GRACE=30 FM_CHECK_TIMEOUT=30 TEST_ROOT="$dir" run_stop "$dir" 2
    else
      FM_SIGNAL_GRACE=30 FM_CHECK_TIMEOUT=300 TEST_ROOT="$dir" run_stop "$dir" 2
    fi
    TEST_ROOT=$original_root
    wait_file "$dir/rc" 250
    [ "$(cat "$dir/rc")" = 2 ] || fail "$mode mismatch allowed Stop to fail open"
    assert_contains "$(cat "$dir/out")" 'watcher failed' "$mode mismatch omitted the refusal"
    assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' "$mode mismatch received bounded admission"
    kill -0 "$watcher" 2>/dev/null || fail "$mode mismatch killed the independently owned watcher"
    finish "$dir"
    kill -TERM "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  done
  pass 'attached watcher capability binds timeout, guard and remote observation'
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
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
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
    printf 'window=fleet:%s\nworktree=%s\nproject=%s\nbackend=tmux\nkind=ship\nharness=codex\nspawn_gen=%s-1\n' \
      "$id" "$dir" "$dir" "$id" > "$dir/state/$id.meta"
    printf '%s\n' 'working: initial signal state' > "$dir/state/$id.status"
    prime_status_seen "$dir/state" "$dir/state/$id.status"
  done
  register_active_supervision_tasks "$dir" first second third
  : > "$dir/classification-calls"
  PATH="$dir/fakebin:$PATH" \
    FM_TEST_EXISTING_TARGETS='fleet:first fleet:second fleet:third' \
    FM_TEST_LIVE_TARGETS='fleet:first fleet:second fleet:third' \
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
  local dir original_root=$TEST_ROOT id inventory_sessions
  dir=$(fixture stale-endpoint-inventory)
  install_controlled_watcher "$dir"
  install_endpoint_inventory_tmux "$dir"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-pending-reply-lib.sh"
    fm_pending_reply_index_recover "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" || fail 'could not initialize the pending-reply hot-set index'
  mkdir -p "$dir/state/pending-replies"
  mkdir -p "$dir/pooled-worktree"
  id=1
  while [ "$id" -le 10000 ]; do
    printf 'window=archive-%s:dead\nworktree=%s\nproject=%s\nspawn_gen=archive-%s\n' \
      "$id" "$dir/pooled-worktree" "$dir" "$id" \
      > "$dir/state/archive-$id.meta"
    printf 'done: archived-%s\n' "$id" > "$dir/state/archive-$id.status"
    printf 'archived-%s\n' "$id" > "$dir/state/archive-$id.turn-ended"
    printf 'schema=fm-pending-reply.v1\ncorr_id=%016x\ntask_id=archive-%s\nphase=awaiting_report\ndelivered_epoch=1\ngrace_secs=0\n' \
      "$id" "$id" > "$(printf '%s/pending-replies/%016x' "$dir/state" "$id")"
    id=$((id + 1))
  done
  mkdir -p "$dir/live-a-worktree" "$dir/live-b-worktree"
  printf 'window=fleet:live-a\nworktree=%s\nproject=%s\nspawn_gen=live-a\n' \
    "$dir/live-a-worktree" "$dir" > "$dir/state/live-a.meta"
  printf 'window=fleet:live-b\nworktree=%s\nproject=%s\nspawn_gen=live-b\n' \
    "$dir/live-b-worktree" "$dir" > "$dir/state/live-b.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" bootstrap bootstrap-gen || exit 1
    fm_supervision_registry_cancel_reservation "$FM_STATE_OVERRIDE" bootstrap bootstrap-gen || exit 1
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" live-a "$FM_STATE_OVERRIDE/live-a.meta" || exit 1
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" live-b "$FM_STATE_OVERRIDE/live-b.meta"
  ' _ "$ROOT/bin" || fail 'pre-Stop lifecycle mutation could not publish the bounded hot set'
  for id in $(seq 1 12); do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/state/check-$id.check.sh"
    chmod 0700 "$dir/state/check-$id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "check-$id" >/dev/null \
      || fail "could not register stale-inventory check $id"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:live-a fleet:live-b' \
    FM_TEST_LIVE_TARGETS='fleet:live-a fleet:live-b' \
    FM_TEST_INVENTORY_LOG="$dir/inventory-access" \
    FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 TEST_ROOT="$dir" run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release stale-endpoint inventory fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'stale endpoint history blocked the Codex Stop watcher'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' 'stale endpoint history prevented watcher startup'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'absent historical endpoints consumed the live cycle budget'
  inventory_sessions=$(LC_ALL=C sort -u "$dir/inventory-access")
  [ "$inventory_sessions" = fleet ] \
    || fail "archived endpoint paths entered recurring admission: $inventory_sessions"
  assert_not_contains "$(cat "$dir/out")" 'archive-' \
    'archived status, turn-end, or pending-reply records entered recurring supervision'
  assert_no_watcher "$dir"
  finish "$dir"
  pass '10,000 archived task records stay outside the active supervision hot set'
}

test_no_snapshot_bootstrap_discovers_live_ordinary_owners() {
  local dir original_root=$TEST_ROOT inventory inventory_sessions
  dir=$(fixture no-snapshot-live-ordinary-upgrade)
  install_controlled_watcher "$dir"
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' \
    'window=firstmate:fm-live-ship' "worktree=$dir/ship-worktree" "project=$dir" \
    'kind=ship' 'harness=codex' 'spawn_gen=ship-1' > "$dir/state/live-ship.meta"
  printf '%s\n' \
    'window=firstmate:fm-live-scout' "worktree=$dir/scout-worktree" "project=$dir" \
    'kind=scout' 'harness=codex' 'spawn_gen=scout-1' > "$dir/state/live-scout.meta"
  printf '%s\n' \
    'window=archive:fm-retired' "worktree=$dir/pooled-worktree" "project=$dir" \
    'kind=ship' 'harness=codex' 'spawn_gen=retired-1' > "$dir/state/retired.meta"
  mkdir -p "$dir/ship-worktree" "$dir/scout-worktree" "$dir/pooled-worktree"

  PATH="$dir/fakebin:$PATH" \
    FM_TEST_EXISTING_TARGETS='firstmate:fm-live-ship firstmate:fm-live-scout' \
    FM_TEST_LIVE_TARGETS='firstmate:fm-live-ship firstmate:fm-live-scout' \
    FM_TEST_INVENTORY_LOG="$dir/inventory-access" \
    FM_POLL=15 FM_SIGNAL_GRACE=30 FM_GUARD_GRACE=10 TEST_ROOT="$dir" run_stop "$dir" 180
  TEST_ROOT=$original_root
  wait_file "$dir/controlled-watcher-ready"
  append_wake "$dir/state" check release 'check: release no-snapshot live-owner fixture'
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 2 ] || fail 'no-snapshot live ordinary owners returned idle'
  assert_contains "$(cat "$dir/out")" 'durable wake pending' \
    'no-snapshot live ordinary owners did not arm supervision'
  inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" | sed 's|.*/||; s/\.meta$//') \
    || fail 'could not read the no-snapshot live-owner inventory'
  [ "$inventory" = $'live-scout\nlive-ship' ] \
    || fail "bounded bootstrap did not retain exactly live ordinary owners: $inventory"
  inventory_sessions=$(LC_ALL=C sort -u "$dir/inventory-access")
  [ "$inventory_sessions" = $'all\nfirstmate' ] \
    || fail "bounded bootstrap probed metadata-derived scopes: $inventory_sessions"
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'no-snapshot bootstrap retains live ordinary ship and scout owners'
}

test_no_snapshot_bootstrap_refuses_uncertain_backend_inventories() {
  local backend observation dir rc leftovers
  for backend in tmux herdr zellij cmux; do
    for observation in unavailable invalid; do
      dir=$(fixture "bootstrap-$backend-$observation")
      mkdir -p "$dir/fakebin"
      printf '%s\n' \
        'window=firstmate:fm-live-owner' "worktree=$dir/worktree" "project=$dir" \
        'kind=ship' 'harness=codex' "backend=$backend" 'spawn_gen=owner-1' \
        > "$dir/state/live-owner.meta"
      cat > "$dir/fakebin/$backend" <<'SH'
#!/usr/bin/env bash
case "$(basename "$0"):${FM_TEST_INVENTORY_OBSERVATION:-unavailable}" in
  tmux:invalid) printf '%s\n' 'invalid-row'; exit 0 ;;
  herdr:invalid) printf '%s\n' '{invalid'; exit 0 ;;
  zellij:invalid)
    case "${1:-}" in
      list-sessions) printf '%s\n' firstmate ;;
      *) printf '%s\n' '{invalid' ;;
    esac
    exit 0
    ;;
  cmux:invalid) printf '%s\n' '{invalid'; exit 0 ;;
  *) exit 71 ;;
esac
SH
      chmod 0700 "$dir/fakebin/$backend"
      set +e
      PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
        FM_STATE_OVERRIDE="$dir/state" FM_TEST_INVENTORY_OBSERVATION="$observation" bash -c '
          . "$1/fm-wake-lib.sh"
          . "$1/fm-backend.sh"
          . "$1/fm-supervision-registry-lib.sh"
          fm_supervision_registry_recover "$FM_STATE_OVERRIDE"
        ' _ "$ROOT/bin"
      rc=$?
      set -e
      [ "$rc" -ne 0 ] \
        || fail "$backend $observation inventory published a first registry generation"
      [ ! -e "$dir/state/.active-supervision-generation" ] \
        || fail "$backend $observation inventory left an authoritative registry snapshot"
      leftovers=$(find "$dir/state" -maxdepth 1 -name '.active-supervision-live.*' -print)
      [ -z "$leftovers" ] \
        || fail "$backend $observation inventory left bootstrap scratch state"
    done
  done
  pass 'no-snapshot bootstrap refuses unavailable and invalid backend inventories'
}

test_herdr_bulk_snapshot_bootstrap_is_conservative() {
  local mode dir target workspace tab inventory rc
  for mode in later-live partial; do
    dir=$(fixture "herdr-duplicate-workspace-$mode")
    mkdir -p "$dir/fakebin"
    case "$mode" in
      later-live) target=pane-live; workspace=w2; tab='tab-live' ;;
      partial) target=pane-first; workspace=w1; tab='tab-first' ;;
    esac
    printf '%s\n' \
      "window=fmtest:$target" "worktree=$dir/worktree" "project=$dir" \
      'kind=ship' 'harness=codex' 'backend=herdr' 'herdr_session=fmtest' \
      "herdr_workspace_id=$workspace" "herdr_tab_id=$tab" "herdr_pane_id=$target" \
      'spawn_gen=owner-1' \
      > "$dir/state/live-owner.meta"
    cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  session:list)
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true}]}'
    ;;
  workspace:list)
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"w2","label":"launcher"}]}}'
    ;;
  tab:list)
    case "${FM_TEST_HERDR_DUPLICATE_MODE:-}" in
      later-live) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-shell","label":"shell","workspace_id":"w1"},{"tab_id":"tab-live","label":"fm-live-owner","workspace_id":"w2"}]}}' ;;
      partial) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-first","label":"fm-live-owner","workspace_id":"w1"}]}}' ;;
      *) exit 71 ;;
    esac
    ;;
  pane:list)
    case "${FM_TEST_HERDR_DUPLICATE_MODE:-}" in
      later-live) printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"tab-shell","agent_status":"unknown"},{"pane_id":"pane-live","tab_id":"tab-live","agent_status":"working"}]}}' ;;
      partial) printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-other","tab_id":"tab-other","agent_status":"unknown"}]}}' ;;
      *) exit 71 ;;
    esac
    ;;
  *) exit 72 ;;
esac
SH
    chmod 0700 "$dir/fakebin/herdr"
    set +e
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      HERDR_SESSION=fmtest \
      FM_STATE_OVERRIDE="$dir/state" FM_TEST_HERDR_DUPLICATE_MODE="$mode" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin")
    rc=$?
    set -e
    if [ "$mode" = later-live ]; then
      [ "$rc" -eq 0 ] || fail 'later Herdr duplicate workspace blocked bootstrap'
      [ "$inventory" = "$dir/state/live-owner.meta" ] \
        || fail "later Herdr duplicate workspace lost its live owner: $inventory"
    else
      [ "$rc" -ne 0 ] || fail 'partial Herdr duplicate workspace inventory published a snapshot'
      [ ! -e "$dir/state/.active-supervision-generation" ] \
        || fail 'partial Herdr duplicate workspace inventory became authoritative'
    fi
  done
  pass 'Herdr session-wide snapshots are complete or rejected'
}

test_no_snapshot_bootstrap_covers_legacy_backend_layouts() {
  local backend dir inventory
  for backend in herdr zellij; do
    dir=$(fixture "bootstrap-$backend-valid-legacy-layout")
    mkdir -p "$dir/fakebin"
    case "$backend" in
      herdr)
        printf '%s\n' \
          'window=fmtest:pane-launcher-worker' "worktree=$dir/launcher-worktree" "project=$dir" \
          'kind=ship' 'harness=codex' 'backend=herdr' 'herdr_session=fmtest' \
          'herdr_workspace_id=launcher' 'herdr_tab_id=tab-launcher' \
          'herdr_pane_id=pane-launcher-worker' 'spawn_gen=launcher-1' \
          > "$dir/state/herdr-launcher.meta"
        printf '%s\n' \
          'window=fmtest:pane-presentation' "worktree=$dir/presentation-worktree" "project=$dir" \
          'kind=ship' 'harness=codex' 'backend=herdr' 'herdr_session=fmtest' \
          'herdr_workspace_id=presentation' 'herdr_tab_id=tab-presentation' \
          'herdr_pane_id=pane-presentation' 'spawn_gen=presentation-1' \
          > "$dir/state/herdr-presentation.meta"
        cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  session:list) printf '%s\n' '{"sessions":[{"name":"fmtest","running":true}]}' ;;
  workspace:list) printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"launcher","label":"captain"},{"workspace_id":"presentation","label":"└ herdr-presentation · p:abcdefghijklmnopqrstuv"}]}}' ;;
  tab:list) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-launcher","label":"fm-herdr-launcher","workspace_id":"launcher"},{"tab_id":"tab-presentation","label":"fm-herdr-presentation","workspace_id":"presentation"}]}}' ;;
  pane:list) printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-shell","tab_id":"tab-launcher","agent_status":"unknown"},{"pane_id":"pane-launcher-worker","tab_id":"tab-launcher","agent_status":"working"},{"pane_id":"pane-presentation","tab_id":"tab-presentation","agent_status":"working"}]}}' ;;
  *) exit 72 ;;
esac
SH
        chmod 0700 "$dir/fakebin/herdr"
        ;;
      zellij)
        printf '%s\n' \
          'window=zsession:8' "worktree=$dir/legacy-worktree" "project=$dir" \
          'kind=scout' 'harness=codex' 'backend=zellij' 'spawn_gen=legacy-1' \
          > "$dir/state/zellij-legacy.meta"
        cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-sessions ]; then
  printf '%s\n' zsession
  exit 0
fi
case "$*" in
  *" action list-tabs --json"*) printf '%s\n' '[{"tab_id":7,"name":"fm-zellij-legacy"}]' ;;
  *" action list-panes --json"*) printf '%s\n' '[{"tab_id":7,"id":6,"is_plugin":false},{"tab_id":7,"id":8,"is_plugin":false}]' ;;
  *) exit 71 ;;
esac
SH
        chmod 0700 "$dir/fakebin/zellij"
        ;;
    esac
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      HERDR_SESSION=fmtest FM_ZELLIJ_SESSION=zsession \
      FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin" | sed 's|.*/||; s/\.meta$//') \
      || fail "$backend valid legacy layout blocked no-snapshot bootstrap"
    case "$backend:$inventory" in
      herdr:$'herdr-launcher\nherdr-presentation'|zellij:zellij-legacy) ;;
      *) fail "$backend valid legacy layout produced the wrong inventory: $inventory" ;;
    esac
  done
  pass 'no-snapshot bootstrap retains valid Herdr and legacy Zellij layouts'
}

test_herdr_bootstrap_uses_bounded_bulk_inventory() {
  local dir inventory rc workspace_calls
  dir=$(fixture herdr-bounded-bulk-bootstrap)
  mkdir -p "$dir/fakebin"
  printf '%s\n' \
    'window=fmtest:pane-live' "worktree=$dir/worktree" "project=$dir" \
    'kind=ship' 'harness=codex' 'backend=herdr' 'herdr_session=fmtest' \
    'herdr_workspace_id=w-live' 'herdr_tab_id=tab-live' 'herdr_pane_id=pane-live' \
    'spawn_gen=owner-1' \
    > "$dir/state/live-owner.meta"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  session:list) printf '%s\n' '{"sessions":[{"name":"fmtest","running":true}]}' ;;
  workspace:list)
    printf '%s\n' "$*" >> "$FM_TEST_HERDR_WORKSPACE_SCAN"
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w-live","label":"firstmate"}]}}'
    ;;
  tab:list) printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-live","label":"fm-live-owner","workspace_id":"w-live"}]}}' ;;
  pane:list) printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-live","tab_id":"tab-live","agent_status":"working"}]}}' ;;
  *) exit 72 ;;
esac
SH
  chmod 0700 "$dir/fakebin/herdr"
  set +e
  inventory=$(perl -e '
    my $timeout=shift @ARGV;
    my $pid=fork;
    die unless defined $pid;
    if (!$pid) { exec @ARGV }
    local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 };
    alarm $timeout;
    waitpid $pid, 0;
    alarm 0;
    exit($? >> 8)
  ' 4 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    HERDR_SESSION=fmtest \
    FM_STATE_OVERRIDE="$dir/state" FM_TEST_HERDR_WORKSPACE_SCAN="$dir/workspace-scan" \
    bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
      fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "Herdr bulk bootstrap exceeded its bounded admission window: $rc"
  [ "$inventory" = "$dir/state/live-owner.meta" ] \
    || fail "Herdr bulk bootstrap lost its live owner: $inventory"
  workspace_calls=$(wc -l < "$dir/workspace-scan" | tr -d '[:space:]')
  [ "$workspace_calls" = 1 ] || fail "Herdr bootstrap took $workspace_calls workspace snapshots"
  ! grep -F -- '--workspace' "$dir/workspace-scan" >/dev/null \
    || fail 'Herdr bootstrap performed a per-workspace inventory read'
  pass 'Herdr bootstrap uses bounded session-wide bulk inventory'
}

test_bootstrap_inventory_uses_configured_backend_sessions() {
  local backend mode dir target inventory rc id session_calls
  for backend in herdr zellij; do
    for mode in complete incomplete; do
      dir=$(fixture "bootstrap-$backend-scoped-sessions-$mode")
      mkdir -p "$dir/fakebin"
      case "$backend" in
        herdr) target=bootstrap-target:pane-live ;;
        zellij) target=bootstrap-target:8 ;;
      esac
      printf '%s\n' \
        "window=$target" "worktree=$dir/worktree" "project=$dir" \
        'kind=ship' 'harness=codex' "backend=$backend" 'spawn_gen=owner-1' \
        > "$dir/state/live-owner.meta"
      if [ "$backend" = herdr ]; then
        printf '%s\n' 'herdr_session=bootstrap-target' 'herdr_workspace_id=w-live' \
          'herdr_tab_id=tab-live' 'herdr_pane_id=pane-live' \
          >> "$dir/state/live-owner.meta"
      fi
      case "$backend" in
        herdr)
          cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
case "${1:-}:${2:-}" in
  session:list)
    printf '%s' '{"sessions":['
    separator=
    n=1
    while [ "$n" -le 100 ]; do
      printf '%s{"name":"unrelated-%s","running":true}' "$separator" "$n"
      separator=,
      n=$((n + 1))
    done
    printf '%s\n' ',{"name":"bootstrap-target","running":true}]}'
    ;;
  workspace:list)
    if [ "$session" != bootstrap-target ]; then
      printf '%s\n' "$session" >> "$FM_TEST_UNRELATED_SESSION_LOG"
      sleep 10
      exit 71
    fi
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w-live","label":"firstmate"}]}}'
    ;;
  tab:list)
    if [ "$session" != bootstrap-target ]; then
      printf '%s\n' "$session" >> "$FM_TEST_UNRELATED_SESSION_LOG"
      sleep 10
      exit 71
    fi
    [ "$FM_TEST_SCOPED_SESSION_MODE" = complete ] || exit 71
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-live","label":"fm-live-owner","workspace_id":"w-live"}]}}'
    ;;
  pane:list)
    printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-live","tab_id":"tab-live","agent_status":"working"}]}}'
    ;;
  *) exit 72 ;;
esac
SH
          chmod 0700 "$dir/fakebin/herdr"
          ;;
        zellij)
          cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-sessions ]; then
  n=1
  while [ "$n" -le 100 ]; do
    printf 'unrelated-%s\n' "$n"
    n=$((n + 1))
  done
  printf '%s\n' bootstrap-target
  exit 0
fi
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
if [ "$session" != bootstrap-target ]; then
  printf '%s\n' "$session" >> "$FM_TEST_UNRELATED_SESSION_LOG"
  sleep 10
  exit 71
fi
case "$*" in
  *" action list-tabs --json"*)
    [ "$FM_TEST_SCOPED_SESSION_MODE" = complete ] || { printf '%s\n' '{invalid'; exit 0; }
    printf '%s\n' '[{"tab_id":7,"name":"fm-live-owner"}]'
    ;;
  *" action list-panes --json"*)
    printf '%s\n' '[{"tab_id":7,"id":8,"is_plugin":false}]'
    ;;
  *) exit 72 ;;
esac
SH
          chmod 0700 "$dir/fakebin/zellij"
          ;;
      esac
      set +e
      inventory=$(perl -e '
        my $timeout=shift @ARGV;
        my $pid=fork;
        die unless defined $pid;
        if (!$pid) { exec @ARGV }
        local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 };
        alarm $timeout;
        waitpid $pid, 0;
        alarm 0;
        exit($? >> 8)
      ' 4 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
        HERDR_SESSION=bootstrap-target FM_ZELLIJ_SESSION=bootstrap-target \
        FM_STATE_OVERRIDE="$dir/state" FM_TEST_SCOPED_SESSION_MODE="$mode" \
        FM_TEST_UNRELATED_SESSION_LOG="$dir/unrelated-sessions" bash -c '
          . "$1/fm-wake-lib.sh"
          . "$1/fm-backend.sh"
          . "$1/fm-supervision-registry-lib.sh"
          fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
          fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
        ' _ "$ROOT/bin")
      rc=$?
      set -e
      [ "$rc" -ne 124 ] || fail "$backend bootstrap read unrelated sessions until timeout"
      [ ! -e "$dir/unrelated-sessions" ] \
        || fail "$backend bootstrap inventoried unrelated sessions: $(cat "$dir/unrelated-sessions")"
      if [ "$mode" = complete ]; then
        [ "$rc" -eq 0 ] || fail "$backend scoped bootstrap inventory failed: $rc"
        [ "$inventory" = "$dir/state/live-owner.meta" ] \
          || fail "$backend scoped bootstrap lost its live owner: $inventory"
      else
        [ "$rc" -ne 0 ] || fail "$backend incomplete scoped inventory published a snapshot"
        [ ! -e "$dir/state/.active-supervision-generation" ] \
          || fail "$backend incomplete scoped inventory became authoritative"
      fi
    done
  done
  for backend in herdr zellij; do
    dir=$(fixture "bootstrap-$backend-prior-session")
    mkdir -p "$dir/fakebin"
    case "$backend" in
      herdr) target=old-session:pane-live ;;
      zellij) target=old-session:8 ;;
    esac
    printf '%s\n' \
      "window=$target" "worktree=$dir/worktree" "project=$dir" \
      'kind=ship' 'harness=codex' "backend=$backend" 'spawn_gen=owner-1' \
      > "$dir/state/live-owner.meta"
    if [ "$backend" = herdr ]; then
      printf '%s\n' 'herdr_session=old-session' 'herdr_workspace_id=w-live' \
        'herdr_tab_id=tab-live' 'herdr_pane_id=pane-live' \
        >> "$dir/state/live-owner.meta"
      cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
case "${1:-}:${2:-}" in
  session:list) printf '%s\n' '{"sessions":[{"name":"new-session","running":true},{"name":"old-session","running":true}]}' ;;
  tab:list)
    printf 'herdr\t%s\n' "$session" >> "$FM_TEST_SESSION_LOG"
    if [ "$session" = new-session ]; then
      printf '%s\n' '{"result":{"tabs":[]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"tab-live","label":"fm-live-owner","workspace_id":"w-live"}]}}'
    fi
    ;;
  workspace:list) printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w-live","label":"firstmate"}]}}' ;;
  pane:list) printf '%s\n' '{"result":{"panes":[{"pane_id":"pane-live","tab_id":"tab-live","agent_status":"working"}]}}' ;;
  *) exit 72 ;;
esac
SH
      chmod 0700 "$dir/fakebin/herdr"
    else
      cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-sessions ]; then
  printf '%s\n' new-session old-session
  exit 0
fi
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
case "$*" in
  *" action list-tabs --json"*)
    printf 'zellij\t%s\n' "$session" >> "$FM_TEST_SESSION_LOG"
    if [ "$session" = new-session ]; then
      printf '%s\n' '[]'
    else
      printf '%s\n' '[{"tab_id":7,"name":"fm-live-owner"}]'
    fi
    ;;
  *" action list-panes --json"*) printf '%s\n' '[{"tab_id":7,"id":8,"is_plugin":false}]' ;;
  *) exit 72 ;;
esac
SH
      chmod 0700 "$dir/fakebin/zellij"
    fi
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      HERDR_SESSION=new-session FM_ZELLIJ_SESSION=new-session \
      FM_STATE_OVERRIDE="$dir/state" FM_TEST_SESSION_LOG="$dir/session-inventory" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin") || fail "$backend prior-session bootstrap failed"
    [ "$inventory" = "$dir/state/live-owner.meta" ] \
      || fail "$backend prior-session bootstrap lost its live owner: $inventory"
    session_calls=$(LC_ALL=C sort -u "$dir/session-inventory")
    [ "$session_calls" = "$backend"$'\tnew-session\n'"$backend"$'\told-session' ] \
      || fail "$backend prior-session bootstrap read the wrong sessions: $session_calls"
  done
  dir=$(fixture bootstrap-historical-running-sessions)
  mkdir -p "$dir/fakebin"
  id=1
  while [ "$id" -le 5000 ]; do
    printf '%s\n' \
      "window=stale-herdr-$id:pane" "worktree=$dir/herdr-$id" "project=$dir" \
      'kind=ship' 'harness=codex' 'backend=herdr' "spawn_gen=herdr-$id" \
      > "$dir/state/herdr-$id.meta"
    printf '%s\n' \
      "window=stale-zellij-$id:8" "worktree=$dir/zellij-$id" "project=$dir" \
      'kind=scout' 'harness=codex' 'backend=zellij' "spawn_gen=zellij-$id" \
      > "$dir/state/zellij-$id.meta"
    id=$((id + 1))
  done
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}:${2:-}" = session:list ]; then
  printf '%s' '{"sessions":['
  separator=
  n=1
  while [ "$n" -le 5000 ]; do
    printf '%s{"name":"stale-herdr-%s","running":true}' "$separator" "$n"
    separator=,
    n=$((n + 1))
  done
  printf '%s\n' ',{"name":"current-herdr","running":true}]}'
  exit 0
fi
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
printf 'herdr\t%s\n' "$session" >> "$FM_TEST_SESSION_LOG"
[ "$session" = current-herdr ] || exit 71
case "${1:-}:${2:-}" in
  tab:list) printf '%s\n' '{"result":{"tabs":[]}}' ;;
  *) exit 72 ;;
esac
SH
  cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-sessions ]; then
  n=1
  while [ "$n" -le 5000 ]; do
    printf 'stale-zellij-%s\n' "$n"
    n=$((n + 1))
  done
  printf '%s\n' current-zellij
  exit 0
fi
session=
previous=
for argument in "$@"; do
  [ "$previous" = --session ] && session=$argument
  previous=$argument
done
printf 'zellij\t%s\n' "$session" >> "$FM_TEST_SESSION_LOG"
[ "$session" = current-zellij ] || exit 71
case "$*" in
  *" action list-tabs --json"*) printf '%s\n' '[]' ;;
  *) exit 72 ;;
esac
SH
  chmod 0700 "$dir/fakebin/herdr" "$dir/fakebin/zellij"
  set +e
  inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    HERDR_SESSION=current-herdr FM_ZELLIJ_SESSION=current-zellij \
    FM_STATE_OVERRIDE="$dir/state" FM_TEST_SESSION_LOG="$dir/session-inventory" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
      fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'oversized running-session inventory published a snapshot'
  [ ! -e "$dir/state/.active-supervision-generation" ] \
    || fail 'oversized running-session inventory became authoritative'
  [ ! -e "$dir/session-inventory" ] \
    || fail "oversized running-session inventory performed scoped reads: $(cat "$dir/session-inventory")"
  pass 'bootstrap inventory covers bounded active backend sessions'
}

test_bounded_bootstrap_rebinds_unique_live_targets() {
  local mode dir title old_workspace old_surface new_workspace new_surface second_workspace second_surface
  local inventory rc current_window current_workspace current_surface live_workspace live_surface workspace_label
  local canonical_home token foreign_home owner_label foreign_label recovery promotion recovery_rc promotion_rc
  old_workspace=aaaaaaaa-0000-0000-0000-000000000000
  old_surface=bbbbbbbb-1111-1111-1111-111111111111
  new_workspace=cccccccc-2222-2222-2222-222222222222
  new_surface=dddddddd-3333-3333-3333-333333333333
  second_workspace=eeeeeeee-4444-4444-4444-444444444444
  second_surface=ffffffff-5555-5555-5555-555555555555
  for mode in unique ambiguous; do
    dir=$(fixture "bounded-bootstrap-cmux-remap-$mode")
    mkdir -p "$dir/fakebin"
    title=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/backends/cmux.sh"
      fm_backend_cmux_scoped_title fm-live-owner
    ' _ "$ROOT/bin") || fail 'could not derive the cmux bootstrap title'
    printf '%s\n' \
      "window=$old_workspace:$old_surface" 'endpoint_task_id=live-owner' \
      "worktree=$dir/worktree" "project=$dir" 'kind=ship' 'harness=codex' \
      'backend=cmux' "cmux_workspace_id=$old_workspace" "cmux_surface_id=$old_surface" \
      'spawn_gen=owner-1' > "$dir/state/live-owner.meta"
    cat > "$dir/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  list-windows:*)
    count=2
    [ "$FM_TEST_CMUX_REMAP_MODE" = unique ] && count=1
    printf '[{"id":"11111111-6666-6666-6666-666666666666","workspace_count":1},{"id":"22222222-7777-7777-7777-777777777777","workspace_count":%s}]\n' "$count"
    ;;
  workspace:list)
    window=
    previous=
    for argument in "$@"; do
      [ "$previous" = --window ] && window=$argument
      previous=$argument
    done
    if [ -z "$window" ] || [ "$window" = 11111111-6666-6666-6666-666666666666 ]; then
      printf '%s\n' '{"workspaces":[{"id":"99999999-8888-8888-8888-888888888888","title":"zsh"}]}'
    elif [ "$FM_TEST_CMUX_REMAP_MODE" = unique ]; then
      printf '{"workspaces":[{"id":"%s","title":"%s"}]}\n' \
        "$FM_TEST_CMUX_WORKSPACE" "$FM_TEST_CMUX_TITLE"
    else
      printf '{"workspaces":[{"id":"%s","title":"%s"},{"id":"%s","title":"%s"}]}\n' \
        "$FM_TEST_CMUX_WORKSPACE" "$FM_TEST_CMUX_TITLE" \
        "$FM_TEST_CMUX_SECOND_WORKSPACE" "$FM_TEST_CMUX_TITLE"
    fi
    ;;
  list-panes:*)
    workspace=
    previous=
    for argument in "$@"; do
      [ "$previous" = --workspace ] && workspace=$argument
      previous=$argument
    done
    case "$workspace" in
      "$FM_TEST_CMUX_WORKSPACE") surface=$FM_TEST_CMUX_SURFACE ;;
      "$FM_TEST_CMUX_SECOND_WORKSPACE") surface=$FM_TEST_CMUX_SECOND_SURFACE ;;
      *) exit 71 ;;
    esac
    printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}\n' \
      "$surface" "$surface"
    ;;
  *) exit 72 ;;
esac
SH
    chmod 0700 "$dir/fakebin/cmux"
    set +e
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$dir/state" FM_TEST_CMUX_REMAP_MODE="$mode" \
      FM_TEST_CMUX_TITLE="$title" FM_TEST_CMUX_WORKSPACE="$new_workspace" \
      FM_TEST_CMUX_SURFACE="$new_surface" FM_TEST_CMUX_SECOND_WORKSPACE="$second_workspace" \
      FM_TEST_CMUX_SECOND_SURFACE="$second_surface" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin")
    rc=$?
    set -e
    current_window=$(sed -n 's/^window=//p' "$dir/state/live-owner.meta")
    current_workspace=$(sed -n 's/^cmux_workspace_id=//p' "$dir/state/live-owner.meta")
    current_surface=$(sed -n 's/^cmux_surface_id=//p' "$dir/state/live-owner.meta")
    if [ "$mode" = unique ]; then
      [ "$rc" -eq 0 ] || fail 'unique cmux relaunch target blocked bounded bootstrap'
      [ "$inventory" = "$dir/state/live-owner.meta" ] \
        || fail "unique cmux relaunch target lost its live owner: $inventory"
      [ "$current_window" = "$new_workspace:$new_surface" ] \
        && [ "$current_workspace" = "$new_workspace" ] \
        && [ "$current_surface" = "$new_surface" ] \
        || fail 'unique cmux relaunch target did not normalize durable endpoint identity'
    else
      [ "$rc" -ne 0 ] || fail 'ambiguous cmux relaunch targets published a snapshot'
      [ ! -e "$dir/state/.active-supervision-generation" ] \
        || fail 'ambiguous cmux relaunch targets became authoritative'
      [ "$current_window" = "$old_workspace:$old_surface" ] \
        && [ "$current_workspace" = "$old_workspace" ] \
        && [ "$current_surface" = "$old_surface" ] \
        || fail 'ambiguous cmux relaunch targets rewrote durable endpoint identity'
    fi
  done
  old_workspace=old-workspace
  old_surface=old:pane
  new_workspace=new-workspace
  new_surface=new:pane
  second_workspace='second-workspace'
  second_surface=second:pane
  for mode in exact exact-mismatch exact-ambiguous launcher foreign-primary foreign-secondmate copied-presentation sibling captain ambiguous; do
    dir=$(fixture "bounded-bootstrap-herdr-remap-$mode")
    mkdir -p "$dir/fakebin"
    live_workspace=$new_workspace
    live_surface=$new_surface
    case "$mode" in
      exact|exact-ambiguous)
        live_workspace=$old_workspace
        live_surface=$old_surface
        workspace_label=captain
        ;;
      exact-mismatch)
        live_surface=$old_surface
        workspace_label=captain
        ;;
      launcher) live_workspace=$old_workspace; workspace_label=captain ;;
      foreign-secondmate)
        foreign_home="$dir/foreign-home"
        mkdir -p "$foreign_home/state"
        printf '%s\n' alpha > "$dir/.fm-secondmate-home"
        printf '%s\n' alpha > "$foreign_home/.fm-secondmate-home"
        owner_label=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
          . "$1/backends/herdr.sh"
          fm_backend_herdr_workspace_label
        ' _ "$ROOT/bin") || fail 'could not derive the owner secondmate Herdr workspace label'
        foreign_label=$(FM_HOME="$foreign_home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
          . "$1/backends/herdr.sh"
          fm_backend_herdr_workspace_label
        ' _ "$ROOT/bin") || fail 'could not derive the foreign secondmate Herdr workspace label'
        [ "$owner_label" = 2ndmate-alpha ] && [ "$foreign_label" = 2ndmate-alpha ] \
          || fail 'secondmate Herdr homes did not reproduce the shared workspace label'
        workspace_label=$foreign_label
        ;;
      copied-presentation)
        foreign_home="$dir/foreign-home"
        mkdir -p "$foreign_home/state"
        token=abcdefghijklmnopqrstuv
        workspace_label="└ live-owner · p:$token"
        canonical_home=$(cd "$dir" && pwd -P)
        printf '%s\n' \
          'version=2' 'task_id=live-owner' "projection_id=$token" \
          "home=$canonical_home" 'session=default' "workspace_id=$old_workspace" \
          'tab_id=old-tab' "pane_id=$old_surface" 'parent_workspace_id=parent-workspace' \
          'parent_label=firstmate' "workspace_label=$workspace_label" 'task_label=fm-live-owner' \
          > "$dir/state/live-owner.herdr-presentation"
        ;;
      foreign-primary)
        foreign_home="$dir/foreign-home"
        mkdir -p "$foreign_home/state"
        owner_label=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
          . "$1/backends/herdr.sh"
          fm_backend_herdr_workspace_label
        ' _ "$ROOT/bin") || fail 'could not derive the owner Herdr workspace label'
        foreign_label=$(FM_HOME="$foreign_home" FM_ROOT_OVERRIDE="$ROOT" bash -c '
          . "$1/backends/herdr.sh"
          fm_backend_herdr_workspace_label
        ' _ "$ROOT/bin") || fail 'could not derive the foreign Herdr workspace label'
        [ "$owner_label" = firstmate ] && [ "$foreign_label" = firstmate ] \
          || fail 'primary Herdr homes did not reproduce the shared workspace label'
        workspace_label=$foreign_label
        ;;
      ambiguous) workspace_label=firstmate ;;
      sibling) workspace_label=2ndmate-sibling ;;
      captain) workspace_label=captain ;;
    esac
    printf '%s\n' \
      "window=default:$old_surface" 'endpoint_task_id=live-owner' \
      "worktree=$dir/worktree" "project=$dir" 'kind=ship' 'harness=codex' \
      'backend=herdr' 'herdr_session=default' "herdr_workspace_id=$old_workspace" \
      'herdr_tab_id=old-tab' "herdr_pane_id=$old_surface" 'spawn_gen=owner-1' \
      > "$dir/state/live-owner.meta"
    cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  session:list) printf '%s\n' '{"sessions":[{"name":"default","running":true}]}' ;;
  workspace:list)
    if [ "$FM_TEST_HERDR_REMAP_MODE" = ambiguous ] \
      || [ "$FM_TEST_HERDR_REMAP_MODE" = exact-ambiguous ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"%s","label":"%s"},{"workspace_id":"%s","label":"%s"}]}}\n' \
        "$FM_TEST_HERDR_WORKSPACE" "$FM_TEST_HERDR_WORKSPACE_LABEL" \
        "$FM_TEST_HERDR_SECOND_WORKSPACE" "$FM_TEST_HERDR_WORKSPACE_LABEL"
    else
      printf '{"result":{"workspaces":[{"workspace_id":"%s","label":"%s"}]}}\n' \
        "$FM_TEST_HERDR_WORKSPACE" "$FM_TEST_HERDR_WORKSPACE_LABEL"
    fi
    ;;
  tab:list)
    if [ "$FM_TEST_HERDR_REMAP_MODE" != ambiguous ] \
      && [ "$FM_TEST_HERDR_REMAP_MODE" != exact-ambiguous ]; then
      case "$FM_TEST_HERDR_REMAP_MODE" in
        launcher|exact) tab=old-tab ;;
        *) tab=new-tab ;;
      esac
      printf '{"result":{"tabs":[{"tab_id":"%s","label":"fm-live-owner","workspace_id":"%s"}]}}\n' \
        "$tab" "$FM_TEST_HERDR_WORKSPACE"
    else
      tab=new-tab
      [ "$FM_TEST_HERDR_REMAP_MODE" != exact-ambiguous ] || tab=old-tab
      printf '{"result":{"tabs":[{"tab_id":"%s","label":"fm-live-owner","workspace_id":"%s"},{"tab_id":"second-tab","label":"fm-live-owner","workspace_id":"%s"}]}}\n' \
        "$tab" "$FM_TEST_HERDR_WORKSPACE" "$FM_TEST_HERDR_SECOND_WORKSPACE"
    fi
    ;;
  pane:list)
    if [ "$FM_TEST_HERDR_REMAP_MODE" != ambiguous ] \
      && [ "$FM_TEST_HERDR_REMAP_MODE" != exact-ambiguous ]; then
      case "$FM_TEST_HERDR_REMAP_MODE" in
        launcher|exact) tab=old-tab ;;
        *) tab=new-tab ;;
      esac
      printf '{"result":{"panes":[{"pane_id":"%s","tab_id":"%s","agent_status":"working"}]}}\n' \
        "$FM_TEST_HERDR_PANE" "$tab"
    else
      tab=new-tab
      [ "$FM_TEST_HERDR_REMAP_MODE" != exact-ambiguous ] || tab=old-tab
      printf '{"result":{"panes":[{"pane_id":"%s","tab_id":"%s","agent_status":"working"},{"pane_id":"%s","tab_id":"second-tab","agent_status":"working"}]}}\n' \
        "$FM_TEST_HERDR_PANE" "$tab" "$FM_TEST_HERDR_SECOND_PANE"
    fi
    ;;
  *) exit 72 ;;
esac
SH
    chmod 0700 "$dir/fakebin/herdr"
    set +e
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$dir/state" FM_TEST_HERDR_REMAP_MODE="$mode" \
      FM_TEST_HERDR_WORKSPACE="$live_workspace" FM_TEST_HERDR_WORKSPACE_LABEL="$workspace_label" \
      FM_TEST_HERDR_PANE="$live_surface" \
      FM_TEST_HERDR_SECOND_WORKSPACE="$second_workspace" \
      FM_TEST_HERDR_SECOND_PANE="$second_surface" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin")
    rc=$?
    set -e
    current_window=$(sed -n 's/^window=//p' "$dir/state/live-owner.meta")
    current_workspace=$(sed -n 's/^herdr_workspace_id=//p' "$dir/state/live-owner.meta")
    current_surface=$(sed -n 's/^herdr_pane_id=//p' "$dir/state/live-owner.meta")
    case "$mode" in
      exact)
        [ "$rc" -eq 0 ] || fail 'unique exact Herdr binding blocked bounded bootstrap'
        [ "$inventory" = "$dir/state/live-owner.meta" ] \
          || fail "unique exact Herdr binding lost its live owner: $inventory"
        [ "$current_window" = "default:$old_surface" ] \
          && [ "$current_workspace" = "$old_workspace" ] \
          && [ "$current_surface" = "$old_surface" ] \
          || fail 'unique exact Herdr binding rewrote durable endpoint identity'
        ;;
      launcher)
        [ "$rc" -eq 0 ] || fail "$mode-owned Herdr target remap blocked bounded bootstrap"
        [ "$inventory" = "$dir/state/live-owner.meta" ] \
          || fail "$mode-owned Herdr target remap lost its live owner: $inventory"
        [ "$current_window" = "default:$new_surface" ] \
          && [ "$current_workspace" = "$old_workspace" ] \
          && [ "$current_surface" = "$new_surface" ] \
          || fail "$mode-owned Herdr target remap did not normalize durable endpoint identity"
        ;;
      exact-mismatch|exact-ambiguous|foreign-primary|foreign-secondmate|copied-presentation|sibling|captain|ambiguous)
        [ "$rc" -ne 0 ] || fail "$mode Herdr target remap published a snapshot"
        [ ! -e "$dir/state/.active-supervision-generation" ] \
          || fail "$mode Herdr target remap became authoritative"
        [ "$current_window" = "default:$old_surface" ] \
          && [ "$current_workspace" = "$old_workspace" ] \
          && [ "$current_surface" = "$old_surface" ] \
          || fail "$mode Herdr target remap rewrote durable endpoint identity"
        ;;
    esac
  done
  dir=$(fixture bounded-bootstrap-remap-metadata-race)
  mkdir -p "$dir/fakebin"
  old_workspace=aaaaaaaa-0000-0000-0000-000000000000
  old_surface=bbbbbbbb-1111-1111-1111-111111111111
  new_workspace=cccccccc-2222-2222-2222-222222222222
  new_surface=dddddddd-3333-3333-3333-333333333333
  title=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/backends/cmux.sh"
    fm_backend_cmux_scoped_title fm-live-owner
  ' _ "$ROOT/bin") || fail 'could not derive the concurrent cmux bootstrap title'
  printf '%s\n' \
    "window=$old_workspace:$old_surface" 'endpoint_task_id=live-owner' \
    "worktree=$dir/worktree" "project=$dir" 'kind=scout' 'harness=codex' \
    'backend=cmux' "cmux_workspace_id=$old_workspace" "cmux_surface_id=$old_surface" \
    'spawn_gen=owner-1' > "$dir/state/live-owner.meta"
  cat > "$dir/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  list-windows:*)
    printf '%s\n' '[{"id":"11111111-6666-6666-6666-666666666666","workspace_count":1}]'
    ;;
  workspace:list)
    printf '{"workspaces":[{"id":"%s","title":"%s"}]}\n' \
      "$FM_TEST_CMUX_WORKSPACE" "$FM_TEST_CMUX_TITLE"
    ;;
  list-panes:*)
    printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}\n' \
      "$FM_TEST_CMUX_SURFACE" "$FM_TEST_CMUX_SURFACE"
    ;;
  *) exit 72 ;;
esac
SH
  chmod 0700 "$dir/fakebin/cmux"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_TEST_CMUX_TITLE="$title" \
    FM_TEST_CMUX_WORKSPACE="$new_workspace" FM_TEST_CMUX_SURFACE="$new_surface" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_backend_agent_state_batch() {
        printf "%s\n" observing > "$FM_HOME/recovery-observing"
        while [ ! -e "$FM_HOME/release-recovery" ]; do sleep 0.01; done
        while IFS="$(printf "\t")" read -r backend target route home; do
          printf "%s\t%s\tunverified\t%s\t%s\n" "$backend" "$target" "$route" "$home"
        done
      }
      fm_supervision_registry_recover "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin" > "$dir/recovery.out" 2> "$dir/recovery.err" &
  recovery=$!
  wait_file "$dir/recovery-observing" 100
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_TEST_CMUX_TITLE="$title" \
    FM_TEST_CMUX_WORKSPACE="$new_workspace" FM_TEST_CMUX_SURFACE="$new_surface" \
    "$ROOT/bin/fm-promote.sh" live-owner --mode direct-PR --yolo off \
    > "$dir/promotion.out" 2> "$dir/promotion.err" &
  promotion=$!
  for _ in $(seq 1 100); do
    [ -d "$dir/state/.control-live-owner.lock" ] && break
    sleep 0.01
  done
  [ -d "$dir/state/.control-live-owner.lock" ] \
    || fail 'concurrent promotion did not acquire its lifecycle lock'
  grep -qx 'kind=scout' "$dir/state/live-owner.meta" \
    || fail 'concurrent promotion committed metadata before registry recovery'
  kill -0 "$promotion" 2>/dev/null \
    || fail 'concurrent promotion did not wait for registry recovery'
  : > "$dir/release-recovery"
  set +e
  wait "$recovery"
  recovery_rc=$?
  wait "$promotion"
  promotion_rc=$?
  set -e
  [ "$recovery_rc" -eq 0 ] || fail 'registry recovery failed while promotion waited to commit'
  [ "$promotion_rc" -eq 0 ] \
    || fail "concurrent promotion failed after bootstrap contention: $(cat "$dir/promotion.err")"
  if grep -qx 'kind=ship' "$dir/state/live-owner.meta" \
    && grep -qx 'mode=direct-PR' "$dir/state/live-owner.meta" \
    && grep -qx 'yolo=off' "$dir/state/live-owner.meta"; then
    :
  else
    fail 'live-target normalization lost the concurrent promotion contract'
  fi
  [ "$(sed -n 's/^window=//p' "$dir/state/live-owner.meta")" = "$new_workspace:$new_surface" ] \
    || fail 'pre-promotion recovery did not normalize the live target'
  inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin") || fail 'concurrent promotion did not publish active supervision'
  [ "$inventory" = "$dir/state/live-owner.meta" ] \
    || fail 'concurrent promotion lost its active supervision entry'
  pass 'bounded bootstrap safely rebinds proven live endpoints'
}

test_zellij_scoped_title_alias_bootstrap_is_conservative() {
  local mode dir home_tag legacy_task title inventory rc
  for mode in scoped legacy ambiguous; do
    dir=$(fixture "zellij-scoped-title-alias-$mode")
    mkdir -p "$dir/fakebin"
    home_tag=$(FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
      . "$1/backends/zellij.sh"
      fm_backend_zellij_home_label
    ' _ "$ROOT/bin") || fail 'could not derive the Zellij home tag'
    legacy_task="$home_tag-job"
    title="fm-$legacy_task"
    case "$mode" in
      scoped|ambiguous)
        printf '%s\n' \
          'window=zsession:8' "worktree=$dir/scoped-worktree" "project=$dir" \
          'kind=ship' 'harness=codex' 'backend=zellij' 'spawn_gen=scoped-1' \
          > "$dir/state/job.meta"
        ;;
    esac
    case "$mode" in
      legacy|ambiguous)
        printf '%s\n' \
          'window=zsession:8' "worktree=$dir/legacy-worktree" "project=$dir" \
          'kind=ship' 'harness=codex' 'backend=zellij' 'spawn_gen=legacy-1' \
          > "$dir/state/$legacy_task.meta"
        ;;
    esac
    cat > "$dir/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-sessions ]; then
  printf '%s\n' zsession
  exit 0
fi
case "$*" in
  *" action list-tabs --json"*) printf '[{"tab_id":7,"name":"%s"}]\n' "$FM_TEST_ZELLIJ_ALIAS_TITLE" ;;
  *" action list-panes --json"*) printf '%s\n' '[{"tab_id":7,"id":8,"is_plugin":false}]' ;;
  *) exit 71 ;;
esac
SH
    chmod 0700 "$dir/fakebin/zellij"
    set +e
    inventory=$(PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_ZELLIJ_SESSION=zsession \
      FM_STATE_OVERRIDE="$dir/state" FM_TEST_ZELLIJ_ALIAS_TITLE="$title" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-backend.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
        fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
      ' _ "$ROOT/bin")
    rc=$?
    set -e
    case "$mode" in
      scoped)
        [ "$rc" -eq 0 ] || fail 'scoped Zellij identity blocked bootstrap'
        [ "$inventory" = "$dir/state/job.meta" ] \
          || fail "scoped Zellij identity resolved incorrectly: $inventory"
        ;;
      legacy)
        [ "$rc" -eq 0 ] || fail 'legacy Zellij identity blocked bootstrap'
        [ "$inventory" = "$dir/state/$legacy_task.meta" ] \
          || fail "legacy Zellij identity resolved incorrectly: $inventory"
        ;;
      ambiguous)
        [ "$rc" -ne 0 ] || fail 'ambiguous Zellij title alias published two owners'
        [ ! -e "$dir/state/.active-supervision-generation" ] \
          || fail 'ambiguous Zellij title alias became authoritative'
        ;;
    esac
  done
  pass 'Zellij title aliases resolve uniquely or block bootstrap'
}

test_bounded_event_wait_uses_active_registry() {
  local dir rc
  dir=$(fixture bounded-event-wait-inventory)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  mkdir -p "$dir/live-worktree"
  printf 'window=archive-session:archive-pane\nbackend=herdr\nspawn_gen=archive-gen\n' \
    > "$dir/state/archive.meta"
  printf 'window=fleet:live\nworktree=%s\nproject=%s\nspawn_gen=live-gen\n' \
    "$dir/live-worktree" "$dir" > "$dir/state/live.meta"
  register_active_supervision_tasks "$dir" live
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
exit 1
SH
  chmod +x "$dir/fakebin/herdr"
  set +e
  FM_TEST_HERDR_LOG="$dir/herdr-calls" FM_TEST_EXISTING_TARGETS='fleet:live' \
    FM_TEST_LIVE_TARGETS='fleet:live' FM_TEST_BOUNDED_WATCH_TIMEOUT=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "bounded watcher did not complete observer cycles: rc=$rc $(cat "$dir/watch.err")"
  [ -e "$dir/state/.last-watcher-beat" ] || fail 'bounded watcher never completed an observer cycle'
  [ ! -e "$dir/herdr-calls" ] \
    || fail "bounded event wait revisited archived Herdr metadata: $(cat "$dir/herdr-calls")"
  pass 'bounded event wait reads only active registry owners'
}

test_production_shaped_stale_inventory_arms_supervision() {
  local dir id active_inventory registered_checks inventory_sessions now old_mtime age
  dir=$(fixture production-shaped-stale-inventory)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  id=1
  while [ "$id" -le 59 ]; do
    printf 'window=archive-%s:dead\nspawn_gen=archive-%s\n' "$id" "$id" \
      > "$dir/state/archive-$id.meta"
    id=$((id + 1))
  done
  for id in live-a live-b; do
    printf 'window=fleet:%s\nworktree=%s\nproject=%s\nbackend=tmux\nkind=secondmate\nharness=codex\nspawn_gen=%s-1\n' \
      "$id" "$dir" "$dir" "$id" > "$dir/state/$id.meta"
  done
  register_active_supervision_tasks "$dir" live-a live-b
  active_inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" | sed 's|.*/||; s/\.meta$//') \
    || fail 'could not read the production-shaped active inventory'
  [ "$active_inventory" = $'live-a\nlive-b' ] \
    || fail "live-only inventory did not retain exactly the active endpoints: $active_inventory"

  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" ran > "$FM_HOME/production-due-check-ran"' \
    'printf "%s\n" ready' > "$dir/state/production-due.check.sh"
  chmod 0700 "$dir/state/production-due.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" production-due >/dev/null \
    || fail 'could not register the production-shaped due check'
  registered_checks=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-pr-lib.sh"
    fm_check_index_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin") || fail 'could not read the production-shaped check index'
  [ "$registered_checks" = "$dir/state/production-due.check.sh" ] \
    || fail "production-shaped check index was not exact: $registered_checks"
  : > "$dir/state/.last-check"
  now=$(date +%s)
  old_mtime=$((now - 93415))
  python3 - "$dir/state/.last-check" "$old_mtime" <<'PY'
import os
import sys

stamp = int(sys.argv[2])
os.utime(sys.argv[1], (stamp, stamp))
PY
  age=$(( $(date +%s) - $(python3 -c 'import os, sys; print(int(os.path.getmtime(sys.argv[1])))' "$dir/state/.last-check") ))
  [ "$age" -ge 93415 ] && [ "$age" -le 93416 ] \
    || fail "production-shaped check age was $age seconds instead of 93415"

  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:live-a fleet:live-b' \
    FM_TEST_LIVE_TARGETS='fleet:live-a fleet:live-b' \
    FM_TEST_INVENTORY_LOG="$dir/inventory-access" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=10 FM_CHECK_INTERVAL=300 \
    FM_CHECK_TIMEOUT=5 \
    run_stop "$dir" 120
  wait_file "$dir/rc" 450
  [ "$(cat "$dir/rc")" = 2 ] \
    || fail 'production-shaped stale inventory blocked Codex Stop supervision'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
    '59 stale metadata records multiplied the watcher admission budget'
  wait_file "$dir/production-due-check-ran" 10
  assert_contains "$(cat "$dir/state/.wake-queue")" 'production-due.check.sh' \
    'the sole overdue registered check was not retained by the live watcher cycle'
  inventory_sessions=$(LC_ALL=C sort -u "$dir/inventory-access")
  [ "$inventory_sessions" = fleet ] \
    || fail "stale metadata entered the production-shaped endpoint probes: $inventory_sessions"
  assert_no_watcher "$dir"
  finish "$dir"
  pass '59 stale task records and one overdue check preserve live-only Stop admission'
}

test_empty_active_snapshot_ignores_retained_metadata() {
  local dir
  dir=$(fixture empty-active-snapshot)
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:retained' 'spawn_gen=retained-old' \
    > "$dir/state/retained.meta"
  if FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-supervision-lib.sh"
    fm_supervision_needed "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin"; then
    fail 'a retained metadata archive overrode an authoritative empty snapshot'
  fi
  run_stop "$dir" 4
  wait_file "$dir/rc"
  [ "$(cat "$dir/rc")" = 0 ] || fail 'idle Stop refused with an empty active snapshot'
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'idle Stop launched a watcher for retained metadata'
  [ ! -e "$dir/state/.codex-stop-failure-episode.json" ] \
    || fail 'idle Stop retained a stale failure episode'
  finish "$dir"
  pass 'an authoritative empty snapshot leaves retained metadata idle'
}

test_active_indexes_discover_new_obligations() {
  local dir
  dir=$(fixture active-index-discovery)
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:active' 'kind=secondmate' 'backend=tmux' \
    'spawn_gen=active-1' > "$dir/state/active.meta"
  register_active_supervision_tasks "$dir" active
  printf '%s\n' 'done: indexed status' > "$dir/state/active.status"
  printf '%s\n' 'indexed turn' > "$dir/state/active.turn-ended"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-task-inbox-lib.sh"
    . "$1/fm-pending-reply-lib.sh"
    fm_task_inbox_write "$FM_STATE_OVERRIDE" active "indexed instruction" >/dev/null || exit 1
    corr=$(FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_NOW=100 \
      fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" active report) || exit 1
    FM_PENDING_REPLY_NOW=100 fm_pending_reply_mark_delivered \
      "$FM_STATE_OVERRIDE" "$corr" 100 || exit 1
    printf "%s\n" "$corr" > "$FM_HOME/active-corr"
  ' _ "$ROOT/bin" || fail 'could not create indexed post-snapshot obligations'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TASK_INBOX_GRACE_SECS=0 \
    FM_TASK_INBOX_RING_MAX=0 FM_PENDING_REPLY_NOW=200 bash -c '
    . "$1/fm-watch.sh"
    generation=$(fm_supervision_registry_generation "$FM_STATE_OVERRIDE") || exit 1
    FM_CODEX_REGISTRY_INDEX=$(mktemp -d "$FM_STATE_OVERRIDE/.test-index.XXXXXX") || exit 1
    fm_supervision_registry_snapshot_index \
      "$FM_STATE_OVERRIDE" "$generation" "$FM_CODEX_REGISTRY_INDEX" || exit 1
    FM_CODEX_BOUNDED_WATCH=1
    scan_signals > "$FM_HOME/indexed-signals" || exit 1
    fm_task_inbox_due_action "$FM_STATE_OVERRIDE" active > "$FM_HOME/indexed-inbox" || exit 1
    fm_pending_reply_backend_observation() { printf "idle\n"; }
    fm_pending_reply_send_recovery() {
      printf "%s\n" "$2" > "$FM_HOME/indexed-reply"
      fm_pending_reply_set "$(fm_pending_reply_path "$1" "$2")" phase recovery_sent
    }
    inventory=$(printf "tmux\tfleet:active\talive\tlocal\t-\tactive\tsecondmate\tactive-1\n")
    fm_pending_reply_tick "$FM_STATE_OVERRIDE" "$inventory" active-only || exit 1
    find "$FM_CODEX_REGISTRY_INDEX" -depth -delete
  ' _ "$ROOT/bin" || fail 'active indexed discovery failed'
  [ "$(wc -l < "$dir/indexed-signals" | tr -d ' ')" = 2 ] \
    || fail 'post-snapshot status and turn-end were not both discovered'
  assert_contains "$(cat "$dir/indexed-inbox")" 'escalate ' \
    'post-snapshot inbox was not discovered through its task index'
  [ "$(cat "$dir/indexed-reply")" = "$(cat "$dir/active-corr")" ] \
    || fail 'post-snapshot pending reply was not discovered through its task index'
  pass 'active indexes discover status, turn-end, inbox, and reply obligations'
}

test_registered_check_index_reconciles_after_ready() {
  local dir inventory
  dir=$(fixture registered-check-index-reconcile)
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-pr-lib.sh"
    fm_check_index_recover "$FM_STATE_OVERRIDE" || exit 1
  ' _ "$ROOT/bin" || fail 'could not initialize registered-check index'
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" recovered-check' \
    > "$dir/state/recovered.check.sh"
  chmod 0700 "$dir/state/recovered.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" recovered >/dev/null \
    || fail 'could not publish registered-check fixture'
  rm -f -- "$dir/state/.registered-checks-v1/recovered"
  inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-pr-lib.sh"
    fm_check_index_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin") || fail 'registered-check reconciliation failed'
  [ "$inventory" = "$dir/state/recovered.check.sh" ] \
    || fail "runnable check stayed absent after ready marker: $inventory"
  [ "$("$inventory")" = recovered-check ] \
    || fail 'reconciled registered check was not executable'
  pass 'registered-check index reconciles runnable artifacts after readiness'
}

test_registry_phase_transition_recovers_torn_publication() {
  local dir inventory txdir
  dir=$(fixture registry-torn-transition)
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
    printf "%s\n" "window=zellij-main:fm-torn" "endpoint_task_id=torn" \
      "endpoint_state=planned" "worktree=-" "project=/project/torn" \
      "harness=codex" "kind=ship" "backend=zellij" \
      "recovery_detail=zellij-main" "spawn_gen=torn-gen" \
      > "$FM_STATE_OVERRIDE/.torn.plan" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" torn torn-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" torn torn-gen \
      planned zellij zellij-main:fm-torn zellij-main "$FM_STATE_OVERRIDE/.torn.plan" || exit 1
    cp "$FM_STATE_OVERRIDE/.active-supervision-generation" "$FM_STATE_OVERRIDE/.planned-snapshot" || exit 1
    printf "%s\n" "window=zellij-main:8" "endpoint_task_id=torn" \
      "endpoint_state=endpoint-only" "worktree=-" "project=/project/torn" \
      "harness=codex" "kind=ship" "backend=zellij" "zellij_session=zellij-main" \
      "zellij_tab_id=7" "zellij_pane_id=8" "spawn_gen=torn-gen" \
      > "$FM_STATE_OVERRIDE/.torn.endpoint" || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" torn torn-gen \
      endpoint-only zellij zellij-main:8 7 "$FM_STATE_OVERRIDE/.torn.endpoint" || exit 1
    cp "$FM_STATE_OVERRIDE/.planned-snapshot" "$FM_STATE_OVERRIDE/.active-supervision-generation" || exit 1

    printf "%s\n" "window=zellij-main:fm-reverse" "endpoint_task_id=reverse" \
      "endpoint_state=planned" "worktree=-" "project=/project/reverse" \
      "harness=codex" "kind=ship" "backend=zellij" \
      "recovery_detail=zellij-main" "spawn_gen=reverse-gen" \
      > "$FM_STATE_OVERRIDE/.reverse.plan" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" reverse reverse-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" reverse reverse-gen \
      planned zellij zellij-main:fm-reverse zellij-main "$FM_STATE_OVERRIDE/.reverse.plan" || exit 1
    reverse_dir=$(fm_supervision_registry_transaction_dir "$FM_STATE_OVERRIDE" reverse) || exit 1
    cp "$reverse_dir/record" "$FM_STATE_OVERRIDE/.reverse.planned-record" || exit 1
    printf "%s\n" "window=zellij-main:10" "endpoint_task_id=reverse" \
      "endpoint_state=endpoint-only" "worktree=-" "project=/project/reverse" \
      "harness=codex" "kind=ship" "backend=zellij" "zellij_session=zellij-main" \
      "zellij_tab_id=9" "zellij_pane_id=10" "spawn_gen=reverse-gen" \
      > "$FM_STATE_OVERRIDE/.reverse.endpoint" || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" reverse reverse-gen \
      endpoint-only zellij zellij-main:10 9 "$FM_STATE_OVERRIDE/.reverse.endpoint" || exit 1
    cp "$FM_STATE_OVERRIDE/.reverse.planned-record" "$reverse_dir/record" || exit 1

    printf "%s\n" "window=zellij-main:fm-internal--internal-gen" "endpoint_task_id=internal" \
      "endpoint_state=planned" "worktree=-" "project=/project/internal" \
      "harness=codex" "kind=ship" "backend=zellij" \
      "recovery_detail=zellij-main" "spawn_gen=internal-gen" \
      > "$FM_STATE_OVERRIDE/.internal.plan" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" internal internal-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" internal internal-gen \
      planned zellij zellij-main:fm-internal--internal-gen zellij-main "$FM_STATE_OVERRIDE/.internal.plan" || exit 1
    internal_dir=$(fm_supervision_registry_transaction_dir "$FM_STATE_OVERRIDE" internal) || exit 1
    internal_slot=$(fm_meta_get "$internal_dir/record" metadata) || exit 1
    cp "$internal_dir/record" "$FM_STATE_OVERRIDE/.internal.planned-record" || exit 1
    cp "$internal_dir/$internal_slot" "$FM_STATE_OVERRIDE/.internal.planned-meta" || exit 1
    cp "$FM_STATE_OVERRIDE/.active-supervision-generation" "$FM_STATE_OVERRIDE/.internal.planned-snapshot" || exit 1
    printf "%s\n" "window=zellij-main:12" "endpoint_task_id=internal" \
      "endpoint_state=endpoint-only" "worktree=-" "project=/project/internal" \
      "harness=codex" "kind=ship" "backend=zellij" "zellij_session=zellij-main" \
      "zellij_tab_id=11" "zellij_pane_id=12" "spawn_gen=internal-gen" \
      > "$FM_STATE_OVERRIDE/.internal.endpoint" || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" internal internal-gen \
      endpoint-only zellij zellij-main:12 11 "$FM_STATE_OVERRIDE/.internal.endpoint" || exit 1
    cp "$FM_STATE_OVERRIDE/.internal.planned-record" "$internal_dir/record" || exit 1
    cp "$FM_STATE_OVERRIDE/.internal.planned-meta" "$internal_dir/$internal_slot" || exit 1
    cp "$FM_STATE_OVERRIDE/.internal.planned-snapshot" "$FM_STATE_OVERRIDE/.active-supervision-generation" || exit 1
  ' _ "$ROOT/bin" || fail 'could not construct torn reservation transition'
  inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_backend_agent_state_batch() {
      while IFS="$(printf "\t")" read -r backend target route home; do
        printf "%s\t%s\tunverified\t%s\t%s\n" "$backend" "$target" "$route" "$home"
      done
    }
    fm_backend_recover_planned() { printf "missing\t-\t-\t-\t-\t-\t-\t-\t-\n"; }
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin") || fail 'torn reservation transition did not recover'
  [ "$inventory" = "$(printf '%s\n%s' "$dir/state/reverse.meta" "$dir/state/torn.meta")" ] \
    || fail "unverified endpoint-only owner did not enter usable inventory: $inventory"
  grep -F "$(printf 'entry\ttorn\ttorn-gen\tpending')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'torn reservation transition did not converge to pending ownership'
  grep -F "$(printf 'entry\treverse\treverse-gen\tpending')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'reverse-order reservation transition did not converge to pending ownership'
  ! grep -F "$(printf '\tinternal\t')" "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'record-first transaction interruption did not retain its coherent planned journal'
  txdir="$dir/state/.active-supervision-transactions-v1"
  [ -d "$txdir" ] && [ -z "$(find "$txdir" -mindepth 1 -print -quit)" ] \
    || fail 'recovered reservation transaction was not retired'
  pass 'reservation phase transition recovers torn publication'
}

test_small_live_endpoint_inventory_remains_bounded() {
  local dir id
  dir=$(fixture live-endpoint-inventory)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  for id in first second; do
    printf 'window=fleet:%s\n' "$id" > "$dir/state/$id.meta"
  done
  register_active_supervision_tasks "$dir" first second
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

test_failed_inventory_probe_is_conservatively_budgeted() {
  local dir
  dir=$(fixture uncertain-endpoint-inventory)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:uncertain' > "$dir/state/uncertain.meta"
  register_active_supervision_tasks "$dir" uncertain
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:uncertain' \
    FM_TEST_LIVE_TARGETS='fleet:uncertain' FM_TEST_INVENTORY_FAILURES=fleet \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=10 FM_CREW_STATE_NM_TIMEOUT=200 \
    FM_WORKTREE_WRITE_TIMEOUT=200 run_stop "$dir" 4
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 2 ] || fail 'uncertain endpoint escaped the fixed Stop deadline'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'failed inventory probe was treated as authoritative death'
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'uncertain endpoint inventory started an under-budgeted watcher'
  finish "$dir"
  pass 'failed inventory probes remain conservatively budgeted'
}

test_remote_endpoints_avoid_local_backend_probes() {
  local dir inventory_count
  dir=$(fixture remote-endpoint-isolation)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=remote:mate' 'kind=secondmate' \
    'remote_host=remote.invalid' 'home=/remote/firstmate' > "$dir/state/mate.meta"
  printf '%s\n' 'paused: waiting for the captain' > "$dir/state/mate.status"
  prime_status_seen "$dir/state" "$dir/state/mate.status"
  printf '%s\n' 'window=fleet:dead' 'kind=ship' 'backend=tmux' > "$dir/state/z-dead.meta"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='remote:mate fleet:dead' \
    FM_TEST_INVENTORY_LOG="$dir/inventories" FM_TEST_BACKEND_PROBE_LOG="$dir/backend-probes" \
    FM_TEST_CAPTURE_LOG="$dir/captures" FM_SIGNAL_GRACE=0 run_stop "$dir" 180
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 2 ] || fail 'remote endpoint escaped Codex Stop supervision'
  assert_contains "$(cat "$dir/out")" 'Run bin/fm-wake-drain.sh' 'local death did not complete the remote isolation cycle'
  grep -R -qF "$(printf '\ttmux\tfleet:dead')" "$dir/state/.death-notified-v3" \
    || fail 'local death did not persist its exact notification receipt'
  ! grep -R -qF 'remote:mate' "$dir/state/.death-notified-v3" \
    || fail 'remote collision produced a false local death receipt'
  inventory_count=$(grep -c '^fleet$' "$dir/inventories")
  [ "$inventory_count" -ge 2 ] \
    || fail 'admission and watcher did not inventory the local tmux scope'
  [ "$(grep -vc '^fleet$' "$dir/inventories")" = 0 ] \
    || fail 'a non-local tmux scope entered the admission or watcher inventory'
  ! grep -qF 'remote' "$dir/inventories" || fail 'remote endpoint was probed through a local backend'
  [ ! -e "$dir/captures" ] || fail 'remote endpoint was captured through a local backend'
  finish "$dir"
  pass 'paused remote endpoints stay isolated from local stale handling'
}

test_remote_inbox_stays_owned_by_remote_delivery() {
  local dir rec
  dir=$(fixture remote-inbox-isolation)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=remote:inbox' 'kind=secondmate' \
    'remote_host=remote.invalid' 'home=/remote/firstmate' > "$dir/state/mate.meta"
  printf '%s\n' 'window=fleet:dead' 'kind=ship' 'backend=tmux' > "$dir/state/z-dead.meta"
  rec=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" mate "respond through the remote delivery path"
  ' _ "$ROOT/bin" "$dir/state") || fail 'could not create remote retained inbox record'
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='remote:inbox fleet:dead' \
    FM_TEST_BACKEND_PROBE_LOG="$dir/backend-probes" FM_TEST_CAPTURE_LOG="$dir/captures" \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=1 FM_SIGNAL_GRACE=0 \
    run_stop "$dir" 180
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 2 ] || fail 'remote inbox escaped Codex Stop supervision'
  [ -f "$rec" ] || fail 'remote retained inbox record was discarded locally'
  [ ! -e "$dir/state/mate.inbox/.ring-state" ] \
    || fail 'remote retained inbox advanced the local ring ladder'
  [ ! -e "$dir/state/mate.inbox/.escalated" ] \
    || fail 'remote retained inbox was falsely escalated locally'
  ! grep -qF $'tmux\tsend-keys' "$dir/backend-probes" \
    || fail 'remote retained inbox rang a colliding local pane'
  [ ! -e "$dir/captures" ] || fail 'remote retained inbox captured a colliding local pane'
  finish "$dir"
  pass 'remote inboxes remain owned by durable remote delivery'
}

test_herdr_endpoints_use_one_snapshot_per_cycle() {
  local dir id calls states
  dir=$(fixture herdr-endpoint-inventory)
  install_endpoint_inventory_herdr "$dir"
  install_endpoint_inventory_tmux "$dir"
  states=$(printf 'herdr\tfleet:w-dead:p1\tlocal\t\nherdr\tfleet:w-live:p1\tlocal\t\n' \
    | PATH="$dir/fakebin:$PATH" FM_TEST_HERDR_EXISTING_TARGETS='fleet:w-dead:p1 fleet:w-live:p1' \
      FM_TEST_HERDR_LIVE_TARGETS='fleet:w-live:p1' bash -c '
        . "$1/fm-backend.sh"
        fm_backend_agent_state_batch
      ' _ "$ROOT/bin") || fail 'Herdr bulk classifier failed'
  [ "$(printf '%s\n' "$states" | awk -F '\t' '$2 == "fleet:w-dead:p1" { print $3 }')" = unverified ] \
    || fail 'Herdr bulk classifier treated an unknown agent status as authoritative death'
  [ "$(printf '%s\n' "$states" | awk -F '\t' '$2 == "fleet:w-live:p1" { print $3 }')" = alive ] \
    || fail 'Herdr bulk classifier did not retain a registered live pane'
  for id in $(seq 1 40); do
    printf 'window=fleet:w%s:p1\nbackend=herdr\n' "$id" > "$dir/state/dead-$id.meta"
  done
  printf '%s\n' 'window=local:dead' 'backend=tmux' > "$dir/state/z-local-dead.meta"
  PATH="$dir/fakebin:$PATH" FM_TEST_HERDR_PROBE_LOG="$dir/herdr-probes" \
    FM_TEST_EXISTING_TARGETS='local:dead' FM_SIGNAL_GRACE=0 run_stop "$dir" 10
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 2 ] || fail 'Herdr endpoint inventory escaped Codex Stop supervision'
  grep -R -qF "$(printf '\ttmux\tlocal:dead')" "$dir/state/.death-notified-v3" \
    || fail 'Herdr watcher phase did not finish before the local terminal wake'
  calls=$(wc -l < "$dir/herdr-probes" | tr -d '[:space:]')
  [ "$calls" -ge 3 ] && [ "$calls" -le 8 ] \
    || fail "Herdr admission and watcher used $calls snapshots for a 40-endpoint inventory"
  [ "$(awk -F '\t' '$2 == "pane" && $3 == "list" { count++ } END { print count + 0 }' "$dir/herdr-probes")" = "$calls" ] \
    || fail 'Herdr batch classification issued a non-inventory endpoint probe'
  finish "$dir"
  pass 'Herdr histories use bounded bulk snapshots without endpoint probes'
}

test_admission_timeout_reaps_probe_descendants() {
  local dir pid alive
  dir=$(fixture admission-timeout-descendant)
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  bash -c '
    trap "" TERM
    printf "%s\n" "$$" > "$FM_HOME/probe-descendant.pid"
    while :; do sleep 1; done
  ' &
  wait
fi
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' 'window=fleet:hanging-probe' 'backend=tmux' > "$dir/state/hanging.meta"
  PATH="$dir/fakebin:$PATH" FM_SIGNAL_GRACE=0 run_stop "$dir" 4
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'timed-out admission probe escaped Stop supervision'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
    'timed-out admission probe did not fail conservatively'
  wait_file "$dir/probe-descendant.pid" 50
  pid=$(cat "$dir/probe-descendant.pid")
  alive=1
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      alive=0
      break
    fi
    sleep 0.1
  done
  [ "$alive" -eq 0 ] || fail "timed-out admission probe left descendant $pid alive"
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'admission timeout terminates its probe process group'
}

test_many_dead_endpoints_take_cheap_watcher_path() {
  local dir id existing='' key pane_hash inventory_calls tmux_probes process_probes capture_probes backend_probes
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
    printf 'window=fleet:dead-%s\nkind=secondmate\nharness=grok\nbackend=tmux\n' "$id" \
      > "$dir/state/dead-$id.meta"
    if [ "$id" -lt 25 ]; then
      printf '%s\n' 'paused: retained completed worker' > "$dir/state/dead-$id.status"
      printf 'fm-death-notified.v2\tlegacy:0\tdead-%s\ttmux\tfleet:dead-%s\n' "$id" "$id" \
        > "$dir/state/.death-notified-fleet_dead-$id"
    else
      printf '%s\n' 'working: agent exited without a terminal event' > "$dir/state/dead-$id.status"
    fi
    prime_status_seen "$dir/state" "$dir/state/dead-$id.status"
    key="fleet_dead-$id"
    printf '%s' "$pane_hash" > "$dir/state/.hash-$key"
    printf '%s\n' 1 > "$dir/state/.count-$key"
    existing="$existing fleet:dead-$id"
  done
  printf '%s\n' 'window=fleet:uncertain-reply' 'kind=secondmate' 'harness=grok' 'backend=tmux' \
    > "$dir/state/uncertain-reply.meta"
  printf '%s\n' 'working: waiting quietly for routed work' > "$dir/state/uncertain-reply.status"
  prime_status_seen "$dir/state" "$dir/state/uncertain-reply.status"
  printf '%s\n' 'window=fleet:missing-reply' 'kind=secondmate' 'harness=grok' 'backend=tmux' \
    > "$dir/state/missing-reply.meta"
  printf '%s\n' 'working: waiting quietly for routed work' > "$dir/state/missing-reply.status"
  prime_status_seen "$dir/state" "$dir/state/missing-reply.status"
  existing="$existing fleet:uncertain-reply"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 bash -c '
    . "$1/fm-pending-reply-lib.sh"
    for id in $(seq 1 25); do
      corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" "dead-$id" "report status") || exit 1
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000 || exit 1
    done
    corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" missing-reply "report status") || exit 1
    fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000 || exit 1
    corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" uncertain-reply "report status") || exit 1
    fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000 || exit 1
  ' _ "$ROOT/bin" || fail 'could not create pending-reply inventory fixture'
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$existing" \
    FM_TEST_AMBIGUOUS_TARGETS='fleet:uncertain-reply' \
    FM_TEST_CAPTURE='retained dead pane' FM_TEST_CAPTURE_LOG="$dir/capture-calls" \
    FM_PENDING_REPLY_PLAN_LOOKUP_LOG="$dir/plan-lookups" \
    FM_CREW_STATE_BIN="$dir/slow-crew-state.sh" FM_PENDING_REPLY_NOW=1000 \
    FM_TEST_INVENTORY_LOG="$dir/inventory-calls" \
    FM_TEST_BACKEND_PROBE_LOG="$dir/backend-probe-calls" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_stop "$dir" 4
  wait_file "$dir/rc" 300
  [ "$(cat "$dir/rc")" = 2 ] || fail 'retained dead endpoint inventory escaped Stop supervision'
  case "$(cat "$dir/out")" in
    *'durable wake pending'*|*'watcher delivered an actionable wake'*) ;;
    *) fail 'retained dead endpoint inventory lost the required dead-worker notification' ;;
  esac
  assert_not_contains "$(cat "$dir/out")" 'watcher failed' 'retained dead endpoints reached unbudgeted watcher work'
  assert_not_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' 'retained dead endpoints recreated the admission refusal'
  grep -F "$(printf '\tstale\tfleet:dead-25\tstale: fleet:dead-25')" "$dir/state/.wake-queue" >/dev/null \
    || fail 'authoritatively dead worker did not retain its stale notification'
  [ ! -e "$dir/crew-state-calls" ] || fail 'authoritatively dead targets reached expensive crew-state classification'
  [ "$(wc -l < "$dir/plan-lookups" | tr -d '[:space:]')" = 3 ] \
    || fail 'pending replies did not restrict keyed classification lookup to active owners'
  inventory_calls=$(wc -l < "$dir/inventory-calls")
  [ "$inventory_calls" -ge 2 ] && [ "$inventory_calls" -le 7 ] \
    || fail "admission and watcher used $inventory_calls inventories across bounded probe cycles"
  backend_probes=$(wc -l < "$dir/backend-probe-calls")
  tmux_probes=$(grep -c "$(printf '^tmux\tlist-windows$')" "$dir/backend-probe-calls" || true)
  process_probes=$(grep -c "$(printf '^ps\tsnapshot$')" "$dir/backend-probe-calls" || true)
  capture_probes=$(grep -c "$(printf '^tmux\tcapture-pane$')" "$dir/backend-probe-calls" || true)
  [ "$tmux_probes" -eq "$inventory_calls" ] && [ "$process_probes" -eq "$inventory_calls" ] \
    && [ "$capture_probes" -eq 1 ] \
    && [ "$backend_probes" -eq "$((2 * inventory_calls + capture_probes))" ] \
    || fail "admission and watcher used unexpected backend probes: $(tr '\n' ' ' < "$dir/backend-probe-calls")"
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'pending replies reuse dead inventory while uncertainty remains observable'
}

test_duplicate_endpoint_pending_replies_share_classification() {
  local dir mode target rc
  for mode in dead missing; do
    dir=$(fixture "duplicate-endpoint-$mode-pending")
    install_endpoint_inventory_tmux "$dir"
    initialize_empty_active_supervision_registry "$dir"
    target="fleet:shared-$mode"
    printf 'window=%s\nkind=secondmate\nharness=grok\nbackend=tmux\n' "$target" \
      > "$dir/state/a-owner.meta"
    printf 'window=%s\nkind=secondmate\nharness=grok\nbackend=tmux\n' "$target" \
      > "$dir/state/b-pending.meta"
    printf '%s\n' 'working: awaiting a correlated report' > "$dir/state/b-pending.status"
    prime_status_seen "$dir/state" "$dir/state/b-pending.status"
    register_active_supervision_tasks "$dir" a-owner b-pending
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 bash -c '
      . "$1/fm-pending-reply-lib.sh"
      corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" b-pending "report status") || exit 1
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000
    ' _ "$ROOT/bin" || fail "could not create duplicate-endpoint $mode pending reply"
    set +e
    if [ "$mode" = dead ]; then
      FM_PENDING_REPLY_NOW=1000 FM_TEST_EXISTING_TARGETS="$target" \
        FM_TEST_CAPTURE_LOG="$dir/captures" FM_TEST_BOUNDED_WATCH_TIMEOUT=6 \
        run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/out" 2> "$dir/err"
    else
      FM_PENDING_REPLY_NOW=1000 FM_TEST_CAPTURE_LOG="$dir/captures" \
        FM_TEST_BOUNDED_WATCH_TIMEOUT=6 \
        run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/out" 2> "$dir/err"
    fi
    rc=$?
    set -e
    case "$mode:$rc" in
      dead:0|dead:124|missing:124) : ;;
      *) fail "duplicate-endpoint $mode cycle ended unexpectedly: rc=$rc $(cat "$dir/err")" ;;
    esac
    if [ "$mode" = dead ]; then
      grep -qF "$(printf '\tstale\t%s\tstale: %s' "$target" "$target")" "$dir/state/.wake-queue" \
        || fail 'duplicate-endpoint dead fixture was not authoritatively classified'
    fi
    [ ! -e "$dir/captures" ] \
      || fail "duplicate-endpoint $mode pending reply captured an authoritative unavailable pane"
  done
  pass 'duplicate endpoint owners share exact unavailable classification'
}

test_bounded_check_batch_parks_at_safe_boundary() {
  local dir watcher rc original_root=$TEST_ROOT sequence deadline_ns
  dir=$(fixture bounded-check-batch-boundary)
  for name in a-first b-second; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s\\n' '$name-start' >> \"\$FM_HOME/check-runs\"" \
      'sleep 0.2' \
      "printf '%s\\n' '$name-finish' >> \"\$FM_HOME/check-runs\"" \
      > "$dir/state/$name.check.sh"
    chmod 0700 "$dir/state/$name.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$name" >/dev/null \
      || fail "could not register $name boundary fixture"
  done
  deadline_ns=$(python3 -c 'import time; print(time.monotonic_ns() + 120_000_000_000)') \
    || fail 'could not allocate the parked watcher lease deadline'
  env FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=30 \
    FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE=1 FM_CODEX_CHECK_BATCH_LEASE=test-lease \
    FM_CODEX_LEASE_DEADLINE_NS="$deadline_ns" \
    FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION=1 FM_POLL=0.02 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  wait_file "$dir/state/.watch.lock/codex-check-batch-boundary" 100
  sleep 0.3
  [ "$(cat "$dir/check-runs")" = $'a-first-start\na-first-finish' ] \
    || fail "bounded watcher crossed its safe boundary: $(cat "$dir/check-runs")"
  kill -0 "$watcher" 2>/dev/null || fail 'bounded watcher exited instead of parking at its boundary'
  : > "$dir/state/task.meta"
  FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=30 FM_POLL=0.02 FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 \
    FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=100 \
    run_stop "$dir" 1
  wait_file "$dir/rc" 250
  case "$(cat "$dir/rc")" in 0|2) ;; *) fail 'attached parked watcher returned an invalid Stop result' ;; esac
  sequence=$(cat "$dir/state/.watch.lock/codex-check-batch-sequence")
  [ "$sequence" = 2 ] || fail "attached parked watcher did not accept the next batch lease: $sequence"
  [ "$(cat "$dir/check-runs")" = $'a-first-start\na-first-finish\nb-second-start\nb-second-finish' ] \
    || fail "attached parked watcher did not continue the next lexical batch: $(cat "$dir/check-runs")"
  kill -0 "$watcher" 2>/dev/null || fail 'Stop killed an independently owned parked watcher'
  finish "$dir"
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  [ ! -e "$dir/state/.check-sweep-cursor" ] \
    || fail 'bounded watcher did not retire its lexical cursor after the complete sweep'

  rm -f "$dir/rc" "$dir/release" "$dir/out"
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_TEST_WATCH_MODE=heartbeat-only FM_SIGNAL_GRACE=0 FM_CHECK_TIMEOUT=1 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 250
  rc=$(cat "$dir/rc")
  [ "$rc" = 2 ] || fail 'heartbeat-only watcher allowed Stop to fail open'
  assert_contains "$(cat "$dir/out")" 'watcher failed' \
    'heartbeat-only watcher was not refused without a safe boundary'
  assert_not_contains "$(cat "$dir/out")" 'quiet checkpoint elapsed' \
    'heartbeat was treated as batch completion'
  finish "$dir"
  pass 'bounded checks park and heartbeat cannot impersonate completion'
}

test_retiring_session_owner_hands_off_current_stop() {
  local dir old_harness owner resume output rc
  dir=$(fixture retiring-session-owner-handoff)
  install_controlled_watcher "$dir"
  : > "$dir/state/task.meta"
  FM_TEST_WATCH_MODE=heartbeat-only FM_SIGNAL_GRACE=0 FM_CHECK_TIMEOUT=1 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 TEST_ROOT="$dir" run_stop "$dir" 1
  TEST_ROOT=$ROOT
  old_harness=$HARNESS
  wait_file "$dir/state/.watch.lock/pid" 250
  owner=$(jq -r .owner "$dir/state/.codex-stop.json")
  (
    while [ ! -e "$dir/replacement-started" ]; do sleep 0.02; done
    sleep 0.5
    kill -CONT "$owner" 2>/dev/null || true
  ) &
  resume=$!
  kill -STOP "$owner" 2>/dev/null || fail 'could not freeze the retiring session owner'

  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CODEX_WATCH_CHECKPOINT=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 FM_GUARD_GRACE=3 \
    FM_BACKEND=tmux FM_TEST_WATCH_MODE=heartbeat-only FM_SIGNAL_GRACE=0 \
    FM_CHECK_TIMEOUT=1 FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    "$TEST_CODEX" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      : > "$FM_HOME/replacement-started"
      "$TEST_ROOT/bin/fm-turnend-guard.sh" --codex \
        <<< "{\"session_id\":\"replacement\",\"stop_hook_active\":true}" \
        > "$FM_HOME/replacement-out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/replacement-rc"
    '
  wait "$resume" 2>/dev/null || true
  wait_file "$dir/replacement-rc" 250
  rc=$(cat "$dir/replacement-rc")
  output=$(cat "$dir/replacement-out")
  touch "$dir/release"
  wait "$old_harness" 2>/dev/null || true

  [ "$rc" = 2 ] || fail 'retiring owner handoff allowed Stop to fail open'
  assert_contains "$output" 'quiet checkpoint elapsed' \
    'retiring prior-session owner prevented the current owner from completing supervision'
  assert_not_contains "$output" 'owner unavailable' \
    'retiring prior-session owner leaked a generic transport symptom'
  pass 'a retiring prior-session owner hands the current Stop to its successor'
}

test_bounded_check_resume_requires_live_owner() {
  local dir watcher owner_identity deadline deadline_ns request registry_generation
  dir=$(fixture bounded-check-resume-owner)
  for name in a-first b-second; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s\\n' '$name' >> \"\$FM_HOME/check-runs\"" \
      > "$dir/state/$name.check.sh"
    chmod 0700 "$dir/state/$name.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$name" >/dev/null \
      || fail "could not register $name owner fixture"
  done
  deadline_ns=$(python3 -c 'import time; print(time.monotonic_ns() + 120_000_000_000)') \
    || fail 'could not allocate the resume-owner watcher lease deadline'
  env FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=1 \
    FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE=1 FM_CODEX_CHECK_BATCH_LEASE=owner-lease \
    FM_CODEX_LEASE_DEADLINE_NS="$deadline_ns" \
    FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION=1 FM_POLL=0.02 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  wait_file "$dir/state/.watch.lock/codex-check-batch-boundary" 100
  registry_generation=$(cut -f2 "$dir/state/.active-supervision-generation")
  owner_identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c \
    '. "$1/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT/bin" "$$") \
    || fail 'could not identify resume fixture owner'
  deadline=$(( $(date +%s) - 1 ))
  printf '{"token":"expired-token","owner":%s,"owner_identity":"%s","session_pid":%s,"session_identity":"%s","resume_deadline":%s,"resume_cycle_timeout":3,"registry_generation":"%s","phase":"watching"}\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" > "$dir/state/.codex-stop.json"
  request=$(printf 'fm-codex-check-batch.v4\towner-lease\t2\texpired-token\t%s\t%s\t%s\t%s\t%s\t3\t%s\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation")
  printf '%s' "$request" > "$dir/state/.watch.lock/codex-check-batch-resume"
  sleep 0.2
  [ "$(cat "$dir/state/.watch.lock/codex-check-batch-sequence")" = 1 ] \
    || fail 'expired resume authorization advanced the batch sequence'
  [ "$(cat "$dir/check-runs")" = a-first ] \
    || fail 'expired resume authorization started an unowned check batch'

  kill -STOP "$watcher"
  deadline=$(( $(date +%s) + 10 ))
  printf '{"token":"revoked-token","owner":%s,"owner_identity":"%s","session_pid":%s,"session_identity":"%s","resume_deadline":%s,"resume_cycle_timeout":3,"registry_generation":"%s","phase":"watching"}\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" > "$dir/state/.codex-stop.json"
  printf 'fm-codex-check-batch.v4\towner-lease\t2\trevoked-token\t%s\t%s\t%s\t%s\t%s\t3\t%s\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" \
    > "$dir/state/.watch.lock/codex-check-batch-resume"
  rm -f "$dir/state/.watch.lock/codex-check-batch-resume"
  kill -CONT "$watcher"
  sleep 0.2
  [ "$(cat "$dir/state/.watch.lock/codex-check-batch-sequence")" = 1 ] \
    || fail 'revoked resume authorization advanced the batch sequence'
  [ "$(cat "$dir/check-runs")" = a-first ] \
    || fail 'revoked resume authorization started an unowned check batch'
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass 'bounded check resume requires live unrevoked Stop ownership'
}

test_bounded_check_resume_requires_complete_cycle_budget() {
  local dir watcher owner_identity deadline deadline_ns registry_generation
  dir=$(fixture bounded-check-resume-cycle-budget)
  for name in a-first b-second c-third d-fourth e-fifth f-sixth; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s\\n' '$name' >> \"\$FM_HOME/check-runs\"" \
      > "$dir/state/$name.check.sh"
    chmod 0700 "$dir/state/$name.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$name" >/dev/null \
      || fail "could not register $name cycle-budget fixture"
  done
  deadline_ns=$(python3 -c 'import time; print(time.monotonic_ns() + 120_000_000_000)') \
    || fail 'could not allocate the cycle-budget watcher lease deadline'
  env FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=300 FM_CHECK_TIMEOUT=1 \
    FM_CODEX_BOUNDED_WATCH=1 FM_CHECKS_PER_CYCLE=3 FM_CODEX_CHECK_BATCH_LEASE=cycle-lease \
    FM_CODEX_LEASE_DEADLINE_NS="$deadline_ns" \
    FM_PENDING_REPLY_DEFER_REMOTE_OBSERVATION=1 FM_POLL=0.02 FM_HEARTBEAT=999999 \
    FM_SIGNAL_GRACE=0 FM_GUARD_GRACE=3 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  wait_file "$dir/state/.watch.lock/codex-check-batch-boundary" 100
  registry_generation=$(cut -f2 "$dir/state/.active-supervision-generation")
  owner_identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c \
    '. "$1/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT/bin" "$$") \
    || fail 'could not identify cycle-budget fixture owner'
  deadline=$(( $(date +%s) + 3 ))
  printf '{"token":"short-cycle-token","owner":%s,"owner_identity":"%s","session_pid":%s,"session_identity":"%s","resume_deadline":%s,"resume_cycle_timeout":6,"registry_generation":"%s","phase":"watching"}\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" > "$dir/state/.codex-stop.json"
  printf 'fm-codex-check-batch.v4\tcycle-lease\t2\tshort-cycle-token\t%s\t%s\t%s\t%s\t%s\t6\t%s\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" \
    > "$dir/state/.watch.lock/codex-check-batch-resume"
  sleep 0.2
  [ "$(cat "$dir/state/.watch.lock/codex-check-batch-sequence")" = 1 ] \
    || fail 'partial-cycle authorization advanced the batch sequence'
  [ "$(cat "$dir/check-runs")" = $'a-first\nb-second\nc-third' ] \
    || fail 'partial-cycle authorization started successor checks'

  deadline=$(( $(date +%s) + 10 ))
  printf '{"token":"full-cycle-token","owner":%s,"owner_identity":"%s","session_pid":%s,"session_identity":"%s","resume_deadline":%s,"resume_cycle_timeout":6,"registry_generation":"%s","phase":"watching"}\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" > "$dir/state/.codex-stop.json"
  printf 'fm-codex-check-batch.v4\tcycle-lease\t2\tfull-cycle-token\t%s\t%s\t%s\t%s\t%s\t6\t%s\n' \
    "$$" "$owner_identity" "$$" "$owner_identity" "$deadline" "$registry_generation" \
    > "$dir/state/.watch.lock/codex-check-batch-resume"
  for _ in $(seq 1 50); do
    [ "$(wc -l < "$dir/check-runs" | tr -d ' ')" = 6 ] && break
    sleep 0.02
  done
  [ "$(cat "$dir/state/.watch.lock/codex-check-batch-sequence")" = 2 ] \
    || fail 'full-cycle authorization did not advance the batch sequence'
  [ "$(cat "$dir/check-runs")" = $'a-first\nb-second\nc-third\nd-fourth\ne-fifth\nf-sixth' ] \
    || fail 'full-cycle authorization did not complete the successor batch'
  kill -TERM "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  pass 'bounded check resume requires the complete admitted cycle budget'
}

test_duplicate_endpoint_owners_share_stale_pass() {
  local dir pane_hash rc captures kind
  dir=$(fixture duplicate-endpoint-stale-pass)
  install_endpoint_inventory_tmux "$dir"
  for task in a-owner b-owner c-owner; do
    kind=ship
    [ "$task" != a-owner ] || kind=secondmate
    printf '%s\n' 'window=fleet:shared' "kind=$kind" 'harness=grok' 'backend=tmux' \
      > "$dir/state/$task.meta"
    printf '%s\n' 'working: shared endpoint fixture' > "$dir/state/$task.status"
    prime_status_seen "$dir/state" "$dir/state/$task.status"
  done
  cat > "$dir/fast-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: stopped · source: pane · bare shell'
SH
  chmod +x "$dir/fast-crew-state.sh"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:shared' \
    FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" b-owner "$FM_STATE_OVERRIDE/b-owner.meta"
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" c-owner "$FM_STATE_OVERRIDE/c-owner.meta"
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" a-owner
  ' _ "$ROOT/bin" || fail 'could not register active duplicate-endpoint owners'
  if command -v md5 >/dev/null 2>&1; then
    pane_hash=$(printf '%s' 'retained endpoint' | md5 -q)
  else
    pane_hash=$(printf '%s' 'retained endpoint' | md5sum | cut -d' ' -f1)
  fi
  printf '%s' "$pane_hash" > "$dir/state/.hash-fleet_shared"
  printf '%s\n' 0 > "$dir/state/.count-fleet_shared"
  set +e
  FM_TEST_EXISTING_TARGETS='fleet:shared' FM_TEST_LIVE_TARGETS='fleet:shared' \
    FM_TEST_CAPTURE_LOG="$dir/captures" FM_TEST_BOUNDED_WATCH_TIMEOUT=6 FM_TEST_WATCH_POLL=10 \
    FM_CREW_STATE_BIN="$dir/fast-crew-state.sh" \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "duplicate endpoint stale cycle ended unexpectedly: rc=$rc $(cat "$dir/err")"
  captures=$(wc -l < "$dir/captures" | tr -d ' ')
  [ "$captures" -eq 1 ] || fail "duplicate endpoint owners caused $captures pane captures"
  [ "$(cat "$dir/state/.count-fleet_shared")" = 1 ] \
    || fail 'duplicate endpoint owners advanced the stale counter more than once'
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail 'duplicate endpoint owners produced a false stale wake'
  pass 'retained mixed endpoint owners cannot suppress active policy'
}

test_launcher_exit_before_child_publication_retires_owned_watcher() {
  local dir original_root=$TEST_ROOT watcher
  dir=$(fixture launcher-exit-after-spawn)
  cp -R "$ROOT/bin/." "$dir/bin/"
  : > "$dir/state/task.meta"
  TEST_ROOT="$dir" FM_SIGNAL_GRACE=0 FM_TEST_WATCH_ARM_EXIT_AFTER_FORK=1 \
    FM_TEST_WATCH_CHILD_HANDSHAKE_DELAY=3 run_stop "$dir" 5
  TEST_ROOT=$original_root
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'launcher exit after spawn allowed Stop to fail open'
  wait_file "$dir/arm-exit-candidate-pid"
  watcher=$(cat "$dir/arm-exit-candidate-pid")
  if kill -0 "$watcher" 2>/dev/null; then fail "launcher-exit watcher $watcher survived refusal commit"; fi
  [ ! -e "$dir/state/.codex-arm-owner" ] \
    || fail 'retired launcher ownership record survived exact child cleanup'
  finish "$dir"
  pass 'production launcher exit retains ownership until child retirement'
}

test_paused_and_captain_held_deaths_notify_once() {
  local dir mode status rc stale_rows
  for mode in paused captain-held; do
    dir=$(fixture "dead-$mode-notification")
    install_endpoint_inventory_tmux "$dir"
    initialize_empty_active_supervision_registry "$dir"
    case "$mode" in
      paused) status='paused: awaiting external dependency' ;;
      *) status='captain-held [key=route]: tracked by held-decision-route' ;;
    esac
    printf '%s\n' "window=fleet:dead-$mode" 'kind=ship' 'harness=grok' 'backend=tmux' \
      'spawn_gen=spawn-a' > "$dir/state/dead-$mode.meta"
    register_active_supervision_tasks "$dir" "dead-$mode"
    printf '%s\n' "$status" > "$dir/state/dead-$mode.status"
    prime_status_seen "$dir/state" "$dir/state/dead-$mode.status"

    set +e
    FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS="fleet:dead-$mode" \
      run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
      > "$dir/first-death.out" 2> "$dir/first-death.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "$mode death did not surface: rc=$rc $(cat "$dir/first-death.err")"
    [ "$(death_receipt_count "$dir")" -eq 1 ] || fail "$mode death did not persist its receipt"

    set +e
    FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS="fleet:dead-$mode" \
      run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
      > "$dir/repeat-death.out" 2> "$dir/repeat-death.err"
    rc=$?
    set -e
    [ "$rc" -eq 124 ] || fail "$mode duplicate death was not suppressed: rc=$rc"
    stale_rows=$(grep -Fc "$(printf '\tstale\tfleet:dead-%s\tstale: fleet:dead-%s' "$mode" "$mode")" \
      "$dir/state/.wake-queue" || true)
    [ "$stale_rows" -eq 1 ] || fail "$mode death queued $stale_rows notifications"
  done
  pass 'paused and captain-held deaths notify once before long cadence'
}

test_local_secondmate_death_notifies_once() {
  local dir rc stale_rows
  dir=$(fixture local-secondmate-death)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:local-mate' 'kind=secondmate' 'harness=grok' 'backend=tmux' \
    'spawn_gen=mate-a' > "$dir/state/local-mate.meta"
  register_active_supervision_tasks "$dir" local-mate
  printf '%s\n' 'working: waiting quietly for routed work' > "$dir/state/local-mate.status"
  prime_status_seen "$dir/state" "$dir/state/local-mate.status"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:local-mate' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/first-death.out" 2> "$dir/first-death.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "local secondmate death did not surface: rc=$rc $(cat "$dir/first-death.err")"
  [ "$(death_receipt_count "$dir")" -eq 1 ] \
    || fail 'local secondmate death did not persist its exact receipt'

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:local-mate' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/repeat-death.out" 2> "$dir/repeat-death.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "duplicate local secondmate death was not suppressed: rc=$rc"
  stale_rows=$(grep -Fc "$(printf '\tstale\tfleet:local-mate\tstale: fleet:local-mate')" \
    "$dir/state/.wake-queue" || true)
  [ "$stale_rows" -eq 1 ] || fail "local secondmate death queued $stale_rows notifications"

  dir=$(fixture healthy-local-secondmate)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:idle-mate' 'kind=secondmate' 'harness=grok' 'backend=tmux' \
    'spawn_gen=mate-alive' > "$dir/state/idle-mate.meta"
  register_active_supervision_tasks "$dir" idle-mate
  printf '%s\n' 'working: waiting quietly for routed work' > "$dir/state/idle-mate.status"
  prime_status_seen "$dir/state" "$dir/state/idle-mate.status"
  set +e
  FM_TEST_EXISTING_TARGETS='fleet:idle-mate' FM_TEST_LIVE_TARGETS='fleet:idle-mate' \
    FM_TEST_CAPTURE_LOG="$dir/captures" run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/healthy.out" 2> "$dir/healthy.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "healthy idle local secondmate was not quiet: rc=$rc"
  [ "$(death_receipt_count "$dir")" -eq 0 ] \
    || fail 'healthy idle local secondmate created a death receipt'
  [ ! -e "$dir/captures" ] || fail 'healthy idle local secondmate entered stale capture handling'

  dir=$(fixture remote-secondmate-death-isolation)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=remote:mate' 'kind=secondmate' 'remote_host=remote.invalid' \
    'home=/remote/firstmate' 'spawn_gen=mate-remote' > "$dir/state/remote-mate.meta"
  register_active_supervision_tasks "$dir" remote-mate
  printf '%s\n' 'working: remote owner remains authoritative' > "$dir/state/remote-mate.status"
  prime_status_seen "$dir/state" "$dir/state/remote-mate.status"
  set +e
  FM_TEST_EXISTING_TARGETS='remote:mate' FM_TEST_CAPTURE_LOG="$dir/captures" \
    FM_TEST_BACKEND_PROBE_LOG="$dir/backend-probes" \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/remote.out" 2> "$dir/remote.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "remote secondmate entered local death handling: rc=$rc"
  [ "$(death_receipt_count "$dir")" -eq 0 ] \
    || fail 'remote secondmate created a local death receipt'
  [ ! -e "$dir/captures" ] || fail 'remote secondmate entered local stale capture handling'
  [ ! -e "$dir/backend-probes" ] \
    || fail 'remote secondmate was probed through a local backend'
  pass 'local secondmate deaths notify once while healthy and remote mates stay quiet'
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

test_missing_endpoint_preserves_inbox_escalation() {
  local dir rec
  dir=$(fixture missing-endpoint-inbox)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:missing-inbox' 'kind=ship' 'harness=grok' 'backend=tmux' \
    > "$dir/state/missing-inbox.meta"
  printf '%s\n' 'working: awaiting durable steer' > "$dir/state/missing-inbox.status"
  prime_status_seen "$dir/state" "$dir/state/missing-inbox.status"
  rec=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" missing-inbox "respond to the captain"
  ' _ "$ROOT/bin" "$dir/state") || fail 'could not create missing-target inbox record'
  PATH="$dir/fakebin:$PATH" FM_TEST_CAPTURE_LOG="$dir/capture-calls" \
    FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=1 FM_SIGNAL_GRACE=0 \
    run_stop "$dir" 10
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'missing-target inbox escalation escaped Stop supervision'
  grep -qF "unread firstmate instruction: $rec" "$dir/state/.wake-queue" \
    || fail 'missing-target inbox record did not escalate durably'
  [ ! -e "$dir/capture-calls" ] || fail 'missing-target inbox escalation captured the pane'
  [ "$(cat "$dir/state/missing-inbox.inbox/.escalated")" = 001.msg ] \
    || fail 'missing-target inbox escalation did not persist its dedup marker'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'missing endpoints retain inbox escalation without pane work'
}

test_dead_endpoint_honors_explicit_notification_receipt() {
  local dir id existing='' pane_hash key meta_reads
  dir=$(fixture dead-endpoint-marker-migration)
  install_endpoint_inventory_tmux "$dir"
  cat > "$dir/fakebin/grep" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    *.meta) printf '%s\n' "$arg" >> "$FM_HOME/meta-read-log" ;;
  esac
done
exec /usr/bin/grep "$@"
SH
  chmod +x "$dir/fakebin/grep"
  pane_hash=$(hash_text 'historical dead pane')
  for id in $(seq 1 25); do
    printf 'window=fleet:dead-history-%s\nkind=ship\nharness=grok\nbackend=tmux\nspawn_gen=spawn-%s\n' "$id" "$id" \
      > "$dir/state/dead-history-$id.meta"
    printf 'window=fleet:dead-history-%s\nkind=secondmate\nharness=grok\nbackend=tmux\nspawn_gen=duplicate-%s\n' "$id" "$id" \
      > "$dir/state/z-duplicate-$id.meta"
    printf '%s\n' 'working: historical stopped worker' > "$dir/state/dead-history-$id.status"
    prime_status_seen "$dir/state" "$dir/state/dead-history-$id.status"
    key="fleet_dead-history-$id"
    printf '%s' "$pane_hash" > "$dir/state/.hash-$key"
    printf '%s' authoritatively-dead > "$dir/state/.stale-$key"
    printf 'fm-death-notified.v2\tspawn:spawn-%s\tdead-history-%s\ttmux\tfleet:dead-history-%s\n' \
      "$id" "$id" "$id" > "$dir/state/.death-notified-$key"
    existing="$existing fleet:dead-history-$id"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$existing" \
    FM_TEST_CAPTURE='historical dead pane' FM_TEST_CAPTURE_LOG="$dir/capture-calls" \
    FM_SIGNAL_GRACE=0 run_stop "$dir" 2
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 0 ] || fail 'fully surfaced dead history did not leave Stop idle'
  [ ! -s "$dir/out" ] || fail 'fully surfaced dead history emitted a supervision notice'
  [ ! -s "$dir/state/.wake-queue" ] || fail 'explicit death receipts queued a duplicate notification'
  for id in $(seq 1 25); do
    [ "$(cat "$dir/state/.stale-fleet_dead-history-$id")" = authoritatively-dead ] \
      || fail "explicit death marker $id changed unexpectedly"
    [ ! -e "$dir/state/.death-notified-fleet_dead-history-$id" ] \
      || fail "legacy death receipt $id was not migrated"
  done
  [ "$(death_receipt_count "$dir")" -eq 25 ] \
    || fail 'explicit death receipts did not migrate to exact owner identities'
  [ ! -e "$dir/capture-calls" ] || fail 'explicit death receipts captured an exact-dead endpoint'
  if [ -f "$dir/meta-read-log" ]; then
    meta_reads=$(wc -l < "$dir/meta-read-log")
  else
    meta_reads=0
  fi
  [ "$meta_reads" -le 2500 ] \
    || fail "exact-dead inventory performed $meta_reads metadata reads instead of linear work"
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'exact-dead inventory is linear and explicit receipts suppress duplicates'
}

test_absorbed_dead_endpoint_emits_new_death_notification() {
  local dir pane_hash
  dir=$(fixture absorbed-dead-endpoint)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:absorbed-dead' 'kind=ship' 'harness=grok' 'backend=tmux' \
    > "$dir/state/absorbed-dead.meta"
  printf '%s\n' 'working: previously absorbed worker' > "$dir/state/absorbed-dead.status"
  prime_status_seen "$dir/state" "$dir/state/absorbed-dead.status"
  pane_hash=$(hash_text 'absorbed dead pane')
  printf '%s' "$pane_hash" > "$dir/state/.hash-fleet_absorbed-dead"
  printf '%s' "$pane_hash" > "$dir/state/.stale-fleet_absorbed-dead"
  date +%s > "$dir/state/.stale-since-fleet_absorbed-dead"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:absorbed-dead' \
    FM_TEST_CAPTURE='absorbed dead pane' FM_TEST_CAPTURE_LOG="$dir/capture-calls" \
    FM_SIGNAL_GRACE=0 run_stop "$dir" 2
  wait_file "$dir/rc" 250
  [ "$(cat "$dir/rc")" = 2 ] || fail 'absorbed dead endpoint escaped Stop supervision'
  case "$(cat "$dir/out")" in
    *'durable wake pending'*|*'watcher delivered an actionable wake'*) ;;
    *) fail 'absorbed dead endpoint lost its new death wake' ;;
  esac
  grep -F "$(printf '\tstale\tfleet:absorbed-dead\tstale: fleet:absorbed-dead')" \
    "$dir/state/.wake-queue" >/dev/null \
    || fail 'absorbed dead endpoint did not retain its death notification'
  [ "$(cat "$dir/state/.stale-fleet_absorbed-dead")" = authoritatively-dead ] \
    || fail 'absorbed dead endpoint did not migrate its marker'
  [ ! -e "$dir/state/.stale-since-fleet_absorbed-dead" ] \
    || fail 'absorbed dead endpoint retained its obsolete timer'
  [ ! -e "$dir/capture-calls" ] || fail 'absorbed dead endpoint captured the pane'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'absorbed dead endpoints emit one new death notification'
}

test_resumed_worker_retires_death_generation() {
  local dir pane_hash rc receipt stale_rows
  dir=$(fixture resumed-worker-death-generation)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:resumed-worker' 'kind=ship' 'harness=grok' 'backend=tmux' \
    'spawn_gen=spawn-a' \
    > "$dir/state/resumed-worker.meta"
  register_active_supervision_tasks "$dir" resumed-worker
  printf '%s\n' 'working: worker generation fixture' > "$dir/state/resumed-worker.status"
  prime_status_seen "$dir/state" "$dir/state/resumed-worker.status"
  pane_hash=$(hash_text 'Ctrl+c:cancel')
  printf '%s' "$pane_hash" > "$dir/state/.hash-fleet_resumed-worker"
  printf '%s' authoritatively-dead > "$dir/state/.stale-fleet_resumed-worker"
  printf 'fm-death-notified.v2\tspawn:spawn-a\tresumed-worker\ttmux\tfleet:resumed-worker\n' \
    > "$dir/state/.death-notified-fleet_resumed-worker"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:resumed-worker' \
    FM_TEST_LIVE_TARGETS='fleet:resumed-worker' \
    FM_TEST_CAPTURE='Ctrl+c:cancel' run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/live-watch.out" 2> "$dir/live-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "resumed worker cycle ended unexpectedly: rc=$rc $(cat "$dir/live-watch.err")"
  [ "$(death_receipt_count "$dir")" -eq 0 ] \
    || fail 'resumed worker retained the previous death receipt'
  [ ! -e "$dir/state/.stale-fleet_resumed-worker" ] \
    || fail 'resumed worker retained ambiguous stale state'
  [ ! -e "$dir/state/.death-generation-fleet_resumed-worker" ] \
    || fail 'spawn-bound receipt unexpectedly used the legacy generation counter'

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:resumed-worker' \
    FM_TEST_CAPTURE='Ctrl+c:cancel' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/dead-watch.out" 2> "$dir/dead-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "new worker death did not surface: rc=$rc $(cat "$dir/dead-watch.err")"
  receipt=$(death_receipt_contents "$dir")
  [ "$receipt" = "$(printf 'fm-death-notified.v3\tspawn:spawn-a\tresumed-worker\ttmux\tfleet:resumed-worker')" ] \
    || fail 'new worker death receipt was not bound to the resumed generation'
  stale_rows=$(grep -c "$(printf '\tstale\tfleet:resumed-worker\tstale: fleet:resumed-worker')" \
    "$dir/state/.wake-queue")
  [ "$stale_rows" -eq 1 ] || fail "new worker death queued $stale_rows notifications"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:resumed-worker' \
    FM_TEST_CAPTURE='Ctrl+c:cancel' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/repeat-dead-watch.out" 2> "$dir/repeat-dead-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "same death receipt did not suppress a duplicate: rc=$rc"
  stale_rows=$(grep -c "$(printf '\tstale\tfleet:resumed-worker\tstale: fleet:resumed-worker')" \
    "$dir/state/.wake-queue")
  [ "$stale_rows" -eq 1 ] || fail "same death queued $stale_rows notifications"
  pass 'resumed work retires death receipt and wakes once'
}

test_relaunch_generation_surfaces_death_before_alive_observation() {
  local dir rc receipt stale_rows
  dir=$(fixture relaunched-worker-death-generation)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:relaunched-worker' 'kind=ship' 'harness=grok' 'backend=tmux' \
    'spawn_gen=spawn-a' > "$dir/state/relaunched-worker.meta"
  printf '%s\n' 'working: original worker generation' > "$dir/state/relaunched-worker.status"
  prime_status_seen "$dir/state" "$dir/state/relaunched-worker.status"
  printf '%s' authoritatively-dead > "$dir/state/.stale-fleet_relaunched-worker"
  printf 'fm-death-notified.v2\tspawn:spawn-a\trelaunched-worker\ttmux\tfleet:relaunched-worker\n' \
    > "$dir/state/.death-notified-fleet_relaunched-worker"
  sed 's/spawn_gen=spawn-a/spawn_gen=spawn-b/' "$dir/state/relaunched-worker.meta" \
    > "$dir/state/relaunched-worker.meta.next"
  mv "$dir/state/relaunched-worker.meta.next" "$dir/state/relaunched-worker.meta"
  register_active_supervision_tasks "$dir" relaunched-worker

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:relaunched-worker' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/dead-watch.out" 2> "$dir/dead-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "relaunched worker death did not surface: rc=$rc $(cat "$dir/dead-watch.err")"
  receipt=$(death_receipt_contents "$dir")
  [ "$receipt" = "$(printf 'fm-death-notified.v3\tspawn:spawn-b\trelaunched-worker\ttmux\tfleet:relaunched-worker')" ] \
    || fail 'relaunched worker death receipt retained the previous spawn generation'
  stale_rows=$(grep -c "$(printf '\tstale\tfleet:relaunched-worker\tstale: fleet:relaunched-worker')" \
    "$dir/state/.wake-queue")
  [ "$stale_rows" -eq 1 ] || fail "relaunched worker death queued $stale_rows notifications"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:relaunched-worker' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/repeat-dead-watch.out" 2> "$dir/repeat-dead-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "same relaunched death was not suppressed: rc=$rc"
  stale_rows=$(grep -c "$(printf '\tstale\tfleet:relaunched-worker\tstale: fleet:relaunched-worker')" \
    "$dir/state/.wake-queue")
  [ "$stale_rows" -eq 1 ] || fail "same relaunched death queued $stale_rows notifications"
  pass 'relaunch generation death surfaces before alive observation'
}

test_colliding_endpoint_keys_keep_independent_death_receipts() {
  local dir rc dot_rows underscore_rows receipts
  dir=$(fixture colliding-death-receipts)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:fm-a.b' 'kind=ship' 'harness=grok' 'backend=tmux' \
    'spawn_gen=spawn-dot' > "$dir/state/collision-dot.meta"
  printf '%s\n' 'window=fleet:fm-a_b' 'kind=ship' 'harness=grok' 'backend=tmux' \
    'spawn_gen=spawn-underscore' > "$dir/state/collision-underscore.meta"
  register_active_supervision_tasks "$dir" collision-dot collision-underscore
  printf '%s\n' 'working: previously surfaced dotted endpoint' > "$dir/state/collision-dot.status"
  printf '%s\n' 'working: new underscored endpoint death' > "$dir/state/collision-underscore.status"
  prime_status_seen "$dir/state" "$dir/state/collision-dot.status"
  prime_status_seen "$dir/state" "$dir/state/collision-underscore.status"
  printf '%s' authoritatively-dead > "$dir/state/.stale-fleet_fm-a_b"
  printf 'fm-death-notified.v2\tspawn:spawn-dot\tcollision-dot\ttmux\tfleet:fm-a.b\n' \
    > "$dir/state/.death-notified-fleet_fm-a_b"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    FM_TEST_EXISTING_TARGETS='fleet:fm-a.b fleet:fm-a_b' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/new-death.out" 2> "$dir/new-death.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "colliding new death did not surface: rc=$rc $(cat "$dir/new-death.err")"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    FM_TEST_EXISTING_TARGETS='fleet:fm-a.b fleet:fm-a_b' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/quiet-one.out" 2> "$dir/quiet-one.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "colliding receipts did not stabilize: rc=$rc"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    FM_TEST_EXISTING_TARGETS='fleet:fm-a.b fleet:fm-a_b' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/quiet-two.out" 2> "$dir/quiet-two.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "colliding receipts alternated on a later cycle: rc=$rc"

  dot_rows=$(grep -Fc "$(printf '\tstale\tfleet:fm-a.b\tstale: fleet:fm-a.b')" \
    "$dir/state/.wake-queue" || true)
  underscore_rows=$(grep -Fc "$(printf '\tstale\tfleet:fm-a_b\tstale: fleet:fm-a_b')" \
    "$dir/state/.wake-queue" || true)
  [ "$dot_rows" -eq 0 ] || fail "migrated dotted death queued $dot_rows duplicate notifications"
  [ "$underscore_rows" -eq 1 ] || fail "underscored death queued $underscore_rows notifications"
  [ "$(death_receipt_count "$dir")" -eq 2 ] \
    || fail 'colliding endpoint identities did not retain independent receipts'
  receipts=$(death_receipt_contents "$dir")
  printf '%s\n' "$receipts" | grep -Fqx \
    "$(printf 'fm-death-notified.v3\tspawn:spawn-dot\tcollision-dot\ttmux\tfleet:fm-a.b')" \
    || fail 'dotted endpoint receipt did not migrate to its exact identity'
  printf '%s\n' "$receipts" | grep -Fqx \
    "$(printf 'fm-death-notified.v3\tspawn:spawn-underscore\tcollision-underscore\ttmux\tfleet:fm-a_b')" \
    || fail 'underscored endpoint receipt did not retain its exact identity'
  [ ! -e "$dir/state/.death-notified-fleet_fm-a_b" ] \
    || fail 'ambiguous legacy receipt remained after exact migration'
  pass 'colliding endpoint keys retain independent stable death receipts'
}

test_ambiguous_busy_resume_retires_death_receipt() {
  local dir rc stale_rows
  dir=$(fixture ambiguous-busy-resume)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:ambiguous-busy' 'kind=ship' 'harness=grok' 'backend=tmux' \
    'spawn_gen=spawn-a' > "$dir/state/ambiguous-busy.meta"
  register_active_supervision_tasks "$dir" ambiguous-busy
  printf '%s\n' 'working: worker resumes with ambiguous attribution' \
    > "$dir/state/ambiguous-busy.status"
  prime_status_seen "$dir/state" "$dir/state/ambiguous-busy.status"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:ambiguous-busy' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/first-death.out" 2> "$dir/first-death.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "first ambiguous-worker death did not surface: rc=$rc"
  [ "$(death_receipt_count "$dir")" -eq 1 ] \
    || fail 'first ambiguous-worker death did not persist its receipt'

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:ambiguous-busy' \
    FM_TEST_AMBIGUOUS_TARGETS='fleet:ambiguous-busy' FM_TEST_CAPTURE='Ctrl+c:cancel' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/busy.out" 2> "$dir/busy.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "ambiguous busy resume ended unexpectedly: rc=$rc $(cat "$dir/busy.err")"
  [ "$(death_receipt_count "$dir")" -eq 0 ] \
    || fail 'ambiguous busy resume retained the previous death receipt'

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_EXISTING_TARGETS='fleet:ambiguous-busy' \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/second-death.out" 2> "$dir/second-death.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-resume death did not surface: rc=$rc $(cat "$dir/second-death.err")"
  stale_rows=$(grep -c "$(printf '\tstale\tfleet:ambiguous-busy\tstale: fleet:ambiguous-busy')" \
    "$dir/state/.wake-queue")
  [ "$stale_rows" -eq 2 ] || fail "busy-resumed worker deaths queued $stale_rows notifications"
  pass 'ambiguous busy resume retires the previous death receipt'
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
    FM_CHECK_TIMEOUT=30 run_stop "$dir" 90
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
  local dir state rc FM_TEST_BOUNDED_WATCH_TIMEOUT=6
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
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' early >> \"\$FM_HOME/check-runs\"" > "$state/0-early.check.sh"
  chmod 0700 "$state/0-early.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" 0-early >/dev/null \
    || fail 'could not register adversarial early check'
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' late >> \"\$FM_HOME/check-runs\"" > "$state/zz-late.check.sh"
  chmod 0700 "$state/zz-late.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" zz-late >/dev/null \
    || fail 'could not register adversarial late check'

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
  [ ! -e "$state/.check-sweep-high-water" ] || fail 'completed resumed sweep retained its high-water bound'
  [ -e "$state/.last-check" ] || fail 'completed resumed sweep did not restore its cadence'
  rm -f "$state/.last-check" "$state/a-recurring.check.sh" "$state/z-tail.check.sh"

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 run_bounded_watcher_cycle \
    "$dir" "$dir/fakebin" > "$dir/watch-4.out" 2> "$dir/watch-4.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "next lexical sweep ended unexpectedly: rc=$rc $(cat "$dir/watch-4.err")"
  [ "$(cat "$state/.check-sweep-cursor")" = 0-early.check.sh ] \
    || fail 'new earlier check did not lead the next immutable sweep'
  [ "$(cat "$state/.check-sweep-high-water")" = zz-late.check.sh ] \
    || fail 'next sweep did not freeze its starting high-water bound'

  set +e
  FM_TEST_WATCH_HANDLING_SUCCESSOR=1 run_bounded_watcher_cycle \
    "$dir" "$dir/fakebin" > "$dir/watch-5.out" 2> "$dir/watch-5.err"
  rc=$?
  set -e
  case "$rc" in 0|124) ;; *) fail "late lexical sweep ended unexpectedly: rc=$rc $(cat "$dir/watch-5.err")" ;; esac
  [ "$(cat "$dir/check-runs")" = $'recurring\npr\ntail\nearly\nlate' ] \
    || fail "immutable high-water sweep starved an earlier arrival: $(cat "$dir/check-runs")"
  [ ! -e "$state/.check-sweep-cursor" ] && [ ! -e "$state/.check-sweep-high-water" ] \
    || fail 'completed adversarial sweep retained progress state'

  dir=$(fixture disappearing-check-high-water)
  state="$dir/state"
  mkdir "$dir/fakebin"
  for check_id in a m z; do
    printf '%s\n' '#!/usr/bin/env bash' \
      "printf '%s\\n' $check_id >> \"\$FM_HOME/check-runs\"" > "$state/$check_id.check.sh"
    chmod 0700 "$state/$check_id.check.sh"
    FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$check_id" >/dev/null \
      || fail "could not register $check_id high-water check"
  done
  rm -f "$state/.last-check"
  set +e
  FM_TEST_CHECKS_PER_CYCLE=2 FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "initial disappearing-bound cycle ended unexpectedly: rc=$rc $(cat "$dir/watch-1.err")"
  [ "$(cat "$dir/check-runs")" = $'a\nm' ] \
    && [ "$(cat "$state/.check-sweep-cursor")" = m.check.sh ] \
    && [ "$(cat "$state/.check-sweep-high-water")" = z.check.sh ] \
    || fail 'initial frozen high-water sweep did not checkpoint after a and m'
  rm -f "$state/z.check.sh"
  set +e
  FM_TEST_CHECKS_PER_CYCLE=2 FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "removed high-water cycle ended unexpectedly: rc=$rc $(cat "$dir/watch-2.err")"
  [ "$(cat "$dir/check-runs")" = $'a\nm' ] \
    || fail 'removed high-water item reran completed checks before wrapping'
  [ ! -e "$state/.check-sweep-cursor" ] && [ ! -e "$state/.check-sweep-high-water" ] \
    && [ -e "$state/.last-check" ] \
    || fail 'removed high-water item stranded the completed sweep'
  rm -f "$state/.last-check"
  set +e
  FM_TEST_CHECKS_PER_CYCLE=2 FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/watch-3.out" 2> "$dir/watch-3.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "wrapped high-water cycle ended unexpectedly: rc=$rc $(cat "$dir/watch-3.err")"
  [ "$(cat "$dir/check-runs")" = $'a\nm\na\nm' ] \
    || fail "removed high-water item starved the next lexical sweep: $(cat "$dir/check-runs")"
  pass 'actionable custom and merged checks resume bounded sweeps fairly'
}

test_check_sweep_order_is_canonical_across_locales() {
  local locale_name locale_key dir state id cycle rc action_id expected_initial expected_next actual
  expected_initial=$'A-dash\nZ.dot\n_under\na_lower\nz-last'
  expected_next=$'A-dash\nB-late\nZ.dot\n_under\na_lower\nz-last\nzz-late'
  for locale_name in ${FM_TEST_CHECK_ORDER_LOCALES:-C en_US.UTF-8 sv_SE.UTF-8}; do
    locale -a | grep -Fx "$locale_name" >/dev/null \
      || fail "required locale is not installed: $locale_name"
    locale_key=$(printf '%s' "$locale_name" | tr '.-' '__')
    dir=$(fixture "canonical-check-order-$locale_key")
    state="$dir/state"
    mkdir -p "$dir/fakebin"
    for id in A-dash Z.dot _under a_lower z-last; do
      printf '%s\n' '#!/usr/bin/env bash' \
        "printf '%s\\n' '$id' >> \"\$FM_HOME/check-runs\"" \
        "[ ! -f \"\$FM_HOME/action-$id\" ] || printf '%s\\n' ready" \
        > "$state/$id.check.sh"
      chmod 0700 "$state/$id.check.sh"
      FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
        || fail "could not register $locale_name check $id"
    done
    FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
      "$ROOT/bin/fm-pr-check-migrate.sh" --checks-safe >/dev/null \
      || fail "could not preflight $locale_name check migration"
    for cycle in 1 2 3; do
      case "$cycle" in
        1) action_id=Z.dot ;;
        2) action_id=a_lower ;;
        3) action_id=z-last ;;
      esac
      rm -f "$dir"/action-*
      touch "$dir/action-$action_id"
      set +e
      LC_ALL="$locale_name" FM_TEST_CHECKS_PER_CYCLE=2 \
        FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_BOUNDED_WATCH_TIMEOUT=10 \
        run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
          > "$dir/initial-$cycle.out" 2> "$dir/initial-$cycle.err"
      rc=$?
      set -e
      [ "$rc" -eq 0 ] \
        || fail "$locale_name initial sweep $cycle ended unexpectedly: rc=$rc $(cat "$dir/initial-$cycle.err")"
      ack_watcher_cycle "$state" >/dev/null \
        || fail "could not acknowledge $locale_name initial sweep $cycle"
      if [ "$cycle" -eq 1 ]; then
        for id in B-late zz-late; do
          printf '%s\n' '#!/usr/bin/env bash' \
            "printf '%s\\n' '$id' >> \"\$FM_HOME/check-runs\"" \
            "[ ! -f \"\$FM_HOME/action-$id\" ] || printf '%s\\n' ready" \
            > "$state/$id.check.sh"
          chmod 0700 "$state/$id.check.sh"
          FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
            || fail "could not register deferred $locale_name check $id"
        done
      fi
    done
    actual=$(cat "$dir/check-runs")
    [ "$actual" = "$expected_initial" ] \
      || fail "$locale_name changed the frozen starting sweep order: $actual"
    [ ! -e "$state/.check-sweep-cursor" ] && [ ! -e "$state/.check-sweep-high-water" ] \
      || fail "$locale_name starting sweep did not finish finitely"
    rm -f "$state/.last-check"
    for cycle in 1 2 3 4; do
      case "$cycle" in
        1) action_id=B-late ;;
        2) action_id=_under ;;
        3) action_id=z-last ;;
        4) action_id=zz-late ;;
      esac
      rm -f "$dir"/action-*
      touch "$dir/action-$action_id"
      set +e
      LC_ALL="$locale_name" FM_TEST_CHECKS_PER_CYCLE=2 \
        FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_TEST_BOUNDED_WATCH_TIMEOUT=10 \
        run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
          > "$dir/next-$cycle.out" 2> "$dir/next-$cycle.err"
      rc=$?
      set -e
      [ "$rc" -eq 0 ] \
        || fail "$locale_name next sweep $cycle ended unexpectedly: rc=$rc $(cat "$dir/next-$cycle.err")"
      ack_watcher_cycle "$state" >/dev/null \
        || fail "could not acknowledge $locale_name next sweep $cycle"
    done
    actual=$(tail -n 7 "$dir/check-runs")
    [ "$actual" = "$expected_next" ] \
      || fail "$locale_name did not run deferred insertions in the next finite sweep: $actual"
  done
  pass 'check sweeps use one C-collated immutable order across installed locales'
}

test_supervision_rows_preserve_backslash_bytes() {
  local dir generation index selected
  dir=$(fixture byte-preserving-supervision-rows)
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:shared' 'kind=ship' 'harness=claude' \
    'home=/tmp/home \c-tail\\slash with spaces' 'spawn_gen=row-a' \
    > "$dir/state/row-a.meta"
  printf '%s\n' 'window=fleet:shared' 'kind=secondmate' 'harness=claude' \
    'home=/tmp/other !punctuation!\\path' 'spawn_gen=row-b' \
    > "$dir/state/row-b.meta"
  printf '%s\n' 'working: row a' > "$dir/state/row-a.status"
  printf '%s\n' 'done: row b' > "$dir/state/row-b.status"
  register_active_supervision_tasks "$dir" row-a row-b
  generation=$(head -1 "$dir/state/.active-supervision-generation" | cut -f2)
  index=$(mktemp -d "$dir/state/.row-index.XXXXXX")
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_INDEX="$index" \
    FM_TEST_GENERATION="$generation" bash -c '
    . "$1/fm-watch.sh"
    FM_CODEX_BOUNDED_WATCH=1
    FM_CODEX_REGISTRY_INDEX=$FM_TEST_INDEX
    fm_supervision_registry_snapshot_index \
      "$FM_STATE_OVERRIDE" "$FM_TEST_GENERATION" "$FM_CODEX_REGISTRY_INDEX" || exit 1
    owners=$(active_window_inventory) || exit 1
    printf "%s\n" "$owners" > "$FM_HOME/owner-rows"
    states=$(printf "%s\n" "$owners" | awk -F "\t" \
      "BEGIN { OFS=\"\\t\" } { print \$3, \$1, \"alive\", \$5, \$6, \$2, \$4, \$7 }")
    bounded_score_inventory "$states" "$FM_HOME/scored-scratch" > "$FM_HOME/scored-rows" || exit 1
    fm_supervision_tsv_row "literal\\c" "double\\\\slash" "space value" \
      > "$FM_HOME/encoded-row" || exit 1
    printf "%s\t%s\t%s\n" "literal\\c" "double\\\\slash" "space value" \
      > "$FM_HOME/expected-row"
    cmp "$FM_HOME/expected-row" "$FM_HOME/encoded-row" || exit 1
    bad=$(printf "bad\tfield")
    ! fm_supervision_tsv_row "$bad" safe >/dev/null
  ' _ "$ROOT/bin" || fail 'byte-preserving supervision row round trip failed'
  [ "$(wc -l < "$dir/owner-rows" | tr -d ' ')" = 2 ] \
    && [ "$(wc -l < "$dir/scored-rows" | tr -d ' ')" = 2 ] \
    || fail 'duplicate endpoint owners were dropped during row scoring'
  grep -F '/tmp/home \c-tail\\slash with spaces' "$dir/owner-rows" >/dev/null \
    || fail 'owner inventory interpreted a literal backslash-c sequence'
  grep -F '/tmp/home \c-tail\\slash with spaces' "$dir/scored-rows" >/dev/null \
    || fail 'watcher scoring interpreted a literal backslash-c sequence'
  selected=$(awk -F '\t' '{ print $(NF-1) ":" $NF }' "$dir/scored-rows" | LC_ALL=C sort -u)
  [ "$selected" = row-b:secondmate ] \
    || fail "duplicate-owner scoring lost its selected policy: $selected"
  find "$index" -depth -delete
  pass 'admission and watcher scoring preserve literal backslashes and duplicate owners'
}

test_due_remote_recovery_fits_cycle_budget() {
  local dir original_root=$TEST_ROOT corr
  dir=$(fixture due-remote-recovery)
  cp -R "$ROOT/bin/." "$dir/bin/"
  install_controlled_watcher "$dir"
  printf '%s\n' 'window=remote:remote-task' 'remote_host=fixture.invalid' \
    'kind=secondmate' 'spawn_gen=remote-task-a' > "$dir/state/remote-task.meta"
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
  if [ -f "$dir/cycle-budget-scans" ]; then
    scans=$(wc -l < "$dir/cycle-budget-scans")
  else
    scans=0
  fi
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

test_running_arm_cancellation_reaps_prelock_descendants() {
  local dir original_root=$TEST_ROOT descendant
  dir=$(fixture prelock-arm-descendant)
  cp -R "$ROOT/bin/." "$dir/bin/"
  cat > "$dir/bin/fm-pr-check-migrate.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/prelock-descendant-pid"
while :; do sleep 1; done
SH
  chmod +x "$dir/bin/fm-pr-check-migrate.sh"
  : > "$dir/state/task.meta"
  TEST_ROOT="$dir" run_stop "$dir" 15
  TEST_ROOT=$original_root
  wait_file "$dir/prelock-descendant-pid" 150
  descendant=$(cat "$dir/prelock-descendant-pid")
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" task
  ' _ "$ROOT/bin" || fail 'pre-lock descendant fixture could not retire active ownership'
  rm "$dir/state/task.meta"
  wait_file "$dir/rc" 200
  [ "$(cat "$dir/rc")" = 0 ] || fail 'pre-lock descendant cleanup did not close the idle Stop quietly'
  if is_live_non_zombie "$descendant"; then
    fail "pre-lock watcher descendant $descendant survived Stop cleanup"
  fi
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'running arm cancellation reaps pre-lock watcher descendants'
}

test_reaped_uncertain_group_is_not_signalled() {
  local dir original_root=$TEST_ROOT sentinel
  dir=$(fixture uncertain-arm-group)
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-supervision-registry-lib.sh,fm-pending-reply-lib.sh,fm-task-inbox-lib.sh,fm-hook-host-lib.sh,fm-backend.sh,fm-pr-lib.sh,fm-check-lib.sh} "$dir/bin/"
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
    case "$kind" in
      no-need)
        install_controlled_watcher "$dir"
        TEST_ROOT="$dir" run_stop "$dir" 15
        ;;
      *) run_stop "$dir" 15 ;;
    esac
    wait_file "$dir/state/.watch.lock/pid"
    hook=$(cat "$dir/hook")
    case "$kind" in
      TERM|KILL) kill "-$kind" "$hook" ;;
      afk) touch "$dir/state/.afk" ;;
      replacement) printf '99999999\n' > "$dir/state/.lock" ;;
      no-need)
        FM_STATE_OVERRIDE="$dir/state" bash -c '
          . "$1/fm-wake-lib.sh"
          . "$1/fm-backend.sh"
          . "$1/fm-supervision-registry-lib.sh"
          fm_supervision_registry_retire "$FM_STATE_OVERRIDE" task
        ' _ "$ROOT/bin" || fail 'no-need fixture could not retire active ownership'
        rm "$dir/state/task.meta"
        ;;
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
  cp "$ROOT/bin/"{fm-turnend-guard.sh,fm-codex-stop.sh,fm-primary-scope-lib.sh,fm-session-lock-lib.sh,fm-cursor-lib.sh,fm-wake-lib.sh,fm-supervision-lib.sh,fm-supervision-registry-lib.sh,fm-pending-reply-lib.sh,fm-task-inbox-lib.sh,fm-hook-host-lib.sh,fm-backend.sh,fm-pr-lib.sh,fm-check-lib.sh} "$dir/bin/"
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

test_active_supervision_registry_owns_lifecycle_inventory() {
  local dir inventory generation
  dir=$(fixture active-supervision-registry)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:live' 'spawn_gen=live-a' > "$dir/state/live.meta"
  printf '%s\n' 'window=fleet:retained' 'spawn_gen=retained-a' > "$dir/state/retained.meta"
  printf '%s\n' 'window=fleet:newly-dead' 'spawn_gen=dead-a' > "$dir/state/newly-dead.meta"
  write_exact_death_receipt "$dir/state" retained fleet:retained tmux retained-a \
    || fail 'could not publish the retained endpoint receipt fixture'
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:live fleet:retained' \
    FM_TEST_LIVE_TARGETS='fleet:live' FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover_legacy "$FM_STATE_OVERRIDE"
      fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin" > "$dir/recovered" || fail 'active registry recovery failed'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/recovered")
  [ "$inventory" = $'live\nnewly-dead' ] \
    || fail "registry recovery lost a new death or admitted surfaced history: $inventory"
  generation=$(head -1 "$dir/state/.active-supervision-generation" | cut -f2)
  printf '%s\n' 'window=fleet:new' 'spawn_gen=new-a' > "$dir/state/new.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" new "$FM_STATE_OVERRIDE/new.meta"
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" live
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/transitioned" || fail 'active registry lifecycle transition failed'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/transitioned")
  [ "$inventory" = $'new\nnewly-dead' ] || fail "registry lifecycle retained the wrong active set: $inventory"
  [ "$(cut -f2 "$dir/state/.active-supervision-generation")" != "$generation" ] \
    || fail 'registry lifecycle transition did not revoke the prior generation'
  pass 'active supervision recovery and lifecycle transitions own inventory'
}

test_registry_receipt_recovery_is_owner_addressed() {
  local dir id target key targets='' inventory
  dir=$(fixture owner-addressed-registry-receipts)
  install_endpoint_inventory_tmux "$dir"
  targets=' fleet:shared-owner'
  printf '%s\n' 'window=fleet:shared-owner' 'spawn_gen=shared-a-gen' > "$dir/state/shared-a.meta"
  printf '%s\n' 'window=fleet:shared-owner' 'spawn_gen=shared-b-gen' > "$dir/state/shared-b.meta"
  write_exact_death_receipt "$dir/state" shared-a fleet:shared-owner tmux shared-a-gen \
    || fail 'could not publish the shared endpoint receipt'
  for id in $(seq 1 80); do
    target="fleet:retained-$id"
    targets="$targets $target"
    printf 'window=%s\nspawn_gen=retained-%s\n' "$target" "$id" > "$dir/state/retained-$id.meta"
    if [ "$id" -le 40 ]; then
      write_exact_death_receipt "$dir/state" "retained-$id" "$target" tmux "retained-$id" \
        || fail "could not publish exact receipt $id"
    else
      key=$(printf '%s' "$target" | tr ':/' '__' | tr '.' '_')
      printf 'fm-death-notified.v2\tspawn:retained-%s\tretained-%s\ttmux\t%s\n' \
        "$id" "$id" "$target" > "$dir/state/.death-notified-$key"
    fi
  done
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/find" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *".death-notified-v3"*)
    : > "$FM_TEST_RECEIPT_SCAN_LOG"
    exit 97
    ;;
esac
exec /usr/bin/find "$@"
SH
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/find" "$dir/fakebin/tmux"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$targets" \
    FM_TEST_RECEIPT_SCAN_LOG="$dir/receipt-tree-scanned" FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover_legacy "$FM_STATE_OVERRIDE" || exit 1
      fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin" > "$dir/recovered" || fail 'large surfaced-death registry recovery failed'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/recovered")
  [ "$inventory" = shared-b ] \
    || fail "an owner receipt suppressed a distinct owner on the same endpoint: $inventory"
  [ ! -e "$dir/receipt-tree-scanned" ] || fail 'registry recovery scanned the receipt tree'
  pass 'registry recovery resolves exact and legacy receipts per owner'
}

test_registry_pending_snapshot_is_immediately_authoritative() {
  local dir before after inventory
  dir=$(fixture active-supervision-pending-snapshot)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:existing' 'spawn_gen=existing-a' > "$dir/state/existing.meta"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:existing' \
    FM_TEST_LIVE_TARGETS='fleet:existing' FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover_legacy "$FM_STATE_OVERRIDE"
    ' _ "$ROOT/bin" || fail 'could not initialize registry snapshot'
  before=$(cut -f2 "$dir/state/.active-supervision-generation")
  printf '%s\n' 'window=fleet:pending' 'spawn_gen=pending-a' > "$dir/state/pending.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_prepare "$FM_STATE_OVERRIDE" pending "$FM_STATE_OVERRIDE/pending.meta"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/pending-inventory" || fail 'pending lifecycle publication failed'
  after=$(cut -f2 "$dir/state/.active-supervision-generation")
  [ "$after" != "$before" ] || fail 'pending lifecycle publication did not replace the registry generation'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/pending-inventory")
  [ "$inventory" = $'existing\npending' ] || fail "pending owner was not atomically visible: $inventory"
  pass 'pending lifecycle ownership publishes through one authoritative snapshot'
}

test_registry_snapshot_index_is_generation_bound() {
  local dir id targets='' generation index first second rc
  dir=$(fixture active-supervision-membership-index)
  install_endpoint_inventory_tmux "$dir"
  for id in $(seq 1 80); do
    targets="$targets fleet:active-$id"
    printf 'window=fleet:active-%s\nspawn_gen=active-%s\n' "$id" "$id" \
      > "$dir/state/active-$id.meta"
  done
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS="$targets" FM_TEST_LIVE_TARGETS="$targets" \
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-backend.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_recover_legacy "$FM_STATE_OVERRIDE" || exit 1
    ' _ "$ROOT/bin" || fail 'large active registry fixture could not be recovered'
  generation=$(head -1 "$dir/state/.active-supervision-generation" | cut -f2)
  index=$(mktemp -d "$dir/state/.active-supervision-index.test.XXXXXX")
  FM_STATE_OVERRIDE="$dir/state" FM_TEST_INDEX="$index" FM_TEST_GENERATION="$generation" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_snapshot_index \
      "$FM_STATE_OVERRIDE" "$FM_TEST_GENERATION" "$FM_TEST_INDEX" || exit 1
    for id in $(seq 1 80); do
      fm_supervision_registry_index_contains "$FM_TEST_INDEX" "active-$id" || exit 1
    done
    ! fm_supervision_registry_index_contains "$FM_TEST_INDEX" archived
  ' _ "$ROOT/bin" || fail 'generation-bound membership index lost active-owner identity'
  printf '%s\n' 'window=fleet:new' 'spawn_gen=new-gen' > "$dir/state/new.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" new "$FM_STATE_OVERRIDE/new.meta" || exit 1
    head -1 "$FM_STATE_OVERRIDE/.active-supervision-generation" | cut -f2
    fm_supervision_registry_retire "$FM_STATE_OVERRIDE" new || exit 1
    head -1 "$FM_STATE_OVERRIDE/.active-supervision-generation" | cut -f2
  ' _ "$ROOT/bin" > "$dir/rapid-generations" || fail 'rapid registry mutations failed'
  first=$(sed -n '1p' "$dir/rapid-generations")
  second=$(sed -n '2p' "$dir/rapid-generations")
  case "$generation:$first:$second" in g[0-9]*:g[0-9]*:g[0-9]*) ;; *) fail 'registry emitted a non-monotonic generation format' ;; esac
  [ "${first#g}" -gt "${generation#g}" ] && [ "${second#g}" -gt "${first#g}" ] \
    || fail "rapid registry mutations reused or reversed generations: $generation $first $second"
  set +e
  FM_STATE_OVERRIDE="$dir/state" FM_TEST_GENERATION="$generation" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE" "$FM_TEST_GENERATION"
  ' _ "$ROOT/bin" >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail 'registry mutation did not revoke the indexed generation'
  find "$index" -depth -delete
  pass 'active-owner membership is indexed once per monotonic generation'
}

test_incarnation_allocator_is_durable_unique_and_nonreusable() {
  local dir id pid first second values count expected pids=
  dir=$(fixture incarnation-allocation)
  initialize_empty_active_supervision_registry "$dir"
  : > "$dir/incarnations"
  for id in $(seq 1 64); do
    (
      FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$1/fm-wake-lib.sh"
        . "$1/fm-supervision-registry-lib.sh"
        fm_supervision_registry_allocate_incarnation "$FM_STATE_OVERRIDE" same-task
      ' _ "$ROOT/bin" >> "$dir/incarnations"
    ) &
    pids="$pids $!"
  done
  for pid in $pids; do
    wait "$pid" || fail 'parallel incarnation allocation failed'
  done
  for id in $(seq 1 4); do
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"
      . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_allocate_incarnation "$FM_STATE_OVERRIDE" same-task
    ' _ "$ROOT/bin" >> "$dir/incarnations" \
      || fail 'post-process-restart incarnation allocation failed'
  done
  count=$(wc -l < "$dir/incarnations" | tr -d ' ')
  [ "$count" = 68 ] || fail "incarnation allocator returned $count of 68 values"
  [ "$(LC_ALL=C sort -u "$dir/incarnations" | wc -l | tr -d ' ')" = 68 ] \
    || fail 'parallel incarnation allocation reused a value'
  values=$(sed -E 's/^i([0-9]+)\..*/\1/' "$dir/incarnations" | sort -n)
  expected=$(seq 1 68)
  [ "$values" = "$expected" ] || fail 'durable incarnation sequence was not strictly monotonic'

  first=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_allocate_incarnation "$FM_STATE_OVERRIDE" receipt-task
  ' _ "$ROOT/bin") || fail 'could not allocate original receipt incarnation'
  printf '%s\n' 'window=fleet:receipt' 'backend=tmux' "spawn_gen=$first" \
    > "$dir/state/receipt-task.meta"
  write_exact_death_receipt "$dir/state" receipt-task fleet:receipt tmux "$first" \
    || fail 'could not persist old incarnation death receipt'
  second=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_allocate_incarnation "$FM_STATE_OVERRIDE" receipt-task
  ' _ "$ROOT/bin") || fail 'could not allocate replacement receipt incarnation'
  printf '%s\n' 'window=fleet:receipt' 'backend=tmux' "spawn_gen=$second" \
    > "$dir/state/receipt-task.meta"
  if FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_death_surfaced \
      "$FM_STATE_OVERRIDE" receipt-task "$FM_STATE_OVERRIDE/receipt-task.meta"
  ' _ "$ROOT/bin"; then
    fail 'an old death receipt suppressed a replacement incarnation'
  fi
  if FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_allocate_incarnation "$FM_STATE_OVERRIDE" same-task replayed-value
  ' _ "$ROOT/bin"; then
    fail 'the allocator accepted a caller-selected replay value'
  fi
  pass 'incarnation allocation is monotonic, parallel-safe, and non-replayable'
}

test_registry_reservation_recovers_spawn_crash_windows() {
  local dir inventory rc
  dir=$(fixture active-supervision-reservation-recovery)
  install_endpoint_inventory_tmux "$dir"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" abandoned abandoned-gen || exit 1
  ' _ "$ROOT/bin" || fail 'pre-endpoint reservation fixture failed'
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/rolled-back" || fail 'dead pre-endpoint reservation did not roll back'
  [ ! -s "$dir/rolled-back" ] || fail 'dead pre-endpoint reservation entered active inventory'

  set +e
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" live live-gen || exit 1
    printf "%s\n" "window=fleet:fm-live" "endpoint_task_id=live" \
      "worktree=$2/live-worktree" "project=$2/live-project" "kind=ship" \
      "spawn_gen=live-gen" > "$FM_STATE_OVERRIDE/.live.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" live live-gen created tmux @42 fleet:fm-live \
      "$FM_STATE_OVERRIDE/.live.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" dead dead-gen || exit 1
    printf "%s\n" "window=fleet:fm-dead" "endpoint_task_id=dead" \
      "worktree=$2/dead-worktree" "project=$2/dead-project" "kind=ship" \
      "spawn_gen=dead-gen" > "$FM_STATE_OVERRIDE/.dead.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" dead dead-gen created tmux @43 fleet:fm-dead \
      "$FM_STATE_OVERRIDE/.dead.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" uncertain uncertain-gen || exit 1
    printf "%s\n" "window=fleet:fm-uncertain" "endpoint_task_id=uncertain" \
      "worktree=$2/uncertain-worktree" "project=$2/uncertain-project" "kind=ship" \
      "spawn_gen=uncertain-gen" > "$FM_STATE_OVERRIDE/.uncertain.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" uncertain uncertain-gen created tmux @44 fleet:fm-uncertain \
      "$FM_STATE_OVERRIDE/.uncertain.staged" || exit 1
    exit 74
  ' _ "$ROOT/bin" "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 74 ] || fail 'post-creation crash fixture did not reach its crash boundary'
  PATH="$dir/fakebin:$PATH" \
    FM_TEST_EXISTING_TARGETS='fleet:fm-live fleet:fm-dead fleet:fm-uncertain' \
    FM_TEST_LIVE_TARGETS='fleet:fm-live' FM_TEST_AMBIGUOUS_TARGETS='fleet:fm-uncertain' \
    FM_TEST_TMUX_RESERVATIONS="@42=fleet:fm-live=$dir/live-worktree @43=fleet:fm-dead=$dir/dead-worktree @44=fleet:fm-uncertain=$dir/uncertain-worktree" \
    FM_TEST_TMUX_KILL_LOG="$dir/killed-reservations" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/created-unpublished" \
    || fail 'created endpoint reservation did not converge after owner death'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/created-unpublished")
  [ "$inventory" = $'live\nuncertain' ] \
    || fail "created endpoint recovery produced the wrong inventory: $inventory"
  [ "$(sed -n 's/^window=//p' "$dir/state/live.meta")" = fleet:fm-live ] \
    && [ "$(sed -n 's/^worktree=//p' "$dir/state/live.meta")" = "$dir/live-worktree" ] \
    && [ "$(sed -n 's/^spawn_gen=//p' "$dir/state/live.meta")" = live-gen ] \
    || fail 'live endpoint recovery did not publish its classifier-compatible identity'
  [ "$(sed -n 's/^window=//p' "$dir/state/uncertain.meta")" = fleet:fm-uncertain ] \
    && [ "$(sed -n 's/^worktree=//p' "$dir/state/uncertain.meta")" = "$dir/uncertain-worktree" ] \
    || fail 'uncertain endpoint recovery did not remain conservatively active'
  [ ! -e "$dir/state/dead.meta" ] && [ "$(cat "$dir/killed-reservations")" = @43 ] \
    || fail 'proven dead reservation was not retired through its stable identity'
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/live.meta" live
    fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/uncertain.meta" uncertain
  ' _ "$ROOT/bin" || fail 'recovered tmux metadata did not pass lifecycle validation'
  grep -F "$(printf 'entry\tlive\tlive-gen\tpending')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'live endpoint reservation did not become pending ownership'

  set +e
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" remote remote-gen || exit 1
    printf "%s\n" "window=remote:remote" "endpoint_task_id=remote" \
      "worktree=/remote/home" "project=/remote/root" "harness=codex" \
      "kind=secondmate" "mode=secondmate" "yolo=off" "home=/remote/home" \
      "projects=project-a" "remote_host=host.example" "remote_root=/remote/root" \
      "remote_backend=herdr" "remote_herdr_session=fm-remote" "remote_target=unknown" \
      "spawn_gen=remote-gen" > "$FM_STATE_OVERRIDE/.remote.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" remote remote-gen remote-unknown remote remote:remote host.example \
      "$FM_STATE_OVERRIDE/.remote.staged" || exit 1
    exit 75
  ' _ "$ROOT/bin" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 75 ] || fail 'remote unknown-completion fixture did not reach its boundary'
  mkdir -p "$dir/data"
  cat > "$dir/data/secondmates.md" <<EOF
- remote - Remote fixture (host: host.example; root: /remote/root; home: /remote/home; scope: recovery; projects: project-a; added 2026-10-17)
- remote-missing - Missing remote fixture (host: missing.example; root: /remote/missing-root; home: /remote/missing-home; scope: recovery; projects: project-a; added 2026-10-17)
EOF
  cat > "$dir/fakebin/recovery-ssh" <<'SH'
#!/usr/bin/env bash
case "${FM_TEST_REMOTE_RECOVERY:-unknown}" in
  unknown) exit 255 ;;
  alive)
    printf '%s\n' 'schema=fm-remote-secondmate-recovery.v1' 'state=alive' \
      'backend=herdr' 'target=fm-remote:pane-remote' 'herdr_session=fm-remote' 'harness=codex'
    ;;
  missing) printf '%s\n' 'schema=fm-remote-secondmate-recovery.v1' 'state=missing' ;;
  *) exit 1 ;;
esac
SH
  chmod 0700 "$dir/fakebin/recovery-ssh"
  set +e
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" \
    FM_SSH_BIN="$dir/fakebin/recovery-ssh" FM_TEST_REMOTE_RECOVERY=unknown \
    FM_SEND_REMOTE_BUDGET=2 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/remote-unavailable"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'unavailable remote recovery exposed an incomplete inventory'
  grep -F "$(printf 'reservation\tremote\tremote-gen')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'unknown remote completion released its reservation'

  cat > "$dir/data/secondmates.md" <<EOF
- remote - Remote fixture (host: host.example; root: /remote/drift-root; home: /remote/home; scope: recovery; projects: project-a; added 2026-10-17)
- remote-missing - Missing remote fixture (host: missing.example; root: /remote/missing-root; home: /remote/missing-home; scope: recovery; projects: project-a; added 2026-10-17)
EOF
  set +e
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" \
    FM_SSH_BIN="$dir/fakebin/recovery-ssh" FM_TEST_REMOTE_RECOVERY=alive \
    FM_SEND_REMOTE_BUDGET=2 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/remote-drift"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'remote recovery followed a route that changed roots'
  grep -F "$(printf 'reservation\tremote\tremote-gen')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'route drift released unknown remote ownership'
  cat > "$dir/data/secondmates.md" <<EOF
- remote - Remote fixture (host: host.example; root: /remote/root; home: /remote/home; scope: recovery; projects: project-a; added 2026-10-17)
- remote-missing - Missing remote fixture (host: missing.example; root: /remote/missing-root; home: /remote/missing-home; scope: recovery; projects: project-a; added 2026-10-17)
EOF

  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" \
    FM_SSH_BIN="$dir/fakebin/recovery-ssh" FM_TEST_REMOTE_RECOVERY=alive \
    FM_SEND_REMOTE_BUDGET=2 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/remote-known" \
    || fail 'authoritative remote recovery did not converge'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/remote-known")
  [ "$inventory" = $'live\nremote\nuncertain' ] \
    || fail "remote unknown recovery produced the wrong inventory: $inventory"
  [ "$(sed -n 's/^window=//p' "$dir/state/remote.meta")" = remote:remote ] \
    && [ "$(sed -n 's/^remote_host=//p' "$dir/state/remote.meta")" = host.example ] \
    && [ "$(sed -n 's/^remote_target=//p' "$dir/state/remote.meta")" = fm-remote:pane-remote ] \
    && [ "$(sed -n 's/^spawn_gen=//p' "$dir/state/remote.meta")" = remote-gen ] \
    || fail 'remote unknown recovery did not preserve its route ownership'

  set +e
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" remote-missing missing-gen || exit 1
    printf "%s\n" "window=remote:remote-missing" "endpoint_task_id=remote-missing" \
      "worktree=/remote/missing-home" "project=/remote/missing-root" "harness=codex" \
      "kind=secondmate" "mode=secondmate" "yolo=off" "home=/remote/missing-home" \
      "projects=project-a" "remote_host=missing.example" "remote_root=/remote/missing-root" \
      "remote_backend=herdr" "remote_herdr_session=fm-remote" "remote_target=unknown" \
      "spawn_gen=missing-gen" > "$FM_STATE_OVERRIDE/.remote-missing.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" remote-missing missing-gen remote-unknown remote \
      remote:remote-missing missing.example "$FM_STATE_OVERRIDE/.remote-missing.staged" || exit 1
    exit 76
  ' _ "$ROOT/bin" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 76 ] || fail 'remote missing fixture did not reach its crash boundary'
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_DATA_OVERRIDE="$dir/data" \
    FM_SSH_BIN="$dir/fakebin/recovery-ssh" FM_TEST_REMOTE_RECOVERY=missing \
    FM_SEND_REMOTE_BUDGET=2 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/remote-missing" \
    || fail 'authoritative remote absence did not converge'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/remote-missing")
  [ "$inventory" = $'live\nremote\nuncertain' ] \
    || fail "remote absence changed the wrong inventory: $inventory"
  if [ ! -e "$dir/state/remote-missing.meta" ] \
    && ! grep -F "$(printf 'reservation\tremote-missing\t')" \
      "$dir/state/.active-supervision-generation" >/dev/null; then
    :
  else
    fail 'proven remote absence retained lifecycle ownership'
  fi

  set +e
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" published published-gen || exit 1
    printf "%s\n" "window=fleet:fm-published" "endpoint_task_id=published" \
      "worktree=$2/published-worktree" "project=$2/published-project" "kind=ship" \
      "spawn_gen=published-gen" > "$FM_STATE_OVERRIDE/.published.staged" || exit 1
    fm_supervision_registry_mark_reservation \
      "$FM_STATE_OVERRIDE" published published-gen created tmux @43 fleet:fm-published \
      "$FM_STATE_OVERRIDE/.published.staged" || exit 1
    cp "$FM_STATE_OVERRIDE/.published.staged" "$FM_STATE_OVERRIDE/published.meta" || exit 1
    exit 73
  ' _ "$ROOT/bin" "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 73 ] || fail 'post-metadata crash fixture did not reach its crash boundary'
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/recovered" || fail 'published reservation was not recovered'
  inventory=$(sed 's/.*\///; s/\.meta$//' "$dir/recovered")
  [ "$inventory" = $'live\npublished\nremote\nuncertain' ] \
    || fail "post-metadata crash recovered the wrong inventory: $inventory"
  grep -F "$(printf 'entry\tpublished\tpublished-gen\tpending')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'published reservation did not become pending lifecycle ownership'
  pass 'spawn reservations recover live, dead, uncertain, published, and remote outcomes'
}

test_remote_recovery_protocol_reports_exact_endpoint() {
  local dir home out
  dir=$(fixture remote-recovery-protocol)
  home="$dir/remote-home"
  mkdir -p "$home/bin" "$home/state/parent-route" "$dir/fakebin"
  : > "$home/AGENTS.md"
  printf '%s\n' remote > "$home/.fm-secondmate-home"
  printf '%s\n' 'window=fm-remote:pane-recovery' 'endpoint_task_id=remote' \
    'worktree=/remote/worktree' 'project=/remote/project' 'harness=codex' \
    'kind=secondmate' 'backend=herdr' 'herdr_session=fm-remote' \
    'herdr_workspace_id=workspace-recovery' 'herdr_tab_id=tab-recovery' \
    'herdr_pane_id=pane-recovery' 'spawn_gen=remote-host-gen' \
    > "$home/state/parent-route/remote.meta"
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  pane:get) printf '%s\n' '{"result":{"pane":{"pane_id":"pane-recovery"}}}' ;;
  agent:get) printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' ;;
  *) exit 1 ;;
esac
SH
  chmod 0700 "$dir/fakebin/herdr"
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" recovery remote) \
    || fail 'remote recovery protocol could not inspect an exact endpoint'
  [ "$out" = $'schema=fm-remote-secondmate-recovery.v1\nstate=alive\nbackend=herdr\ntarget=fm-remote:pane-recovery\nherdr_session=fm-remote\nharness=codex' ] \
    || fail "remote recovery protocol returned an inexact endpoint: $out"
  rm -f "$home/state/parent-route/remote.meta"
  out=$(PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" recovery remote) \
    || fail 'remote recovery protocol could not report authoritative absence'
  [ "$out" = $'schema=fm-remote-secondmate-recovery.v1\nstate=missing' ] \
    || fail "remote recovery protocol did not report exact absence: $out"
  pass 'remote recovery protocol reports exact endpoints and absence'
}

test_transaction_journals_recover_every_backend() {
  local dir rc task
  dir=$(fixture transaction-journal-backends)
  install_endpoint_inventory_herdr "$dir"
  install_endpoint_inventory_tmux "$dir"
  set +e
  PATH="$dir/fakebin:$PATH" FM_TEST_HERDR_EXISTING_TARGETS=default:pane-1 \
    FM_TEST_TMUX_RESERVATIONS='@42=fleet:fm-tmux-task=/tmp/tmux\c-work' \
    FM_TEST_EXISTING_TARGETS='fleet:fm-tmux-task' \
    FM_TEST_LIVE_TARGETS='fleet:fm-tmux-task' \
    FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1

    printf "%s\n" "window=fleet:fm-tmux-task" "endpoint_task_id=tmux-task" \
      "worktree=/tmp/tmux\\c-work" "project=/tmp/tmux\\c-project" "kind=ship" \
      "spawn_gen=tmux-gen" > "$FM_STATE_OVERRIDE/.tmux-task.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" tmux-task tmux-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" tmux-task tmux-gen \
      created tmux @42 fleet:fm-tmux-task "$FM_STATE_OVERRIDE/.tmux-task.staged" || exit 1

    printf "%s\n" "window=default:pane-1" "endpoint_task_id=herdr-flat" \
      "worktree=/tmp/work\\c-flat" "project=/tmp/project\\c-flat" "kind=ship" \
      "backend=herdr" "herdr_session=default" "herdr_workspace_id=workspace-1" \
      "herdr_tab_id=tab-1" "herdr_pane_id=pane-1" "spawn_gen=herdr-gen" \
      > "$FM_STATE_OVERRIDE/.herdr-flat.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" herdr-flat herdr-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" herdr-flat herdr-gen \
      created herdr default:pane-1 tab-1 "$FM_STATE_OVERRIDE/.herdr-flat.staged" || exit 1

    printf "%s\n" "window=default:pane-2" "endpoint_task_id=herdr-projected" \
      "worktree=/tmp/projected-work" "project=/tmp/projected-project" "kind=ship" \
      "backend=herdr" "herdr_session=default" "herdr_workspace_id=workspace-2" \
      "herdr_tab_id=tab-pane-2" "herdr_pane_id=pane-2" "spawn_gen=projected-gen" \
      > "$FM_STATE_OVERRIDE/.herdr-projected.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" herdr-projected projected-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" herdr-projected projected-gen \
      created herdr default:pane-2 tab-pane-2 \
      "$FM_STATE_OVERRIDE/.herdr-projected.staged" || exit 1

    printf "%s\n" "window=zellij-main:2" "endpoint_task_id=zellij-task" \
      "worktree=/tmp/zellij-work" "project=/tmp/zellij-project" "kind=ship" \
      "backend=zellij" "zellij_session=zellij-main" "zellij_tab_id=1" \
      "zellij_pane_id=2" "spawn_gen=zellij-gen" \
      > "$FM_STATE_OVERRIDE/.zellij-task.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" zellij-task zellij-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" zellij-task zellij-gen \
      created zellij zellij-main:2 1 "$FM_STATE_OVERRIDE/.zellij-task.staged" || exit 1

    printf "%s\n" "window=workspace-2:surface-2" "endpoint_task_id=cmux-task" \
      "worktree=/tmp/cmux-work" "project=/tmp/cmux-project" "kind=ship" \
      "backend=cmux" "cmux_workspace_id=workspace-2" "cmux_surface_id=surface-2" \
      "spawn_gen=cmux-gen" > "$FM_STATE_OVERRIDE/.cmux-task.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" cmux-task cmux-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" cmux-task cmux-gen \
      created cmux workspace-2:surface-2 workspace-2 "$FM_STATE_OVERRIDE/.cmux-task.staged" || exit 1

    printf "%s\n" "window=fm-orca-task" "endpoint_task_id=orca-task" \
      "worktree=/tmp/orca-work" "project=/tmp/orca-project" "kind=ship" \
      "backend=orca" "orca_worktree_id=worktree-3" "terminal=terminal-3" \
      "spawn_gen=orca-gen" > "$FM_STATE_OVERRIDE/.orca-task.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" orca-task orca-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" orca-task orca-gen \
      created orca terminal-3 worktree-3 "$FM_STATE_OVERRIDE/.orca-task.staged" || exit 1

    printf "%s\n" "window=remote:remote-pending" "endpoint_task_id=remote-pending" \
      "worktree=/remote/pending-home" "project=/remote/pending-root" "harness=codex" \
      "kind=secondmate" "mode=secondmate" "yolo=off" "home=/remote/pending-home" \
      "projects=project-a" "remote_host=pending.example" \
      "remote_root=/remote/pending-root" "remote_backend=herdr" \
      "remote_herdr_session=fm-remote" "remote_target=unknown" \
      "spawn_gen=remote-pending-gen" > "$FM_STATE_OVERRIDE/.remote-pending.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" remote-pending remote-pending-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" remote-pending remote-pending-gen \
      remote-unknown remote remote:remote-pending pending.example \
      "$FM_STATE_OVERRIDE/.remote-pending.staged" || exit 1

    printf "%s\n" "window=remote:remote-created" "endpoint_task_id=remote-created" \
      "worktree=/remote/home" "project=/remote/root" "harness=codex" \
      "kind=secondmate" "mode=secondmate" "yolo=off" "home=/remote/home" \
      "projects=project-a,project-b" "remote_host=remote.example" \
      "remote_root=/remote/root" "remote_backend=herdr" \
      "remote_herdr_session=fm-remote" "remote_target=fm-remote:pane-4" \
      "spawn_gen=remote-created-gen" > "$FM_STATE_OVERRIDE/.remote-created.staged" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" remote-created remote-created-gen || exit 1
    fm_supervision_registry_mark_reservation "$FM_STATE_OVERRIDE" remote-created remote-created-gen \
      created remote-herdr fm-remote:pane-4 remote.example \
      "$FM_STATE_OVERRIDE/.remote-created.staged" || exit 1
    exit 79
  ' _ "$ROOT/bin" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 79 ] || fail 'validator-complete backend journals did not reach their crash boundary'

  mkdir -p "$dir/data"
  cat > "$dir/data/secondmates.md" <<EOF
- remote-pending - Pending remote fixture (host: pending.example; root: /remote/pending-root; home: /remote/pending-home; scope: recovery; projects: project-a; added 2026-10-17)
EOF
  cat > "$dir/fakebin/recovery-ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'schema=fm-remote-secondmate-recovery.v1' 'state=alive' \
  'backend=herdr' 'target=fm-remote:pane-pending' 'herdr_session=fm-remote' 'harness=codex'
SH
  chmod 0700 "$dir/fakebin/recovery-ssh"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DATA_OVERRIDE="$dir/data" FM_SSH_BIN="$dir/fakebin/recovery-ssh" \
    FM_TEST_HERDR_EXISTING_TARGETS='default:pane-1 default:pane-2' \
    FM_TEST_TMUX_RESERVATIONS='@42=fleet:fm-tmux-task=/tmp/tmux\c-work' \
    FM_TEST_EXISTING_TARGETS='fleet:fm-tmux-task' \
    FM_TEST_LIVE_TARGETS='fleet:fm-tmux-task' \
    FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin" > "$dir/inventory" || fail 'backend transaction journals did not recover'
  for task in tmux-task herdr-flat herdr-projected zellij-task cmux-task orca-task remote-created; do
    cmp "$dir/state/.$task.staged" "$dir/state/$task.meta" \
      || fail "$task transaction journal did not preserve metadata bytes"
  done
  for task in tmux-task herdr-flat herdr-projected zellij-task cmux-task orca-task; do
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-backend.sh"
      fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/$2.meta" "$2"
    ' _ "$ROOT/bin" "$task" || fail "$task recovered metadata failed endpoint validation"
  done
  [ "$(sed -n 's/^remote_target=//p' "$dir/state/remote-created.meta")" = fm-remote:pane-4 ] \
    && [ "$(sed -n 's/^remote_root=//p' "$dir/state/remote-created.meta")" = /remote/root ] \
    || fail 'remote-created journal lost its exact route'
  [ "$(sed -n 's/^remote_target=//p' "$dir/state/remote-pending.meta")" = fm-remote:pane-pending ] \
    && [ "$(sed -n 's/^remote_host=//p' "$dir/state/remote-pending.meta")" = pending.example ] \
    && [ "$(sed -n 's/^remote_root=//p' "$dir/state/remote-pending.meta")" = /remote/pending-root ] \
    || fail 'remote-before-response journal did not converge to its authoritative route'
  pass 'transaction journals preserve backend metadata and converge remote unknown completion'
}

test_planned_reservations_converge_after_backend_creation_crashes() {
  local dir rc backend task target facts
  dir=$(fixture planned-reservation-crashes)
  set +e
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_backend_recover_planned() { printf "missing\t-\t-\t-\t-\t-\t-\t-\t-\n"; }
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
    while IFS="|" read -r backend task target detail; do
      staged="$FM_STATE_OVERRIDE/.$task.plan"
      printf "%s\n" "window=$target" "endpoint_task_id=$task" \
        "endpoint_state=planned" "worktree=/planned/$task" \
        "project=/project/$task" "harness=codex" "kind=ship" \
        "backend=$backend" "recovery_detail=$detail" "spawn_gen=$task-gen" \
        > "$staged" || exit 1
      fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" "$task" "$task-gen" || exit 1
      fm_supervision_registry_plan_reservation "$FM_STATE_OVERRIDE" "$task" "$task-gen" \
        "$backend" "$target" "$detail" "$staged" || exit 1
    done <<EOF
tmux|planned-tmux|fleet:fm-planned-tmux|fleet:fm-planned-tmux
herdr|planned-herdr|default:fm-planned-herdr|workspace-planned
zellij|planned-zellij|zellij-main:fm-planned-zellij|zellij-main
cmux|planned-cmux|fm-planned-cmux|fm-home-planned-cmux
orca|planned-orca|fm-planned-orca|/project/planned-orca
tmux|planned-missing|fleet:fm-planned-missing|fleet:fm-planned-missing
tmux|planned-unknown|fleet:fm-planned-unknown|fleet:fm-planned-unknown
EOF
    exit 79
  ' _ "$ROOT/bin" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 79 ] || fail 'planned reservations did not reach the simulated creation crash'
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_backend_recover_planned() {
      case "$2" in
        planned-tmux) printf "found\tcreated\t@41\tfleet:fm-planned-tmux\t/planned/planned-tmux\t-\t-\t-\t-\n" ;;
        planned-herdr) printf "found\tcreated\tdefault:pane-2\ttab-2\t-\tdefault\tworkspace-planned\ttab-2\tpane-2\n" ;;
        planned-zellij) printf "found\tcreated\tzellij-main:8\t7\t-\tzellij-main\t7\t8\t-\n" ;;
        planned-cmux) printf "found\tcreated\tworkspace-3:surface-3\tworkspace-3\t-\tworkspace-3\tsurface-3\t-\t-\n" ;;
        planned-orca) printf "found\tworktree-only\tfm-planned-orca\tworktree-4\t/planned/planned-orca\tworktree-4\t-\t-\t-\n" ;;
        planned-missing) printf "missing\t-\t-\t-\t-\t-\t-\t-\t-\n" ;;
        planned-unknown) return 1 ;;
        *) return 1 ;;
      esac
    }
    fm_backend_agent_state_batch() {
      while IFS="$(printf "\t")" read -r backend target route home; do
        printf "%s\t%s\tdead\t%s\t%s\n" "$backend" "$target" "$route" "$home"
      done
    }
    fm_backend_reservation_identity() { printf "match\t/planned/planned-tmux\n"; }
    fm_backend_retire_reservation() { printf "tmux:%s\n" "$2" >> "$FM_STATE_OVERRIDE/retired-plans"; }
    fm_backend_kill() { printf "%s:%s\n" "$1" "$2" >> "$FM_STATE_OVERRIDE/retired-plans"; }
    fm_supervision_registry_generation "$FM_STATE_OVERRIDE" >/dev/null
  ' _ "$ROOT/bin" || fail 'planned reservation reconciliation failed'
  for backend in tmux herdr zellij cmux; do
    task="planned-$backend"
    [ ! -e "$dir/state/$task.meta" ] \
      || fail "$backend creation recovery published endpoint-only metadata"
    ! grep -F "$(printf '\t%s\t' "$task")" \
      "$dir/state/.active-supervision-generation" >/dev/null \
      || fail "$backend endpoint-only recovery retained a retired endpoint"
  done
  grep -F 'tmux:@41' "$dir/state/retired-plans" >/dev/null \
    || fail 'tmux endpoint-only recovery did not retire its stable endpoint'
  if grep -F 'herdr:default:pane-2' "$dir/state/retired-plans" >/dev/null \
    && grep -F 'zellij:zellij-main:8' "$dir/state/retired-plans" >/dev/null \
    && grep -F 'cmux:workspace-3:surface-3' "$dir/state/retired-plans" >/dev/null; then
    :
  else
    fail 'non-tmux endpoint-only recovery did not retire exact endpoints'
  fi
  grep -F "$(printf 'entry\tplanned-orca\tplanned-orca-gen\tpending')" \
    "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'Orca worktree recovery did not publish lifecycle ownership'
  [ -f "$dir/state/planned-orca.meta" ] \
    || fail 'Orca recovery did not publish its real worktree metadata'
  ! grep -F "$(printf '\tplanned-missing\t')" "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'authoritatively missing creation plan retained ownership'
  grep -F "$(printf 'reservation\tplanned-unknown\tplanned-unknown-gen\t')" \
    "$dir/state/.active-supervision-generation" | grep -F "$(printf '\tplanned\ttmux\t')" >/dev/null \
    || fail 'unverified creation plan did not remain fail-closed'
  [ -z "$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_target_of_meta "$FM_STATE_OVERRIDE/planned-orca.meta"
  ' _ "$ROOT/bin")" ] || fail 'Orca worktree-only recovery invented a terminal target'
  facts=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_meta_facts "$FM_STATE_OVERRIDE/planned-orca.meta" planned-orca
  ' _ "$ROOT/bin") || fail 'Orca worktree-only metadata facts were unreadable'
  case "$facts" in absent$'\t'orca$'\t-'$'\t'*) ;; *) fail 'Orca worktree-only facts exposed a fabricated endpoint' ;; esac
  pass 'backend creation plans converge through authoritative discovery'
}

test_planned_reservation_rejects_preexisting_endpoint() {
  local dir
  dir=$(fixture planned-reservation-preexisting)
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" collision collision-gen || exit 1
    printf "%s\n" "window=fleet:fm-collision" "endpoint_task_id=collision" \
      "endpoint_state=planned" "worktree=-" "project=/project/collision" \
      "harness=codex" "kind=ship" "backend=tmux" \
      "recovery_detail=fleet:fm-collision" "spawn_gen=collision-gen" \
      > "$FM_STATE_OVERRIDE/.collision.plan" || exit 1
    fm_backend_recover_planned() {
      printf "found\tcreated\t@99\tfleet:fm-collision\t/project/collision\t-\t-\t-\t-\n"
    }
    if fm_supervision_registry_plan_reservation "$FM_STATE_OVERRIDE" collision collision-gen \
        tmux fleet:fm-collision fleet:fm-collision "$FM_STATE_OVERRIDE/.collision.plan"; then
      exit 2
    fi
  ' _ "$ROOT/bin" || fail 'pre-existing endpoint plan fixture failed'
  grep -F "$(printf 'reservation\tcollision\tcollision-gen')" \
    "$dir/state/.active-supervision-generation" | grep -F "$(printf '\treserved\t-\t-\t-')" >/dev/null \
    || fail 'pre-existing endpoint was bound into a planned transaction'
  pass 'planned reservations reject pre-existing predictable endpoints'
}

test_planned_reservation_ignores_racing_canonical_endpoint() {
  local dir inventory
  dir=$(fixture planned-reservation-race)
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_supervision_registry_recover "$FM_STATE_OVERRIDE" || exit 1
    fm_supervision_registry_reserve "$FM_STATE_OVERRIDE" racing racing-gen || exit 1
    printf "%s\n" "window=fleet:fm-racing--racing-gen" "endpoint_task_id=racing" \
      "endpoint_state=planned" "worktree=-" "project=/project/racing" \
      "harness=codex" "kind=ship" "backend=tmux" \
      "recovery_detail=fleet:fm-racing--racing-gen" "spawn_gen=racing-gen" \
      > "$FM_STATE_OVERRIDE/.racing.plan" || exit 1
    fm_backend_recover_planned() {
      [ "$3" = fleet:fm-racing ] || exit 3
      printf "missing\t-\t-\t-\t-\t-\t-\t-\t-\n"
    }
    fm_supervision_registry_plan_reservation "$FM_STATE_OVERRIDE" racing racing-gen \
      tmux fleet:fm-racing--racing-gen fleet:fm-racing--racing-gen \
      "$FM_STATE_OVERRIDE/.racing.plan" fleet:fm-racing fleet:fm-racing
  ' _ "$ROOT/bin" || fail 'could not publish transaction-bound racing plan'
  inventory=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    fm_backend_recover_planned() {
      if [ "$3" = fleet:fm-racing ]; then
        printf "found\tcreated\t@99\tfleet:fm-racing\t/project/foreign\t-\t-\t-\t-\n"
      else
        [ "$3" = fleet:fm-racing--racing-gen ] || return 1
        printf "missing\t-\t-\t-\t-\t-\t-\t-\t-\n"
      fi
    }
    fm_supervision_registry_inventory "$FM_STATE_OVERRIDE"
  ' _ "$ROOT/bin") || fail 'transaction-bound racing plan did not reconcile'
  [ -z "$inventory" ] || fail "racing canonical endpoint was adopted: $inventory"
  ! grep -F "$(printf '\tracing\t')" "$dir/state/.active-supervision-generation" >/dev/null \
    || fail 'missing provisional endpoint retained or adopted canonical ownership'
  pass 'planned reservations ignore racing canonical endpoints'
}

test_planned_backend_discovery_uses_live_identity() {
  local dir
  dir=$(fixture planned-backend-discovery)
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_source tmux || exit 1
    fm_backend_source herdr || exit 1
    fm_backend_source zellij || exit 1
    fm_backend_source cmux || exit 1
    fm_backend_source orca || exit 1
    tmux() {
      [ "$1" = list-windows ] || return 1
      printf "@71\tfleet:fm-discovery-tmux\t/live/tmux\n"
    }
    fm_backend_herdr_cli() {
      case "$2:$3" in
        tab:list) printf "%s\n" "{\"result\":{\"tabs\":[{\"tab_id\":\"tab-2\",\"label\":\"fm-discovery-herdr\"}]}}" ;;
        pane:list) printf "%s\n" "{\"result\":{\"panes\":[{\"tab_id\":\"tab-2\",\"pane_id\":\"pane-2\"}]}}" ;;
        *) return 1 ;;
      esac
    }
    fm_backend_zellij_cli() {
      case "$2:$3" in
        action:list-tabs)
          title=$(fm_backend_zellij_scoped_title fm-discovery-zellij)
          printf "[{\"tab_id\":7,\"name\":\"%s\"}]\n" "$title"
          ;;
        action:list-panes) printf "%s\n" "[{\"tab_id\":7,\"id\":8,\"is_plugin\":false}]" ;;
        *) return 1 ;;
      esac
    }
    fm_backend_cmux_cli() {
      case "$1:$2" in
        workspace:list)
          title=$(fm_backend_cmux_scoped_title fm-discovery-cmux)
          printf "{\"workspaces\":[{\"id\":\"workspace-3\",\"title\":\"%s\"}]}\n" "$title"
          ;;
        list-panes:*) printf "%s\n" "{\"panes\":[{\"selected_surface_id\":\"surface-3\"}]}" ;;
        *) return 1 ;;
      esac
    }
    orca() {
      case "$1:$2" in
        status:--json) printf "%s\n" "{\"ok\":true,\"result\":{\"runtime\":{\"reachable\":true,\"state\":\"ready\"}}}" ;;
        repo:show) printf "%s\n" "{\"ok\":true,\"result\":{\"repo\":{\"id\":\"repo-4\"}}}" ;;
        worktree:list) printf "%s\n" "{\"ok\":true,\"result\":{\"worktrees\":[{\"id\":\"worktree-4\",\"displayName\":\"fm-discovery-orca\",\"path\":\"/live/orca\"}],\"truncated\":false}}" ;;
        *) return 1 ;;
      esac
    }
    [ "$(fm_backend_tmux_recover_planned discovery-tmux fleet:fm-discovery-tmux fleet:fm-discovery-tmux)" = \
      "$(printf "found\tcreated\t@71\tfleet:fm-discovery-tmux\t/live/tmux\t-\t-\t-\t-")" ] || exit 1
    [ "$(fm_backend_herdr_recover_planned discovery-herdr default:fm-discovery-herdr workspace-2)" = \
      "$(printf "found\tcreated\tdefault:pane-2\ttab-2\t-\tdefault\tworkspace-2\ttab-2\tpane-2")" ] || exit 1
    [ "$(fm_backend_zellij_recover_planned discovery-zellij zellij-main:fm-discovery-zellij zellij-main)" = \
      "$(printf "found\tcreated\tzellij-main:8\t7\t-\tzellij-main\t7\t8\t-")" ] || exit 1
    cmux_title=$(fm_backend_cmux_scoped_title fm-discovery-cmux)
    [ "$(fm_backend_cmux_recover_planned discovery-cmux fm-discovery-cmux "$cmux_title")" = \
      "$(printf "found\tcreated\tworkspace-3:surface-3\tworkspace-3\t-\tworkspace-3\tsurface-3\t-\t-")" ] || exit 1
    [ "$(fm_backend_orca_recover_planned discovery-orca fm-discovery-orca /project/orca)" = \
      "$(printf "found\tworktree-only\tfm-discovery-orca\tworktree-4\t/live/orca\tworktree-4\t-\t-\t-")" ] || exit 1
  ' _ "$ROOT/bin" || fail 'planned backend discovery did not resolve live identities'
  pass 'planned backend discovery resolves exact live identities'
}

test_registered_check_kills_term_ignoring_process_group() {
  local dir started elapsed child rc
  dir=$(fixture registered-check-hard-timeout)
  cat > "$dir/state/ignores-term.check.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$FM_HOME/check-child-pid"
while :; do sleep 1; done
SH
  chmod 0700 "$dir/state/ignores-term.check.sh"
  started=$(monotonic_seconds)
  set +e
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CHECK_TIMEOUT=1 FM_CHECK_KILL_GRACE=1 \
    bash -c '. "$1/fm-watch.sh"; run_check_capture "$2"' \
      _ "$ROOT/bin" "$dir/state/ignores-term.check.sh"
  rc=$?
  set -e
  elapsed=$(( $(monotonic_seconds) - started ))
  [ "$rc" -eq 0 ] || fail "hard-timeout check runner failed: rc=$rc"
  [ "$elapsed" -le 4 ] || fail "TERM-ignoring check exceeded its kill/reap lease: ${elapsed}s"
  child=$(cat "$dir/check-child-pid" 2>/dev/null || true)
  [ -n "$child" ] || fail 'TERM-ignoring check never started'
  ! kill -0 "$child" 2>/dev/null || fail 'TERM-ignoring check survived the hard timeout'
  pass 'registered checks receive TERM then bounded KILL and reap'
}

test_registered_check_preserves_grace_for_orphan_descendant() {
  local dir started elapsed child rc
  dir=$(fixture registered-check-orphan-grace)
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env perl
use strict;
use warnings;
my ($flag, $grace, $bound, @command) = @ARGV;
exit 98 unless defined $flag && $flag eq '-k';
my $pid = fork;
exit 97 unless defined $pid;
if (!$pid) {
  my $grandchild = fork;
  exit 96 unless defined $grandchild;
  if (!$grandchild) {
    $SIG{TERM} = 'IGNORE';
    open my $marker, '>', "$ENV{FM_HOME}/orphan-child-pid" or exit 95;
    print {$marker} "$$\n";
    close $marker;
    while (1) { sleep 1; }
  }
  waitpid $grandchild, 0;
  exit 0;
}
local $SIG{ALRM} = sub {
  local $SIG{TERM} = 'IGNORE';
  kill 'TERM', -getpgrp(0);
  waitpid $pid, 0;
  exit 124;
};
alarm $bound;
waitpid $pid, 0;
exit($? >> 8);
SH
  chmod 0700 "$dir/fakebin/timeout"
  cat > "$dir/state/orphan.check.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$dir/state/orphan.check.sh"
  started=$(monotonic_seconds)
  set +e
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CHECK_TIMEOUT=2 FM_CHECK_KILL_GRACE=2 FM_CHECK_REAP_ALLOWANCE=1 \
    bash -c '. "$1/fm-watch.sh"; run_check_capture "$2"' \
      _ "$ROOT/bin" "$dir/state/orphan.check.sh"
  rc=$?
  set -e
  elapsed=$(( $(monotonic_seconds) - started ))
  [ "$rc" -eq 0 ] || fail "orphan-grace check runner failed: rc=$rc"
  [ "$elapsed" -ge 4 ] && [ "$elapsed" -le 7 ] \
    || fail "orphan descendant did not receive the configured grace: ${elapsed}s"
  child=$(cat "$dir/orphan-child-pid" 2>/dev/null || true)
  [ -n "$child" ] || fail 'orphan-descendant check never started'
  ! kill -0 "$child" 2>/dev/null || fail 'orphan descendant survived bounded group cleanup'
  pass 'registered check descendants retain grace after their leader exits'
}

test_bounded_check_starts_without_observer_endpoint() {
  local dir rc
  dir=$(fixture bounded-check-no-observer-endpoint)
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" started > "$FM_HOME/baseline-check-started"' \
    'printf "%s\n" ready' > "$dir/state/baseline.check.sh"
  chmod 0700 "$dir/state/baseline.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" baseline >/dev/null \
    || fail 'could not register baseline bounded check'
  set +e
  FM_TEST_BOUNDED_WATCH_TIMEOUT=4 FM_TEST_CHECKS_PER_CYCLE=1 \
    FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/baseline.out" 2> "$dir/baseline.err"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail 'bounded check did not start with an empty active endpoint inventory'
  wait_file "$dir/baseline-check-started" 10
  assert_contains "$(cat "$dir/state/.wake-queue")" $'check\t' \
    'baseline bounded check did not publish its actionable result'
  pass 'a due bounded check starts without an observer endpoint'
}

test_bounded_observer_remains_live_during_check() {
  local dir watcher rc check_pid
  dir=$(fixture observer-during-check)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:fm-active' "worktree=$dir" "project=$dir" \
    'backend=tmux' 'kind=ship' 'harness=codex' 'spawn_gen=observer-1' \
    > "$dir/state/active.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/active.meta" active
  ' _ "$ROOT/bin" || fail 'observer fixture endpoint did not pass lifecycle validation'
  register_active_supervision_tasks "$dir" active
  printf '%s\n' 'working: initial' > "$dir/state/active.status"
  printf '%s\n' initial > "$dir/state/active.turn-ended"
  prime_status_seen "$dir/state" "$dir/state/active.status"
  prime_status_seen "$dir/state" "$dir/state/active.turn-ended"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$$" > "$FM_HOME/observer-check-pid"' \
    'printf "%s\n" started > "$FM_HOME/observer-check-started"' 'sleep 30' \
    > "$dir/state/slow.check.sh"
  chmod 0700 "$dir/state/slow.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" slow >/dev/null \
    || fail 'could not register observer slow check'
  set +e
  FM_TEST_EXISTING_TARGETS='fleet:fm-active' FM_TEST_LIVE_TARGETS='fleet:fm-active' \
    FM_TEST_BOUNDED_WATCH_TIMEOUT=30 FM_TEST_CHECKS_PER_CYCLE=1 \
    FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_SIGNAL_GRACE=0 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/during.out" 2> "$dir/during.err" &
  watcher=$!
  set -e
  wait_file "$dir/observer-check-started" 250
  printf '%s\n' 'done: arrived during check' > "$dir/state/active.status"
  printf '%s\n' 'turn arrived during check' > "$dir/state/active.turn-ended"
  set +e
  wait "$watcher"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail 'observer parked while a registered check was running'
  assert_contains "$(cat "$dir/state/.wake-queue")" $'signal\tactive.status' \
    'status arriving during a check was not queued by the observer'
  assert_contains "$(cat "$dir/state/.wake-queue")" $'signal\tactive.turn-ended' \
    'turn-end arriving during a check was not queued by the observer'
  check_pid=$(cat "$dir/observer-check-pid")
  ! kill -0 "$check_pid" 2>/dev/null || fail 'observer wake left its running check alive'
  pass 'the cheap observer remains live while a registered check runs'
}

test_bounded_observer_remains_live_after_check_boundary() {
  local dir watcher rc
  dir=$(fixture observer-after-check-boundary)
  install_endpoint_inventory_tmux "$dir"
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' 'window=fleet:fm-active' "worktree=$dir" "project=$dir" \
    'backend=tmux' 'kind=ship' 'harness=codex' 'spawn_gen=observer-2' \
    > "$dir/state/active.meta"
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-backend.sh"
    fm_backend_validate_task_endpoint "$FM_STATE_OVERRIDE/active.meta" active
  ' _ "$ROOT/bin" || fail 'parked-observer fixture endpoint did not pass lifecycle validation'
  register_active_supervision_tasks "$dir" active
  printf '%s\n' 'working: initial' > "$dir/state/active.status"
  printf '%s\n' initial > "$dir/state/active.turn-ended"
  prime_status_seen "$dir/state" "$dir/state/active.status"
  prime_status_seen "$dir/state" "$dir/state/active.turn-ended"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/state/instant.check.sh"
  chmod 0700 "$dir/state/instant.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" instant >/dev/null \
    || fail 'could not register observer boundary check'
  set +e
  FM_TEST_EXISTING_TARGETS='fleet:fm-active' FM_TEST_LIVE_TARGETS='fleet:fm-active' \
    FM_TEST_BOUNDED_WATCH_TIMEOUT=30 FM_TEST_CHECKS_PER_CYCLE=1 \
    FM_TEST_WATCH_HANDLING_SUCCESSOR=1 FM_SIGNAL_GRACE=0 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/parked.out" 2> "$dir/parked.err" &
  watcher=$!
  set -e
  wait_file "$dir/state/.watch.lock/codex-check-batch-boundary" 250
  printf '%s\n' 'done: arrived after boundary' > "$dir/state/active.status"
  printf '%s\n' 'turn arrived after boundary' > "$dir/state/active.turn-ended"
  set +e
  wait "$watcher"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail 'observer parked with its check batch boundary'
  assert_contains "$(cat "$dir/state/.wake-queue")" $'signal\tactive.status' \
    'status arriving after check parking was not queued by the observer'
  assert_contains "$(cat "$dir/state/.wake-queue")" $'signal\tactive.turn-ended' \
    'turn-end arriving after check parking was not queued by the observer'

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1/fm-watch.sh"
    FM_CODEX_BOUNDED_WATCH=1
    FM_CODEX_REGISTRY_INDEX=$(mktemp -d "$FM_STATE_OVERRIDE/.observer-index.XXXXXX") || exit 1
    mkdir "$FM_CODEX_REGISTRY_INDEX/tasks" || exit 1
    printf "%s\n" "$FM_STATE_OVERRIDE/active.meta" > "$FM_CODEX_REGISTRY_INDEX/inventory"
    process_signal_changes() { printf "status-turn\n" >> "$FM_HOME/observer-ticks"; }
    procevent_surface_queued() { printf "process-event\n" >> "$FM_HOME/observer-ticks"; }
    inbox_steer_check() { printf "inbox\n" >> "$FM_HOME/observer-ticks"; }
    bounded_observer_tick_during_check
    find "$FM_CODEX_REGISTRY_INDEX" -depth -delete
  ' _ "$ROOT/bin" || fail 'bounded observer tick did not complete'
  [ "$(cat "$dir/observer-ticks")" = $'status-turn\nprocess-event\ninbox' ] \
    || fail 'bounded observer omitted a signal, process-event, or inbox source'
  pass 'the cheap observer remains live after check parking'
}

test_check_grace_and_absolute_lease_are_preserved() {
  local dir started elapsed child rc watcher generation identity deadline
  dir=$(fixture check-grace-and-lease)
  initialize_empty_active_supervision_registry "$dir"
  printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM' \
    'printf "%s\n" "$$" > "$FM_HOME/check-grace-child"' \
    'while :; do sleep 1; done' > "$dir/state/grace.check.sh"
  chmod 0700 "$dir/state/grace.check.sh"
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env perl
use strict;
use warnings;
my ($flag, $grace, $bound, @command) = @ARGV;
exit 98 unless defined $flag && $flag eq '-k' && $grace =~ /^\d+$/ && $bound =~ /^\d+$/;
open my $log, '>', $ENV{FM_TEST_TIMEOUT_LOG} or exit 97;
print {$log} "$grace\t$bound\n";
close $log;
my $pid = fork;
exit 96 unless defined $pid;
if (!$pid) {
  setpgrp(0, 0);
  exec @command;
  exit 95;
}
local $SIG{ALRM} = sub {
  kill 'TERM', -$pid;
  select undef, undef, undef, $grace;
  kill 'KILL', -$pid;
  waitpid $pid, 0;
  exit 124;
};
alarm $bound;
waitpid $pid, 0;
exit($? >> 8);
SH
  chmod 0700 "$dir/fakebin/timeout"
  started=$(monotonic_seconds)
  set +e
  PATH="$dir/fakebin:$PATH" FM_TEST_TIMEOUT_LOG="$dir/timeout-call" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CHECK_TIMEOUT=1 \
    FM_CHECK_KILL_GRACE=10 FM_CHECK_REAP_ALLOWANCE=1 \
    bash -c '. "$1/fm-watch.sh"; run_check_capture "$2"' \
      _ "$ROOT/bin" "$dir/state/grace.check.sh"
  rc=$?
  set -e
  elapsed=$(( $(monotonic_seconds) - started ))
  [ "$rc" -eq 0 ] || fail "configured-grace check runner failed: rc=$rc"
  [ "$elapsed" -ge 10 ] && [ "$elapsed" -le 14 ] \
    || fail "configured kill grace was not retained as 10 seconds: ${elapsed}s"
  [ "$(cat "$dir/timeout-call")" = $'10\t1' ] \
    || fail 'external timeout did not receive the configured TERM-to-KILL grace'
  child=$(cat "$dir/check-grace-child")
  ! kill -0 "$child" 2>/dev/null || fail 'configured-grace cancellation returned before reap'

  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CHECK_TIMEOUT=1 \
    FM_CHECK_KILL_GRACE=10 FM_CHECK_REAP_ALLOWANCE=2 FM_CODEX_BOUNDED_WATCH=1 \
    FM_MONOTONIC_NS_NOW=1000000000 FM_CODEX_LEASE_DEADLINE_NS=14000000000 bash -c '
      . "$1/fm-watch.sh"
      fm_codex_check_lease_allows_slot || exit 1
      FM_CODEX_LEASE_DEADLINE_NS=13999999999
      ! fm_codex_check_lease_allows_slot
    ' _ "$ROOT/bin" || fail 'check-slot admission omitted configured grace or reap allowance'

  generation=$(head -1 "$dir/state/.active-supervision-generation" | cut -f2)
  identity=$(FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1/fm-wake-lib.sh"; fm_pid_identity "$PPID"' _ "$ROOT/bin") \
    || fail 'could not capture lease-test owner identity'
  deadline=13000000000
  printf '{"token":"lease-token","owner":%s,"owner_identity":"%s","session_pid":%s,"session_identity":"%s","resume_deadline_ns":%s,"resume_cycle_timeout":1,"registry_generation":"%s","phase":"watching"}\n' \
    "$$" "$identity" "$$" "$identity" "$deadline" "$generation" \
    > "$dir/state/.codex-stop.json"
  printf 'fm-codex-check-batch.v5\tlease\t2\tlease-token\t%s\t%s\t%s\t%s\t%s\t1\t%s\n' \
    "$$" "$identity" "$$" "$identity" "$deadline" "$generation" > "$dir/exact.request"
  printf 'fm-codex-check-batch.v5\tlease\t2\tlease-token\t%s\t%s\t%s\t%s\t14000000000\t1\t%s\n' \
    "$$" "$identity" "$$" "$identity" "$generation" > "$dir/extended.request"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CODEX_CHECK_BATCH_LEASE=lease \
    FM_MONOTONIC_NS_NOW=12000000000 bash -c '
      . "$1/fm-watch.sh"
      codex_check_batch_request_valid "$2" 2 || exit 1
      ! codex_check_batch_request_valid "$3" 2
    ' _ "$ROOT/bin" "$dir/exact.request" "$dir/extended.request" \
    || fail 'resume accepted an extension of its immutable monotonic deadline'

  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/state/capability.check.sh"
  chmod 0700 "$dir/state/capability.check.sh"
  FM_HOME="$dir" "$ROOT/bin/fm-check-register.sh" capability >/dev/null \
    || fail 'could not register lease capability check'
  set +e
  FM_CHECK_KILL_GRACE=10 FM_CHECK_REAP_ALLOWANCE=2 FM_TEST_BOUNDED_WATCH_TIMEOUT=3 \
    FM_TEST_CHECKS_PER_CYCLE=1 FM_TEST_WATCH_HANDLING_SUCCESSOR=1 \
    run_bounded_watcher_cycle "$dir" "$dir/fakebin" > "$dir/capability.out" 2> "$dir/capability.err" &
  watcher=$!
  set -e
  wait_file "$dir/state/.watch.lock/codex-bounded-capability" 100
  assert_contains "$(cat "$dir/state/.watch.lock/codex-bounded-capability")" \
    $'check-kill-grace=10\tcheck-reap-allowance=2' \
    'watcher capability rewrote the configured grace or reap allowance'
  set +e
  wait "$watcher"
  set -e
  pass 'configured check grace, reap, and one monotonic deadline survive every handoff'
}

test_active_only_pending_replies_exclude_archive() {
  local dir
  dir=$(fixture active-only-pending-replies)
  for task in active archived dead-active; do
    printf '%s\n' "window=fleet:$task" 'kind=secondmate' 'harness=claude' 'backend=tmux' \
      > "$dir/state/$task.meta"
  done
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PENDING_REPLY_NOW=1000 bash -c '
    . "$1/fm-wake-lib.sh"
    . "$1/fm-backend.sh"
    . "$1/fm-supervision-registry-lib.sh"
    . "$1/fm-pending-reply-lib.sh"
    for task in active archived dead-active; do
      corr=$(fm_pending_reply_create "$FM_HOME" "$FM_STATE_OVERRIDE" "$task" report) || exit 1
      fm_pending_reply_mark_delivered "$FM_STATE_OVERRIDE" "$corr" 1000 || exit 1
    done
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" active "$FM_STATE_OVERRIDE/active.meta" || exit 1
    fm_supervision_registry_register "$FM_STATE_OVERRIDE" dead-active "$FM_STATE_OVERRIDE/dead-active.meta" || exit 1
    fm_pending_reply_backend_observation() {
      printf "%s\n" "$2" >> "$FM_HOME/observations"
      printf idle
    }
    inventory=$(printf "tmux\tfleet:active\talive\tlocal\t-\tactive\tsecondmate\t-\n")
    inventory="$inventory$(printf "\ntmux\tfleet:dead-active\tdead\tlocal\t-\tdead-active\tsecondmate\t-")"
    fm_pending_reply_tick "$FM_STATE_OVERRIDE" "$inventory" active-only
  ' _ "$ROOT/bin" || fail 'active-only pending reply tick failed'
  [ "$(cat "$dir/observations")" = 'fleet:active' ] \
    || fail 'bounded pending replies captured an archived or exact-dead endpoint'
  pass 'bounded pending replies observe only active available owners'
}

test_mixed_active_owner_policy_surfaces_once() {
  local dir pane_hash rc captures archive_busy_gen
  dir=$(fixture mixed-active-owner-policy)
  install_endpoint_inventory_tmux "$dir"
  printf '%s\n' 'window=fleet:shared' 'kind=ship' 'harness=grok' 'backend=tmux' > "$dir/state/a-archive.meta"
  archive_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/state" a-archive) \
    || fail 'could not arm archived busy owner'
  printf 'busy_gen=%s\n' "$archive_busy_gen" >> "$dir/state/a-archive.meta"
  printf '%s\n' 'working: archived owner' > "$dir/state/a-archive.status"
  printf '%s\n' 'window=fleet:shared' 'kind=ship' 'harness=claude' 'backend=tmux' > "$dir/state/b-working.meta"
  printf '%s\n' 'working: active owner' > "$dir/state/b-working.status"
  printf '%s\n' 'window=fleet:shared' 'kind=ship' 'harness=claude' 'backend=tmux' > "$dir/state/c-blocked.meta"
  printf '%s\n' 'needs-decision: captain action required' > "$dir/state/c-blocked.status"
  cat > "$dir/stopped-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'state: stopped · source: pane · bare shell'
SH
  chmod +x "$dir/stopped-crew-state.sh"
  prime_status_seen "$dir/state" "$dir/state/a-archive.status"
  prime_status_seen "$dir/state" "$dir/state/b-working.status"
  prime_status_seen "$dir/state" "$dir/state/c-blocked.status"
  PATH="$dir/fakebin:$PATH" FM_TEST_EXISTING_TARGETS='fleet:shared' FM_TEST_LIVE_TARGETS='fleet:shared' \
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-wake-lib.sh"; . "$1/fm-backend.sh"; . "$1/fm-supervision-registry-lib.sh"
      fm_supervision_registry_register "$FM_STATE_OVERRIDE" b-working "$FM_STATE_OVERRIDE/b-working.meta"
      fm_supervision_registry_register "$FM_STATE_OVERRIDE" c-blocked "$FM_STATE_OVERRIDE/c-blocked.meta"
      fm_supervision_registry_retire "$FM_STATE_OVERRIDE" a-archive
    ' _ "$ROOT/bin" || fail 'could not register mixed active owners'
  pane_hash=$(hash_text 'retained endpoint')
  printf '%s' "$pane_hash" > "$dir/state/.hash-fleet_shared"
  printf '%s\n' 1 > "$dir/state/.count-fleet_shared"
  set +e
  FM_TEST_EXISTING_TARGETS='fleet:shared' FM_TEST_LIVE_TARGETS='fleet:shared' \
    FM_TEST_CAPTURE='retained endpoint' FM_TEST_CAPTURE_LOG="$dir/captures" \
    FM_CREW_STATE_BIN="$dir/stopped-crew-state.sh" \
    FM_TEST_BOUNDED_WATCH_TIMEOUT=6 run_bounded_watcher_cycle "$dir" "$dir/fakebin" \
    > "$dir/out" 2> "$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail 'blocked active owner was suppressed by a sibling policy'
  grep -F "$(printf '\tstale\tfleet:shared\tstale: fleet:shared')" "$dir/state/.wake-queue" >/dev/null \
    || fail 'mixed active-owner policy did not surface the blocked owner'
  captures=$(wc -l < "$dir/captures" | tr -d ' ')
  [ "$captures" -eq 1 ] || fail "mixed owners caused $captures endpoint captures"
  pass 'active owner policies fold over one endpoint observation'
}

test_shared_endpoint_fanout_consumes_cycle_lease() {
  local dir task
  dir=$(fixture shared-endpoint-fanout-budget)
  install_endpoint_inventory_tmux "$dir"
  for task in $(seq 1 20); do
    printf '%s\n' 'window=fleet:shared' 'kind=ship' 'harness=claude' 'backend=tmux' \
      > "$dir/state/owner-$task.meta"
    FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$1/fm-task-inbox-lib.sh"
      fm_task_inbox_write "$FM_STATE_OVERRIDE" "$2" "due instruction" >/dev/null
    ' _ "$ROOT/bin" "owner-$task" || fail "could not create owner-$task inbox"
  done
  FM_TEST_EXISTING_TARGETS='fleet:shared' FM_TEST_LIVE_TARGETS='fleet:shared' \
    FM_TASK_INBOX_GRACE_SECS=0 FM_SEND_REMOTE_BUDGET=20 FM_CODEX_STOP_TEST_TRANSPORT_TIMEOUT=80 \
    run_stop "$dir" 4
  wait_file "$dir/rc" 120
  [ "$(cat "$dir/rc")" = 2 ] || fail 'shared endpoint fan-out escaped Stop refusal'
  assert_contains "$(cat "$dir/out")" 'watcher cycle exceeds Codex Stop deadline' \
    'per-owner backend submits were omitted from the atomic cycle lease'
  assert_no_watcher "$dir"
  finish "$dir"
  pass 'shared endpoint fan-out is fully charged to the cycle lease'
}

if [ -n "${FM_CODEX_STOP_FOCUSED_CASES:-}" ]; then
  for focused_case in $FM_CODEX_STOP_FOCUSED_CASES; do
    case "$focused_case" in
      test_*) declare -F "$focused_case" >/dev/null || fail "unknown focused case: $focused_case" ;;
      *) fail "invalid focused case: $focused_case" ;;
    esac
    "$focused_case"
  done
  exit 0
fi

test_initial_fork_failure_blocks_stop
test_python_bootstrap_failure_fails_closed
test_python_launch_failure_fails_closed
test_public_stop_dispatches_pending_queue
test_quiet_renewal
test_wedged_arm_cannot_report_quiet_renewal
test_late_watcher_gets_full_quiet_window
test_admission_time_preserves_arm_confirmation
test_recurring_probe_honors_transport_deadline
test_idle_probe_wins_at_terminal_reserve
test_registry_turnover_refreshes_budget_refusal
test_identity_and_cleanup_phases_preserve_transport_reserve
test_registry_retirement_preserves_conclusive_generation_change
test_persistent_identity_timeout_fails_closed
test_terminal_error_generation_tristate
test_current_generation_failure_episode_is_bounded
test_stalled_watcher_cannot_complete_quiet_window
test_late_stopped_watcher_cannot_complete_quiet_window
test_complete_watcher_cycle_can_deliver_actionable_wake
test_attached_arm_uses_complete_cycle_grace
test_attached_arm_rejects_unproven_bounded_mode
test_attached_arm_rejects_mismatched_bounded_runtime
test_sequential_checks_fit_complete_cycle_bound
test_sequential_task_classification_fits_complete_cycle_bound
test_retired_status_history_does_not_consume_cycle_budget
test_fresh_checks_do_not_consume_cycle_budget
test_large_stale_endpoint_inventory_does_not_consume_cycle_budget
test_no_snapshot_bootstrap_discovers_live_ordinary_owners
test_no_snapshot_bootstrap_refuses_uncertain_backend_inventories
test_herdr_bulk_snapshot_bootstrap_is_conservative
test_no_snapshot_bootstrap_covers_legacy_backend_layouts
test_herdr_bootstrap_uses_bounded_bulk_inventory
test_bootstrap_inventory_uses_configured_backend_sessions
test_bounded_bootstrap_rebinds_unique_live_targets
test_zellij_scoped_title_alias_bootstrap_is_conservative
test_bounded_event_wait_uses_active_registry
test_production_shaped_stale_inventory_arms_supervision
test_empty_active_snapshot_ignores_retained_metadata
test_active_indexes_discover_new_obligations
test_registered_check_index_reconciles_after_ready
test_active_supervision_registry_owns_lifecycle_inventory
test_registry_receipt_recovery_is_owner_addressed
test_registry_pending_snapshot_is_immediately_authoritative
test_registry_snapshot_index_is_generation_bound
test_incarnation_allocator_is_durable_unique_and_nonreusable
test_registry_reservation_recovers_spawn_crash_windows
test_registry_phase_transition_recovers_torn_publication
test_remote_recovery_protocol_reports_exact_endpoint
test_transaction_journals_recover_every_backend
test_planned_reservations_converge_after_backend_creation_crashes
test_planned_reservation_rejects_preexisting_endpoint
test_planned_reservation_ignores_racing_canonical_endpoint
test_planned_backend_discovery_uses_live_identity
test_registered_check_kills_term_ignoring_process_group
test_registered_check_preserves_grace_for_orphan_descendant
test_bounded_check_starts_without_observer_endpoint
test_bounded_observer_remains_live_during_check
test_bounded_observer_remains_live_after_check_boundary
test_check_grace_and_absolute_lease_are_preserved
test_active_only_pending_replies_exclude_archive
test_mixed_active_owner_policy_surfaces_once
test_shared_endpoint_fanout_consumes_cycle_lease
test_small_live_endpoint_inventory_remains_bounded
test_failed_inventory_probe_is_conservatively_budgeted
test_remote_endpoints_avoid_local_backend_probes
test_remote_inbox_stays_owned_by_remote_delivery
test_herdr_endpoints_use_one_snapshot_per_cycle
test_admission_timeout_reaps_probe_descendants
test_many_dead_endpoints_take_cheap_watcher_path
test_duplicate_endpoint_pending_replies_share_classification
test_bounded_check_batch_parks_at_safe_boundary
test_retiring_session_owner_hands_off_current_stop
test_bounded_check_resume_requires_live_owner
test_bounded_check_resume_requires_complete_cycle_budget
test_duplicate_endpoint_owners_share_stale_pass
test_paused_and_captain_held_deaths_notify_once
test_local_secondmate_death_notifies_once
test_dead_endpoint_preserves_inbox_escalation
test_missing_endpoint_preserves_inbox_escalation
test_dead_endpoint_honors_explicit_notification_receipt
test_absorbed_dead_endpoint_emits_new_death_notification
test_resumed_worker_retires_death_generation
test_relaunch_generation_surfaces_death_before_alive_observation
test_colliding_endpoint_keys_keep_independent_death_receipts
test_ambiguous_busy_resume_retires_death_receipt
test_due_custom_and_pr_checks_remain_bounded
test_actionable_checks_resume_bounded_sweep
test_check_sweep_order_is_canonical_across_locales
test_supervision_rows_preserve_backslash_bytes
test_due_remote_recovery_fits_cycle_budget
test_codex_defers_remote_pending_reply_observation
test_cycle_budget_scans_are_throttled
test_large_check_inventory_is_batched_before_transport_deadline
test_dead_arm_launcher_retires_owned_watcher_group
test_running_arm_cancellation_reaps_prelock_descendants
test_launcher_exit_before_child_publication_retires_owned_watcher
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
