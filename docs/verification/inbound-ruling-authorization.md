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

A Browser-Sol-governed landing candidate cannot reach either mutation path's merge command without consuming a valid, head-bound, one-use authorization, and a candidate no ruling governs lands through the ordinary gates and says so.

1. A governed candidate with no approving ruling is refused by the real `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`, and no merge is performed.
2. A spent authority presented again is refused, and the second attempt performs no merge.
3. Non-vacuity, landing: a governed candidate under an approving ruling lands, and the authority is recorded spent.
4. Non-vacuity, not-applicable: an ungoverned candidate lands normally, and the not-applicable observation is reported on the command's own output.
5. Governance survives a moved head. A ruling bound to another head refuses rather than falling through as ungoverned, because falling through would make moving the head the cheapest way to shed a ruling.
6. The seam composes with the pre-existing merge guards and never replaces them: a red check rollup still refuses under a valid authority, and leaves that authority unspent.
7. Two live requests claiming the same item at the same head are ambiguous and refuse, rather than one of them being picked.
8. Governance ends. A closed request no longer governs, and a gate outside the landing-governing set never did, so neither can make an item permanently unlandable.

Claims 3, 4, and 8 are not courtesies.
Claims 1, 2, 5, 6, and 7 are all refusals, and a merge gate that refused everything would satisfy every one of them at once.

### What is NOT claimed

The seam does not decide whether a ruling approves.
`bin/fm-landing-authorization.sh` owns minting, the closed approving-verdict set, the exactly-once spend, and the head re-observation; the seam selects the request to hand it and refuses to guess when the selection is not unique.

It does not correlate a ruling to a request, and it does not create correlation records.
Both are owned by `bin/fm-outbound-artifact.sh`.

It establishes nothing about whether a head is green, mergeable, or unblocked by review.

Which gates govern a landing is a decision, not an observation: every `sol-control` gate governs except `ARCHITECTURE_RULING_REQUIRED`, whose subject is a design question rather than this head's fitness to land.
The exclusion is stated as an exclusion so that a gate added to the outbound vocabulary later governs a landing until somebody decides otherwise.

### The act is counted, never assumed

`spend` exits 0 on two different outcomes: the act ran and the authority is now spent, or the authority was already spent and no act was performed.
Reading only the exit status turns the second into a merge gate reporting success while merging nothing, which is the double-land this whole mechanism exists to prevent.
So the act is wrapped in a prologue that records having been entered, and a landing counts as performed only when that receipt says the act was reached.
Defect 06 below is that control's own red.

The suite counts the same way. A merge is observed by counting the `pr merge` invocations the fake forge recorded, and a local landing by comparing the default branch's own commit, and both counts are printed in the passing line - because zero merges is also what a completely broken gate produces.

### Red calibration

Every control was observed failing for its intended reason.
Each run stages a copy of `bin/` and `tests/`, injects exactly one defect, and runs `bash tests/fm-landing-seam.test.sh`.
`00-no-defect` is the harness's own control: an unpatched staged copy must be green, or a red below would be evidence about the staging rather than about the defect it names.
`passed=` is how many cases reported success before the suite stopped at its first failure.

| # | Injected defect | Observed result |
| - | --------------- | --------------- |
| 00 | none - the staging control | `GREEN (passed=19)` |
| 01 | the pull-request merge site ignores the seam and always merges | `not ok - governed-ruled: expected exactly one spent authorization, got [fm-auth-a5062494976aa3f7c0e0583bb85b1885 granted]` |
| 02 | the governed branch lands directly instead of inside the spend | `not ok - governed-ruled: expected exactly one spent authorization, got [fm-auth-a5062494976aa3f7c0e0583bb85b1885 granted]` |
| 03 | the local merge site lands outside the spend | `not ok - local-governed-unruled: an unruled review gate must refuse the fast-forward, got exit 0` |
| 04 | not-applicable is decided and never reported | `not ok - ungoverned: expected 'FM_LANDING_NOT_APPLICABLE' in the command's own output` |
| 05 | a head no ruling approved is reported as ungoverned | `not ok - governed-moved-head: a head the ruling never approved must refuse, got exit 0` |
| 06 | the spend's exit status is read without the act receipt | `not ok - governed-replay: a spent authority must refuse the second landing, got exit 0` |
| 07 | an unreadable correlation record is skipped instead of refusing | `not ok - unreadable-record: an unreadable record must refuse, got exit 0` |
| 08 | live governance with no configured venue reads as ungoverned | `not ok - governed-no-venue: live governance with no venue must refuse, got exit 0` |
| 09 | the caller's head replaces the forge's re-observed one | `not ok - reobserved-head: a moved forge head must refuse, got exit 0` |
| 10 | an unruled request is allowed to grant an authorization | `not ok - governed-unruled: expected 'FM_LANDING_AUTHORIZATION_REFUSED' in the command's own output` |
| 11 | LA-1 as found: the pull-request gate asks and does not enforce the answer | `not ok - governed-unruled: an unruled review gate must refuse the merge, got exit 0` |
| 12 | LA-1 as found: the local gate never asks | `not ok - local-governed-unruled: an unruled review gate must refuse the fast-forward, got exit 0` |
| 13 | a closed request keeps governing | `not ok - closed-request: a closed request must not govern, got exit 1: ... FM_LANDING_AUTHORIZATION_REFUSED` |
| 14 | the non-landing gate exclusion is emptied, so every gate governs | `not ok - nongoverning-gate: a non-landing gate must not block, got exit 1: ... FM_LANDING_AUTHORIZATION_REFUSED` |
| 15 | two claims on one head resolve to the last one seen | `not ok - ambiguous-authority: two claims on one head must refuse, got exit 0` |

