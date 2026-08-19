# Same-lane execution-attempt replacement verification

Audience: maintainer verification.

This record supports the execution-attempt lineage and the replacement gate in [`../../bin/fm-attempt.sh`](../../bin/fm-attempt.sh), the `--succeed-execution` dispatch in [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh), and the `owner-state` verb in [`../../bin/fm-worktree-guard.sh`](../../bin/fm-worktree-guard.sh).
It records what was measured about the controls on that transition, and the limits of what the measurement establishes.
Throughout, `attempt` is written in its qualified form; [`../vocabulary-collisions.md`](../vocabulary-collisions.md) owns that ruling.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The regression coverage is [`../../tests/fm-execution-replacement.test.sh`](../../tests/fm-execution-replacement.test.sh).

## What the suite executes

Measured 2026-08-19 on Linux 6.18 (WSL2), bash 5.2, git 2.53.0, shellcheck 0.11.0.

The suite runs **19 test functions covering the 14 declared controls, the boundary rules the implementation created, and three review-regression cases**, each driving `bin/fm-attempt.sh` and `bin/fm-spawn.sh` as executables against a real isolated git worktree, a real routed dispatch policy read by the real `bin/fm-route.sh`, and a controlled process table.
Nothing asserts implementation source bytes.

```
$ bash tests/fm-execution-replacement.test.sh
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
ok - a successor on a clean detached lane opens on the predecessor's exact head
ok - an orca lane refuses succession as unverified custody reuse, and the lane is untouched
ok - a successor dispatch cannot skip the gate that sanctions it
ok - only a confirmed launch is protected from rebinding; an unstarted one produced nothing
ok - a reviewing lane refuses a replacement that is not independent of its maker
ok - the execution ledger retires with the attempt record
```

That is a POSITIVE EXECUTED COUNT - nineteen assertion groups reported, listed rather than summarized - and not an absence of failures.
A run that executed nothing would print nothing here, which is the reason the list is recorded at all.
The suite takes about 70 seconds; the recorded portable-serial weight hint in `bin/fm-test-run.sh` is seeded from that measurement.

Three of the nineteen are review-regression cases added after the initial implementation was reviewed, each named for the defect it guards: the effort axis of the sanctioned binding left unpinned at the launch door, a clean DETACHED lane's head silently reset to the slot base by the successor dispatch (unreachable from the original fixtures, which all sat on a named branch), and an orca-backed lane's succession silently allocating a fresh worktree instead of refusing.
The orca case also pins the refusal's shape: its own exit status (3), the condition named as UNVERIFIED custody reuse rather than permanent unsupport, the pointer to this record as where a verified reuse path would be recorded, and the lane - worktree, metadata and sanctioned record - untouched afterwards.
The lift condition is self-contained: the refusal stands exactly until a verified orca custody-reuse path lands and its verification is recorded here, at which point the refusal, its case, and this paragraph all retire together.
These three were authored against defects that existed in the reviewed tree, but they have not been through the defect-build watch below; what they establish is bounded to the assertions they print.

## Each control watched RED against its own defect build

A passing assertion establishes nothing on its own: an assertion that cannot fail passes for the same reason a correct one does.
So every control was measured a second way - the control was REMOVED from the implementation, the suite was re-run, and the case that names that control was observed to go red.

The apparatus refuses two ways of reaching a false green.
A mutation that matched nothing is reported `MUTATION-DID-NOT-APPLY`, and one that produced a byte-identical file is reported `MUTATION-CHANGED-NOTHING`; neither is ever recorded as a watched red.
A defect build that left the suite green is reported `DEFECT-NOT-CAUGHT`, and that is a finding about the test rather than about the code.
All three outcomes were reached during development and each was repaired before this record was written: one anchor stopped matching after a refactor, one defect build was survived because the control had a second enforcing path the defect did not remove, and one case was found to be passing on the wrong subject - it was asserting against a missing-metadata refusal rather than against the ownership record it claimed to measure.

Measured 2026-08-19 against the implementation as committed. Fifteen defect builds, fifteen watched reds, **15 of 15**:

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
| boundary - only a CONFIRMED launch is protected | a confirmed launch is treated as an unstarted one | `an ordinary relaunch onto a different model must be refused` |

Two defect builds reach a different wrong answer rather than a false pass, which the cases still catch but which bounds what they establish.
Control 3's build reaches could-not-observe, because removing the `alive` refusal leaves the remaining `dead` requirement unsatisfied.
The boundary build fails the earlier "only door" case before reaching the case named for it.
In both, the assertion is demonstrably controlled by the removed clause; what neither run establishes is that the clause is the ONLY thing standing between that input and a sanctioned replacement.

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

## What this record does not establish

It establishes that each named control is load-bearing for its case's verdict, and that the suite executes the assertions it prints.
It does not establish that the control set is COMPLETE.
The fourteen are the ones the commissioning brief declared, plus the two boundaries the implementation itself created; a fifteenth failure mode nobody named would pass every case here.

It also does not establish anything about the owners this gate composes.
Route eligibility, provider capacity, role qualification, agent liveness and current run state are each measured by their own suites; what is measured here is that this gate ASKS them, honours all three of their values, and refuses on the third.
The capacity term in particular keeps its owner's ruled asymmetry - an unmeasurable candidate stays eligible with its uncertainty disclosed - rather than being re-decided here, so "could not observe capacity" does not by itself refuse a replacement.
That is deliberate: re-deciding it here would be a second capacity policy.

The independence case drives a stubbed routing and qualification reader.
It measures this gate's handling of an adjudicated contract - refusing a maker as its own reviewer, and refusing outright when no maker is known - and not the qualification register's own verdicts, which `tests/fm-qualification.test.sh` and `tests/fm-route-qualification.test.sh` own.

## Reproducing the red watch

The defect builds are not committed; they are a development instrument, and a committed defect is a defect.
To repeat the watch, remove one control from the implementation, run the suite, and confirm the case that names that control fails - then restore the file from git before doing anything else.
Confirm the mutation actually changed the file first: a mutation that silently matched nothing produces a green run that reads exactly like a control nothing can break.
