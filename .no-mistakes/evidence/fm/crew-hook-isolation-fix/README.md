# Crew isolation from the captain's global Claude Code config - live evidence

Branch `fm/crew-hook-isolation-fix`, HEAD `7687e1d`, base `2c621d4`.
Claude Code 2.1.259, real captain config (9 plugins incl. `oh-my-claudecode` and `i-have-adhd`).

## 1. What firstmate now types into a crewmate pane

`spawn-typed-launch-commands.txt` - captured live from `bin/fm-spawn.sh` driving a fake tmux
pane that records the literal `send-keys -l` payload. Every `claude` crewmate launch now carries
`--setting-sources project,local` immediately after `--dangerously-skip-permissions`; codex, grok
and opencode launches are byte-identical to before, and the `CLAUDE_CONFIG_DIR` forwarding case
still forwards.

## 2. The leak, before and after, with a real claude session

`live-before-fix.txt` / `live-after-fix.txt`. Identical scratch git project, identical probe prompt,
identical project-local `.claude/settings.local.json` turn-end hooks written with the real
`bin/fm-busy-event.sh` contract. The only difference is the flag.

| | before (no flag) | after (`--setting-sources project,local`) |
|---|---|---|
| claude exit (OAuth/keychain auth) | 0 | 0 |
| crewmate sees `ADHD MODE ACTIVE` (captain's global plugin hook text) | **PRESENT** | **ABSENT** |
| hooks registered from plugins | **34 hooks from 9 plugins** | **0 hooks from 0 plugins** |
| SessionEnd hooks that ran | peon-ping + 4 plugin hooks + the project turn-end hook | **only the project turn-end hook** |
| busy-state record after the turn | `seq=4 state=idle source=claude-hook event=session-end` | `seq=4 state=idle source=claude-hook event=session-end` |

`seq=4` means three hook events applied on top of fm-spawn's launch arm
(`user-prompt-submit` -> busy, `stop` -> idle, `session-end` -> idle), which is the exact turn-end
cycle `bin/fm-crew-state.sh` and the watcher depend on. It is unchanged by the flag.

`hook-registry-contrast.txt` is the trimmed side-by-side; `debug-before-fix.log` and
`debug-after-fix.log` are Claude Code's own `--debug-file` output for the two runs.

## 3. Documented residual

The probe still reports the residual the harness-adapters note describes: the flag suppresses
hooks, not the captain's static global `CLAUDE.md`/`rules/*.md` prose. The `ADHD MODE ACTIVE`
banner is hook-injected and is gone; static global prose is not covered by this flag and the
skill note says so.
