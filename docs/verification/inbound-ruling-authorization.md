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

Date: 2026-08-22.
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
| D00 `bc7aa0672cc7` | none - the staging control, which must be GREEN. | **0 - the staging control must redden nothing** |
| D01 `bab55ff9f495` | LA-1's successor as found: an absent correlation is read as not-applicable instead of consulting the declared governed landing domain. | 13 of 31 |
| D02 `18f80c33c2d0` | An undeclared landing domain is read as an empty one. | 1 of 31 |
| D03 `30d2c3dc1ecb` | A malformed landing domain declaration is read as an empty one. | 1 of 31 |
| D04 `a016a9170f15` | The DECLARATION side of the comparison becomes case-sensitive, so a domain entry written in another case stops matching the repository it names. | 1 of 31 |
| D05 `da8e36fde83a` | A candidate whose repository could not be established is read as being outside the domain rather than as could-not-observe. | 1 of 31 |
| D06 `f684654bac6c` | An explicitly empty landing domain refuses instead of landing, which is the non-vacuity direction: it proves the empty-domain landings are real. | 2 of 31 |
| D07 `fc353b43745c` | The pull-request gate stops telling the seam which repository it writes. | 8 of 31 |
| D08 `86789d762c6e` | The local gate stops telling the seam which repository it writes. | 2 of 31 |
| D09 `4f19104f240f` | The pull-request merge site ignores the seam's answer and always merges. | 4 of 31 |
| D10 `ca0dc3e0eb73` | The local merge site lands outside the spend. | 3 of 31 |
| D11 `1f5b2331419c` | The spend's exit status is read without the act receipt, so a spent authority reports success while merging nothing. | 2 of 31 |
| D12 `4284e4467e3e` | The CANDIDATE side of the comparison becomes case-sensitive, so the domain is shed by how somebody typed a pull request url. | 1 of 31 |
| D13 `02f7c6863e69` | A home with no control venue is refused instead of landing, which is the non-vacuity direction for the shipped default. | 1 of 31 |
| D14 `f3835901e03c` | An emitted-but-unruled request stops counting as live, so a review that was asked for and never answered no longer governs. | 2 of 31 |
| D15 `87d0e31e9065` | A head no live request approved falls through as ungoverned instead of refusing, which makes moving the head the cheapest way to shed a ruling. | 1 of 31 |
| D16 `4e7c7bc7851a` | Two live requests claiming one head resolve to the last one seen instead of refusing, so the authority a landing consumes is picked on no evidence. | 1 of 31 |
| D17 `1fec72e37649` | A declining or unclassifiable ruling is treated as authorizing. | 2 of 31 |
| D18 `07cb85e2f74b` | An unreadable correlation record is skipped instead of refusing, so the one record that might have governed reads as an absence of rulings. | 1 of 31 |
| D19 `95f060504a7f` | Live governance with no configured control venue reads as ungoverned rather than as the configuration contradiction it is. | 1 of 31 |
| D20 `676650357657` | The pull-request gate stops enforcing its own check rollup, so a valid landing authority is all that stands between a red head and the forge. The seam must COMPOSE with the pre-existing guards, never replace them. | 1 of 31 |
| D21 `f53230cb9bec` | The forge's re-observed head is accepted whenever it differs from the approved one, so a pull request that moved after approval still lands. | 1 of 31 |

Every declared control has at least one red witness, and the run reports that count rather than leaving it to be inferred:

```
$ tests/landing-seam-red-matrix.py matrix
controls declared: 31
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
| `test_pr_merge_refuses_an_unreadable_landing_domain` | D01, D03 |
| `test_pr_merge_refuses_live_governance_with_no_configured_venue` | D19 |
| `test_pr_merge_refuses_two_requests_claiming_the_same_head` | D16 |
| `test_pr_merge_refuses_when_the_landing_domain_is_undeclared` | D01, D02 |
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
