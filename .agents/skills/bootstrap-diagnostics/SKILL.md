---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, MODEL_REGISTRY, MODEL_PRICE, MODEL_VERIFY, ADMISSION_CONTROL, WAKE_LEDGER, TASK_AXIS_BACKFILL, CAPACITY_DEFERRED, CAPACITY_UNMEASURED, FLEET_SYNC, PR_CHECK_MIGRATION, VALIDATION_DAEMON, COMMITMENT, OUTBOUND, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For `gh-axi`, this also covers an installed version below the bootstrap-owned floor; treat it as an upgrade request so non-interactive PR merges keep a working bare `--squash` shorthand.
  For `tasks-axi`, this also covers an installed build that fails the compatibility probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `MODEL_REGISTRY: invalid config/models.json - <reason>` - the model registry exists but failed schema validation, so every provider-prefixed model is now refused at spawn until it is corrected.
  Fix the registry; never delete it to clear the error, because deleting it silently disables zero-budget enforcement rather than restoring it.
- `MODEL_REGISTRY: <model> <problem>` - the dispatch config and the registry disagree: the model is unregistered, carries a non-approved status, or has no current live-probe record.
  This is the check that catches a bad model before any worker is launched against it, so correct the dispatch rule or complete the model's admission; do not weaken the check to make the line go away.
- `MODEL_REGISTRY: no config/models.json, ...` - routed provider models exist but nothing enforces the zero-budget rule for them.
  This is a standing gap rather than a failure, and it stays inert by design; raise it with the captain rather than treating it as a startup blocker.
- `MODEL_PRICE: <model> ... no longer zero` - an allowlisted model is no longer free at its provider, which is the exposure a name-only allowlist cannot see.
  Suspend that route immediately, then re-verify its cost class before it is routed to again.
- `MODEL_PRICE: <model> price drifted ...` or `... catalogue source is unreadable` - re-verify the cost class and update the recorded price, or repair the declared catalogue path so the check stops being blind.
- `MODEL_VERIFY: <model> ...` - a live probe failed. Load `model-onboarding` and read the shape before reacting: a provider refusal means this account can never use that model and it must leave routing, while a local failure is a configuration error on this machine and not a provider fact.
- `ADMISSION_CONTROL: invalid config/crew-dispatch.json _scheduling.admission_control - <reason>` - the optional fleet-admission policy exists but failed schema validation, so the fleet's admission layer cannot resolve a band.
  Do not dispatch new work in this home until the named field is corrected; an unknown field is refused rather than ignored precisely so a typo cannot silently disable a safety condition.
  `docs/configuration.md` "Fleet admission control" owns the schema, and `fleet-admission` owns what firstmate does with a resolved band.
- `WAKE_LEDGER: <n> outcome record(s) join no wake record` - that many recorded supervision costs point at a wake this home never drained, so every figure drawn from the ledger overcounts by up to that number.
  Treat it as a measurement defect, never as supervision work: report the count rather than any rate or total computed from the file, until those records are retired.
  The records are append-only evidence, so never rewrite, migrate or purge the file to clear the count; retire them in place with `bin/fm-wake-ledger.sh reconcile --list` to review the candidates and `invalidate --target outcome --reason <class>` to record the ruling, which excludes them from every count while leaving the raw records readable.
  Invalidation is terminal and needs the captain's decision on what the records actually are, because nothing un-retires one and the candidate list proves only that a record joins nothing - true of a fabricated sequence and of a legacy record from a genuinely wiped home alike.
  A count that GROWS is a bug to escalate rather than old damage: no supported path appends another unjoined outcome record, because an explicit unjoinable sequence is refused and the genuine wiped-home case records under its own `recovered-outcome` kind.
- `WAKE_LEDGER: the wake ledger could not be read ...` - the file exists but could not be opened, so the count above is unavailable rather than zero.
  Repair its permissions or path before quoting any supervision-cost figure; an unreadable ledger is reported precisely so it cannot pass as a clean one.
