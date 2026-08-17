# Recurrence and mutation proof

Maintainer-verification record for [`bin/fm-review-mutation.sh`](../../bin/fm-review-mutation.sh), the proof owner that answers whether a named target assertion ran and what it concluded.
The guarantee it records is narrow and exact: no label, marker, or caller-supplied name can establish that a named assertion executed.
Watched-red evidence is recorded only when it describes the current measured subject.

The script's own header owns the law, the fold, the twenty-two bound dimensions, and the mechanics.
This file records only what was measured, and when.

## Why watched red is the acceptance condition here

The predecessor this replaces accepted a proxy in its own implementation.
It ran an entire suite and treated an exact textual `ok - <case>` / `not ok - <case>: <failure>` line as proof that the named assertion had executed, and its mutation catalogue routed many distinct cases through that one broad-suite wrapper - including cases whose stated purpose was proving that labels and proxies cannot establish execution.
Fifteen correction rounds did not fix it, which is why it was retired rather than repaired a sixteenth time.

A control that has only ever been seen green is indistinguishable from that defect.
Every control in [`tests/fm-review-mutation.test.sh`](../../tests/fm-review-mutation.test.sh) is therefore run against every single-defect build, individually, and the unmodified suite is trusted passing only after that.
The defect builds are materialized into a temporary directory and removed; no tracked file is ever mutated to produce them.
The catalogue that defines them is tracked, in [`tests/review-mutation-red-matrix.py`](../../tests/review-mutation-red-matrix.py), so every row below is replayable by someone who did not run it.

The controls are run one at a time rather than as a suite, because the suite stops at its first failing control.
A suite-at-a-time measurement reports each defect reddening exactly one control and says nothing about the other thirty, which is a coverage claim resting on an observation that was never made.
Running each control separately produces a complete matrix, including the row that matters most: **controls no defect reddened**, which is reported rather than left to be inferred from a table that happens to look full.

### What this measurement caught in its own controls

Four times, and each time the finding was the point rather than an obstacle.

A control was found inadequate rather than recorded as passing.
The source-custody control originally observed the source only after the run finished, so a build that mutated the source in place and restored it in a `finally` satisfied every check it made.
That is the shape the standing law names - a control must never mutate the artifact it protects, and restore-in-finally is not sufficient because a concurrent reader sees the mutated state.
It now samples the source **from inside the probe**, the one thing running at the moment any mutation would be live, once per execution.
The build it could not see is `D12`, and it is red in the matrix.

Five controls were then found to have no red witness at all, once each control was run separately rather than as a suite.
Builds `D19` through `D23` were written for exactly those five.

A sixth was found at the final measurement: the control asserting that a record's named path is bound to where its mutants actually differ.
That binding lives in two places, and no single defect defeated both, so the control had never been seen failing.
`D29` removes both, because removing one leaves the other standing and reddens nothing.

The inventory drift control was also reporting its own success before running its checks, so that it could count its own identity.
It now counts the suite's declared controls without executing them and reports only after its checks.
A full run separately binds the declared controls to the identities that actually executed.

## What the proof owner establishes, and what it does not

It establishes that the probe's terminal verdict is controlled by the named target's exact bytes in both directions - bad under the falsifying substitution, good under the satisfying one - and what verdict the probe reached on the unmutated candidate.

It does not establish **why** those bytes control the verdict.
Terminal states cannot separate "the assertion evaluated these bytes" from "these bytes were load-bearing for some other reason", such as a substitution that makes the file fail to parse.
The satisfying direction exists to shrink that gap: a substitution that merely breaks the file breaks it in both directions, and a satisfied run that does not pass reaches could-not-observe rather than a verdict.
The residue is not argued away - every record carries it under `does_not_establish`, together with all three exits, so a reader can judge it.

It also does not establish that the caller's words about a case are true.
Caller declarations are recorded under `declared`, quarantined from `dimensions`, marked `evidential: false`, and never read to reach a verdict.

## Cost, stated so it is discoverable rather than surprising

