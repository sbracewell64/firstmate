# Review envelope controls

Maintainer-verification record for [`bin/fm-review-envelope.sh`](../../bin/fm-review-envelope.sh) and [`bin/fm-review-envelope-lib.sh`](../../bin/fm-review-envelope-lib.sh), the `review-envelope/v1` contract, its compiler and its classifier.
The mutation evidence below covers 56 properties with targeted mutations of the kinds actually recorded: single-guard removals; inverted mutations that turn red when an accepting path breaks; and one redundantly enforced property that no single-guard mutation can falsify, measured with both independent guards removed.

The library header owns the contract itself, and [`docs/contracts/review-envelope.md`](../contracts/review-envelope.md) is generated from its field catalog.
This file records only what was measured, and when.

## Why watched red is the acceptance condition here

The envelope exists because four separate defects in one day were caught only by a human noticing: a green computed against a base far behind the trunk, recorded evidence citing a head that had since moved, a validation transcript whose own `git rev-parse HEAD` showed a pre-rebase commit while claiming to prove the successor, and a generic CI run cited as evidence for an acceptance dimension its gate never invoked.
A control against those defects that has only ever been seen green is indistinguishable from no control at all.

Two measurement failures from the same campaign are the reason each red below is checked for its INTENDED property rather than merely for being red.
One probe read a field that did not exist, so it failed unconditionally and corroborated whatever it was pointed at while measuring nothing.
Another exited zero because its request was rejected for an unrelated reason before ever reaching the property under test.

The second failure recurred here and was caught by this campaign.
The evidence-locator control originally pointed its escaping locator at a path that did not exist in the fixture's checked-out tree, so it refused because the file was missing and would have kept passing with the traversal guard removed.
It is now pointed at a file that exists outside the evidence root, whose digest matches, so the only thing standing between that locator and a review-ready envelope is the guard the control is named after.

Coverage here is counted PER PROPERTY, never per test function.
Three test functions covering nine properties is not thin coverage, and nine test functions would not by itself establish coverage either.
The mutation is the arbiter: a named property whose mutation leaves the suite green is uncovered no matter how many controls exist or what they are called.

## Environment

Measured 2026-08-16 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, Python 3.14.4 and GNU bash 5.3.9.
Every measurement below was taken against head `61cdb47b`, the commit whose subject bytes the campaign artifact records, so the table describes one experiment and is current for the code shipped here.

## Campaign artifact

The measurements below are backed by [`review-envelope-campaign.json`](review-envelope-campaign.json), which records the content digest of every measured subject.
A control fails when a subject's shipped bytes differ from the bytes measured, or when the claims below disagree with the artifact, so relabelling this prose contradicts the experiment instead of quietly redescribing it.

Campaign head: `61cdb47b65c1df89c308cb2edc2b54a17a55b76b`.
Mutations built: 72.

## Commands

The green pass, which must show every control passing:

```
bash tests/fm-review-envelope.test.sh
```

One red pass per mutation, where `<variant>` is a copy of BOTH `bin/fm-review-envelope.sh` and `bin/fm-review-envelope-lib.sh` into one directory, with exactly one edit:

```
FM_REVIEW_ENVELOPE_BIN=<variant>/bin/fm-review-envelope.sh bash tests/fm-review-envelope.test.sh
```

Both files are copied because the entrypoint sources its library from its own directory, so a variant carrying only one of them would test the tracked build.
`FM_REVIEW_ENVELOPE_BIN` is read only by the test file and defaults to the tracked script, so the seam exists for this measurement and changes nothing in production.

## What was measured

67 controls pass against the shipped scripts.
Count claim: the green count-drift control establishes only that the number stated above matches the suite's actual executed control count.
It says nothing about whether any control was ever watched red, and it is not evidence of mutation measurement.

Mutation-measurement claim: 72 mutations were built against the subjects recorded in the campaign artifact, and 71 turned the suite red.
Coverage is counted per property rather than per test function, because a named property whose mutation leaves the suite green is uncovered however many controls exist.

One mutation deliberately did not turn the suite red.
That one is listed in the table as a non-red with its reason, rather than dropped from the table or given a manufactured red, because a control whose redundancy makes it single-mutation-proof is a real property and stating it is more honest than a uniform table.

Each row is one property, the mutation aimed at it, and the exact first failing line that mutation produced, or an explicit non-red where that is what was measured.
Every mutation is a real edit to a real code path, and each build was confirmed to differ from the tracked script and to run before the suite was pointed at it.
That confirmation matters because a variant that never parsed would report a red line that measures the variant rather than the control.

