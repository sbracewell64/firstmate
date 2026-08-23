# Verification: the candidate-publication effect and identity guard

Audience: maintainer-verification.
Subject: `bin/fm-publication-guard.sh` and `bin/fm-publication-seam-lib.sh`, the publication effect subject added to `bin/fm-landing-authorization-lib.sh`, and the seam that consumes them inside `bin/fm-attest.sh`.
Regression owners: `tests/fm-publication-seam.test.sh` for the guard and its controls, `tests/fm-attest.test.sh` for the wiring into the real publication path.

## What is claimed

A candidate reaches the outside world when it is PUSHED, not when it is merged.
This mechanism asks whether that push is permitted before the remote moves, binds the answer to one exact subject, and exhausts the answer by using it.

Six properties, and one control without which none of them means anything:

1. A governed publication is refused before the remote moves whenever an active hold, an unmet must-close ruling, a placeholder or unmapped identity, a second actionable candidate for the same semantic work, a retained predecessor ref, a stale ruling or policy generation, or a remote tip other than the one planned against applies.
2. Permission is re-compiled at the moment of use, so an authority granted while eligible refuses once a newer hold, a revoked ruling or a bumped generation arrives.
3. A remote that moved under a granted authority refuses without overwriting what moved it.
4. An authority is spent exactly once, and a replay refuses and publishes nothing.
5. An authority consumed before its effect is durably `consumed-without-confirmed-effect`, is never resurrected, and recovery mints a fresh authority for the same unchanged subject rather than reusing it.
6. A remote already equal to the head is a typed `NO_EFFECT_ALREADY_EQUAL` result that consumes no authority.
7. Non-vacuity: a governed candidate with a clean identity, no hold, one semantic owner, fresh generations and the exact remote tip publishes exactly once.

Property 7 is not a courtesy.
Properties 1 through 6 all pass against a guard that refuses everything, so without 7 the suite would be green and worthless.

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

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-publication-seam.test.sh
bin/fm-test-run.sh tests/fm-attest.test.sh
bin/fm-dead-predicate-check.sh
bin/fm-lint.sh
```

## A probe must not mint

`prepare` is side-effect-free only on the paths where it REFUSES.
A probe written to expect a refusal therefore stops being a probe on the day that refusal stops firing: it mints instead, and leaves a live one-use authority behind at exactly the moment nobody wanted one.

That is not hypothetical.
Running this guard's own pinned probe verbatim against the operational home, at a moment when the governing hold record had not yet been provisioned, granted a real authority for a stale head rather than refusing.
`--dry-run` exists because of it: it compiles and prints the same verdict, names the same deterministic id, and writes nothing.

Any probe, any check-path, and any command that only wants the verdict must use it.

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

That enrolment is load-bearing rather than decorative, and it caught two real defects during this work.
`fm_auth_effect_valid` was defined and never consulted, which is the exact shape the control exists for - a guard that reads as present because the file defines it.
Separately, a helper named `rec` collided with a common local variable name in six other files, which made those files unreadable to the control and turned 56 resolved predicates into could-not-observe across libraries this change never touched.
The second is worth keeping in mind when naming anything in an enrolled file: a three-letter helper name is not a local decision.

Re-run the red calibration after any change to the resolution order in `fm_pub_seam_resolve`, to the spend sequence in `cmd_consume`, or to the publish path of `bin/fm-attest.sh`.
A control whose red no longer names its own defect is a control that has stopped measuring what this record says it measures.