Each case performs four `--no-local` clones of the candidate repository: one disposable clone the mutation lives in, and one per execution inside [`bin/fm-review-exec.sh`](../../bin/fm-review-exec.sh).
`--no-local` copies objects rather than hardlinking them, which is the property that makes the clones isolated and is measured directly by link count.
That cost is deliberate and is the reason this is a deliberately invoked proof rather than a check in a delivery path.
The evidence a record rests on stays under its output directory, because `result` re-derives from it and trusts nothing stored; removing it makes the record could-not-observe rather than stale-passing.

## Environment

Measured 2026-08-17 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, `jq` 1.8.1, GNU bash 5.3.9, and Python 3.14, with the branch based on `c5c7dff1`.

## Commands

The green pass, which must show every control passing:

```
bash tests/fm-review-mutation.test.sh
```

The whole matrix, which builds every catalogued defect and runs every control against each one:

```
tests/review-mutation-red-matrix.py matrix --json <out.json>
```

It exits non-zero when any control has no red witness, so a measurement that leaves a gap cannot be mistaken for one that did not.
A single entry, for checking one row of the table below:

```
tests/review-mutation-red-matrix.py replay <defect> <control>
```

Both drive the suite through four seams, each read only by the test file and each defaulting to the tracked artifact, so they exist for this measurement and change nothing in production:

| Seam | Overrides | Why it has to exist separately |
| --- | --- | --- |
| `FM_REVIEW_MUTATION_BIN` | the proof owner | the subject of most defects |
| `FM_VERIFY_BIN` | the wrapper that transports its result | `bin/fm-verify.sh` resolves the proof owner from its OWN directory, so overriding only the binary would exercise the shipped adapter against the shipped proof owner and the adapter's own defect would go unwitnessed |
| `FM_REVIEW_MUTATION_RECORD` | this record | the drift control's subject is the RECORD, not the binary, so no defect build could otherwise reach it - it would be the one control that could never be watched red |
| `FM_REVIEW_MUTATION_ONLY` | which control runs | refuses a name not in `FM_CONTROLS` rather than running nothing, because selecting a control that does not exist would otherwise report a clean run having observed nothing at all |

Each defect build was confirmed to differ from the tracked script and to parse before it was run.
That confirmation matters because a build that fails to parse fails every control unconditionally, corroborating whatever it was pointed at while measuring nothing.

## Observed red and green

### Inventory claim

The suite executes 31 controls, and the current measured-file inventory is:

```
inventory_control_count: 31
inventory_sha256: bin/fm-review-mutation.sh fcc9998483e554db47311a3b54bbcc4d219f79ffbdc472a1019654e78d0ed36e
inventory_sha256: bin/fm-verify.sh 5682f35bbf89cda3bd15de96a0df825317e5698d4956122bd0c7fb4627dd8318
inventory_sha256: tests/fm-review-mutation.test.sh 8cc6ccbf05b0e2aded4f60801d785e1c333364a2790a6aa58b880cdba354c9b0
inventory_sha256: tests/review-mutation-red-matrix.py 876a0991d51f556999886482d5abb405488ff9d1d671fdccd947c567dcc08d48
```

This is an inventory claim only: it says these files and this control count agree with the
suite that runs today.
`tests/fm-review-mutation.test.sh` enforces it and fails when they drift, counting from the suite's declared control array rather than from a second number.
The full-run branch separately enforces that every declared test identity executed.

**Passing this inventory claim is NOT evidence for the measurement claim below.** A green
inventory sitting on top of unmeasured rows is the collapse this separation exists to
prevent, so the two are stated apart and never folded together.

### Measurement claim

Measured at `99f700f0` after the inventory control was isolated to execute only itself.
The green pass ran all 31 controls against the shipped files and exited 0.
The matrix then measured 29 single-defect builds, running each control separately against each build.
Every control has at least one red witness, and no control is left unwitnessed.

The inventory digests above were identical before and after the matrix, so the complete measurement describes one build rather than a moving subject.
The inventory claim above remains separate from this measurement claim and is not evidence for it.

