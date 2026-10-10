# No-mistakes validation lifecycle

`AGENTS.md` section 7's "Validate" step points here; this doc is the single owner of pipeline ownership, requirement-routing, ask-user decision delivery, and run-step-judgment detail for an active no-mistakes run.
`docs/validation-invalidation-recovery.md` separately owns the abort, custody-recovery, and rebase procedure for the one case that completely invalidates work already in validation.

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, via the `harness-adapters` invocation.
That worker drives the pipeline and owns every `no-mistakes axi run`/`respond` call; firstmate never calls `axi respond` for a crew-owned run.
Once validation starts, route new requirements to follow-up work rather than expanding the task, unless a requirement completely invalidates the work in validation.
The smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate stay within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

An ask-user finding returns as `needs-decision`; load `ask-user-authority` and decide or escalate per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the attributed run step through `bin/fm-crew-state.sh`, not shell liveness or the last status event: running, fixing, or CI is working; parked approval or fix-review needs the active gate's help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting mid-run outside the invalidation procedure in `docs/validation-invalidation-recovery.md` duplicates pipeline ownership; steer it back to the gate flow.
The worker reports the PR when CI first goes green, not after merge monitoring finishes.
