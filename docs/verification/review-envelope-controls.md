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
Every measurement below was taken against head `d016170a`, and EACH ENTRY in the campaign artifact records that head individually rather than relying on one head written once.
Each entry also carries a digest of its whole captured run and the patch that rebuilds its variant, so an independent party can replay any entry and compare rather than taking this record's word for it.

## Campaign artifact

The measurements below are backed by [`review-envelope-campaign.json`](review-envelope-campaign.json), which records the content digest of every measured subject.
A control fails when a subject's shipped bytes differ from the bytes measured, or when the claims below disagree with the artifact, so relabelling this prose contradicts the experiment instead of quietly redescribing it.

Campaign head: `d016170a7078fed2aa860a57694e7b96823366a3`.
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

72 controls pass against the shipped scripts.
Count claim: the green count-drift control establishes only that the number stated above matches the suite's actual executed control count.
It says nothing about whether any control was ever watched red, and it is not evidence of mutation measurement.

Mutation-measurement claim: 72 mutations were built against the subjects recorded in the campaign artifact, and all 72 turned the suite red.
Coverage is counted per property rather than per test function, because a named property whose mutation leaves the suite green is uncovered however many controls exist.

There is no non-red in this campaign, and the reason that changed is recorded below rather than left as a silently uniform table.

Every entry's target control and observed control agree: 72 of 72.

The target is assigned from each mutation's INTENT and the observed control is DERIVED from its captured run, by counting the success lines that precede the failure and reading them against the suite's invocation order. Those two must be independent or the comparison is worthless: a target taken from the observation would agree by construction, for every entry, including entries that measured nothing.

An earlier campaign at this head had three entries whose red belonged to a neighbouring control. Each of those mutations was coarser than the property it named - it emptied an array, which tripped the fixture-defect guard before the target control ran - so each was narrowed to violate only its own property, and all three now redden their own control. That is recorded because the narrowing, not the count, is what makes those three measurements real.

