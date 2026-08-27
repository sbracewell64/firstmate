# Verification: the candidate-publication effect and identity guard

Audience: maintainer-verification.
Subject: `bin/fm-publication-guard.sh` and `bin/fm-publication-seam-lib.sh`, the publication and custody effect subjects added to `bin/fm-landing-authorization-lib.sh`, and the seam that consumes them inside `bin/fm-attest.sh`.
Regression owners: `tests/fm-publication-seam.test.sh` for the guard and its controls, `tests/fm-attest.test.sh` for the wiring into the real publication path.

## What is claimed

A candidate reaches the outside world when it is PUSHED, not when it is merged.
This mechanism asks whether that push is permitted before the remote moves, binds the answer to one exact subject, and exhausts the answer by using it.

Sixteen properties, and one control without which none of them means anything:

1. A governed publication is refused before the remote moves whenever an active hold, an unmet must-close ruling, a placeholder or unmapped identity, a second actionable candidate for the same semantic work, a retained predecessor ref, a stale ruling or policy generation, or a remote tip other than the one planned against applies.
2. Permission is re-compiled at the moment of use, so an authority granted while eligible refuses once a newer hold, a revoked ruling or a bumped generation arrives.
3. A remote that moved under a granted authority refuses without overwriting what moved it.
4. An authority is spent exactly once through the authorization store's atomic compare-and-claim mechanism, so concurrent consumers execute one push and every replay refuses and publishes nothing.
   A claim binds the owning process identity and process group; a provably dead owner can be reclaimed through a durable, restartable intent, while a live group or unobservable owner refuses reclamation, and consume, reconcile and retire cannot overwrite one another.
5. An authority consumed before its effect is durably `consumed-without-confirmed-effect`, is never resurrected, and recovery mints a fresh authority for the same unchanged subject rather than reusing it.
6. A remote already equal to the head is a typed `NO_EFFECT_ALREADY_EQUAL` result that consumes no authority.
7. A governed candidate publishes only when a ruling is bound to the EXACT head being published and the role qualification register currently records the declared reviewer as qualified and assignment-distinct against the declared maker.
   Policy governance says a review is REQUIRED and never that one happened; a register answer of could-not-observe is non-PASS and never a pass.
8. An outbound record in a state no landed vocabulary declares reads as a hold in force, not as an absence of one.
9. An approval bound to this head does not cover for another live governing request that is still unanswered.
10. A remote-changing candidate act carries an effect class the GUARD decides: `CUSTODY_REPLICATION` grants nothing beyond a remote copy of one exact commit on the work's own unprotected feature ref, `PUBLICATION_EFFECT` carries every obligation above, and a class the evidence does not support is refused rather than reclassified.
11. The candidate states `local-only`, `custody-replicated`, `review-published`, `publication-qualified`, `landing-authorized` and `landed` are projected from the durable owners, none implies the next, and a slot is reclaimable only when `ls-remote` resolves the custody ref to the exact candidate head.
12. Consume accepts only the constructed single-ref, non-forcing `git -C <repo> push <remote> <head>:<ref>` token sequence bound by the authority; wrappers, extra refspecs, alternate sources and other argument shapes refuse before the act.
13. Every observation and act resolves Git from the fixed trusted executable set rather than from caller functions or `PATH`, and the spend record identifies the selected executable by absolute path and content digest.
14. An authority binds the canonical remote name, credential-free push URL, URL digest and venue identity at grant time and enforces all four again at consume time; a credential-bearing remote is refused rather than accepted after stripping its userinfo.
15. Push output and exit status are captured in the spend record and included in an unconfirmed-effect refusal only after the shared default-deny credential scrubber has removed or withheld every unsafe line.
16. An ungoverned act still passes the same command validation, atomic one-use spend and post-effect remote confirmation, then returns the distinct `FM_PUB_NOT_APPLICABLE` classification that callers relay verbatim.
17. Non-vacuity: a governed candidate with a clean identity, no hold, an approving exact-head ruling, a qualified reviewer, one semantic owner, fresh generations and the exact remote tip publishes exactly once; and an exact clean candidate replicates to its own feature ref under a custody authority.

Property 17 is not a courtesy.
Properties 1 through 16 all pass against a guard that refuses everything, so without 17 the suite would be green and worthless.

