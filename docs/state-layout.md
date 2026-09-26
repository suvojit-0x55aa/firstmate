# Data, config, and state record semantics

This doc owns the per-file semantics of every `data/`, `config/`, and `state/` record referenced from `AGENTS.md` section 2's top-level tree.
The top-level operational-home layout is owned by [`configuration.md`](configuration.md#operational-home-layout-and-state), not restated here.
`AGENTS.md` keeps only the top-level tree and pointers here; each producing script's own header and `--help` remain the authoritative source for exact fields and mutation mechanics whenever this doc and a script disagree.

## data/

```
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (AGENTS.md section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (AGENTS.md section 6)
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
```

A `state/<id>.status` line is a wake event, not current-state truth; `bin/fm-crew-state.sh` owns current-state reconciliation.
Treat `data/captain.md` as the domain-local record of captain preferences, optional `data/captain-shared.md` as the main-authoritative shared captain-preference file for secondmate inheritance, and `data/learnings.md` as curated home-local knowledge, regardless of harness memory.

## config/

```
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (AGENTS.md section 4)
config/crew-dispatch.json  optional crewmate dispatch profiles; LOCAL, gitignored; firstmate-maintained but human-editable natural-language rules that choose a per-task harness/model/effort profile (AGENTS.md section 4). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; AGENTS.md section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = default tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (AGENTS.md section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), while herdr, zellij, orca, and cmux are experimental spawn backends (docs/herdr-backend.md, docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Pi Calm presentation preference; LOCAL, gitignored, and not inherited; see docs/configuration.md "Pi Calm preference"
config/supervision-branch-model config/supervision-branch-effort  Pi supervision-branch model and reasoning-effort pins written by /supervision-model; LOCAL, gitignored, independently settable, and not inherited; see docs/configuration.md "Pi supervision branch model and effort"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/stow-pass-horizon  optional presence flag opting this home in to /stow's default-off pass-count decay horizon; LOCAL, gitignored, and not inherited; see docs/configuration.md "Stow pass horizon"
config/herdr-presentation-spaces  optional "off" opt-out from, or "on" opt-in to, Herdr's default-on disposable single-task visual projection, which is unconfigured-default-on only at or above a Herdr version floor; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/watched-tools.json  optional list of the tools this home depends on, read by the update check armed with bin/fm-tool-update-check.sh; LOCAL, gitignored, firstmate-maintained but human-editable, and NOT inherited by secondmate homes; see docs/configuration.md "Watched tool updates"
config/x-mode.env    generated Relay watcher cadence; LOCAL, gitignored; source before arming watcher when present
```

## state/

```
state/               runtime records and signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended    touched by turn-end hooks
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.muse-session  muse busy-source binding (sessions root plus task worktree) written by fm-spawn; removed by teardown
  <id>.cursor-session  cursor busy-source binding (projects root, task worktree, prior conversations) written by fm-spawn; removed by teardown
  <id>.reconcile-nudged  epoch second of the last inventory-reconcile nudge sent to this secondmate; bin/fm-secondmate-reconcile.sh owns its per-home cooldown window
  <id>.inbox/          durable steering inbox: sequenced firstmate instruction records the worker acknowledges by moving them into its handled/ subdirectory; written by fm-send, with ordinary records re-rung and escalated by the watcher while explicit fire-and-forget records are excluded from that ladder, and removed by teardown (bin/fm-task-inbox-lib.sh)
  <id>.meta          task metadata; each producer script's header owns its exact fields and mutation contract, with docs/configuration.md routing operator-facing backend and trace-context details
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified Relay shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  <id>.pr-poll-merge-notified  canonical PR identity of the last merge outcome delivered for this task; bin/fm-pr-lib.sh owns the marker format and identity mechanics, while bin/fm-merge-outcome-lib.sh owns locked publication, duplicate suppression, and replacement
  branch-outcomes.jsonl .branch-outcomes-cursor  Pi supervision-branch durable outcome store and its read cursor; bin/fm-branch-outcome.sh owns the format
  branch-session/ .branch-session .branch-mirror-cursor  the branch's persistent conversation, its pointer, and the dialog-mirror cursor; extension-owned (docs/pi-supervision-branch.md)
  .branch-eligible-rows .branch-eligible-owner .main-eligible-rows  per-actor wake-row claims and branch-owner evidence; docs/watcher-continuity.md owns the acknowledgement contract
  .lease-<task>        per-task supervision lease naming which actor (main or branch) may change that task; bin/fm-lease-lib.sh owns the contract the guarded scripts enforce
  .pr-check-quarantine/  private non-runnable storage for checks neutralized by the non-executing migration
  .pr-check-migration.log  private per-task outcomes distinguishing rebuilt or canonically registered replacement polls, quarantined unarmed polls, and incomplete migrations
  .pr-check-migration-scan-v1  private marker proving the non-executing scan disabled every unsafe legacy check; .pr-check-migration-v1 separately records completed private repairs
  x-watch.check.sh   generated Relay poll shim; present only when opted in (AGENTS.md section 14)
  tool-updates.check.sh  generated watched-tool update poll shim and its .check-trust binding; present only after bin/fm-tool-update-check.sh arm; its report record .tool-updates is what keeps one pending update from being reported on every poll
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written only by bin/fm-procevent.sh, and their presence alone keeps supervision required (AGENTS.md section 13)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private records marking a captured-answer source as feeding the keyed-answer intake, with a legacy origin on pre-collapse records; written only by bin/fm-captain-hold.sh bind, dropped by unbind and by source retirement (AGENTS.md section 13; docs/captain-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (AGENTS.md section 13's process-event-sources trigger)
  inbox/             captain notes captured out of band by bin/fm-inbox.sh, including the voice handover's queued requests; each note appends one `check` wake and stays pending until acknowledged with `bin/fm-inbox.sh drain --ack <id>`, which moves it to inbox/handled/ (docs/voice-relay.md)
  x-inbox/           generated Relay pending mention payloads; fmx-respond drains it (AGENTS.md section 14)
  x-context/         generated Relay durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (AGENTS.md section 14; bin/fm-x-lib.sh)
  x-outbox/          generated Relay dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (AGENTS.md section 14)
  public-followup/   generated private transport for promised public replies: retained open-loop registrations, typed terminal-result inbox, accepted/rejected ledgers, and retirement receipts (AGENTS.md section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated Relay and offer-claim diagnostic dedupe markers
  .startup-network.*  status, report, per-step elapsed timings, inline-print claim, and lock for the deferred network stage session start runs off its blocking path; bin/fm-startup-network.sh
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity/byte-offset manifest and serialization lock preventing already-presented status lines from being replayed as new; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop auto-arm single-flight, epoch, failure-episode, attended-alarm, guard-budget, and budget-lock records; never touch
  .cursor-park-owner .cursor-park-owner.lock .turnend-cursor-blocks   Cursor stop-hook owner record, publication and commit lock, and bounded repair-nag budget; never touch
  .hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .writing-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak   watcher internals; never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts read it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
```
