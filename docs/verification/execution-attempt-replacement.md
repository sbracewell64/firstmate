# Same-lane execution-attempt replacement verification

Audience: maintainer verification.

This record supports the execution-attempt lineage and the replacement gate in [`../../bin/fm-attempt.sh`](../../bin/fm-attempt.sh), the `--succeed-execution` dispatch in [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh), the `owner-state` verb in [`../../bin/fm-worktree-guard.sh`](../../bin/fm-worktree-guard.sh), and the endpoint-absent and no-run readings of `bin/fm-crew-state.sh`'s structured answer in [`../../bin/fm-classify-lib.sh`](../../bin/fm-classify-lib.sh), which the gate composes.
It records what was measured about the controls on that transition, and the limits of what the measurement establishes.
Throughout, `attempt` is written in its qualified form; [`../vocabulary-collisions.md`](../vocabulary-collisions.md) owns that ruling.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The regression coverage is [`../../tests/fm-execution-replacement.test.sh`](../../tests/fm-execution-replacement.test.sh).

## What the suite executes

Measured 2026-08-21 on Linux 6.18 (WSL2), bash 5.2, git 2.53.0, shellcheck 0.11.0.

The suite runs **the test functions enumerated below - the 14 declared controls, the boundary rules the implementation created, and the review-regression cases**, each driving `bin/fm-attempt.sh` and `bin/fm-spawn.sh` as executables against a real isolated git worktree, a real routed dispatch policy read by the real `bin/fm-route.sh`, and a controlled process table.
One case additionally drives the real `bin/fm-crew-state.sh` rather than the suite's stub, which is what binds the gate's enumeration to the answers its producer actually emits.
The behavioral assertions inspect only public command results and durable outputs; the three integrated watched-red checks described below copy the shipped toolbelt and replace one exact implementation clause solely to create their controlled defect builds.

```
$ bash tests/fm-execution-replacement.test.sh
ok - recorded successors derive a numeric Treehouse slot from a spaced worktree path
ok - recorded successors preserve the ordinary no-space slot layout
ok - recorded successor paths outside, ambiguous, or malformed for the Treehouse pool refuse before launch
ok - control 1+2: the lane continues on its own slot and requests no allocator slot
ok - control 14: the verdict and the slot follow the allocator's record, never a directory count
ok - control 3: replacement is refused while the old process group still holds the lane
ok - control 12: ambiguous process, table, custody and cross-lane ownership never read as permitted
ok - control 11: an operation already in flight refuses replacement
ok - control 9: an alternate the routing owner does not admit refuses
ok - control 10: an exhausted primary with no eligible alternate stays held
ok - control 4+5+7+8: identity and binding move, work lineage and prior attribution do not
ok - control 6: unresolved questions and active obligations survive replacement
ok - control 13: a crash or a concurrent attempt still leaves exactly one active execution
ok - the only door: an ordinary relaunch cannot rebind a lane
ok - a successor launches only onto the binding its gate admitted
ok - a successor launches only at the effort its gate admitted
ok - replace refuses an unstated effort sanction; a stated one is recorded, pinned, and launches
ok - a successor against a record carrying no effort sanction is refused, never adopted
ok - a successor on a clean detached lane opens on the predecessor's exact head
ok - an orca lane refuses succession as unverified custody reuse, and the lane is untouched
ok - a successor dispatch cannot skip the gate that sanctions it
ok - only a confirmed launch is protected from rebinding; an unstarted one produced nothing
ok - an ended attempt closes its execution and admits a fresh-execution retry on any binding
ok - a reviewing lane refuses a replacement that is not independent of its maker
ok - a pre-lineage lane adopts its recorded binding, replaces, and launches its successor
ok - an adoption with no readable binding refuses could-not-observe and writes nothing
ok - an adopted execution is refused a rebind an unstarted one is allowed, and stays replaceable
ok - the execution ledger retires with the attempt record
ok - a dead-endpoint lane composes quiescence, replaces, and launches its successor
ok - every unknown but the composed one still refuses replacement
ok - the real current-state reader emits the composition the gate admits
FM_TEST_CONTRACT suite=fm-execution-replacement.test.sh status=pass
```

