#!/usr/bin/env bash
# Credentialed native Codex Stop proof in a guarded non-default Herdr session.
# FM_CODEX_STOP_LIVE=1 tests/fm-codex-stop-live.test.sh
# Artifacts remain in .no-mistakes/codex-stop-live for review.
# Automatic project integration remains suspended; this guard installs an
# isolated fixture registration for the dormant Stop adapter.
# shellcheck disable=SC2016 # wait_condition evaluates these expressions on each poll
set -eu
if [ "${FM_CODEX_STOP_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_CODEX_STOP_LIVE=1 for native Codex Stop proof'
  exit 0
fi
printf '%s\n' '# Codex automatic project-hook integration is suspended; testing the dormant Stop adapter through an isolated fixture registration.'
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EVIDENCE="$ROOT/.no-mistakes/codex-stop-live"
PROJECT="$EVIDENCE/project-$$"
mkdir -p "$PROJECT/.codex" "$PROJECT/state" "$PROJECT/config"
git init -q "$PROJECT"
cp -R "$ROOT/bin" "$PROJECT/bin"
printf '%s\n' 'This is an isolated native hook experiment. Follow the prompt exactly.' > "$PROJECT/AGENTS.md"
python3 - "$ROOT/.codex/hooks.json" "$PROJECT" <<'PY'
import json,sys
tracked_path,p=sys.argv[1:]
with open(tracked_path) as stream:
    tracked=json.load(stream)
if tracked != {'hooks': {}}:
    raise SystemExit('tracked Codex hooks must remain semantically empty during suspended integration')
f=p+'/.codex/hooks.json'
stop_command=r'''bash -lc 'payload=$(cat 2>/dev/null || true); [ -n "$payload" ] || exit 0; command -v jq >/dev/null 2>&1 || exit 0; root=$(pwd -P) || exit 0; [ -x "$root/bin/fm-turnend-guard.sh" ] || exit 0; [ -f "$root/AGENTS.md" ] || exit 0; [ -f "$root/.codex/hooks.json" ] || exit 0; jq -e "any(.hooks.Stop[]?.hooks[]?.command?; type == \"string\" and contains(\"fm-turnend-guard.sh --codex\"))" "$root/.codex/hooks.json" >/dev/null 2>&1 || exit 0; printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh" --codex' '''.strip()
s={'hooks': {
    'SessionStart': [{'hooks': [{'type': 'command', 'command': 'bin/fm-lock.sh', 'timeout': 10}]}],
    'Stop': [{'hooks': [{'type': 'command', 'command': stop_command, 'timeout': 600}]}],
}}
original=s['hooks']['Stop'][0]['hooks'][0]['command']
open(p+'/stop-command','w').write(original)
s['hooks']['Stop'][0]['hooks'][0]['command']='bash stop-observe.sh # fm-turnend-guard.sh --codex'
with open(f,'w') as stream:
    json.dump(s,stream)
PY
# The registration's identity check recognizes the actual tracked guard name.
cat > "$PROJECT/stop-observe.sh" <<'HOOK'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> stop-payloads
printf '%s stop-start\n' "$(date +%s)" >> timeline
count=$(wc -l < stop-payloads | tr -d ' ')
printf '%s' "$payload" | bash -c "$(cat stop-command)" 2> "stop-result.$count"
rc=$?
cat "stop-result.$count" >&2
printf '%s stop-end %s\n' "$(date +%s)" "$rc" >> timeline
exit "$rc"
HOOK
cat > "$PROJECT/lab-handle.sh" <<'HANDLE'
#!/usr/bin/env bash
set -eu
printf '%s handled\n' "$(date +%s)" >> handled
bin/fm-wake-drain.sh > drained 2> drain-errors
cat drained drain-errors
sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' drain-errors)
generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' drain-errors)
if [ -n "$sequence" ] && [ -n "$generation" ]; then
 bin/fm-wake-drain.sh --ack-through "$sequence" --recovery-generation "$generation"
fi
HANDLE
: > "$PROJECT/state/task.meta"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-native-stop-minimal)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab workspace create --cwd "$PROJECT" --label codex-stop > "$EVIDENCE/workspace.json"
pane=$(jq -r '.result.root_pane.pane_id' "$EVIDENCE/workspace.json")
lab pane send-text "$pane" "cd '$PROJECT' && env -u CLAUDECODE FM_HOME='$PROJECT' FM_ROOT_OVERRIDE='$PROJECT' FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust --no-alt-screen -c 'model_reasoning_effort=\"low\"' 'First reply exactly READY without tools. Whenever Stop hook feedback arrives, run bash lab-handle.sh once, then reply exactly HANDLED. Do nothing else. Do not launch a watcher.'"
lab pane send-keys "$pane" Enter
wait_condition() {
 local condition=$1 seconds=$2 deadline
 deadline=$(( $(date +%s) + seconds ))
 until eval "$condition"; do
  lab pane read "$pane" --lines 45 > "$EVIDENCE/pane.txt"
  if grep -Eq 'Trust this folder\?|Do you trust the contents' "$EVIDENCE/pane.txt"; then lab pane send-keys "$pane" Enter; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
   cat "$EVIDENCE/pane.txt" >&2
   printf 'not ok - timed out: %s\n' "$condition" >&2
   exit 1
  fi
  sleep 1
 done
}
watcher_healthy() {
 FM_HOME="$PROJECT" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$PROJECT/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watcher_healthy "$1/state" "$1/bin/fm-watch.sh" 300 "$1"' _ "$PROJECT"
}
wait_condition 'watcher_healthy' 90
printf '%s watcher-start\n' "$(date +%s)" >> "$PROJECT/timeline"
wait_condition '[ -s "$PROJECT/handled" ]' 240
first_start=$(awk '$2 == "stop-start" { print $1; exit }' "$PROJECT/timeline")
first_end=$(awk '$2 == "stop-end" { print $1; exit }' "$PROJECT/timeline")
case "$first_start" in ''|*[!0-9]*) echo 'not ok - first Stop start was not recorded' >&2; exit 1 ;; esac
case "$first_end" in ''|*[!0-9]*) echo 'not ok - first Stop end was not recorded' >&2; exit 1 ;; esac
quiet_seconds=$((first_end - first_start))
[ "$quiet_seconds" -ge 180 ] || { echo "not ok - first Stop renewed after only ${quiet_seconds}s" >&2; exit 1; }
grep -F 'quiet checkpoint elapsed; supervision is still needed' "$PROJECT/stop-result.1" >/dev/null \
  || { echo 'not ok - first Stop did not report a quiet checkpoint renewal' >&2; exit 1; }
