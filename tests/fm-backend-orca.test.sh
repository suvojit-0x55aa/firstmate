#!/usr/bin/env bash
# tests/fm-backend-orca.test.sh - fake-Orca-CLI unit tests for the Orca
# terminal adapter primitives in bin/backends/orca.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-tests)

make_orca_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
next=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ -f "$RESP/change-after-terminal" ] && [ "${1:-}" = terminal ] && [ "${2:-}" = close ]; then
  : > "$RESP/.terminal-closed"
fi
if [ "${1:-}" = status ] && [ "${FM_ORCA_STATUS_RESPONSE:-ready}" != sequence ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
if [ -f "$RESP/use-show-sequence" ] && [ "${1:-}" = worktree ] && [ "${2:-}" = show ]; then
  SHOW_COUNT_FILE="$RESP/.show-count"
  show_next=$(( $(cat "$SHOW_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$show_next" > "$SHOW_COUNT_FILE"
  if [ -f "$RESP/.terminal-closed" ] && [ -f "$RESP/after-terminal.exit" ]; then
    exit "$(cat "$RESP/after-terminal.exit")"
  fi
  if [ -f "$RESP/.terminal-closed" ] && [ -f "$RESP/after-terminal.out" ]; then
    cat "$RESP/after-terminal.out"
  elif [ -f "$RESP/show-$show_next.exit" ]; then
    exit "$(cat "$RESP/show-$show_next.exit")"
  elif [ -f "$RESP/show-$show_next.out" ]; then
    cat "$RESP/show-$show_next.out"
  elif [ -f "$RESP/worktree.out" ]; then
    cat "$RESP/worktree.out"
  fi
  exit 0
fi
n=$next
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

orca_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_orca_fakebin "$CASE_DIR")
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

add_tmux_fake() {
  local fb=$1
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
{
  printf 'tmux'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
exit 0
SH
  chmod +x "$fb/tmux"
}

add_teardown_side_effect_fakes() {
  local fb=$1
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'side-effect:no-mistakes:%s\n' "$*" >> "${FM_ORCA_LOG:?}"
exit 0
SH
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'side-effect:lsof:%s\n' "$*" >> "${FM_ORCA_LOG:?}"
if [ -n "${FM_ORCA_TEST_LSOF_PID:-}" ]; then
  printf 'p%s\nfcwd\nn%s\n' "$FM_ORCA_TEST_LSOF_PID" "${FM_ORCA_TEST_LSOF_PATH:?}"
fi
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/lsof"
}

test_capture_reads_terminal_tail_json() {
  local out
  orca_case capture-tail
  printf '{"result":{"terminal":{"tail":["line one","line two"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-123 40' "$ROOT" )
  [ "$out" = $'line one\nline two' ] || fail "capture should print result.terminal.tail joined by newlines, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--limit'$'\x1f''40'$'\x1f''--json' \
    "capture did not call orca terminal read with terminal/limit/json"
  pass "fm_backend_orca_capture: parses result.terminal.tail and calls terminal read"
}

test_capture_falls_back_to_text_fields() {
  local out
  orca_case capture-text
  printf '{"result":{"text":"plain text output"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-abc 5' "$ROOT" )
  [ "$out" = "plain text output" ] || fail "capture should fall back to result.text, got '$out'"
  pass "fm_backend_orca_capture: falls back to result text fields"
}

test_capture_fails_on_orca_error_json() {
  local out status
  orca_case capture-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_capture term-stale 5' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on Orca ok:false read JSON"
  assert_contains "$out" "terminal handle stale" "capture should surface the Orca read error message"
  pass "fm_backend_orca_capture: fails closed on Orca read error JSON"
}

test_runtime_check_accepts_ready_orca_status() {
  local out
  orca_case runtime-ready
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" )
  [ -z "$out" ] || fail "runtime_check should be quiet on ready status, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "runtime_check did not call orca status --json"
  pass "fm_backend_orca_runtime_check: accepts reachable ready runtime"
}

test_runtime_check_refuses_unready_orca_status() {
  local out status
  orca_case runtime-unready
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_runtime_check' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should fail when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" "runtime_check should explain the readiness requirement"
  pass "fm_backend_orca_runtime_check: fails closed when runtime is not ready"
}

test_send_text_submit_verifies_empty_composer_after_enter() {
  local out
  orca_case send-submit
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭───╮","│ > │","╰───╯"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should report empty on successful Orca send, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''hello captain'$'\x1f''--json' \
    "send_text_submit did not type the text literally before Enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_text_submit did not send Enter after typing"
  # The composer read is ONE bounded tail read: the old backward paging
  # (--cursor follow-ups on a limited page) is deleted, because paging into
  # scrollback is what let a stale startup banner compete with the live
  # composer (audit fm-composer-consolidation-audit-s1, section 3.3).
  assert_not_contains "$(cat "$LOG")" $'\x1f''--cursor'$'\x1f' \
    "the composer read must never page backward into scrollback"
  pass "fm_backend_orca_send_text_submit: verifies empty composer after Enter with one bounded read"
}

test_send_text_submit_borderless_claude_confirms() {
  # The #2029 analogue this adapter never received: a borderless claude
  # composer (bare `❯` row between horizontal rules) must confirm a submit.
  # Before consolidation orca knew only the bordered shape, so every steer to
  # a borderless harness exited unconfirmed and --resolve-key never closed.
  local out
  orca_case send-submit-borderless
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["────────────────","❯","────────────────"]}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "a borderless claude composer should confirm the submit, got '$out'"
  pass "fm_backend_orca_send_text_submit: a borderless claude composer confirms delivery (the missing #2029 shape)"
}

test_composer_state_stale_banner_never_wins() {
  # The audit's confidently-wrong case (section 3.3): codex's startup banner
  # (`│ permissions: YOLO mode │` inside a rounded box) classified as the
  # composer, reading `pending` for a row that is not a composer at all. With
  # the full shape catalogue the live bare row below the banner wins; with a
  # plain capture its trailing hint text is unreadable, so the verdict is
  # `unknown` (defer) - never the banner's false `pending`.
  local out
  orca_case composer-stale-banner
  printf '{"ok":true,"result":{"terminal":{"tail":["╭────────────────────────╮","│ permissions: YOLO mode │","╰────────────────────────╯","› Use /skills to list available skills"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" != pending ] || fail "a stale startup banner must never classify as pending composer text"
  [ "$out" = unknown ] || fail "the plain-capture codex hint should defer as unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a stale startup banner cannot outrank the live composer row"
}

test_send_text_submit_retries_when_composer_stays_pending() {
  local out log_text enter_count
  orca_case send-submit-pending
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ > hello captain │","╰─────────────────╯"]}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["╭─────────────────╮","│ >               │","╰─────────────────╯"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello captain" 3 0.01 0.01' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit should send Enter twice when the first read is pending, got $enter_count"
  pass "fm_backend_orca_send_text_submit: retries Enter while composer remains pending"
}

test_composer_state_popup_placeholder_fill_is_pending() {
  local out
  orca_case composer-popup-placeholder
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = pending ] || fail "a popup-close-with-placeholder-fill must still read as pending (not yet submitted), got '$out'"
  pass "fm_backend_orca_composer_state: a slash-command popup's argument-hint placeholder still reads pending"
}

# Dead-shell injection safety (task fm-composer-shellglyph-safety): a pane whose
# agent has exited to a bare login shell has no bordered composer row, so the
# classifier finds nothing and reports `unknown` - NOT a safe (empty) injection
# target. Covers the same guarantee herdr/cmux/tmux tests pin for their backends.
test_composer_state_bare_shell_prompt_is_unknown() {
  local out
  orca_case composer-bare-shell
  printf '{"ok":true,"result":{"terminal":{"tail":["some earlier output","kunchen@mac firstmate $ "]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_composer_state term-123' "$ROOT" )
  [ "$out" = unknown ] || fail "a bare dead-shell prompt (no bordered composer row) must read unknown, got '$out'"
  pass "fm_backend_orca_composer_state: a bare dead-shell prompt reads unknown (unsafe-for-injection), never empty"
}

test_send_text_submit_popup_autocomplete_requires_second_enter() {
  local out log_text enter_count
  orca_case send-submit-popup-autocomplete
  # 1: literal send "/compact"
  # 2: Enter #1 closes the popup and fills the placeholder
  # 3: read - composer still holds real pending text
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭──────────────────────────────────────╮","  │ ❯ /compact compaction instructions   │","  ╰──────────────── Composer ────────────╯","","  Enter:send"]}}}\n' > "$RESP/3.out"
  # 4: Enter #2 actually submits
  # 5: read - composer is empty
  printf '{"ok":true,"result":{"send":{"handle":"term-123","accepted":true}}}\n' > "$RESP/4.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["  ╭────────────────────────╮","  │ ❯                      │","  ╰──────── Composer ──────╯","","  Shift+Tab:mode"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "/compact" 3 0.01 1.2' "$ROOT" )
  [ "$out" = empty ] || fail "send_text_submit should eventually report empty once the SECOND Enter actually clears the composer, got '$out'"
  log_text=$(cat "$LOG")
  enter_count=$(printf '%s\n' "$log_text" | grep -c $'orca\x1fterminal\x1fsend\x1f--terminal\x1fterm-123\x1f--text\x1f\x1f--enter\x1f--json')
  [ "$enter_count" -eq 2 ] || fail "send_text_submit must send a SECOND Enter after the popup-placeholder fill still reads pending, got $enter_count Enter(s)"
  pass "fm_backend_orca_send_text_submit: a slash-command popup's placeholder fill on Enter #1 does not short-circuit as submitted; Enter #2 is retried and lands it"
}

