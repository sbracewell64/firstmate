# Recurrence and mutation proof

Maintainer-verification record for [`bin/fm-review-mutation.sh`](../../bin/fm-review-mutation.sh), the proof owner that answers whether a named target assertion ran and what it concluded.
The guarantee measured here is narrow and exact: no label, marker, or caller-supplied name can establish that a named assertion executed.
The watched-red evidence below describes only the pinned `43b78b12` subject and the 32-control, 30-defect inventory recorded for that execution.
Later source-adjacent output guards in the checked-out subject add three controls and three defect builds, so they require a fresh watched-red measurement before this record can describe the checked-out subject as fully witnessed.

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

Five times, and each time the finding was the point rather than an obstacle.

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

The correction is checkable in the matrix below rather than asserted here: that control's witnesses are now `D26`, `D27` and `D28` alone - the three builds that actually make the inventory check fail - where the contaminated measurement had credited it with twenty-nine.
A repair that removes twenty-six false witnesses makes the claim smaller and true, which is the direction a correction to a verification record should move.

Last, the proof owner was found writing into a source it had just refused.
It claimed its output directory before it judged the source, so a caller naming a primary checkout with an output path inside it received a correct refusal *and* a directory left behind in the checkout that refusal was about.
That is the standing law broken inside the increment whose subject is that law: a control must never mutate the artifact it protects.
The source is now resolved and every refusal about it reached before this process creates anything, and the output path is canonicalised without being created by resolving its nearest existing ancestor.
`D30` restores the old ordering, and the control it reddens asserts the absence of a trace rather than the wording of the refusal - the refusal text was always correct, which is exactly why the defect survived until someone compared the checkout before and after.

Worth recording about how that one was found: it was raised by independent review as a high risk saying the change should not merge, but it reached the pull request body rather than a blocking gate, and the run around it reported a passing outcome with fourteen green checks.
A reader who trusted the outcome line would have shipped it.

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

The measured suite executed 32 controls, and its pinned file inventory was:

```
inventory_control_count: 35
inventory_sha256: bin/fm-review-mutation.sh f08aa8b4d6f3a9d74a6b82f81e716d863f33f5f3ba9da8cc4769e36b0e303b04
inventory_sha256: bin/fm-verify.sh 5682f35bbf89cda3bd15de96a0df825317e5698d4956122bd0c7fb4627dd8318
inventory_sha256: tests/fm-review-mutation.test.sh 1825e89611322421a2078cea86503a89fcc4386a4e4da1880cb5898fb50f0967
inventory_sha256: tests/review-mutation-red-matrix.py ad788b1e8e0c0789ccfb29eaf9299dcfd23c1fb44c6c42bc9171cec86c7416cd
```

This is an inventory claim only: it says those measured files and that control count agreed at `43b78b12`.
The measured `tests/fm-review-mutation.test.sh` enforced it and failed when they drifted, counting from the suite's own declared control array - which needed no execution, so it could not credit another control's failure by construction.
A full run separately bound those declared controls to the identities that actually executed, via `fm_test_contract`.

**Passing this inventory claim is NOT evidence for the measurement claim below.** A green
inventory sitting on top of unmeasured rows is the collapse this separation exists to
prevent, so the two are stated apart and never folded together.

### Measurement claim

Measured at `43b78b12`. The green pass ran all 32 controls against the shipped scripts and exited 0.
30 single-defect builds were then measured, each control run separately against each build.
**Every control has at least one red witness, and no control is left unwitnessed.**

The measurement pinned the inventory digests before and after the run and they were identical,
so all of it describes one build rather than a moving one.

Controls are run one at a time rather than as a suite, because the suite stops at its first
failing control. A suite-at-a-time measurement reports each defect reddening exactly one
control and says nothing about the rest, which is a coverage claim resting on an observation
that was never made.

### Replaying an entry

