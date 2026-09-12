#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-reset-notify.sh.
#
# The load-bearing guarantee this suite proves: the script never drives task
# lifecycle. It shadows fm-control.sh and fm-crew-state.sh on PATH with fakes
# that record every invocation, so any real call - not just a printed
# mention - would be caught.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-quota-reset-notify-tests)
NOTIFY_SH="$ROOT/bin/fm-quota-reset-notify.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CONTROL_CALLS="$TMP_ROOT/fm-control-calls"
CREW_STATE_CALLS="$TMP_ROOT/fm-crew-state-calls"
cat > "$FAKEBIN/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CONTROL_CALLS"
exit 0
SH
cat > "$FAKEBIN/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CREW_STATE_CALLS"
exit 0
SH
chmod +x "$FAKEBIN/fm-control.sh" "$FAKEBIN/fm-crew-state.sh"

FAKE_PEEK="$TMP_ROOT/fake-peek.sh"
cat > "$FAKE_PEEK" <<'SH'
#!/usr/bin/env bash
printf 'peeked %s lines=%s\n' "$1" "$2"
SH
chmod +x "$FAKE_PEEK"

# --- normal firing: peeks read-only, names manual next steps, invokes nothing
out=$(PATH="$FAKEBIN:$PATH" FM_QUOTA_PEEK_OVERRIDE="$FAKE_PEEK" "$NOTIFY_SH" task-42 30)
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

# --- usage ---------------------------------------------------------------
out=$("$NOTIFY_SH" 2>&1)
expect_code 1 $? "missing task-id"
assert_contains "$out" "error:" "missing task-id reports a loud error"
pass "a missing task-id is refused"

printf 'all fm-quota-reset-notify tests passed\n'