## What is NOT claimed, and where those properties live

**This does not make a remote unbypassable.**
A human typing `git push`, a provider web UI, and no-mistakes' own `PushStep` each reach a remote without passing here.
What is claimed is narrower and exact: every remote-changing publication FIRSTMATE ITSELF performs reaches this verdict first.
Server-side protection is the separate defence for the other paths and is not established by anything in this file.

**The no-mistakes candidate branch push is a different repository's owner.**
`internal/pipeline/steps/push.go`'s `(*PushStep).Execute` is where a candidate branch is published, and its eligibility call belongs after `resolveForcePushDecision` and immediately before the first possible `git.PushCommit`.
That is the `no-mistakes` project, not this one.
What lands here is the FirstMate half the patch plan already separates: the external verdict compiler such an integration consumes, reachable as `fm-publication-guard.sh prepare`, whose closed result vocabulary is the contract.
Installed no-mistakes v1.40.3 has no trusted pre-publication command to reach it with, so nothing here asserts that the branch push is currently guarded.

**Applicability is not governance.**
A home with no publication identity policy and no live Browser Sol request governs nothing, and a publication there proceeds and reports that it was ungoverned.
Only once a policy exists does an unidentifiable venue become could-not-observe rather than ungoverned.

**A GitHub email association is never maker proof.**
The governed identity mapping is what `config/publication-identity.json` states; an identity it does not state refuses, whatever a forge associates.

**Custody replication is not review, CI, acceptance or landing, and nothing here claims it prevents them.**
A custody push copies one commit to the work's own feature ref.
Whether a forge or a CI system reacts to a ref appearing is that system's own configuration and is outside this mechanism entirely.
What is established is narrower and exact: a custody replication grants none of those states, the projection does not advance past `custody-replicated` because of one, and the publication obligations remain unmet afterwards.

**This does not qualify a reviewer, and it does not judge review quality.**
`bin/fm-qualification.sh` owns whether a binding was ever observed to do a job, and this consumes its verdict through the command it publishes.
A reviewer the register records as qualified may still review badly; nothing here establishes otherwise.

**The undeclared-state rule is a placeholder for a vocabulary that does not exist yet.**
`quarantined` is written by the outbound owner's quarantine path and is absent from `FM_OUTBOUND_RECORD_STATES`.
Until `outbound-quarantined-state-vocabulary-integration` lands, `fm_pub_seam_state_in_force`'s undeclared branch is load-bearing; afterwards it becomes a pass-through to the landed live rule and that branch becomes unreachable.

**Correlation is somebody else's proven work.**
Whether a ruling answers a given request, an unrelated or ambiguous ruling body, and a request whose identity has moved are owned by `bin/fm-outbound-artifact.sh`.
This reads those records read-only, exactly as the landing authority does.

## How the effect is observed

The effect is COUNTED, never assumed.
Every case reads the remote's actual tip with `git ls-remote` before and after and asserts the value it found, and the wiring cases read the push target's own ref state afterwards.
This matters more here than anywhere else in the fleet: "no bad publication happened" is also exactly what a completely broken guard produces, and a refusal asserted only from an exit status would pass just as well against a command that refuses everything.

Every refusal case is ONE perturbation away from `test_publishes_one_governed_candidate_exactly_once`, which runs the same fixture unperturbed and publishes.
That pairing is what makes each refusal evidence about its own perturbation rather than about a mechanism that refuses everything.

## Dated evidence

Observed 2026-08-22 on Linux, from FirstMate `1f2141ad25b0da95b1d0a680b4b5887f2ec1ca5c` tree `3e10762412ef0fa6d884deaae974c6d44bc4cd2b`, with git 2.53.0, jq 1.8.1 and ShellCheck 0.11.0.
The no-mistakes source generation was reconciled at `c0e06bebd0a43f17365af755b98f942d77fcd82c` tree `facd921041317e348a200eb79ecbe7c05121a1e8`, and `git log c0e06beb..HEAD -- internal/pipeline/steps/push.go internal/gatecontext` was empty, so the reviewed owner bytes had not moved.

```
bin/fm-test-run.sh tests/fm-publication-seam.test.sh
  -> 26 ok, 0 not ok, FM_TEST_CONTRACT status=pass
bin/fm-test-run.sh tests/fm-attest.test.sh
  -> 95 ok, 0 not ok
```

