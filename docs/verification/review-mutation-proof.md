# Recurrence and mutation proof

Maintainer-verification record for [`bin/fm-review-mutation.sh`](../../bin/fm-review-mutation.sh), the proof owner that answers whether a named target assertion ran and what it concluded.
The guarantee measured here is narrow and exact: no label, marker, or caller-supplied name can establish that a named assertion executed.
An earlier version of this record described only the pinned `43b78b12` subject and its 32-control, 30-defect inventory, but that scope was superseded by the measurement at `fe9efa50`.
The `fe9efa50` scope covered a 35-control, 33-defect inventory, including the three source-adjacent output guards added after the earlier measurement, but it was itself superseded when catalogue argv decoding was corrected.
That gap has since been closed by re-measurement: the watched-red evidence below describes the pinned `015301ea` subject and its 35-control, 33-single-defect inventory, measured after the argv correction.
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
A suite-at-a-time measurement reports each defect reddening exactly one control and says nothing about the other thirty-four, which is a coverage claim resting on an observation that was never made.
Running each control separately produces a complete matrix, including the row that matters most: **controls no defect reddened**, which is reported rather than left to be inferred from a table that happens to look full.

### What this measurement caught in its own controls

Six times, and each time the finding was the point rather than an obstacle.

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
The source is now resolved and every source refusal is reached before this process creates anything, and the output path is canonicalised without being created by resolving its nearest existing ancestor.
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

For the superseded measurement, each defect build was confirmed to differ from the tracked script and to parse before it was run.
That confirmation matters because a build that fails to parse fails every control unconditionally, corroborating whatever it was pointed at while measuring nothing.

## Observed red and green

### Inventory claim

The suite executes 39 controls, and the current measured-file inventory is:

```
inventory_control_count: 39
inventory_sha256: bin/fm-review-mutation.sh 356906d81bf941b06b05fa1bd36d92d6a4085740ec3a1fa927422a59b6a529d6
inventory_sha256: bin/fm-verify.sh a187ed0765a1d17b419c83cbc55c9e98fd5f380701f0a50f8cdcd909e7c1bd37
inventory_sha256: tests/fm-review-mutation.test.sh 1c9c5684ad02bb64192013ffe44e5770079a1678c2f5d931b169d37687e4cb24
inventory_sha256: tests/review-mutation-red-matrix.py ad788b1e8e0c0789ccfb29eaf9299dcfd23c1fb44c6c42bc9171cec86c7416cd
```

This is an inventory claim only: it says these files and this control count agree with the
suite that runs today. `tests/fm-review-mutation.test.sh` enforces it and fails when they
drift, counting from the suite's own declared control array - which needs no execution, so it
cannot credit another control's failure by construction. A full run separately binds those
declared controls to the identities that actually executed, via `fm_test_contract`.

**Passing this inventory claim is NOT evidence for the measurement claim below.** A green
inventory sitting on top of unmeasured rows is the collapse this separation exists to
prevent, so the two are stated apart and never folded together.

### Measurement claim

