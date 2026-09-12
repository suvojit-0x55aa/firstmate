#!/usr/bin/env bash
# Behavior tests for bin/fm-time-reached.sh, the condition half of the
# quota-reset watch. FM_QUOTA_NOW_OVERRIDE stands in for `date +%s` so the
# boundary can be tested deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SH="$ROOT/bin/fm-time-reached.sh"

FM_QUOTA_NOW_OVERRIDE=100 "$SH" 100
expect_code 0 $? "now == epoch fires"
pass "exit 0 exactly at the target epoch"

FM_QUOTA_NOW_OVERRIDE=101 "$SH" 100
expect_code 0 $? "now > epoch fires"
pass "exit 0 after the target epoch"

FM_QUOTA_NOW_OVERRIDE=99 "$SH" 100
expect_code 1 $? "now < epoch does not fire"
pass "exit 1 before the target epoch"

out=$("$SH" abc 2>&1)
expect_code 2 $? "non-numeric epoch"
assert_contains "$out" "error:" "non-numeric epoch reports a loud error"
pass "a non-numeric epoch is refused, not silently treated as unreached"

out=$("$SH" -5 2>&1)
expect_code 2 $? "negative epoch"
assert_contains "$out" "error:" "negative epoch reports a loud error"
pass "a negative epoch is refused"

out=$("$SH" 2>&1)
expect_code 2 $? "missing epoch"
assert_contains "$out" "error:" "missing epoch reports a loud error"
pass "a missing epoch argument is refused"

printf 'all fm-time-reached tests passed\n'
