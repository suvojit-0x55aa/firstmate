#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-reset-notify.sh.
#
# The load-bearing guarantee this suite proves: the script never drives task
# lifecycle. The script under test runs from a sandbox bin/ that holds
# recording fakes for fm-control.sh, fm-crew-state.sh, and fm-peek.sh, and
# those fakes also shadow the real commands on PATH. Both invocation idioms
# this repo uses - a bare name resolved through PATH and the "$SCRIPT_DIR/fm-*"
# absolute path every sibling script prefers - therefore land on a fake that
# records the call, so any real call would be caught rather than only a
# printed mention.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-quota-reset-notify-tests)

CONTROL_CALLS="$TMP_ROOT/fm-control-calls"
CREW_STATE_CALLS="$TMP_ROOT/fm-crew-state-calls"

SANDBOX_BIN="$TMP_ROOT/sandbox/bin"
mkdir -p "$SANDBOX_BIN"
cp "$ROOT/bin/fm-quota-reset-notify.sh" "$SANDBOX_BIN/fm-quota-reset-notify.sh"
chmod +x "$SANDBOX_BIN/fm-quota-reset-notify.sh"
NOTIFY_SH="$SANDBOX_BIN/fm-quota-reset-notify.sh"

# recorder <path> <log>: an executable that appends its argv to <log>.
recorder() {
  cat > "$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exit 0
SH
  chmod +x "$1"
}

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
for name in fm-control.sh fm-crew-state.sh; do
  case "$name" in
    fm-control.sh) log=$CONTROL_CALLS ;;
    *) log=$CREW_STATE_CALLS ;;
  esac
  recorder "$FAKEBIN/$name" "$log"
  recorder "$SANDBOX_BIN/$name" "$log"
done

cat > "$SANDBOX_BIN/fm-peek.sh" <<'SH'
#!/usr/bin/env bash
printf 'peeked %s lines=%s\n' "$1" "$2"
SH
chmod +x "$SANDBOX_BIN/fm-peek.sh"

# --- normal firing: peeks read-only, names manual next steps, invokes nothing
# No peek override here, so the script resolves its peek the way it does in
# production - through SCRIPT_DIR, which is the sandbox.
out=$(PATH="$FAKEBIN:$PATH" "$NOTIFY_SH" task-42 30)
expect_code 0 $? "notify exit code"
assert_contains "$out" "peeked task-42 lines=30" "notify re-peeks the task read-only"
assert_contains "$out" "bin/fm-crew-state.sh task-42" "notify names the state-check command"
assert_contains "$out" "bin/fm-control.sh task-42 relaunch" "notify names the manual relaunch command"
assert_absent "$CONTROL_CALLS" "fm-control.sh was never actually invoked"
assert_absent "$CREW_STATE_CALLS" "fm-crew-state.sh was never actually invoked"
pass "notify reports and names next steps without driving lifecycle"

# --- a failed peek (e.g. the endpoint is gone) still names no lifecycle call -
FAILING_PEEK="$TMP_ROOT/failing-peek.sh"
cat > "$FAILING_PEEK" <<'SH'
#!/usr/bin/env bash
echo "peek failed" >&2
exit 1
SH
chmod +x "$FAILING_PEEK"
out=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_PEEK_OVERRIDE="$FAILING_PEEK" "$NOTIFY_SH" task-99 30)
expect_code 0 $? "notify still exits 0 when the peek itself fails"
assert_contains "$out" "bin/fm-crew-state.sh task-99" "notify still points at how to check state"
assert_absent "$CONTROL_CALLS" "fm-control.sh was never invoked even on a failed peek"
assert_absent "$CREW_STATE_CALLS" "fm-crew-state.sh was never invoked even on a failed peek"
pass "a failed peek is reported without ever driving lifecycle"

# --- the sandbox itself records a SCRIPT_DIR-style lifecycle call -----------
# Proves the guard above is load-bearing rather than vacuous: a script sitting
# where the one under test sits, calling fm-control.sh the way every sibling
# script calls its helpers, does leave a record in $CONTROL_CALLS.
PROBE="$SANDBOX_BIN/lifecycle-probe.sh"
cat > "$PROBE" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/fm-control.sh" "$1" relaunch
SH
chmod +x "$PROBE"
"$PROBE" task-probe >/dev/null
assert_present "$CONTROL_CALLS" "a SCRIPT_DIR-style lifecycle call is recorded by the sandbox fake"
assert_grep "task-probe relaunch" "$CONTROL_CALLS" "the recorded call carries the argv it was made with"
pass "the no-lifecycle guard catches the absolute-path idiom, not just PATH lookups"

# --- usage ---------------------------------------------------------------
out=$("$NOTIFY_SH" 2>&1)
expect_code 1 $? "missing task-id"
assert_contains "$out" "error:" "missing task-id reports a loud error"
pass "a missing task-id is refused"

printf 'all fm-quota-reset-notify tests passed\n'