Every row is reproducible from the catalogue bytes pinned by the inventory above in
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
| D01 | `325978d24507ba2bc465e918be0311f713490679727fa76007676c6df9a12cb9` | The retired defect, restored: the verdict is read from an `ok - ` line in the probe's captured output instead of from the differential. |
| D02 | `fd1d5c4308ed50fd3ff26a2d719e7b78549de4a8995404f494dd473d682b90e7` | Control is established by the falsifying direction alone. |
| D03 | `9e8e53b0e9c4f7a820f0e4bd346837efbeb366c1b9ae65b8819029936958530c` | The occurrence guard accepts more than one site and uses the first. |
| D04 | `eaadcdadc3811708bc486596e53457a507f3d482e4a802a93e42e0298920797a` | The clone is made locally and its isolation assumed rather than measured. |
| D05 | `7079ce93a94c6745ea565c808de4213cb5b8fd1ef3ed0c03d7cac2cadc5352a5` | The apparatus perturbs the baseline tree and nothing requires it not to. |
| D06 | `da84d0d43865a621498fe33e38fef5e248bcb5bc8a1c95acab0757dbc357b54a` | Mutation facts are read out of the record instead of re-proven. |
| D07 | `10958795fccb3735c6a657f544f1071397636e256c9d4aff43435c3239842551` | An occupied output directory is cleared and reused. |
| D08 | `55c386f5adf9f3723f02d245dede6f80864a3ca2c1bed68209a2c149496a2b33` | The primary-checkout refusal is dropped. |
| D09 | `39ddb735ff81befaef6319532f54ee4d6b5a778f7b088bd211344833779b2e89` | The catalogue fold reports a gap ahead of a failure. |
| D10 | `badd48ac61795a2d004e90006bc0565ed1659e2705afe4a35b881473f242b221` | An unobserved dimension no longer outranks the fold. |
| D11 | `87d80e0a4ac068f4903823601cacee2301fa841aa5eae5c3112d4c81c538c3da` | A caller declaration is read and reaches the verdict. |
| D12 | `0119a64262c21a8c79c3de19b2ab144f2b5ae3f2b5cd4a9cf6aa7537910e56ef` | The source is mutated in place and restored in a finally - every after-the-fact check is satisfied, a reader during the run is not. |
| D13 | `33218271c36813f1c8590d0ba88ba29fe1fe793e905207630603d3d4c0dcdcc4` | An empty catalogue is folded as clean. |
| D14 | `ff93c6946608496ec95c01b58e46a9c87a613cd800439dd462f9642803678c94` | Duplicate case identities are accepted. |
| D15 | `e9105fed01304b43def6159b5ab49255969717edee87bdd99be1e417b1be9542` | The probe argv is recorded as a space-joined rendering of itself. |
| D16 | `1ab224f38ec321ebbcf7ab69d6ccbf297accfc153ad841b2d2407ac39b4d61bb` | The regular-file guard on the target path is dropped. |
| D17 | `864d6be76a803b8952582ccecbbd682bc6ce5f0c9d833fbdabc2680db85d3499` | With no execution substrate the build reports PASS itself rather than refusing - the exact fallback the law forbids. |
| D18 | `8cdf493fa6351c1c3da07e75a9f0d58c9601d6198d19f75fb4ba111fc601de5d` | The wrapper narrows any transported result to PASS. |
| D19 | `f363d6721cd813eb991cfe0f1e1273ba3614c1bb214eee32fb064ea9bc803bda` | The label defect in its other direction: a FAILURE literal in the probe's own output is read as a failure. |
| D20 | `fbdcb1c7797d2094feafdf8d1c4915fb0ebace9169180b02cc8ce4212a4dd48f` | The unmutated baseline is ignored once control is established. |
| D21 | `f1a5094c5ee34abf58e58be35f9ca811ef96fe1969aac109fbf5bf47fbba524f` | A target that is not present is spliced in at the start of the file instead of refused - discovery failing open. |
| D22 | `77afd4696a77ed6d39b9734e466d65d26e0b9cf6899968958217834e3e9e8dcb` | The identical-substitution refusals are dropped. |
| D23 | `d216f4d6668e2397c679d4ad45fefa1f8db4d9928fdf059b41bdd3cead554b5e` | The record is believed even when the clone it names is gone. |
| D24 | `be42e22f38b87f40b997ef1fe8074b6b036599c345ac4df0dfb2623058b90fa9` | Every execution record is accepted for every variant, so an execution belonging to another mutation can manufacture control. |
| D25 | `adc3676a266c4a0d53626a1a934f5934d29e4e1d30ebefba52d00d64dc08a534` | The mutation bytes are not re-derived: any mismatch is swallowed, so a record can describe arbitrary commits as the three exact-byte mutations. |
| D26 | `8e8a8b76319699cd4effe2749aa47ac2c3c82b8b5218a9ba294eaded91be9952` | The record's documented control count disagrees with the suite. |
| D27 | `12de98ef091e82464cca13943041f1d4bac7c16ddf6b69d9c4d27f292cf0d702` | A documented file digest disagrees with the bytes it names. |
| D28 | `12b66fbaa543a364a167f7fee87e0d101de233e0171089ab8d12342c4d08f397` | The record carries no parseable inventory count at all. |
| D29 | `104fedf2497cb6383fa9801eeb487c01ee3ba7db79ccfcb12ee8a1a45211a133` | The record's declared target path is never bound to where the mutants actually differ, so a record can name one file while its commits changed another. The binding lives in two places - the name-only diff and the re-derivation's path lookup - so defeating it takes both, which is one defect and not two. |
| D30 | `9a2135b049d34393b3e581ea204e8c7e9718886e9b269cab44e99922f28e9e3f` | The output directory is claimed before the source is judged, so a caller naming a primary checkout with an output path inside it gets a directory written into the very checkout the next line refuses. The refusal text stays correct; the refusal leaves a trace in what it refused. |

