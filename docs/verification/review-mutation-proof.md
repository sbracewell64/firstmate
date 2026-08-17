# Recurrence and mutation proof

Maintainer-verification record for [`bin/fm-review-mutation.sh`](../../bin/fm-review-mutation.sh), the proof owner that answers whether a named target assertion ran and what it concluded.
The guarantee it records is narrow and exact: no label, marker, or caller-supplied name can establish that a named assertion executed.
The measured table below records observed watched-red evidence.

The script's own header owns the law, the fold, the twenty-two bound dimensions, and the mechanics.
This file records only what was measured, and when.

## Why watched red is the acceptance condition here

The predecessor this replaces accepted a proxy in its own implementation.
It ran an entire suite and treated an exact textual `ok - <case>` / `not ok - <case>: <failure>` line as proof that the named assertion had executed, and its mutation catalogue routed many distinct cases through that one broad-suite wrapper - including cases whose stated purpose was proving that labels and proxies cannot establish execution.
Fifteen correction rounds did not fix it, which is why it was retired rather than repaired a sixteenth time.

A control that has only ever been seen green is indistinguishable from that defect.
Every control then present in [`tests/fm-review-mutation.test.sh`](../../tests/fm-review-mutation.test.sh) was therefore run against every single-defect build, individually, and the full unmodified suite was trusted passing only after that.
The defect builds are scratch copies outside the repository; no tracked source was mutated to produce them.

The controls are run one at a time rather than as a suite, because the suite stops at its first failing control.
A suite-at-a-time measurement would report each defect reddening exactly one control and would say nothing about the other twenty-seven, which is a coverage claim resting on an observation that was never made.
Running each control separately produces the complete matrix below, including the row that matters most: **controls no defect reddened**, which is reported rather than left to be inferred from a table that happens to look full.

One control was found to be inadequate by exactly this measurement and was repaired rather than recorded as passing.
The source-custody control originally observed the source only after the run finished, so a build that mutated the source in place and restored it in a `finally` satisfied every check it made.
That is the shape the standing law names - a control must never mutate the artifact it protects, and restore-in-finally is not sufficient because a concurrent reader sees the mutated state.
The control now samples the source **from inside the probe**, which is the one thing running at the moment any mutation would be live, once per execution.
The defect build that went unwitnessed is `D12` in the table below, and it is red there.

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

Measured 2026-08-17 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, `jq` 1.8.1, and GNU bash 5.3.9, with the branch based on `c5c7dff1`.

## Commands

The green pass, which must show every control passing:

```
bash tests/fm-review-mutation.test.sh
```

One red run per control per defect build, where `<variant>` is a copy of `bin/fm-review-mutation.sh` carrying exactly one defect, `<wrapper>` is the matching copy of `bin/fm-verify.sh`, and `<control>` is one name from the suite's declared `FM_CONTROLS`:

```
FM_REVIEW_MUTATION_BIN=<variant> FM_VERIFY_BIN=<wrapper> \
  FM_REVIEW_MUTATION_ONLY=<control> bash tests/fm-review-mutation.test.sh
```

All three seams are read only by the test file and default to the tracked scripts and the whole control set, so they exist for this measurement and change nothing in production.

`FM_VERIFY_BIN` is a separate seam because `bin/fm-verify.sh` resolves the proof owner from its own directory: overriding only the binary would still exercise the shipped adapter against the shipped proof owner, so the adapter's own defect would go unwitnessed.
`FM_REVIEW_MUTATION_ONLY` refuses a name that is not in `FM_CONTROLS` rather than running nothing, because a measurement that selects a control that does not exist would otherwise report a clean run having observed nothing at all.

Each defect build was confirmed to differ from the tracked script and to parse before it was run.
That confirmation matters because a build that fails to parse fails every control unconditionally, corroborating whatever it was pointed at while measuring nothing.

## Observed red and green

### Coverage not yet measured at this head

The matrix below was measured against the bytes committed at `fab6b69f` and covers exactly the controls that existed there.
The suite's `FM_CONTROLS` array now contains three controls with no matrix row: `test_an_execution_from_the_wrong_variant_is_could_not_observe`, `test_preserved_mutation_bytes_are_rederived`, and `test_verification_record_inventory_matches_executed_controls`.
Each of those controls is GREEN in the suite but has NOT been watched red.
Each therefore has watched-red status COULD-NOT-OBSERVE, explicitly not an omission, not a pass, and not a claim that no defect would redden it.
This record therefore does NOT currently claim complete watched-red coverage.

### Inventory claim

The suite executes 31 controls, and the current measured-file inventory is:

```
inventory_control_count: 31
inventory_sha256: bin/fm-review-mutation.sh fcc9998483e554db47311a3b54bbcc4d219f79ffbdc472a1019654e78d0ed36e
inventory_sha256: bin/fm-verify.sh 5682f35bbf89cda3bd15de96a0df825317e5698d4956122bd0c7fb4627dd8318
inventory_sha256: tests/fm-review-mutation.test.sh 94613e6c6215177001d44079500680fa1377afea8c00c1d594ba3bee69afa879
inventory_sha256: tests/review-mutation-red-matrix.py d974973bb05d9e870b094115cc48ed3d684b88a380f3fffaf6f0ab4cbbca5387
```

This is an inventory claim only: these files and control count agree with the suite that passes on the current bytes.
Passing this inventory claim is NOT evidence for the separate measurement claim that specific matrix rows were observed red at the head named in each row, because a green inventory sitting on top of unmeasured rows is the collapse this separation exists to prevent.

