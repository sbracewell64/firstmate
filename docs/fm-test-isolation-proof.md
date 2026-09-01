# Firstmate test isolation proof

`docs/fm-test-isolation-proof.json` is the machine-readable proof that a bounded set of behavior tests runs correctly under concurrency.
`bin/fm-test-isolation-proof.sh` is the harness that produces it, `bin/fm-test-isolation-lib.sh` owns what a measurement is and when a proof has gone stale, and `bin/fm-test-run.sh` consumes the artifact for production lane composition.

The artifact is the single owner of the proven-isolated set.
`bin/fm-test-run.sh` used to carry its own hand-maintained copy of that list, which is what actually decided CI shard membership, so the document and the behavior could agree only by luck.

## The freshness model

An isolation proof is a measurement, and a measurement is only about the thing that was measured.
Each proven subject therefore binds to its own bytes and to the named material dependencies its isolation claim rests on, and `bin/fm-test-run.sh --check-coverage` refuses when any of them has moved.
`bin/fm-test-isolation-lib.sh`'s header is the single owner of that model - what is bound, what is deliberately not bound, and the precedence between a stale finding and an unobservable one.
Read it before changing what a proof means.

| Binding | Recorded as | On change |
|---|---|---|
| The subject's own bytes | per-subject `digest` | that subject is `STALE` |
| Fixture identity: the shared `tests/` harness files it loads | per-subject `fixtures[]` with digests | that subject is `STALE` |
| Runner semantics and sandbox layout | `isolation_contract.digest` | the whole proof is `STALE` |
| The concurrency the proven set is actually run at | `lane_concurrency`, checked against `concurrency` | the whole proof is `STALE` |
| Shared-state surfaces the subject touches | per-subject `shared_state[]` | recorded evidence; its freshness rides on the two digests above |

The runner-semantics binding is precise about its subject: the contract digest binds the isolation contract in `bin/fm-test-isolation-lib.sh`, which the proof harness builds every worker sandbox from.
`bin/fm-test-run.sh --jobs` implements the same contract from its own copy of the values.
The two sets of values are identical today, but the digest does not cover that second copy, so a future change to only the runner's copy would not make the proof stale.
This is a known gap - the binding covers the sandboxes the proof measured, not every runner of the proven set.

Repository state at large is deliberately not a binding.
An unrelated file moving does not invalidate anything, which is why nothing digests a whole workflow file or a tree hash: the CI lane contributes a number, its concurrency, not its bytes.

`shared_state[]` is observed statically from the subject's and its fixtures' bytes.
It names the shared surfaces the code references and cannot prove that a surface is never reached at run time.

## When a proof goes stale

Editing a proven test is normal and expected.
It makes that subject's proof stale, and the repair is to measure it again:

```sh
bin/fm-test-isolation-proof.sh --jobs 4 --json docs/fm-test-isolation-proof.json
bin/fm-test-run.sh --check-coverage
```

Re-measuring means running the subjects again.
There is no path anywhere in this module that stamps a fresh digest onto an existing record, and adding one would recreate exactly the failure this artifact was rebuilt to prevent.
`bin/fm-test-run.sh`'s serial-lane budget carries the same lesson from a sibling incident, and its comment cross-references this one.

The harness run currently takes about eleven minutes and must be allowed to finish; a run cut short writes no artifact and changes nothing.

One run is the whole procedure, whichever subject moved.
`bin/fm-test-isolation-proof.sh` executes every candidate first, publishes only from a run that observed every one of them good, and then asks `bin/fm-test-run.sh --check-coverage` whether the artifact it just wrote is accepted.
A run with a failed or unmeasured subject prints `FM_ISOLATION_ARTIFACT WITHHELD`, exits non-zero, and leaves the previous genuine artifact byte-identical.
That is not tolerance in reverse: the measured failure stays a failure, and the fix is the subject, not a second pass.