Each defect build's full SHA-256 is recorded below.
The tracked catalogue owns each defect's executable definition and supports replay with `tests/review-mutation-red-matrix.py replay <defect> <control>`.

| Build | SHA-256 |
| --- | --- |
| D01 | `1f6a9d95b9861e80c0a8b0ec5d9a75cb9a0855d920495039e563a182a7522f68` |
| D02 | `1dc2477f2580f6f38f4e67144f0de1ec8b2193f8ac1edbac51116f860df5f82e` |
| D03 | `501ed119c1b8459b7efac5f3fd02664593bfaf35c744185ca0073e9952f3db51` |
| D04 | `5af432056a3c40504724fe729db3ce29242385d71237b449061e78bac222f68c` |
| D05 | `0c1b84f33577e6fbb15ad667f7bd1b259494d7029e780aa405abc129985103d5` |
| D06 | `bbc291e2f02bb39a63834fb51a2d9b99cae2ed0aa4c9019693b235f485a55607` |
| D07 | `3cbbee29509b7a29f70ecae643ca255670c41dc4b19f736f7b321e78493758ab` |
| D08 | `70f37a3863deeddccd998adbc697dd7e2beeff4740a821de137472391a419aa2` |
| D09 | `d21bcd4ba49c1341c6bcdda0cc54c056dd237e08071bf780a671360743a0327a` |
| D10 | `fbb5381d2f19921cea7e18c8c98fd700d3139af36dba4457d95459a655fd3b43` |
| D11 | `b453723a28a00acc11ba62aed3ad85f3e2603b2498dfda49f605e6af2bb2bba4` |
| D12 | `94ef8a59b5eb1b5506f180e460d1184a1ca1538e5ec255979c32f330dee9fddf` |
| D13 | `6b731228d8636ca932cb5dcefb37aa844029b25f517a6cbe01f559bfbc751e88` |
| D14 | `b505dd35be19cc4b7702bf4bf5dbead59b4c9554d7de98ff2b53c1e6f2305842` |
| D15 | `6ad404671108f4330eb23b42a8d62edfc8b6f3e209c13f404efb433761272524` |
| D16 | `28b4a806fdd9c80ff5af31ad2885370f6f9a1180a60bbc2c5d8456db593e2cd7` |
| D17 | `5b34d52f7e7e1d386a8473cab67da07c484af568d02fd3dc8a1906a537265818` |
| D18 | `2d5c239a93209a46b88e8696c8bbe91ba9600d096d8a7663a867f7ccedbe8d90` |
| D19 | `d782bca21f9774f32201f18f98837758cc61b93fa903467f86e5db6464027c68` |
| D20 | `0dac107606a6a0e137d93c401398ccdd98eb2589e072094941936d7b219e095d` |
| D21 | `ff8572fd3d7e03e1da2e340ff2963c1496c5e45e7151f961e6a7363a465e6baf` |
| D22 | `045573f433f1dbb070a6246c1d6297a26c6aae1d2c8eb6731b5e97f722c83823` |
| D23 | `cb776f895e77e1e846983deb568aa0432787fb57f35cbd98c8788256113fc101` |
| D24 | `f4ebd93d3bfed8cbbcc0d2cf7b7c5a5aaab06d9a501a7d5e6236aa0e91ac6ad7` |
| D25 | `8803b7a5243f883855609ddf3a348a8ec03da7a0cbe4d4e49f4c10816e5fc7f3` |
| D26 | `8190a87a0418bf1151c424d2206823fd0240d1e642d262749720afda34f470a1` |
| D27 | `f467886bc77b1632d229d614a94817bbb0df39bed14374efaf15d4c2ac68ab3c` |
| D28 | `cd8ced9494291b1e0883311de45f24254bacf6939718e67dbf41f94a853870de` |
| D29 | `bdbe221a9f688c478f793b7f2305aa2ca641456d269d51638bdab71b2444ecaf` |