test_send_literal_constructs_non_enter_send() {
  orca_case send-literal
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-123 "typed only"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f''typed only'$'\x1f''--json' \
    "send_literal did not send text without --enter"
  assert_not_contains "$(cat "$LOG")" $'\x1f''--enter' "send_literal should not submit Enter"
  pass "fm_backend_orca_send_literal: sends text without submitting"
}

test_send_text_submit_reports_send_failed() {
  local out
  orca_case send-fail
  printf '1\n' > "$RESP/1.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-123 "hello" 1 0.01 0.01' "$ROOT" )
  [ "$out" = send-failed ] || fail "failed Orca send should report send-failed, got '$out'"
  pass "fm_backend_orca_send_text_submit: reports send-failed when Orca send fails"
}

test_send_helpers_reject_orca_error_json() {
  local out status
  orca_case send-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_line term-stale "hello"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_text_line should fail on Orca ok:false JSON"
  assert_contains "$out" "terminal handle stale" "send_text_line should surface the Orca send error"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_literal term-stale "typed"' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_literal should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-stale Enter' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should fail on Orca ok:false JSON"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_text_submit term-stale "hello" 1 0.01 0.01' "$ROOT" 2>/dev/null )
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed on Orca ok:false JSON, got '$out'"
  pass "Orca send helpers: fail closed on ok:false JSON"
}

test_send_key_enter_and_interrupt() {
  orca_case send-key
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Enter; fm_backend_orca_send_key term-123 C-c' "$ROOT"
  expect_code 0 $? "send_key Enter and C-c should succeed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send_key Enter did not send empty text with --enter"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--interrupt'$'\x1f''--json' \
    "send_key C-c did not send --interrupt"
  pass "fm_backend_orca_send_key: Enter maps to empty enter, C-c maps to interrupt"
}

test_send_key_refuses_unknown_key() {
  local out status
  orca_case send-key-unknown
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 F12' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse unsupported Orca keys"
  assert_contains "$out" "unsupported Orca key 'F12'" "send_key did not name the unsupported key"
  pass "fm_backend_orca_send_key: refuses unsupported keys loudly"
}

test_send_key_refuses_escape_until_supported() {
  local out status
  orca_case send-key-escape
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_send_key term-123 Escape' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse Escape until Orca exposes a real Escape primitive"
  assert_contains "$out" "unsupported Orca key 'Escape'" "send_key did not name Escape as unsupported"
  [ ! -s "$LOG" ] || fail "unsupported Escape should not call orca terminal send"
  pass "fm_backend_orca_send_key: refuses Escape instead of mapping it to interrupt"
}

test_kill_is_best_effort_close() {
  orca_case kill
  printf '1\n' > "$RESP/1.exit"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_kill term-123' "$ROOT"
  expect_code 0 $? "kill should stay best-effort when Orca close fails"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-123'$'\x1f''--json' \
    "kill did not call orca terminal close"
  pass "fm_backend_orca_kill: calls terminal close and stays best-effort"
}

test_remove_worktree_refuses_empty_id() {
  local out status
  orca_case remove-empty
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree ""' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail when the Orca worktree id is empty"
  assert_contains "$out" "missing Orca worktree id" "remove_worktree did not explain the missing id"
  [ ! -s "$LOG" ] || fail "remove_worktree should not call Orca with an empty id"
  pass "fm_backend_orca_remove_worktree: refuses empty worktree ids"
}

test_remove_worktree_rejects_orca_error_json() {
  local out status
  orca_case remove-error-json
  printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_remove_worktree wt-gone' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree should fail on Orca ok:false JSON"
  assert_contains "$out" "worktree not found" "remove_worktree should surface the Orca removal error"
  pass "fm_backend_orca_remove_worktree: fails closed on ok:false JSON"
}

test_worktree_path_resolves_id() {
  local out
  orca_case path-resolve
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_path wt-123' "$ROOT" )
  [ "$out" = /tmp/orca-wt ] || fail "worktree path helper should print the resolved path, got '$out'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--json' \
    "worktree path helper did not call orca worktree show"
  pass "fm_backend_orca_worktree_path: resolves an Orca worktree id to its path"
}

test_json_get_ignores_undocumented_terminal_id_shapes() {
  local out status wt_id wt_path term
  orca_case parser-pruned-terminal-shapes

  set +e
  out=$( printf '{"ok":true,"result":{"id":"term-root-id"}}\n' | \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_json_get terminal-handle' "$ROOT" )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "terminal-handle should not treat undocumented result.id as a terminal handle, got '$out'"

  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt","terminal":{"handle":"term-nested"}}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  term=${wt_path#*$'\t'}
  wt_path=${wt_path%%$'\t'*}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should still print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should still print worktree path, got '$wt_path'"
  [ "$term" = "$wt_path" ] || fail "worktree helper should ignore undocumented result.worktree.terminal and omit an implicit terminal, got '$out'"
  pass "fm_backend_orca_json_get: ignores undocumented terminal id shapes"
}

test_worktree_and_terminal_helpers_parse_json() {
  local out wt_id wt_path term
  orca_case lifecycle-helpers
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-123"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-123","path":"/tmp/orca-wt"}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-123"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" )
  wt_id=${out%%$'\t'*}
  wt_path=${out#*$'\t'}
  [ "$wt_id" = wt-123 ] || fail "worktree helper should print worktree id, got '$wt_id'"
  [ "$wt_path" = /tmp/orca-wt ] || fail "worktree helper should print worktree path, got '$wt_path'"
  term=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_terminal_create wt-123 fm-task' "$ROOT" )
  [ "$term" = term-123 ] || fail "terminal helper should print terminal handle, got '$term'"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''show'$'\x1f''--repo'$'\x1f''path:/repo/path'$'\x1f''--json' \
    "worktree helper should first check repo registration"
  assert_contains "$(cat "$LOG")" $'orca\x1f''repo'$'\x1f''add'$'\x1f''--path'$'\x1f''/repo/path'$'\x1f''--json' \
    "worktree helper should register an absent repo"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''create'$'\x1f''--repo'$'\x1f''id:repo-123'$'\x1f''--name'$'\x1f''fm-task'$'\x1f''--no-parent'$'\x1f''--setup'$'\x1f''skip'$'\x1f''--json' \
    "worktree helper did not create an independent no-hook worktree"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-123'$'\x1f''--title'$'\x1f''fm-task'$'\x1f''--json' \
    "terminal helper did not create a titled terminal for the worktree"
  pass "Orca lifecycle helpers: register repo, create worktree, create terminal, parse stable ids"
}

test_worktree_create_removes_worktree_when_path_missing() {
  local out status
  orca_case lifecycle-missing-path
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-no-path"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-no-path"},"terminal":{"handle":"term-no-path"}}}\n' > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/orca.sh"; fm_backend_orca_worktree_create /repo/path fm-task' "$ROOT" 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "worktree helper should fail when Orca omits the worktree path"
  assert_contains "$out" "orca worktree create did not return a path for fm-task" \
    "worktree helper did not explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-no-path'$'\x1f''--json' \
    "worktree helper did not close the implicit terminal when path parsing failed"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-no-path'$'\x1f''--force'$'\x1f''--json' \
    "worktree helper did not remove the pathless Orca worktree"
  pass "fm_backend_orca_worktree_create: removes created worktree when path is missing"
}

test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails() {
  local proj data state config id out status
  id="orcapathlessz6"
  proj="$TMP_ROOT/pathless-cleanup-project"
  data="$TMP_ROOT/pathless-cleanup-data"
  state="$TMP_ROOT/pathless-cleanup-state"
  config="$TMP_ROOT/pathless-cleanup-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case pathless-cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-pathless-cleanup"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-pathless-cleanup"}}}\n' > "$RESP/3.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/4.out"
  printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when path parsing and cleanup fail"
  assert_contains "$out" "orca worktree create did not return a path" \
    "pathless worktree failure should explain the missing path"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-pathless-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "pathless cleanup should attempt helper-backed worktree removal"
  assert_present "$state/$id.meta" "failed pathless cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved pathless metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved pathless metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-pathless-cleanup" "$state/$id.meta" "preserved pathless metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved pathless metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when pathless cleanup fails"
}