### Measurement claim

The green pass measured at `fab6b69f` ran all twenty-eight controls then present against the shipped script and exited 0.
Twenty-three single-defect builds were then measured, each control run separately against each build, and every one of those twenty-eight controls had at least one red witness.

The measurement pinned the digests of `bin/fm-review-mutation.sh`, `bin/fm-verify.sh`, and `tests/fm-review-mutation.test.sh` before and after, and they were identical, so all of it describes one build rather than a moving one.

Five controls had no red witness when the first eighteen builds were measured.
They are listed here because that is the finding the measurement exists to produce - a table that merely looks full is the same claim the retired substrate made.
Builds `D19` through `D23` were written for exactly those five, and the orphan list is now empty.

Several defects redden more than one control, which is expected and is why the matrix is reported rather than a one-to-one mapping.
`D01`, the retired defect restored, reddens nine.

### The defect builds

| Build | Defect injected |
| --- | --- |
| D01 | the verdict is read from an `ok - ` line in the probe's captured output - the retired defect, restored |
| D02 | control is established by the falsifying direction alone |
| D03 | the occurrence guard accepts more than one site and uses the first |
| D04 | the disposable clone is made locally and its isolation is assumed rather than measured |
| D05 | the identity substitution perturbs the baseline tree, and nothing requires it not to |
| D06 | execution results and mutation facts are read from the record instead of re-proven |
| D07 | an occupied output directory is cleared and reused |
| D08 | the primary-checkout refusal is dropped |
| D09 | the catalogue fold reports a gap ahead of a failure |
| D10 | an unobserved dimension no longer outranks the fold |
| D11 | a caller declaration is read and reaches the verdict |
| D12 | the source is mutated in place and restored in a `finally` |
| D13 | an empty catalogue is folded as clean |
| D14 | duplicate case identities are accepted |
| D15 | the probe argv is recorded as a space-joined rendering of itself |
| D16 | the regular-file guard on the target path is dropped |
| D17 | with no execution substrate, the build reports PASS itself instead of refusing |
| D18 | `bin/fm-verify.sh`'s adapter narrows any transported result to PASS |
| D19 | a FAILURE literal in the probe's captured output is read as a failure |
| D20 | the unmutated baseline is ignored once control is established |
| D21 | a target that is not present is spliced in at the start of the file instead of refused |
| D22 | the identical-substitution refusals are dropped |
| D23 | the record is believed even when the clone it names is gone |

### The matrix

Each row is one control, every defect build that reddened it, and the exact failing line the first of those produced.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| a matching success line cannot establish that the target ran | D01 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `fab6b69f` |
| the proof owner's own success literal cannot reach a verdict | D19 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 1` | `fab6b69f` |
| a target that executed and passed is a pass | D01 | `the basis must say the target executed and concluded pass` | `fab6b69f` |
| a target that executed and failed is a fail | D20 | `an executed target that concluded fail is FAIL: expected exit 1, got 0` | `fab6b69f` |
| an unattributable substitution is could not observe | D01 D02 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `fab6b69f` |
| a target occurring more than once is refused | D03 | `a target with more than one occurrence has no single site: expected exit 2, got 1` | `fab6b69f` |
| a target occurring zero times is refused | D21 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `fab6b69f` |
| overlapping occurrences are counted separately | D03 | `overlapping occurrences must not collapse into one site: expected exit 2, got 1` | `fab6b69f` |
| the identity substitution reproduces the candidate tree | D05 | `the identity substitution must reproduce the candidate tree exactly` | `fab6b69f` |
| a substitution identical to the target is refused | D22 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `fab6b69f` |
| the source is never mutated | D12 | `the source file must be unmutated at every moment an execution was live` | `fab6b69f` |
| the disposable clone shares no object storage | D04 | `the disposable clone must share no object storage with the source` | `fab6b69f` |
| refuses a primary checkout as its source | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `fab6b69f` |
| refuses to overwrite an existing record | D07 | `a second generation must not be written over the first: expected exit 2, got 0` | `fab6b69f` |
| a record whose mutants are gone is could not observe | D23 | `a record whose mutation evidence is gone must be could-not-observe` | `fab6b69f` |
| an edited record cannot be read into a verdict | D01 D06 D23 | `the label case must fail before editing` | `fab6b69f` |
| a missing dimension outranks a clean fold | D10 | `one unobserved dimension outranks three clean executions: expected exit 2, got 0` | `fab6b69f` |
| a record pointing at another path is could not observe | D06 D23 | `a record whose named path is not where the mutants differ must not pass` | `fab6b69f` |
| a caller declaration cannot change the verdict | D01 D11 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `fab6b69f` |
| the probe argv is recorded exactly | D15 | `probe_argv must record every argument, including an empty one` | `fab6b69f` |
| one failing case makes the catalogue fail | D01 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `fab6b69f` |
| a failing case outranks an unobservable one | D01 D02 D09 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `fab6b69f` |
| an unobservable case outranks a passing one | D01 D02 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `fab6b69f` |
| an empty catalogue is could not observe | D13 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `fab6b69f` |
| a catalogue with duplicate identities is refused | D14 | `the refusal must name the collision (missing: 'duplicate case identities')` | `fab6b69f` |
| fm verify transports the result | D01 D18 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `fab6b69f` |
| a symlinked target path is refused | D16 | `the refusal must name what it saw (missing: 'not a regular file')` | `fab6b69f` |
| a missing execution substrate is could not observe | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `fab6b69f` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
