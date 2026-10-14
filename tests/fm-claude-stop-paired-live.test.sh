#!/usr/bin/env bash
# Real unchanged Claude asyncRewake delivery paired with the Codex Stop proof.
set -eu
if [ "${FM_CLAUDE_STOP_PAIRED_LIVE:-0}" != 1 ]; then
 echo 'skip: set FM_CLAUDE_STOP_PAIRED_LIVE=1 for the Claude native negative control'
 exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EVIDENCE="$ROOT/.no-mistakes/claude-stop-paired-live"
PROJECT="$EVIDENCE/project-$$"
mkdir -p "$PROJECT/.claude" "$PROJECT/state" "$PROJECT/config"
git init -q "$PROJECT"
cp -R "$ROOT/bin" "$PROJECT/bin"
printf '%s\n' 'This is an isolated native hook experiment. Follow the prompt exactly.' > "$PROJECT/AGENTS.md"
# The Stop registration and both production Claude entrypoints are unchanged.
python3 - "$ROOT" "$PROJECT" <<'PY'
import json,sys
root,p=sys.argv[1:]
s=json.load(open(root+'/.claude/settings.json'))
s['hooks']={'SessionStart':[{'hooks':[{'type':'command','command':'"$CLAUDE_PROJECT_DIR"/bin/fm-lock.sh','timeout':10}]}],'Stop':s['hooks']['Stop']}
open(p+'/.claude/settings.json','w').write(json.dumps(s))
PY
# A tripwire fixture makes any accidental Codex dispatch observable.
cat > "$PROJECT/bin/fm-codex-stop.sh" <<'TRIPWIRE'
#!/usr/bin/env bash
printf 'unexpected Codex invocation\n' >> "$FM_HOME/codex-invoked"
exit 99
TRIPWIRE
cat > "$PROJECT/lab-handle.sh" <<'HANDLE'
#!/usr/bin/env bash
set -eu
bin/fm-wake-drain.sh > drained 2> drain-errors
cat drained drain-errors
sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\).*$/\1/p' drain-errors)
generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' drain-errors)
[ -n "$sequence" ] && [ -n "$generation" ]
bin/fm-wake-drain.sh --ack-through "$sequence" --recovery-generation "$generation"
rm "$FM_HOME/state/task.meta"
printf '%s handled\n' "$(date +%s)" >> handled
HANDLE
: > "$PROJECT/state/task.meta"
HERDR_LAB_HELPER='/Users/shin/Documents/Project/firstmate/bin/fm-herdr-lab.sh'
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-native-stop-minimal)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab workspace create --cwd "$PROJECT" --label claude-stop > "$EVIDENCE/workspace.json"
pane=$(jq -r '.result.root_pane.pane_id' "$EVIDENCE/workspace.json")
lab pane send-text "$pane" "cd '$PROJECT' && env -u CLAUDECODE FM_HOME='$PROJECT' FM_ROOT_OVERRIDE='$PROJECT' FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_POLL=1 claude --allowedTools Bash --effort low 'First reply exactly READY without tools. Whenever Stop hook feedback arrives, run bash lab-handle.sh once, then reply exactly HANDLED. Do nothing else. Do not launch a watcher.'"
lab pane send-keys "$pane" Enter
wait_condition() {
 local condition=$1 seconds=$2 deadline trusted=0 imports=0
 deadline=$(( $(date +%s) + seconds ))
 until eval "$condition"; do
  lab pane read "$pane" --lines 50 > "$EVIDENCE/pane.txt"
  if [ "$trusted" -eq 0 ] && grep -q 'Yes, I trust this folder' "$EVIDENCE/pane.txt"; then
   cp "$EVIDENCE/pane.txt" "$EVIDENCE/trust-prompt.txt"
   if grep -q '❯ No, exit' "$EVIDENCE/pane.txt"; then
    lab pane send-keys "$pane" Down
    sleep 0.5
    lab pane read "$pane" --lines 18 > "$EVIDENCE/trust-selected.txt"
    grep -q '❯ Yes, I trust this folder' "$EVIDENCE/trust-selected.txt" || { echo 'not ok - trust selection did not move'; exit 1; }
   fi
   lab pane send-keys "$pane" Enter
   trusted=1
  fi
  if [ "$imports" -eq 0 ] && grep -q '❯ No, disable external imports' "$EVIDENCE/pane.txt"; then
   lab pane send-keys "$pane" Enter
   imports=1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then cat "$EVIDENCE/pane.txt" >&2; echo "not ok - timed out: $condition" >&2; exit 1; fi
  sleep 1
 done
}
wait_condition '[ -s "$PROJECT/state/.watch.lock/pid" ] && [ -f "$PROJECT/state/.last-watcher-beat" ]' 120
printf '%s watcher-start\n' "$(date +%s)" >> "$PROJECT/timeline"
printf 'done: native Claude post-turn event\n' > "$PROJECT/state/event.status"
printf '%s event-written\n' "$(date +%s)" >> "$PROJECT/timeline"
wait_condition '[ -s "$PROJECT/handled" ]' 120
wait_condition '[ ! -e "$PROJECT/state/.watch.lock" ]' 15
[ ! -e "$PROJECT/codex-invoked" ] || { echo 'not ok - Claude invoked Codex adapter'; exit 1; }
[ ! -e "$PROJECT/state/.codex-stop.json" ] || { echo 'not ok - Claude created Codex handling state'; exit 1; }
[ ! -s "$PROJECT/state/.wake-queue" ] || { echo 'not ok - model did not acknowledge event'; exit 1; }
claude --version
cat "$PROJECT/timeline" "$PROJECT/handled"
cat "$PROJECT/state/.claude-autoarm-epoch"
echo 'ok - unchanged Claude asyncRewake delivered post-turn event without Codex invocation or handling state'
