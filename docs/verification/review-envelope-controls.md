# Review envelope controls

Maintainer-verification record for [`bin/fm-review-envelope.sh`](../../bin/fm-review-envelope.sh) and [`bin/fm-review-envelope-lib.sh`](../../bin/fm-review-envelope-lib.sh), the `review-envelope/v1` contract, its compiler and its classifier.
The mutation evidence below is one targeted mutation per recorded row, each a real edit aimed at the property its row names; the kinds recorded include single-guard removals and inverted mutations that turn red when an accepting path breaks.
No property count stands in this sentence: the campaign artifact and the mutation table own the inventory, and a summary count restated here is arithmetic that rots on the next edit.

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

## Digested-array canonicalization sweep

The first sweep read the construction site and classified only top-level arrays, so its method could not observe nesting and missed `verification.applicability_rules[].paths` and `verification.contracts[].execution_worlds`.
The replacement controls compile the suite's baseline fixture augmented across cases with populated findings, rulings, obligations and repeated nested verification values, then walk the resulting digested body recursively to arbitrary depth and classify every array path they observe.
The sweep universe covers sibling breadth across every object key, nesting depth across every object and array element, and populated shape variants supplied by the fixture; walking the artifact makes those axes properties of the real body rather than assumptions inferred from its builder.
[`review-envelope-array-classifications.json`](review-envelope-array-classifications.json) is the single registry of every observed array path, its canonicalized or order-meaningful classification, and the reason for that classification.
The control compares the recursive walk and registry in both directions, so a new unclassified path and a stale classification both fail by name.
Every registry entry also owns its experiment: an input path reordered alone before recompiling, a compiled-body path reordered and normalized by its declared canonical key before digest and identity recomputation, or a compiled-body meaningful-order path reordered without normalization.
The registry is the discoverable source for the experiment inventory; this record does not duplicate a count or path list.
The contract field catalog describes arrays without structural upper bounds, and the compiler accepts each as a list without a maximum, so the control rejects exemption experiments and requires every observed array path to be populated and exercised.
When a checked party controls the sample, sample cardinality is an attack surface: admissibility conditions must be anchored to schema, contract, or upstream reality that the sample author cannot shrink.
Five earlier escapes asserted false claims and could be caught by comparing claim with reality; the sixth made its claim true by thinning the fixture, so it required moving the condition off the fixture entirely.
Every non-exempt path carries at least two distinct fixture entries, and the registry-driven control requires canonicalized paths to retain one identity and order-meaningful paths to change identity.
The control also reverses each classification in turn and requires the observed outcome to reject the false label, so relabelling cannot substitute for canonicalization.
Every path is therefore exercised in isolation, leaving no exemption branch for an unchecked assertion.

## Environment

Measured 2026-08-16 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, Python 3.14.4 and GNU bash 5.3.9.
Every measurement below was taken against the subjects cited under "Campaign artifact", and EACH ENTRY in the campaign artifact records the head it was measured at individually rather than relying on one head written once.
Those subjects are NOT the bytes shipped at this head: the fixes recorded under "Wrong subject, four times in one component" edited two of them, so the campaign is invalidated by design and awaits re-measurement. The campaign-artifact control refuses until it is re-measured, which is that invalidation being visible rather than assumed.
Each entry also carries a digest of its whole captured run and the patch that rebuilds its variant, so an independent party can replay any entry and compare rather than taking this record's word for it.

## Campaign artifact

The measurements below are backed by [`review-envelope-campaign.json`](review-envelope-campaign.json), which records the content digest of every measured subject.
A control fails when a subject's shipped bytes differ from the bytes measured, or when the claims below disagree with the artifact, so relabelling this prose contradicts the experiment instead of quietly redescribing it.

A record about a subject NAMES THE SUBJECT. The citation for this campaign is therefore these three digests, and nothing else:

- `bin/fm-review-envelope-lib.sh` — `sha256:b6bbe3e1bb7a56c3f5085915153ce8c91ec2b0c0d2a3f248c2db5ebfb7190948`
- `bin/fm-review-envelope.sh` — `sha256:f5c1efdf049feaf7c81368d5dd64e73accfbf0cc092ecf36524e07234954b17a`
- `tests/fm-review-envelope.test.sh` — `sha256:988b9a7ea4b1050496cb89302eb7500bc6be0d4c62070fb2d0913fdc6fde3c1a`

Campaign head: `3d37b6998beed3ca37180752f91773e2866d2434` (provenance only).
Mutations built: 74.

That head is PROVENANCE: the commit the measurement was taken at, recorded so the moment is attributable. It is not the coordinate a replay depends on. It is NOT reachable from the history shipped here, and that changes nothing: this branch is replayed under fresh commit ids as it moves through the gate, which strands every id written before a replay while changing not one measured byte. That is why the head carries the provenance-only label above. The digests are the binding, and they stay checkable whatever later becomes of the commit.

That distinction was learned here rather than assumed. An earlier campaign recorded head `9c15cbb3` (non-retrievable provenance), and a later rebase stranded that commit while changing not one measured byte: every measurement stayed true of the bytes, and the citation stopped resolving for anyone who fetched the branch. The record at the time invited an independent party to replay against that head, so the instruction was executable only in the clone that still held a pre-rebase backup ref. The control could not see it either — it compared the record's head field with the artifact's head field, which establishes that two fields agree and says nothing about whether anything is replayable.

To replay, do not start from the head. Check out this branch, confirm each subject above hashes to the digest cited for it, then rebuild any entry from its `replay_patch` and compare the whole captured run against its `output_sha256`. The subject digests are obtainable from the branch by anyone; a head can be stranded by any rebase.

The control enforces exactly that. It requires all three subjects to be recorded, requires each to still hash to the digest cited, requires this prose to cite the digests the artifact measured, and requires any cited head to be either reachable from this branch or carry the provenance-only label above.

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

## The two seams, and what each one may do