- `WAKE_LEDGER: <n> task(s) declared failure with no terminal record ...` - only a lock-holding session records those, so a read-only session names them and leaves the recording to the session that holds the lock.
  Take no action on the count itself; the next locked session records it, and the tasks themselves are ordinary work whose state is read the usual way.
  Terminal outcome counts stay diagnostic while any of them is unrecorded, so never quote a success rate from the ledger.
- `TASK_AXIS_BACKFILL: <n> task record(s) state an identity the deprecated kind= alias contradicts - <ids>` - a task's role, deliverable, or stage disagrees with the old single-field value still recorded beside it, so that task's identity is unreliable rather than merely stale.
  The backfill sweep refuses those records instead of converging them, because either side could be the stale one and choosing silently would pick a task's identity by luck.
  Read the named record and settle it from evidence outside the file - what the task was dispatched to produce, and whether it was reflagged - then correct the disagreeing field; `bin/fm-task-axis-lib.sh` owns the axes and the derivation, and `docs/vocabulary-collisions.md` owns the alias's retirement condition.
  A record that appears here after a spawn or a reflag is a writer bug to escalate, not old damage: every current writer writes both sides together.
- `CAPACITY_DEFERRED: <n> task(s) stopped waiting for model capacity and were never dispatched - <ids>` - each named task was held because every model meeting its capability floor was out of provider capacity, then stopped because a fresh dispatch could not be reconstructed safely or its durable retry state could not be maintained.
  The work never entered a pool that could not run it and is still held in the backlog, but its automatic wait is no longer active; `bin/fm-capacity-retry.sh list` shows what it was waiting on and why it stopped.
  The line appears only for a wait that STOPPED; a wait still in progress and a wait that resumed by itself are both silent, because neither needs a decision.
  Read the recorded reason and route with `bin/fm-capacity-retry.sh list`, then inspect the current picture with `bin/fm-route.sh capacity --route <route>`.
  Repair the named durable-record failure before attempting another dispatch, or decide the work is no longer wanted, in which case `bin/fm-capacity-retry.sh release <id>` drops the stopped record.
  A stopped wait has no supported rearm command, so escalate that tooling gap rather than claiming the work will resume.
  Never resolve one of these by dispatching the same task on a model below its route's floor.
  A required floor that is currently unavailable is a wait, and quietly running the work on something weaker is the exact failure the deferral exists to prevent.
- `CAPACITY_UNMEASURED: <n> task(s) stopped waiting for model capacity WITHOUT a measurable bound - <ids>` - each named task stopped because the deferral count that bounds its wait could not be written, not because that bound was reached.
  This is a defect in the instrument, not a fact about the pool, and it is the one capacity line that is could-not-observe rather than observed-bad.
  Do not read it as an exhausted pool: nothing here established that any model was tried and found out of capacity, only that how long the task waited is unknown.
  Repair the recorder first - `state/<id>.attempt` is the record that could not be written, so check its directory's permissions, the free space under `state/`, and whether another process holds the path - then decide the wait again with the same three options `CAPACITY_DEFERRED` offers.
  Raising the bound before the recorder is fixed only buys another unbounded wait, because the count that would stop it still cannot be written.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `VALIDATION_DAEMON: down - <evidence>` - the shared no-mistakes validation daemon is not running, so no task can be validated and every pipeline already waiting on it is stalled.
  When the line carries a `last active` duration, use that as the outage length; the clause is deliberately absent when bootstrap has no daemon-log timestamp from which to measure it.
  Starting it is firstmate's decision and never an automatic one: the daemon's own startup recovery fails every run it cannot resume, so reconcile each task's real validation state after any start rather than trusting a pre-outage record.
  Report the stall and any measured outage length to the captain under `AGENTS.md` section 9 before dispatching work that depends on validation.
- `VALIDATION_DAEMON: unknown - cannot read a pid from <path>` - the daemon's pid file is present but no pid can be read out of it, so liveness is genuinely unmeasured.
  Do not treat this as down and do not treat it as alive: inspect the named path, and settle the daemon's actual state before either alarming the captain or dispatching validation-dependent work.
