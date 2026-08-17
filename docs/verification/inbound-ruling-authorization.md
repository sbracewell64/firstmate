# Verification: the one-use, head-bound landing authorization

Audience: maintainer-verification.
Subject: `bin/fm-landing-authorization.sh` and `bin/fm-landing-authorization-lib.sh`.
Regression owner: `tests/fm-landing-authorization.test.sh`.

## What is claimed

A Browser Sol ruling that approves a landing grants an authority, and this mechanism makes that authority durable, bound to one exact head, and spendable exactly once.

Four properties, and one control without which none of them means anything:

1. An authorization is bound to an exact head and is refused for any other head.
2. It is spent exactly once, so a second use is refused even after a restart mid-spend.
3. A restart during the spend leaves the state determinable rather than silently spent-and-forgotten.
4. An authorization for a superseded request is refused.
5. Non-vacuity: a fresh, correctly bound, unspent authorization is still consumed successfully.

Property 5 is not a courtesy. Properties 1 through 4 are all refusals, and a mechanism that refuses everything satisfies all four at once, so without 5 the suite would be green and worthless.

## What is NOT claimed, and where those properties live

This mechanism does not establish that a ruling answers a given request.
Correlating a ruling to its request, refusing an unrelated ruling, refusing an ambiguous ruling body, and invalidating a request whose identity has moved are owned by `bin/fm-outbound-artifact.sh` and proven by `tests/fm-outbound-artifact.test.sh`.
This starts from a correlation record already in state `ruled`.

It does not re-derive the correlation record's own identity digest, and it does not re-read the ruling comment on the forge.
A correlation record that is internally consistent but forged, and a ruling edited on the forge after correlation, are both outside what this establishes.

The head shape check accepts either a 40- or 64-character object id because this mechanism never clones the target repository and so cannot determine its object format.
That is weaker than the outbound owner's resolvable-object rule, and it is sound here only because the shape is a prefilter: the property is carried by equality against an independently observed head, not by the shape.

**This mechanism is not yet wired into a landing path.**
Nothing in `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh` calls it, and the correlation records it consumes are created by an outbound emitter that has not landed.
What is verified below is the authority layer itself against correlation records supplied as data in the published schema.
Verified-and-unwired is a real state and is recorded here rather than left for a reader to assume either way.

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