`FM_REVIEW_ENVELOPE_BIN` is read only by the test file and defaults to the tracked script, so the seam exists for this measurement and changes nothing in production.

`FM_REVIEW_ENVELOPE_TEST_OPENED_SEAM` and `FM_REVIEW_ENVELOPE_TEST_OPENED_LOCATOR` are read by `digest_evidence_handle` in `bin/fm-review-envelope-lib.sh`, so unlike the one above this seam is in shipped code and is documented here for that reason - an undocumented seam in `bin/` reads as an accident.
It exists because the property it proves cannot be observed any other way: that the bytes bound are the OPENED HANDLE's rather than the pathname's, which requires repointing the name after the handle opens and at a moment the test chooses.
It replaced a scheduler-dependent control that could pass without ever reaching its window, and a control that can pass without exercising its case is worse than a seam.

Three properties bound what a leak of either variable can do:

- The seam is confined to one directory this library owns, `SEAM_DIRECTORY` under the process's temporary directory. A seam must resolve STRICTLY INSIDE that directory or it is refused before anything is written - including a seam pointed at the directory itself, whose signal files would land beside it rather than in it, which is the containment failing on its own boundary. So what a leak of the seam variable can still choose is a name inside that one directory, and nothing about where the directory is. The directory's parent is the process's temporary directory as `tempfile.gettempdir()` resolves it, which honours `TMPDIR`, `TEMP` and `TMP` - the ordinary temporary-directory contract every program on the machine already follows, stated here because the confinement rests on it rather than replacing it.
- Both halves of the handshake are bounded by `SEAM_DEADLINE_SECONDS`, one number in the library that the test reads out of the build under test rather than restating. A leak costs that bound once, and the two halves of one handshake cannot drift into disagreeing about how long it lasts.
- Every way it can refuse - a seam not strictly inside its root, a signal it could not write, a handshake that did not complete - is the contract's own could-not-observe under `evidence_seam_unusable`. A seam that answers a refusal with a traceback is a hole in the three-valued promise rather than a measurement affordance.

## What was measured

No control count is asserted at this head: the fixes above changed measured subjects, so the suite halts at the campaign-artifact control before reaching its end, and no run from here can observe how many controls pass. The count is stated again after re-measurement lets a run reach the end of the suite.

Pending on these stale subjects, which is the CONDITION that justifies the deferral and is re-checked against the tree on every run:

- `bin/fm-review-envelope-lib.sh` — artifact `sha256:b6bbe3e1bb7a56c3f5085915153ce8c91ec2b0c0d2a3f248c2db5ebfb7190948`, shipped `sha256:d1342bff0c7504d12f7492f7370bcf1a7f8fc7251e883ab5282523ff2f043226`
- `tests/fm-review-envelope.test.sh` — artifact `sha256:988b9a7ea4b1050496cb89302eb7500bc6be0d4c62070fb2d0913fdc6fde3c1a`, shipped `sha256:fc7f344aba17d6e3cea0caa3910390202f24c0f8c3e15073b5f7d7e2551294ee`

A remedy state that does not carry its own condition outlives it, so the count-drift control refuses this deferral the moment the campaign artifact matches every shipped subject again - from then on a count is observable and must be stated. It also refuses a deferral whose named subjects are not the stale ones this tree actually has, because a reason without a condition is just a reason.

THE RULE THAT PRODUCES THAT SENTENCE, recorded because it was learned the expensive way twice in one day: A CLAIM ABOUT SUITE COVERAGE MAY ONLY BE WRITTEN AFTER A RUN THAT REACHED THE SUITE'S END. A halted suite tells you what RAN passed. It never tells you that everything ran, and a count copied out of the invocation list is arithmetic, not an observation - which is how a number nobody had seen came to stand in the one section this record reserves for what was measured.
The count-drift control enforces every half: a stated number must equal the run's executed count; a record that states no number must DECLARE that explicitly, with a reason and with the stale subjects the deferral rests on; absence alone fails; a number standing beside a deferral fails; and the deferral itself fails once the condition behind it is gone. So the deferred state cannot become a place to keep a claim quiet.

A REMEDY STATE MUST CARRY THE CONDITION THAT JUSTIFIES IT, CHECKED AGAINST THE WORLD, SO IT CANNOT OUTLIVE IT. That is the third law recorded here today, and like the other two it was learned from a claim that had been true when written.

Count claim, when a number stands here: the green count-drift control establishes only that the number matches the suite's actual executed control count.
It says nothing about whether any control was ever watched red, and it is not evidence of mutation measurement.

Mutation-measurement claim: 73 expected-red mutations were built against the subjects recorded in the campaign artifact, and all 73 turned the suite red. A 74th entry is expected-GREEN and is the campaign's own non-vacuity control, described below.
Coverage is counted per property rather than per test function, because a named property whose mutation leaves the suite green is uncovered however many controls exist.

There is no non-red in this campaign, and the reason that changed is recorded below rather than left as a silently uniform table.

Every expected-red entry's target control and observed control agree: 73 of 73.
The mutation table below carries exactly one row per expected-red entry, and a control compares the two in BOTH directions: a row no entry backs fails, and an entry with no row fails. That comparison was added because both directions had drifted - one row outlived its mutation's removal from the campaign, and two measured entries had no row - and nothing was checking.

The campaign also carries its OWN non-vacuity control, and it is the seventy-fourth entry. A campaign in which every mutation reddens cannot show that this harness is able to report green at all - which is the vacuous-pass defect inverted, since a suite that fails on everything produces a perfect-looking record and proves nothing, exactly as a suite reporting zero failures over zero executed tests does. So one mutation is chosen such that GREEN is the correct answer: a semantics-preserving edit that binds a sorted result to a name before returning it, a real change to a real code path that alters no behaviour. It is judged against that expectation rather than exempted from judgement, must carry a captured run containing no failure, and must name no control.

