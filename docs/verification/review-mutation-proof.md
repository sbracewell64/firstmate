# Recurrence and mutation proof

Maintainer-verification record for [`bin/fm-review-mutation.sh`](../../bin/fm-review-mutation.sh), the proof owner that answers whether a named target assertion ran and what it concluded.
The guarantee measured here is narrow and exact: no label, marker, or caller-supplied name can establish that a named assertion executed.
An earlier version of this record described only the pinned `43b78b12` subject and its 32-control, 30-defect inventory, but that scope was superseded by the measurement at `fe9efa50`.
The `fe9efa50` scope covered a 35-control, 33-defect inventory, including the three source-adjacent output guards added after the earlier measurement, but it was itself superseded when catalogue argv decoding was corrected.
That gap has since been closed by re-measurement: the watched-red evidence below describes the pinned `015301ea` subject and its 35-control, 33-single-defect inventory, measured after the argv correction.
That scope was superseded by the quiet-window measurement at `6269ffb4`; the watched-red evidence below now describes its 40-control, 34-single-defect inventory.
Each supersession is recorded rather than overwritten, because a record that shows when its own evidence stopped applying is more credible than one that only ever states its latest figures.

The script's own header owns the law, the fold, the twenty-two bound dimensions, and the mechanics.
This file records only what was measured, when, and when that measurement no longer applies.

## Why watched red is the acceptance condition here

The predecessor this replaces accepted a proxy in its own implementation.
It ran an entire suite and treated an exact textual `ok - <case>` / `not ok - <case>: <failure>` line as proof that the named assertion had executed, and its mutation catalogue routed many distinct cases through that one broad-suite wrapper - including cases whose stated purpose was proving that labels and proxies cannot establish execution.
Fifteen correction rounds did not fix it, which is why it was retired rather than repaired a sixteenth time.

A control that has only ever been seen green is indistinguishable from that defect.
Every control in [`tests/fm-review-mutation.test.sh`](../../tests/fm-review-mutation.test.sh) is therefore run against every single-defect build, individually, and the unmodified suite is trusted passing only after that.
The defect builds are materialized into a temporary directory and removed; no tracked file is ever mutated to produce them.
The catalogue that defines them is tracked in [`tests/review-mutation-red-matrix.py`](../../tests/review-mutation-red-matrix.py), so every recorded row is replayable by someone who did not run it.
Every defect identifier used in this record is defined by that tracked catalogue and remains replayable whether or not this record currently carries a matrix.

The controls are run one at a time rather than as a suite, because the suite stops at its first failing control.
A suite-at-a-time measurement reports each defect reddening exactly one control and says nothing about the other thirty-nine, which is a coverage claim resting on an observation that was never made.
Running each control separately produces a complete matrix, including the row that matters most: **controls no defect reddened**, which is reported rather than left to be inferred from a table that happens to look full.

### What this measurement caught in its own controls

Seven times, and each time the finding was the point rather than an obstacle.

A control was found inadequate rather than recorded as passing.
The source-custody control originally observed the source only after the run finished, so a build that mutated the source in place and restored it in a `finally` satisfied every check it made.
That is the shape the standing law names - a control must never mutate the artifact it protects, and restore-in-finally is not sufficient because a concurrent reader sees the mutated state.
It now samples the source **from inside the probe**, the one thing running at the moment any mutation would be live, once per execution.
The measured red witness was `D12`, whose build remains defined and replayable from the tracked catalogue.

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

The correction is checkable in the recorded matrix when one is present: the inventory control's witnesses were `D26`, `D27` and `D28` alone - the three builds that actually make the inventory check fail - where the contaminated measurement had credited it with twenty-nine.
A repair that removes twenty-six false witnesses makes the claim smaller and true, which is the direction a correction to a verification record should move.