test_spawn_writes_orca_metadata_and_launches_harness() {
  local proj wt data state config id out log
  id="orcaspawnz1"
  proj="$TMP_ROOT/spawn-project"
  wt="$TMP_ROOT/spawn-wt"
  data="$TMP_ROOT/spawn-data"
  state="$TMP_ROOT/spawn-state"
  config="$TMP_ROOT/spawn-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case spawn
  log="$LOG"
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-spawn"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-spawn","path":"%s"},"terminal":{"handle":"term-spawn"}}}\n' "$wt" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  expect_code 0 $? "fm-spawn.sh --backend orca should succeed with fake Orca"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$wt" \
    "spawn output missing Orca window/worktree summary"
  assert_grep "backend=orca" "$state/$id.meta" "meta missing backend=orca"
  assert_grep "window=fm-$id" "$state/$id.meta" "meta missing stable Orca window alias"
  assert_grep "terminal=term-spawn" "$state/$id.meta" "meta missing terminal handle"
  assert_grep "orca_worktree_id=wt-spawn" "$state/$id.meta" "meta missing Orca worktree id"
  assert_grep "worktree=$wt" "$state/$id.meta" "meta missing Orca worktree path"
  assert_not_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''create' \
    "spawn should reuse the implicit terminal returned by Orca worktree creation"
  assert_contains "$(cat "$log")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-spawn'$'\x1f''--text'$'\x1f''export GOTMPDIR=/tmp/fm-orcaspawnz1/gotmp'$'\x1f''--enter'$'\x1f''--json' \
    "spawn did not export GOTMPDIR through the Orca terminal"
  assert_contains "$(cat "$log")" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "spawn did not send the selected harness launch command through Orca"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh --backend orca: reuses implicit terminal, records metadata, launches harness"
}

test_spawn_refuses_orca_secondmate_before_home_mutation() {
  local home subhome data state config id out status
  id="orcasmz1"
  home="$TMP_ROOT/secondmate-refusal-home"
  subhome="$TMP_ROOT/secondmate-refusal-subhome"
  data="$home/data"
  state="$home/state"
  config="$home/config"
  mkdir -p "$data" "$state" "$config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$config/crew-harness"
  touch "$state/.last-watcher-beat"
  set +e
  out=$( FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend orca --secondmate 2>&1 )
  status=$?
  set +e
  [ "$status" -ne 0 ] || fail "backend=orca --secondmate should be refused"
  assert_contains "$out" "backend=orca does not support --secondmate spawns yet" \
    "orca secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" \
    "orca secondmate refusal should not propagate inherited local material into the secondmate home"
  pass "fm-spawn.sh --backend orca --secondmate: refuses before secondmate-home mutation"
}

test_spawn_refuses_orca_when_runtime_not_ready() {
  local proj data state config id out status
  id="orcaruntimez6"
  proj="$TMP_ROOT/runtime-down-project"
  data="$TMP_ROOT/runtime-down-data"
  state="$TMP_ROOT/runtime-down-state"
  config="$TMP_ROOT/runtime-down-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case runtime-down-spawn
  printf '{"ok":true,"result":{"runtime":{"reachable":false,"state":"starting"}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" FM_ORCA_STATUS_RESPONSE=sequence \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn.sh --backend orca should refuse when Orca runtime is not ready"
  assert_contains "$out" "requires a ready Orca runtime" \
    "runtime readiness refusal should explain the Orca requirement"
  assert_absent "$state/$id.meta" "runtime refusal must not record metadata"
  assert_contains "$(cat "$LOG")" $'orca\x1f''status'$'\x1f''--json' \
    "spawn did not probe Orca runtime readiness"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''repo' \
    "spawn should fail before repo/worktree creation when runtime is not ready"
  pass "fm-spawn.sh --backend orca: refuses before mutation when Orca runtime is not ready"
}

test_spawn_refuses_orca_nonisolated_worktree() {
  local proj data state config id out status
  id="orcabadwtz4"
  proj="$TMP_ROOT/bad-spawn-project"
  data="$TMP_ROOT/bad-spawn-data"
  state="$TMP_ROOT/bad-spawn-state"
  config="$TMP_ROOT/bad-spawn-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case bad-spawn
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-bad"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-bad","path":"%s"},"terminal":{"handle":"term-bad"}}}\n' "$proj" > "$RESP/3.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  expect_code 1 "$status" "fm-spawn.sh --backend orca should refuse a primary checkout worktree"
  assert_contains "$out" "orca worktree create did not yield an isolated worktree" \
    "Orca spawn should reuse the isolated-worktree guard"
  assert_absent "$state/$id.meta" "aborted Orca spawn must not record meta"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create' \
    "Orca spawn should validate the worktree before creating a terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-bad'$'\x1f''--json' \
    "Orca spawn should close the implicit terminal after validation aborts"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-bad'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree after validation aborts"
  pass "fm-spawn.sh --backend orca: refuses non-isolated worktrees and closes implicit terminals"
}

test_spawn_removes_orca_worktree_when_terminal_create_fails() {
  local proj wt data state config id out status
  id="orcatermfailz8"
  proj="$TMP_ROOT/terminal-fail-project"
  wt="$TMP_ROOT/terminal-fail-wt"
  data="$TMP_ROOT/terminal-fail-data"
  state="$TMP_ROOT/terminal-fail-state"
  config="$TMP_ROOT/terminal-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case terminal-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-terminal-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-terminal-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation fails"
  assert_absent "$state/$id.meta" "terminal-create abort should not record metadata after successful cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''create'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail'$'\x1f''--title'$'\x1f'"fm-$id"$'\x1f''--json' \
    "Orca spawn should attempt terminal creation before abort cleanup"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-terminal-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the worktree when terminal creation fails"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca spawn should not close a terminal when no handle was recorded"
  pass "fm-spawn.sh --backend orca: removes worktree when terminal creation fails"
}

test_spawn_preserves_orca_metadata_when_abort_cleanup_fails() {
  local proj wt data state config id out status
  id="orcacleanupleakz0"
  proj="$TMP_ROOT/cleanup-fail-project"
  wt="$TMP_ROOT/cleanup-fail-wt"
  data="$TMP_ROOT/cleanup-fail-data"
  state="$TMP_ROOT/cleanup-fail-state"
  config="$TMP_ROOT/cleanup-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  touch "$state/.last-watcher-beat"
  orca_case cleanup-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-cleanup-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '1\n' > "$RESP/4.exit"
  printf '1\n' > "$RESP/5.exit"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when terminal creation and abort cleanup fail"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-cleanup-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should attempt helper cleanup before preserving metadata"
  assert_present "$state/$id.meta" "failed Orca abort cleanup should preserve metadata"
  assert_grep "window=fm-$id" "$state/$id.meta" "preserved metadata missing stable window alias"
  assert_grep "backend=orca" "$state/$id.meta" "preserved metadata missing backend=orca"
  assert_grep "orca_worktree_id=wt-cleanup-fail" "$state/$id.meta" "preserved metadata missing Orca worktree id"
  assert_no_grep "terminal=" "$state/$id.meta" "preserved metadata should not invent a terminal handle"
  pass "fm-spawn.sh --backend orca: preserves metadata when abort cleanup fails"
}

test_spawn_releases_orca_resources_when_metadata_write_fails() {
  local proj wt data state config id out status
  id="orcametafailz9"
  proj="$TMP_ROOT/meta-fail-project"
  wt="$TMP_ROOT/meta-fail-wt"
  data="$TMP_ROOT/meta-fail-data"
  state="$TMP_ROOT/meta-fail-state"
  config="$TMP_ROOT/meta-fail-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state/$id.meta" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  orca_case meta-fail
  printf '1\n' > "$RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-meta-fail"}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-meta-fail","path":"%s"}}}\n' "$wt" > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"handle":"term-meta-fail"}}}\n' > "$RESP/4.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off --backend orca 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "Orca spawn should fail when metadata cannot be written"
  assert_contains "$out" "Is a directory" "spawn should fail at metadata publication"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-meta-fail'$'\x1f''--json' \
    "Orca spawn should close the recorded terminal when a later abort occurs"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-meta-fail'$'\x1f''--force'$'\x1f''--json' \
    "Orca spawn should remove the recorded worktree when a later abort occurs"
  [ ! -f "$state/$id.meta" ] || fail "metadata-write abort should not publish a regular metadata file"
  pass "fm-spawn.sh --backend orca: releases terminal and worktree on later aborts"
}

test_peek_send_and_crew_state_route_through_orca_meta() {
  local wt state id out neutral record body
  id="orcaiopathz2"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-io" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case io-path
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":true,"result":{"terminal":{"tail":["ready"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Orca metadata, got '$out'"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/2.out"
  printf '{"ok":true,"result":{"send":{"handle":"term-io","accepted":true}}}\n' > "$RESP/3.out"
  printf '{"ok":true,"result":{"terminal":{"tail":["│ > │"]}}}\n' > "$RESP/4.out"
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello orca"
  printf '{"ok":true,"result":{"terminal":{"tail":["idle prompt"]}}}\n' > "$RESP/5.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should fall back cleanly for an idle Orca scout"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-io' \
    "peek/crew-state did not read the recorded Orca terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f'"fm-$id" \
    "crew-state should not read the stable Orca alias as a terminal handle"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "send did not enqueue through the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello orca" ] || fail "Orca task inbox did not preserve the send body, got '$body'"
  assert_not_contains "$(cat "$LOG")" $'--text\x1fhello orca\x1f' \
    "send typed the payload instead of recording it"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f''Firstmate instruction waiting:' \
    "send did not ring the inbox doorbell through the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''send'$'\x1f''--terminal'$'\x1f''term-io'$'\x1f''--text'$'\x1f\x1f''--enter'$'\x1f''--json' \
    "send did not submit the doorbell through the recorded Orca terminal"
  pass "fm-peek/fm-send/fm-crew-state route through backend=orca metadata and its durable inbox"
}