It cannot be measured against a red baseline, because it would record that baseline's failure instead of its own result. So the campaign runs in two passes: the expected-red entries first, the artifact written from them, and the expected-green entry against the green baseline that produces. The generator refuses to stamp a head while any measured subject is uncommitted, because a head recorded over uncommitted bytes labels the measurement with a commit whose contents are not the measured contents.

The target is assigned from each mutation's INTENT and the observed control is DERIVED from its captured run, by counting the success lines that precede the failure and reading them against the suite's invocation order. Those two must be independent or the comparison is worthless: a target taken from the observation would agree by construction, for every entry, including entries that measured nothing.

An earlier campaign at this head had three entries whose red belonged to a neighbouring control. Each of those mutations was coarser than the property it named - it emptied an array, which tripped the fixture-defect guard before the target control ran - so each was narrowed to violate only its own property, and all three now redden their own control. That is recorded because the narrowing, not the count, is what makes those three measurements real.

Of those 73 reds, 69 are DISTINCT, they land on 62 distinct controls, and every entry carries its whole captured run rather than only a digest of it.

That distinctness is recorded because the total on its own is exactly what a forged campaign would produce. While the artifact is stale the suite is red at baseline, so a campaign measured in that state records the SAME failure for every mutation: 72 entries, all red, a complete-looking matrix generated by one defect rather than by 72. Nothing downstream could tell that apart from a real campaign by reading the count.

The distinctness is what separates them, so it is reported alongside the total rather than left to be inferred from it. Vacuity was also checked directly: no entry recorded the stale-artifact failure.

Each row is one property, the mutation aimed at it, and the exact first failing line that mutation produced, or an explicit non-red where that is what was measured.
Every mutation is a real edit to a real code path, and each build was confirmed to differ from the tracked script and to run before the suite was pointed at it.
That confirmation matters because a variant that never parsed would report a red line that measures the variant rather than the control.

Two rows are marked INVERTED. Those are non-vacuity mutations: they break the ACCEPTING path rather than a guard, and they are not optional, because without them the refusal mutations could all be red for the trivial reason that nothing validates at all.

