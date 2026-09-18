#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, a
# handling successor that keeps supervising instead of going blind, and the
# acked:* re-arm cooldown that keeps a merely non-empty wake queue from
# forcing a fresh downtime announcement on every single poll, and the
# same-session turn boundary that must not re-open an announced episode.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

# arm_check_action <state> <marker> <cooldown-secs>: run the production
# fm_recovery_marker_arm_check against <marker> with the acked:* cooldown
# pinned to <cooldown-secs> (so the test does not wait out the real 3600s
# default), and print the resulting FM_RECOVERY_MARKER_ACTION.
arm_check_action() {
  local state=$1 marker=$2 secs=$3 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" FM_RECOVERY_MARKER_ACKED_RESURFACE_SECS="$secs" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_recovery_marker_arm_check "$2" || exit 1
    printf "%s\n" "$FM_RECOVERY_MARKER_ACTION"
  ' _ "$lib" "$marker"
}

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop immediately and surface a
# real crew event instead of sitting in a pre-loop wait that refreshes the
# liveness beacon and then exits with a synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 5 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within a poll interval or two (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# T3: an acked marker with a non-empty wake queue must re-arm at most once per
# cooldown window, not on every poll. A single well-behaved, correctly-
# throttled queue entry (a routine stale: recheck) must not force a fresh
# downtime announcement every cycle just because the queue is non-empty.
test_acked_rearm_is_throttled_by_cooldown() {
  local dir state marker action
  dir=$(make_case acked-rearm-cooldown)
  state="$dir/state"
  marker="$state/.watcher-down"
  printf 'acked:downtime:seed.1.aaa\n' > "$marker"
  chmod 600 "$marker"
  printf '%s\t1\tstale\tseed\tstale: seed (idle 999s)\n' "$(date +%s)" > "$state/.wake-queue"

  action=$(arm_check_action "$state" "$marker" 2) \
    || fail "first acked check with a non-empty queue failed: $action"
  [ "$action" = recover ] \
    || fail "first acked check with a non-empty queue must re-arm, got: $action"
  grep -Eq '^announced:downtime:' "$marker" \
    || fail "first re-arm did not move the marker to announced: $(cat "$marker")"

  # Drive the marker back to acked, the way _fm_recovery_marker_ack would,
  # without advancing the wall clock - isolates the cooldown from generation
  # bookkeeping, which T1 already pins separately.
  printf 'acked:downtime:seed.1.aaa\n' > "$marker"

  action=$(arm_check_action "$state" "$marker" 2) \
    || fail "second acked check inside the cooldown window failed: $action"
  [ "$action" = none ] \
    || fail "second acked check inside the cooldown window must not re-arm, got: $action"
  grep -qx 'acked:downtime:seed.1.aaa' "$marker" \
    || fail "a throttled check must leave the marker acked: $(cat "$marker")"

  sleep 3

  action=$(arm_check_action "$state" "$marker" 2) \
    || fail "third acked check after the cooldown expired failed: $action"
  [ "$action" = recover ] \
    || fail "third acked check after the cooldown expired must re-arm, got: $action"
  grep -Eq '^announced:downtime:' "$marker" \
    || fail "post-cooldown re-arm did not move the marker to announced: $(cat "$marker")"

  pass "acked:* re-arm is throttled by a bounded cooldown instead of firing on every poll"
}

# start_nonsuccessor_watcher <dir> <out>: start the real watcher the way the
# Claude Stop auto-arm does between turns - a plain start with no
# FM_WATCH_HANDLING_SUCCESSOR - and set WATCHER_CHILD to its pid. It sets a
# variable instead of printing so the watcher stays this shell's own child and
# `wait` really waits for it to exit.
start_nonsuccessor_watcher() {
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  WATCHER_CHILD=$!
}

