Mode: Codex native Stop continuation.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle all presented work, then run the exact `WAKE_ACK_REQUIRED` command it prints.
   Until acknowledgement, the work remains durable for replay after interruption.
2. Source `__FM_X_MODE_ENV__` first when Relay is active.
3. End the handling turn normally.
   The tracked Stop hook invokes `bin/fm-turnend-guard.sh --codex`, which delegates to `bin/fm-codex-stop.sh`.
4. The adapter owns the existing watcher while Stop waits and requests a native next turn on an actionable wake or a quiet checkpoint while supervision is still needed.
   Drain, handle and acknowledge on that next turn; its next Stop renews coverage.
5. Do not launch a manual checkpoint, background task, or second watcher.
   If the adapter reports a failure, inspect its registration and startup rather than substituting a yielded tool call.

`bin/fm-codex-stop.sh` owns the bounded continuation, cancellation and successor contract.
Its local owner answers live health challenges; stale records alone cannot certify supervision.
Its cycle admission charges bounded crew-state and worktree reads only for recorded workers that are not authoritatively dead, while still charging unseen signals, due remote reply recovery and the fixed safety reserves.
Retained metadata for a worker whose verified backend reports `dead` or `missing` therefore cannot consume the deadline as if that worker could repeatedly reach the watcher's expensive downstream classification paths; an ambiguous result or a backend without a verified agent-state classifier remains fully charged.
An exact-dead worker is suppressed only by its collision-free owner-identity notification receipt for the durable spawn incarnation; exact liveness or a verified busy verdict retires that receipt and ambiguous stale hashes so a later death surfaces once.
Due checks retain their individual timeout and run through a durable batch sized to the remaining cycle budget, so a large registered set completes over multiple watcher cycles instead of being admitted as one unbounded sweep.
Attaching to an existing watcher requires an exact current capability match for the check batch and timeout, cadence, classification and write timeouts, remote-send and inactive-reconcile budgets, admission guard, and deferred remote-observation mode.
The Stop-owned watcher defers remote pending-reply endpoint observation so that observation's network latency cannot consume the fixed Stop deadline; durable local reply evidence and the ordinary non-Codex observation path remain unchanged.
The adapter never acknowledges queued work and stands down on interruption, away mode, session replacement or no remaining need.
Claude retains its separate `asyncRewake` path.
