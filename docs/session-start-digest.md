# Session-start digest stages

`bin/fm-session-start.sh`'s header is the single owner of composed commands, ordering, and digest contents; this doc explains the stage-by-stage breakdown of what it prints so `AGENTS.md` does not have to.

1. **Lock** - acquires the per-home session lock before anything mutates shared state, then starts the deferred network stage.
2. **Bootstrap** - detect-only checks (tool/version, worktree-tangle, harness override, dispatch-profile validation, backlog-backend status) always run silently unless actionable; a lock-refused tangle check is read-only advisory with no repair command.
   The MUTATING sweeps (stale Herdr cleanup, non-executing legacy PR-check migration, fleet sync, secondmate convergence and liveness, pending remote handoff retry, Relay artifact writes) run only when this session holds the lock, with the network-dependent ones deferred rather than run here.
   Secondmate liveness relaunches only from recovery-grade `dead`/`missing` states, preserves ambiguous, unreadable, or unreachable remote targets, and reports skipped or failed guarantees as `SECONDMATE_LIVENESS:` lines (`bin/fm-bootstrap.sh`; `docs/remote-secondmates.md`).
3. **Wake queue** - when locked, presents the durable wake queue's raw records as this turn's first work queue, optionally annotated by every status event still unread at the presentation cursor; the annotation never replaces the raw record or current-state reconciliation.
   Presented records stay durable until the handling turn runs the generation-bound acknowledgement the drain prints.
   The same drain also prints a bounded `OPEN DECISIONS` section for open durable decisions even when the queue is empty, an unbounded `UNREAD STATUS` section for every still-unread `note:` line and pending-reply resolution (not re-printed after), and a bounded `RECORD DIVERGENCE` section naming any captain call the status log reads as resolved while its backlog task is still held.
   Nothing is closed automatically; reconcile all three sections before continuing, with `captain-hold-lifecycle` owning record-divergence reconciliation.
   A lock-refused session leaves the queue untouched and prints tangle/watcher-liveness alarms in read-only advisory mode only.
4. **Supervision operating instructions** - one operating block for the detected primary harness plus the read-once contract governing it, rendered by `bin/fm-supervision-instructions.sh` from `docs/supervision-protocols/`; the script itself never starts supervision.
5. **Fleet-state digest** - the compact backlog listing, every `state/<id>.meta`, a bounded status tail per task (wake-EVENT history, not current state, full log path given), the `state/.afk` flag, and one cheap alive/dead endpoint read per task.
   That liveness line is a fast presence check only; read actual current state with `bin/fm-crew-state.sh <id>` when it matters.
6. **Network checks** - the deferred stage's result, or an explicit statement of what is unconfirmed; a read-only session runs none and says so.
7. **Context digest and next step** - full contents of `data/projects.md`, `data/secondmates.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, each delimited, then the closing reminder.
   A missing file prints an explicit `ABSENT` marker (never confused with empty-but-present): `captain.md` absent means built-in defaults, `projects.md` absent means rebuild from `projects/` clones, etc.
   The closing reminder points back to the supervision block and keeps only the lock, afk, Relay, and read-once reminders.