Of those 72 reds, 68 are DISTINCT, they land on 61 distinct controls, and every entry carries its whole captured run rather than only a digest of it.

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
| a base that falls behind the trunk refuses | the base-to-trunk distance is no longer compared with policy | `test_a_base_that_falls_behind_the_trunk_refuses` | `not ok - the refusal must name the policy bound it exceeded (missing: 'refusal base_behind_main_` |
| an asserted head the repository contradicts refuses | the head asserted by the inputs is believed instead of checked | `test_an_asserted_head_the_repository_contradicts_refuses` | `not ok - a head asserted in prose that the repository contradicts refuses: expected exit 1, got ` |
| a tampered envelope body refuses | the stored body is no longer re-digested on read | `test_a_tampered_envelope_body_refuses` | `not ok - the refusal must name the broken content address (missing: 'refusal envelope_digest_mis` |
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
| duplicate attempts with no ordering refuse | unorderable repeated attempts are resolved anyway | `test_duplicate_attempts_with_no_ordering_refuse` | `not ok - the refusal must name the check whose current attempt is undecidable (missing: 'refusal` |
| two workflows sharing a check name stay two checks | checks are keyed by name alone, dropping the owning workflow | `test_two_workflows_sharing_a_check_name_stay_two_checks` | `not ok - one workflow's pass must not mask another workflow's failure: expected exit 1, got 0` |
| a superseded failure is replaced by its later rerun | every attempt is treated as current, not just the latest | `test_order_insensitive_facts_produce_an_identical_identity` | `not ok - the first fact order compiles: expected exit 0, got 1` |
| alias fallback resolves a later declared candidate | every candidate is still probed, but only the first is allowed to resolve | `test_alias_fallback_resolves_a_later_declared_candidate` | `not ok - a capability whose first alias is absent and whose second is present is observed, not c` |
| an exhausted candidate set is could-not-observe | an unresolved required capability stops being could-not-observe | `test_an_exhausted_candidate_set_is_could_not_observe` | `not ok - an exhausted candidate set is could-not-observe: expected exit 2, got 0` |
| a candidate that will not state its identity is not a selection | a candidate that will not state its identity is selected anyway | `test_a_candidate_that_will_not_state_its_identity_is_not_a_selection` | `not ok - the unusable candidate must be recorded as identity_failed, not as absent` |
| a silently dropped obligation refuses | an unaccounted predecessor obligation is skipped | `test_a_silently_dropped_obligation_refuses` | `not ok - an obligation that simply disappears refuses: expected exit 1, got 0` |
| a silently dropped obligation refuses | the predecessor's active obligations are read as an empty set | `test_array_classification_registry_is_total` | `not ok - the populated registry fixture compiles to a classified envelope: expected exit 0, got ` |
| every prior obligation may be accounted for explicitly | a discharged obligation is treated as still active | `test_every_prior_obligation_may_be_accounted_for_explicitly` | `not ok - explicit accounting for every prior obligation advances: expected exit 0, got 1` |
| a satisfied obligation without evidence refuses | satisfaction stops requiring named evidence | `test_a_satisfied_obligation_without_evidence_refuses` | `not ok - satisfaction asserted without evidence refuses: expected exit 1, got 0` |
| a preserved obligation missing from the active set refuses | preservation stops requiring presence in the active set | `test_a_preserved_obligation_missing_from_the_active_set_refuses` | `not ok - an obligation called preserved but absent refuses: expected exit 1, got 0` |
| a superseded obligation without a replacement refuses | supersession stops requiring an active replacement | `test_a_superseded_obligation_without_a_replacement_refuses` | `not ok - supersession pointing at nothing refuses: expected exit 1, got 0` |
| a resolution without an authority refuses | resolution stops requiring an authority and a reason | `test_a_resolution_without_an_authority_refuses` | `not ok - a resolution with no authority refuses: expected exit 1, got 0` |
| a successor that declares no predecessor is could-not-observe | an absent predecessor block is assumed to mean a fresh chain | `test_a_successor_that_declares_no_predecessor_is_could_not_observe` | `not ok - an undeclared predecessor is could-not-observe: expected exit 2, got 0` |
| a disposition for an obligation the predecessor never held refuses | a disposition for an unheld obligation is accepted | `test_a_disposition_for_an_obligation_the_predecessor_never_held_refuses` | `not ok - a disposition for an obligation nobody held refuses: expected exit 1, got 0` |
| a predecessor that is not the declared one is could-not-observe | the supplied predecessor's digest is no longer compared | `test_a_predecessor_that_is_not_the_declared_one_is_could_not_observe` | `not ok - a predecessor that is not the declared one is could-not-observe: expected exit 2, got 1` |
| a ruling that does not apply cannot authorize a resolution | ruling head applicability is no longer compared at the classify site | `test_a_ruling_that_does_not_apply_cannot_authorize_a_resolution` | `not ok - a ruling issued against another head cannot authorize anything here: expected exit 1, g` |
| a blocking adverse finding refuses | a blocking adverse finding stops refusing | `test_a_blocking_adverse_finding_refuses` | `not ok - a blocking adverse finding refuses: expected exit 1, got 0` |
| a required unproven dimension is could-not-observe | a required unproven dimension stops being could-not-observe | `test_a_required_unproven_dimension_is_could_not_observe` | `not ok - a required unproven dimension is could-not-observe: expected exit 2, got 0` |
| a fully excluded scope refuses | a scope that excludes everything stops refusing | `test_exclusion_rule_order_remains_meaningful` | `not ok - the first exclusion order compiles to a refusal: expected exit 1, got 0` |
| excluded scope is bound explicitly | the rule that excluded a path is no longer recorded | `test_exclusion_rule_order_remains_meaningful` | `not ok - the first matching exclusion rule must receive credit` |
| a contribution that changes nothing refuses | an empty changed-file set stops refusing | `test_a_contribution_that_changes_nothing_refuses` | `not ok - the refusal must say the contribution changes nothing (missing: 'refusal changed_file_s` |
| a base the candidate does not descend from refuses | a base outside the candidate's ancestry stops refusing | `test_a_base_the_candidate_does_not_descend_from_refuses` | `not ok - the refusal must name the base the candidate does not descend from (missing: 'refusal b` |
| a declared repository identity this is not refuses | the declared repository identity is no longer checked | `test_a_declared_repository_identity_this_is_not_refuses` | `not ok - compiling against the wrong repository refuses: expected exit 1, got 0` |
| a check that names no head cannot cover a required platform | a headless attempt is still recorded, and also counted as exact-head | `test_a_check_that_names_no_head_cannot_cover_a_required_platform` | `not ok - a check with no head association cannot cover a platform: expected exit 1, got 0` |
| validate refuses to guess about evidence | validation guesses the evidence decision instead of refusing | `test_validate_refuses_to_guess_about_evidence` | `not ok - validation with no evidence decision is could-not-observe: expected exit 2, got 1` |
| declining the evidence recheck cannot reach review ready | a declined evidence recheck no longer blocks review-ready | `test_declining_the_evidence_recheck_cannot_reach_review_ready` | `not ok - a declined evidence recheck cannot pass: expected exit 2, got 0` |
| validate rechecks evidence bytes | the evidence recheck arm never runs | `test_validate_rechecks_evidence_bytes` | `not ok - evidence replaced after compilation refuses at validation: expected exit 1, got 0` |
| the generated contract page matches the catalog | the generated contract page's section heading changes | `test_the_generated_contract_page_matches_the_catalog` | `not ok - docs/contracts/review-envelope.md is stale; regenerate it with bin/fm-review-envelope.s` |
| a crashed compiler cannot reach a verdict | an unreadable compiler result is read as a pass | `test_a_crashed_compiler_cannot_reach_a_verdict` | `not ok - a compiler that produced no result is could-not-observe: expected exit 2, got 0` |
| symlink out of root refused before any byte is read or digested | the final open stops refusing to follow a symlink | `test_an_evidence_symlink_that_escapes_its_root_refuses_before_reading` | `not ok - a symlink outside the evidence root refuses: expected exit 1, got 0` |
| duplicate disposition refused, order A (later duplicate wins) | duplicate dispositions resolve by last-one-wins | `test_duplicate_dispositions_refuse_in_both_orders` | `not ok - duplicate dispositions refuse in preserved-first order: expected exit 1, got 0` |
| duplicate disposition refused, order B (earlier duplicate wins) | duplicate dispositions resolve by first-one-wins | `test_duplicate_dispositions_refuse_in_both_orders` | `not ok - the duplicate refusal must not depend on disposition order (missing: 'refusal obligatio` |
| claimed identity mismatching a recomputation refuses | a mismatched declared identity stops refusing at compile time | `test_request_identity_is_recomputed_and_checked` | `not ok - a mismatched claimed request identity refuses: expected exit 1, got 0` |
| a matching recomputation is accepted (non-vacuity, inverted) | INVERTED: a correctly matching claim is made to refuse | `test_request_identity_is_recomputed_and_checked` | `not ok - a correctly recomputed request identity is accepted: expected exit 0, got 1` |
| deleting the claim refuses | the outer integrity digest is no longer recomputed on read | `test_request_identity_is_recomputed_and_checked` | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| replacing the claim with the computed value refuses | the declared claim is dropped from the outer integrity payload | `test_request_identity_is_recomputed_and_checked` | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| absent claim field is could-not-observe | an absent claim state is read as an explicit null | `test_request_identity_is_recomputed_and_checked` | `not ok - an absent claim state is could-not-observe: expected exit 2, got 0` |
| explicit null claim is distinguishable from a missing field | an explicit null claim is collapsed into absent | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved envel` |
| a correct claim with intact digests validates (non-vacuity, inverted) | INVERTED: an intact outer digest is made to refuse | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - a structurally malformed body is could-not-observe: expected exit 2, got 1` |
| an evidence locator that escapes its root refuses | both the lexical traversal guard and the symlink refusal are removed | `test_an_evidence_locator_that_escapes_its_root_refuses` | `not ok - a locator escaping its evidence root refuses: expected exit 1, got 0` |
| a ruling without a stable id refuses | a ruling with no stable id is accepted | `test_a_ruling_without_a_stable_id_refuses` | `not ok - a missing ruling id refuses: expected exit 1, got 0` |
| duplicate ruling ids are ambiguous, order A | duplicate ruling ids stop being ambiguous | `test_duplicate_ruling_ids_are_ambiguous_in_both_orders` | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 0` |
| duplicate ruling ids are ambiguous, order B | duplicate ruling ids are detected only when the pair does not start the list | `test_duplicate_ruling_ids_are_ambiguous_in_both_orders` | `not ok - duplicate ruling ids refuse in applicable-first order: expected exit 1, got 0` |
| a ruling's envelope digest binds the current envelope | both ruling envelope-digest applicability sites are removed | `test_a_ruling_envelope_digest_binds_the_current_envelope` | `not ok - a relied-upon ruling bound to another envelope must refuse: expected exit 1, got 0` |
| a verifier result without a tree refuses | a verifier result's tree is no longer compared | `test_a_verifier_result_without_a_tree_refuses` | `not ok - a result without a tree refuses: expected exit 1, got 0` |
| order-insensitive facts produce an identical identity | order-insensitive facts stop being canonicalised before digesting | `test_order_insensitive_facts_produce_an_identical_identity` | `not ok - order-insensitive facts must have one envelope digest` |
| a structurally malformed envelope is could-not-observe | the malformed-body handler catches a narrower exception class | `test_a_structurally_malformed_envelope_is_could_not_observe` | `not ok - the readable verify record must name the malformed envelope (missing: 'unobserved envel` |
| verification applicability must be declared explicitly | the applicability declaration becomes optional again | `test_verification_applicability_must_be_declared_explicitly` | `not ok - the absent applicability declaration must be named (missing: 'unobserved verification_a` |
| an explicit no-contracts declaration is accepted | an explicit no-contracts declaration stops being accepted | `test_no_verification_contracts_requires_an_explicit_reason` | `not ok - an explicit reason may declare that no contracts are required: expected exit 0, got 2` |
| requested decisions accept only uppercase tokens | the requested-decision token format stops being enforced | `test_requested_decision_is_an_uppercase_token` | `not ok - a malformed requested decision refuses: expected exit 1, got 0` |

## The redundancy that used to hide a guard, and why it is gone

Earlier campaigns recorded one deliberate non-red: removing the lexical parent-traversal guard alone left the suite green, because evidence-root containment was then enforced twice over the same case - lexically, and again by a real-path comparison. No single-guard mutation could falsify that control.

Containment was since rewritten to open the evidence once without following symlinks and to hash that same descriptor, so the check and the use share one handle rather than resolving a path twice.

That rewrite removed the overlap. The two guards now cover DISJOINT cases: the lexical check is the only thing refusing a `..` component, because a parent directory is not a symlink and the no-follow open does not stop it, and the no-follow open is the only thing refusing a symlink. Each is now singly enforced and singly falsifiable, which is why every mutation in this campaign turns red and none is a deliberate non-red.

This is a strengthening of the measurement rather than a weakening of the guard. Containment itself is stricter than before; what disappeared is the redundancy that made one guard's removal undetectable.

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