Controls selected 26, attempted 26, completed 26 for the guard suite; the two wiring cases in the attestation suite were selected 2, attempted 2, completed 2.

### Dated evidence: the review-qualification repair, the undeclared state, and the effect class

Observed 2026-08-25 on Linux from the candidate worktree, with git 2.53.0, jq 1.8.1 and ShellCheck 0.11.0.
Measured at `af5cfefdae8174ea47b415e0e2cef75bbc13a9a1` tree `485dbaddfe79e1b8d17e205cc4857655e39c7eb7`; the commit adding this record follows it, so that head is the code these numbers were taken from rather than the head of the branch.

```
bash tests/fm-publication-seam.test.sh
  -> 44 ok, 0 not ok, FM_TEST_CONTRACT status=pass
bash tests/fm-attest.test.sh
  -> 95 ok, 0 not ok
bash bin/fm-lint.sh
  -> fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0), exit 0
bash bin/fm-dead-predicate-check.sh
  -> ok enrolled=6 scanned=119 unchecked=247 alive=137 could_not_observe=0 marked=0
bash bin/fm-doc-audience-check.sh
  -> ok surfaces=92 local_links=403
```

Controls selected 44, attempted 44, completed 44.

### Red calibration

Every control was observed failing for its intended reason.
Each run stages a full copy of the worktree, injects exactly one defect, and runs the named suite.
`00-no-defect` is the harness's own control: an unpatched staged copy must be green, or a red below would be evidence about the staging rather than about the defect it names.

| # | Injected defect | Observed result |
| - | --------------- | --------------- |
| 00 | none - the staging control | `GREEN (17 ok, before control 12 was added)` |
| 01 | the hold check is removed | `not ok - hold: an active publication hold did not refuse (exit 0): ALLOW_EXACT fm-auth-4c218bee65892f10d1ca6fb358b858b1` |
| 02 | the placeholder identity check is removed | `not ok - placeholder: the refusal did not name the placeholder identity: REFUSE FM_PUB_IDENTITY_UNMAPPED ... (missing: 'FM_PUB_IDENTITY_PLACEHOLDER')` |
| 03 | remote movement is not compared | `not ok - wrong-tip: a wrong expected tip did not refuse (exit 0): ALLOW_EXACT fm-auth-b2fd02c433f6ab36b7e6c5675500305e` |
| 04 | a rival actionable candidate is ignored | `not ok - duplicate: a second actionable candidate did not refuse (exit 0): ALLOW_EXACT fm-auth-009612b99576b11f0a1c8fec6dcad0c2` |
| 05 | an unreadable correlation record is read as an absence | `not ok - unreadable: an unreadable correlation record must be could-not-observe, not a verdict (exit 0): ALLOW_EXACT fm-auth-3c355dfd950916f73f451193a94615f5` |
| 06 | a stale generation is not compared at the moment of use | `not ok - generation: the refusal did not name the changed generation: REFUSE FM_PUB_REMOTE_TIP_MOVED ... (missing: 'FM_PUB_GENERATION_CHANGED')` |
| 07 | a spent authority is accepted again | `not ok - replay: a spent authority was accepted again (exit 0): NO_EFFECT_ALREADY_EQUAL ...` |
| 08 | the effect is trusted from the exit status instead of the remote | `not ok - unconfirmed: an unconfirmed effect was not could-not-observe (exit 0): APPLIED fm-auth-525d47b0974e18e318caaaa3ac79b75d refs/heads/candidate now at -` |
| 09 | an authority consumed without a confirmed effect is restored | `not ok - unconfirmed: a retired authority was not void: granted (missing: 'void')` |
| 10 | a retained predecessor is treated as actionable | `not ok - predecessor: a superseded candidate did not refuse (exit 0): ALLOW_EXACT fm-auth-eec559bc2e836a1a080a07be9c89911d` |
| 11 | the attestation path pushes directly instead of through the guard | `not ok - a publication that could not be placed under this home's governance was published` |
| 12 | the outcome record is rebuilt from the copy read before the intent | `not ok - intent: the spent record carries no record of the intent written before the act` |
| 13 | the wiring relays the guard's verdict word as the token | `not ok - token: the refusal doubled its own verdict word instead of naming the reason: REFUSE REFUSE ... (unexpected: 'REFUSE REFUSE')` |
| 14 | a dry run mints anyway | `not ok - dry-run: a probe minted an authority (0 -> 1): [fm-auth-4403b3ee68f326f7c437f6b624209e33 granted]` |
| 15 | retirement rebuilds the record instead of amending it | `not ok - retire: retirement changed what the record says it authorized` |
| 16 | retirement accepts a spent record | `not ok - retire-spent: a spent authority was retired (exit 0): RETIRED fm-auth-eb8a8d0248ce456bc30678520f7a72b6 is now void (tidy up)` |
| 17 | retirement is not idempotent | `not ok - retire-twice: repeating the retirement changed the record` |
| 18 | a retired authority is still spendable | `not ok - retire-consume: a retired authority was accepted (exit 0): APPLIED fm-auth-4f6058d22d127f535eed8530bcc00ea8 refs/heads/candidate now at 52372b62` |