test_peek_and_crew_state_fail_closed_on_orca_error_json() {
  local wt state id out status neutral
  id="orcareaderrz7"
  wt="$TMP_ROOT/read-error-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/read-error-state"; mkdir -p "$state"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-stale" "worktree=$wt" "project=$wt" "harness=claude" "kind=scout" "backend=orca"
  touch "$state/.last-watcher-beat"
  orca_case read-error-json
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "fm-peek should fail when Orca reports a stale terminal"
  assert_contains "$out" "terminal handle stale" "fm-peek should surface the Orca read error message"
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/2.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: unknown" "crew-state should not treat an Orca read error as a live endpoint"
  assert_contains "$out" "backend target gone: term-stale" "crew-state should report the stale Orca terminal as gone"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''read'$'\x1f''--terminal'$'\x1f''term-stale' \
    "fm-peek/fm-crew-state did not read the recorded Orca terminal"
  pass "fm-peek/fm-crew-state: Orca read error JSON fails closed"
}

test_target_exists_rejects_orca_error_json() {
  local status
  orca_case target-exists-error-json
  printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal handle stale"}}\n' > "$RESP/1.out"
  set +e
  PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_target_exists orca term-stale fm-task' "$ROOT"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fm_backend_target_exists should reject Orca ok:false read JSON"
  pass "fm_backend_target_exists: Orca ok:false read JSON is not live"
}

test_scout_teardown_removes_orca_worktree_via_helper() {
  local proj wt data state config id out rc neutral
  id="orcateardownz3"
  proj="$TMP_ROOT/teardown-project"
  wt="$TMP_ROOT/teardown-wt"
  data="$TMP_ROOT/teardown-data"
  state="$TMP_ROOT/teardown-state"
  config="$TMP_ROOT/teardown-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_test_seed_manual_task "$data" "$config" "$id"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-teardown" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-teardown" \
    "decisions_reviewed=1" "decision_keys="
  orca_case teardown
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-teardown","path":"%s"}}}\n' "$wt" \
    > "$RESP/worktree.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca scout teardown should succeed once report exists"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-teardown'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-teardown'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the Orca worktree through orca worktree rm"
  assert_absent "$state/$id.meta" "teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: scout report gate then helper-backed worktree removal"
}

test_scout_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcascoutmismatchz5"
  proj="$TMP_ROOT/scout-mismatch-project"
  wt="$TMP_ROOT/scout-mismatch-wt"
  other_wt="$TMP_ROOT/scout-mismatch-other-wt"
  data="$TMP_ROOT/scout-mismatch-data"
  state="$TMP_ROOT/scout-mismatch-state"
  config="$TMP_ROOT/scout-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  fm_test_seed_manual_task "$data" "$config" "$id"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-scout-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-scout-mismatch" \
    "decisions_reviewed=1" "decision_keys="
  orca_case scout-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-scout-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse when id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca scout worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca scout teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca scout teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout teardown refuses id/path mismatches"
}

test_teardown_removes_orca_worktree_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcamissingpathz7"
  proj="$TMP_ROOT/missing-path-project"
  wt="$TMP_ROOT/missing-path-wt"
  data="$TMP_ROOT/missing-path-data"
  state="$TMP_ROOT/missing-path-state"
  config="$TMP_ROOT/missing-path-config"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-path" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-path" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-path
  for response in 1 2 3; do
    printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/$response.out"
  done
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca teardown should release helpers even when the path is absent"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-missing-path'$'\x1f''--json' \
    "teardown did not close the recorded Orca terminal when the path was absent"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "teardown attempted to remove an Orca worktree already proven absent"
  assert_absent "$state/$id.meta" "successful helper cleanup should remove task metadata"
  pass "fm-teardown.sh backend=orca: retires an authoritatively absent worktree"
}

run_orca_remove_failure_retry_case() {
  local variant=$1 proj wt data state config id out rc neutral
  id="orcrm${variant}z2"
  proj="$TMP_ROOT/remove-$variant-project"
  wt="$TMP_ROOT/remove-$variant-wt"
  data="$TMP_ROOT/remove-$variant-data"
  state="$TMP_ROOT/remove-$variant-state"
  config="$TMP_ROOT/remove-$variant-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf '# Backlog\n\n## In flight\n\n- [ ] %s - Removal retry fixture (repo: firstmate) (kind: scout)\n\n## Queued\n\n## Done\n' \
    "$id" > "$data/backlog.md"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-remove-$variant" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-remove-$variant" \
    "decisions_reviewed=1" "decision_keys="
  orca_case "remove-$variant-teardown"
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-remove-%s","path":"%s"}}}\n' \
    "$variant" "$wt" > "$RESP/worktree.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  if [ "$variant" = structured ]; then
    printf '{"ok":false,"error":{"code":"worktree_not_removed","message":"worktree not removed"}}\n' > "$RESP/2.out"
  else
    printf '75\n' > "$RESP/2.exit"
  fi
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca $variant removal failure should refuse teardown"
  assert_contains "$out" "Orca worktree removal failed" \
    "Orca $variant removal failure should explain that custody was retained"
  if [ "$variant" = structured ]; then
    assert_contains "$out" "worktree not removed" "teardown should surface the structured Orca removal error"
  fi
  assert_not_contains "$out" "teardown $id complete" \
    "Orca $variant removal failure reported false teardown success"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "Orca $variant removal failure fixture did not reach worktree removal"
  assert_present "$state/$id.meta" "failed Orca $variant removal should preserve task metadata"
  assert_present "$wt" "failed Orca $variant removal should preserve the worktree"

  orca_case "remove-$variant-retry"
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-remove-%s","path":"%s"}}}\n' \
    "$variant" "$wt" > "$RESP/worktree.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/2.out"
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca $variant removal retry should succeed"$'\n'"$out"
  assert_contains "$out" "teardown $id complete" \
    "Orca $variant removal retry did not report success"
  assert_absent "$state/$id.meta" "successful Orca $variant removal retry retained task metadata"
}

test_teardown_retries_after_orca_remove_failures() {
  run_orca_remove_failure_retry_case structured
  run_orca_remove_failure_retry_case transient
  pass "fm-teardown.sh backend=orca: removal failures preserve custody for safe retry"
}

run_orca_cleanup_refusal_case() {
  local phase=$1 proj wt data state config id out rc neutral head status
  id="orcaclean${phase}z4"
  proj="$TMP_ROOT/cleanup-$phase-project"
  wt="$TMP_ROOT/cleanup-$phase-wt"
  data="$TMP_ROOT/cleanup-$phase-data"
  state="$TMP_ROOT/cleanup-$phase-state"
  config="$TMP_ROOT/cleanup-$phase-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf '# Backlog\n\n## In flight\n\n- [ ] %s - Cleanup refusal fixture (repo: firstmate) (kind: ship)\n\n## Queued\n\n## Done\n' \
    "$id" > "$data/backlog.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-cleanup-$phase" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-cleanup-$phase" \
    "decisions_reviewed=1" "decision_keys="
  orca_case "cleanup-$phase-refusal"
  add_teardown_side_effect_fakes "$FB"
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-cleanup-%s","path":"%s"}}}\n' \
    "$phase" "$wt" > "$RESP/worktree.out"
  status=
  if [ "$phase" = run ]; then
    head=$(git -C "$wt" rev-parse HEAD)
    status=$(cat <<EOF
run:
  id: "01RUN"
  branch: fm/$id
  status: awaiting_approval
  head: "$head"
  pr: ""
steps[0]:
EOF
)
    cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'side-effect:no-mistakes:%s\n' "$*" >> "${FM_ORCA_LOG:?}"
case " $* " in
  *" axi status "*) printf '%s\n' "${FM_ORCA_TEST_NM_STATUS:?}" ;;
esac
exit 0
SH
    chmod +x "$FB/no-mistakes"
  else
    cat > "$FB/lsof" <<'SH'
#!/usr/bin/env bash
printf 'side-effect:lsof:%s\n' "$*" >> "${FM_ORCA_LOG:?}"
exit 1
SH
    chmod +x "$FB/lsof"
  fi
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ORCA_TEST_NM_STATUS="$status" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca $phase cleanup refusal should stop teardown"
  assert_not_contains "$out" "teardown $id complete" \
    "Orca $phase cleanup refusal reported false teardown success"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca $phase cleanup refusal closed the endpoint"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "Orca $phase cleanup refusal removed the worktree"
  assert_present "$state/$id.meta" "Orca $phase cleanup refusal removed task metadata"
  assert_present "$wt" "Orca $phase cleanup refusal removed the worktree path"
  if [ "$phase" = run ]; then
    assert_contains "$(cat "$LOG")" 'side-effect:no-mistakes:' \
      "Orca run-conclusion refusal fixture never reached no-mistakes: $out"
    assert_contains "$out" "is still parked after axi abort" \
      "Orca run-conclusion refusal did not preserve the parked run"
    assert_not_contains "$(cat "$LOG")" 'side-effect:lsof:' \
      "Orca run-conclusion refusal continued into process enumeration"
  else
    assert_contains "$(cat "$LOG")" 'side-effect:lsof:' \
      "Orca process refusal fixture never reached process enumeration"
    assert_contains "$out" "cannot determine leaked processes" \
      "Orca process refusal did not explain the failed safety scan"
  fi
}

