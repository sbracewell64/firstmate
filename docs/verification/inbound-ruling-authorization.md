# Verification: the one-use, head-bound landing authorization

Audience: maintainer-verification.
Subject: `bin/fm-landing-authorization.sh` and `bin/fm-landing-authorization-lib.sh`, and the seam that consumes them - `bin/fm-landing-seam-lib.sh` inside `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`.
Regression owners: `tests/fm-landing-authorization.test.sh` for the authority layer, `tests/fm-landing-seam.test.sh` for the seam.

## What is claimed

A Browser Sol ruling that approves a landing grants an authority, and this mechanism makes that authority durable, bound to one exact head, and spendable exactly once.

Four properties, and one control without which none of them means anything:

1. An authorization is bound to an exact head and is refused for any other head.
2. It is spent exactly once, so a second use performs no act and returns the recorded spent outcome.
3. A restart during the spend leaves a durable `indeterminate` state that requires evidence-backed reconciliation rather than silently treating the authority as spent or reusable.
4. An authorization for a superseded request is refused.
5. Non-vacuity: a fresh, correctly bound, unspent authorization is still consumed successfully.

Property 5 is not a courtesy.
Properties 1 through 4 can all pass while the mechanism performs no landing act, so without 5 the suite would be green and worthless.

The typed effect-plan contract is owned by `bin/fm-landing-authorization-lib.sh`'s header, and its red calibration and end-to-end proof are recorded in ["Effect-plan verification"](#effect-plan-verification) below.

## What is NOT claimed, and where those properties live

This mechanism does not establish that a ruling answers a given request.
Correlating a ruling to its request, refusing an unrelated ruling, refusing an ambiguous ruling body, and invalidating a request whose identity has moved are owned by `bin/fm-outbound-artifact.sh` and proven by `tests/fm-outbound-artifact.test.sh`.
This starts from a correlation record already in state `ruled`.

It does not re-derive the correlation record's own identity digest, and it does not re-read the ruling comment on the forge.
A correlation record that is internally consistent but forged, and a ruling edited on the forge after correlation, are both outside what this establishes.

The head shape check accepts either a 40- or 64-character object id because this mechanism never clones the target repository and so cannot determine its object format.
That is weaker than the outbound owner's resolvable-object rule, and it is sound here only because the shape is a prefilter: the property is carried by equality against an independently observed head, not by the shape.

The authority layer is verified against correlation records supplied as data in the published schema; it does not create them, and the outbound emitter that does is verified separately by `tests/fm-outbound-artifact.test.sh`.

