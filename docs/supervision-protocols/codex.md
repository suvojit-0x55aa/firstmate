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
The adapter never acknowledges queued work and stands down on interruption, away mode, session replacement or no remaining need.
Claude retains its separate `asyncRewake` path.
