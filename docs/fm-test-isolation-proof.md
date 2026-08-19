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

`--check-coverage` answers three-valued, and could-not-observe is never a pass.

| Exit | Verdict | Meaning |
|---:|---|---|
| 0 | ok | Every lane invariant holds and the proof is current for this code. |
| 1 | refused | A lane invariant broke, or a subject, fixture, contract, or concurrency binding moved. |
| 3 | could-not-observe | The proof, a subject, a fixture, the digest tool, or the CI lane inventory could not be read. |

An unreadable proof is could-not-observe rather than an empty proven set.
An empty set would silently reroute every proven script into the serial lane and still read as a successful selection.

## Verification

- Date: 2026-08-19
- Command: `bin/fm-test-isolation-proof.sh --jobs 4 --json docs/fm-test-isolation-proof.json`
- Result: `FM_ISOLATION_SUMMARY total=24 failed=0 concurrency=4 duration_ms=298803`
- Consumer: `bin/fm-test-run.sh --check-coverage` then reports
  `FM_ISOLATION_FRESHNESS PROVEN subjects=24 proven=24 stale=0 unobservable=0 dependencies_stale=0 dependencies_unobservable=0`
  followed by `FM_TEST_COVERAGE ok total=169 parallel=24 serial=134 serial_shards=8 herdr=11 proof_fresh=24`.

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