Last, the proof owner was found writing into a source it had just refused.
It claimed its output directory before it judged the source, so a caller naming a primary checkout with an output path inside it received a correct refusal *and* a directory left behind in the checkout that refusal was about.
That is the standing law broken inside the increment whose subject is that law: a control must never mutate the artifact it protects.
The source checkout root is now resolved and every source refusal is reached before this process creates anything, and the output path is canonicalised without being created by resolving its nearest existing ancestor.
`D30` restores the old ordering, and the control it reddens asserts the absence of a trace rather than the wording of the refusal - the refusal text was always correct, which is exactly why the defect survived until someone compared the checkout before and after.

Worth recording about how that one was found: it was raised by independent review as a high risk saying the change should not merge, but it reached the pull request body rather than a blocking gate, and the run around it reported a passing outcome with fourteen green checks.
A reader who trusted the outcome line would have shipped it.

That custody repair was then found incomplete, twice over, by the next review.
A `..` component in a nonexistent suffix defeated the non-creating resolution, so `--out <parent>/new/../src/evidence` passed the containment check as a string and `mkdir` created the directory inside the source before the later check refused it.
Separately, `catalogue` had been given the primary-checkout refusal but never the containment check, so a valid linked-worktree source with an output path inside it was created and then refused.
Both were observed directly, the directory appearing in the checkout each time.

The repair was a class fix rather than a third patch of the same shape, and the reasoning is worth keeping.
Normalising around traversal is a rule that must be right every time; refusing traversal outright is a rule that must be right once, so any `--out` containing a `..` component is now refused by a closed guard matching the one already applied to `--path`.
And the containment logic now lives in ONE function called by both `prove` and `catalogue`: duplicating that guard instead of sharing it is exactly what produced the second finding, because two copies have two chances to be incomplete and nothing notices when only one is updated.
`D31`, `D32` and `D33` witness the three properties separately - traversal refused with the source left byte-identical, catalogue containment on a linked-worktree source, and the non-vacuity control that a legitimate output outside the source is still accepted.
That last one is not optional: a guard that refused everything would satisfy the other two while making the tool useless, and nothing else in the suite would have noticed.

Seventh, the guard binding this record to its subject was one-sided.
The inventory claim bound the recorded digests to the CURRENT bytes; nothing bound them to the bytes that actually produced the measurement, so a repin that was not a re-measurement decoupled the two silently - and did so here, while every control stayed green.
The record now also carries the digests AS MEASURED, written only by a measurement run, and a control fails when they diverge from the current subject. `D34` is its witness.

That control's first measurement was discarded rather than recorded.
Run against a record that did not yet carry a measured block, it failed for every defect build in the catalogue - not because any targets it, but because a precondition none of them controls was absent and each running build was credited with the result.
Byte-identical failure text repeated across every build is one cause, not many detections, and recording it would have claimed a witness set none of those builds earned.
It was re-measured against the completed record, and its witness is `D34` alone.

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
A single entry, for checking one row of a matrix result:

```
tests/review-mutation-red-matrix.py replay <defect> <control>
```

Both drive the suite through four seams, each read only by the test file and each defaulting to the tracked artifact, so they exist for matrix measurement and change nothing in production:

| Seam | Overrides | Why it has to exist separately |
| --- | --- | --- |
| `FM_REVIEW_MUTATION_BIN` | the proof owner | the subject of most defects |
| `FM_VERIFY_BIN` | the wrapper that transports its result | `bin/fm-verify.sh` resolves the proof owner from its OWN directory, so overriding only the binary would exercise the shipped adapter against the shipped proof owner and the adapter's own defect would go unwitnessed |
| `FM_REVIEW_MUTATION_RECORD` | this record | the drift control's subject is the RECORD, not the binary, so no defect build could otherwise reach it - it would be the one control that could never be watched red |
| `FM_REVIEW_MUTATION_ONLY` | which control runs | refuses a name not in `FM_CONTROLS` rather than running nothing, because selecting a control that does not exist would otherwise report a clean run having observed nothing at all |

