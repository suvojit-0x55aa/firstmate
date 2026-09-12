#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-reset-arm.sh.
#
# Every scenario runs against the real bin/fm-procevent.sh and
# bin/fm-procevent-when.sh in an isolated FM_HOME, with quota-axi mocked
# through FM_QUOTA_AXI_CMD. The suite proves: a fresh arm registers a watch
# targeting the resolved reset epoch plus buffer, a second arm on a still-
# live watch is a no-op, a sibling task id's pending result neither blocks nor
# is consumed by this arm, a task-id the watch name cannot carry is refused
# before any quota-axi query, a self-heal that cannot clear its leftover says
# why, a watch that already fired is re-armed rather than
# reported as still armed, a help invocation arms nothing at all, the watch's
# give-up deadline always outlasts its own target, and a watch left fired-
# with-an-unhandled-result from a prior cycle is healed (marked handled,
# retired) and re-armed rather than refused forever or silently reported as
# armed with nothing actually done.
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
# The spec is fm-procevent-when.sh's own persisted watch record: header fields,
# then an `argv:` line followed by condition_argc condition elements and the
# action elements. Read the condition argv back as a vector rather than
# grepping the file, so the target has to be the condition's argument and not
# merely a number appearing somewhere in the record.
spec="$H/state/when/when-quota-reset-task-alpha.spec"
spec_field() { sed -n "s/^$1=//p" "$2"; }
condition_argv() {
  local file=$1 argc
  argc=$(spec_field condition_argc "$file")
  sed -n '/^argv:$/,$p' "$file" | sed -n "2,$((argc + 1))p"
}
cond=()
while IFS= read -r arg; do cond+=("$arg"); done < <(condition_argv "$spec")
[ "${#cond[@]}" -eq 2 ] || fail "condition argv has ${#cond[@]} elements, want 2: ${cond[*]-}"
[ "$(basename "${cond[0]}")" = fm-time-reached.sh ] ||
  fail "condition is ${cond[0]}, want fm-time-reached.sh"
[ "${cond[1]}" = "$target" ] ||
  fail "condition target is ${cond[1]}, want $target (resolved epoch + 90s buffer)"
pass "a fresh arm registers a watch whose condition is fm-time-reached.sh at epoch plus buffer"