### The matrix

Each row is one control, every defect build that reddened it, the exact failing line the
first of those produced, and the head it was measured at. The head is recorded per row: one
global label would let a single relabelling silently re-attribute every row.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| a matching success line cannot establish that the target ran | D01 D05 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `43b78b12` |
| the proof owners own success literal cannot reach a verdict | D05 D19 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `43b78b12` |
| a target that executed and passed is a pass | D01 D05 | `the basis must say the target executed and concluded pass` | `43b78b12` |
| a target that executed and failed is a fail | D05 D20 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `43b78b12` |
| an unattributable substitution is could not observe | D01 D02 D05 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `43b78b12` |
| a target occurring more than once is refused | D03 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `43b78b12` |
| a target occurring zero times is refused | D21 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `43b78b12` |
| overlapping occurrences are counted separately | D03 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `43b78b12` |
| the identity substitution reproduces the candidate tree | D05 | `the identity substitution must reproduce the candidate tree exactly` | `43b78b12` |
| a substitution identical to the target is refused | D22 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `43b78b12` |
| the source is never mutated | D12 | `the source file must be unmutated at every moment an execution was live` | `43b78b12` |
| a refused source is never written to | D08 D30 | `the refusal must name what it rejected (missing: 'refuses a primary checkout as its source')` | `43b78b12` |
| the disposable clone shares no object storage | D04 | `the disposable clone must share no object storage with the source` | `43b78b12` |
| refuses a primary checkout as its source | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `43b78b12` |
| refuses to overwrite an existing record | D07 | `a second generation must not be written over the first: expected exit 2, got 0` | `43b78b12` |
| a record whose mutants are gone is could not observe | D05 | `the case must pass before the evidence is removed` | `43b78b12` |
| an edited record cannot be read into a verdict | D01 D05 D06 D23 | `the label case must fail before editing` | `43b78b12` |
| an execution from the wrong variant is could not observe | D24 | `an execution for another mutation must not enter the fold` | `43b78b12` |
| preserved mutation bytes are rederived | D25 D29 | `changed preserved bytes must invalidate the claimed mutant` | `43b78b12` |
| a missing dimension outranks a clean fold | D10 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `43b78b12` |
| a record pointing at another path is could not observe | D29 | `a record whose named path is not where the mutants differ must not pass` | `43b78b12` |
| a caller declaration cannot change the verdict | D01 D05 D11 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `43b78b12` |
| the probe argv is recorded exactly | D15 | `probe_argv must record every argument, including an empty one` | `43b78b12` |
| one failing case makes the catalogue fail | D01 D05 D09 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `43b78b12` |
| a failing case outranks an unobservable one | D01 D02 D05 D09 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `43b78b12` |
| an unobservable case outranks a passing one | D01 D02 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `43b78b12` |
| an empty catalogue is could not observe | D13 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `43b78b12` |
| a catalogue with duplicate identities is refused | D14 | `the refusal must name the collision (missing: 'duplicate case identities')` | `43b78b12` |
| fm verify transports the result | D01 D05 D18 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `43b78b12` |
| a symlinked target path is refused | D16 | `the refusal must name what it saw (missing: 'not a regular file')` | `43b78b12` |
| a missing execution substrate is could not observe | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `43b78b12` |
| verification record inventory matches executed controls | D26 D27 D28 | `the documented control count (1) must equal the suite's declared control count (32)` | `43b78b12` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