For the current measurement, each defect build was confirmed to differ from the tracked script and to parse before it was run.
That confirmation matters because a build that fails to parse fails every control unconditionally, corroborating whatever it was pointed at while measuring nothing.

## Observed red and green

### Inventory claim

The suite executes 40 controls, and the current measured-file inventory is:

```
inventory_control_count: 40
inventory_sha256: bin/fm-review-mutation.sh 6961e3bbee3bf13b876982b32ebb42a92c94e2ec64a066a05e46e968c4f88993
inventory_sha256: bin/fm-verify.sh a187ed0765a1d17b419c83cbc55c9e98fd5f380701f0a50f8cdcd909e7c1bd37
inventory_sha256: tests/fm-review-mutation.test.sh 092b1fb90a77ab8e330627c552b2501629580a82e6d1ff88c763c854ea73a7fe
inventory_sha256: tests/review-mutation-red-matrix.py 1917504e3326bbdb38182b2f41d61038c8709c03c84516e4f6422eb81602f668
```

The same digests, recorded as the bytes the matrix below was actually measured against.
They are written only by a measurement run, so a repin that is not a re-measurement cannot move them, and `tests/fm-review-mutation.test.sh` fails when they diverge from the current subject.
Without this the inventory could be made current while the measurement silently described bytes that no longer exist.

```
measured_at: 6269ffb4
measured_sha256: bin/fm-review-mutation.sh 6961e3bbee3bf13b876982b32ebb42a92c94e2ec64a066a05e46e968c4f88993
measured_sha256: bin/fm-verify.sh a187ed0765a1d17b419c83cbc55c9e98fd5f380701f0a50f8cdcd909e7c1bd37
measured_sha256: tests/fm-review-mutation.test.sh 092b1fb90a77ab8e330627c552b2501629580a82e6d1ff88c763c854ea73a7fe
measured_sha256: tests/review-mutation-red-matrix.py 1917504e3326bbdb38182b2f41d61038c8709c03c84516e4f6422eb81602f668
```

This is an inventory claim only: it says these files and this control count agree with the suite that runs today.
`tests/fm-review-mutation.test.sh` enforces it and fails when they drift, counting from the suite's own declared control array - which needs no execution, so it cannot credit another control's failure by construction.
A full run separately binds those declared controls to the identities that actually executed, via `fm_test_contract`.

**Passing this inventory claim is NOT evidence for the measurement claim below.**
A green inventory sitting on top of unmeasured rows is the collapse this separation exists to prevent, so the two are stated apart and never folded together.

### Measurement claim

Measured at `6269ffb4`. The green pass ran all 40 controls against the shipped scripts and exited 0.
34 single-defect builds were then measured, each control run separately against each build.
**Every control has at least one red witness, and no control is left unwitnessed.**
**Every defect build reddened at least one control, so no catalogued defect is inert.**
That is a separate claim from control coverage above, and neither implies the other.

The measurement pinned the inventory digests before and after the run and they were identical, so all of it describes one build rather than a moving one.

Controls are run one at a time rather than as a suite, because the suite stops at its first failing control.
A suite-at-a-time measurement reports each defect reddening exactly one control and says nothing about the rest, which is a coverage claim resting on an observation that was never made.

### Replaying an entry

Every row is reproducible from the tracked catalogue in [`tests/review-mutation-red-matrix.py`](../../tests/review-mutation-red-matrix.py):

```
tests/review-mutation-red-matrix.py replay <defect> <control>
```

It rebuilds that exact defect, reruns that one control, and prints the defect build's sha256 alongside the outcome.
Compare the digest with the defect table below before comparing outcomes: a digest that does not reproduce means the row describes a build that is not the one in front of you.
A replay is a new execution and cannot establish that the historical run happened - what it removes is the need to take this record's word for it.

### The defect builds