That is a POSITIVE EXECUTED COUNT - the enumeration above IS the count, one reported line per executed assertion group, so no total is maintained by hand beside it - and not an absence of failures.
A run that executed nothing would print nothing here, which is the reason the list is recorded at all.

The closing `FM_TEST_CONTRACT` line is what makes that count enforceable rather than merely printed.
`fail` inside a command substitution kills only the subshell, so an aborting `make_lane` handed its caller an empty string and the suite kept running, then exited on its LAST case's status - and `bin/fm-test-run.sh` grades a suite by its exit code alone, so a `not ok` printed that way was read as a pass.
The suite now opts into `tests/lib.sh`'s identity contract, which compares the declared `test_` functions against the ones that reported success and exits nonzero on any difference.
Measured against a build with every invocation but the first removed: `exit=1`, naming each declared case that never reported.
The suite takes about 115 seconds on the machine above, up from about 102 before the recorded-slot cases, about 92 before the door-3 cases, and about 70 before the pre-lineage ones.
The portable-serial weight hint in `bin/fm-test-run.sh` reads 137103 from the latest complete CI timing artifacts rather than this local measurement, because the table's own header requires CI evidence and forbids mixing in local timing.
The hint is a balance hint only, so the staleness costs shard balance and never coverage.

The three recorded-slot cases exercise the Treehouse layout as `<pool>/<slot>/<repository>` with spaces in the project, pool, and repository names, preserve the ordinary no-space layout, and refuse worktrees outside Treehouse's answer and ambiguous or malformed recorded paths before pane launch.
The spaced-path case also requires the custody holder to be observable before exact-path verification, asserts that the numeric slot rather than the repository basename is passed through shell quoting, and watches both the parent-derivation and custody-readiness properties go red against controlled defects.
The ordinary-path case separately watches the established non-space slot turn red when the repository basename is substituted for its slot identity.

The review-regression cases, each added after a review round of this branch and named for the defect it guards:

- `test_a_successor_may_only_launch_at_the_admitted_effort` - the effort axis of the sanctioned binding left unpinned at the launch door.
- `test_a_detached_lane_keeps_the_predecessors_exact_head` - a clean DETACHED lane's head silently reset to the slot base by the successor dispatch, unreachable from the original fixtures, which all sat on a named branch.
- `test_an_orca_lane_refuses_succession_until_custody_reuse_is_verified` - an orca-backed lane's succession silently allocating a fresh worktree instead of refusing. The case also pins the refusal's shape: its own exit status (3), the condition named as UNVERIFIED custody reuse rather than permanent unsupport, the pointer to this record as where a verified reuse path would be recorded, and the lane - worktree, metadata and sanctioned record - untouched afterwards. The lift condition is self-contained: the refusal stands exactly until a verified orca custody-reuse path lands and its verification is recorded here, at which point the refusal, its case, and this bullet all retire together.
- `test_replace_refuses_an_unstated_effort_sanction` and `test_a_successor_with_no_effort_sanction_refuses_at_launch` - an UNSTATED effort sanction (an empty or `default` recorded band) accepted instead of refused, measured at both of its doors: `replace` refuses to mint a successor carrying no band and points at `--alternate-effort`, and the successor gate refuses a sanctioned record carrying none rather than adopting whatever the launch declared.
- `test_a_prelineage_lane_adopts_its_recorded_binding_and_replaces`, `test_a_prelineage_lane_without_a_recorded_binding_refuses` and `test_an_adopted_execution_is_not_re_pointed_like_an_unstarted_one` - the zero-lineage deadlock this capability's FIRST production use hit, and the two boundaries the fix creates. The first drives the whole adopted path end to end: `--check` naming the successor the adoption will actually produce, the mint, the ledger's adopted-provenance line, and the `--succeed-execution` launch that follows. The second pins the adoption to a durable record, refusing could-not-observe and writing nothing when the metadata names no binding and when it is absent entirely. The third pins the adopted token itself, asserting the DIVERGENCE - the same record differing only in that token is admitted as `launching` and refused as `adopted` - so the case cannot go quietly vacuous.
- `test_a_dead_endpoint_lane_composes_quiescence_and_replaces`, `test_every_other_unknown_still_refuses_replacement` and `test_the_real_reader_emits_the_composition_the_gate_admits` - the dead-endpoint deadlock, its boundaries, and the producer it is bound to. The first drives the composed path end to end: the `--check` that names the composition before anything is committed, the mint, the `inflight=` disposition on the ledger line that closes the predecessor, and the `--succeed-execution` launch onto the same slot, worktree and committed work. The second asserts the DIVERGENCE rather than the pass - the same lane and the same gate refusing an unknown from a live endpoint, an unknown selected by a rule that is not endpoint-absent, an endpoint-absent unknown that still has a run attributed to it, and an in-flight run with the endpoint gone underneath it - and then sanctions the composed one, so the refusals cannot all be a gate that refuses everything. The third takes the stub away entirely: the real `bin/fm-crew-state.sh` reads the real lane with its endpoint removed, its emitted tokens are asserted, the same lane with a LIVE endpoint is asserted NOT to read endpoint-gone, and the same real reader is then handed to the gate.
- `test_an_ended_attempt_admits_a_fresh_execution_on_any_binding` - a force-discarded task deadlocked out of retrying on a different binding: the ended record still carried an `active` execution, so the rebind refusal fired with nothing executing, while `replace` refused on the discarded lane's missing custody. `end` now closes the execution it ends (reader and writer both: the guard exempts an ended record, `open` mints the retry a fresh execution, and no record can carry ended=1 with an executing dispatch again), with the live-record refusal asserted beside it so the exemption stays bounded.

