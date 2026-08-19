# Fleet vocabulary-collision registry

This file is the fleet's single owner of words that carry more than one meaning across the fleet, the Agentic Engineering platform, and the vendor tools both depend on.
A row here records a ruled disposition, not an opinion: what the senses are, who owns each, what was decided, and what a contributor must write instead.
When a word acquires a second live sense anywhere the fleet reads or writes, add a row here rather than resolving it locally in the file where it surfaced.

The platform keeps the mirror of this registry as Register 3 of its `docs/architecture/governance-registers.md`.
Neither registry is authoritative over the other's repository: each records the dispositions its own repository must honor, and a cross-repository row states both sides.

## Dispositions

The vocabulary of this column follows the platform's Register 3 precedent.

- **NO RENAME** - both senses keep the word; the row exists so the ruling is findable.
- **QUALIFY** - both senses keep the word, but each must always be written in its qualified form.
- **NO-CONTACT** - the senses cannot reach each other, and the row records the evidence for that.
- **DISSOLVED BY RENAME** - one sense was renamed; the row records both names and the retirement point of the old one.
- **DISSOLVED BY SPLIT** - one overloaded identifier was split into independent fields; the row records the axes and the retirement point of the old identifier.

## Rows

Every row below was ruled by the captain on 2026-08-07 against the measured census in the CFVC-16 naming proposal, except `reservation` and `attempt`, each ruled on 2026-08-18 when its second sense was built, and any row that states its own later ruling date.

### `axi`

| | |
|---|---|
| **Disposition** | NO RENAME |
| **Fleet sense** | the `*-axi` CLI family - `gh-axi`, `lavish-axi`, `chrome-devtools-axi`, `quota-axi`, `tasks-axi` |
| **Platform sense** | the Agent Interface Layer |
| **Third sense** | the upstream `axi` "Agent eXperience Interface" discipline, external to both repositories |

The fleet does not own the identifier: the `*-axi` tools are third-party package names, so a fleet-side rename would be a fork rather than a rename.
The platform's own row (Register 3, added 2026-07-23) already rules the convergence deliberate.
Write the tool name in full (`gh-axi`, never "axi") whenever the fleet means a tool.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 3 names the tool family; every `bin/fm-*.sh` that shells out to one of them.

### `skill`

| | |
|---|---|
| **Disposition** | QUALIFY (fleet side); DISSOLVED BY RENAME (platform entity sense only) |
| **Fleet sense** | a procedure directory under `.agents/skills/<name>/SKILL.md`, loaded by name |
| **Fleet sense** | a public installer-facing procedure under `skills/<name>/SKILL.md`, never loaded by a running firstmate |
| **Platform sense** | an engineering procedure under its `harness/skills/<name>/SKILL.md` |
| **Platform sense** | the `EngineeringSkill` entity, renamed platform-side to `EngineeringTechnique` |
| **Vendor sense** | the harness vendor's `Skill` tool and the literal `SKILL.md` discovery filename |

Five senses, not the three the platform's Register 3 first recorded.
The markdown senses are not renameable by either repository, because `SKILL.md` is the vendor's discovery filename and `Skill` is the vendor's tool name.
Fleet-side the word always takes a qualifier - "agent-only skill", "public skill", "the `Skill` tool" - and never stands alone in a document either repository may read.
The platform's persisted `skill_id` / `SKILL-*` wire identity intentionally lags the renamed type and is not rewritten.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) sections 2 and 13; the `.agents/skills/` and `skills/` split recorded in section 2's layout.

### `watch`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Fleet sense** | the supervision daemon - always written **`watcher`**, never bare "watch" |
| **Platform sense** | the governance view - always written **`Watch Register`**, never bare "Watch" |

Neither side renames.
The two vocabularies meet only in cross-repository assessment documents, and both already write the qualified form there.
The residual overlap is the bare English verb, which no rename removes.
A contributor writing about the fleet's supervision means `watcher`; a hyphenated compound (`watch-arm`, `watcher-beat`, `watch-checkpoint`) is already qualified and needs no change.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 8 and its captain-facing translation table in section 9; [`docs/watcher-continuity.md`](watcher-continuity.md); `bin/fm-watch*.sh`.

### `promotion`

| | |
|---|---|
| **Disposition** | DISSOLVED BY RENAME (fleet sense) |
| **Platform sense** | **Promotion Law**, a canonized law with a declared firing threshold and recorded firings - keeps the word, unchanged |
| **Fleet sense** | the scout-to-ship operation, renamed **`reflag`** (`bin/fm-reflag.sh`) |
| **Fleet sense** | model promotion and demotion between routing tiers, which keeps the word |
| **Other platform senses** | evidence-class promotion; census promotion trigger; the authority-ladder promotion of a managed trading project |