- `COMMITMENT: <id> UNMET (<label>) - <evidence>` - something was recorded as a commitment, and the probe registered for it says it is not real yet.
  The line is not a reminder to re-file the commitment; it is the evidence that the thing the record promises is not happening.
  Read the named evidence, decide with the captain whether closing it is work worth dispatching now, and record that decision - but never edit or delete the entry to quiet the line, because the entry retires by itself the moment its probe passes, and one removed by hand takes the gap with it.
  This is deliberately not suppressed by age, count, or rate: a quieter question hides a genuine unmet commitment along with the noise.
- `COMMITMENT: <id> COULD-NOT-OBSERVE - <evidence>` - the probe reached no verdict, or the entry is inadmissible, or it is an attested criterion that cannot execute.
  This is the third value and it is never read as enforced: the commitment may or may not be real, and until the probe can answer, no one may say it is.
  Repair whatever stopped the observation - an entry the interpreter refuses names its own defect in the evidence - rather than treating the absence of a failure as a pass.
  Read a `TIMEOUT:` evidence line as a probe to fix rather than as an ordinary open item, because could-not-observe cannot close a key and a probe that always times out blocks its closure forever.
- `COMMITMENT: register unreadable - <reason>` - the commitment register itself could not be read, so no commitment was checked at all.
  Treat it as the register failing rather than as an empty register, and repair it before trusting any session-start silence about recorded commitments.
- `OUTBOUND: <item> is waiting on <gate> with no applicable durable artifact (<token>) - <evidence>` - the item's durable state says it is waiting for something outside the fleet, and the thing it is waiting for was never created or no longer applies to its current head.
  This is a CONTROL-TRANSPORT DEFECT, not an external wait: nobody is considering that work, and nothing will ever arrive to unblock it, so it does not clear by waiting longer and no amount of patience is the right response.
  Do not re-hold the item, extend its wait, or describe it to the captain as blocked on an external party - by this evidence there is no external party involved yet.
  Read the token to choose the repair: `FM_OUTBOUND_NO_ARTIFACT` means nothing was ever asked; `FM_OUTBOUND_STALE_HEAD` means an earlier ask exists but the reviewed head moved, so it answers a different question now; `FM_OUTBOUND_INCOMPLETE_BINDING` and `FM_OUTBOUND_HEAD_UNOBSERVED` mean the item cannot be bound to an exact head at all, which must be repaired before anything is asked rather than papered over with a vague request.
  `FM_OUTBOUND_CORRELATION_RECORD_MISSING` means the artifact WAS observed on the forge but this home holds no correlation record for it, so nothing here can join a ruling back to the waiting item; re-run `bin/fm-outbound-artifact.sh emit <item>`, which adopts the existing artifact and writes the missing record rather than posting a second one.
- `OUTBOUND: <item> has its artifact <artifact> on the forge, but the correlation record filed under <request-id> names a DIFFERENT request (FM_OUTBOUND_IDENTITY_REFUSED) - ...` - the artifact exists and was observed; what is refused is the local record's identity, which recomputes to some other request.
  Read this as a correlation defect and never as a missing artifact: do NOT re-emit, because emitting would post a second request for work that already has one.
  Both identifiers are printed on purpose - open the named artifact and the named request id, decide which one the record actually belongs to, and re-key or remove the record so the correct identity is filed under the correct id.
  `bin/fm-outbound-artifact.sh show <request-id>` refuses the same record for the same reason, which is the confirmation that the file rather than the forge is what is wrong.
  On the `sol-control` channel, `bin/fm-outbound-artifact.sh emit <item>` creates the missing request once the binding is complete.
  On the `pull-request` channel that command deliberately refuses, because opening a pull request is a delivery action owned by the task's selected delivery path (`AGENTS.md` section 7) and an outward-facing one on an upstream contribution; relaunch the work through that path instead, and observe the project's outward-consent posture where it applies.