#### Reds 19 to 32: the review-qualification repair, the undeclared state, and the effect class

Observed 2026-08-25 by the same method: a full staged copy of the worktree, exactly one injected defect, the named suite run.

| # | Injected defect | Observed result |
| - | --------------- | --------------- |
| 19 | an outbound state no landed vocabulary declares is skipped instead of held | `not ok - undeclared: a request in state 'quarantined' did not refuse the publication (exit 0): ALLOW_EXACT fm-auth-a0e0fbc6439bbe8cd2eccaa669669052` |
| 20 | the requirement for a ruling at this exact head is removed | `not ok - unreviewed: a candidate no ruling reviewed did not refuse (exit 0): ALLOW_EXACT fm-auth-4a384ce1de9ca62a41c0744e36ea2fde` |
| 21 | the role qualification register's answer is always taken as yes | `not ok - unqualified: a QUALIFICATION_REQUIRED reviewer did not refuse (exit 0): ALLOW_EXACT fm-auth-93de6afdfa0a6b40891687c5deb76f31` |
| 22 | a register could-not-observe is read as a pass | `not ok - qualification-unobserved: an unobserved qualification was not could-not-observe (exit 0): ALLOW_EXACT fm-auth-dc7f49abd69dae288a15e91ecb73aed1` |
| 23 | an undeclared review contract is read as exemption from review | `not ok - contracts-undeclared: an unstated review contract was not could-not-observe (exit 0): ALLOW_EXACT fm-auth-98280fecc0438386ea3c8c294fc27896` |
| 24 | one approval covers for every other unmet obligation | `not ok - newer-hold: a hold arriving after the grant did not refuse (exit 0): APPLIED fm-auth-282b2ac4b198bf188f85bcfee1f73479 refs/heads/candidate now at f5ec94f3` |
| 25 | the candidate need not be the head that is checked out | `not ok - custody-drift: the custody replication was not refused (exit 0): ALLOW_EXACT fm-auth-55a112a732b0a12d7ef2e7a8e1e76b1f class=CUSTODY_REPLICATION` |
| 26 | an unclean worktree is replicated anyway | `not ok - custody-dirty-tracked: the custody replication was not refused (exit 0): ALLOW_EXACT fm-auth-cb4a889c89e301ee9c8f8723353ebab4 class=CUSTODY_REPLICATION` |
| 27 | custody may address any ref | `not ok - custody-wrong-ref: the custody replication was not refused (exit 0): ALLOW_EXACT fm-auth-de1e0c20bef8f1b772f6601250c053fb class=CUSTODY_REPLICATION` |
| 28 | the act's forcing arguments are not inspected | `not ok - custody-force: '--force' was not refused (exit 0): To .../custody-force-force/remote.git` |
| 29 | an occupied custody ref is advanced onto | `not ok - custody-occupied: the custody replication was not refused (exit 0): ALLOW_EXACT fm-auth-92175c27ea24928b603948a07ff44504 class=CUSTODY_REPLICATION` |
| 30 | a custody replication is projected as a review | `not ok - custody-grants-nothing: the projection did not stop at custody` |
| 31 | reclaimability is read from branch existence rather than the exact head | `not ok - reclaim-other-head: a branch at another head was treated as a backup (exit 0): custody-replicated yes ... at exactly 726b904e` |
| 32 | an unreachable remote is read as not-reclaimable rather than unobserved | `not ok - reclaim-unreachable: an unreachable remote was not could-not-observe (exit 3): custody-replicated no` |
| 33 | the protected-ref rule is removed, and the protected ref IS the work's own derived ref | `not ok - custody-protected-own: the custody replication was not refused (exit 0): ALLOW_EXACT fm-auth-2cd69528505fae09738b971492275cfd class=CUSTODY_REPLICATION` |
| 34 | the custody effect is trusted from the act's exit status instead of the remote | `not ok - custody-unconfirmed: an unconfirmed custody effect was not could-not-observe (exit 0): APPLIED CUSTODY_REPLICATION fm-auth-b2456d9cbe8c892b79be742ce1cae2e1 refs/heads/fm/fixture-work now at -` |
| 35 | the typed no-effect for a repeated replication is removed | `not ok - custody-restart: a repeated replication did not complete: REFUSE FM_PUB_CUSTODY_REF_OCCUPIED: ... already has refs/heads/fm/fixture-work at aa1ee7ed...` |
| 36 | review publication is read from this work rather than from this head | `not ok - project-other-head: a request at another head was read as this head being submitted` |