The second review round also moved the ordinary-relaunch rebind refusal ahead of allocation: it previously fired only at `fm-attempt.sh open`, after a pool slot was selected (and reset) and a window's pane had entered it, so every refused rebind leaked a live window occupying a slot. The rebind case now also asserts that a refused rebind creates no window.
Every case listed above was authored against a defect that existed in the reviewed tree, but none has been through the defect-build watch below; what they establish is bounded to the assertions they print.

## Each control watched RED against its own defect build

A passing assertion establishes nothing on its own: an assertion that cannot fail passes for the same reason a correct one does.
So every control was measured a second way - the control was REMOVED from the implementation, the suite was re-run, and the case that names that control was observed to go red.

The apparatus refuses two ways of reaching a false green.
A mutation that matched nothing is reported `MUTATION-DID-NOT-APPLY`, and one that produced a byte-identical file is reported `MUTATION-CHANGED-NOTHING`; neither is ever recorded as a watched red.
A defect build that left the suite green is reported `DEFECT-NOT-CAUGHT`, and that is a finding about the test rather than about the code.
All three outcomes were reached during development and each was repaired before this record was written: one anchor stopped matching after a refactor, one defect build was survived because the control had a second enforcing path the defect did not remove, and one case was found to be passing on the wrong subject - it was asserting against a missing-metadata refusal rather than against the ownership record it claimed to measure.

Twenty-nine defect builds, twenty-nine watched reds, **29 of 29** - but measured in two passes, and the difference matters.
The nineteen rows above the door-3 block were measured 2026-08-19 against the tree they landed in; they were NOT re-run against this change, so what their cases establish here is that the assertions still execute and still pass, not that each removed clause is still the only thing controlling its verdict.
The seven door-3 and wiring rows were measured 2026-08-19 against the implementation as committed there, each mutation applied to the committed file, the suite re-run, and the file restored before the next build.
The three recorded-slot rows were measured 2026-08-21 by the suite's integrated watched-red helper, which first runs the public property against the shipped toolbelt and then against a disposable toolbelt copy carrying the named exact-clause defect.