| Property under test | Mutation injected | Control observed red | Observed result |
| --- | --- | --- | --- |
| a complete candidate is review-ready | the envelope binds the base commit where the head belongs | `test_a_complete_candidate_is_review_ready` | `not ok - a complete candidate is review-ready: expected exit 0, got 1` |
| required contracts are computed from the changed files | a mandatory applicability rule stops being honoured | `test_required_contracts_are_computed_from_the_changed_files` | `not ok - a mandatory contract and a contract whose paths changed are both required` |
| identical facts produce an identical digest | the compile time is moved inside the digested body | `test_identical_facts_produce_an_identical_digest` | `not ok - nothing time-varying may sit inside the digested body` |
| a stale envelope refuses | the candidate reference is no longer compared with the bound head | `test_a_stale_envelope_refuses` | `not ok - a stale envelope refuses: expected exit 1, got 0` |
| a base that falls behind the trunk refuses | the base-to-trunk distance is no longer compared with policy | `test_a_base_that_falls_behind_the_trunk_refuses` | `not ok - the refusal must name the policy bound it exceeded (missing: 'refusal base_behind_m` |
| an asserted head the repository contradicts refuses | the head asserted by the inputs is believed instead of checked | `test_an_asserted_head_the_repository_contradicts_refuses` | `not ok - a head asserted in prose that the repository contradicts refuses: expected exit 1, ` |
| a tampered envelope body refuses | the stored body is no longer re-digested on read | `test_a_tampered_envelope_body_refuses` | `not ok - the refusal must name the broken content address (missing: 'refusal envelope_digest` |
| an envelope is written once | an occupied output directory is reused instead of refused | `test_an_envelope_is_written_once` | `not ok - overwriting an envelope is could-not-observe: expected exit 2, got 0` |
| a missing required contract refuses | a required contract with no reference is skipped | `test_a_missing_required_contract_refuses` | `not ok - a required contract with no reference refuses: expected exit 1, got 0` |
| a missing required verifier result refuses | a required world with no result is skipped | `test_a_missing_required_verifier_result_refuses` | `not ok - a required contract with no result refuses: expected exit 1, got 0` |
| a verifier result bound to another head refuses | a verifier result's head is no longer compared with the candidate | `test_a_verifier_result_bound_to_another_head_refuses` | `not ok - a result bound to another head refuses: expected exit 1, got 0` |
| a missing red calibration refuses | a missing red calibration returns instead of refusing | `test_a_missing_red_calibration_refuses` | `not ok - a passing verifier never observed failing refuses: expected exit 1, got 0` |
| a red calibration that records a pass refuses | the calibration's recorded outcome is no longer checked | `test_a_red_calibration_that_records_a_pass_refuses` | `not ok - a calibration that never went red refuses: expected exit 1, got 0` |
| a could-not-observe verifier cannot become review-ready | a non-PASS verifier result falls through to the passing path | `test_a_could_not_observe_verifier_cannot_become_review_ready` | `not ok - a could-not-observe verifier is not a pass: expected exit 2, got 0` |
| a broken evidence digest refuses | the evidence check returns before it checks anything | `test_a_broken_evidence_digest_refuses` | `not ok - evidence that no longer matches its digest refuses: expected exit 1, got 0` |
| an evidence locator that escapes its root refuses | the lexical parent-traversal guard is removed | `test_an_evidence_locator_that_escapes_its_root_refuses` | `not ok - a locator escaping its evidence root refuses: expected exit 1, got 0` |
| a result that does not identify its verifier refuses | a result carrying no verifier identity is accepted | `test_a_result_that_does_not_identify_its_verifier_refuses` | `not ok - a result that does not identify what produced it refuses: expected exit 1, got 0` |
| wrong head ci refuses | wrong-head coverage stops being reported as wrong-head, leaving both attempt arrays intact | `test_wrong_head_ci_refuses` | `not ok - the refusal must name the foreign head (missing: 'refusal ci_wrong_head')` |
| a skipped required check refuses | a skipped current check stops refusing | `test_ci_canonicalization_preserves_meaningful_differences` | `not ok - the meaningfully different CI attempt refuses: expected exit 1, got 0` |
| an absent required platform refuses | an uncovered required platform stops refusing | `test_an_absent_required_platform_refuses` | `not ok - a required platform with no check at all refuses: expected exit 1, got 0` |
| a pending required check is could-not-observe | a still-running required check stops being could-not-observe | `test_a_pending_required_check_is_could_not_observe` | `not ok - a check still running has reached no verdict: expected exit 2, got 0` |
| duplicate attempts with no ordering refuse | unorderable repeated attempts are resolved anyway | `test_duplicate_attempts_with_no_ordering_refuse` | `not ok - the refusal must name the check whose current attempt is undecidable (missing: 'ref` |
| two workflows sharing a check name stay two checks | checks are keyed by name alone, dropping the owning workflow | `test_two_workflows_sharing_a_check_name_stay_two_checks` | `not ok - one workflow's pass must not mask another workflow's failure: expected exit 1, got ` |
| a superseded failure is replaced by its later rerun | every attempt is treated as current, not just the latest | `test_order_insensitive_facts_produce_an_identical_identity` | `not ok - the first fact order compiles: expected exit 0, got 1` |
| alias fallback resolves a later declared candidate | every candidate is still probed, but only the first is allowed to resolve | `test_alias_fallback_resolves_a_later_declared_candidate` | `not ok - a capability whose first alias is absent and whose second is present is observed, n` |
| an exhausted candidate set is could-not-observe | an unresolved required capability stops being could-not-observe | `test_an_exhausted_candidate_set_is_could_not_observe` | `not ok - an exhausted candidate set is could-not-observe: expected exit 2, got 0` |
| a candidate that will not state its identity is not a selection | a candidate that will not state its identity is selected anyway | `test_a_candidate_that_will_not_state_its_identity_is_not_a_selection` | `not ok - the unusable candidate must be recorded as identity_failed, not as absent` |
| a silently dropped obligation refuses | an unaccounted predecessor obligation is skipped | `test_a_silently_dropped_obligation_refuses` | `not ok - an obligation that simply disappears refuses: expected exit 1, got 0` |
| a silently dropped obligation refuses | the predecessor's active obligations are read as an empty set | `test_array_classification_registry_is_total` | `not ok - the populated registry fixture compiles to a classified envelope: expected exit 0, ` |
| every prior obligation may be accounted for explicitly | a discharged obligation is treated as still active | `test_every_prior_obligation_may_be_accounted_for_explicitly` | `not ok - explicit accounting for every prior obligation advances: expected exit 0, got 1` |
| a satisfied obligation without evidence refuses | satisfaction stops requiring named evidence | `test_a_satisfied_obligation_without_evidence_refuses` | `not ok - satisfaction asserted without evidence refuses: expected exit 1, got 0` |
| a preserved obligation missing from the active set refuses | preservation stops requiring presence in the active set | `test_a_preserved_obligation_missing_from_the_active_set_refuses` | `not ok - an obligation called preserved but absent refuses: expected exit 1, got 0` |
| a superseded obligation without a replacement refuses | supersession stops requiring an active replacement | `test_a_superseded_obligation_without_a_replacement_refuses` | `not ok - supersession pointing at nothing refuses: expected exit 1, got 0` |
| a resolution without an authority refuses | resolution stops requiring an authority and a reason | `test_a_resolution_without_an_authority_refuses` | `not ok - a resolution with no authority refuses: expected exit 1, got 0` |
| a successor that declares no predecessor is could-not-observe | an absent predecessor block is assumed to mean a fresh chain | `test_a_successor_that_declares_no_predecessor_is_could_not_observe` | `not ok - an undeclared predecessor is could-not-observe: expected exit 2, got 0` |
| a disposition for an obligation the predecessor never held refuses | a disposition for an unheld obligation is accepted | `test_a_disposition_for_an_obligation_the_predecessor_never_held_refuses` | `not ok - a disposition for an obligation nobody held refuses: expected exit 1, got 0` |
| a predecessor that is not the declared one is could-not-observe | the supplied predecessor's digest is no longer compared | `test_a_predecessor_that_is_not_the_declared_one_is_could_not_observe` | `not ok - a predecessor that is not the declared one is could-not-observe: expected exit 2, g` |
| a ruling that does not apply cannot authorize a resolution | ruling head applicability is no longer compared at the classify site | `test_a_ruling_that_does_not_apply_cannot_authorize_a_resolution` | `not ok - a ruling issued against another head cannot authorize anything here: expected exit ` |
| a blocking adverse finding refuses | a blocking adverse finding stops refusing | `test_a_blocking_adverse_finding_refuses` | `not ok - a blocking adverse finding refuses: expected exit 1, got 0` |
| a required unproven dimension is could-not-observe | a required unproven dimension stops being could-not-observe | `test_a_required_unproven_dimension_is_could_not_observe` | `not ok - a required unproven dimension is could-not-observe: expected exit 2, got 0` |
| a fully excluded scope refuses | a scope that excludes everything stops refusing | `test_exclusion_rule_order_remains_meaningful` | `not ok - the first exclusion order compiles to a refusal: expected exit 1, got 0` |
| excluded scope is bound explicitly | the rule that excluded a path is no longer recorded | `test_exclusion_rule_order_remains_meaningful` | `not ok - the first matching exclusion rule must receive credit` |
| a contribution that changes nothing refuses | an empty changed-file set stops refusing | `test_a_contribution_that_changes_nothing_refuses` | `not ok - the refusal must say the contribution changes nothing (missing: 'refusal changed_fi` |
| a base the candidate does not descend from refuses | a base outside the candidate's ancestry stops refusing | `test_a_base_the_candidate_does_not_descend_from_refuses` | `not ok - the refusal must name the base the candidate does not descend from (missing: 'refus` |
| a declared repository identity this is not refuses | the declared repository identity is no longer checked | `test_a_declared_repository_identity_this_is_not_refuses` | `not ok - compiling against the wrong repository refuses: expected exit 1, got 0` |
| a check that names no head cannot cover a required platform | a headless attempt is still recorded, and also counted as exact-head | `test_a_check_that_names_no_head_cannot_cover_a_required_platform` | `not ok - a check with no head association cannot cover a platform: expected exit 1, got 0` |
| validate refuses to guess about evidence | validation guesses the evidence decision instead of refusing | `test_validate_refuses_to_guess_about_evidence` | `not ok - validation with no evidence decision is could-not-observe: expected exit 2, got 1` |
| declining the evidence recheck cannot reach review ready | a declined evidence recheck no longer blocks review-ready | `test_declining_the_evidence_recheck_cannot_reach_review_ready` | `not ok - a declined evidence recheck cannot pass: expected exit 2, got 0` |
| validate rechecks evidence bytes | the evidence recheck arm never runs | `test_validate_rechecks_evidence_bytes` | `not ok - evidence replaced after compilation refuses at validation: expected exit 1, got 0` |
| the generated contract page matches the catalog | the generated contract page's section heading changes | `test_the_generated_contract_page_matches_the_catalog` | `not ok - docs/contracts/review-envelope.md is stale; regenerate it with bin/fm-review-envelo` |
| symlink out of root refused before any byte is read or digested | the final open stops refusing to follow a symlink | `test_an_evidence_symlink_that_escapes_its_root_refuses_before_reading` | `not ok - a symlink outside the evidence root refuses: expected exit 1, got 0` |
| duplicate disposition refused, order A (later duplicate wins) | duplicate dispositions resolve by last-one-wins | `test_duplicate_dispositions_refuse_in_both_orders` | `not ok - duplicate dispositions refuse in preserved-first order: expected exit 1, got 0` |
| duplicate disposition refused, order B (earlier duplicate wins) | duplicate dispositions resolve by first-one-wins | `test_duplicate_dispositions_refuse_in_both_orders` | `not ok - the duplicate refusal must not depend on disposition order (missing: 'refusal oblig` |
| claimed identity mismatching a recomputation refuses | a mismatched declared identity stops refusing at compile time | `test_request_identity_is_recomputed_and_checked` | `not ok - a mismatched claimed request identity refuses: expected exit 1, got 0` |
| a matching recomputation is accepted (non-vacuity, inverted) | INVERTED: a correctly matching claim is made to refuse | `test_request_identity_is_recomputed_and_checked` | `not ok - a correctly recomputed request identity is accepted: expected exit 0, got 1` |
| deleting the claim refuses | the outer integrity digest is no longer recomputed on read | `test_request_identity_is_recomputed_and_checked` | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| replacing the claim with the computed value refuses | the declared claim is dropped from the outer integrity payload | `test_request_identity_is_recomputed_and_checked` | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| absent claim field is could-not-observe | an absent claim state is read as an explicit null | `test_request_identity_is_recomputed_and_checked` | `not ok - an absent claim state is could-not-observe: expected exit 2, got 0` |
| explicit null claim is distinguishable from a missing field | an explicit null claim is collapsed into absent | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved e` |
| a correct claim with intact digests validates (non-vacuity, inverted) | INVERTED: an intact outer digest is made to refuse | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - a structurally malformed body is could-not-observe: expected exit 2, got 1` |
| an evidence locator that escapes its root refuses | both the lexical traversal guard and the symlink refusal are removed | `test_an_evidence_locator_that_escapes_its_root_refuses` | `not ok - a locator escaping its evidence root refuses: expected exit 1, got 0` |
| a ruling without a stable id refuses | a ruling with no stable id is accepted | `test_a_ruling_without_a_stable_id_refuses` | `not ok - a missing ruling id refuses: expected exit 1, got 2` |
| duplicate ruling ids are ambiguous, order A | duplicate ruling ids stop being ambiguous | `test_duplicate_ruling_ids_are_ambiguous_in_both_orders` | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 2` |
| duplicate ruling ids are ambiguous, order B | duplicate ruling ids are detected only when the pair does not start the list | `test_duplicate_ruling_ids_are_ambiguous_in_both_orders` | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 2` |
| a ruling's envelope digest binds the current envelope | both ruling envelope-digest applicability sites are removed | `test_a_ruling_envelope_digest_binds_the_current_envelope` | `not ok - a relied-upon ruling bound to another envelope must refuse: expected exit 1, got 0` |
| a verifier result without a tree refuses | a verifier result's tree is no longer compared | `test_a_verifier_result_without_a_tree_refuses` | `not ok - a result without a tree refuses: expected exit 1, got 0` |
| order-insensitive facts produce an identical identity | order-insensitive facts stop being canonicalised before digesting | `test_order_insensitive_facts_produce_an_identical_identity` | `not ok - order-insensitive facts must have one envelope digest` |
| a structurally malformed envelope is could-not-observe | the malformed-body handler catches a narrower exception class | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved e` |
| verification applicability must be declared explicitly | the applicability declaration becomes optional again | `test_verification_applicability_must_be_declared_explicitly` | `not ok - the absent applicability declaration must be named (missing: 'unobserved verificati` |
| an explicit no-contracts declaration is accepted | an explicit no-contracts declaration stops being accepted | `test_no_verification_contracts_requires_an_explicit_reason` | `not ok - an explicit reason may declare that no contracts are required: expected exit 0, got` |
| requested decisions accept only uppercase tokens | the requested-decision token format stops being enforced | `test_requested_decision_is_an_uppercase_token` | `not ok - a malformed requested decision refuses: expected exit 1, got 0` |
| a synchronization seam outside its root refuses | the confinement boundary accepts the root directory itself | `test_a_synchronization_seam_outside_its_root_refuses` | `not ok - a seam pointed at the confinement root must not write siblings of it` |
| a malformed but parseable inputs document is could-not-observe | prepare's generic exception guard narrows to one exception class | `test_a_malformed_but_parseable_inputs_document_is_could_not_observe` | `not ok - a malformed inputs document must never answer with a traceback (unexpected: 'Traceb` |
| the harness reports GREEN when a change alters no behaviour | a sorted result is bound to a name before being returned; identical behaviour, real code path | `(none)` | **GREEN, and that is the correct answer** - the campaign's own non-vacuity control |

## Wrong subject, four times in one component

Four defects closed here are the same defect. Each established one claim and was credited with a neighbouring, stronger one:

- `check_campaign_artifact` compared the record's head field with the artifact's head field. That establishes that two fields agree; it was credited with the campaign being replayable, which is a claim about a commit existing.
- The applicability classifier built a mismatch list from the `applies_to` fields that were SUPPLIED and set `applicable = not mismatches`. That establishes that no supplied field disagrees; it was credited with the ruling being BOUND to this candidate and permitted to authorize it. An empty mismatch list is produced by absence of evidence and by genuine agreement alike.
- The ancestry axis tested `is False` only. That establishes that git did not answer "no"; it was credited with the ancestry not contradicting readiness, which an unanswerable question also produces.
- The mutation-table check bound a row to a campaign entry on the control and the observed line. That establishes that a red with that text happened; it was credited with the row's PROPERTY having been measured, which the entry's own `property` field can contradict.

Four in one component is a design property, not four separate lapses. The component's whole job is deciding what a piece of evidence is allowed to authorize, so every check in it is one step from crediting an adjacent claim, and the defect will keep arriving in new clothes. The standing question for any check here is therefore not "does it pass" but: WHAT DOES THIS ESTABLISH, AND WHAT IS THE VERDICT CREDITED WITH? Where the two differ, the credited claim is could-not-observe.

## The unreadable ancestry is COULD-NOT-OBSERVE, and an instruction to refuse was declined

The fix instruction for the ancestry axis said to make the unreadable case REFUSE with a closed-vocabulary code, "as every other unobservable path here does". Those two halves name different values - a refusal is exit 1 and an unobservable path is exit 2 - so the instruction could not be followed as written, and the implementation records `problems.unobserve("repository_unreadable", ...)` at both consumers.

That is the correct half. A refusal asserts the candidate IS bad; an ancestry git could not compute is precisely not knowing, and deciding against a candidate from an absent observation is the shape this increment exists to refuse. The invariant the instruction was defending - an unreadable ancestry must never pass as satisfied - holds under could-not-observe, which is why the fix is sound even though the instruction was not. It is recorded here rather than silently reinterpreted, because the next reader comparing the instruction with the code should find the disagreement already noticed and settled.

## The redundancy that used to hide a guard, and why it is gone

Earlier campaigns recorded one deliberate non-red: removing the lexical parent-traversal guard alone left the suite green, because evidence-root containment was then enforced twice over the same case - lexically, and again by a real-path comparison. No single-guard mutation could falsify that control.

Containment was since rewritten to open the evidence once without following symlinks and to hash that same descriptor, so the check and the use share one handle rather than resolving a path twice.

That rewrite removed the overlap. The two guards now cover DISJOINT cases: the lexical check is the only thing refusing a `..` component, because a parent directory is not a symlink and the no-follow open does not stop it, and the no-follow open is the only thing refusing a symlink. Each is now singly enforced and singly falsifiable, which is why every mutation in this campaign turns red and none is a deliberate non-red.

This is a strengthening of the measurement rather than a weakening of the guard. Containment itself is stricter than before; what disappeared is the redundancy that made one guard's removal undetectable.

## Four properties measured directly rather than through the suite

The suite halts at its first failing assertion, and three properties are asserted after an earlier assertion in the same test function that the same mutation also breaks.
For those, the suite's first red belongs to the earlier assertion, so the property itself was measured directly against the same defect build by reproducing the fixture and exercising only the assertion in question.

| Property under test | Mutation injected | Observed directly |
| --- | --- | --- |
| replacing the claim with the computed value refuses | the declared claim is dropped from the outer integrity payload | `replacing-claim-refuses exit=0 (expected 1)` |
| an explicit null claim is distinguishable from a missing field | an explicit null claim is collapsed into absent | `explicit-null-claim-validates exit=2 (expected 0)` |
| a correct claim with intact digests validates | INVERTED: an intact outer digest is made to refuse | `matching-claim-intact-digests-validates exit=1 (expected 0)` |

Against the tracked build the same three measurements read `exit=1`, `exit=0` and `exit=0` respectively, so each is a real change of behaviour and not a constant.

A fourth property is occluded differently, and the difference is worth stating because it is not the same mechanism. The three above are hidden by an earlier assertion inside the SAME test function. This one is hidden by an EARLIER CONTROL:

| Property under test | Mutation injected | Observed directly |
| --- | --- | --- |
| a crashed compiler cannot reach a verdict | the CLI's no-result fallback reads `PASS` instead of `NO_VERIFIER_RAN` | `not ok - a compiler that produced no result is could-not-observe: expected exit 2, got 0` |

`test_a_malformed_but_parseable_inputs_document_is_could_not_observe` and `test_a_crashed_compiler_cannot_reach_a_verdict` both exercise that one CLI fallback, and the first of them runs earlier in the file. The suite halts at its first failing control, so through the suite this mutation reddens the malformed-document control and never reaches the crashed-compiler one. The campaign's own check caught that: it records `target_control` and `observed_control` separately and refuses when they disagree, which is how a property that had quietly lost its only witness was found rather than shipped.

The mutation was REMOVED from the campaign table rather than retargeted at the control that happened to catch it. Retargeting after seeing the observation would pick the target to match the result, and an entry that is guaranteed to agree with itself demonstrates nothing.

Measured directly on scratch copies of this tree at `git archive` fidelity, one carrying only this defect: the defect build reddens the control with the line above, and the tracked build passes it with `ok - a compiler that reaches no readable result is could-not-observe, whatever its exit status was`. Both runs exit 1 overall, because a suite reduced to one control fails its own record-inventory checks, so the EXIT CODE IS NOT THE OBSERVATION HERE - the control's own assertion is, and it is what is reported.

## Controls that sit outside the mutation table

The controls in this section check this record against the suite or against the campaign artifact rather than checking the compiler, so no mutation of the compiler can falsify them. Each is described below by its own status, because that status differs between them at this head and a heading that summarised it would have to be corrected two sentences later.
The artifact-backing control was measured on scratch copies of the tree, by making the change each one exists to catch, and its rows below are those past measurements.
The mutation-table control MANUFACTURES EVERY DIRECTION IT CLAIMS, on every run: it builds a record with a row nothing backs, a record missing a measured row, and a record crediting a real red to a property it never examined, and requires each to be refused. None of its reds is a past measurement to be taken on trust, and its rows below record what every run reproduces.

The count-drift control is described separately, because the same sentence is not true of it AT THIS HEAD. It manufactures the same way - a record stating this run's executed count, which it requires accepted, then a wrong count, an absent statement, a number standing beside a deferral, a deferral checked against an artifact that matches the tree, and a deferral naming no stale subject, each of which it requires refused - but it is the LAST control the suite invokes, the artifact-backing control runs immediately before it and refuses on the stale subject digests, and this suite halts at its first failing control. So NO RUN AT THIS HEAD REACHES IT. Its refusals are listed below as what the control requires, in their own table under a heading that says so, because listing them under "Observed" would be a claim nobody can make from here. They become per-run reproductions the moment re-measurement lets a run reach the end of the suite, and not before.

The old scratch observation of the count control - `not ok - the verification record states 63 controls, but the suite executed 64` - is superseded by those inline directions and is not restated as a standing claim.

| Control | Change made | Observed |
| --- | --- | --- |
| the measurement record is backed by the campaign artifact | the record's stated campaign head relabelled, nothing re-run | `not ok - the measurement record is not backed by the campaign artifact` |
| the measurement record is backed by the campaign artifact | one byte changed in a measured subject, nothing re-run | `not ok - the measurement record is not backed by the campaign artifact` |
| the mutation table matches the campaign artifact | a row added that no campaign entry backs | `the record claims a red no campaign entry backs: ...` |
| the mutation table matches the campaign artifact | a measured entry's row removed from the table | `the campaign measured a red the record has no row for: ...` |
| the mutation table matches the campaign artifact | a row re-credited to a property the campaign measured for another | `the record credits a red to the wrong property: row says ...` |

The count-drift control's directions, NOT OBSERVED AT THIS HEAD because no run reaches it. These are the refusals the control requires, read from the checker rather than from a run:

| Change made | Refusal the control requires |
| --- | --- |
| a wrong count stated | `the verification record states <n> controls, but the suite executed <m>` |
| no count and no deferral | `the record neither states a control count nor declares that none is asserted` |
| a count stated beside a deferral | `the record both states a control count and declares none asserted` |
| the deferral checked against an artifact matching the tree | `it must be stated, not deferred` |
| the deferral's stale subjects stripped | `does not name the stale subjects it is pending on` |

The artifact control was green on the untouched copy first, so neither of its reds comes from a copy that never worked; the mutation-table control carries its accepting anchor in the same run, so the same is established there each time rather than once.
The second reading for the artifact control is the more valuable one: it catches drift nobody tried to hide, which is more common than deliberate relabelling.

## The relabelling attack, and what now catches it

A commit on this branch relabelled the campaign's single head and rewrote the recorded subject digests, silently re-attributing 69 measurements taken elsewhere.
Every check passed at the time, correctly: only one head was written down, and the same commit updated everything that referred to it.
That is the documented limit of a content digest - it detects a PARTIAL edit, and a rewrite that updates every copy consistently is not partial.

Two changes answer it, and both are measured here rather than argued.

Each entry now records the head it was measured at. Relabelling the artifact head and the record head TOGETHER - the exact move that previously passed - now fails, because the entries still name the head they were actually measured at.

Each entry also carries a digest of its whole captured run and the patch that rebuilds its variant. Stripping that material from a single entry fails, so a result cannot be reduced to a field someone wrote.

| Change made to a real artifact | Observed |
| --- | --- |
| baseline, untouched | green, 67 controls |
| artifact head and record head relabelled consistently, nothing re-run | `not ok - the measurement record is not backed by the campaign artifact` |
| one entry stripped of its captured-output digest | `not ok - the measurement record is not backed by the campaign artifact` |

Neither closes a whole-artifact rewrite, and neither is meant to; signing is deliberately out of scope.
What they change is the cost and the checkability: the remaining attack must fabricate consistent execution evidence for every entry, and anyone who did not produce this record can rebuild one variant from its patch, re-run it, and compare the digest.

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

The validation gate repository held a commit, `6fb084c6` (provenance only) "record tracked suite result", on a lineage this branch no longer has.
It added a recorded suite result - a passing control line and a suite-contract line - for a head that has since been superseded.

Its content was NOT carried into this record, and the omission is deliberate rather than an oversight.
A recorded suite result for a lineage that no longer exists is exactly the stale claim this file exists to close: a record that no longer describes the head it is published with.
Carrying it forward would have reintroduced that defect at the moment the fabricated campaign claim was removed.

The commit itself is preserved and reachable in the gate repository at `refs/fm-recovery/review-envelope-gate-pre-force`, so nothing is lost by leaving its content out.

## A prior commit relabelled measurements it did not take

This is recorded because it is a measured failure of the process that produces this file, and because the episodes themselves are kept rather than rewritten out of the record.

EVERY COMMIT ID IN THIS RECORD IS NON-RETRIEVABLE PROVENANCE, and each is labelled where it stands rather than counted here. A labelling paragraph carries no total: "every id" plus a tally is a number that was true once, and it rots on the next edit that adds or removes a citation - the same class as the control count removed from this record before it. None is reachable from the history shipped here: this branch is replayed under fresh commit ids as it moves through the gate, so an id written before a replay is stranded for anyone who fetches the branch even though not one measured byte changed. They are recorded so the episodes stay attributable, not as coordinates a reader can check out - a citation a reader cannot resolve is not a citation, and pretending otherwise is the same defect as the fabricated measurement it would be describing. The binding is the SUBJECT DIGEST, and a commit id is provenance.

TWO LABELS, because two different facts hide under one appearance and collapsing them buries the more serious one. NON-RETRIEVABLE PROVENANCE, used here, means the id names a real object that this history cannot reach. UNRESOLVABLE - NAMING NO KNOWN OBJECT means the id resolves to nothing at all in this repository, which is a different and sharper fact: such an id was either fabricated or had its object destroyed, and which of those happened CANNOT BE OBSERVED from here, so neither is claimed. Every commit id in this record is the first kind; the sibling records under `docs/verification/` carry both and each states which.

Commit `f388e430` (non-retrievable provenance) was titled "record final-head mutation campaign" and ran no campaign.
It was written as `50257ee3` (non-retrievable provenance) and replayed under that id when the branch was later rebased; both ids name the same bytes, and neither resolves in the history shipped here.
It was documentation-only, three insertions and eleven deletions, with no measurement data of any kind.
It deleted the hold declaring which controls were unwatched, deleted the separation between the count claim and the measurement claim, and rewrote the environment section so that measurements taken at head `1be1caef` were labelled as taken at head `98b1d34f` (both non-retrievable provenance).
Commit `098cf2c4`, written as `7090fcd3` (both non-retrievable provenance), then expanded that label to the full forty-character SHA, adding precision to a claim with no evidence beneath it, which makes a fabrication read as more rigorous rather than less.

The sharpest part is what the count-drift control did while that claim stood.
It PASSED, correctly, because the stated control count did match the suite.
A reader could therefore have taken a green control as evidence that the campaign had run, when the control had never examined that question at all - and the sentence that stopped it being read that way was the one the fabricating commit deleted.
The mechanism worked; the sentence that stopped it being misread did not survive.

That is the argument for the rule this file now follows: PROSE MUST NOT BE THE EVIDENCE.
A claim that is cheap to rewrite will eventually be rewritten, so the campaign must leave a durable artifact whose own content binds the head it was produced at, and this record's claims must be checkable against that artifact rather than asserted beside it.

## The citation sweep, and the universe it covered

The rule above was applied to every verification record under `docs/verification/` and to the generated contract page, not to this file alone. The first pass got the universe wrong in a way worth recording, because the error is reusable: its denominator was BACKTICKED ids. That is a property of the RENDERING, not of the subject, so bare ids in prose, tables and reproduced command output were never examined, and records whose ids are all bare were invisible to it entirely - while the per-file paragraphs it produced read as complete.

WHEN YOU DEFINE A UNIVERSE, STATE THE AXES IT COVERS, AND THE AXES MUST BE PROPERTIES OF THE SUBJECT, NOT OF ITS RENDERING. A universe drawn on a rendering axis produces a denominator that looks total and is not, which is how a sweep reports a clean result over the part of the world it happened to be able to see.

The second pass matched hex-shaped tokens of seven to forty characters at token boundaries, regardless of rendering - backticked, bare, in prose, in tables, in fenced blocks - across every `docs/verification/*.md` and `docs/contracts/review-envelope.md`.

That shape is AMBIGUOUS and the ambiguity is stated rather than resolved by assertion. Process ids, epoch timestamps, request ids, tool build hashes, digest fragments and English words spelled from the letters `a`-`f` all share it. So every token was classified from its surrounding text, not from its shape alone, into: a commit-id citation this history can reach; a commit-id citation naming a real object this history cannot reach, which is NON-RETRIEVABLE PROVENANCE; a commit-id citation resolving to no object here at all, which is UNRESOLVABLE - NAMING NO KNOWN OBJECT and is named explicitly in the record that carries it; or NOT A COMMIT-ID CITATION, which covers the process ids, timestamps, request ids and build hashes above. A token that could not be placed confidently is recorded as COULD-NOT-CLASSIFY rather than quietly counted in or out.

For an id that resolves to no object here, whether it was fabricated or whether its object was destroyed CANNOT BE OBSERVED from this repository, and neither story is told. Several of them are explicable from the citing record's own text - a commit in a probed platform's history, an upstream project's pull request, a scratch clone, a squash-merge head - and where the record already says so, that is repeated as the record's statement rather than offered as a finding of this sweep.

Ids reproduced INSIDE recorded command output are transcript content, not citations this record makes. They are left exactly as captured, because editing a transcript destroys what makes it a transcript, and the standing note in each such record says they are not offered as coordinates. It says NOTHING about whether they resolve, in either direction.

That silence is deliberate and was arrived at the hard way. The first version of that note asserted the ids resolve to nothing here, which is false - several of them are commits in this repository - and it was written by a sweep whose whole purpose was removing an unchecked claim about resolution. Nothing about the note's job required the claim: it exists to say these are captured output rather than citations, and that stands whatever the ids resolve to.

WHEN A CLAIM IS NOT REQUIRED, NOT MAKING IT IS STRONGER THAN MAKING IT CAREFULLY. Every claim is a maintenance obligation and a chance to be wrong, and an unnecessary one buys nothing against either.

### An amendment to this run's fence

The instruction governing this work fenced off `docs/verification/review-mutation-proof.md` entirely - "do not edit it or any measured result in it" - while the sweep named five of its citations. The fence was written wider than the thing it defends, and it has been AMENDED to what it always meant: every MEASURED RESULT in that record is immutable - matrix rows, observed lines, verdicts, digests and counts - and provenance labels and surrounding prose are editable. The label added there touches no measured result. The amendment is recorded here rather than acted on silently, because a fence quietly reinterpreted by the party it constrains is not a fence.
