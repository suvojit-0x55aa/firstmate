#!/usr/bin/env bash
# tests/fm-lock-unusable-parent.test.sh - bounded failure for a lock whose
# owning directory disappears. This uses the real age and lock helpers because
# stubbing fm_path_age would miss masked stat failures and recursive steal paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-unusable-parent)
state="$TMP_ROOT/state"
lockdir="$state/.contend.lock"
dirname_log="$TMP_ROOT/dirname.log"
out="$TMP_ROOT/out"
err="$TMP_ROOT/err"
mkdir -p "$state"
: > "$dirname_log"

FM_TEST_DIRNAME_LOG="$dirname_log" FM_STATE_OVERRIDE="$state" bash -c '
  dirname() {
    printf "%s\n" "$*" >> "$FM_TEST_DIRNAME_LOG"
    /usr/bin/dirname "$@"
  }
  . "$1"
  if fm_lock_try_acquire "$2"; then existing=0; else existing=$?; fi
  [ "$existing" -eq 0 ] || exit 20
  fm_lock_release "$2"
  rmdir "$3" || exit 21
  age=
  age_rc=0
  age=$(fm_path_age "$2") || age_rc=$?
  if fm_lock_try_acquire "$2"; then try_rc=0; else try_rc=$?; fi
  if fm_lock_acquire_wait "$2"; then wait_rc=0; else wait_rc=$?; fi
  printf "existing=%s age_rc=%s age=%s try=%s wait=%s\n" \
    "$existing" "$age_rc" "$age" "$try_rc" "$wait_rc"
' _ "$LIB" "$lockdir" "$state" > "$out" 2> "$err" &
pid=$!

i=0
while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  fail "missing-parent acquisition did not return within three seconds"
fi
rc=0
wait "$pid" || rc=$?
[ "$rc" -eq 0 ] \
  || fail "missing-parent acquisition did not return safely (rc=$rc): $(cat "$err")"
[ "$(cat "$out")" = "existing=0 age_rc=1 age= try=2 wait=2" ] \
  || fail "missing-parent helpers did not report permanent path failure: $(cat "$out")"
! grep -E 'integer expression expected|Segmentation fault' "$err" >/dev/null \
  || fail "missing-parent lock path emitted an arithmetic or signal failure: $(cat "$err")"
! grep -q '\.steal\.steal' "$dirname_log" \
  || fail "missing-parent acquisition attempted a nested steal path: $(tr '\n' ' ' < "$dirname_log")"
pass "missing lock parent fails once without recursion, arithmetic diagnostics, or retry spin"
