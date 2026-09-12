#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-reset-epoch.sh.
#
# quota-axi is mocked through FM_QUOTA_AXI_CMD, an injectable override
# (same pattern as FM_QUOTA_PEEK_OVERRIDE elsewhere) that names a fake
# executable to run instead of the real `quota-axi`. Every scenario is
# exercised through the script's public stdout/exit contract; nothing here
# asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-quota-reset-epoch-tests)
EPOCH_SH="$ROOT/bin/fm-quota-reset-epoch.sh"

# fake_quota_axi <name> <version-line> <body-script>: writes an executable
# fake quota-axi to $TMP_ROOT/<name> that answers --version with
# <version-line> and otherwise runs <body-script> (a heredoc body).
fake_quota_axi() {
  local path="$TMP_ROOT/$1" version=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "$version"
  exit 0
fi
SH
  cat >> "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# --- happy path: single limiting window resolves to its resetsAt -----------
CMD=$(fake_quota_axi good-single "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00.141747+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour"]}]}}]}
JSON
SH
)
epoch=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" --provider claude)
expect_code 0 $? "single limiting window: exit code"
expected=$(date -u -d '2026-09-12T09:20:00+00:00' +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' '2026-09-12T09:20:00+0000' +%s)
[ "$epoch" = "$expected" ] || fail "single limiting window: expected $expected, got $epoch"
pass "resolves the single all_models limiting window's resetsAt"

# --- multiple limiting windows: earliest resetsAt wins ----------------------
CMD=$(fake_quota_axi good-multi "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+00:00"},{"id":"seven_day","resetsAt":"2026-09-17T18:00:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["seven_day","five_hour"]}]}}]}
JSON
SH
)
epoch=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" --provider claude)
expect_code 0 $? "multiple limiting windows: exit code"
[ "$epoch" = "$expected" ] || fail "multiple limiting windows: earliest window did not win (got $epoch, want $expected)"
pass "picks the earliest resetsAt when more than one window is limiting"

# --- mixed UTC offsets: the earliest true instant wins, not the earliest
# --- string. 09:20+05:30 is 03:50Z, so it precedes 09:00Z even though it
# --- sorts after it lexicographically.
CMD=$(fake_quota_axi good-mixed-offsets "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+05:30"},{"id":"seven_day","resetsAt":"2026-09-12T09:00:00Z"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour","seven_day"]}]}}]}
JSON
SH
)
epoch=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" --provider claude)
expect_code 0 $? "mixed UTC offsets: exit code"
mixed_expected=$(date -u -d '2026-09-12T03:50:00+00:00' +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' '2026-09-12T03:50:00+0000' +%s)
[ "$epoch" = "$mixed_expected" ] || fail "mixed UTC offsets: expected $mixed_expected, got $epoch"
pass "compares limiting windows chronologically when their UTC offsets differ"

# --- default provider is claude ---------------------------------------------
CMD=$(fake_quota_axi good-default "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+00:00"},{"id":"seven_day","resetsAt":"2026-09-17T18:00:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["seven_day","five_hour"]}]}}]}
JSON
SH
)
epoch=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH")
[ "$epoch" = "$expected" ] || fail "default provider did not resolve claude's window"
pass "defaults to provider claude when --provider is omitted"

# --- missing quota-axi command -----------------------------------------------
out=$(FM_QUOTA_AXI_CMD="$TMP_ROOT/does-not-exist" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "missing command: exit code"
assert_contains "$out" "error:" "missing command: reports a loud error"
pass "a missing quota-axi command fails loudly"

# --- incompatible version ----------------------------------------------------
CMD=$(fake_quota_axi old-version "quota-axi 0.0.1" <<'SH'
echo "should never be reached"
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "incompatible version: exit code"
assert_contains "$out" "error:" "incompatible version: reports a loud error"
pass "an incompatible quota-axi version fails loudly instead of querying"

# --- timeout ------------------------------------------------------------------
CMD=$(fake_quota_axi hang "quota-axi 0.1.32" <<'SH'
sleep 30
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" FM_QUOTA_AXI_TIMEOUT_SECS=1 "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "timeout: exit code"
assert_contains "$out" "error:" "timeout: reports a loud error"
pass "a hanging quota-axi query is bounded by the timeout and fails loudly"

# --- nonzero exit from the JSON query ----------------------------------------
CMD=$(fake_quota_axi bad-exit "quota-axi 0.1.32" <<'SH'
echo "boom" >&2
exit 3
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "nonzero query exit: exit code"
assert_contains "$out" "error:" "nonzero query exit: reports a loud error"
pass "a nonzero quota-axi exit fails loudly rather than guessing at partial output"

# --- malformed JSON -----------------------------------------------------------
CMD=$(fake_quota_axi bad-json "quota-axi 0.1.32" <<'SH'
echo "not json"
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "malformed JSON: exit code"
assert_contains "$out" "error:" "malformed JSON: reports a loud error"
pass "malformed JSON output fails loudly"

# --- valid JSON with no all_models limiting window ---------------------------
CMD=$(fake_quota_axi no-all-models "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"2026-09-12T09:20:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"model","limitingWindowIds":["five_hour"]}]}}]}
JSON
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "no all_models scope: exit code"
assert_contains "$out" "error:" "no all_models scope: reports a loud error"
pass "a response with no all_models limiting window fails loudly instead of guessing"

# --- a limiting window with no windows[] entry ---------------------------------
# The unresolvable id must not be dropped in favour of whatever else resolved:
# five_hour is the window that actually binds availability here, and answering
# with seven_day's later epoch would spend the single wake days late.
CMD=$(fake_quota_axi missing-window "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"seven_day","resetsAt":"2026-09-17T18:00:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour","seven_day"]}]}}]}
JSON
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "unresolvable limiting window: exit code"
assert_contains "$out" "error:" "unresolvable limiting window: reports a loud error"
assert_contains "$out" "five_hour" "the error names the window that could not be resolved"
pass "a limiting window absent from windows[] fails loudly instead of answering with a later epoch"

# --- a limiting window whose resetsAt is null ---------------------------------
CMD=$(fake_quota_axi null-resets-at "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":null},{"id":"seven_day","resetsAt":"2026-09-17T18:00:00+00:00"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour","seven_day"]}]}}]}
JSON
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "null resetsAt: exit code"
assert_contains "$out" "error:" "null resetsAt: reports a loud error"
pass "a limiting window with a null resetsAt fails loudly instead of answering with a later epoch"

# --- unparseable resetsAt ------------------------------------------------------
CMD=$(fake_quota_axi bad-timestamp "quota-axi 0.1.32" <<'SH'
cat <<'JSON'
{"providers":[{"provider":"claude","windows":[{"id":"five_hour","resetsAt":"not-a-timestamp"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","limitingWindowIds":["five_hour"]}]}}]}
JSON
SH
)
out=$(FM_QUOTA_AXI_CMD="$CMD" "$EPOCH_SH" 2>&1)
code=$?
expect_code 1 "$code" "unparseable resetsAt: exit code"
assert_contains "$out" "error:" "unparseable resetsAt: reports a loud error"
pass "an unparseable resetsAt fails loudly instead of printing a wrong epoch"

printf 'all fm-quota-reset-epoch tests passed\n'