This mechanism WAS verified-and-unwired until 2026-08-19.
Nothing in `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh` called it, so every property above was true and load-bearing for nothing.
That state is recorded here rather than deleted, because it is the failure this document now has to keep closed: a control can be complete, correct, and green in its own suite while the production route walks around it, and no amount of testing the control detects that.
The seam and its own claims are in ["The seam"](#the-seam-the-authority-is-consumed-by-the-real-mutation-path) below.

## Red calibration

Every control below was observed failing for its intended reason before it was trusted.
Each was produced by staging a copy of the mechanism, injecting exactly one defect, and running the suite.

Date: 2026-08-17.
Command shape, per case: copy `bin/` and `tests/` to a scratch root, apply one patch, run `bash tests/fm-landing-authorization.test.sh`, record the first `not ok`.
The review worker personally watched cases 5, 5c, 5d, 13, 14, and 15 fail in this worktree after the corresponding review fixes; cases 1 through 4 and 6 through 12 retain the initial worker's recorded observations.

| # | Injected defect | Observed failure |
| - | --------------- | ---------------- |
| 1 | the act is never performed | `not ok - nonvacuity: the act ran 0 times, not once` |
| 2 | `spent` admitted for another spend | `not ok - exactly-once: the act ran 2 times across two spends` |
| 3 | the caller-stated head is not compared | `not ok - head-bound: a different head must refuse: spent: ... landed demo-item at 1111111111111111111111111111111111111111: expected exit 3, got 0` |
| 4 | the observed head is replaced by the caller's | `not ok - moved-head: a moved forge head must refuse: spent: ... landed demo-item at 1111111111111111111111111111111111111111: expected exit 3, got 0` |
| 5 | group liveness ignored after the wrapper leader dies | `not ok - restart: reconciliation reclaimed while the act child lived: reconciled: fm-auth-3fc7425751e637a0f3d58b0d15457f5c is now granted: expected exit 4, got 0` |
| 5c | `EPERM` from the direct group probe treated as absence | `not ok - restart: permission-denied group probe reclaimed the authorization: reconciled: fm-auth-3fc7425751e637a0f3d58b0d15457f5c is now granted: expected exit 4, got 0` |
| 5d | `ESRCH` from the direct group probe never admitted as absence | `not ok - restart: reconciling not-applied did not restore the authority (missing: 'granted')` followed by `FM_AUTH_SPEND_INDETERMINATE: the spender process group for fm-auth-3fc7425751e637a0f3d58b0d15457f5c could not be observed as gone` |
| 6 | any correlation state accepted | `not ok - superseded: a superseded request must refuse: spent: ...: expected exit 3, got 0` |
| 7 | an unrecognized verdict classed as approving | `not ok - mint-unknown: an unrecognized verdict must be could-not-observe: ...: expected exit 4, got 0` |
| 8 | a nonce added to the mint identity | `not ok - mint-idempotent: the same ruling minted two ids, fm-auth-b0a09b1e... and fm-auth-962bc8c1...` |
| 9 | the filename adopted as the request identity | `not ok - misplaced: a record naming another request must refuse: ...: expected exit 3, got 0` |
| 10 | `gh` exit status and head shape both ignored | `not ok - head-unobservable: a failed observation must be could-not-observe: FM_AUTH_STALE_HEAD: ... but owner/demo#7 is now at : expected exit 4, got 3` |
| 11 | the spend claim never refuses | `not ok - in-flight: a held claim must refuse: spent: ...: expected exit 3, got 0` |
| 12 | an unreadable member skipped during enumeration | `not ok - enumeration: an unreadable member must make the listing could-not-observe: fm-auth-000...	unreadable` |
| 13 | a live identity-matched spender claim reclaimed | `not ok - live-reconcile: reconciliation reclaimed a live spender: reconciled: fm-auth-3fc7425751e637a0f3d58b0d15457f5c is now granted: expected exit 4, got 0` |
| 14 | authorization-id validation removed from record path construction | `not ok - malformed-id: traversal id opened a record outside the store` |
| 15 | authorization records trusted after schema alone | `not ok - malformed-record: skeletal record was trusted: spent: expected exit 4, got 0` |

The exact shell commands used for the four review-round calibrations were:

```sh
cal_root=.red-calibration-20260817
mkdir -p "$cal_root/group-child" "$cal_root/live-spender" "$cal_root/malformed-id" "$cal_root/record-validation"
for case_dir in "$cal_root"/*; do cp -a bin tests "$case_dir/"; done
for defect in group-child live-spender malformed-id record-validation; do
  printf 'DEFECT=%s\n' "$defect"
  (cd ".red-calibration-20260817/$defect" && bash tests/fm-landing-authorization.test.sh) 2>&1
  printf 'EXIT=%s\n' "$?"
done
```

Each copied mechanism received only its tabled defect before that command ran.
The first failing line from each real run is reproduced verbatim in the table, and every defect run exited 1.
The malformed-id defect was rerun after making the authorization-store directory present so its FIFO sentinel proved the traversal opened the outside record.
The exact rerun command was:

```sh
cd .red-calibration-20260817/malformed-id && bash tests/fm-landing-authorization.test.sh
```

The exact shell commands used for cases 5c and 5d were:

```sh
cal_root=.red-calibration-group-probe-20260817
mkdir -p "$cal_root/eperm-reclaims" "$cal_root/esrch-never-reclaims"
for case_dir in "$cal_root"/*; do cp -a bin tests "$case_dir/"; done
for defect in eperm-reclaims esrch-never-reclaims; do
  printf 'DEFECT=%s\n' "$defect"
  (cd ".red-calibration-group-probe-20260817/$defect" && bash tests/fm-landing-authorization.test.sh) 2>&1
  printf 'EXIT=%s\n' "$?"
done
```

The `eperm-reclaims` copy classified probe exit 5 as gone.
The `esrch-never-reclaims` copy classified probe exit 3 as unobserved.
Both real defect runs exited 1 with the first failing lines reproduced verbatim in the table.

### The two that carry the most weight

**Case 4** is the one the whole head binding rests on.
The defect replaces the independently observed head with the head the caller passed in, which leaves every caller-side check agreeing with itself.
The suite goes red because the fixture's forge head has moved while the caller still names the approved one: without an observation the spending actor sets the condition it is checked against, and a landing at the wrong head succeeds.
Case 3 alone does not establish this - it only proves the caller's own claim is compared to the grant, which is the weaker neighbour of the property.

**Case 10** shows the failure mode the third value exists to prevent.
With both the exit-status check and the shape prefilter removed, an unreadable forge answer becomes an empty string, and the mechanism concludes the head *moved to empty* - refusing with `FM_AUTH_STALE_HEAD` (exit 3, a verdict) instead of `FM_AUTH_HEAD_UNOBSERVED` (exit 4, no verdict).
Both stop the act, which is why this survives casual review: the collapse is not unsafe here, it is unreportable, and an operator told a head moved goes looking for a push that never happened.

## Green run

```
$ bash tests/fm-landing-authorization.test.sh
ok - a fresh, correctly bound, unspent authorization is consumed successfully
ok - a second spend is refused and performs no act
ok - a head other than the approved one is refused
ok - a moved forge head is refused even when the caller states the approved head
ok - a restart inside the spend window leaves a determinable state
ok - an authorization for a superseded request is refused
ok - minting requires a ruled request and an authorizing verdict
ok - minting the same ruling twice grants one authorization
ok - a correlation record filed under another id is refused
ok - an unobservable head stops the spend without destroying the authorization
ok - a spend already in flight is refused
ok - a partial enumeration is could-not-observe rather than a short list
ok - reconciliation cannot reclaim a live spender's authorization
ok - malformed authorization ids cannot address the store
ok - malformed or misbound authorization records are unreadable
FM_TEST_CONTRACT suite=fm-landing-authorization.test.sh status=pass
```

The trailing `FM_TEST_CONTRACT` line is the suite's own guard against a declared case silently not running: it fails unless every `test_*` function defined in the file also reported a pass.

The delivery revalidation on 2026-08-17 also checked the maintained documentation inventory and the repository's pinned shell lint definition:

```sh
$ bash tests/fm-landing-authorization.test.sh && bin/fm-doc-audience-check.sh && bin/fm-lint.sh
ok - a fresh, correctly bound, unspent authorization is consumed successfully
ok - a second spend is refused and performs no act
ok - a head other than the approved one is refused
ok - a moved forge head is refused even when the caller states the approved head
ok - a restart inside the spend window leaves a determinable state
ok - an authorization for a superseded request is refused
ok - minting requires a ruled request and an authorizing verdict
ok - minting the same ruling twice grants one authorization
ok - a correlation record filed under another id is refused
ok - an unobservable head stops the spend without destroying the authorization
ok - a spend already in flight is refused
ok - a partial enumeration is could-not-observe rather than a short list
ok - reconciliation cannot reclaim a live spender's authorization
ok - malformed authorization ids cannot address the store
ok - malformed or misbound authorization records are unreadable
FM_TEST_CONTRACT suite=fm-landing-authorization.test.sh status=pass
fm-doc-audience-check: ok surfaces=83 local_links=291
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
```

## The seam: the authority is consumed by the real mutation path

Date: 2026-08-19.
Subject: `bin/fm-landing-seam-lib.sh`, wired into `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`.
Regression owner: `tests/fm-landing-seam.test.sh`.

### What is claimed

A candidate inside the declared Browser Sol landing domain cannot reach either mutation path's merge command without a live request covering its exact head and consumption of that request's valid, head-bound, one-use authorization, while a candidate proven outside the domain lands through the ordinary gates and says so.

1. A governed candidate with no approving ruling is refused by the real `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`, and no merge is performed.
2. A spent authority presented again is refused, and the second attempt performs no merge.
3. Non-vacuity, landing: a governed candidate under an approving ruling lands, and the authority is recorded spent.
4. Non-vacuity, not-applicable: a candidate proven outside the declared governed landing domain lands normally, and the not-applicable observation is reported on the command's own output.
5. Governance survives a moved head. A ruling bound to another head refuses rather than falling through as ungoverned, because falling through would make moving the head the cheapest way to shed a ruling.
6. The seam composes with the pre-existing merge guards and never replaces them: a red check rollup still refuses under a valid authority, and leaves that authority unspent.
7. Two live requests claiming the same item at the same head are ambiguous and refuse, rather than one of them being picked.
8. Governance ends OUTSIDE the declared domain. A closed request no longer governs, and a gate outside the landing-governing set never did, so neither can make an ungoverned item permanently unlandable.
9. Applicability is positive and closed. Inside the declared governed landing domain, a landing with no live request covering it REFUSES; `not-applicable` is reached only from a declaration, never from an absent record.
10. An undeclared domain is could-not-observe, and a malformed one is too. Neither reads as an empty domain, because reading a silence as permission is the defect claim 9 closes.
11. The domain is compared case-insensitively in BOTH directions, so neither a declaration nor a hand-typed pull request url sheds it by case alone.
12. A candidate whose repository could not be established cannot be shown to be outside a non-empty domain, and refuses; an explicitly empty domain needs no repository identity and lands.

Claims 3, 4, 8, and the landing half of 12 are not courtesies.
Claims 1, 2, 5, 6, 7, 9, 10, 11, and the refusing half of 12 are all refusals, and a merge gate that refused everything would satisfy every one of them at once.

### Why claim 9 replaced an earlier reading

Claim 4 originally read "an ungoverned candidate lands", and the seam established "ungoverned" by finding no live correlation record for the item.
That is an ABSENCE read as an answer, and it is the same shape as the defect the seam itself was built to close: a landing obligation that is real but was never written into one exact local record disappeared into the same clean `not-applicable` as work no ruling was ever going to cover.
A record that was never written, a store that was never populated, and a review that was promised and never emitted were all indistinguishable from genuinely ungoverned work.

`landing_domain` in `config/sol-control.json` is the declaration that makes the answer positive, and [`configuration.md`](../configuration.md) owns its schema.
The consequence is deliberate and is the point: inside the declared domain, a landing needs a live request every time, and a past or non-governing record is not a substitute for one.

### What is NOT claimed

The seam does not decide whether a ruling approves.
`bin/fm-landing-authorization.sh` owns minting, the closed approving-verdict set, the exactly-once spend, and the head re-observation; the seam selects the request to hand it and refuses to guess when the selection is not unique.

It does not correlate a ruling to a request, and it does not create correlation records.
Both are owned by `bin/fm-outbound-artifact.sh`.

It establishes nothing about whether a head is green, mergeable, or unblocked by review.

It compares the correlation record's ITEM and HEAD and nothing else about the subject.
The record's project and repository fields are deliberately not compared, because the two surfaces name projects differently - a correlation record carries a registry name while a merge gate holds a clone path - so comparing them would refuse correct landings on a naming mismatch while adding nothing the item and the exact head do not already establish.
A record whose base or working tree has moved under an unchanged head is likewise outside what this observes: the authority binds to a commit, and a commit is the only thing an outside reviewer was shown.

Which gates govern a landing is a decision, not an observation: every `sol-control` gate governs except `ARCHITECTURE_RULING_REQUIRED`, whose subject is a design question rather than this head's fitness to land.
The exclusion is stated as an exclusion so that a gate added to the outbound vocabulary later governs a landing until somebody decides otherwise.

Which repositories are inside the governed landing domain is also a decision rather than an observation, and the seam reads it rather than deriving it.
The seam therefore establishes nothing about whether a declared domain is the RIGHT one: a home that omits a repository it meant to govern gets an ungoverned landing that says so, and no control here can tell that apart from a repository deliberately left out.
The refusal on an undeclared domain is what keeps that decision from being made by default.

### The act is counted, never assumed

`spend` exits 0 on two different outcomes: the act ran and the authority is now spent, or the authority was already spent and no act was performed.
Reading only the exit status turns the second into a merge gate reporting success while merging nothing, which is the double-land this whole mechanism exists to prevent.
So the act is wrapped in a prologue that records having been entered, and a landing counts as performed only when that receipt says the act was reached.
Defect 06 below is that control's own red.

The suite counts the same way. A merge is observed by counting the `pr merge` invocations the fake forge recorded, and a local landing by comparing the default branch's own commit, and both counts are printed in the passing line - because zero merges is also what a completely broken gate produces.

### Red calibration

Date: 2026-08-26.
Every control was observed failing for its intended reason, and the defect that made it fail is tracked rather than described.

The catalogue lives in [`tests/landing-seam-red-matrix.py`](../../tests/landing-seam-red-matrix.py), so every row below is replayable by somebody who did not run it:

```
tests/landing-seam-red-matrix.py matrix [--defects D01,D02] [--json <out>]
tests/landing-seam-red-matrix.py replay <defect> [<control>]
tests/landing-seam-red-matrix.py list
```

Each build stages `bin/` and `tests/` into a temporary root, applies exactly one exact-substring patch, and runs the STAGED suite, which drives the real `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` end to end.
A patch whose anchor no longer matches is a hard error rather than a skip, because an unmodified build reddens nothing and the control would look witnessed while measuring a defect that was never injected.

`D00` is the harness's own control: an unpatched staged copy must redden NOTHING, or every row below is evidence about the staging rather than about the defect it names.
Every defect is run against every declared control separately through `FM_LANDING_SEAM_ONLY`, because the suite stops at its first failure and a defect that reddens several controls would otherwise only ever be seen reddening the earliest.

This table supersedes the untracked 2026-08-19 calibration of defects 00-15.
Those rows measured the same controls through a scratch harness that no longer exists, and keeping a describable-but-unreproducible table beside a replayable one would leave two records of one fact.

| # | Injected defect | Controls reddened |
| - | --------------- | ----------------- |
| D00 `df9c51b07a01` | none - the staging control, which must be GREEN. | **0 - the staging control must redden nothing** |
| D01 `4b993112b994` | LA-1's successor as found: an absent correlation is read as not-applicable instead of consulting the declared governed landing domain. | 11 of 35 |
| D02 `c7a228c28800` | An undeclared landing domain is read as an empty one. | 6 of 35 |
| D03 `c7a228c28800` | A malformed landing domain declaration is read as an empty one. | 6 of 35 |
| D04 `2d3170df636c` | The DECLARATION side of the comparison becomes case-sensitive, so a domain entry written in another case stops matching the repository it names. | 1 of 35 |
| D05 `e84d57787ac5` | A candidate whose repository could not be established is read as being outside the domain rather than as could-not-observe. | 1 of 35 |
| D06 `cf1f5c9f3cf5` | An explicitly empty landing domain refuses instead of landing, which is the non-vacuity direction: it proves the empty-domain landings are real. | 2 of 35 |
| D07 `082674016cf4` | The pull-request gate stops telling the seam which repository it writes. | 8 of 35 |
| D08 `eafd357748dc` | The local gate stops telling the seam which repository it writes. | 2 of 35 |
| D09 `5fefad22ee9a` | The pull-request merge site ignores the seam's answer and always merges. | 4 of 35 |
| D10 `c142fdad824e` | The local merge site lands outside the spend. | 3 of 35 |
| D11 `5137f240c272` | The spend's exit status is read without the act receipt, so a spent authority reports success while merging nothing. | 2 of 35 |
| D12 `21c64a645b14` | The CANDIDATE side of the comparison becomes case-sensitive, so the domain is shed by how somebody typed a pull request url. | 1 of 35 |
| D13 `cd51daafebb3` | A home with no control venue is refused instead of landing, which is the non-vacuity direction for the shipped default. | 1 of 35 |
| D14 `f198824150cf` | An emitted-but-unruled request stops counting as live, so a review that was asked for and never answered no longer governs. | 2 of 35 |
| D15 `f592e90696e8` | A head no live request approved falls through as ungoverned instead of refusing, which makes moving the head the cheapest way to shed a ruling. | 1 of 35 |
| D16 `2fa647caea92` | Two live requests claiming one head resolve to the last one seen instead of refusing, so the authority a landing consumes is picked on no evidence. | 1 of 35 |
| D17 `0ce0b970c426` | A declining or unclassifiable ruling is treated as authorizing. | 2 of 35 |
| D18 `12e7cdc22c64` | An unreadable correlation record is skipped instead of refusing, so the one record that might have governed reads as an absence of rulings. | 1 of 35 |
| D19 `c8e95de75bd3` | Live governance with no configured control venue reads as ungoverned rather than as the configuration contradiction it is. | 1 of 35 |
| D20 `a56c7e950064` | The pull-request gate stops enforcing its own check rollup, so a valid landing authority is all that stands between a red head and the forge. The seam must COMPOSE with the pre-existing guards, never replace them. | 1 of 35 |
| D21 `0eb539dc0665` | The forge's re-observed head is accepted whenever it differs from the approved one, so a pull request that moved after approval still lands. | 1 of 35 |
| D22 `c7a228c28800` | Invalid venue configuration is treated as absent and permits landing. | 6 of 35 |
| D23 `e33868e6b0a4` | Repository schema validation accepts paths with extra components. | 1 of 35 |

Every declared control has at least one red witness, and the run reports that count rather than leaving it to be inferred:

```
$ tests/landing-seam-red-matrix.py matrix
controls declared: 35
...
every defect was witnessed by a control, and the staging control is green
CONTROLS WITH NO RED WITNESS: 0
```

| Control | Witnessed by |
| ------- | ------------ |
| `test_pr_merge_keeps_its_red_head_refusal_under_a_valid_authority` | D20 |
| `test_pr_merge_lands_a_candidate_proven_outside_the_domain` | D01, D07 |
| `test_pr_merge_lands_a_governed_candidate_under_a_valid_ruling` | D09 |
| `test_pr_merge_lands_an_in_domain_candidate_under_a_valid_ruling` | D09 |
| `test_pr_merge_lands_under_a_gate_that_does_not_govern_landing` | D07 |
| `test_pr_merge_lands_when_no_control_venue_is_configured` | D13 |
| `test_pr_merge_lands_when_the_landing_domain_is_declared_empty` | D01, D06 |
| `test_pr_merge_lands_when_the_only_request_is_closed` | D07 |
| `test_pr_merge_matches_a_mixed_case_candidate_against_the_domain` | D01, D07, D12 |
| `test_pr_merge_matches_the_landing_domain_case_insensitively` | D01, D04, D07 |
| `test_pr_merge_refuses_a_declining_ruling` | D17 |
| `test_pr_merge_refuses_a_governed_candidate_with_no_ruling` | D14 |
| `test_pr_merge_refuses_a_head_the_ruling_never_approved` | D15 |
| `test_pr_merge_refuses_a_second_landing_under_a_spent_authority` | D09, D11 |
| `test_pr_merge_refuses_a_verdict_it_cannot_classify` | D17 |
| `test_pr_merge_refuses_an_in_domain_candidate_with_no_correlation` | D01, D07 |
| `test_pr_merge_refuses_an_in_domain_closed_request` | D01, D07 |
| `test_pr_merge_refuses_an_in_domain_nongoverning_gate` | D01, D07 |
| `test_pr_merge_refuses_an_unreadable_correlation_record` | D18 |
| `test_pr_merge_refuses_an_unreadable_landing_domain` | D02, D03, D22 |
| `test_pr_merge_refuses_invalid_venue_field_types` | D02, D03, D22 |
| `test_pr_merge_refuses_live_governance_with_no_configured_venue` | D19 |
| `test_pr_merge_refuses_malformed_venue_configuration` | D02, D03, D22 |
| `test_pr_merge_refuses_multi_segment_domain_repositories` | D02, D03, D22, D23 |
| `test_pr_merge_refuses_two_requests_claiming_the_same_head` | D16 |
| `test_pr_merge_refuses_venue_configuration_missing_repo` | D02, D03, D22 |
| `test_pr_merge_refuses_when_the_landing_domain_is_undeclared` | D02, D03, D22 |
| `test_pr_merge_reobserves_the_head_at_the_moment_of_use` | D09, D21 |
| `test_merge_local_lands_a_candidate_proven_outside_the_domain` | D01, D08 |
| `test_merge_local_lands_a_governed_candidate_under_a_valid_ruling` | D10 |
| `test_merge_local_lands_with_no_repository_under_an_empty_domain` | D01, D06 |
| `test_merge_local_refuses_a_governed_candidate_with_no_ruling` | D10, D14 |
| `test_merge_local_refuses_a_second_landing_under_a_spent_authority` | D10, D11 |
| `test_merge_local_refuses_an_in_domain_candidate_with_no_correlation` | D01, D08 |
| `test_merge_local_refuses_when_its_repository_cannot_be_established` | D01, D05 |

### Green run

Date: 2026-08-22.

```
$ bash tests/fm-landing-seam.test.sh
ok - a pull request proven outside the declared landing domain lands through fm-pr-merge and reports not-applicable (merges executed: 1)
ok - a governed-domain pull request with no review request refuses the real fm-pr-merge path (merges executed: 0)
ok - a configured venue with no declared landing domain refuses fm-pr-merge (merges executed: 0)
ok - a malformed landing domain declaration refuses fm-pr-merge (merges executed: 0)
ok - an explicitly empty landing domain lands through fm-pr-merge (merges executed: 1)
ok - a case difference does not put a candidate outside the declared landing domain (merges executed: 0)
ok - a mixed-case candidate repository is still matched against the declared landing domain (merges executed: 0)
ok - an approved ruling inside the declared landing domain lands and spends its authority (merges executed: 1, authorizations spent: 1)
ok - a closed request does not authorise a governed-domain landing (merges executed: 0)
ok - a gate outside the landing-governing set does not authorise a governed-domain landing (merges executed: 0)
ok - a home with no control venue lands and names the missing venue (merges executed: 1)
ok - an unruled Browser Sol review gate refuses the real fm-pr-merge path (merges executed: 0)
ok - an approved ruling lands through fm-pr-merge and spends its authority (merges executed: 1, authorizations spent: 1)
ok - a spent landing authority refuses a replayed fm-pr-merge (merges executed across two attempts: 1)
ok - a head no ruling approved refuses fm-pr-merge rather than falling through as ungoverned (merges executed: 0)
ok - a rejecting ruling refuses the real fm-pr-merge path (merges executed: 0)
ok - a ruling verdict this fleet cannot classify refuses fm-pr-merge (merges executed: 0)
ok - an unreadable correlation record refuses rather than reading as an absence of rulings (merges executed: 0)
ok - a home holding live rulings and no control venue refuses rather than reading as ungoverned (merges executed: 0)
ok - a valid landing authority composes with the check-rollup guard and never replaces it (merges executed: 0)
ok - the head is re-observed at the moment of use and a moved one refuses (merges executed: 0)
ok - two live requests claiming one head refuse rather than one being picked (merges executed: 0)
ok - a closed Browser Sol request no longer governs, and the item lands (merges executed: 1)
ok - a gate outside the landing-governing set does not block a landing (merges executed: 1)
ok - a local-only task proven outside the declared landing domain lands through fm-merge-local (fast-forwards executed: 1)
ok - a governed-domain local-only task with no review request refuses the real fm-merge-local path (fast-forwards executed: 0)
ok - a local landing whose repository cannot be established refuses under a declared domain (fast-forwards executed: 0)
ok - an empty landing domain lands a clone whose repository is unestablished (fast-forwards executed: 1)
ok - an unruled Browser Sol review gate refuses the real fm-merge-local path (fast-forwards executed: 0)
ok - an approved ruling lands through fm-merge-local and spends its authority (fast-forwards executed: 1, authorizations spent: 1)
ok - a spent landing authority refuses a replayed fm-merge-local (fast-forwards executed across two attempts: 1)
FM_TEST_CONTRACT suite=fm-landing-seam.test.sh status=pass
```

The pre-existing suites for both landing paths were re-run unchanged on the same tree, because the applicability change must not have altered any refusal they already owned:

```
$ bash tests/fm-pr-merge.test.sh | grep -c '^ok'
45
$ bash tests/fm-merge-local.test.sh | grep -c '^ok'
27
$ bash tests/fm-landing-authorization.test.sh | grep -c '^ok'
17
```

### Refreshing this record

Re-run all four suites after any change to the seam, either merge gate's merge site, or the authority layer.
Re-run the red calibration - not just the green suites - after any change to the applicability rule, the declared-domain reader, the governing-gate set, the live-state set, or the act receipt, because those are the five places where this control can go quietly vacuous while staying green.
`tests/landing-seam-red-matrix.py matrix` is that calibration, and it fails rather than reports when a defect goes unwitnessed or the staging control reddens anything.

## Effect-plan verification

Date: 2026-08-26.
Subject: `bin/fm-landing-authorization.sh` and `bin/fm-landing-authorization-lib.sh`, as consumed by `bin/fm-landing-seam-lib.sh` inside `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`.
Regression owner: `tests/fm-landing-authorization.test.sh`, beginning with control 16 and including the ruling-reservation, freshness, post-effect, and real-path controls that follow it.
The effect-plan contract is stated once in `bin/fm-landing-authorization-lib.sh`'s header.
This section records only the repeatable evidence for that contract and the required inventory of adjacent authorizers.

### Red calibration

Every control was observed failing for its intended reason.
Each defect was applied to a fresh copy of `bin/` and `tests/` under a scratch root created with `mktemp -d`, outside this repository, and the copy was run unmodified otherwise.

```sh
scratch=$(mktemp -d)
for d in caller-act-performed exec-digest-unchecked plan-field-defaulted \
         credential-screen-off ruling-reland-allowed concurrent-siblings \
         signal-before-act reservation-release-failure orphaned-grant-unreadable \
         orphaned-grant-no-evidence live-granted-reservation act-never-performed \
         moved-project-alias post-effect-unconfirmed; do
  mkdir -p "$scratch/$d" && cp -a bin tests "$scratch/$d/"
done
# one defect applied per copy, then:
for d in caller-act-performed exec-digest-unchecked plan-field-defaulted \
         credential-screen-off ruling-reland-allowed concurrent-siblings \
         signal-before-act reservation-release-failure orphaned-grant-unreadable \
         orphaned-grant-no-evidence live-granted-reservation act-never-performed \
         moved-project-alias post-effect-unconfirmed; do
  ( cd "$scratch/$d" && bash tests/fm-landing-authorization.test.sh 2>&1 | grep -m1 '^not ok' )
done
```

| Injected defect | Observed failure |
| --------------- | ---------------- |
| the caller's asserted argv is performed instead of the plan's act | `not ok - owner-act: a substituted executable must refuse: pr merge 7 --repo owner/demo --squash` |
| the pinned executable is not re-digested at effect time | `not ok - swapped-exec: a replaced executable must refuse: spent: fm-auth-e1f6eb44e8cffcaee3ad43d6ac96292a landed demo-item at 1111111111111111111111111111111111111111: expected exit 3, got 0` |
| a missing plan field is defaulted rather than refused | `not ok - plan-incomplete: a missing plan field must be could-not-observe: spent: fm-auth-ba4bf45227ca421e9f11a05ba8f2fca7 landed demo-item at 1111111111111111111111111111111111111111: expected exit 4, got 0` |
| credential screening always answers "no credential" | `not ok - credential: refusal token (missing: 'FM_AUTH_CREDENTIAL_BEARING_INPUT')` |
| one-approval-one-landing is checked at the mint but not at the act | `not ok - one-landing: one approval performed 2 landings` |
| sibling effect plans claim only their distinct authorization ids | `not ok - concurrent-siblings: concurrent plans entered 2 acts` |
| a pre-act signal clears traps before releasing the ruling reservation | `not ok - signal-before-act: signal orphaned ...ruling-reservation` |
| an indeterminate release failure is discarded | `not ok - reservation-release-failure: token (missing: 'FM_AUTH_INTENT_UNRECORDABLE')` |
| a granted record with an orphaned reservation is not reconcilable | `not ok - orphaned-grant: evidence did not settle the absent effect: FM_AUTH_AUTHORIZATION_VOID: authorization ... is granted; only an indeterminate spend needs reconciling` |
| an orphaned granted reservation settles without evidence | `not ok - orphaned-grant: evidence-free reconciliation released the reservation` |
| a live granted reservation is reclaimed | `not ok - live-granted-reservation: reconciliation reclaimed a live holder` |
| the act is never performed | `not ok - nonvacuity: the act ran 0 times, not once` |
| the local act is addressed at the mutable project alias instead of the pinned identity | `not ok - moved-project-alias: the replacement repository was retargeted` |
| a zero-exit act is recorded applied without post-effect observation | `not ok - post-effect: unconfirmed success must be indeterminate: spent: fm-auth-...: expected exit 4, got 0` |

Every defect run exited 1.

The first row is the founding defect stated as a defect: it is the mechanism exactly as it behaved before this change, and the control that catches it is the one that was missing.

The last row reds at the non-vacuity control, which runs first, so it does not by itself show that the end-to-end control has teeth.
That was measured separately, by running the same defective copy with the test list reduced to the end-to-end control alone:

```
not ok - real-path: main is at c97958f8e2c240eda2fdb3fc903d6cc77b2c8647, not the authorized 7866e849dd88581ba2d760a315ddd018425dc143
```

That refusal is read from the scratch repository's own `git rev-parse`, not from anything this mechanism recorded.

A separate copy replaced the local fast-forward's act with an inert `git status`.
It reds earlier than the post-effect proof, at the assertion, and the wording is worth keeping because it shows the two halves are not independent - an act that changed cannot satisfy an assertion derived from the plan it no longer matches:

```
not ok - real-path: spending the authority: FM_AUTH_ACT_ASSERTION_MISMATCH: the caller asserts an act of 7 argument(s); authorization fm-auth-95013bd6b789e6a992ea32c1f646870d derives one of 5 from its effect plan: expected exit 0, got 3
```

### The adjacent effect authorizers, inventoried

The same invariant applies to every mechanism in this fleet that authorizes an irreversible outward effect.
Two others exist, and neither is changed by this record; they are inventoried here so a reader is not left assuming the property is fleet-wide.

**FirstMate candidate publication**, `bin/fm-publication-guard.sh`, open for independent review as pull request #133 at head `a5db4d0cb5d11811fa0762a3e11a762815f4464a`.
It satisfies the invariant on every axis this record covers: it constructs `git push <remote> refs/heads/<branch>:refs/heads/<branch>` from the authority's own fields rather than running a caller command, resolves a trusted `git` from a fixed executable set to a path and a content digest, binds the remote by a credential-free URL digest and remote identity, and re-observes both at consume, refusing on any mismatch.
Its conformance credit belongs to the exact generation that passes its own review and landing gates, so it is inventoried as conforming and not yet credited.

**no-mistakes `PushStep`**, `internal/pubauth` plus `internal/pipeline/steps/push.go`, at that project's local `main` `0d96d8c`.
Its effect subject is typed and closed - repository, run, push generation, ref, branch, candidate head and tree, expected and observed remote tips, target kind and credential-free target fingerprint, and effect kind - and `Subject.Equal` compares every field exactly, so an `ALLOW_EXACT` echoing any other subject is refused and the push is built from those fields rather than from a caller command.

One axis of the invariant is open there: the git EXECUTABLE is not part of the authorized subject.
`internal/git/git.go` invokes `exec.CommandContext(ctx, "git", args...)`, an ambient `PATH` resolution performed at effect time, with no pinned path and no content digest, so a `git` substituted between authorization and effect would be run rather than refused.
That is the one mechanism-significant field its subject does not carry, and it is exactly the axis both FirstMate mechanisms close.
The owner is that project's `internal/pubauth` and `internal/git`; it is stated here as a follow-on rather than repaired, because that project is outside this change.

### The real end-to-end path

`test_the_whole_path_lands_one_real_fast_forward_and_proves_it` is the only control that does not stub the effect.
It creates a scratch git repository under the suite's own temp root, commits a base and a branch commit, writes a ruled correlation record naming that branch head as the reviewed head, mints a `local-fast-forward` plan against that repository, and spends it.
The act is real `git` advancing a real `refs/heads/main`, and the proof is `git rev-parse main` afterwards, plus the act receipt, plus the authority reporting `spent` and refusing a replay.

### Green run

```
$ bash tests/fm-landing-authorization.test.sh
...
ok - the act performed is the authority's own, and an asserted act may only agree
ok - an executable swapped after authorization refuses at effect time
ok - an incomplete or unsupported effect plan refuses before the act
ok - credential-bearing mechanism input is refused before the act
ok - one approval grants one landing, even under a second plan
ok - concurrent sibling plans share one ruling reservation
ok - a pre-act signal releases the ruling reservation
ok - a failed ruling reservation release is observable
ok - an orphaned granted reservation is reconciled from evidence
ok - a live granted reservation is not reclaimed
ok - an act that exits non-zero leaves the authority indeterminate
ok - a project alias moved after mint performs no act
ok - successful exit requires post-effect proof
ok - the whole path lands one real fast-forward and proves it from the repository
FM_TEST_CONTRACT suite=fm-landing-authorization.test.sh status=pass
```

`tests/fm-landing-seam.test.sh` was re-run unchanged on the same tree and stayed green, which is the evidence that the production merge gates still reach the authority after the act moved inside it.

### Refreshing this record

Re-run the red calibration - not just the green suite - after any change to the plan vocabulary, the act construction, the assertion comparison, or the effect-time re-observation.
Those are the four places where this control can go quietly vacuous while staying green: a plan that stops covering a mutation-significant field, an act rebuilt from something other than the plan, an assertion that stops comparing, and a freshness check that stops looking.

## The restart window, stated precisely

The spend writes its intent before the act and its outcome after, so a process killed between them leaves a durable record that says a spend began and does not say how it ended.
That is reported as `indeterminate`, and it is neither neighbour on purpose: reporting `granted` invites a retry that lands twice, and reporting `spent` strands work that may never have landed.

The restart control runs a blocking act in the spend wrapper's owned process group, waits until that child is running, and sends SIGKILL to the wrapper leader without cooperative cleanup.
It proves reconciliation refuses while the child remains alive, then lets the final group member exit and proves reconciliation can reclaim the authorization rather than refusing forever.
The recovery path asks the kernel directly about the recorded negative process-group id.
Success and `EPERM` both prove that group exists and refuse reclamation, `ESRCH` alone proves it is gone, and any other error leaves the authorization alone as unobserved.
The control proves the `EPERM` refusal and the non-vacuous `ESRCH` reclaim independently.

An act that exits non-zero lands in the same window by the same reasoning: a failed command has not said the irreversible operation had no effect.
The cost is that a transient failure needs `reconcile` rather than a blind retry, and that cost is accepted because a retry that lands twice is not recoverable and a reconciliation is.
`reconcile` requires an `--evidence` pointer and refuses without one, so the way out of the window is an observation rather than a guess.

## Refreshing this record

Re-run the suite after any change to either script.
Re-run the red calibration - not just the green suite - after any change to the head comparison, the spend sequence, or the state vocabulary, because those are the three places where a control can go quietly vacuous while staying green.