test_orca_cleanup_refusals_precede_destructive_teardown() {
  run_orca_cleanup_refusal_case run
  run_orca_cleanup_refusal_case process
  pass "fm-teardown.sh backend=orca: cleanup refusals preserve endpoint and custody"
}

run_orca_term_mutation_case() {
  local mutation=$1 proj wt scan_wt data state config id out rc neutral marker ready pid i
  id="orcaterm${mutation}z6"
  proj="$TMP_ROOT/term-$mutation-project"
  wt="$TMP_ROOT/term-$mutation-wt"
  data="$TMP_ROOT/term-$mutation-data"
  state="$TMP_ROOT/term-$mutation-state"
  config="$TMP_ROOT/term-$mutation-config"
  marker="$TMP_ROOT/term-$mutation-finished"
  ready="$TMP_ROOT/term-$mutation-ready"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  if [ "$mutation" = pushed ]; then
    git init -q --bare "$TMP_ROOT/term-$mutation-fork.git"
    git -C "$proj" remote add fork "$TMP_ROOT/term-$mutation-fork.git"
  fi
  scan_wt=$(cd "$wt" && pwd -P)
  mkdir -p "$data/$id" "$state" "$config"
  printf '# Backlog\n\n## In flight\n\n- [ ] %s - TERM mutation fixture (repo: firstmate) (kind: ship)\n\n## Queued\n\n## Done\n' \
    "$id" > "$data/backlog.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-mutation-$mutation" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-term-$mutation" \
    "decisions_reviewed=1" "decision_keys="
  orca_case "term-$mutation"
  add_teardown_side_effect_fakes "$FB"
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-term-%s","path":"%s"}}}\n' \
    "$mutation" "$wt" > "$RESP/worktree.out"
  cat > "$CASE_DIR/term-worker" <<'SH'
#!/usr/bin/env bash
set -u
cd "${FM_ORCA_TERM_WT:?}"
on_term() {
  case "${FM_ORCA_TERM_MUTATION:?}" in
    commit)
      printf 'committed after TERM\n' > term-commit.txt
      git add term-commit.txt
      git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'commit after TERM'
      ;;
    pushed)
      printf 'pushed after TERM\n' > term-pushed.txt
      git add term-pushed.txt
      git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'pushed after TERM'
      git push -q fork HEAD:refs/heads/fm/term-pushed
      git fetch -q fork
      ;;
    *) printf 'dirty after TERM\n' > term-dirty.txt ;;
  esac
  : > "${FM_ORCA_TERM_MARKER:?}"
  exit 0
}
trap on_term TERM
: > "${FM_ORCA_TERM_READY:?}"
while :; do sleep 0.1; done
SH
  chmod +x "$CASE_DIR/term-worker"
  FM_ORCA_TERM_WT="$wt" FM_ORCA_TERM_MUTATION="$mutation" \
    FM_ORCA_TERM_MARKER="$marker" FM_ORCA_TERM_READY="$ready" \
    "$CASE_DIR/term-worker" &
  pid=$!
  i=0
  while [ ! -f "$ready" ] && [ "$i" -lt 50 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  [ -f "$ready" ] || fail "Orca TERM $mutation worker did not become ready"
  cat > "$FB/lsof" <<'SH'
#!/usr/bin/env bash
printf 'side-effect:lsof:%s\n' "$*" >> "${FM_ORCA_LOG:?}"
if [ ! -f "${FM_ORCA_TERM_MARKER:?}" ]; then
  printf 'p%s\nfcwd\nn%s\n' "${FM_ORCA_TERM_PID:?}" "${FM_ORCA_TERM_SCAN_WT:?}"
fi
exit 0
SH
  chmod +x "$FB/lsof"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ORCA_TERM_PID="$pid" FM_ORCA_TERM_WT="$wt" FM_ORCA_TERM_SCAN_WT="$scan_wt" FM_ORCA_TERM_MARKER="$marker" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  [ -f "$marker" ] || fail "Orca TERM $mutation fixture did not mutate the worktree: $out; log: $(cat "$LOG")"
  [ "$rc" -ne 0 ] || fail "Orca teardown removed work after a process $mutation on TERM"
  assert_contains "$out" "REFUSED:" \
    "Orca TERM $mutation teardown did not report the renewed safety refusal"
  assert_not_contains "$out" "teardown $id complete" \
    "Orca TERM $mutation teardown reported false success"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "Orca TERM $mutation teardown closed the endpoint after safety changed"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "Orca TERM $mutation teardown removed the changed worktree"
  assert_present "$state/$id.meta" "Orca TERM $mutation teardown removed task metadata"
  assert_present "$wt" "Orca TERM $mutation teardown removed the changed worktree path"
  if [ "$mutation" = pushed ]; then
    git -C "$wt" merge-base --is-ancestor HEAD refs/remotes/fork/fm/term-pushed \
      || fail "Orca TERM pushed fixture did not retain H2 in remote custody"
    assert_contains "$out" "not landed in its intended default branch" \
      "Orca TERM pushed refusal did not require current landing proof"
  fi
}

test_orca_rechecks_safety_after_process_cleanup() {
  run_orca_term_mutation_case dirty
  run_orca_term_mutation_case commit
  run_orca_term_mutation_case pushed
  pass "fm-teardown.sh backend=orca: post-TERM mutations stop destructive teardown"
}

test_scout_teardown_refuses_orca_missing_report_when_path_missing() {
  local proj wt data state config id out rc neutral
  id="orcanoreportz4"
  proj="$TMP_ROOT/missing-report-project"
  wt="$TMP_ROOT/missing-report-wt"
  data="$TMP_ROOT/missing-report-data"
  state="$TMP_ROOT/missing-report-state"
  config="$TMP_ROOT/missing-report-config"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-report" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-report"
  orca_case missing-report
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca scout teardown should refuse without a report even when the path is absent"
  assert_contains "$out" "has no report" "Orca scout teardown should explain the missing report"
  [ ! -s "$LOG" ] || fail "refused Orca scout teardown should not close terminals or remove worktrees"
  assert_present "$state/$id.meta" "refused Orca scout teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: scout report gate precedes pathless helper cleanup"
}

test_ship_teardown_refuses_orca_missing_worktree_path() {
  local proj wt data state config id out rc neutral
  id="orcashipmissingz8"
  proj="$TMP_ROOT/missing-ship-project"
  wt="$TMP_ROOT/missing-ship-wt"
  data="$TMP_ROOT/missing-ship-data"
  state="$TMP_ROOT/missing-ship-state"
  config="$TMP_ROOT/missing-ship-config"
  fm_git_init_commit "$proj"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-ship" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-missing-ship" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-ship-path
  printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"runtime unavailable"}}\n' > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse a missing worktree path"
  assert_contains "$out" "cannot prove Orca worktree id wt-missing-ship is absent" \
    "Orca ship teardown should explain the ambiguous control-plane state"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show' \
    "refused Orca ship teardown did not consult the recorded worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused Orca ship teardown closed its terminal"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused Orca ship teardown removed a worktree"
  assert_present "$state/$id.meta" "refused Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when worktree path is missing"
}