Eighteen controls were added and seventeen of them appear above; the eighteenth is the custody non-vacuity case, which by definition has no red.
Control 17's reclaimability case carries two rows because it asserts two different wrong answers.

Red 34 needed the run block trimmed to the two custody spend cases before it could be attributed.
The suite stops at its first failure, and this defect breaks an earlier publication-path control first, so the unmodified run reported that one and never reached the custody case.
That trim is a change to the harness and not to the subject, and it is recorded because a red read off a suite that stopped earlier is a red about a different control.

Red 35 is the weakest row here and is marked as such: with the typed no-effect removed the restart is refused as an occupied ref rather than permitted, so the row establishes that the typed answer is gone and does not independently establish that a no-effect consumes nothing.
That second half is asserted directly by the control, which compares the whole authority store across the restart.

Two controls were REWRITTEN after their first red proved they were measuring a different rule, and the rewrite is the point rather than an aside.

A protected-ref case built on `refs/heads/main` went red with protection removed - but it went red naming `FM_PUB_CUSTODY_REF_NOT_PERMITTED`, because `refs/heads/main` is not the work's own ref either.
That case would have passed with the protection deleted entirely, so it was evidence about the permitted-ref rule wearing the protected-ref rule's name.
It now protects the work's OWN derived ref, which is the only construction that rule alone catches.

An occupied-ref case compiled against an absent tip went red naming `FM_PUB_REMOTE_TIP_MOVED` for the same reason.
It now compiles against the tip that is actually there, so the caller is one that knows the ref is occupied and is asking to advance it, and only the occupied rule stands in the way.

Red 24 is worth reading twice for the opposite reason: it is an EXISTING control going red under a rule that was strengthened, not a new control.
Once an approving ruling exists in the green fixture, the old "any approval is enough" phrasing let a hold arriving after the grant through - so the strengthening was required to keep a guarantee the suite already claimed.

Red 30's perturbation is one line in the projection rather than in the fold, because that is where the claim lives: the fold already refuses to publish, and what property 11 asserts is that the projection does not describe a backup as a review.

Reds 06 and 07 are worth reading twice, because both name a token other than the one the defect removed.
That is defence in depth showing itself rather than a miscalibrated control: with the explicit generation comparison gone the authority identity still fails to recompute, and with the replay refusal gone the remote is already at the head so the second consume becomes a no-effect.
Both still go red, and both name what actually happened.

Red 11 is the only one that establishes the wiring, and it is the one without which every other row is a description of a control rather than a control.

Control 12 was found by re-reading the spend sequence rather than by any test failing, which is the reason it is listed: the record still reported `spent`, so every state assertion in the suite stayed green while the intent evidence was being dropped.
A control that only checks the state a mechanism reports cannot see a mechanism losing the evidence for that state.

### The real seam, on the real remote

Synthetic fixtures establish the logic; they do not establish that the mechanism refuses a real prohibited attempt against a real remote.
This probe was run from the candidate worktree against `github.com/sbracewell64/firstmate`, the venue this branch would publish to, on 2026-08-22.
It is read-only by construction: `prepare` observes the remote with `git ls-remote` and mints a local record, and it never pushes.