Measured at `015301ea`. The green pass ran all 35 controls against the shipped scripts and exited 0.
33 single-defect builds were then measured, each control run separately against each build.
**Every control has at least one red witness, and no control is left unwitnessed.**
**Every defect build reddened at least one control, and zero defect builds reddened nothing.**

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
| D01 | `6a7dd35ba431bb2c2add98af9d3970bef93570f91564df8cb5058e145b6bb9be` | The retired defect, restored: the verdict is read from an `ok - ` line in the probe's captured output instead of from the differential. |
| D02 | `4e0542f2ced6a7683ed69f068aa0df6f6c73cca2936bbcc4716e1c432029a984` | Control is established by the falsifying direction alone. |
| D03 | `f2fadf5a95aeb6a7fcb7a13eee52702f120020fa228405ac046292e0c945844b` | The occurrence guard accepts more than one site and uses the first. |
| D04 | `e83a830737670799e6e0ee7bafcbec5b93fd45d804699cfda3fa80b1b9073c58` | The clone is made locally and its isolation assumed rather than measured. |
| D05 | `f136b1868efb3a418326428652bacb08142cd51cb455c739256dff9fc166b2b4` | The apparatus perturbs the baseline tree and nothing requires it not to. |
| D06 | `a06ee73709fef8a601495ec74c5c9710a4f94302c2f08b871b048a776665b1ac` | Mutation facts are read out of the record instead of re-proven. |
| D07 | `595dbabddd4bd3d805072ded3533b0bbb7309187abbc6d116f7b217007fafd3c` | An occupied output directory is cleared and reused. |
| D08 | `dbd8116807e4d56e8c6d716a5023d394586f5b39c81fd96e62e09ef061764400` | The primary-checkout refusal is dropped. |
| D09 | `50e428695921d3d5a6df0232a4ab38b5a1f725254c2ce9da585efba40117a594` | The catalogue fold reports a gap ahead of a failure. |
| D10 | `b5eff3ae15e91a2adf4a0a088f54ad865035af47a7987ea00bb6be386e81b8ab` | An unobserved dimension no longer outranks the fold. |
| D11 | `255ed4d64ed7573ca05b0d951320da0688b0b7c7c5b868b94abc28f138fb6a72` | A caller declaration is read and reaches the verdict. |
| D12 | `654c7efea116bf9526aceffde129a10a22a6945e886cc0e8a080973198548149` | The source is mutated in place and restored in a finally - every after-the-fact check is satisfied, a reader during the run is not. |
| D13 | `fbfd76b144c3a045e3499aa8bcfbc0e4016e4c3ce731b1812a42098510c521a9` | An empty catalogue is folded as clean. |
| D14 | `bc90d4b820347f9b8cdc461d5d92e3d2f62c268da31cb5ffa5d91c3f2c897082` | Duplicate case identities are accepted. |
| D15 | `0e29254c97c132422b8e913ed15070faab9f09686fa63dce96d0099969709539` | The probe argv is recorded as a space-joined rendering of itself. |
| D16 | `3ec599d3e3c18c40757ddb19ec96b37a6a7dc58cd37caa34cdbfbd5ac183b7d3` | The regular-file guard on the target path is dropped. |
| D17 | `8d5253611447759474e45f62c1d2353fd56cfef35bc14269d656690bb804d2cf` | With no execution substrate the build reports PASS itself rather than refusing - the exact fallback the law forbids. |
| D18 | `21d4aa3cd9ba1e5b7ea56ac2cbdb94d2fef66a1bca06896df0aec468855e1e1e` | The wrapper narrows any transported result to PASS. |
| D19 | `84a9de69a7d56f83170df8ad794e6008094caa3e0c884108a31e2fd3a4290eca` | The label defect in its other direction: a FAILURE literal in the probe's own output is read as a failure. |
| D20 | `c0dfec4ab82493637eac922b40b4c06c75c1b9eede8116b47e70ad2f592c6f38` | The unmutated baseline is ignored once control is established. |
| D21 | `7e9e3ce046a0ecc51a868b3873ac937f1149862821a99512cefa3f8adf0aaaf2` | A target that is not present is spliced in at the start of the file instead of refused - discovery failing open. |
| D22 | `111d1aae91895cbf4548e28a33676fce14ac985351f2d395b80134b730e7cd3b` | The identical-substitution refusals are dropped. |
| D23 | `8faa25652f2ec63973205027506233ed5bec91188772d3d9b6a9ff13fafd67a8` | The record is believed even when the clone it names is gone. |
| D24 | `de97aca065ccc057803c1fd166e344c6c7acd5c6c22558c526b9bc9439211c14` | Every execution record is accepted for every variant, so an execution belonging to another mutation can manufacture control. |
| D25 | `4390c5c5c6a2b3893c3bcb65e46a598762c3cb6a2165a448b19021e09ad29991` | The mutation bytes are not re-derived: any mismatch is swallowed, so a record can describe arbitrary commits as the three exact-byte mutations. |
| D26 | `7c9278f40ca5926d3530b93a09c3bef0304c7fc2874c8ab87a674d4457c3a355` | The record's documented control count disagrees with the suite. |
| D27 | `d66453c1fb7edec53f1e91f955a6f183603c2f6a1abbdcfa23c368f2e5053d87` | A documented file digest disagrees with the bytes it names. |
| D28 | `7fa0e3d3d39b84160f9c1c8561c9fc20bbeb1629d10f5acfdec46bbfc179492f` | The record carries no parseable inventory count at all. |
| D29 | `65e20a425ec16429e429a37a563033bee6f62e976ed3ce5cb6a6b7dc2f711a69` | The record's declared target path is never bound to where the mutants actually differ, so a record can name one file while its commits changed another. The binding lives in two places - the name-only diff and the re-derivation's path lookup - so defeating it takes both, which is one defect and not two. |
| D30 | `18e14051668cc5584c884a1d7d7151fc11d33bad9f4afc31e96e69cc9db4b757` | The output directory is claimed before the source is judged, so a caller naming a primary checkout with an output path inside it gets a directory written into the very checkout the next line refuses. The refusal text stays correct; the refusal leaves a trace in what it refused. |
| D31 | `d3d8d0330096b7a238981579e7a0a61d288b08a2df6440659bfc843d34a5bb27` | The closed `..` rejection is replaced by the old nearest-ancestor resolution, so traversal in a nonexistent suffix creates inside the source before the post-creation containment check refuses it. |
| D32 | `215d9dc40a3eab64ae9c29a7bf8346b5e1f89ddff743822fbe81ae25ebf938c2` | The shared pre-creation output guard is omitted from catalogue only, so output inside a linked-worktree source is created before the backstop refuses it. |
| D33 | `0764a1a4e4cb8b28a69a40f95f8fa4106db7a96046ed646de563e2df3250e6d9` | The shared output guard refuses every path, so legitimate evidence output outside the source can never proceed. |