run_ship_teardown_orca_landing_replay_case() {
  local variant=$1 proj wt other_wt data state config id out rc=0 neutral head receipt
  id="orcalanding${variant}z6"
  proj="$TMP_ROOT/landing-$variant-project"
  wt="$TMP_ROOT/landing-$variant-wt"
  data="$TMP_ROOT/landing-$variant-data"
  state="$TMP_ROOT/landing-$variant-state"
  config="$TMP_ROOT/landing-$variant-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-landing-$variant" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-landing-$variant" \
    "decisions_reviewed=1" "decision_keys=" "spawn_gen=landing-$variant"
  head=$(git -C "$wt" rev-parse HEAD)
  neutral=$(neutral_fm_root "$TMP_ROOT/landing-$variant-neutral")
  FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-terminal-reconcile.sh" local-landed "$id" "$head"
  receipt=$(find "$state/terminal-delivery" -type f -name '*.json' -print -quit)
  assert_present "$receipt" "Orca landing replay fixture did not create exact proof"
  if [ "$variant" = replacement ]; then
    printf '%s\n' 'spawn_gen=replacement-incarnation' >> "$state/$id.meta"
  fi
  git -C "$proj" worktree remove --force "$wt"
  orca_case "landing-$variant"
  case "$variant" in
    exact|replacement)
      printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/1.out"
      if [ "$variant" = exact ]; then
        printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/2.out"
        printf '{"ok":false,"error":{"code":"worktree_not_found","message":"worktree not found"}}\n' > "$RESP/3.out"
      fi
      ;;
    redirected)
      other_wt="$TMP_ROOT/landing-$variant-redirected"
      mkdir -p "$other_wt"
      printf '{"ok":true,"result":{"worktree":{"id":"wt-landing-%s","path":"%s"}}}\n' \
        "$variant" "$other_wt" > "$RESP/1.out"
      ;;
    reused)
      other_wt="$TMP_ROOT/landing-$variant-reused"
      git -C "$proj" worktree add --quiet -b "fm/$id-reused" "$other_wt"
      printf '{"ok":true,"result":{"worktree":{"id":"wt-landing-%s","path":"%s"}}}\n' \
        "$variant" "$other_wt" > "$RESP/1.out"
      ;;
    unavailable)
      printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"runtime unavailable"}}\n' > "$RESP/1.out"
      ;;
  esac
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  if [ "$variant" = exact ]; then
    expect_code 0 "$rc" "Orca exact landing-proof replay should complete"$'\n'"$out"
    assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-landing-exact' \
      "Orca exact landing-proof replay did not prove the recorded worktree id absent"
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
      "Orca exact landing-proof replay tried to remove an already absent worktree id"
    assert_absent "$state/$id.meta" "Orca exact landing-proof replay retained task metadata"
    jq -e '.retired and (.discarded != true)' "$receipt" >/dev/null \
      || fail "Orca exact landing-proof replay did not finish receipt retirement"
  else
    [ "$rc" -ne 0 ] || fail "Orca $variant landing replay accepted unsafe worktree identity"
    case "$variant" in
      replacement)
        assert_contains "$out" "no inspectable git worktree" \
          "Orca replacement refusal did not retain the missing-worktree safety boundary"
        ;;
      redirected|reused)
        assert_contains "$out" "still resolves to" \
          "Orca $variant refusal did not identify the live control-plane worktree"
        assert_present "$other_wt" "Orca $variant refusal removed the unrelated worktree"
        ;;
      unavailable)
        assert_contains "$out" "cannot prove Orca worktree id wt-landing-unavailable is absent" \
          "Orca unavailable refusal did not fail closed on ambiguous control-plane state"
        ;;
    esac
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
      "Orca $variant refusal closed the endpoint"
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
      "Orca $variant refusal removed a worktree"
    assert_present "$state/$id.meta" "Orca $variant refusal removed task metadata"
  fi
}

test_ship_teardown_replays_exact_orca_landing_proof() {
  run_ship_teardown_orca_landing_replay_case exact
  pass "fm-teardown.sh backend=orca: exact landing proof survives removed-worktree replay"
}

test_ship_teardown_rejects_replacement_orca_landing_proof() {
  run_ship_teardown_orca_landing_replay_case replacement
  pass "fm-teardown.sh backend=orca: replacement incarnation rejects stale landing proof"
}

test_ship_teardown_rejects_redirected_orca_landing_replay() {
  run_ship_teardown_orca_landing_replay_case redirected
  pass "fm-teardown.sh backend=orca: absent-path replay rejects redirected ids"
}

test_ship_teardown_rejects_reused_orca_landing_replay() {
  run_ship_teardown_orca_landing_replay_case reused
  pass "fm-teardown.sh backend=orca: absent-path replay rejects reused ids"
}

test_ship_teardown_rejects_unavailable_orca_landing_replay() {
  run_ship_teardown_orca_landing_replay_case unavailable
  pass "fm-teardown.sh backend=orca: absent-path replay rejects unavailable control planes"
}

test_ship_teardown_removes_orca_worktree_when_id_path_matches() {
  local proj wt data state config id out rc neutral
  id="orcashipmatchz2"
  proj="$TMP_ROOT/ship-match-project"
  wt="$TMP_ROOT/ship-match-wt"
  data="$TMP_ROOT/ship-match-data"
  state="$TMP_ROOT/ship-match-state"
  config="$TMP_ROOT/ship-match-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf '# Backlog\n\n## In flight\n\n- [ ] %s - Exact landed Orca fixture (repo: firstmate) (kind: ship)\n\n## Queued\n\n## Done\n' \
    "$id" > "$data/backlog.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-match" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-match" \
    "decisions_reviewed=1" "decision_keys="
  orca_case ship-match
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-match","path":"%s"}}}\n' "$wt" > "$RESP/worktree.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/1.out"
  printf '{"ok":true,"result":{}}\n' > "$RESP/2.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "Orca ship teardown should succeed when the id path matches the inspected worktree"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-match'$'\x1f''--json' \
    "teardown did not resolve the Orca worktree id before removal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-ship-match'$'\x1f''--json' \
    "teardown did not close the matched Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-ship-match'$'\x1f''--force'$'\x1f''--json' \
    "teardown did not remove the matched Orca worktree"
  assert_absent "$state/$id.meta" "successful matched teardown should remove task metadata"
  pass "fm-teardown.sh backend=orca: ship teardown requires a matching Orca id path"
}

test_ship_teardown_refuses_orca_unresolvable_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcashipunresolvedz1"
  proj="$TMP_ROOT/ship-unresolved-project"
  wt="$TMP_ROOT/ship-unresolved-wt"
  data="$TMP_ROOT/ship-unresolved-data"
  state="$TMP_ROOT/ship-unresolved-state"
  config="$TMP_ROOT/ship-unresolved-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-unresolved" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-unresolved"
  orca_case ship-unresolved
  printf '1\n' > "$RESP/1.exit"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the worktree id cannot be resolved"
  assert_contains "$out" "cannot resolve Orca worktree id wt-ship-unresolved" \
    "unresolvable Orca worktree id refusal should explain the fail-closed check"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-unresolved'$'\x1f''--json' \
    "teardown did not attempt to resolve the Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused unresolved Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused unresolved Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused unresolved Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown fails closed when id resolution fails"
}

test_ship_teardown_refuses_orca_id_path_mismatch() {
  local proj wt other_wt data state config id out rc neutral
  id="orcashipmismatchz9"
  proj="$TMP_ROOT/ship-mismatch-project"
  wt="$TMP_ROOT/ship-mismatch-wt"
  other_wt="$TMP_ROOT/ship-mismatch-other-wt"
  data="$TMP_ROOT/ship-mismatch-data"
  state="$TMP_ROOT/ship-mismatch-state"
  config="$TMP_ROOT/ship-mismatch-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  mkdir -p "$data/$id" "$state" "$config"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-ship-mismatch" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-ship-mismatch"
  orca_case ship-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-ship-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca ship teardown should refuse when the id path differs from worktree="
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca worktree path refusal should name the mismatch"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show'$'\x1f''--worktree'$'\x1f''id:wt-ship-mismatch'$'\x1f''--json' \
    "teardown did not resolve the mismatched Orca worktree id"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca ship teardown should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca ship teardown should not remove worktrees"
  assert_present "$state/$id.meta" "refused mismatched Orca ship teardown should preserve metadata"
  pass "fm-teardown.sh backend=orca: ship teardown refuses id/path mismatches"
}