A proof also goes stale when the default branch changes a proven subject, because pull request CI checks the merge of the branch into that branch.
The branch that changed the subject owns the re-measurement; a branch that merely merges it re-measures when it takes the change.

`--check-coverage` answers three-valued, and could-not-observe is never a pass.

| Exit | Verdict | Meaning |
|---:|---|---|
| 0 | ok | Every lane invariant holds and the proof is current for this code. |
| 1 | refused | A lane invariant broke, or a subject, fixture, contract, or concurrency binding moved. |
| 3 | could-not-observe | The proof, a subject, a fixture, the digest tool, or the CI lane inventory could not be read, or the proof records no passing subject. |

An unreadable proof - and a readable proof in which no recorded subject passed - is could-not-observe rather than an empty proven set.
An empty set would silently reroute every proven script into the serial lane and still read as a successful selection.

## The two-pass claim this document used to make

This section is kept because it is adverse evidence, not because the behavior still exists.

An earlier version of this file said that when the stale subject is `tests/fm-test-run.test.sh`, two runs converge: the first leaves that subject recorded failing, and the second, started with that artifact installed, measures the whole set green.
That was false, and it was measured false on 2026-08-24 against canonical `main` at `1f2141ad`.

`tests/fm-test-run.test.sh` was a proof subject that asserted `--check-coverage` reports `FM_TEST_COVERAGE ok` and `FM_ISOLATION_FRESHNESS PROVEN` for the repository it runs in.
So it required the installed proof to already classify itself current, while producing a current proof required it to pass.
Starting from a genuine `subjects=24 proven=24` artifact and appending one hunk to that file:

```
after the edit   FM_ISOLATION_FRESHNESS STALE subjects=24 proven=23 stale=1
pass 1           FM_ISOLATION_SUMMARY total=24 failed=1     tests/fm-test-run.test.sh exit=1
                 failed on: coverage guard: the isolation proof is STALE for this code
                 artifact replaced with a 23-subject proof; --check-coverage rc=1
pass 2           FM_ISOLATION_SUMMARY total=24 failed=1     tests/fm-test-run.test.sh exit=1
                 failed on: shard union must equal proven-isolated set
                 artifact still 23 subjects; --check-coverage rc=1
```

The second pass failed for a different reason than the first and reached the same place.
No further pass changes it, because each pass reproduces its own precondition.

`docs/architecture.md` names the class under EVIDENCE_GENERATION_WELL_FOUNDEDNESS: a subject may not require, as a passing precondition, the current acceptance artifact its own passing produces.
The repair was made in the two owners that already existed, and both halves are needed.

`tests/fm-test-run.test.sh` no longer consults proof FRESHNESS at all.
It still reads the artifact - a prior genuine proof is an ordinary committed input - but nothing in it requires that artifact to be current for its own bytes.
The `--check-coverage` cases moved to `tests/fm-test-isolation-proof.test.sh`, which is excluded from the candidate set and is therefore not a subject of the proof whose consumption it asserts.
That file also holds the real-seam assertion: the production runner consumes the canonical artifact and finds it current.

`bin/fm-test-isolation-proof.sh` no longer publishes a partial measurement.
Without that half the cycle survives in a new form: the run would fail the subject, publish nothing, and stall at a different fixed point.
Without the first half, publishing correctly is not enough either, because the subject would still be failed by the stale artifact it was about to replace.
`bin/fm-test-isolation-lib.sh`'s `fm_isolation_artifact_refusal` owns the publish decision, and its writer renames a completed document over the destination so a write that dies partway leaves the last genuine artifact intact.

## Verification

- Date: 2026-09-01
- Command: `bin/fm-test-isolation-proof.sh --jobs 4 --json docs/fm-test-isolation-proof.json`
- Artifact: `run_id fm-isolation-1788304310886-2582278`
- Result, one pass, exit 0:

```
FM_ISOLATION_SUMMARY total=26 failed=0 concurrency=4 duration_ms=499012
FM_ISOLATION_ARTIFACT WRITTEN path=docs/fm-test-isolation-proof.json subjects=26 candidates=26
FM_ISOLATION_SEAM PROVEN consumer=bin/fm-test-run.sh check=--check-coverage
```

- Consumer: `bin/fm-test-run.sh --check-coverage` then exits 0 and reports
  `FM_ISOLATION_FRESHNESS PROVEN subjects=26 proven=26 stale=0 unobservable=0 dependencies_stale=0 dependencies_unobservable=0`
  followed by `FM_TEST_COVERAGE ok total=173 parallel=26 serial=136 serial_shards=8 herdr=11 proven=26`.
- `bin/fm-test-isolation-proof.sh --list` and `--list-proven` are identical, so the artifact enumerates the exact candidate universe and records only subjects that actually passed.

### The withheld-artifact control

Measured 2026-08-24 on a disposable clone with one real semantic regression injected into `bin/fm-test-run.sh` (`is_proven_isolated_script` made to accept every script), so the failure is a genuine runner defect rather than the self-reference:

```
artifact sha256 before  63a7e87d05bf5deb862a095947b7785c75a7b02092fc0b12a4dc999d86c73c66
FM_ISOLATION_SUMMARY total=24 failed=1 concurrency=4 duration_ms=146849
FM_ISOLATION_CANDIDATE_END tests/fm-test-run.test.sh exit=2
FM_ISOLATION_ARTIFACT WITHHELD path=... reason=subject-not-observed-good candidates=24 failed=1
artifact sha256 after   63a7e87d05bf5deb862a095947b7785c75a7b02092fc0b12a4dc999d86c73c66
harness exit 1; --list-proven still 24, the previous genuine set
```

The regression reddened the suite, the run published nothing, and the last genuine artifact was byte-identical afterwards.
That is the control for both "a real runner regression keeps its subject out of the proven set" and "a run that did not observe everything good never replaces the evidence".

Whole-file replacement in `fm_isolation_write_proof` is what extends the same protection to a write killed partway.
`tests/fm-test-isolation-proof.test.sh` pins the failure path - a write that cannot complete leaves the destination byte-identical and no partial document beside it - but a mid-`json.dump` crash is prevented by construction (`os.replace`) rather than by an injected fault, and that limit is stated rather than implied.

### Drift, at the 2026-08-19 measurement

Drift measured against the previous proof (`run_id fm-isolation-1785367157179-18165`, taken 2026-07-29T23:21:46Z) at the moment this one was recorded:

```
total=24  changed_after_proof=17  unchanged=7
```

The audit that prompted this work measured 14 of 24 on 2026-08-18; three more subjects moved before the repair landed.
The number is not the finding.
The finding is that it was derivable only by hand from `git log`, because the evidence recorded no per-subject content digest and no consumer could compare one.

## Scope

Each worker runs under the contract `bin/fm-test-isolation-proof.sh --print-contract` prints: a private mode-`0700` sandbox root, `TMPDIR` and `TMP` pointed only at it, ambient `FM_HOME` and `FM_*_OVERRIDE` cleared, global Git configuration snapshotted before and after, the repository root shared as the working directory, and no retry.
Those values are the same variables the sandbox is built from, so the contract digest tracks the semantics rather than the bytes of the file that happens to hold them.

A candidate that fails under concurrency fails the aggregate run and requires investigation rather than a retry.
A candidate whose sandbox could not be built to contract is recorded unmeasured, not failed, and stays out of the proven set.

## Commands

```sh
bin/fm-test-isolation-proof.sh --list             # candidates: the input to a proof run
bin/fm-test-isolation-proof.sh --list-proven      # proven set: its output, and what CI consumes
bin/fm-test-isolation-proof.sh --print-contract
bin/fm-test-isolation-proof.sh --check-freshness
bin/fm-test-run.sh --check-coverage
```