Two rows are marked INVERTED. Those are non-vacuity mutations: they break the ACCEPTING path rather than a guard, and they are not optional, because without them the refusal mutations could all be red for the trivial reason that nothing validates at all.

| Property under test | Mutation injected | Observed result |
| --- | --- | --- |
| a complete candidate is review-ready | the envelope binds the base commit where the head belongs | `not ok - a complete candidate is review-ready: expected exit 0, got 1` |
| required contracts are computed from the changed files | a mandatory applicability rule stops being honoured | `not ok - a mandatory contract and a contract whose paths changed are both required` |
| verification applicability must be declared explicitly | absent and empty applicability declarations are accepted | `not ok - absent applicability rules are could-not-observe: expected exit 2, got 0` |
| an explicit no-contracts declaration is accepted | an explicit declaration with a reason is rejected | `not ok - an explicit reason may declare that no contracts are required: expected exit 0, got 2` |
| requested decisions accept only uppercase tokens | malformed requested-decision tokens are no longer refused | `not ok - a malformed requested decision refuses: expected exit 1, got 0` |
| identical facts produce an identical digest | the compile time is moved inside the digested body | `not ok - nothing time-varying may sit inside the digested body` |
| a stale envelope refuses | the candidate reference is no longer compared with the bound head | `not ok - a stale envelope refuses: expected exit 1, got 0` |
| a base that falls behind the trunk refuses | the base-to-trunk distance is no longer compared with policy | `not ok - the refusal must name the policy bound it exceeded (missing: 'refusal base_behind_main_exceeds_policy')` |
| an asserted head the repository contradicts refuses | the head asserted by the inputs is believed instead of checked | `not ok - a head asserted in prose that the repository contradicts refuses: expected exit 1, got 0` |
| a tampered envelope body refuses | the stored body is no longer re-digested on read | `not ok - the refusal must name the broken content address (missing: 'refusal envelope_digest_mismatch')` |
| an envelope is written once | an occupied output directory is reused instead of refused | `not ok - overwriting an envelope is could-not-observe: expected exit 2, got 0` |
| a missing required contract refuses | a required contract with no reference is skipped | `not ok - a required contract with no reference refuses: expected exit 1, got 0` |
| a missing required verifier result refuses | a required world with no result is skipped | `not ok - a required contract with no result refuses: expected exit 1, got 0` |
| a verifier result bound to another head refuses | a verifier result's head is no longer compared with the candidate | `not ok - a result bound to another head refuses: expected exit 1, got 0` |
| a missing red calibration refuses | a missing red calibration returns instead of refusing | `not ok - a passing verifier never observed failing refuses: expected exit 1, got 0` |
| a red calibration that records a pass refuses | the calibration's recorded outcome is no longer checked | `not ok - a calibration that never went red refuses: expected exit 1, got 0` |
| a could-not-observe verifier cannot become review-ready | a non-PASS verifier result falls through to the passing path | `not ok - a could-not-observe verifier is not a pass: expected exit 2, got 0` |
| a broken evidence digest refuses | the evidence check returns before it checks anything | `not ok - evidence that no longer matches its digest refuses: expected exit 1, got 0` |
| an evidence locator that escapes its root refuses | the lexical parent-traversal guard alone is removed | **NO RED - deliberate, see below**: containment is enforced twice and independently, so removing one guard alone does not falsify this control |
| a result that does not identify its verifier refuses | a result carrying no verifier identity is accepted | `not ok - a result that does not identify what produced it refuses: expected exit 1, got 0` |
| wrong head ci refuses | every attempt is treated as if it ran at the candidate head | `not ok - a required platform covered only by another head's run refuses: expected exit 1, got 0` |
| a skipped required check refuses | a skipped current check stops refusing | `not ok - a skipped required check refuses: expected exit 1, got 0` |
| an absent required platform refuses | an uncovered required platform stops refusing | `not ok - a required platform with no check at all refuses: expected exit 1, got 0` |
| a pending required check is could-not-observe | a still-running required check stops being could-not-observe | `not ok - a check still running has reached no verdict: expected exit 2, got 0` |
| duplicate attempts with no ordering refuse | unorderable repeated attempts are resolved anyway | `not ok - the refusal must name the check whose current attempt is undecidable (missing: 'refusal ci_duplicate_attempt_undecidable')` |
| two workflows sharing a check name stay two checks | checks are keyed by name alone, dropping the owning workflow | `not ok - one workflow's pass must not mask another workflow's failure: expected exit 1, got 0` |
| a superseded failure is replaced by its later rerun | every attempt is treated as current, not just the latest | `not ok - a superseded failure must not block its own successful rerun: expected exit 0, got 1` |
| alias fallback resolves a later declared candidate | only the first declared executable candidate is evaluated | `not ok - a capability whose first alias is absent and whose second is present is observed, not could-not-observe: expected exit 0, got 2` |
| an exhausted candidate set is could-not-observe | an unresolved required capability stops being could-not-observe | `not ok - an exhausted candidate set is could-not-observe: expected exit 2, got 0` |
| a candidate that will not state its identity is not a selection | a candidate that will not state its identity is selected anyway | `not ok - the unusable candidate must be recorded as identity_failed, not as absent` |
| a silently dropped obligation refuses | an unaccounted predecessor obligation is skipped | `not ok - an obligation that simply disappears refuses: expected exit 1, got 0` |
| a silently dropped obligation refuses | the predecessor's active obligations are read as an empty set | `not ok - the refusal must name the unaccounted obligation (missing: 'refusal obligation_dropped')` |
| every prior obligation may be accounted for explicitly | a discharged obligation is treated as still active | `not ok - explicit accounting for every prior obligation advances: expected exit 0, got 1` |
| a satisfied obligation without evidence refuses | satisfaction stops requiring named evidence | `not ok - satisfaction asserted without evidence refuses: expected exit 1, got 0` |
| a preserved obligation missing from the active set refuses | preservation stops requiring presence in the active set | `not ok - an obligation called preserved but absent refuses: expected exit 1, got 0` |
| a superseded obligation without a replacement refuses | supersession stops requiring an active replacement | `not ok - supersession pointing at nothing refuses: expected exit 1, got 0` |
| a resolution without an authority refuses | resolution stops requiring an authority and a reason | `not ok - a resolution with no authority refuses: expected exit 1, got 0` |
| a successor that declares no predecessor is could-not-observe | an absent predecessor block is assumed to mean a fresh chain | `not ok - an undeclared predecessor is could-not-observe: expected exit 2, got 0` |
| a disposition for an obligation the predecessor never held refuses | a disposition for an unheld obligation is accepted | `not ok - a disposition for an obligation nobody held refuses: expected exit 1, got 0` |
| a predecessor that is not the declared one is could-not-observe | the supplied predecessor's digest is no longer compared | `not ok - a predecessor that is not the declared one is could-not-observe: expected exit 2, got 1` |
| a ruling that does not apply cannot authorize a resolution | ruling head applicability is no longer compared at the classify site | `not ok - a ruling issued against another head cannot authorize anything here: expected exit 1, got 0` |
| a blocking adverse finding refuses | a blocking adverse finding stops refusing | `not ok - a blocking adverse finding refuses: expected exit 1, got 0` |
| a required unproven dimension is could-not-observe | a required unproven dimension stops being could-not-observe | `not ok - a required unproven dimension is could-not-observe: expected exit 2, got 0` |
| a fully excluded scope refuses | a scope that excludes everything stops refusing | `not ok - excluding everything refuses: expected exit 1, got 0` |
| excluded scope is bound explicitly | the rule that excluded a path is no longer recorded | `not ok - the envelope must name which rule excluded each path` |
| a contribution that changes nothing refuses | an empty changed-file set stops refusing | `not ok - the refusal must say the contribution changes nothing (missing: 'refusal changed_file_set_empty')` |
| a base the candidate does not descend from refuses | a base outside the candidate's ancestry stops refusing | `not ok - the refusal must name the base the candidate does not descend from (missing: 'refusal base_not_ancestor_of_candidate')` |
| a declared repository identity this is not refuses | the declared repository identity is no longer checked | `not ok - compiling against the wrong repository refuses: expected exit 1, got 0` |
| a check that names no head cannot cover a required platform | an attempt naming no head is treated as if it named one | `not ok - the refusal must say the platform has no exact-head check (missing: 'refusal ci_required_platform_uncovered')` |
| validate refuses to guess about evidence | validation guesses the evidence decision instead of refusing | `not ok - validation with no evidence decision is could-not-observe: expected exit 2, got 1` |
| declining the evidence recheck cannot reach review ready | a declined evidence recheck no longer blocks review-ready | `not ok - a declined evidence recheck cannot pass: expected exit 2, got 0` |
| validate rechecks evidence bytes | the evidence recheck arm never runs | `not ok - evidence replaced after compilation refuses at validation: expected exit 1, got 0` |
| the generated contract page matches the catalog | the generated contract page's section heading changes | `not ok - docs/contracts/review-envelope.md is stale; regenerate it with bin/fm-review-envelope.sh docs` |
| a crashed compiler cannot reach a verdict | an unreadable compiler result is read as a pass | `not ok - a compiler that produced no result is could-not-observe: expected exit 2, got 0` |
| symlink out of root refused before any byte is read or digested | real-path containment is removed, leaving only lexical checks | `not ok - a symlink outside the evidence root refuses: expected exit 1, got 0` |
| duplicate disposition refused, order A (later duplicate wins) | duplicate dispositions resolve by last-one-wins | `not ok - duplicate dispositions refuse in preserved-first order: expected exit 1, got 0` |
| duplicate disposition refused, order B (earlier duplicate wins) | duplicate dispositions resolve by first-one-wins | `not ok - the duplicate refusal must not depend on disposition order (missing: 'refusal obligation_disposition_duplicate')` |
| claimed identity mismatching a recomputation refuses | a mismatched declared identity stops refusing at compile time | `not ok - a mismatched claimed request identity refuses: expected exit 1, got 0` |
| a matching recomputation is accepted (non-vacuity, inverted) | INVERTED: a correctly matching claim is made to refuse | `not ok - a correctly recomputed request identity is accepted: expected exit 0, got 1` |
| deleting the claim refuses | the outer integrity digest is no longer recomputed on read | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| replacing the claim with the computed value refuses | the declared claim is dropped from the outer integrity payload | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| absent claim field is could-not-observe | an absent claim state is read as an explicit null | `not ok - an absent claim state is could-not-observe: expected exit 2, got 0` |
| explicit null claim is distinguishable from a missing field | an explicit null claim is collapsed into absent | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved envelope_unreadable')` |
| a correct claim with intact digests validates (non-vacuity, inverted) | INVERTED: an intact outer digest is made to refuse | `not ok - a structurally malformed body is could-not-observe: expected exit 2, got 1` |
| an evidence locator that escapes its root refuses | both evidence-root containment guards are removed | `not ok - a locator escaping its evidence root refuses: expected exit 1, got 0` |
| a ruling without a stable id refuses | a ruling with no stable id is accepted | `not ok - a missing ruling id refuses: expected exit 1, got 0` |
| duplicate ruling ids are ambiguous, order A | duplicate ruling ids stop being ambiguous | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 0` |
| duplicate ruling ids are ambiguous, order B | duplicate ruling ids are detected only when the pair does not start the list | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 0` |
| a ruling's envelope digest binds the current envelope | both ruling envelope-digest applicability sites are removed | `not ok - a relied-upon ruling bound to another envelope must refuse: expected exit 1, got 0` |
| a verifier result without a tree refuses | a verifier result's tree is no longer compared | `not ok - a result without a tree refuses: expected exit 1, got 0` |
| order-insensitive facts produce an identical identity | order-insensitive facts stop being canonicalised before digesting | `not ok - order-insensitive facts must have one envelope digest` |
| a structurally malformed envelope is could-not-observe | the malformed-body handler catches a narrower exception class | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved envelope_unreadable')` |