Defects 11 and 12 are the finding this work closes, reproduced deliberately: the authority layer is present and correct in both copies, and the landing path routes around it.
Defect 11 keeps the not-applicable report intact so its red is attributable to the unenforced answer rather than to a missing observation, which defect 04 covers on its own.

Defect 09 is the one the head binding rests on, and it is injected into `bin/fm-landing-authorization.sh` rather than into the seam on purpose: it proves the seam actually reaches the authority layer's independent head observation, and is not satisfied by the head the merge gate itself verified.

Defects 13 and 14 are the inverse direction, and they matter as much as the refusals.
Both decision sets - which record states are live, and which gates govern a landing - are stated positively so they can be over-applied, and an over-applied set makes an item permanently unlandable.
Those two defects are what keeps this control from being repaired into a different failure.

### Green run

```
$ bash tests/fm-landing-seam.test.sh
ok - an ungoverned pull request lands through fm-pr-merge and reports not-applicable (merges executed: 1)
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
ok - an ungoverned local-only task lands through fm-merge-local and reports not-applicable (fast-forwards executed: 1)
ok - an unruled Browser Sol review gate refuses the real fm-merge-local path (fast-forwards executed: 0)
ok - an approved ruling lands through fm-merge-local and spends its authority (fast-forwards executed: 1, authorizations spent: 1)
ok - a spent landing authority refuses a replayed fm-merge-local (fast-forwards executed across two attempts: 1)
FM_TEST_CONTRACT suite=fm-landing-seam.test.sh status=pass
```

The pre-existing suites for both landing paths were re-run unchanged on the same tree, because the seam must not have altered any refusal they already owned:

```
$ bash tests/fm-pr-merge.test.sh | grep -c '^ok'
45
$ bash tests/fm-merge-local.test.sh | grep -c '^ok'
27
```

### Refreshing this record

Re-run both suites after any change to the seam, either merge gate's merge site, or the authority layer.
Re-run the red calibration - not just the green suites - after any change to the applicability rule, the governing-gate set, the live-state set, or the act receipt, because those are the four places where this control can go quietly vacuous while staying green.

## Effect-plan verification

Date: 2026-08-26.
Subject: `bin/fm-landing-authorization.sh` and `bin/fm-landing-authorization-lib.sh`, as consumed by `bin/fm-landing-seam-lib.sh` inside `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh`.
Regression owner: `tests/fm-landing-authorization.test.sh`, controls 16 through 22.
The effect-plan contract is stated once in `bin/fm-landing-authorization-lib.sh`'s header.
This section records only the repeatable evidence for that contract and the required inventory of adjacent authorizers.

### Red calibration

Every control was observed failing for its intended reason.
Each defect was applied to a fresh copy of `bin/` and `tests/` under a scratch root created with `mktemp -d`, outside this repository, and the copy was run unmodified otherwise.

```sh
scratch=$(mktemp -d)
for d in caller-act-performed exec-digest-unchecked plan-field-defaulted \
         credential-screen-off ruling-reland-allowed act-never-performed; do
  mkdir -p "$scratch/$d" && cp -a bin tests "$scratch/$d/"
done
# one defect applied per copy, then:
for d in caller-act-performed exec-digest-unchecked plan-field-defaulted \
         credential-screen-off ruling-reland-allowed act-never-performed; do
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

A seventh copy replaced the local fast-forward's act with an inert `git status`.
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

Control 22 is the only one that does not stub the effect.
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
