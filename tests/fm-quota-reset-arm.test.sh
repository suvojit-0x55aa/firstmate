#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-reset-arm.sh.
#
# Every scenario runs against the real bin/fm-procevent.sh and
# bin/fm-procevent-when.sh in an isolated FM_HOME, with quota-axi mocked
# through FM_QUOTA_AXI_CMD. The suite proves: a fresh arm registers a watch
# targeting the resolved reset epoch plus buffer, a second arm on a still-
# live watch is a no-op, and a watch left fired-with-an-unhandled-result from
# a prior cycle is healed (marked handled, retired) and re-armed rather than
# refused forever or silently reported as armed with nothing actually done.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-quota-reset-arm-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
ARM_SH="$ROOT/bin/fm-quota-reset-arm.sh"

ARM_HOMES=()
arm_teardown() {
  local home
  for home in ${ARM_HOMES[@]+"${ARM_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap arm_teardown EXIT

new_home() { mkdir -p "$1/state"; ARM_HOMES+=("$1"); }

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
when() { FM_HOME="$1" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }
arm() { FM_HOME="$1" FM_QUOTA_AXI_CMD="$QUOTA_AXI" "$ARM_SH" "${@:2}"; }

QUOTA_AXI="$TMP_ROOT/fake-quota-axi.sh"
cat > "$QUOTA_AXI" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'quota-axi 0.1.32\n'
  exit 0
fi
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour"]}]}}]}
JSON
SH
chmod +x "$QUOTA_AXI"
EXPECTED_EPOCH=$(date -u -d '2026-09-12T09:20:00+00:00' +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' '2026-09-12T09:20:00+0000' +%s)

# --- a fresh arm registers a watch targeting epoch + buffer ------------------
H="$TMP_ROOT/h-fresh"; new_home "$H"
out=$(arm "$H" task-alpha --buffer-secs 90)
expect_code 0 $? "fresh arm exit code"
assert_contains "$out" "armed: when-quota-reset-task-alpha" "fresh arm reports the canonical source id"
assert_present "$H/state/when/when-quota-reset-task-alpha.spec" "arm writes the spec"
target=$((EXPECTED_EPOCH + 90))
assert_grep "$target" "$H/state/when/when-quota-reset-task-alpha.spec" "the spec's condition targets epoch + buffer"
pass "a fresh arm registers a watch targeting the resolved epoch plus buffer"

# --- a second arm on the still-live watch is a no-op -------------------------
out=$(arm "$H" task-alpha --buffer-secs 90)
expect_code 0 $? "idempotent re-arm exit code"
assert_contains "$out" "already armed" "idempotent re-arm reports nothing to do"
pass "arming an already-armed, not-yet-fired watch is a no-op"

# --- quota-axi failure refuses to arm, loudly --------------------------------
H2="$TMP_ROOT/h-bad-quota"; new_home "$H2"
BAD_AXI="$TMP_ROOT/bad-quota-axi.sh"
cat > "$BAD_AXI" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'quota-axi 0.1.32\n'; exit 0; fi
echo "boom" >&2
exit 3
SH
chmod +x "$BAD_AXI"
out=$(FM_HOME="$H2" FM_QUOTA_AXI_CMD="$BAD_AXI" "$ARM_SH" task-beta 2>&1)
code=$?
expect_code 1 "$code" "quota-axi failure: exit code"
assert_contains "$out" "error:" "quota-axi failure refuses to arm"
assert_absent "$H2/state/when/when-quota-reset-task-beta.spec" "nothing was armed when quota-axi failed"
pass "a quota-axi failure refuses to arm instead of guessing a target"

# --- task-id validation -------------------------------------------------------
H3="$TMP_ROOT/h-badid"; new_home "$H3"
out=$(arm "$H3" "bad id" 2>&1)
code=$?
expect_code 1 "$code" "path-unsafe task-id: exit code"
assert_contains "$out" "error:" "path-unsafe task-id is refused"
pass "a path-unsafe task-id is refused"

# --- self-heal: a fired-but-unhandled watch is healed and re-armed ----------
H4="$TMP_ROOT/h-heal"; new_home "$H4"
NAME="quota-reset-task-gamma"
SID="when-$NAME"
when "$H4" arm "$NAME" --interval 1 --stable 1 --condition true --action true >/dev/null
pe "$H4" start "$SID" >/dev/null 2>&1
# The source is auto-retired on a terminal outcome, but its captured result
# is left unhandled - exactly the leftover state a second stuck-quota cycle
# for the same task would otherwise hit as a permanent refusal.
result=$(printf '%s\n' "$H4/state/procevent-inbox/$SID".*.result)
assert_present "$result" "the fired watch left a captured, unhandled result"
assert_absent "${result%.result}.handled" "the captured result starts out unhandled"

out=$(arm "$H4" task-gamma --buffer-secs 30)
code=$?
expect_code 0 "$code" "self-heal re-arm exit code: $out"
assert_contains "$out" "armed: $SID" "the watch is re-armed after self-healing"
assert_present "${result%.result}.handled" "self-heal marks the earlier captured result handled"
assert_present "$H4/state/when/$SID.spec" "self-heal leaves a fresh spec behind"
pass "a fired-but-unhandled watch is healed (marked handled) and re-armed, not refused forever"

# --- the healed re-arm is itself idempotent ----------------------------------
out=$(arm "$H4" task-gamma --buffer-secs 30)
expect_code 0 $? "post-heal idempotent re-arm exit code"
assert_contains "$out" "already armed" "post-heal re-arm reports nothing to do"
pass "the freshly self-healed watch is idempotent on the very next arm"

printf 'all fm-quota-reset-arm tests passed\n'