| Build | sha256 | Defect injected |
| --- | --- | --- |
| D01 | `9a1ac2e8379ccb1be738031720b7b8fcb205ce8415feb86c047e6ab9d89c20ee` | The retired defect, restored: the verdict is read from an `ok - ` line in the probe's captured output instead of from the differential. |
| D02 | `ea879d80254c4f0a9c6ef68e23fc7988d7bb3b891681d9f3fb98fb26225f14d3` | Control is established by the falsifying direction alone. |
| D03 | `e60886802c6788f480fe19160ff7a28964779a37d96253472fffa8b80808a6d2` | The occurrence guard accepts more than one site and uses the first. |
| D04 | `5857c1f1a845b1323adadead1087ecfd62ca772a836b56fda62e35d4b7aa3b52` | The clone is made locally and its isolation assumed rather than measured. |
| D05 | `1aab728d213c0bff18474b6a6a55833e4e91041a54e65359370ffd97548330f2` | The apparatus perturbs the baseline tree and nothing requires it not to. |
| D06 | `90927c701840e79a00820bf72d3d471280baf496fd8cf0ea57e281ecc112b6e7` | Mutation facts are read out of the record instead of re-proven. |
| D07 | `cdef45a4d2969492c11f817f8307618d6d5a08b892a289b162d09c72a01f2d77` | An occupied output directory is cleared and reused. |
| D08 | `cf64caed826ede9da8c36a341e5d5f398f5aa57d3cc3ff35babf0c9bb1fa8c20` | The primary-checkout refusal is dropped. |
| D09 | `1d417fda35a130e9b0c59084dc015f3b78ad7f0cb97fbf30a529d031795805e1` | The catalogue fold reports a gap ahead of a failure. |
| D10 | `d8ce626956cfa3b6e22f88d1093b683ca9e3dace069dcb92700fb8f630060f58` | An unobserved dimension no longer outranks the fold. |
| D11 | `57324351a04426ac9900698523cf78d913ff9c2d10e91d2d35ee0049dd3ad4b3` | A caller declaration is read and reaches the verdict. |
| D12 | `b141cd6f6aeae68ad1fff39450ceed6b35929f83aa60af08a9f2264e5c299647` | The source is mutated in place and restored in a finally - every after-the-fact check is satisfied, a reader during the run is not. |
| D13 | `d9d468ce96ce9bacd405ec96cdbc267c289111ae87b27c916c30aaaa63cbb7e5` | An empty catalogue is folded as clean. |
| D14 | `a5c6a1b0ae4b513f524b8347039b11fdf6859975d58feacae624721490c7e0e9` | Duplicate case identities are accepted. |
| D15 | `9ff66a17d2ab798ef20dc49773467caeb57b152a96fa28751631af33adbba331` | The probe argv is recorded as a space-joined rendering of itself. |
| D16 | `680a5ec3d64301bd331f9f1496cb9808efa388aefdc67981f0925b08ceac8946` | The regular-file guard on the target path is dropped. |
| D17 | `c202f721a8ec9243a7d1f834355015bdb2503feeb6fbb813a4d3dadbab8044d2` | With no execution substrate the build reports PASS itself rather than refusing - the exact fallback the law forbids. |
| D18 | `7e1afca02dda9a6bb7c0ba2d5b879bf2412d97a5b88d17caceb4d352fe8db52d` | The wrapper narrows any transported result to PASS. |
| D19 | `127153e07ffbee086692747f1782a381e0300d19d089f8c02e09db243f61bc4c` | The label defect in its other direction: a FAILURE literal in the probe's own output is read as a failure. |
| D20 | `b7ac23bd6194f30d9d9014870d661eb074c3dbb475e5b3ef76cc48f778ad3347` | The unmutated baseline is ignored once control is established. |
| D21 | `0d06782581619116fba708fee0889b1ead64acad190944a20891072e84372842` | A target that is not present is spliced in at the start of the file instead of refused - discovery failing open. |
| D22 | `9cf76b0ec54ffb0a86e63a509b381842cee363f603c6e6468cd3dce237bd2621` | The identical-substitution refusals are dropped. |
| D23 | `4afe1bb9b2e17c26cc79f9eb3506b6fda7e60f1d31fe46dc78d393318da64026` | The record is believed even when the clone it names is gone. |
| D24 | `0e9586ef2f6d8a5a0badcdca7c56940ea3be5b6100e3cf091c6e76b3e3f5e3fc` | Every execution record is accepted for every variant, so an execution belonging to another mutation can manufacture control. |
| D25 | `91882314d14d8a234c42dca5c73562336d133418c007952e775b7b7a72b1a50a` | The mutation bytes are not re-derived: any mismatch is swallowed, so a record can describe arbitrary commits as the three exact-byte mutations. |
| D26 | `1c19b33c01ebfee097b5417afd74d46ec2b6f567159400fc3b0b95c3e273fe66` | The record's documented control count disagrees with the suite. |
| D27 | `5c847c616773cc043596f559e34290deadbda88add9e160f7462fb7e1124be9a` | A documented file digest disagrees with the bytes it names. |
| D28 | `a2a00d5b94d5363fa11b2e172318907bd363d7cd01e39c9dad35522e0f593c01` | The record carries no parseable inventory count at all. |
| D29 | `8ed879c96cc8eac0b5b473f4ea11bf40f36de20b1a537edead5149f137d25966` | The record's declared target path is never bound to where the mutants actually differ, so a record can name one file while its commits changed another. The binding lives in two places - the name-only diff and the re-derivation's path lookup - so defeating it takes both, which is one defect and not two. |
| D30 | `8fd66d9777fcc24c32bc344ebc8ea30a4f767f50e4f5ee932ea02ef372bd266d` | The output directory is claimed before the source is judged, so a caller naming a primary checkout with an output path inside it gets a directory written into the very checkout the next line refuses. The refusal text stays correct; the refusal leaves a trace in what it refused. |
| D31 | `afb748650811bf241f6d9b536eab4a082d3bb0d24a96eb6ee9ac778feb336544` | The closed `..` rejection is replaced by the old nearest-ancestor resolution, so traversal in a nonexistent suffix creates inside the source before the post-creation containment check refuses it. |
| D32 | `2b6c33887d464113961a48bfe3da0bd58758ba42044312e3905b131b60ab2b37` | The shared pre-creation output guard is omitted from catalogue only, so output inside a linked-worktree source is created before the backstop refuses it. |
| D33 | `eb4acbf4130fc3e9b90faec33fbbdf2eec46de4a3e32af04dc6618cc8a626eb0` | The shared output guard refuses every path, so legitimate evidence output outside the source can never proceed. |
| D34 | `d6834a05a268debafd7cf456ab27150e40a7055eb13d04e8cc8f36fe749e36f8` | The record's measured digests no longer describe the current subject, so the matrix reports a measurement taken against bytes that have since changed. |