printf '%s quiet-renewal-seconds\n' "$quiet_seconds" >> "$PROJECT/timeline"
# A second real Stop cycle proves delivery returned control to the model.
wait_condition '[ "$(wc -l < "$PROJECT/stop-payloads" | tr -d " ")" -ge 2 ] && watcher_healthy' 90
FM_HOME="$PROJECT" FM_STATE_OVERRIDE="$PROJECT/state" bash -c '. "$1"; fm_wake_append check native-lab "check: native post-turn event"' _ "$ROOT/bin/fm-wake-lib.sh"
printf '%s event-enqueued\n' "$(date +%s)" >> "$PROJECT/timeline"
wait_condition '[ "$(wc -l < "$PROJECT/handled" | tr -d " ")" -ge 2 ]' 90
wait_condition '[ "$(wc -l < "$PROJECT/stop-payloads" | tr -d " ")" -ge 3 ] && watcher_healthy' 90
watcher_pid=$(cat "$PROJECT/state/.watch.lock/pid")
watcher_identity=$(FM_STATE_OVERRIDE="$PROJECT/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher_pid")
watcher_still_alive() {
 local current
 kill -0 "$watcher_pid" 2>/dev/null || return 1
 current=$(FM_STATE_OVERRIDE="$PROJECT/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$watcher_pid") || return 1
 [ "$current" = "$watcher_identity" ]
}
lab pane send-keys "$pane" Escape
printf '%s deliberate-interrupt\n' "$(date +%s)" >> "$PROJECT/timeline"
wait_condition '! watcher_still_alive' 15
sleep 3
if watcher_healthy; then echo 'not ok - interruption resurrected watcher' >&2; exit 1; fi
[ "$(wc -l < "$PROJECT/handled" | tr -d ' ')" = 2 ] || { echo 'not ok - interruption delivered an extra continuation' >&2; exit 1; }
codex --version
cat "$PROJECT/timeline" "$PROJECT/handled"
printf 'ok - native Codex Stop delivered quiet renewal and post-turn event, then cancelled on Escape\n'