Subject: head `8398169e9c0145d15f597cdc3fbde4c7642a92c2`, tree `81a4216f4a023a7687cbe2a93b3b20ee8df61427`, ref `refs/heads/fm/candidate-publication-effect-guard`.
That ref was absent on the remote before, between and after every step below, so no remote moved.

| Step | Perturbation | Observed result |
| ---- | ------------ | --------------- |
| 1 | the active publication quarantine holds this exact work at this exact head | `REFUSE FM_PUB_ACTIVE_HOLD: 1 live Browser Sol request(s) hold candidate-publication-effect-guard and none approves publishing 8398169e...` |
| 2 | the hold alone is lifted; every other axis is unchanged | `ALLOW_EXACT fm-auth-80a080d99481ca56401b57bfdddd5ab4` |
| 3 | the hold alone is restored | `REFUSE FM_PUB_ACTIVE_HOLD ...` (identical to step 1) |

Step 2 is what makes steps 1 and 3 evidence about the hold rather than about a mechanism that refuses everything, and the round trip is what makes it evidence about that one axis rather than about fixture drift between two runs.

An earlier attempt at step 2 refused with `FM_PUB_IDENTITY_UNMAPPED` because the probe policy named an author the commit does not carry.
That is recorded rather than removed: it is the guard declining to publish under an identity nobody declared, observed on the real remote, and it is the one axis a synthetic fixture is least able to get wrong by accident.

### The governed subject, against the provisioned records

The probe above ran before this home's governance was provisioned, which is why it names a policy-only verdict.
Repeated on 2026-08-23 against the completed provisioning - identity policy generation `pol-2026-08-23-g1` and canonical request `fm-ob-4e8925ac8dae`, gate `AWAITING_BROWSER_SOL`, emitted and unruled - it reaches the refusal the governance is there to produce.

Subject: head `25427e9e39931d25984227943c892d59edf5c072`, tree `910b6a74f7afc9b61226aff6dee9046f3dc2e250`, ref `refs/heads/fm/candidate-publication-effect-guard`.

| Step | State | Observed result |
| ---- | ----- | --------------- |
| 1 | the canonical request holds this exact head, unruled | `REFUSE FM_PUB_ACTIVE_HOLD: 1 live Browser Sol request(s) hold candidate-publication-effect-guard and none approves publishing 25427e9e...: fm-ob-4e8925ac8dae(AWAITING_BROWSER_SOL/emitted unruled)` |
| 2 | the same head and policy with that hold absent | `ALLOW_EXACT fm-auth-873c92ff3bdc6989eb91e233b56629ad` |
| 3 | the hold restored | identical to step 1 |

Step 2 ran in a scratch home so the operational store was never written, and it is what makes steps 1 and 3 evidence about the request rather than about a mechanism that refuses everything.

Across all three the operational authorization store stayed byte-identical (`sha256 4e1782f3...`, one record) and the remote ref stayed absent.
That is the property the whole probe exists to demonstrate: asking the question changes nothing.

### The real seam, at the exact candidate head, 2026-08-25

Run from the candidate worktree against `github.com/sbracewell64/firstmate`, the venue this branch would publish to.
Subject: head `af5cfefdae8174ea47b415e0e2cef75bbc13a9a1`, tree `485dbaddfe79e1b8d17e205cc4857655e39c7eb7`, ref `refs/heads/fm/candidate-publication-effect-guard`, worktree clean.
Every step used `prepare --dry-run` or the read-only `project`, so nothing was minted and nothing was pushed.