- `OUTBOUND: <item> artifact state COULD-NOT-OBSERVE (<token>) - <evidence>` - the sweep could not determine whether the artifact exists, so the item's waiting is neither confirmed legitimate nor confirmed defective.
  This is the third value and never a pass: repair what stopped the observation rather than reading the absence of a defect as a clean result.
  `FM_OUTBOUND_TRANSPORT_UNCONFIGURED` means this home has no `config/sol-control.json`, so the venue a request would be posted to is unknown; `docs/configuration.md` owns that file.
  The remaining tokens name which read failed, and each is repaired by restoring that read rather than by re-emitting anything.
  `FM_OUTBOUND_RECORD_UNREADABLE` - the correlation record exists but could not be parsed or its lifecycle state is not one of the known ones; inspect the file itself, and note that this is the "could not read it" answer, distinct from `FM_OUTBOUND_IDENTITY_REFUSED`, which read it fine and found it is about other work.
  `FM_OUTBOUND_ARTIFACT_UNOBSERVED` - the forge read did not conclusively establish presence or absence, usually credentials, rate limits, or `FM_OUTBOUND_TIMEOUT` being too tight for this forge.
  `FM_OUTBOUND_BACKLOG_ROW_UNREADABLE` - a durable backlog row could not be classified, so that item's whole question is unanswered; repair the row.
  `FM_OUTBOUND_PROJECT_REGISTRY_UNREADABLE`, `FM_OUTBOUND_PROJECT_POSTURE_UNOBSERVED`, `FM_OUTBOUND_CLONE_UNREADABLE`, `FM_OUTBOUND_REFS_UNOBSERVED`, `FM_OUTBOUND_REF_UNOBSERVED` - the branch inventory could not enumerate its candidate universe for a project, so a negative claim about that project proves nothing; repair the registry entry, the project mode command, or the clone named in the line.
  `FM_OUTBOUND_VENUE_UNRESOLVED` and `FM_OUTBOUND_LANDING_TARGET_UNOBSERVED` - the project's contribution venue or its landing target could not be resolved, so neither "a pull request is missing" nor "the work already landed" can be asserted; repair that clone's remotes.
  `FM_OUTBOUND_WORK_STATE_UNOBSERVED` - no lifecycle state could be parsed for the item, which includes an in-progress branch with no durable row at all; this is the expected reading for ordinary work in flight and is repaired by the completion writer recording a row, never by treating it as finished.
  `FM_OUTBOUND_WORK_LIFECYCLE_CONFLICT` - lifecycle rows were read and they DISAGREE, typically a completion row and a reopened row for the same item; reconcile the rows rather than choosing one.
- `OUTBOUND: reconciliation refused an emit (status <n>) - ...` - session-start reconciliation attempted every selected item and at least one emit refused; the refusal's own token is printed immediately above this line, un-prefixed.
  The sweep report that follows is complete and covers every other item, so read this line as one item's failure rather than as the sweep having stopped.
  `FM_OUTBOUND_EMIT_IN_FLIGHT` means another session holds that request's lock and is not a defect to repair; `FM_OUTBOUND_CHANNEL_DETECT_ONLY` means the item is on the `pull-request` channel, which this command never creates.
- `OUTBOUND: sweep unevaluable - <reason>` or `OUTBOUND: probe cap <n> reached - ...` - the invariant was not checked across the whole fleet, so session-start silence about stranded work proves nothing this time.
  Repair the named cause, or re-run `bin/fm-outbound-artifact.sh check` with a higher `FM_OUTBOUND_MAX_PROBES`, before treating the fleet as clean.
  The `bootstrap deadline expired` variant is a BOUNDED report, not an empty one: every `OUTBOUND:` line above it is a real finding the sweep established before it was stopped, and each is acted on exactly as it would be in a complete run.
  What the marker withdraws is only the negative claim - nothing below the point it stopped was looked at - so a bounded report may be acted on but must never be read as a clean fleet.
  Raise `FM_OUTBOUND_BOOTSTRAP_DEADLINE` (the whole-sweep bound, distinct from the per-observation `FM_OUTBOUND_TIMEOUT`; `docs/configuration.md` owns both) or run the sweep by hand to close the unexamined remainder.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after same-host connectivity returns; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