## The one mutation that stayed green, and why it is not a gap

Removing the lexical parent-traversal guard alone left the suite green.
That is not an uncovered property; it is redundancy. Evidence-root containment is now enforced twice and independently, by the lexical component check and by real-path containment, and either one alone still refuses `../outside.log`.

So the property was measured with BOTH guards removed, which is the last row of the table, and it turns red.
The consequence worth stating: no single-guard mutation can falsify that control, so a future change that removes one guard will not be caught by this suite.
Whoever removes either guard must re-measure with the remaining one removed too.

## Three properties measured directly rather than through the suite

The suite halts at its first failing assertion, and three properties are asserted after an earlier assertion in the same test function that the same mutation also breaks.
For those, the suite's first red belongs to the earlier assertion, so the property itself was measured directly against the same defect build by reproducing the fixture and exercising only the assertion in question.

| Property under test | Mutation injected | Observed directly |
| --- | --- | --- |
| replacing the claim with the computed value refuses | the declared claim is dropped from the outer integrity payload | `replacing-claim-refuses exit=0 (expected 1)` |
| an explicit null claim is distinguishable from a missing field | an explicit null claim is collapsed into absent | `explicit-null-claim-validates exit=2 (expected 0)` |
| a correct claim with intact digests validates | INVERTED: an intact outer digest is made to refuse | `matching-claim-intact-digests-validates exit=1 (expected 0)` |