# wait_for_watcher <state> <pid>: wait until <pid> holds the watcher lock or
# has already exited. Fails when neither happens within the startup budget.
wait_for_watcher() {
  local state=$1 child=$2 i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && return 0
    kill -0 "$child" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# run_turn <dir> <out>: run one non-successor watcher cycle. Once the watcher
# holds the lock, give it a few polls (the downtime resurface runs at the top
# of its first one) to deliver a wake and exit on its own; otherwise stop it.
run_turn() {
  local dir=$1 out=$2 child i=0
  start_nonsuccessor_watcher "$dir" "$out"
  child=$WATCHER_CHILD
  if ! wait_for_watcher "$dir/state" "$child"; then
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "T4 watcher never took the lock: $(cat "$out")"
  fi
  while [ "$i" -lt 30 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
}

marker_generation() {
  local line
  line=$(cat "$1" 2>/dev/null || true)
  printf '%s\n' "${line##*:}"
}

# T4: an announced-but-unacked episode must not be re-opened by the next
# ordinary turn of the SAME firstmate session. The Claude Stop auto-arm starts
# every next-turn watcher as a non-successor; before the fix each of those
# starts minted a fresh generation and re-fired check: rearm-resurface on every
# wake-handling cycle while the queue stayed non-empty. A different session
# owner (a genuinely new down stretch) must still re-open and re-announce, and
# a crashed watcher's stale lock must still re-announce within the same session.
test_same_session_turn_does_not_reopen_announced_episode() {
  local dir state marker session other gen1 gen2 gen3 gen4 out child
  dir=$(make_case same-session-reopen)
  state="$dir/state"
  marker="$state/.watcher-down"
  mkdir -p "$dir/home/data"
  # Stand-in session owners: live processes whose pids play the harness pid
  # bin/fm-lock.sh records in state/.lock. Detached from the test's stdout so
  # a failing assertion cannot leave them holding a pipe open.
  sleep 300 >/dev/null 2>&1 &
  session=$!
  sleep 300 >/dev/null 2>&1 &
  other=$!
  trap 'kill "$session" "$other" 2>/dev/null; fm_test_cleanup' EXIT
  printf '%s\n' "$session" > "$state/.lock"
  printf 'pending:downtime:seed.1.aaa\n' > "$marker"
  chmod 600 "$marker"
  append_wake "$state" check seed "check: seed decision" \
    || fail "T4 could not seed the durable queue"

  # Turn 1: first recovery presentation for this session.
  out="$dir/turn1.out"
  run_turn "$dir" "$out"
  grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 turn 1 must announce the pending episode once: $(cat "$out")"
  grep -Eq '^announced:downtime:' "$marker" \
    || fail "T4 turn 1 did not mark the episode announced: $(cat "$marker")"
  gen1=$(marker_generation "$marker")

  # The model's turn: the drain begins handling this generation, and a new
  # wake lands before its acknowledgement, so the queue stays non-empty and
  # the episode stays announced-but-unacked across the turn boundary.
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_recovery_marker_begin_handling "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$marker" \
    || fail "T4 could not begin handling the announced episode"
  append_wake "$state" check late "check: late arrival" \
    || fail "T4 could not append the late wake"
  grep -Eq '^announced:' "$marker" \
    || fail "T4 fixture did not leave the episode announced: $(cat "$marker")"

  # Turn 2: the same session re-arms. This is continuation, not downtime.
  out="$dir/turn2.out"
  run_turn "$dir" "$out"
  ! grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 turn 2 re-announced an episode this same session already saw: $(cat "$out")"
  gen2=$(marker_generation "$marker")
  [ "$gen2" = "$gen1" ] \
    || fail "T4 turn 2 minted a fresh generation for the same session ($gen1 -> $gen2)"

  # Turn 3: still the same session, still no re-announcement.
  out="$dir/turn3.out"
  run_turn "$dir" "$out"
  ! grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 turn 3 re-announced an episode this same session already saw: $(cat "$out")"
  [ "$(marker_generation "$marker")" = "$gen1" ] \
    || fail "T4 turn 3 minted a fresh generation for the same session"

  # Negative control: a watcher crash inside the same session leaves a stale
  # lock, and the next start must still re-announce.
  out="$dir/turn-crashed.out"
  start_nonsuccessor_watcher "$dir" "$out"
  child=$WATCHER_CHILD
  wait_for_watcher "$state" "$child" \
    && [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -KILL "$child" 2>/dev/null; fail "T4 crash fixture watcher never held the lock: $(cat "$out")"; }
  kill -KILL "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  out="$dir/turn-crash.out"
  run_turn "$dir" "$out"
  grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 a crashed watcher's stale lock must still re-announce: $(cat "$out")"
  gen3=$(marker_generation "$marker")

  # Negative control: a different live session owner is a new down stretch.
  printf '%s\n' "$other" > "$state/.lock"
  out="$dir/turn-new-session.out"
  run_turn "$dir" "$out"
  grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 a new session must re-announce the unacked episode: $(cat "$out")"
  gen4=$(marker_generation "$marker")
  [ "$gen4" != "$gen3" ] \
    || fail "T4 a new session must mint a fresh generation (still $gen3)"
  grep -Eq '^announced:downtime:' "$marker" \
    || fail "T4 new-session re-announce did not mark the fresh episode announced: $(cat "$marker")"

  # Negative control: a dead session owner is also a new down stretch.
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  out="$dir/turn-dead-session.out"
  run_turn "$dir" "$out"
  grep -qF 'check: rearm-resurface' "$out" \
    || fail "T4 a dead session owner must re-announce the unacked episode: $(cat "$out")"
  [ "$(marker_generation "$marker")" != "$gen4" ] \
    || fail "T4 a dead session owner must mint a fresh generation"

  kill "$session" 2>/dev/null || true
  wait "$session" 2>/dev/null || true
  trap fm_test_cleanup EXIT
  pass "an ordinary same-session turn keeps the announced episode, while a new or dead session and a crashed watcher still re-announce"
}

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
test_acked_rearm_is_throttled_by_cooldown
test_same_session_turn_does_not_reopen_announced_episode