# --- a far-future reset cannot expire the watch before its own target --------
# fm-procevent-when.sh counts the deadline from `armed` and defaults it to one
# week, so a weekly window resetting further out than that would otherwise
# publish `never-true` and retire before the real reset ever arrived. The spec
# is that script's own persisted watch record: read `armed` and `deadline` back
# and require their sum to land after the target.
H6="$TMP_ROOT/h-far"; new_home "$H6"
FAR_EPOCH=$(( $(date +%s) + 2592000 ))
FAR_ISO=$(date -u -d "@$FAR_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$FAR_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
FAR_AXI="$TMP_ROOT/far-quota-axi.sh"
cat > "$FAR_AXI" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'quota-axi 0.1.32\n'
  exit 0
fi
printf '%s\n' '{"providers":[{"provider":"claude","windows":[{"id":"seven_day","resetsAt":"$FAR_ISO"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["seven_day"]}]}}]}'
SH
chmod +x "$FAR_AXI"
out=$(FM_HOME="$H6" FM_QUOTA_AXI_CMD="$FAR_AXI" "$ARM_SH" task-far --buffer-secs 60)
expect_code 0 $? "far-future arm exit code: $out"
far_spec="$H6/state/when/when-quota-reset-task-far.spec"
far_target=$((FAR_EPOCH + 60))
armed_at=$(spec_field armed "$far_spec")
deadline=$(spec_field deadline "$far_spec")
[ -n "$armed_at" ] && [ -n "$deadline" ] || fail "the spec records no armed/deadline pair"
[ $((armed_at + deadline)) -gt "$far_target" ] ||
  fail "the watch gives up at $((armed_at + deadline)), before its own target $far_target"
pass "the give-up deadline is derived from the target, so a far-future reset is still detected"

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

# --- a help invocation arms nothing ------------------------------------------
H5="$TMP_ROOT/h-help"; new_home "$H5"
for flag in -h --help; do
  out=$(FM_HOME="$H5" FM_QUOTA_AXI_CMD="$QUOTA_AXI" "$ARM_SH" "$flag" 2>&1)
  expect_code 0 $? "$flag: exit code"
  assert_contains "$out" "Usage: fm-quota-reset-arm.sh" "$flag: prints the usage header"
  assert_absent "$H5/state/when" "$flag: no watch state was written"
  [ -z "$(FM_HOME="$H5" "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | grep quota-reset || true)" ] ||
    fail "$flag: registered a quota-reset watch source"
done
pass "a help invocation prints usage and arms nothing"

# --- task-id validation -------------------------------------------------------
H3="$TMP_ROOT/h-badid"; new_home "$H3"
out=$(arm "$H3" "bad id" 2>&1)
code=$?
expect_code 1 "$code" "path-unsafe task-id: exit code"
assert_contains "$out" "error:" "path-unsafe task-id is refused"
pass "a path-unsafe task-id is refused"

# --- refusals that must cost no quota-axi query -------------------------------
# Both shapes are refused by the task-id itself, so neither should reach the
# provider. The recorder proves that by leaving no file behind.
H8="$TMP_ROOT/h-reject"; new_home "$H8"
AXI_CALLS="$TMP_ROOT/axi-calls"
RECORDING_AXI="$TMP_ROOT/recording-quota-axi.sh"
cat > "$RECORDING_AXI" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'quota-axi 0.1.32\n'
  exit 0
fi
printf '%s\n' "\$*" >> "$AXI_CALLS"
printf '%s\n' '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour"]}]}}]}'
SH
chmod +x "$RECORDING_AXI"

out=$(FM_HOME="$H8" FM_QUOTA_AXI_CMD="$RECORDING_AXI" "$ARM_SH" .. 2>&1)
code=$?
expect_code 1 "$code" "leading-dot task-id: exit code"
assert_contains "$out" "error:" "leading-dot task-id is refused"
assert_absent "$H8/state/when/when-quota-reset-...spec" "no watch was armed for a leading-dot task-id"

LONG_ID=$(printf 'a%.0s' $(seq 48))
out=$(FM_HOME="$H8" FM_QUOTA_AXI_CMD="$RECORDING_AXI" "$ARM_SH" "$LONG_ID" 2>&1)
code=$?
expect_code 1 "$code" "over-long task-id: exit code"
assert_contains "$out" "task-id" "the refusal names the task-id, not a derived watch name"
assert_not_contains "$out" "quota-reset-$LONG_ID" "the refusal does not blame a name the caller never typed"
assert_absent "$H8/state/when/when-quota-reset-$LONG_ID.spec" "no watch was armed for an over-long task-id"
assert_absent "$AXI_CALLS" "neither refusal paid a quota-axi query"
pass "task-ids the watch name cannot carry are refused by their own name, before any quota-axi query"

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

# --- a registered watch that already fired is re-armed, not reported armed ---
# fm-procevent-when.sh's runner answers `ambiguous` without polling once the
# fired marker exists, so this state is a spent watch, not a live one. It is
# reachable whenever the post-fire retire cannot re-prove ownership: the
# registration survives, firstmate acknowledges the result, and the next stuck
# cycle arms again. Built here out of public commands only.
H7="$TMP_ROOT/h-spent"; new_home "$H7"
SPENT_NAME="quota-reset-task-delta"
SPENT_SID="when-$SPENT_NAME"
when "$H7" arm "$SPENT_NAME" --interval 1 --stable 1 --condition true --action true >/dev/null
pe "$H7" start "$SPENT_SID" >/dev/null 2>&1
spent_result=$(printf '%s\n' "$H7/state/procevent-inbox/$SPENT_SID".*.result)
assert_present "$H7/state/when/$SPENT_SID.fired" "the fire left its durable marker behind"
spent_seq=${spent_result##*/}
spent_seq=${spent_seq%.result}
spent_seq=${spent_seq##*.}
pe "$H7" handled "$SPENT_SID" "$spent_seq" >/dev/null
pe "$H7" register when "$SPENT_SID" -- "$ROOT/bin/fm-procevent-when.sh" run "$SPENT_SID" >/dev/null

out=$(arm "$H7" task-delta --buffer-secs 30)
code=$?
expect_code 0 "$code" "spent-watch re-arm exit code: $out"
assert_not_contains "$out" "already armed" "a fired watch is not reported as still armed"
assert_contains "$out" "armed: $SPENT_SID" "the spent watch is armed fresh"
assert_absent "$H7/state/when/$SPENT_SID.fired" "the stale fired marker is cleared by the re-arm"
pass "a watch that already fired is re-armed instead of silently reported as still armed"

# --- a self-heal that cannot clear the leftover names its own cause ----------
# fm-procevent-when.sh's retire refuses, leaving the spec/trust/fired triple in
# place, whenever the source's ownership claim cannot be read. Without the heal
# output the operator only sees "retire it first" - the very step that just
# failed - so the refusal has to carry the reason retiring was impossible.
H9="$TMP_ROOT/h-heal-fails"; new_home "$H9"
STUCK_NAME="quota-reset-task-epsilon"
STUCK_SID="when-$STUCK_NAME"
when "$H9" arm "$STUCK_NAME" --interval 1 --stable 1 --condition true --action true >/dev/null
pe "$H9" start "$STUCK_SID" >/dev/null 2>&1
assert_present "$H9/state/when/$STUCK_SID.fired" "the fire left its durable marker behind"
stuck_result=$(printf '%s\n' "$H9/state/procevent-inbox/$STUCK_SID".*.result)
assert_present "$stuck_result" "the fire left a captured, unhandled result"
printf 'not-a-valid-claim\n' > "$FM_PROCEVENT_CLAIM_ROOT/$STUCK_SID.claim"

out=$(arm "$H9" task-epsilon 2>&1)
code=$?
expect_code 1 "$code" "unhealable leftover: exit code"
assert_contains "$out" "cannot arm quota-reset watch for task-epsilon" "the refusal still names the task"
assert_contains "$out" "cannot safely read source ownership" "the refusal carries the reason the self-heal failed"
pass "a self-heal that cannot clear the leftover reports its own cause, not just 'retire it first'"

# Acknowledging the captured result is irreversible - a handled marker stops
# fm-procevent's pending list and its re-announcement forever - so a heal that
# could not clear the leftover must not spend it for nothing.
assert_absent "${stuck_result%.result}.handled" "an unread outcome keeps its re-announcement when the heal failed"
assert_present "$stuck_result" "the captured result itself is untouched"
pass "a failed self-heal leaves the prior fire's captured result still pending"

# --- a sibling task's pending result does not block this task ----------------
# Task ids may contain dots, so `a.b` derives a source id that extends `a`'s
# after a dot. Result ownership therefore has to split on the last dot, not
# prefix-match: an unhandled result belonging to `a.b` is none of `a`'s
# business and must not refuse `a`'s arm.
H10="$TMP_ROOT/h-sibling"; new_home "$H10"
SIB_NAME="quota-reset-a.b"
SIB_SID="when-$SIB_NAME"
when "$H10" arm "$SIB_NAME" --interval 1 --stable 1 --condition true --action true >/dev/null
pe "$H10" start "$SIB_SID" >/dev/null 2>&1
sib_result=$(printf '%s\n' "$H10/state/procevent-inbox/$SIB_SID".*.result)
assert_present "$sib_result" "the sibling task left a captured, unhandled result"
assert_absent "${sib_result%.result}.handled" "the sibling's result starts out unhandled"

out=$(arm "$H10" a --buffer-secs 30 2>&1)
code=$?
expect_code 0 "$code" "sibling-result arm exit code: $out"
assert_contains "$out" "armed: when-quota-reset-a" "task a is armed despite task a.b's pending result"
assert_absent "${sib_result%.result}.handled" "task a's arm never acknowledged the sibling's result"
pass "an unhandled result belonging to a sibling task id neither blocks nor is consumed by this arm"

# --- the healed re-arm is itself idempotent ----------------------------------
out=$(arm "$H4" task-gamma --buffer-secs 30)
expect_code 0 $? "post-heal idempotent re-arm exit code"
assert_contains "$out" "already armed" "post-heal re-arm reports nothing to do"
pass "the freshly self-healed watch is idempotent on the very next arm"

printf 'all fm-quota-reset-arm tests passed\n'