| Step | Asked | Observed result |
| ---- | ----- | --------------- |
| A | may this candidate be PUBLISHED? | `REFUSE FM_PUB_ACTIVE_HOLD: 1 live Browser Sol request(s) hold candidate-publication-effect-guard and 0 of them approve publishing af5cfefd...: fm-ob-6267e1c729b9(EXACT_HEAD_BROWSER_REVIEW_REQUIRED/quarantined at cf4c640b...)` |
| B | the same, with the only hold lifted in a scratch home | `REFUSE FM_PUB_NO_EXACT_CANDIDATE_REVIEW: ... no ruling approves publishing af5cfefd..., so this candidate has no review bound to the exact head it would publish` |
| C | the same, plus a synthetic approving ruling at this exact head | `REFUSE FM_PUB_REVIEWER_NOT_QUALIFIED: ... openai-codex/gpt-5.6-luna is QUALIFICATION_REQUIRED for contract runtime-change-review ... record luna-max-runtime-change-review-v2-20260823 records QUALIFICATION_REQUIRED` |
| D | may this candidate be REPLICATED for custody? | `ALLOW_EXACT fm-auth-5be6d231b61e0e398eeeada10ec73ac8 class=CUSTODY_REPLICATION` |
| E | what state is this candidate in? | `STATE local-only`, with `custody-replicated no`, `review-published no`, `publication-qualified no`, `landing-authorized no`, `landed no`, `reclaimable no` |

Step A is the first finding closed at the real seam.
Before this work the same probe at the same head returned `ALLOW_EXACT`, because the quarantined request fell out of the live-state test and its hold disappeared from the answer.

Steps B and C are the second finding closed, and they are staged rather than combined because each removes exactly one thing.
B lifts only the hold, so what stops the publication next is the absence of any ruling bound to this head - which is the state the earlier `ALLOW_EXACT` had been credited as a satisfied review.
C then supplies an approving ruling at this exact head in the scratch home, which is the only way to reach the reviewer question at all, and the register answers with the real recorded state of the real binding.
Neither B nor C is evidence that a review happened; both are evidence that the guard now asks.

Step D is what makes the separation non-vacuous, and it is the whole reason this work exists: at the same head, in the same home, under the same hold, publication is refused and custody is permitted.
A guard that refused both would produce exactly step A and nothing would be learned from it.

Step E reads `review-published no` while a live request names this work, because that request holds an EARLIER head.
That is the corrected behaviour; the first run of this probe reported `review-published yes` and is what found the defect.

Throughout, the operational authorization store stayed byte-identical (`sha256 4e1782f3...`, one record) and `refs/heads/fm/candidate-publication-effect-guard` stayed absent on the remote, before and after every step.
Asking the question changes nothing.

## The two effect classes

A remote-changing candidate act is one of exactly two things, and the guard decides which.

`CUSTODY_REPLICATION` is a durable backup of one exact committed candidate to its own unprotected feature ref, `refs/heads/fm/<work-id>` on the work's own venue.
It grants nothing: no pull request, no review request, no CI implication, no acceptance, no landing authority, no publication-qualified state.
It demands what publication never asks - a clean worktree including untracked files, the candidate actually checked out at that exact head and tree, an unprotected ref DERIVED from the work rather than chosen by the caller, no force in any form, and a remote ref absent or already equal.
It is not subject to the review it does not claim, so a candidate under an active publication hold may still be backed up.

`PUBLICATION_EFFECT` is anything that makes the candidate enter the review, CI, publication or landing lifecycle.
It is the default, and it carries every obligation this record already claimed.

`--effect` names the class a caller WANTS and never settles it.
The request is verified against observation, and one the evidence does not support is refused rather than quietly reclassified - so a caller cannot discover the class by trying, and custody is strictly weaker in what it grants while being strictly stricter in what it demands.
There is no argument by which naming a class obtains more permission than the evidence already gives.

The force refusal applies to BOTH classes.
The guard has already established the remote is at the tip the plan was compiled against, so a fast-forward suffices, and forbidding a force on the weaker act while permitting it on the stronger one would be incoherent.

## Refreshing this record