run_orca_preflight_order_case() {
  local kind=$1 force_mode=$2 identity=$3 suffix id proj wt other_wt data state config neutral out rc=0 victim='' response
  suffix="${kind}${force_mode}${identity}"
  id="orcapreflight${suffix}z2"
  proj="$TMP_ROOT/preflight-$suffix-project"
  wt="$TMP_ROOT/preflight-$suffix-wt"
  other_wt="$TMP_ROOT/preflight-$suffix-other-wt"
  data="$TMP_ROOT/preflight-$suffix-data"
  state="$TMP_ROOT/preflight-$suffix-state"
  config="$TMP_ROOT/preflight-$suffix-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$data/backlog.md"
  touch "$state/.last-watcher-beat"
  if [ "$kind" = scout ]; then
    printf 'report\n' > "$data/$id/report.md"
  fi
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-$suffix" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=$kind" "mode=local-only" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-$suffix" \
    "decisions_reviewed=1" "decision_keys="
  orca_case "preflight-$suffix"
  add_teardown_side_effect_fakes "$FB"
  : > "$RESP/use-show-sequence"
  if [ "$identity" != exact ]; then
    git -C "$proj" worktree add --quiet -b "fm/$id-other" "$other_wt"
  fi
  printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
    "$suffix" "$wt" > "$RESP/worktree.out"
  if [ "$identity" = mismatch ]; then
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
      "$suffix" "$other_wt" > "$RESP/show-1.out"
  fi
  case "$identity" in
    exact|mismatch) ;;
    changed)
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
        "$suffix" "$other_wt" > "$RESP/show-2.out"
      ;;
    unavailable)
      printf '{"ok":false,"error":{"code":"runtime_unavailable","message":"runtime unavailable"}}\n' \
        > "$RESP/show-2.out"
      ;;
    changedscan)
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
        "$suffix" "$other_wt" > "$RESP/show-4.out"
      ;;
    changedsignal)
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
        "$suffix" "$other_wt" > "$RESP/show-8.out"
      sleep 60 &
      victim=$!
      ;;
    changedcheckout|changedbranch|changedhooks)
      case "$identity" in
        changedcheckout) response=7 ;;
        changedbranch) response=8 ;;
        changedhooks) response=9 ;;
      esac
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
        "$suffix" "$other_wt" > "$RESP/show-$response.out"
      ;;
    changedremove)
      : > "$RESP/change-after-terminal"
      printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' \
        "$suffix" "$other_wt" > "$RESP/after-terminal.out"
      ;;
  esac
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  if [ "$force_mode" = forced ]; then
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      FM_ORCA_TEST_LSOF_PID="$victim" FM_ORCA_TEST_LSOF_PATH="$wt" \
      FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
      "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1 )
  else
    out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
      FM_ORCA_TEST_LSOF_PID="$victim" FM_ORCA_TEST_LSOF_PATH="$wt" \
      FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
      "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  fi
  rc=$?
  set -e
  if [ -n "$victim" ]; then
    kill -0 "$victim" 2>/dev/null \
      || fail "Orca $suffix teardown signaled a process after identity changed"
    kill "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
  fi
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''show' \
    "Orca $suffix teardown did not resolve the recorded worktree id"
  if [ "$identity" = mismatch ]; then
    [ "$rc" -ne 0 ] || fail "Orca $suffix teardown accepted a mismatched worktree identity"
    assert_contains "$out" "not inspected worktree" \
      "Orca $suffix teardown did not report the identity mismatch"
    assert_not_contains "$(cat "$LOG")" 'side-effect:' \
      "Orca $suffix teardown reached run or process cleanup before refusing"
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
      "Orca $suffix teardown closed an endpoint before refusing"
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
      "Orca $suffix teardown removed a worktree before refusing"
    assert_present "$state/$id.meta" "Orca $suffix refusal removed task metadata"
    assert_present "$wt" "Orca $suffix refusal removed the recorded worktree"
    assert_present "$other_wt" "Orca $suffix refusal removed the unrelated worktree"
  elif [ "$identity" = exact ]; then
    expect_code 0 "$rc" "Orca $suffix teardown should accept an exact worktree identity"$'\n'"$out"
    assert_contains "$(cat "$LOG")" 'side-effect:lsof:' \
      "Orca $suffix exact-match teardown did not reach process cleanup"
    if [ "$kind" = ship ]; then
      assert_contains "$(cat "$LOG")" 'side-effect:no-mistakes:' \
        "Orca $suffix exact-match teardown did not reach run conclusion"
    fi
    assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
      "Orca $suffix exact-match teardown did not close its endpoint"
    assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
      "Orca $suffix exact-match teardown did not remove its worktree"
    assert_absent "$state/$id.meta" "Orca $suffix exact-match teardown retained task metadata"
  else
    [ "$rc" -ne 0 ] || fail "Orca $suffix teardown accepted stale control-plane identity evidence"
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
      "Orca $suffix teardown removed a worktree after identity evidence changed"
    assert_present "$state/$id.meta" "Orca $suffix stale-identity refusal removed task metadata"
    assert_present "$wt" "Orca $suffix stale-identity refusal removed the recorded worktree"
    [ "$identity" = unavailable ] || assert_present "$other_wt" \
      "Orca $suffix stale-identity refusal removed the replacement worktree"
    if [ "$identity" = changedremove ]; then
      assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
        "Orca $suffix fixture did not reach the endpoint boundary before identity changed"
    else
      assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
        "Orca $suffix teardown closed an endpoint after revalidation failed"
    fi
  fi
}

test_orca_identity_precedes_all_teardown_side_effects() {
  run_orca_preflight_order_case scout ordinary mismatch
  run_orca_preflight_order_case scout ordinary exact
  run_orca_preflight_order_case ship ordinary mismatch
  run_orca_preflight_order_case ship ordinary exact
  run_orca_preflight_order_case ship forced mismatch
  run_orca_preflight_order_case ship forced exact
  pass "fm-teardown.sh backend=orca: identity preflight precedes every cleanup path"
}

test_orca_identity_is_revalidated_at_destructive_boundaries() {
  run_orca_preflight_order_case scout ordinary changed
  run_orca_preflight_order_case ship forced changed
  run_orca_preflight_order_case ship forced unavailable
  run_orca_preflight_order_case scout ordinary changedscan
  run_orca_preflight_order_case ship forced changedsignal
  run_orca_preflight_order_case scout ordinary changedcheckout
  run_orca_preflight_order_case ship forced changedbranch
  run_orca_preflight_order_case scout ordinary changedhooks
  run_orca_preflight_order_case scout ordinary changedremove
  run_orca_preflight_order_case ship forced changedremove
  pass "fm-teardown.sh backend=orca: identity is revalidated at each destructive boundary"
}

test_teardown_refuses_orca_missing_worktree_id() {
  local proj wt data state config id out rc neutral
  id="orcamissingidz5"
  proj="$TMP_ROOT/missing-id-project"
  wt="$TMP_ROOT/missing-id-wt"
  data="$TMP_ROOT/missing-id-data"
  state="$TMP_ROOT/missing-id-state"
  config="$TMP_ROOT/missing-id-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-missing-id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" "backend=orca" \
    "decisions_reviewed=1" "decision_keys="
  orca_case missing-id
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown should refuse missing orca_worktree_id"
  assert_contains "$out" "missing orca_worktree_id" "teardown did not explain the missing Orca worktree id"
  assert_present "$state/$id.meta" "failed teardown must preserve task metadata"
  [ ! -s "$LOG" ] || fail "teardown should fail before closing terminals or removing worktrees without an Orca worktree id"
  pass "fm-teardown.sh backend=orca: refuses missing worktree ids before cleanup"
}

test_teardown_refuses_orca_worktree_without_terminal_handle() {
  local proj wt data state config id out rc neutral
  id="orcanotermz0"
  proj="$TMP_ROOT/no-terminal-project"
  wt="$TMP_ROOT/no-terminal-wt"
  data="$TMP_ROOT/no-terminal-data"
  state="$TMP_ROOT/no-terminal-state"
  config="$TMP_ROOT/no-terminal-config"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  mkdir -p "$data/$id" "$state" "$config"
  printf 'report\n' > "$data/$id/report.md"
  touch "$state/.last-watcher-beat"
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-no-terminal" \
    "decisions_reviewed=1" "decision_keys="
  orca_case no-terminal
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "Orca teardown accepted metadata without a terminal handle"
  assert_contains "$out" "missing terminal" "teardown did not explain the incomplete Orca endpoint"
  [ ! -s "$LOG" ] || fail "teardown dispatched to Orca before rejecting the incomplete endpoint"
  assert_present "$state/$id.meta" "missing-terminal refusal removed task metadata"
  pass "fm-teardown.sh backend=orca: refuses incomplete worktree-only endpoint metadata before runtime dispatch"
}

test_secondmate_force_teardown_removes_orca_child_via_orca() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-child-parent"
  subhome="$TMP_ROOT/orca-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-worktree"
  child_id="orcachildz6"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-cleanup" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-cleanup"
  orca_case secondmate-child-cleanup
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-cleanup","path":"%s"}}}\n' "$childwt" > "$RESP/worktree.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  expect_code 0 "$rc" "forced secondmate teardown should remove Orca child work through Orca"$'\n'"$out"
  assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f''term-child-cleanup'$'\x1f''--json' \
    "child cleanup did not close the recorded Orca terminal"
  assert_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm'$'\x1f''--worktree'$'\x1f''id:wt-child-cleanup'$'\x1f''--force'$'\x1f''--json' \
    "child cleanup did not remove the Orca worktree through orca worktree rm"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close'$'\x1f''--terminal'$'\x1f'"fm-$child_id" \
    "child cleanup closed the stable alias instead of the Orca terminal"
  assert_absent "$home/state/domain.meta" "parent metadata should be removed after forced teardown"
  pass "fm-teardown.sh --force: removes Orca secondmate children through Orca"
}

test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch() {
  local home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-mismatch-parent"
  subhome="$TMP_ROOT/orca-child-mismatch-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-mismatch-worktree"
  other_wt="$TMP_ROOT/orca-child-mismatch-other-worktree"
  child_id="orcachildmismatchz1"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-mismatch" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-mismatch"
  orca_case secondmate-child-mismatch
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-mismatch","path":"%s"}}}\n' "$other_wt" > "$RESP/1.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown should refuse mismatched Orca child id/path"
  assert_contains "$out" "not inspected worktree" \
    "mismatched Orca child worktree path refusal should name the mismatch"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
    "refused mismatched Orca child cleanup should not close terminals"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "refused mismatched Orca child cleanup should not remove worktrees"
  assert_present "$home/state/domain.meta" "refused forced secondmate teardown should preserve parent metadata"
  pass "fm-teardown.sh --force: refuses Orca child id/path mismatches"
}

