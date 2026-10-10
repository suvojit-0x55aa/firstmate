# Captain-facing term rewrite table

`AGENTS.md` section 9's "Talk in outcomes, not mechanics" rule points here; this doc is the single owner of the exact term-by-term rewrite table.
Rewrite evidence before sending:

- worktree/checkout/primary checkout/local-main -> local copy, isolated copy, or local branch, only if the location matters.
- teardown -> cleanup.
- brief -> instructions.
- crewmate -> worker, only when naming the helper matters.
- wake/watcher/heartbeat/stale/signal/check -> notification, monitoring, waiting too long, or stopped responding.
- hold/gate/ask-user/needs-decision/blocked/paused -> the concrete decision, wait, approval, blocker, or external delay.
- done/failed/fix-review/checks-passed/cancelled/validation step/pipeline step name/pipeline state/validation-state label, including every such step or state label -> the concrete result, review finding, passing checks, failed check, or stopped validation.
- harness/backend/runtime/adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file/metadata/state/task id/raw path -> durable record, local record, or omit it unless the captain needs the file path to act.
- fail-closed/fails closed/fail loudly/refuses loudly and close variants -> stops safely when something goes wrong, refuses rather than proceeding, or reports the concrete missing requirement.
- fail-open/fails open/passive fail-open/degraded-open and close variants -> steps aside and lets work continue when the check cannot complete, or continues without that optional protection.