Against the tracked build the same three measurements read `exit=1`, `exit=0` and `exit=0` respectively, so each is a real change of behaviour and not a constant.

## Two controls measured outside the mutation table

Two controls check this record against the suite rather than checking the compiler, so no mutation of the compiler can falsify them.
They were measured on scratch copies of the tree, by making the change each one exists to catch.

| Control | Change made | Observed |
| --- | --- | --- |
| the verification record matches the executed control count | a control added, the record left untouched | `not ok - the verification record states 63 controls, but the suite executed 64` |
| the measurement record is backed by the campaign artifact | the record's stated campaign head relabelled, nothing re-run | `not ok - the measurement record is not backed by the campaign artifact` |
| the measurement record is backed by the campaign artifact | one byte changed in a measured subject, nothing re-run | `not ok - the measurement record is not backed by the campaign artifact` |

Each was green on the untouched copy first, so none of those reds comes from a copy that never worked.
The second reading for the artifact control is the more valuable one: it catches drift nobody tried to hide, which is more common than deliberate relabelling.

## Only one control in this suite asserted acceptance alone

`a ruling's envelope digest binds the current envelope` once asserted only that a ruling bound to the current envelope applies.
That is the path which still works with the guard deleted, so the control measured nothing about the guard: removing both applicability sites left the whole suite green.
It now asserts the refusal, and that assertion goes red for its own reason when both sites are removed.