### The matrix

Each row is one control, every defect build that reddened it, the exact failing line the
first of those produced, and the head it was measured at. The head is recorded per row: one
global label would let a single relabelling silently re-attribute every row.

| Control | Reddened by | Observed red | Measured at |
| --- | --- | --- | --- |
| a matching success line cannot establish that the target ran | D01 D05 D33 | `a target that did not execute must FAIL even when a suite printed its success line: expected exit 1, got 0` | `015301ea` |
| the proof owners own success literal cannot reach a verdict | D05 D19 D33 | `a real execution must pass even while printing this script's failure record: expected exit 0, got 2` | `015301ea` |
| a target that executed and passed is a pass | D01 D05 D33 | `the basis must say the target executed and concluded pass` | `015301ea` |
| a target that executed and failed is a fail | D05 D20 D33 | `an executed target that concluded fail is FAIL: expected exit 1, got 2` | `015301ea` |
| an unattributable substitution is could not observe | D01 D02 D05 D33 | `a substitution that moves the verdict for another reason is could-not-observe: expected exit 2, got 0` | `015301ea` |
| a target occurring more than once is refused | D03 D33 | `the refusal must name the guard (missing: 'exactly one occurrence is required')` | `015301ea` |
| a target occurring zero times is refused | D21 D33 | `the refusal must report the count it saw (missing: 'target occurs 0 times')` | `015301ea` |
| overlapping occurrences are counted separately | D03 D33 | `overlapping start positions must be counted separately (missing: 'target occurs 2 times')` | `015301ea` |
| the identity substitution reproduces the candidate tree | D05 D33 | `the identity substitution must reproduce the candidate tree exactly` | `015301ea` |
| a substitution identical to the target is refused | D22 D33 | `the refusal must name what was not tested (missing: 'the falsifying substitution is the target itself')` | `015301ea` |
| the source is never mutated | D12 D33 | `the source file must be unmutated at every moment an execution was live` | `015301ea` |
| a refused source is never written to | D08 D30 | `the refusal must name what it rejected (missing: 'refuses a primary checkout as its source')` | `015301ea` |
| a traversing output is refused without touching the source | D30 D31 D33 | `a traversing output refusal must leave the source byte-identical` | `015301ea` |
| the disposable clone shares no object storage | D04 D33 | `the disposable clone must share no object storage with the source` | `015301ea` |
| refuses a primary checkout as its source | D08 | `a primary checkout is refused as a mutation source: expected exit 2, got 0` | `015301ea` |
| refuses to overwrite an existing record | D07 D33 | `a second generation must not be written over the first: expected exit 2, got 0` | `015301ea` |
| a record whose mutants are gone is could not observe | D05 D33 | `the case must pass before the evidence is removed` | `015301ea` |
| an edited record cannot be read into a verdict | D01 D05 D06 D23 D33 | `the label case must fail before editing` | `015301ea` |
| an execution from the wrong variant is could not observe | D24 D33 | `an execution for another mutation must not enter the fold` | `015301ea` |
| preserved mutation bytes are rederived | D25 D29 D33 | `changed preserved bytes must invalidate the claimed mutant` | `015301ea` |
| a missing dimension outranks a clean fold | D10 D33 | `an incomplete record must not classify PASS (missing: 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,')` | `015301ea` |
| a record pointing at another path is could not observe | D29 | `a record whose named path is not where the mutants differ must not pass` | `015301ea` |
| a caller declaration cannot change the verdict | D01 D05 D11 D33 | `a declaration that the target ran cannot make it have run: expected exit 1, got 0` | `015301ea` |
| the probe argv is recorded exactly | D15 D33 | `probe_argv must record every argument, including an empty one` | `015301ea` |
| catalogue refuses output inside a linked worktree source | D32 D33 | `catalogue containment refusal must leave the linked-worktree source byte-identical` | `015301ea` |
| output outside the source is accepted | D05 D33 | `an output path outside the source remains accepted: expected exit 0, got 2` | `015301ea` |
| one failing case makes the catalogue fail | D01 D05 D09 D33 | `one failing case must make the whole catalogue fail: expected exit 1, got 0` | `015301ea` |
| a failing case outranks an unobservable one | D01 D02 D05 D09 D33 | `an observation gap must never mask a real finding: expected exit 1, got 0` | `015301ea` |
| an unobservable case outranks a passing one | D01 D02 D33 | `a catalogue with an unobservable case is not a passing catalogue: expected exit 2, got 0` | `015301ea` |
| an empty catalogue is could not observe | D13 D33 | `zero findings over an empty universe is not a clean universe: expected exit 2, got 0` | `015301ea` |
| a catalogue with duplicate identities is refused | D14 D33 | `the refusal must name the collision (missing: 'duplicate case identities')` | `015301ea` |
| fm verify transports the result | D01 D05 D18 D33 | `the wrapper must transport FAIL as FAIL: expected exit 1, got 0` | `015301ea` |
| a symlinked target path is refused | D16 D33 | `the refusal must name what it saw (missing: 'not a regular file')` | `015301ea` |
| a missing execution substrate is could not observe | D17 | `no execution substrate means no observation of execution: expected exit 2, got 0` | `015301ea` |
| verification record inventory matches executed controls | D26 D27 D28 | `the documented control count (1) must equal the suite's declared control count (35)` | `015301ea` |

## What is not covered

The proof owner is deliberately narrow, and these are named rather than left to be discovered:

- It does not judge a probe's output, findings, or reasoning. That is a different question with a different owner, and mixing them is how a verdict starts standing in for an execution.
- It cannot separate a substitution that flipped an assertion from one that broke the file for another reason, beyond what the satisfying direction rules out. See the limit above.
- It requires the candidate to be reachable from a ref in the source, because a disposable clone carries refs. A candidate that is not reachable is reported as could-not-observe with that exact reason rather than silently proved against something else.
- It requires the target to be a regular file blob in the candidate tree. A symlink or submodule entry is refused, because substituting bytes into one does not mutate the file a case names.
