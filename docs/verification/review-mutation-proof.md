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
Every control in [`tests/fm-review-mutation.test.sh`](../../tests/fm-review-mutation.test.sh) is therefore run against every single-defect build, individually, and the unmodified suite is trusted passing only after that.
The defect builds are materialized into a temporary directory and removed; no tracked file is ever mutated to produce them.
The catalogue that defines them is tracked, in [`tests/review-mutation-red-matrix.py`](../../tests/review-mutation-red-matrix.py), so every row below is replayable by someone who did not run it.

The controls are run one at a time rather than as a suite, because the suite stops at its first failing control.
A suite-at-a-time measurement reports each defect reddening exactly one control and says nothing about the other thirty, which is a coverage claim resting on an observation that was never made.
Running each control separately produces the complete matrix below, including the row that matters most: **controls no defect reddened**, which is reported rather than left to be inferred from a table that happens to look full.

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
It now counts the identities that have passed plus itself, asserts that it is the last declared control so that arithmetic cannot be silently shortened, and reports last.
A success line emitted ahead of its evidence is this increment's own defect turned on its own suite.

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
inventory_sha256: tests/fm-review-mutation.test.sh 94613e6c6215177001d44079500680fa1377afea8c00c1d594ba3bee69afa879
inventory_sha256: tests/review-mutation-red-matrix.py 876a0991d51f556999886482d5abb405488ff9d1d671fdccd947c567dcc08d48
```

This is an inventory claim only: it says these files and this control count agree with the
suite that runs today. `tests/fm-review-mutation.test.sh` enforces it and fails when they
drift, counting from the suite's own executed identities rather than from a second number.

**Passing this inventory claim is NOT evidence for the measurement claim below.** A green
inventory sitting on top of unmeasured rows is the collapse this separation exists to
prevent, so the two are stated apart and never folded together.

### Measurement claim

Measured at `e3412a41`. The green pass ran all 31 controls against the shipped scripts and exited 0.
29 single-defect builds were then measured, each control run separately against each build.
**Every control has at least one red witness, and no control is left unwitnessed.**

The measurement pinned the inventory digests before and after the run and they were identical,
so all of it describes one build rather than a moving one.

Controls are run one at a time rather than as a suite, because the suite stops at its first
failing control. A suite-at-a-time measurement reports each defect reddening exactly one
control and says nothing about the rest, which is a coverage claim resting on an observation
that was never made.

### Replaying an entry

Every row is reproducible from the tracked catalogue in
[`tests/review-mutation-red-matrix.py`](../../tests/review-mutation-red-matrix.py):

```
tests/review-mutation-red-matrix.py replay <defect> <control>
```

It rebuilds that exact defect, reruns that one control, and prints the defect build's sha256
alongside the outcome. Compare the digest with the defect table below before comparing
outcomes: a digest that does not reproduce means the row describes a build that is not the
one in front of you. A replay is a new execution and cannot establish that the historical run
happened - what it removes is the need to take this record's word for it.

### The defect builds

| Build | sha256 | Defect injected |
| --- | --- | --- |
| D01 | `627f2db951f590f9` | The retired defect, restored: the verdict is read from an `ok - ` line in |
| D02 | `fef4546f67969e3e` | Control is established by the falsifying direction alone. |
| D03 | `d5f43b0401c76e2d` | The occurrence guard accepts more than one site and uses the first. |
| D04 | `158e13322203f5a8` | The clone is made locally and its isolation assumed rather than measured. |
| D05 | `e8cb6b01cfffbabe` | The apparatus perturbs the baseline tree and nothing requires it not to. |
| D06 | `be851ac86bcf9f30` | Mutation facts are read out of the record instead of re-proven. |
| D07 | `346d0123b63ad6d8` | An occupied output directory is cleared and reused. |
| D08 | `d50d64f9895f7112` | The primary-checkout refusal is dropped. |
| D09 | `15d19609060a4b37` | The catalogue fold reports a gap ahead of a failure. |
| D10 | `1b3a0cdfbcec9244` | An unobserved dimension no longer outranks the fold. |
| D11 | `ba8159821f850fa8` | A caller declaration is read and reaches the verdict. |
| D12 | `ce29e47479a169ac` | The source is mutated in place and restored in a finally - every |
| D13 | `010b2bd74507c4b9` | An empty catalogue is folded as clean. |
| D14 | `e80b66ec4449a138` | Duplicate case identities are accepted. |
| D15 | `54e56d12763b7591` | The probe argv is recorded as a space-joined rendering of itself. |
| D16 | `cad8446665c476da` | The regular-file guard on the target path is dropped. |
| D17 | `13bba21457ef46ec` | With no execution substrate the build reports PASS itself rather than |
| D18 | `a430a1a85f5a627e` | The wrapper narrows any transported result to PASS. |
| D19 | `41f7b07dcc93aeca` | The label defect in its other direction: a FAILURE literal in the probe's |
| D20 | `270171091ae45d53` | The unmutated baseline is ignored once control is established. |
| D21 | `accd2ed975181c20` | A target that is not present is spliced in at the start of the file |
| D22 | `789a84f8165a934c` | The identical-substitution refusals are dropped. |
| D23 | `7e66f8f567c68762` | The record is believed even when the clone it names is gone. |
| D24 | `a729fe853d1c2690` | Every execution record is accepted for every variant, so an execution |
| D25 | `11cde133a108a335` | The mutation bytes are not re-derived: any mismatch is swallowed, so a |
| D26 | `a9fcbd8ed421551b` | The record's documented control count disagrees with the suite. |
| D27 | `eccca013a6b9a25f` | A documented file digest disagrees with the bytes it names. |
| D28 | `6e354dd22ac8b864` | The record carries no parseable inventory count at all. |
| D29 | `70f8bd70e725dbca` | The record's declared target path is never bound to where the mutants |

### The matrix

Each row is one control, every defect build that reddened it, the exact failing line the
first of those produced, and the head it was measured at. The head is recorded per row: one
global label would let a single relabelling silently re-attribute every row.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| a matching success line cannot establish that the target ran | D01 D05 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `e3412a41` |
| the proof owners own success literal cannot reach a verdict | D05 D19 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `e3412a41` |
| a target that executed and passed is a pass | D01 D05 | `the basis must say the target executed and concluded pass` | `e3412a41` |
| a target that executed and failed is a fail | D05 D20 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `e3412a41` |
| an unattributable substitution is could not observe | D01 D02 D05 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `e3412a41` |
| a target occurring more than once is refused | D03 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `e3412a41` |
| a target occurring zero times is refused | D21 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `e3412a41` |
| overlapping occurrences are counted separately | D03 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `e3412a41` |
| the identity substitution reproduces the candidate tree | D05 | `the identity substitution must reproduce the candidate tree exactly` | `e3412a41` |
| a substitution identical to the target is refused | D22 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `e3412a41` |
| the source is never mutated | D12 | `the source file must be unmutated at every moment an execution was live` | `e3412a41` |
| the disposable clone shares no object storage | D04 | `the disposable clone must share no object storage with the source` | `e3412a41` |
| refuses a primary checkout as its source | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `e3412a41` |
| refuses to overwrite an existing record | D07 | `a second generation must not be written over the first: expected exit 2, got 0` | `e3412a41` |
| a record whose mutants are gone is could not observe | D05 | `the case must pass before the evidence is removed` | `e3412a41` |
| an edited record cannot be read into a verdict | D01 D05 D06 D23 | `the label case must fail before editing` | `e3412a41` |
| an execution from the wrong variant is could not observe | D24 | `an execution for another mutation must not enter the fold` | `e3412a41` |
| preserved mutation bytes are rederived | D25 D29 | `changed preserved bytes must invalidate the claimed mutant` | `e3412a41` |
| a missing dimension outranks a clean fold | D10 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `e3412a41` |
| a record pointing at another path is could not observe | D29 | `a record whose named path is not where the mutants differ must not pass` | `e3412a41` |
| a caller declaration cannot change the verdict | D01 D05 D11 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `e3412a41` |
| the probe argv is recorded exactly | D15 | `probe_argv must record every argument, including an empty one` | `e3412a41` |
| one failing case makes the catalogue fail | D01 D05 D09 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `e3412a41` |
| a failing case outranks an unobservable one | D01 D02 D05 D09 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `e3412a41` |
| an unobservable case outranks a passing one | D01 D02 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `e3412a41` |
| an empty catalogue is could not observe | D13 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `e3412a41` |
| a catalogue with duplicate identities is refused | D14 | `the refusal must name the collision (missing: 'duplicate case identities')` | `e3412a41` |
| fm verify transports the result | D01 D05 D18 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `e3412a41` |
| a symlinked target path is refused | D16 | `the refusal must name what it saw (missing: 'not a regular file')` | `e3412a41` |
| a missing execution substrate is could not observe | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `e3412a41` |
| verification record inventory matches executed controls | D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11 D12 D13 D14 D15 D16 D17 D18 D19 D20 D21 D22 D23 D24 D25 D26 D27 D28 D29 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `e3412a41` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