Each matrix row records the control identity, every defect build that reddened it, one observed failing line, and the measured head.
The head is recorded per row so a single global relabelling cannot silently re-attribute the entire matrix.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| `test_a_matching_success_line_cannot_establish_that_the_target_ran` | D01 D05 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `99f700f0` |
| `test_the_proof_owners_own_success_literal_cannot_reach_a_verdict` | D05 D19 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `99f700f0` |
| `test_a_target_that_executed_and_passed_is_a_pass` | D01 D05 | `the basis must say the target executed and concluded pass` | `99f700f0` |
| `test_a_target_that_executed_and_failed_is_a_fail` | D05 D20 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `99f700f0` |
| `test_an_unattributable_substitution_is_could_not_observe` | D01 D02 D05 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `99f700f0` |
| `test_a_target_occurring_more_than_once_is_refused` | D03 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `99f700f0` |
| `test_a_target_occurring_zero_times_is_refused` | D21 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `99f700f0` |
| `test_overlapping_occurrences_are_counted_separately` | D03 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `99f700f0` |
| `test_the_identity_substitution_reproduces_the_candidate_tree` | D05 | `the identity substitution must reproduce the candidate tree exactly` | `99f700f0` |
| `test_a_substitution_identical_to_the_target_is_refused` | D22 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `99f700f0` |
| `test_the_source_is_never_mutated` | D12 | `the source file must be unmutated at every moment an execution was live` | `99f700f0` |
| `test_the_disposable_clone_shares_no_object_storage` | D04 | `the disposable clone must share no object storage with the source` | `99f700f0` |
| `test_refuses_a_primary_checkout_as_its_source` | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `99f700f0` |
| `test_refuses_to_overwrite_an_existing_record` | D07 | `a second generation must not be written over the first: expected exit 2, got 0` | `99f700f0` |
| `test_a_record_whose_mutants_are_gone_is_could_not_observe` | D05 | `the case must pass before the evidence is removed` | `99f700f0` |
| `test_an_edited_record_cannot_be_read_into_a_verdict` | D01 D05 D06 D23 | `the label case must fail before editing` | `99f700f0` |
| `test_an_execution_from_the_wrong_variant_is_could_not_observe` | D24 | `an execution for another mutation must not enter the fold` | `99f700f0` |
| `test_preserved_mutation_bytes_are_rederived` | D25 D29 | `changed preserved bytes must invalidate the claimed mutant` | `99f700f0` |
| `test_a_missing_dimension_outranks_a_clean_fold` | D10 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `99f700f0` |
| `test_a_record_pointing_at_another_path_is_could_not_observe` | D29 | `a record whose named path is not where the mutants differ must not pass` | `99f700f0` |
| `test_a_caller_declaration_cannot_change_the_verdict` | D01 D05 D11 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `99f700f0` |
| `test_the_probe_argv_is_recorded_exactly` | D15 | `probe_argv must record every argument, including an empty one` | `99f700f0` |
| `test_one_failing_case_makes_the_catalogue_fail` | D01 D05 D09 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `99f700f0` |
| `test_a_failing_case_outranks_an_unobservable_one` | D01 D02 D05 D09 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `99f700f0` |
| `test_an_unobservable_case_outranks_a_passing_one` | D01 D02 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `99f700f0` |
| `test_an_empty_catalogue_is_could_not_observe` | D13 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `99f700f0` |
| `test_a_catalogue_with_duplicate_identities_is_refused` | D14 | `the refusal must name the collision (missing: 'duplicate case identities')` | `99f700f0` |
| `test_fm_verify_transports_the_result` | D01 D05 D18 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `99f700f0` |
| `test_a_symlinked_target_path_is_refused` | D16 | `the refusal must name what it saw (missing: 'not a regular file')` | `99f700f0` |
| `test_a_missing_execution_substrate_is_could_not_observe` | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `99f700f0` |
| `test_verification_record_inventory_matches_executed_controls` | D26 D27 D28 | `the documented control count (1) must equal the suite's declared control count (31)` | `99f700f0` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
