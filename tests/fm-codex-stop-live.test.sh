#!/usr/bin/env bash
# Opt-in real Codex Stop proof in a refuse-default Herdr lab only.
set -eu
[ "${FM_CODEX_STOP_LIVE:-0}" = 1 ] || { echo 'skip: set FM_CODEX_STOP_LIVE=1'; exit 0; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v codex >/dev/null || { echo 'not ok - Codex is not installed'; exit 1; }
HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
mkdir -p "$ROOT/.no-mistakes/live-evidence"
LAB=$(mktemp -d "$ROOT/.no-mistakes/live-evidence/codex-stop.XXXXXX")
SEAT="$LAB/seat"
export FM_HERDR_LAB_STATE_DIR="$LAB/tripwire"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name codex-stop-live)
cleanup() { rm -f "$LAB/codex/auth.json"; "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; }
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
run() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
mkdir -p "$SEAT"/{state,config,data,.codex} "$LAB/codex" "$LAB/tmp"
# Keep credentials opaque and all harness writes inside the isolated lab.
cp "${CODEX_HOME:-$HOME/.codex}/auth.json" "$LAB/codex/auth.json"
printf '[features]\nhooks = true\n[projects."%s"]\ntrust_level = "trusted"\n' "$SEAT" > "$LAB/codex/config.toml"
cp -R "$ROOT/bin" "$SEAT/bin"
git init -q "$SEAT"
printf 'No tools. Reply READY initially and CONTINUED to Stop feedback. This is a bounded isolated test.\n' > "$SEAT/AGENTS.md"
: > "$SEAT/state/work.meta"
cat > "$SEAT/.codex/hooks.json" <<'EOF'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ./stop.sh # fm-turnend-guard.sh --codex","timeout":240}]}]}}
EOF
cat > "$SEAT/stop.sh" <<'EOF'
#!/usr/bin/env bash
payload=$(cat)
n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > count
printf 'begin %s\n' "$n" >> timeline
[ "$n" -le 3 ] || exit 0
bin/fm-lock.sh >> timeline 2>&1 || exit 1
printf '%s' "$payload" | bin/fm-turnend-guard.sh --codex 2>"result-$n"
rc=$?
cat "result-$n" >&2
# This fixture owns the synthetic event; model work cannot obscure the hook test.
bin/fm-wake-drain.sh > drain 2>&1
ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' drain)
[ -z "$ack" ] || bash -c "$ack" >> timeline 2>&1
printf 'end %s rc=%s\n' "$n" "$rc" >> timeline
exit "$rc"
EOF
cat > "$SEAT/start.sh" <<EOF
#!/usr/bin/env bash
cd '$SEAT'
export CODEX_HOME='$LAB/codex' FM_HOME='$SEAT' FM_ROOT_OVERRIDE='$SEAT' TMPDIR='$LAB/tmp'
export FM_PRIMARY_HARNESS=codex FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CODEX_WATCH_CHECKPOINT=180
exec codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust --no-alt-screen 'Reply READY. On Stop feedback reply CONTINUED without tools.'
EOF
chmod +x "$SEAT/start.sh"
result=$(run workspace create --cwd "$SEAT" --label codex-stop-proof --no-focus)
pane=$(printf '%s' "$result" | jq -er '.result.root_pane.pane_id')
run pane run "$pane" "$SEAT/start.sh"
fail() { echo "not ok - $(codex --version): $*; evidence=$LAB" >&2; exit 1; }
wait_for() {
  local needle=$1 budget=$2 start=$SECONDS screen
  while ! grep -Fq "$needle" "$SEAT/timeline" 2>/dev/null; do
    [ $((SECONDS-start)) -lt "$budget" ] || fail "timeout waiting for $needle"
    screen=$(run pane read "$pane" --source visible --lines 30)
    if printf '%s' "$screen" | grep -Fq 'Trust and continue'; then run pane send-keys "$pane" Enter; fi
    sleep 1
  done
}
wait_for 'begin 2' 240
grep -Fq 'checkpoint: quiet' "$SEAT/result-1" || fail '180-second quiet expiry did not request continuation'
printf 'done: synthetic article ready\n' > "$SEAT/state/article.status"
wait_for 'begin 3' 45
grep -Fq 'signal:' "$SEAT/result-2" || fail 'post-turn event did not request continuation'
start=$SECONDS
while [ ! -f "$SEAT/state/.watch.lock/pid" ]; do
  [ $((SECONDS-start)) -lt 15 ] || fail 'third Stop acquired no watcher'
  sleep 0.1
done
watcher=$(cat "$SEAT/state/.watch.lock/pid")
run pane send-keys "$pane" Escape
sleep 5
kill -0 "$watcher" 2>/dev/null && fail 'deliberate interruption left its watcher alive'
[ "$(cat "$SEAT/count")" = 3 ] || fail 'deliberate interruption resurrected a successor'
rm -f "$LAB/codex/auth.json"
echo "ok - $(codex --version): real Stop quiet 180s, post-turn event and cancellation; evidence=$LAB"
