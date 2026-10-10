# Validation invalidation recovery

Exact procedure for `AGENTS.md` section 7's rule that only a current explicit captain instruction completely invalidating validated work keeps a task with the same worker instead of routing to follow-up or a replacement.

The worker cancels the run via no-mistakes axi's supported abort and confirms via axi status that it stopped before changing code, then follows `branch_sync.next_action`: use axi sync's guarded recovery only when its code is `recover_custody`, otherwise proceed only once structured status confirms ownership is already returned.
Custody recovery settles branch ownership, not content: replace the obsolete work from the correct pre-invalidation base rather than building on the recovered-but-obsolete head, and keep the obsolete run's own pipeline-fix commits out of what ships.
Apart from that one supported abort, never hand-edit, commit, restart, or start a second run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head.