| Control | Defect build | Observed red |
| --- | --- | --- |
| 1 - the lane continues on the SAME slot | the successor stops naming its own slot | `treehouse get ACQUIRES and RESETS a slot; a successor must never reach it` |
| 2 - the replacement requests no allocator slot | the successor branch never fires and falls through to the allocator | `the successor must not consult the allocator at all` |
| 3 - refused until the old process group is quiescent | the `alive` refusal is disabled | `a lane with a live process in its slot must be REFUSED, got rc=4` |
| 4 - the successor receives a NEW identity | the mint reuses the ordinal | `the successor must carry a NEW execution identity, got c04-a1/e1` |
| 5 - the work lineage is unchanged | the replacement also advances the work attempt | `a replacement must spend no attempt: the work did not fail` |
| 6 - unresolved questions and obligations survive | the successor dispatch clears the lane's event history | `an unresolved keyed decision must survive the replacement` |
| 7 - old evidence keeps its own producer | the ledger is rewritten instead of appended | `the predecessor's producer line must survive unchanged` |
| 8 - new evidence is attributed to the successor | the successor's line stops naming its predecessor | `the successor's line must name what it replaced` |
| 9 - an unqualified alternate refuses | the eligible-list membership test is dropped | `a model outside the route's pool must be REFUSED, got rc=0` |
| 10 - no qualified alternate leaves the lane held | HELD stops being an outcome | `a route with no eligible candidate must leave the lane HELD, got rc=1` |
| 11 - irreversible work in flight refuses | the active-run refusal is disabled | `a run in flight must REFUSE replacement, got rc=0` |
| 12 - ambiguous ownership returns could-not-observe | the process table is assumed readable | `an unreadable process table must be could-not-observe, got rc=0` |
| 13 - at most one active attempt after a crash | a stale execution id may be marked as the one running | `a stale execution must not be markable as dispatched` |
| 14 - allocation truth is never a directory count | the successor picks its slot by listing the pool directory | `the successor must land on the slot the record names, got .../pool/slot5` |
| recorded slot - identity comes from the Treehouse slot parent | the resolver treats the repository directory itself as the slot parent | `recorded worktree has no Treehouse slot parent: .../Treehouse Pool With Spaces/1/Repository With Spaces` |
| recorded slot - custody is established before exact-path verification | the holder never publishes readiness after entering the recorded worktree | `could not establish custody of worktree .../Treehouse Pool With Spaces/1/Repository With Spaces` |
| recorded slot - ordinary layouts retain their slot identity | the resolver substitutes the repository basename for the slot parent basename | `fake treehouse: unknown slot 'repository'` |
| boundary - only a CONFIRMED launch is protected | a confirmed launch is treated as an unstarted one | `an ordinary relaunch onto a different model must be refused` |
| pre-lineage - a lane with no recorded execution is ADOPTED, not refused | the adoption is removed and the landed refusal restored | `a pre-lineage lane must be replaceable, got rc=4`, on `COULD_NOT_OBSERVE - preline-a1 has no recorded execution attempt` |
| pre-lineage - the adoption reads a durable record and never invents one | the adoption stops requiring a named binding | `a lane whose binding cannot be read must be COULD_NOT_OBSERVE, got rc=0` |
| pre-lineage - the adopted token is never read as an unstarted launch | the adopted state falls into the `launching` permissive reading | `an ADOPTED execution must not be re-pointed onto another binding` |
| pre-lineage - the adopted producer's provenance is on the ledger | the adopted ledger line drops its disposition and unobserved-launch fields | `the adopted line must carry its own provenance disposition (missing: 'disposition=adopted-from-meta')` |
| door 3 - a dead endpoint with no run is OBSERVED quiescence | the composition is removed and the landed refusal restored | `a dead-endpoint lane must be replaceable, got rc=4`, on `COULD_NOT_OBSERVE - ... reported deadep-a1 as 'unknown', which is precisely the absence of usable evidence about what is in flight` |
| door 3 - only an ENDPOINT-ABSENT unknown composes | the precedence conjunct is dropped, so every unknown composes | `an unknown from a live endpoint must be COULD_NOT_OBSERVE, got rc=0` - and the defect build prints its own false composition, naming `busy-signal-unusable` as an endpoint that is not there |
| door 3 - an attributed run refuses whatever the endpoint is doing | the no-run conjunct is dropped | `an attributed run must refuse even under an endpoint-absent rule, got rc=0` |
| door 3 - the composition needs custody established first | the gates are reordered so the composition runs before custody is established | `a dead-endpoint lane must be replaceable, got rc=4`, on `... and its worktree custody was established as 'unestablished' rather than dead` |
| door 3 - the composition is durable, not only printed | the `inflight=` field is dropped from the line that closes the predecessor | `the close must record that the in-flight condition was composed, not observed idle (missing: 'inflight=observed-quiescent-endpoint-absent')` |
| the gate is asked in the shape that produces the states it enumerates | the landed `<id> --json` argument order restored | the suite dies on its FIRST case, `an exhausted primary with a qualified alternate must be sanctioned`, on `COULD_NOT_OBSERVE - ... could not report what c01-a1 is currently doing` - the stub refuses the prose order, so nothing downstream runs |
| the wrong-subject build - the stub cannot certify the wiring | the same argument order, with the stub's argument-order refusal removed | 27 of 28 cases GREEN and only `the gate must compose the REAL reader's answer, got rc=4`, on `COULD_NOT_OBSERVE - ... reported no state for realep-a1` |

The first pre-lineage row is the LIVE red: its defect build restores exactly the refusal that shipped, and the message it prints is the one the platform lane hit in production.
Its watched red is therefore a reproduction of the reported failure and not only a mutation of the fix.
The first door-3 row is the same kind of red for door 3: its defect build restores the landed `unknown` refusal verbatim, and the case fails on that refusal's own text.

The LAST row is the one that matters most about this suite rather than about the code.
It is the only build in the table that leaves the implementation defective and the fixtures untouched, and it shows 27 of 28 cases reporting green over a gate that could not read its source at all.
That is the measurement of how much a stub can certify: everything except whether the thing under test is wired to the thing it is specified against.
The real-reader case is what closed that gap, and it is what found the argument-order defect in the first place.

NON-VACUITY FOR THE ORDINARY PATH, measured the same day.
The adoption fires only on a record holding no execution, and the quiescence composition fires only on an endpoint-absent unknown with no attributed run, so a lane that has an execution and an ordinary observed state must be untouched by both.
Every case above them passes unchanged, and the neighbouring suites that execute `bin/fm-attempt.sh`, the current-state reader it now composes, and the dispatch chain ran with zero failures and positive executed counts: `fm-attempt` 10, `fm-classify` 8, `fm-crew-state` 78, `fm-capacity-retry` 20, `fm-teardown` 87, `fm-route-enforcement` 51, `fm-spawn-dispatch-profile` 27, `fm-exact-head-green-one-owner` 14.
Those are counts of assertions that RAN, not an absence of reported failures.
`fm-classify` and `fm-crew-state` are in that list because the endpoint-absent reading and the token extraction it uses live in `bin/fm-classify-lib.sh`, which `bin/fm-crew-state.sh` itself sources.
`bin/fm-lint.sh` passes on the pinned ShellCheck 0.11.0.

Four defect builds reach a different wrong answer rather than a false pass, which the cases still catch but which bounds what they establish.
Control 3's build reaches could-not-observe, because removing the `alive` refusal leaves the remaining `dead` requirement unsatisfied.
The boundary build fails the earlier "only door" case before reaching the case named for it.
The argument-order build fails the suite's FIRST case rather than the case named for it, because the stub refuses that call for every case at once; the un-stubbed variant in the last row is the one that isolates it.
The gate-reordering build reaches its red through the composition's custody conjunct, which is the only way to reach that conjunct at all - see the limitation recorded below.
In all four, the assertion is demonstrably controlled by the removed clause; what none of the runs establishes is that the clause is the ONLY thing standing between that input and a sanctioned replacement.

## The regression this capability caused, and why the state model has three values

The first implementation recorded an execution as running the moment its task metadata was published.
That broke the capacity owner's in-pool substitution (`tests/fm-capacity-retry.test.sh`, `a non-capacity refusal consults the route owner and resumes on its substitute`): a dispatch whose launch failed AFTER publishing metadata left a recorded producer that had never run, and the lawful retry on the next model in the pool was then refused as an unsanctioned rebind.

`execution_dispatch` therefore has three values rather than two.
`launching` is a published dispatch whose launch is unconfirmed, and it may be re-pointed onto another binding, because a launch that never started produced nothing and there is no producer to preserve.
`active` is a confirmed launch and may not be rebound by anything but the gate.
`sanctioned` is a successor the gate minted, and it refuses every dispatch except the one that succeeds it.

The residue is stated rather than closed: the confirmation is a separate write from the metadata publication, so a failure between them leaves a LIVE execution recorded as `launching`, which a later relaunch could rebind without the gate.
That failure is loud and names its reconciliation command, and it cannot happen silently, because `open` already refuses to launch at all when it cannot write that record.
Closing it properly needs the two writes to be one atomic operation, which they are not.

A fourth value, `adopted`, was added for the pre-lineage lane below.
It is neither of the two readings that already existed and must not collapse into either: its launch was never observed, so it satisfies nothing that requires a confirmed one, and the evidence in its lane is already attributed to it, so it is not re-pointable the way an unconfirmed `launching` execution is.
[`../../bin/fm-attempt.sh`](../../bin/fm-attempt.sh)'s header owns the full vocabulary; what is measured here is that the two readings diverge on the same record.

## The three-door class

**A reader-side gate meeting a state its own design did not enumerate.**

A gate is written against the states its author had in mind.
Every other state its sources can actually produce falls through to the strictest branch - which is the correct default and the wrong answer.
Strictness is not the defect; an incomplete enumeration of what the gate's sources can emit is.

THREE DOORS, all in this one capability, all found the same way: by taking ONE live lane - the platform lane - through its first real replacement, one door at a time.
Each was invisible until the door before it opened, which is why they arrived as three separate findings rather than one.

| Door | The state the gate met | The gate that met it | Where it came from |
| --- | --- | --- | --- |
| 1 - ended attempt | `ended=1` with an execution still recorded `active` | the rebind refusal fired with nothing executing, and `replace` refused on the discarded lane's missing custody | a writer that could produce that pair at all |
| 2 - zero lineage | `execution=0`, every lineage field absent | `replace` refused "no recorded execution attempt, so there is nothing to replace" | an earlier writer era, before these fields existed |
| 3 - dead endpoint | `unknown` under the `endpoint-gone` precedence, with no run attributed | `replace` read it as could-not-observe about what is in flight and refused | the current-state owner, working exactly as designed |

Door 1 came with its own writer defect, fixed beside it: `end` recorded the flag without closing the execution it ended, so the contradictory record could keep being written.
Door 2 reached PRODUCTION on the capability's first use, because every lane dispatched before the lineage landed carries exactly that record.
Door 3 reached production on the very next step of the very same lane.

DOOR 3 WIDENS THE CLASS, and that is the reason it is recorded rather than merely fixed.
Doors 1 and 2 were states a writer era never MEANT to produce - stale shapes, and the fix was to enumerate them.
Door 3 is a state its owner produces DELIBERATELY and correctly: `bin/fm-crew-state.sh` reports `unknown` for a run-less lane whose backend target is gone precisely so that a possibly-stale status log is never read as a live crew's current state.
Nothing was wrong with the producer.
What was wrong was the consumer's reading: it took one owner's narrow "I will not answer THIS question from THIS evidence" as "nothing is known here", when two other owners had each established a fact that, composed, answered the question positively.
So the class is not only about old records.
It is about a gate enumerating the states its own design imagined instead of the states its sources actually emit - and a designed, documented, current state is as easy to leave out of that enumeration as a stale one.

A THIRD VARIANT, found by the control that binds this gate to its real producer.
`replace` asked the current-state reader as `<id> --json`, and that reader recognizes `--json` in position 1 only, treating anything else as the task id.
So it answered in PROSE, the gate's extraction matched nothing, and every real replacement refused could-not-observe here - the enumeration was not merely incomplete, the gate had never once been asked in the shape that produces the states it enumerates.
It has been that way since the capability landed (`4956aefc`), so which of the two refusals the platform lane actually printed is not observable from this record; both are at this one gate, and both are fixed here.
Every case in this suite passed throughout, because the stub ignored its arguments and answered structured JSON to a call the real script renders as prose.
That is the same class one level up: the gate was written against the states its SOURCE can emit, and then wired to a source that could not emit them at all.
The stub now refuses that argument order, so the wiring is asserted rather than assumed.

The check the class implies, for any gate added over an owner's answer: enumerate the states the SOURCE can emit, not the states the new consumer expects, and prove the enumeration against the real source rather than a fixture written from the same expectation.
Pre-schema records, partially written records, records left by an interrupted write, and states the owner produces deliberately are all in that set, and each needs its own answer rather than the fall-through.
This fix adds two such states deliberately - `adopted`, which an interrupted adoption can leave, and the composed `observed-quiescent-endpoint-absent` disposition - and gives each its own token rather than letting either collapse into a neighbour, which is the same enumeration applied to the fix itself.

## What this record does not establish

It establishes that each named control is load-bearing for its case's verdict, and that the suite executes the assertions it prints.
It does not establish that the control set is COMPLETE.
The fourteen are the ones the commissioning brief declared, plus the boundaries the implementation itself created and the three doors found by taking one live lane through a real replacement; a failure mode nobody named would pass every case here.
Three of those doors were found that way and none of them by the control set, which is the strongest available evidence that the set is incomplete rather than merely unproven.

It also does not establish anything about the owners this gate composes.
Route eligibility, provider capacity, role qualification, agent liveness and current run state are each measured by their own suites; what is measured here is that this gate ASKS them, honours all three of their values, and refuses on the third.
The capacity term in particular keeps its owner's ruled asymmetry - an unmeasurable candidate stays eligible with its uncertainty disclosed - rather than being re-decided here, so "could not observe capacity" does not by itself refuse a replacement.
That is deliberate: re-deciding it here would be a second capacity policy.

The pre-lineage fixture is produced by REMOVING the lineage fields from a real dispatch, not by replaying an archived record.
Its field set was compared against the live platform lane that hit this in production and matches it exactly - `attempt`, `attempt_budget`, `failures`, `ended`, `updated` and nothing else - so what the cases drive is the shape that lane carries.
What that does not establish is that no OTHER pre-lineage record differs in some further way; it establishes the reader's behavior on the shape measured.

The adopted-token case constructs that record state directly rather than reaching it through an interrupted write.
It therefore measures the READER on a state the writer can leave, and not how likely the writer is to leave it.

THE CUSTODY CONJUNCT OF THE QUIESCENCE COMPOSITION IS NOT INDEPENDENTLY REACHABLE through the command line as the gates are ordered today.
`replace_custody_gate` runs first and exits on every verdict but `dead`, so by the time the composition reads the published custody state it can only be `dead`.
The conjunct is kept because it makes the composition explicit and fails closed if that order ever changes, and the red watch measures exactly that: the reordered defect build is the only way to reach it, and it goes red there.
What that establishes is that the conjunct is load-bearing under a reordering, not that the CLI can present an unestablished custody to it today.

The dead-endpoint composition is measured against the real `bin/fm-crew-state.sh` in one case and against a stub in the rest.
The real-reader case establishes that the producer emits the four tokens the gate composes, for a run-less lane whose endpoint is gone, on this machine and this backend.
It does not establish that every backend's endpoint removal reaches the same precedence: `no-backend-target`, the second endpoint-absent rule the gate admits, is exercised only through the stub, because the fixture always records a target.
It also does not establish anything about a lane whose endpoint is gone while a run it started is still executing somewhere else - the reader answers that from its run path, which the gate refuses, and the refusal is asserted from the stub rather than from a constructed live run.

The independence case drives a stubbed routing and qualification reader.
It measures this gate's handling of an adjudicated contract - refusing a maker as its own reviewer, and refusing outright when no maker is known - and not the qualification register's own verdicts, which `tests/fm-qualification.test.sh` and `tests/fm-route-qualification.test.sh` own.

## Reproducing the red watch

The defect builds are not committed; they are a development instrument, and a committed defect is a defect.
To repeat the watch, remove one control from the implementation, run the suite, and confirm the case that names that control fails - then restore the file from git before doing anything else.
Confirm the mutation actually changed the file first: a mutation that silently matched nothing produces a green run that reads exactly like a control nothing can break.

## The fixture vacuity this work was caught by, twice

Both defects that reached review on the success path were invisible to a green suite for
the same reason, one level above the assertions: **the fixture could not reach the
defect's precondition.**

The head-reset defect - a successor dispatch resetting a clean lane to its slot base and
orphaning the predecessor's commits - was found by a reviewer tracing the placement code,
not by any of the sixteen assertion groups then passing. Every `make_lane` worktree sits on
a NAMED BRANCH, because `fm_git_worktree` creates one, and the defect only fires on a clean
DETACHED lane. No assertion was wrong; the shape that would have failed was never built.
A suite whose fixtures cannot construct the failing precondition reports green for the same
reason a correct one does, which is the vacuity class this record already names one level
down, applied to fixtures rather than to assertions.

`test_a_detached_lane_keeps_the_predecessors_exact_head` builds that shape deliberately,
and control 1+2 keeps the branch-sitting shape beside it, so neither is now the only one
measured.

## Defence in depth, and what that costs a defect build

Two axes of the successor binding are pinned in TWO places: the spawn-side gate that
compares the sanctioned binding, and `attempt_exec_guard` in the attempt record, which
refuses a rebind of an execution that is not `launching`. A defect build that removes only
the spawn-side comparison therefore leaves the suite GREEN - the second layer still
refuses - and that is not a vacuous test, it is a redundantly enforced control.

Measured, so the record says which it is: with only the spawn-side model comparison
removed, the model axis is still refused by the attempt-record guard; with only the
spawn-side harness comparison removed, the harness axis is likewise still refused. The
honest defect build for either axis removes it from BOTH layers, and then the case goes red:

```
harness axis, both layers removed:
not ok - launching a successor onto a harness no gate admitted must be refused
```

A reader who watched only the single-layer build red-fail would have concluded the wrong
subject: that the spawn-side gate is what pins the axis. It is one of two things that do.

## What this change exposed in remote-secondmate teardown, and the bounded fix

This capability's branch deterministically failed
`tests/fm-remote-secondmate-lifecycle-e2e.test.sh`, which it does not touch. The
characterization took **16 executions** of that suite:

| Configuration | Result |
| --- | --- |
| this branch | FAIL 2/2 |
| `origin/main` | PASS 2/2 |
| this branch's `fm-spawn.sh` + main's `fm-attempt.sh` | PASS 2/2 |
| main's `fm-spawn.sh` + this branch's `fm-attempt.sh` | FAIL 2/2 |

The matrix isolates `bin/fm-attempt.sh`, and a trace of every invocation proves that file is
**never executed** during the test. The effect is therefore timing, not behavior: the larger
file shifts the interleaving of a concurrent teardown and respawn.

A dispatch trace then pinned the mechanism. `fm-remote-secondmate-control.sh retire` runs a
teardown whose own `FM_STATE_OVERRIDE` is `CONTROL_STATE`, which is
`<home>/state/parent-route` - INSIDE the home it deletes. It deletes the home while standing
in it, and leaves exactly that directory. The defect class is **standing inside the object
you delete**, and the residue is the deleting process's own working state.

The fix is bounded to reclaiming that residue: after the home deletion succeeds, the remote
side removes the control state it created. Four guards protect a removal that is recursive,
remote, and built from a variable, and each refuses loudly rather than skipping silently:
the path must be non-empty, absolute and end literally in `state/parent-route`; its prefix
must be the RECORDED home, never one recomputed from the residue; it must not resolve to
`/`, to `$HOME`, or outside the recorded home once symlinks are followed; and it runs only
after the deletion actually succeeded, proven by the home's seed marker being gone. A
recorded home that cannot itself be resolved leaves the containment judgment unestablished,
and that is a refusal too, never a skipped check - the second review round found the guard
defaulting to permitted there. Each guard has its own case in
`tests/fm-secondmate-safety.test.sh`, including the symlink escape, the `$HOME` target and
the unresolvable recorded home, each asserting that the protected content still exists
afterwards.

`bin/fm-teardown.sh` also called `retire_commitment_probe_cache` about 360 lines before its
definition, inside the remote branch that runs from the top-level dispatch, so that cleanup
step failed with `command not found` on every remote teardown. The definition is moved above
its first use. **Measured: fixing that alone does NOT make the e2e pass** - it was applied on
its own and the suite stayed red - so it is a real defect on the same path rather than the
cause.

Executed counts after the fix: the e2e passes **3 of 3** runs on this branch, where it failed
2 of 2 before. Non-vacuity: `fm-teardown`, `fm-secondmate-lifecycle-e2e`,
`fm-secondmate-safety`, `fm-execution-replacement` and `fm-remote-reply` ran with **0
failures**, so the ordinary local teardown path is untouched. The reclaim runs whenever the
remote branch completes, so it does not depend on the interleaving that exposed the residue -
which is what closes `main`'s latent exposure, since `main` avoided the path only by timing.

**The candidate long-term shape, left to the owner.** Placing the control state OUTSIDE the
home would stop the residue existing at all, rather than reclaiming it afterwards. That moves
where every reader of the remote protocol looks for that state, so it is a change to the
remote-secondmate lifecycle rather than cleanup of what one script created, and it is
deliberately not done here.
