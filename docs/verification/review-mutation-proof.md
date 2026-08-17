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
An interim correction counted the identities that had already passed plus the inventory control itself and required that control to be last.
Independent review found that selecting the inventory control ran every control, so 26 of the 29 defect builds credited as its red witnesses had actually failed in another control and only three had exercised the inventory check.
Reading the recorded failure text for every matrix row established that this false attribution was confined to the inventory-control row, because every other selection ran exactly its named control.
The ruling superseded both the executed-identity count and the last-control assertion: the inventory control now counts the suite's declared controls without executing them and reports only after its checks, while a full run separately binds declared controls to the identities that actually executed.
Position is irrelevant to a declared count, so retaining a last-control assertion would guard no property.
The resulting rule is that the named target and the observed failing control must match; a neighbouring or broader red is not evidence for the target.

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

Measured at `60a2a936` after the inventory control was isolated to execute only itself.
The green pass ran all 31 controls against the shipped files and exited 0.
The matrix then measured 29 single-defect builds, running each control separately against each build.
Every control has at least one red witness, and no control is left unwitnessed.

The inventory digests above were identical before and after the matrix, so the complete measurement describes one build rather than a moving subject.
The inventory claim above remains separate from this measurement claim and is not evidence for it.

Each defect build's full SHA-256 is recorded below.
The tracked catalogue owns each defect's executable definition and supports replay with `tests/review-mutation-red-matrix.py replay <defect> <control>`.

| Build | SHA-256 |
| --- | --- |
| D01 | `b483afe133186cca6beebcea92e8964587901d45e523ef30894712d0ec58e69e` |
| D02 | `9f49df732494707d71b427045e0fee95637651abceca9fe3e4491d9df5078a7c` |
| D03 | `c29728286fb20966d2216f0a7a8a2d257b33d2ff003c6332662a324f0dbde8bc` |
| D04 | `e116448233c7f6f09b1e150d99dd431500ace2da3386b90f8c816f9d9a6192c7` |
| D05 | `51500f20898b2f01d756e9bfaa2226996e4cd43c535dca95dfabb98d2519ab3a` |
| D06 | `6a36f0b1ad1785e6e929005a2de416b4411f9263ecaf449e1c09bc53c3ec2e03` |
| D07 | `c371d3883c8bb4fd40c7a0f0a59674992f5bed6825c5a086423c35d280677b7c` |
| D08 | `664a7f4fd8e8fcd5f5d001f670cd88385b4cdbfdaf3f994db9ab8b0634418767` |
| D09 | `edf8ee7cb92a93f58abfeda697ad859d673cb302dedf957e066e373e3d9546c5` |
| D10 | `c1e259a7067655ab9d7c22e9fa683e3284c89f2ad33107fc2b5381cba239cff1` |
| D11 | `eaf0dcbe367edeb92c834a6077292d44ca6d4264d245a394d18d7cfd5a94dc5e` |
| D12 | `2622a307cb25d71a8afcc51a290bcc9f4eb6415ae49b17530ff6304b29dc1bd4` |
| D13 | `e980780e3b7f9aa44172bcf7ddcc2ac202b4ed4c32eb81709de2f0cd03c9052e` |
| D14 | `245dc6fd13e779ba51b5a640cc825ace7dbea0197e4c784cff557dd5f4e7906c` |
| D15 | `c5ee9fd0d61c26ba2598ba504453d78e58eae0dba68f7ab1aedcdb49ce2e6b76` |
| D16 | `84a0c75bf9a93bf4558b52f0047ed5a099c8509dc8859cf061b8a90a6ec865a7` |
| D17 | `3f99bd1194673929e29abcd89dd4d4e0eb6d46d5699752375ec5c3461e44243a` |
| D18 | `d6125d374d2fccecd22a300e188530b568c0353ecc3d00735a9c7d4ebbeb57e8` |
| D19 | `86149ea54637d47a5d55b8195a8414210a810bf588432afb31c23ffdce92ac1e` |
| D20 | `8d40fd1ec182b74d65fe15089c364cd2cfd67ecf9a878d742b6ff9e1943614f1` |
| D21 | `3b46862104d11461d7587a7fe694db63befce02f7d5fae8a0be9569f28692a4c` |
| D22 | `7d6bdd51ee9c8ba8d0842fd5a7928abe446f45012b258bccb8a1b671dafff26d` |
| D23 | `aa886e03f9b647e0b4503c7044842e2edb86b8b9881880e74dc3bcbbd9123728` |
| D24 | `6f2cbf215ef08c38e7466324b1ebb4390367cddb4fd72a97ac25eb98efd75d1e` |
| D25 | `68ffb1f1d7f77b73f530b36f3caf08a8d17c6a1721997e3dcaf706f7b0d3afda` |
| D26 | `cdc9ab1ab35e7dd71114450a9a1d8a20393cf5cc39029f6d786c509bb017d280` |
| D27 | `d193ef51e7b379f9fc3041ba08ee59601ba5fc976a2dce858945944cd59ef74d` |
| D28 | `5d23a18e0583d1bdc415d400f494b4843ac1a345593cb02e74e9066805b1dd64` |
| D29 | `f9fb335cd149bbefad7c356308689b39a39aba741d2f4ca1c34936b0b90c7515` |

