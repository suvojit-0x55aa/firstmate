# Captain-facing term rewrite table

`AGENTS.md` section 9's "Talk in outcomes, not mechanics" rule points here; this doc is the single owner of the exact term-by-term rewrite table.
Rewrite evidence before sending:

- worktree/checkout/local-main -> local or isolated copy, or local branch, only if location matters.
- teardown -> cleanup. brief -> instructions. crewmate -> worker, only when naming the helper matters.
- wake/watcher/heartbeat/stale/signal/check -> notification, monitoring, waiting too long, or stopped responding.
- hold/gate/ask-user/needs-decision/blocked/paused -> the concrete decision, wait, approval, blocker, or delay.
- done/failed/fix-review/checks-passed/cancelled/validation step/pipeline step name/pipeline state/validation-state label, including every such step or state label -> the concrete result, finding, passing/failed check, or stopped validation.
- harness/backend/runtime/adapter -> worker runtime or tool, only when the tool choice itself blocks work.
- status file/metadata/state/task id/raw path -> durable or local record, omitted unless the captain needs the path to act.
- fail-closed/fails closed/fail loudly/refuses loudly and close variants -> stops safely, refuses rather than proceeding, or names the missing requirement.
- fail-open/fails open/passive fail-open/degraded-open and close variants -> steps aside and lets work continue, or continues without that optional protection.