The general rule, because it generalises past this one control: for any guard, THE REFUSING ASSERTION IS THE CONTROL AND THE ACCEPTING ASSERTION IS THE NON-VACUITY ANCHOR.
They are not two halves of equal weight - one is the measurement, and the other only shows the measurement is not trivially red.

This campaign also establishes that it was the ONLY control of that shape here, with evidence rather than by assertion.
Any accepting-only control would leave its guard's deletion undetected and would therefore surface as a green mutation.
72 mutations produced exactly three greens, and all three are accounted for: two are the redundancy above, re-measured until red, and the third was this control.

## One commit's content was deliberately not carried forward

The validation gate repository held a commit, `6fb084c6` "record tracked suite result", on a lineage this branch no longer has.
It added a recorded suite result - a passing control line and a suite-contract line - for a head that has since been superseded.

Its content was NOT carried into this record, and the omission is deliberate rather than an oversight.
A recorded suite result for a lineage that no longer exists is exactly the stale claim this file exists to close: a record that no longer describes the head it is published with.
Carrying it forward would have reintroduced that defect at the moment the fabricated campaign claim was removed.

The commit itself is preserved and reachable in the gate repository at `refs/fm-recovery/review-envelope-gate-pre-force`, so nothing is lost by leaving its content out.

## A prior commit relabelled measurements it did not take

This is recorded because it is a measured failure of the process that produces this file, and because the commits that caused it are preserved in history rather than rewritten out of it.

Commit `f388e430` was titled "record final-head mutation campaign" and ran no campaign.
It was written as `50257ee3` and replayed under this id when the branch was later rebased; both ids name the same bytes, and this one is the one reachable in the history shipped here.
It was documentation-only, three insertions and eleven deletions, with no measurement data of any kind.
It deleted the hold declaring which controls were unwatched, deleted the separation between the count claim and the measurement claim, and rewrote the environment section so that measurements taken at head `1be1caef` were labelled as taken at head `98b1d34f`.
Commit `098cf2c4`, written as `7090fcd3`, then expanded that label to the full forty-character SHA, adding precision to a claim with no evidence beneath it, which makes a fabrication read as more rigorous rather than less.

The sharpest part is what the count-drift control did while that claim stood.
It PASSED, correctly, because the stated control count did match the suite.
A reader could therefore have taken a green control as evidence that the campaign had run, when the control had never examined that question at all - and the sentence that stopped it being read that way was the one the fabricating commit deleted.
The mechanism worked; the sentence that stopped it being misread did not survive.

That is the argument for the rule this file now follows: PROSE MUST NOT BE THE EVIDENCE.
A claim that is cheap to rewrite will eventually be rewritten, so the campaign must leave a durable artifact whose own content binds the head it was produced at, and this record's claims must be checkable against that artifact rather than asserted beside it.
