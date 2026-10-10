#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the bounded foreground checkpoint
# and repeated Stop-continuation behavior that strict successor continuity uses.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
STOP_PROJECT="$LAB/stop-project"
STOP_PAYLOADS="$STOP_PROJECT/.codex/stop-repeat.payloads"
TMUX_SERVER="fm-codex-continuity-$$"
TMUX_SESSION=codex-stop-repeat
CODEX_VERSION=$(codex --version)

cleanup() {
  tmux -L "$TMUX_SERVER" kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After the checkpoint returns, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the real foreground checkpoint result"
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

command -v tmux >/dev/null 2>&1 || fail "tmux not found for the interactive Codex Stop probe"
mkdir -p "$STOP_PROJECT/.codex"
git init -q "$STOP_PROJECT"
cat > "$STOP_PROJECT/AGENTS.md" <<'EOF'
Return the exact word DONE and do not call tools.
EOF
cat > "$STOP_PROJECT/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .codex/stop-repeat.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
cat > "$STOP_PROJECT/.codex/stop-repeat.sh" <<'EOF'
#!/usr/bin/env bash
set -u

payload=$(cat)
count_file=.codex/stop-repeat.count
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$payload" >> .codex/stop-repeat.payloads
if [ "$count" -le 2 ]; then
  printf 'continuity probe %s: return DONE again\n' "$count" >&2
  exit 2
fi
printf '{}\n'
EOF
chmod +x "$STOP_PROJECT/.codex/stop-repeat.sh"
git -C "$STOP_PROJECT" add AGENTS.md .codex/hooks.json .codex/stop-repeat.sh
git -C "$STOP_PROJECT" -c user.name=fmtest -c user.email=fmtest@example.invalid \
  commit -qm init

tmux -L "$TMUX_SERVER" new-session -d -s "$TMUX_SESSION" -c "$STOP_PROJECT" -x 120 -y 40 \
  codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust \
  --no-alt-screen -c 'model_reasoning_effort="low"' \
  'Return the exact word DONE and do not call tools.'

# A fresh git root still receives Codex's directory-trust dialog even in YOLO
# mode and with hook-trust bypassed.
for _ in $(seq 1 80); do
  pane=$(tmux -L "$TMUX_SERVER" capture-pane -p -t "$TMUX_SESSION" -S -30 2>/dev/null || true)
  if printf '%s\n' "$pane" | grep -F 'Do you trust the contents of this directory?' >/dev/null; then
    tmux -L "$TMUX_SERVER" send-keys -t "$TMUX_SESSION" Enter
    break
  fi
  [ -e "$STOP_PROJECT/.codex/stop-repeat.count" ] && break
  sleep 0.25
done

for _ in $(seq 1 240); do
  [ "$(cat "$STOP_PROJECT/.codex/stop-repeat.count" 2>/dev/null || true)" = 3 ] && break
  tmux -L "$TMUX_SERVER" has-session -t "$TMUX_SESSION" 2>/dev/null \
    || fail "Codex interactive Stop probe exited before three hook invocations"
  sleep 0.5
done
[ "$(cat "$STOP_PROJECT/.codex/stop-repeat.count" 2>/dev/null || true)" = 3 ] \
  || fail "Codex did not honor two consecutive Stop continuations"
[ "$(wc -l < "$STOP_PAYLOADS" | tr -d ' ')" = 3 ] \
  || fail "Codex Stop probe did not capture exactly three payloads"
first_active=$(sed -n '1p' "$STOP_PAYLOADS" | jq -r '.stop_hook_active')
second_active=$(sed -n '2p' "$STOP_PAYLOADS" | jq -r '.stop_hook_active')
third_active=$(sed -n '3p' "$STOP_PAYLOADS" | jq -r '.stop_hook_active')
first_turn=$(sed -n '1p' "$STOP_PAYLOADS" | jq -r '.turn_id')
second_turn=$(sed -n '2p' "$STOP_PAYLOADS" | jq -r '.turn_id')
third_turn=$(sed -n '3p' "$STOP_PAYLOADS" | jq -r '.turn_id')
[ "$first_active|$second_active|$third_active" = 'false|true|true' ] \
  || fail "Codex Stop payload progression was not false,true,true"
[ -n "$first_turn" ] && [ "$first_turn" = "$second_turn" ] && [ "$first_turn" = "$third_turn" ] \
  || fail "Codex repeated Stop continuations did not retain one turn_id"

tmux -L "$TMUX_SERVER" send-keys -t "$TMUX_SESSION" -l '/quit'
sleep 1.3
tmux -L "$TMUX_SERVER" send-keys -t "$TMUX_SESSION" Enter
for _ in $(seq 1 40); do
  tmux -L "$TMUX_SERVER" has-session -t "$TMUX_SESSION" 2>/dev/null || break
  sleep 0.25
done
tmux -L "$TMUX_SERVER" has-session -t "$TMUX_SESSION" 2>/dev/null \
  && fail "Codex Stop probe did not exit through /quit"

printf 'ok - %s live E2E preserved the foreground checkpoint and honored Stop payloads false,true,true for one turn_id\n' "$CODEX_VERSION"