The platform's sense is canonized law, so renaming it would be a constitutional-tier act; the fleet's sense had the smallest measured footprint of any collision in the census and no captain-vocabulary cost, because the captain never hears either word.
`reflag` says what the operation does: a vessel is reflagged when its registry and contract change while hull and crew stay, which is exactly the scout-to-ship operation - the worker keeps its window, worktree, and loaded context, and only the delivery contract changes.
The fleet's own model-promotion sense, in `.agents/skills/model-onboarding/SKILL.md`, is a distinct fifth sense that surfaced while this row was being written; it keeps the word because it is a promotion in the platform's own sense - evidence earning a durable position - and it never meets the task vocabulary.

**Retirement of the old entry point.**
`bin/fm-promote.sh` is a bounded compatibility shim, not an alias.
It exists only for a firstmate turn that loaded the pre-rename instructions and has not yet fast-forwarded, so its retirement condition is: **remove it once every home that this repository serves has fast-forwarded past the commit that introduced `bin/fm-reflag.sh` and re-read its instructions.**
The shim records each use in `state/.reflag-shim-used` so that condition is settled by evidence rather than by memory; an absent marker after a full task cycle is the proof that no caller still needs it.
It is not a general-purpose entry point: it forwards, warns on stderr, and is excluded from documentation as a supported command.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 7 "Scout outcome and reflagging" and the section 9 do-not-expose list; [`docs/architecture.md`](architecture.md); [`docs/scripts.md`](scripts.md); `bin/fm-reflag.sh`.

### `execution`

