Mode: Codex synchronous Stop supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle its wakes, open decisions and unread status before running its exact `WAKE_ACK_REQUIRED` command.
2. The tracked Stop hook owns ordinary watcher continuity through `bin/fm-codex-stop.sh`.
   It parks on one singleton watcher and returns a native Codex continuation for an actionable close or a quiet checkpoint deadline.
3. On continuation, drain and handle the durable work; keep quiet intervals silent.
   The next Stop owns the successor, so do not manually launch a checkpoint after an ordinary wake.
4. A yielded unified-exec session or asynchronous hook does not provide post-turn wake delivery.
   Never end a turn treating either as durable supervision.
5. Failure only: inspect the reported session ownership or arm failure and the durable wake queue.
   `bin/fm-watch-checkpoint.sh` remains a bounded diagnostic foreground command, not the ordinary continuation owner.
6. Never use shell `&` or detached Codex background tasks to repair supervision.

`bin/fm-codex-stop.sh` owns timing, cancellation and session-ownership mechanics.
Other primary harnesses keep their own supervision adapters; away mode keeps its existing daemon ownership.