### The matrix

Each row is one control, every defect build that reddened it, the exact failing line the first of those produced, and the head it was measured at.
The head is recorded per row: one global label would let a single relabelling silently re-attribute every row.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| a matching success line cannot establish that the target ran | D01 D05 D33 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `6269ffb4` |
| the proof owners own success literal cannot reach a verdict | D05 D19 D33 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `6269ffb4` |
| a target that executed and passed is a pass | D01 D05 D33 | `the basis must say the target executed and concluded pass` | `6269ffb4` |
| a target that executed and failed is a fail | D05 D20 D33 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `6269ffb4` |
| an unattributable substitution is could not observe | D01 D02 D05 D33 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `6269ffb4` |
| a target occurring more than once is refused | D03 D33 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `6269ffb4` |
| a target occurring zero times is refused | D21 D33 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `6269ffb4` |
| overlapping occurrences are counted separately | D03 D33 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `6269ffb4` |
| the identity substitution reproduces the candidate tree | D05 D33 | `the identity substitution must reproduce the candidate tree exactly` | `6269ffb4` |
| a substitution identical to the target is refused | D22 D33 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `6269ffb4` |
| the source is never mutated | D12 D33 | `the source file must be unmutated at every moment an execution was live` | `6269ffb4` |
| a refused source is never written to | D08 D30 | `the refusal must name what it rejected (missing: 'refuses a primary checkout as its source')` | `6269ffb4` |
| a traversing output is refused without touching the source | D30 D31 D33 | `a traversing output refusal must leave the source byte-identical` | `6269ffb4` |
| prove refuses output through a symlinked source ancestor | D30 D33 | `prove containment refusal must happen before creating output` | `6269ffb4` |
| prove protects the checkout when source is a subdirectory | D33 | `the prove refusal must name checkout-root containment (missing: 'output directory is inside the source checkout')` | `6269ffb4` |
| the disposable clone shares no object storage | D04 D33 | `the disposable clone must share no object storage with the source` | `6269ffb4` |
| refuses a primary checkout as its source | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `6269ffb4` |
| refuses to overwrite an existing record | D07 D33 | `a second generation must not be written over the first: expected exit 2, got 0` | `6269ffb4` |
| a record whose mutants are gone is could not observe | D05 D33 | `the case must pass before the evidence is removed` | `6269ffb4` |
| an edited record cannot be read into a verdict | D01 D05 D06 D23 D33 | `the label case must fail before editing` | `6269ffb4` |
| an execution from the wrong variant is could not observe | D24 D33 | `an execution for another mutation must not enter the fold` | `6269ffb4` |
| preserved mutation bytes are rederived | D25 D29 D33 | `changed preserved bytes must invalidate the claimed mutant` | `6269ffb4` |
| a missing dimension outranks a clean fold | D10 D33 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `6269ffb4` |
| a record pointing at another path is could not observe | D29 | `a record whose named path is not where the mutants differ must not pass` | `6269ffb4` |
| a caller declaration cannot change the verdict | D01 D05 D11 D33 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `6269ffb4` |
| the probe argv is recorded exactly | D15 D33 | `probe_argv must record every argument, including an empty one` | `6269ffb4` |
| catalogue refuses output inside a linked worktree source | D32 D33 | `catalogue containment refusal must leave the linked-worktree source byte-identical` | `6269ffb4` |
| catalogue refuses output through a symlinked source ancestor | D32 D33 | `catalogue containment refusal must happen before creating output` | `6269ffb4` |
| catalogue protects the checkout when source is a subdirectory | D33 | `the catalogue refusal must name checkout-root containment (missing: 'output directory is inside the source checkout')` | `6269ffb4` |
| output outside the source is accepted | D05 D33 | `an output path outside the source remains accepted: expected exit 0, got 2` | `6269ffb4` |
| one failing case makes the catalogue fail | D01 D05 D09 D33 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `6269ffb4` |
| a failing case outranks an unobservable one | D01 D02 D05 D09 D33 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `6269ffb4` |
| an unobservable case outranks a passing one | D01 D02 D33 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `6269ffb4` |
| an empty catalogue is could not observe | D13 D33 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `6269ffb4` |
| a catalogue with duplicate identities is refused | D14 D33 | `the refusal must name the collision (missing: 'duplicate case identities')` | `6269ffb4` |
| fm verify transports the result | D01 D05 D18 D33 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `6269ffb4` |
| a symlinked target path is refused | D16 D33 | `the refusal must name what it saw (missing: 'not a regular file')` | `6269ffb4` |
| a missing execution substrate is could not observe | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `6269ffb4` |
| verification record inventory matches executed controls | D26 D27 D28 | `the documented control count (1) must equal the suite's declared control count (40)` | `6269ffb4` |
| recorded measurement describes the current subject | D34 | `the recorded measurement describes different bytes than the current bin/fm-review-mutation.sh` | `6269ffb4` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