| | |
|---|---|
| **Disposition** | NO-CONTACT (across the platform's managed-project boundary) |
| **Platform sense** | the execution plane - `execution_node`, ADR-0053 / ADR-0054 |
| **Platform sense** | the EI artifacts - `ExecutionUnit`, `ExecutionPlan` |
| **Platform sense** | the provider seam - `execution_provider` |
| **Managed-project sense** | order execution in the platform's trading project |

Neither side renames, and the pair originally reported as the collision is the one pair that cannot collide: the platform and its managed trading project never share an import root, so no name resolution ever reaches across.
"Execution" is also the domain-standard term for order execution, so renaming the trading sense would trade correctness for hygiene.

The collision worth recording is internal to the platform, where three of its own senses do share one import namespace; the platform's Register 3 owns that row.
The fleet's only contacts with any of these senses are deliberate disambiguations that already name the platform artifact explicitly, such as the LoopSpec contract stating that a LoopSpec is not an `ExecutionUnit`.

**Where it bites:** [`.agents/skills/loopspec/SKILL.md`](../.agents/skills/loopspec/SKILL.md); [`loopspecs/schema.json`](../loopspecs/schema.json); `bin/fm-loopspec.sh`.

### `lifecycle`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Platform sense** | the project phase lifecycle - a constitutional state machine with a durable artifact per project |
| **Fleet sense** | the task lifecycle, plus the decision-hold, secondmate, wake-daemon, and Herdr lifecycles |

The platform's sense has the deepest governance footprint measured and is not renameable at any price this work could justify.
The fleet's real ambiguity is internal rather than cross-repository - it uses the word for five different things - and the fix is the qualifier the fleet already writes almost everywhere.
Never write "the lifecycle" bare in a document either repository may read.
Write `task lifecycle`, `project lifecycle`, `decision-hold lifecycle`, `secondmate lifecycle`, `wake-daemon lifecycle`, or `Herdr lifecycle`.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 7, titled "Task lifecycle"; [`docs/decision-hold-lifecycle.md`](decision-hold-lifecycle.md); the `lifecycle`-suffixed test names in `tests/`.

### `kind`

| | |
|---|---|
| **Disposition** | DISSOLVED BY SPLIT (task-metadata sense) |
| **Task-metadata sense** | the single `kind=` field of `state/<task-id>.meta`, split into `role=`, `deliverable=`, and `stage=` |
| **Backlog-hold sense** | `tasks-axi hold --kind captain`, and the admission policy's `--kind load` |
| **Wake-ledger sense** | the wake kind of a queued wake - `signal`, `stale`, `check`, `heartbeat` |
| **Operational-input sense** | the structural kind of a marked message, owned by `bin/fm-operational-input.sh` |

One `kind=` field carried three independent facts at once: who the worker is, what the task produces, and where the task stands in its life.
Every consumer had to reconstruct the axis it cared about from a value that also encoded the two it did not, and the scout-to-ship operation expressed a lifecycle transition by rewriting a deliverable type.
[`bin/fm-task-axis-lib.sh`](../bin/fm-task-axis-lib.sh) is the single owner of the three axes, their values, and the deterministic derivation from the retired field.

`kind` remains a live field name in three other unrelated fleet namespaces, listed above.
Those are separate vocabularies with their own owners and are not part of this split; do not introduce a fourth.

**The role axis is now the home for every role-typed fact about a task.**
A field describing who a worker is - including a requested agent role, which was deferred until this split existed - belongs on `role=` and never as a new dimension beside it.
That deferral was the whole reason the split had to come first: adding a role field to the old single-field vocabulary would have made a fourth conflated axis out of a field that already carried three.
No such field exists in the fleet today; the axis is what makes adding one a one-line change rather than another conflation.

**Remaining work on the stage axis.**
`commissioned` and `reflagged` are written by the spawn and the reflag.
`delivered` is declared but not yet written by any fleet path: stamping it belongs after a confirmed landing, inside the merge path's own private metadata rewrite, and that writer is a deliberate follow-up rather than something added beside this split.
Until it exists, read an absent `delivered` as "no path has reported this task landed", never as "this task did not land".

**Retirement of the deprecated field.**
No consumer branches on `kind=` any more, with one recorded exception the retirement step must migrate: the `active_workers.count` evidence detail in [`bin/fm-admission.sh`](../bin/fm-admission.sh) still groups snapshot tasks by the alias, and dropping the alias without migrating that site silently degrades the detail to a single bucket.
What keeps the field alive is that it is still written - so a home that has not yet fast-forwarded can still read a record this one wrote - and that it is still the derivation source for a record predating the split.
The name also stays on the wire during the window: under the unchanged `v1` schema tags, `fm-fleet-snapshot.v1` carries `kind` beside the axes on its task rows and its `scout_reports[]` rows, and `fm-bearings.v1` carries it beside `role`/`deliverable` on its `in_flight` rows, so an external consumer keying on the old name keeps reading; those wire fields retire at the next schema-tag bump of their surface, never silently under `v1`.
Its retirement condition is therefore: **stop writing `kind=`, migrate the `active_workers.count` detail in [`bin/fm-admission.sh`](../bin/fm-admission.sh) to the axes, and drop `kind` from the `fm-fleet-snapshot.v1` and `fm-bearings.v1` surfaces at their next schema-tag bump, once one full task cycle has run entirely on the three axes across every home this repository serves.**
Until then it is a dual-written deprecated alias with exactly one owner, and a metadata record whose `kind=` disagrees with its explicit axes is refused rather than silently resolved, so a stale writer that flips the old field alone cannot desynchronize a task's identity.

**Where it bites:** [`bin/fm-task-axis-lib.sh`](../bin/fm-task-axis-lib.sh); the metadata field list in [`AGENTS.md`](../AGENTS.md) section 2; [`docs/architecture.md`](architecture.md); the `active_workers.count` evidence detail in [`bin/fm-admission.sh`](../bin/fm-admission.sh); the `kind` wire fields of [`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) and [`bin/fm-bearings-snapshot.sh`](../bin/fm-bearings-snapshot.sh).

### `reservation`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Admission sense** | admission control's distributed reservations - the `reservations` policy key and the `reservation_pressure` signal, owned by [`bin/fm-admission-lib.sh`](../bin/fm-admission-lib.sh) and documented in [`docs/configuration.md`](configuration.md), dormant until a second intake authority or a remote node registers |
| **Slot sense** | one queued trunk repair holding the NEXT free worktree slot in a pool, owned by [`bin/fm-slot-reservation-lib.sh`](../bin/fm-slot-reservation-lib.sh) and applied by [`bin/fm-worktree-guard.sh`](../bin/fm-worktree-guard.sh) |

NO-CONTACT was not available, and the measurement says why.
[`bin/fm-spawn.sh`](../bin/fm-spawn.sh) is the contact point: one dispatch consults admission through `spawn_admission_gate` and the slot reservation through `fm-worktree-guard.sh select --for`, both in the same allocation path and both before anything is allocated, so the two senses meet at one decision point in one file.
The resemblance is not superficial either, which is what makes the confusion durable rather than passing: both senses carry a TTL and stated release conditions, so a reader who knows one of them recognizes the shape of the other and reads the wrong owner.

Write `admission reservation` for the first sense and `slot reservation` for the second.
Bare `reservation` is unacceptable in either sense wherever both could be meant.

The dormant admission config keys are exempt, because this is a writing rule and not a migration.
Do not rename `reservations`, `reservation_pressure`, or any policy key, and do not touch the schema in [`docs/configuration.md`](configuration.md).
Nothing in the slot sense is renamed either: `FM_SLOT_RESERVATION_*`, `fm_slot_reservation_*`, `reservation-<key>.state`, and the `reservation[1]{...}` record already carry `slot` in their own names or paths.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 7; the slot-reservation rows of [`docs/scripts.md`](scripts.md); the slot-reservation section of [`docs/verification/worktree-allocation.md`](verification/worktree-allocation.md); the admission paragraph of [`docs/architecture.md`](architecture.md); the operator-facing refusals of [`bin/fm-worktree-guard.sh`](../bin/fm-worktree-guard.sh) and [`bin/fm-slot-reservation.sh`](../bin/fm-slot-reservation.sh).

### `FM_OUTBOUND_TIMEOUT`

Ruled 2026-08-18, on the review finding that surfaced the collision rather than on the CFVC-16 census.

| | |
|---|---|
| **Disposition** | DISSOLVED BY SPLIT |
| **Module sense** | seconds allowed for **one** forge or git observation, owned by [`bin/fm-outbound-artifact.sh`](../bin/fm-outbound-artifact.sh) |
| **Bootstrap sense** | seconds allowed for the **whole** session-start sweep, owned by [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) |

One name carried a per-observation timeout and a whole-run deadline at once, and the two cannot be reconciled by qualifying the prose at each use: a variable name *is* its use, and every home that set it moved both meanings together.
At the shared default of 15 a single slow probe could spend the entire sweep budget, and the terminated sweep discarded defects it had already found in favour of `OUTBOUND: sweep unevaluable`; raising the value to give the sweep room widened every individual probe by the same factor, so no single value existed that was correct for both.

The whole-sweep deadline is now `FM_OUTBOUND_BOOTSTRAP_DEADLINE` (default 60).
`FM_OUTBOUND_TIMEOUT` (default 15) keeps the per-observation sense only, and the module header says so at the definition rather than at each call.
The bootstrap default must remain several probe timeouts wide, because the relationship between the two - a run is many observations - is the reason they are separate names.

**Retirement of the split.**
The split retires when the session-start relay no longer runs the sweep in the foreground - that is, once the outbound sweep is driven by the persistent poller rather than by `bin/fm-bootstrap.sh` - at which point there is no whole-run deadline for bootstrap to own and `FM_OUTBOUND_BOOTSTRAP_DEADLINE` is removed rather than renamed.
Until then both names are live and neither may be read as the other.

**Where it bites:** the environment table in [`bin/fm-outbound-artifact.sh`](../bin/fm-outbound-artifact.sh); `outbound_artifact_report` in [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh); the Browser Sol control venue section of [`configuration.md`](configuration.md).

### `attempt`

| | |
|---|---|
| **Disposition** | QUALIFY |
| **Work sense** | a try at the WORK - the count and retry budget in `state/<task-id>.attempt`'s `attempt=`/`attempt_budget=`, advanced only by a recorded failure, owned by [`bin/fm-attempt.sh`](../bin/fm-attempt.sh) |
| **Execution sense** | a WORKER INCARNATION executing that work - `execution=`/`execution_id=` in the same record and the `state/<task-id>.lineage` ledger, advanced only by a sanctioned replacement, owned by the same file |
| **Herdr-projection sense** | the "attempt and restart-binding journal" of `state/<task-id>.herdr-presentation`, owned by [`docs/herdr-backend.md`](herdr-backend.md) |

NO-CONTACT was not available and neither was a rename, and the measurement says why.
The first two senses are recorded in ONE file, by one owner, and are read together on every dispatch: `bin/fm-spawn.sh` resolves the retry budget and the producer identity in the same call, and the whole reason the execution sense exists is that a provider window closing mid-flight advances the second while the first must not move.
Renaming either would rename half of one record.

Write `work attempt` for the first sense and `execution attempt` for the second.
Bare `attempt` is acceptable only where the surrounding text has already fixed which one is meant, and never in a field name, a refusal, or a header sentence that introduces the subject.
The Herdr-projection sense is confined to one journal that is never task or endpoint authority, and its own file already qualifies it.

Nothing is renamed: `attempt=`, `attempt_budget=`, `--attempt-budget`, `FM_ATTEMPT_*` and `fm-attempt.sh` keep the work sense's spelling, and every execution-sense field already carries `execution` in its own name.
This is a writing rule, not a migration.

**Where it bites:** [`AGENTS.md`](../AGENTS.md) section 2's `<id>.attempt` and `<id>.lineage` rows and section 7's replacement paragraph; the header of [`bin/fm-attempt.sh`](../bin/fm-attempt.sh); the `--succeed-execution` contract in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh); [`tests/fm-execution-replacement.test.sh`](../tests/fm-execution-replacement.test.sh).

## Maintaining this file

Add a row when a word acquires a second live sense in any repository the fleet reads or writes, not when a rename is proposed.
A row states the senses, their owners, the ruled disposition, what to write instead, and - for a rename or a split - the retirement condition of the obsolete name, so no obsolete path is left with an open-ended life.
Keep the "where it bites" pointers current: they are the reason a contributor finds this file, and each pointed-at site carries a one-line cross-reference back rather than a second copy of the ruling.