Each matrix row records the control identity, every defect build that reddened it, one observed failing line, and the measured head.
The head is recorded per row so a single global relabelling cannot silently re-attribute the entire matrix.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| `test_a_matching_success_line_cannot_establish_that_the_target_ran` | D01 D05 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `60a2a936` |
| `test_the_proof_owners_own_success_literal_cannot_reach_a_verdict` | D05 D19 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `60a2a936` |
| `test_a_target_that_executed_and_passed_is_a_pass` | D01 D05 | `the basis must say the target executed and concluded pass` | `60a2a936` |
| `test_a_target_that_executed_and_failed_is_a_fail` | D05 D20 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `60a2a936` |
| `test_an_unattributable_substitution_is_could_not_observe` | D01 D02 D05 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `60a2a936` |
| `test_a_target_occurring_more_than_once_is_refused` | D03 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `60a2a936` |
| `test_a_target_occurring_zero_times_is_refused` | D21 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `60a2a936` |
| `test_overlapping_occurrences_are_counted_separately` | D03 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `60a2a936` |
| `test_the_identity_substitution_reproduces_the_candidate_tree` | D05 | `the identity substitution must reproduce the candidate tree exactly` | `60a2a936` |
| `test_a_substitution_identical_to_the_target_is_refused` | D22 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `60a2a936` |
| `test_the_source_is_never_mutated` | D12 | `the source file must be unmutated at every moment an execution was live` | `60a2a936` |
| `test_the_disposable_clone_shares_no_object_storage` | D04 | `the disposable clone must share no object storage with the source` | `60a2a936` |
| `test_refuses_a_primary_checkout_as_its_source` | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `60a2a936` |
| `test_refuses_to_overwrite_an_existing_record` | D07 | `a second generation must not be written over the first: expected exit 2, got 0` | `60a2a936` |
| `test_a_record_whose_mutants_are_gone_is_could_not_observe` | D05 | `the case must pass before the evidence is removed` | `60a2a936` |
| `test_an_edited_record_cannot_be_read_into_a_verdict` | D01 D05 D06 D23 | `the label case must fail before editing` | `60a2a936` |
| `test_an_execution_from_the_wrong_variant_is_could_not_observe` | D24 | `an execution for another mutation must not enter the fold` | `60a2a936` |
| `test_preserved_mutation_bytes_are_rederived` | D25 D29 | `changed preserved bytes must invalidate the claimed mutant` | `60a2a936` |
| `test_a_missing_dimension_outranks_a_clean_fold` | D10 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `60a2a936` |
| `test_a_record_pointing_at_another_path_is_could_not_observe` | D29 | `a record whose named path is not where the mutants differ must not pass` | `60a2a936` |
| `test_a_caller_declaration_cannot_change_the_verdict` | D01 D05 D11 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `60a2a936` |
| `test_the_probe_argv_is_recorded_exactly` | D15 | `probe_argv must record every argument, including an empty one` | `60a2a936` |
| `test_one_failing_case_makes_the_catalogue_fail` | D01 D05 D09 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `60a2a936` |
| `test_a_failing_case_outranks_an_unobservable_one` | D01 D02 D05 D09 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `60a2a936` |
| `test_an_unobservable_case_outranks_a_passing_one` | D01 D02 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `60a2a936` |
| `test_an_empty_catalogue_is_could_not_observe` | D13 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `60a2a936` |
| `test_a_catalogue_with_duplicate_identities_is_refused` | D14 | `the refusal must name the collision (missing: 'duplicate case identities')` | `60a2a936` |
| `test_fm_verify_transports_the_result` | D01 D05 D18 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `60a2a936` |
| `test_a_symlinked_target_path_is_refused` | D16 | `the refusal must name what it saw (missing: 'not a regular file')` | `60a2a936` |
| `test_a_missing_execution_substrate_is_could_not_observe` | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `60a2a936` |
| `test_verification_record_inventory_matches_executed_controls` | D26 D27 D28 | `the documented control count (1) must equal the suite's declared control count (31)` | `60a2a936` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
