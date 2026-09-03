#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action and for
# bin/fm-pr-attestation-await.sh, the awaiter the gate workflow reads the live
# pull request through.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
AWAIT="$ROOT/bin/fm-pr-attestation-await.sh"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

# --- bin/fm-pr-attestation-await.sh -----------------------------------------
#
# The gate reads the pull request through the awaiter because `git push
# no-mistakes` pushes the commit and re-signs the PR body moments later: the
# synchronize event payload can therefore name the previous head's attestation
# for a PR that is already compliant, and no later event re-runs that job. These
# cases drive the awaiter against a fake `gh` and then hand what it emitted to
# the real shared verifier, so both the recovery and the guarantee it must not
# weaken are proved end to end.

pr_snapshot() {
  local path=$1 head=$2 attested=$3
  python3 - "$path" "$head" "$attested" "$SIGNATURE" "$COMPLETED_STEPS" <<'PY'
import json
import sys

path, head, attested, signature, steps = sys.argv[1:6]
attestation = ""
if attested:
    payload = json.dumps({"head_sha": attested, "steps": json.loads(steps)}, separators=(",", ":"))
    attestation = "\n<!-- no-mistakes-pipeline-attestation:v1 %s -->" % payload
body = "%s\n\n## Pipeline%s" % (signature, attestation)
snapshot = {
    "number": 3006,
    "body": body,
    "head": {"sha": head, "ref": "fm/awaiter-regression"},
    "user": {"login": "regression"},
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(snapshot, handle)
PY
}

install_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Serve one response per call from FM_FAKE_GH_RESPONSES (one path per line, or
# the literal FAIL for an API error); the last entry repeats once exhausted.
count=0
[ ! -f "$FM_FAKE_GH_COUNT" ] || count=$(cat "$FM_FAKE_GH_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_GH_COUNT"
response=$(sed -n "${count}p" "$FM_FAKE_GH_RESPONSES")
[ -n "$response" ] || response=$(tail -n 1 "$FM_FAKE_GH_RESPONSES")
if [ "$response" = FAIL ]; then
  printf 'fake gh: pull request unreadable\n' >&2
  exit 1
fi
cat "$response"
SH
  chmod +x "$fakebin/gh"
}

# Parse GITHUB_OUTPUT, the documented Actions step-output protocol, into the
# named value (heredoc-delimited values included).
output_value() {
  local file=$1 name=$2
  python3 - "$file" "$name" <<'PY'
import sys

path, name = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
except OSError:
    lines = []

value = None
index = 0
while index < len(lines):
    line = lines[index]
    if line.startswith(name + "<<"):
        delimiter = line[len(name) + 2:]
        index += 1
        collected = []
        while index < len(lines) and lines[index] != delimiter:
            collected.append(lines[index])
            index += 1
        value = "\n".join(collected)
    elif line.startswith(name + "="):
        value = line[len(name) + 1:]
    index += 1

sys.stdout.write("" if value is None else value)
PY
}

# Set up an awaiter case directory: $CASE_DIR, $CASE_OUTPUT (GITHUB_OUTPUT) and
# a fake `gh` on PATH serving the named snapshot files in order.
setup_await_case() {
  local name=$1
  shift
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  local fakebin
  fakebin=$(fm_fakebin "$CASE_DIR")
  install_fake_gh "$fakebin"
  CASE_OUTPUT="$CASE_DIR/github-output"
  : > "$CASE_OUTPUT"
  export FM_FAKE_GH_RESPONSES="$CASE_DIR/responses"
  export FM_FAKE_GH_COUNT="$CASE_DIR/gh-count"
  : > "$FM_FAKE_GH_RESPONSES"
  : > "$FM_FAKE_GH_COUNT"
  CASE_PATH="$fakebin:$PATH"
  local entry
  for entry in "$@"; do
    printf '%s\n' "$entry" >> "$FM_FAKE_GH_RESPONSES"
  done
}

run_await() {
  local rc=0 out
  out=$(PATH="$CASE_PATH" GITHUB_OUTPUT="$CASE_OUTPUT" \
    "$AWAIT" --repo owner/repo --pr 3006 "$@" 2>&1) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

gh_calls() {
  cat "$FM_FAKE_GH_COUNT"
}

test_await_reports_a_body_already_bound_to_the_head() {
  local output rc
  setup_await_case await-bound
  pr_snapshot "$CASE_DIR/fresh.json" "$NEW_SHA" "$NEW_SHA"
  printf '%s\n' "$CASE_DIR/fresh.json" > "$FM_FAKE_GH_RESPONSES"
  rc=0
  output=$(run_await --timeout-seconds 30 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed on a body already bound to the PR head"
  assert_contains "$output" "attestation binds to PR head $NEW_SHA" \
    "awaiter did not report the already-bound attestation"
  expect_code 1 "$(gh_calls)" "awaiter polled again after the first poll was already bound"
  [ "$(output_value "$CASE_OUTPUT" head-sha)" = "$NEW_SHA" ] ||
    fail "awaiter did not emit the live head SHA"
  [ "$(output_value "$CASE_OUTPUT" head-ref)" = "fm/awaiter-regression" ] ||
    fail "awaiter did not emit the live head ref"
  [ "$(output_value "$CASE_OUTPUT" author)" = regression ] ||
    fail "awaiter did not emit the live PR author"
  assert_contains "$(output_value "$CASE_OUTPUT" body)" "\"head_sha\":\"$NEW_SHA\"" \
    "awaiter did not emit the live PR body"
  pass "awaiter emits live PR facts when the body already binds to the head"
}

test_await_waits_for_a_body_signed_after_the_push() {
  local output rc body
  setup_await_case await-late
  pr_snapshot "$CASE_DIR/stale.json" "$NEW_SHA" "$OLD_SHA"
  pr_snapshot "$CASE_DIR/fresh.json" "$NEW_SHA" "$NEW_SHA"
  printf '%s\n%s\n%s\n' \
    "$CASE_DIR/stale.json" "$CASE_DIR/stale.json" "$CASE_DIR/fresh.json" \
    > "$FM_FAKE_GH_RESPONSES"
  rc=0
  output=$(run_await --timeout-seconds 30 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed while waiting for the re-signed body"
  assert_contains "$output" "attestation binds to PR head $NEW_SHA" \
    "awaiter did not report convergence once the body was re-signed"
  expect_code 3 "$(gh_calls)" "awaiter did not keep polling until the body was re-signed"
  body=$(output_value "$CASE_OUTPUT" body)
  assert_contains "$body" "\"head_sha\":\"$NEW_SHA\"" \
    "awaiter emitted a body that does not carry the re-signed attestation"
  assert_not_contains "$body" "$OLD_SHA" \
    "awaiter emitted the stale attestation instead of the re-signed one"
  rc=0
  output=$(run_verifier "$body" "$(output_value "$CASE_OUTPUT" head-sha)") || rc=$?
  expect_code 0 "$rc" "shared action rejected the body the awaiter waited for"
  pass "awaiter waits out the publish-order window and hands the gate a passing body"
}

test_await_still_lets_the_gate_reject_a_never_signed_body() {
  local output rc body
  setup_await_case await-timeout
  pr_snapshot "$CASE_DIR/stale.json" "$NEW_SHA" "$OLD_SHA"
  printf '%s\n' "$CASE_DIR/stale.json" > "$FM_FAKE_GH_RESPONSES"
  rc=0
  output=$(run_await --timeout-seconds 2 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed instead of handing the stale body to the gate"
  assert_contains "$output" "attestation still names $OLD_SHA" \
    "awaiter did not report that the body never bound to the head"
  body=$(output_value "$CASE_OUTPUT" body)
  rc=0
  output=$(run_verifier "$body" "$(output_value "$CASE_OUTPUT" head-sha)") || rc=$?
  [ "$rc" -ne 0 ] || fail "waiting turned a never-signed body into a passing gate"
  assert_contains "$output" "$OLD_SHA" \
    "gate verdict on the awaited body did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "gate verdict on the awaited body did not name the live PR head SHA"
  pass "awaiting a body that never binds still fails the gate on the live head"
}

test_await_binds_the_triggering_commit_after_the_publish_window() {
  local output rc body
  setup_await_case await-head-late
  pr_snapshot "$CASE_DIR/stale.json" "$NEW_SHA" "$OLD_SHA"
  pr_snapshot "$CASE_DIR/fresh.json" "$NEW_SHA" "$NEW_SHA"
  printf '%s\n%s\n' "$CASE_DIR/stale.json" "$CASE_DIR/fresh.json" > "$FM_FAKE_GH_RESPONSES"
  rc=0
  output=$(run_await --head "$NEW_SHA" --timeout-seconds 30 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed while waiting for the triggering commit to be signed"
  assert_contains "$output" "attestation binds to PR head $NEW_SHA" \
    "awaiter did not report convergence on the triggering commit"
  [ "$(output_value "$CASE_OUTPUT" head-sha)" = "$NEW_SHA" ] ||
    fail "awaiter did not emit the triggering commit as the head the gate judges"
  body=$(output_value "$CASE_OUTPUT" body)
  rc=0
  output=$(run_verifier "$body" "$(output_value "$CASE_OUTPUT" head-sha)") || rc=$?
  expect_code 0 "$rc" "shared action rejected the body the awaiter waited for"
  pass "awaiter still closes the publish-order window for the triggering commit"
}

# A check result is recorded against the commit its run was triggered for, and
# GitHub keeps that result cached for the SHA. Reporting the live head instead
# would let a branch that moves during the wait - a force-push back onto an
# already-attested commit is the sharp case - hand the gate an attestation for
# some *other* commit and leave a green check cached on a commit no attestation
# ever named. The awaiter must judge the commit it was triggered for.
test_await_never_certifies_a_commit_the_attestation_does_not_name() {
  local output rc body
  setup_await_case await-head-moved
  pr_snapshot "$CASE_DIR/other.json" "$OLD_SHA" "$OLD_SHA"
  printf '%s\n' "$CASE_DIR/other.json" > "$FM_FAKE_GH_RESPONSES"
  rc=0
  output=$(run_await --head "$NEW_SHA" --timeout-seconds 30 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed instead of handing the moved-head facts to the gate"
  assert_contains "$output" "PR head moved to $OLD_SHA" \
    "awaiter did not report that the branch moved off the triggering commit"
  expect_code 1 "$(gh_calls)" "awaiter kept polling after the branch had moved on"
  [ "$(output_value "$CASE_OUTPUT" head-sha)" = "$NEW_SHA" ] ||
    fail "awaiter emitted the live head instead of the commit this run judges"
  body=$(output_value "$CASE_OUTPUT" body)
  rc=0
  output=$(run_verifier "$body" "$(output_value "$CASE_OUTPUT" head-sha)") || rc=$?
  [ "$rc" -ne 0 ] ||
    fail "awaiter certified a commit the attestation never named"
  assert_contains "$output" "$NEW_SHA" \
    "gate verdict did not name the commit this run was triggered for"
  pass "awaiter never certifies a commit the attestation does not name"
}

test_await_falls_back_when_the_pull_request_is_unreadable() {
  local output rc
  setup_await_case await-unreadable FAIL
  rc=0
  output=$(run_await --timeout-seconds 2 --interval-seconds 1) || rc=$?
  expect_code 0 "$rc" "awaiter failed the gate over an unreadable pull request"
  assert_contains "$output" "leaving the gate to judge the workflow event payload" \
    "awaiter did not report the fallback to the event payload"
  [ ! -s "$CASE_OUTPUT" ] ||
    fail "awaiter emitted step outputs it could not read from the pull request"
  pass "awaiter falls back to the event payload when the pull request is unreadable"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_await_reports_a_body_already_bound_to_the_head
test_await_waits_for_a_body_signed_after_the_push
test_await_still_lets_the_gate_reject_a_never_signed_body
test_await_binds_the_triggering_commit_after_the_publish_window
test_await_never_certifies_a_commit_the_attestation_does_not_name
test_await_falls_back_when_the_pull_request_is_unreadable