The 2026-08-27 UTC rerun at candidate `ff80599ab64cc0955405b8b4965b69b3876d428d` completed the publication-seam suite with `FM_TEST_CONTRACT status=pass` and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0`.
Its 64 controls include stale-claim recovery, durable interrupted-reclaim recovery, live-owner and surviving-process-group refusals, concurrent reclaimer serialization, and serialization of consume against reconcile and retire.
The same 64 controls were rerun directly at candidate `0462f4a2947847f98415935b7fbcd317587306f2`; the suite printed each positive control, ended with `FM_TEST_CONTRACT suite=fm-publication-seam.test.sh status=pass`, and exited 0.
The subsequent CI run `33030583955` timed out portable serial shard 2 after `fm-watch-triage.test.sh` passed and the unchanged `fm-remote-job.test.sh` began, so the aggregate correctly reported the missing shard artifact as could-not-observe; the immediately preceding run `33029663411` completed that same test in 38,318 ms, and a direct rerun at `1b00d850194057c601249982d8c5dc0495f7c20f` printed all 19 controls and `ALL TESTS PASSED` in 39 seconds.
The publication-seam run includes the canonical-command positive control paired with the force-axis refusal, and the dead-predicate run includes the quoted trap-handler positive and non-trap negative controls.
This evidence does not replace the independent review required before landing.

```
bin/fm-test-run.sh tests/fm-publication-seam.test.sh
bin/fm-test-run.sh tests/fm-attest.test.sh
bin/fm-test-run.sh tests/fm-landing-authorization.test.sh
bin/fm-dead-predicate-check.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Judge `bin/fm-lint.sh` by what it PRINTS, not by the exit status of whatever ran it.
A backgrounded wrapper around it reported success while lint was failing on a `# shellcheck disable` directive that an inserted function had displaced from the function it belonged to, and only the foreground run showed it.

## A probe must not mint

`prepare` is side-effect-free only on the paths where it REFUSES.
A probe written to expect a refusal therefore stops being a probe on the day that refusal stops firing: it mints instead, and leaves a live one-use authority behind at exactly the moment nobody wanted one.

That is not hypothetical.
Running this guard's own pinned probe verbatim against the operational home, at a moment when the governing hold record had not yet been provisioned, granted a real authority for a stale head rather than refusing.
`--dry-run` exists because of it: it compiles and prints the same verdict, names the same deterministic id, and writes nothing.

The corrected form, and the one every probe of this guard must use:

```
bin/fm-publication-guard.sh prepare --dry-run --repo <dir> --remote <name|url> \
  --venue <host/owner/repo> --ref <refs/...> --head <sha> --expected-tip <sha|-> \
  --item <work-id>
```

Any probe, any check-path, and any command that only wants the verdict must use `prepare --dry-run`.
Bare `prepare` is the granting path, and a probe written against it is only side-effect-free by accident of which branch it happens to take.

## Retiring an authority that must never be spent

An authority that should never have existed is still evidence that it did, so the repair for a mistaken grant is a RECORDED retirement rather than a removal - and never a hand edit, which leaves no trace that anything was ever different.

`retire` transitions `granted` to `void` and nothing else.
The record is amended rather than rebuilt, so everything it already said about what was authorized survives verbatim and a timestamped reason is added beside it.
Repeating the command reports the record and writes nothing, so a retirement cannot accumulate history.

It refuses the two states that are not unused authorities.
A `spent` record says an act happened; an unobserved one says an act may have.
Replacing either with `void` would turn evidence into a tidier claim than the evidence supports, and the second belongs to `reconcile`, which settles it from an observation rather than assuming it.

## Enrolment in the dead-predicate control

Both new files carry `# fail-closed-predicates: enforced`, so every predicate in them must have a call site or say in writing why it does not.
The repository run went from `enrolled=4 alive=85 could_not_observe=0` to `enrolled=6 alive=123 could_not_observe=0`.

The 2026-08-27 UTC pass at candidate `ff80599ab64cc0955405b8b4965b69b3876d428d` reads `enrolled=6 scanned=124 unchecked=242 alive=151 could_not_observe=0 marked=0`.

That enrolment is load-bearing rather than decorative, and it caught three real defects across this work.
The third was this pass's own: generalising the authority identity over its effect left four `fm_auth_publication_*` wrappers with no call site, and they were deleted rather than marked `unused-by-design`, because a wrapper nobody calls is exactly what the control exists to refuse.
`fm_auth_effect_valid` was defined and never consulted, which is the exact shape the control exists for - a guard that reads as present because the file defines it.
Separately, a helper named `rec` collided with a common local variable name in six other files, which made those files unreadable to the control and turned 56 resolved predicates into could-not-observe across libraries this change never touched.
The second is worth keeping in mind when naming anything in an enrolled file: a three-letter helper name is not a local decision.

Re-run the red calibration after any change to the resolution order in `fm_pub_seam_resolve`, to the spend sequence in `cmd_consume`, or to the publish path of `bin/fm-attest.sh`.
A control whose red no longer names its own defect is a control that has stopped measuring what this record says it measures.