run_secondmate_child_identity_change_case() {
  local change_show=$1 home subhome childproj childwt other_wt child_id neutral out rc
  home="$TMP_ROOT/orca-child-change-$change_show-parent"
  subhome="$TMP_ROOT/orca-child-change-$change_show-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-child-change-$change_show-worktree"
  other_wt="$TMP_ROOT/orca-child-change-$change_show-other"
  child_id="orcachildchange${change_show}z"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  git -C "$childproj" worktree add --quiet -b "fm/$child_id-other" "$other_wt"
  touch "$childwt/.fm-grok-turnend"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca child identity change (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "terminal=term-child-change-$change_show" "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-child-change-$change_show"
  orca_case "secondmate-child-change-$change_show"
  : > "$RESP/use-show-sequence"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-change-%s","path":"%s"}}}\n' \
    "$change_show" "$childwt" > "$RESP/worktree.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-child-change-%s","path":"%s"}}}\n' \
    "$change_show" "$other_wt" > "$RESP/show-$change_show.out"
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a changed child identity at boundary $change_show"
  assert_not_contains "$(cat "$LOG")" $'orca\x1f''worktree'$'\x1f''rm' \
    "changed child identity at boundary $change_show removed a worktree"
  if [ "$change_show" -eq 3 ]; then
    assert_not_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
      "changed child identity closed the endpoint before fresh verification"
    assert_present "$childwt/.fm-grok-turnend" \
      "changed child identity removed hooks before endpoint verification"
  else
    assert_contains "$(cat "$LOG")" $'orca\x1f''terminal'$'\x1f''close' \
      "child identity fixture did not reach endpoint cleanup before boundary $change_show"
  fi
  if [ "$change_show" -eq 4 ]; then
    assert_present "$childwt/.fm-grok-turnend" \
      "changed child identity removed hooks before fresh verification"
  fi
  if [ "$change_show" -eq 5 ]; then
    assert_absent "$childwt/.fm-grok-turnend" \
      "child identity fixture did not reach hook cleanup before worktree verification"
  fi
  assert_present "$home/state/domain.meta" \
    "changed child identity removed parent metadata"
  assert_present "$childwt" "changed child identity removed the recorded child worktree"
  assert_present "$other_wt" "changed child identity removed the redirected child worktree"
}

test_secondmate_child_identity_is_revalidated_at_each_boundary() {
  run_secondmate_child_identity_change_case 3
  run_secondmate_child_identity_change_case 4
  run_secondmate_child_identity_change_case 5
  pass "fm-teardown.sh --force: revalidates Orca child identity at every cleanup boundary"
}

test_secondmate_force_teardown_refuses_partial_orca_child() {
  local home subhome childproj childwt child_id neutral out rc
  home="$TMP_ROOT/orca-partial-child-parent"
  subhome="$TMP_ROOT/orca-partial-child-secondmate"
  childproj="$subhome/projects/alpha"
  childwt="$TMP_ROOT/orca-partial-child-worktree"
  child_id="orcapartialz9"
  mkdir -p "$home/state" "$home/data" "$subhome/state" "$subhome/projects"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  fm_git_worktree "$childproj" "$childwt" "fm/$child_id"
  fm_write_meta "$home/state/domain.meta" \
    "window=firstmate:fm-domain" "worktree=$subhome" "project=$subhome" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$subhome" "projects=alpha"
  printf '%s\n' "- domain - Orca partial child cleanup (home: $subhome; scope: orca cleanup; projects: alpha; added 2026-07-03)" \
    > "$home/data/secondmates.md"
  fm_write_meta "$subhome/state/$child_id.meta" \
    "window=fm-$child_id" "endpoint_task_id=$child_id" \
    "worktree=$childwt" "project=$childproj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-partial-child"
  orca_case secondmate-partial-child-cleanup
  add_tmux_fake "$FB"
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  set +e
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" domain --force 2>&1 )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "forced secondmate teardown accepted a child with no terminal identity"
  assert_contains "$out" "missing terminal" "partial child refusal did not explain the incomplete endpoint"
  [ ! -s "$LOG" ] || fail "partial child refusal dispatched to Orca or tmux"
  assert_present "$home/state/domain.meta" "partial child refusal removed parent metadata"
  assert_present "$subhome/state/$child_id.meta" "partial child refusal removed child metadata"
  pass "fm-teardown.sh --force: refuses partial Orca secondmate children before runtime dispatch"
}

test_dispatcher_sources_orca_and_routes_primitives() {
  local out
  orca_case dispatch
  printf '{"result":{"terminal":{"tail":["via dispatch"]}}}\n' > "$RESP/1.out"
  out=$( PATH="$FB:$PATH" FM_ORCA_LOG="$LOG" FM_ORCA_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate orca; fm_backend_capture orca term-123 9' "$ROOT" )
  [ "$out" = "via dispatch" ] || fail "dispatcher should route capture to the Orca adapter, got '$out'"
  pass "fm-backend dispatcher: accepts orca and routes capture through bin/backends/orca.sh"
}

case "${FM_BACKEND_ORCA_FOCUSED_TEST:-}" in
  '') ;;
  teardown-landing-replay)
    test_ship_teardown_refuses_orca_missing_worktree_path
    test_ship_teardown_replays_exact_orca_landing_proof
    test_ship_teardown_rejects_replacement_orca_landing_proof
    test_ship_teardown_rejects_redirected_orca_landing_replay
    test_ship_teardown_rejects_reused_orca_landing_replay
    test_ship_teardown_rejects_unavailable_orca_landing_replay
    test_ship_teardown_removes_orca_worktree_when_id_path_matches
    exit
    ;;
  teardown-identity-order)
    test_orca_identity_precedes_all_teardown_side_effects
    exit
    ;;
  teardown-identity-lifetime)
    test_orca_identity_is_revalidated_at_destructive_boundaries
    test_secondmate_child_identity_is_revalidated_at_each_boundary
    exit
    ;;
  teardown-cleanup-failures)
    test_orca_cleanup_refusals_precede_destructive_teardown
    test_teardown_retries_after_orca_remove_failures
    test_orca_rechecks_safety_after_process_cleanup
    test_ship_teardown_removes_orca_worktree_when_id_path_matches
    exit
    ;;
  teardown-scout)
    test_scout_teardown_removes_orca_worktree_via_helper
    exit
    ;;
  *) fail "unknown focused Orca backend test: $FM_BACKEND_ORCA_FOCUSED_TEST" ;;
esac

test_capture_reads_terminal_tail_json
test_capture_falls_back_to_text_fields
test_capture_fails_on_orca_error_json
test_runtime_check_accepts_ready_orca_status
test_runtime_check_refuses_unready_orca_status
test_send_text_submit_verifies_empty_composer_after_enter
test_send_text_submit_borderless_claude_confirms
test_composer_state_stale_banner_never_wins
test_send_text_submit_retries_when_composer_stays_pending
test_composer_state_popup_placeholder_fill_is_pending
test_composer_state_bare_shell_prompt_is_unknown
test_send_text_submit_popup_autocomplete_requires_second_enter
test_send_literal_constructs_non_enter_send
test_send_text_submit_reports_send_failed
test_send_helpers_reject_orca_error_json
test_send_key_enter_and_interrupt
test_send_key_refuses_unknown_key
test_send_key_refuses_escape_until_supported
test_kill_is_best_effort_close
test_remove_worktree_refuses_empty_id
test_remove_worktree_rejects_orca_error_json
test_worktree_path_resolves_id
test_dispatcher_sources_orca_and_routes_primitives
test_json_get_ignores_undocumented_terminal_id_shapes
test_worktree_and_terminal_helpers_parse_json
test_worktree_create_removes_worktree_when_path_missing
test_spawn_preserves_orca_metadata_when_pathless_worktree_cleanup_fails
test_spawn_writes_orca_metadata_and_launches_harness
test_spawn_refuses_orca_secondmate_before_home_mutation
test_spawn_refuses_orca_when_runtime_not_ready
test_spawn_refuses_orca_nonisolated_worktree
test_spawn_removes_orca_worktree_when_terminal_create_fails
test_spawn_preserves_orca_metadata_when_abort_cleanup_fails
test_spawn_releases_orca_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_orca_meta
test_peek_and_crew_state_fail_closed_on_orca_error_json
test_target_exists_rejects_orca_error_json
test_scout_teardown_removes_orca_worktree_via_helper
test_scout_teardown_refuses_orca_id_path_mismatch
test_teardown_removes_orca_worktree_when_path_missing
test_teardown_retries_after_orca_remove_failures
test_orca_cleanup_refusals_precede_destructive_teardown
test_orca_rechecks_safety_after_process_cleanup
test_scout_teardown_refuses_orca_missing_report_when_path_missing
test_ship_teardown_refuses_orca_missing_worktree_path
test_ship_teardown_replays_exact_orca_landing_proof
test_ship_teardown_rejects_replacement_orca_landing_proof
test_ship_teardown_rejects_redirected_orca_landing_replay
test_ship_teardown_rejects_reused_orca_landing_replay
test_ship_teardown_rejects_unavailable_orca_landing_replay
test_ship_teardown_removes_orca_worktree_when_id_path_matches
test_ship_teardown_refuses_orca_unresolvable_worktree_id
test_ship_teardown_refuses_orca_id_path_mismatch
test_orca_identity_precedes_all_teardown_side_effects
test_orca_identity_is_revalidated_at_destructive_boundaries
test_teardown_refuses_orca_missing_worktree_id
test_teardown_refuses_orca_worktree_without_terminal_handle
test_secondmate_force_teardown_removes_orca_child_via_orca
test_secondmate_force_teardown_refuses_orca_child_id_path_mismatch
test_secondmate_child_identity_is_revalidated_at_each_boundary
test_secondmate_force_teardown_refuses_partial_orca_child
