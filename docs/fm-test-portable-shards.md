# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the parallel candidate set it measures; `docs/fm-test-isolation-proof.json` owns the proven-isolated set the lanes consume.

## Verification inputs

The candidate timings below came from the 2026-07-29 concurrent proof run (`run_id fm-isolation-1785367157179-18165`), which ran 24 candidates with four workers, no failures, and 149010 ms total wall time.
That run has since been superseded as the isolation proof; [fm-test-isolation-proof.md](fm-test-isolation-proof.md) owns the current verification record.
This table preserves the 2026-07-29 durations only because they are what the lane balance was derived from; the current measurements live in `docs/fm-test-isolation-proof.json`.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two-lane longest-processing-time split in `list_portable_parallel_1` and `list_portable_parallel_2` derives from the 2026-07-29 per-subject durations above, not from the current measurements.
The split is therefore known-stale for balance purposes, pending the follow-up parallel-lane-split-rebalance, which re-derives it from the current durations in `docs/fm-test-isolation-proof.json`.

| Lane | Script count | Estimated duration (2026-07-29 basis) |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

The stale split is a performance fact only, not an isolation dependency.
The two parallel lanes are separate CI jobs on separate runners, and neither passes `--jobs`, so each lane runs strictly serially and no two proven-isolated subjects are ever co-resident on one machine.
Lane placement therefore cannot change any subject's isolation outcome; it changes only which runner executes a script and in what order.
Lane concurrency, which would be such a dependency, is recorded per lane in `docs/fm-test-isolation-proof.json` and enforced by `bin/fm-test-run.sh --check-coverage`, which refuses a lane running above the proof.
A stale balance hint costs a slower shard, never lost coverage or a weakened isolation claim.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

`portable-serial-<k>of<n>` splits the remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` mirrors that count in its matrix, and the regression suite requires the matrix to contain every composed serial shard.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
A script with no hint gets the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default, rounded from the measured per-script mean.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

### Declared budget and where the numbers come from

`bin/fm-test-run.sh` is the single owner of the lane budget, associated shard count and drift bounds, current measured basis, and derived balance.
Its comments state the evidence and derivation beside the declarations so a future remeasurement updates the contract in one place.

Refresh the hints from a complete per-script duration map and refresh the budget basis from complete lane-wall totals recovered from per-shard timing artifacts of runs **on this repository's own lineage**, whose serial inventory matches the head being measured.

The basis must be PLURAL, and `PORTABLE_SERIAL_BASIS_MIN_SAMPLES` is the declared floor.
A single run cannot measure its own uncertainty, so a one-run basis cannot show that the growth threshold is separated from ordinary environmental movement, and the lane axis refuses to credit any product verdict while the basis is that thin.
Declare the budget as the mean of the qualified samples and derive the drift allowance from their measured spread; never widen the allowance to admit a sample, and never delete an adverse sample to improve the numbers.
Record every qualified lane-wall sample in `portable_serial_basis_samples()` with the run id and head that produced it, so `bin/fm-test-run.sh --check-basis` can re-derive the mean and the spread and refuse a declaration that has drifted from its own evidence.
Use per-script durations only for balance hints; use shard-wall totals for lane-budget observations and the worst-shard headroom comparison.
If an inventory change requires replacing the qualified sample table, first preserve every displaced adverse observation verbatim in the adjacent `BASIS` evidence comment; a later favourable sample must never erase it.
Artifacts from a fork or upstream with a different test inventory describe a different lane and must not be transferred in.

```sh
gh run download <run-id> -R sbracewell64/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Refuse a hint refresh unless every script in the serial inventory has exactly one recovered duration, then replace the `portable_serial_weight_hints` table wholesale with those measured pairs.
Re-derive the budget from the qualified lane-wall sample table, not by summing per-script durations.
Re-derive the shard count and bounds only when their stated sizing policies are being revisited.
A budget-and-hint refresh changes balance estimates and recurrence-control evidence only; it does not change test inventory, selection, or execution semantics.

## Serial budget recurrence control

`bin/fm-test-run.sh --check-budget <lane.json>...` judges the serial lane a run actually executed against the declared budget, and `.github/workflows/ci.yml` runs it in `tests-timing-aggregate` where every lane artifact is already downloaded.
It exists because serial-lane growth was invisible until a shard reached its cap: nothing compared the lane the suite had become against the lane its timeout was sized for.
It does not validate a changed hint table's composed partition, because historical artifacts retain the shard assignment that their run actually executed; score a hint refresh by composing the current shards and summing them against a complete measured duration map.

It answers three-valued, and could-not-observe is never a pass.

| Exit | Verdict | Meaning |
|---:|---|---|
| 0 | `ok` | Within every stated bound, and the declared partition ran exactly once. |
| 1 | `drifted` | A stated upper bound was exceeded by more than the measured spread, or the run did not execute the lane this head declares. |
| 4 | `cno` | Measurement could-not-observe: the lane sits within the declared measured spread of its threshold, or the basis is too small to calibrate the axis. Neither a pass nor a failure. |
| 3 | `could-not-observe` | Artifacts missing, unreadable, structurally invalid, incomplete, or built for a different shard count. |

The two could-not-observe values answer different questions and must not be collapsed.
Exit 3 means the evidence could not be read at all, which is an instrument defect to repair, and CI fails on it.
Exit 4 means the evidence was read correctly and the instrument cannot resolve which side of the boundary the lane is on, which is a fact about measurement resolution rather than about the candidate; CI reports it and treats the semantic axis as carrying no verdict, neither green nor red.

A shard cancelled at its hang tripwire uploads no timing, so it lands on that third value rather than on either of the other two.
Negative durations are structurally invalid evidence because they could otherwise manufacture an under-budget verdict.
The summary duration is shard wall time, so legitimate runner overhead may make it longer than the sum of its script durations.
A summary duration shorter than that sum is self-contradictory evidence and yields `could-not-observe`.

The lane-drift bound carries the semantic verdict, while shard headroom is compared only with the hang tripwire so ordinary per-shard jitter is not called a defect.
`bin/fm-test-run.sh` owns both current thresholds and their measured margins.

The lane axis is the only one the measured spread applies to, because it is the only one whose input is a wall-clock measurement on a shared hosted runner.
Whether the declared partition ran, and whether a shard is crowding its hang tripwire, are facts about what happened rather than measurements of how fast, so they keep ordinary pass/fail verdicts and a deterministic failure still outranks a measurement `cno`.
This separation exists because pull request 133 ran the same runner blob against its own unchanged inventory and landed on both sides of the then-declared bound, which proved that boundary was reporting the runner rather than the suite.
Those adverse observations are preserved in the basis comment in `bin/fm-test-run.sh`; a later favourable sample does not erase an earlier adverse one.

The shard-headroom bound detects dangerous imbalance independently of lane growth, before an overloaded shard reaches its timeout.

A job cannot read its own `timeout-minutes`, so the workflow passes its literal through `FM_SERIAL_TIMEOUT_MINUTES` and the control refuses a value that disagrees with the one its bounds were derived against, the same way a lane name carrying the wrong shard count is refused.
The regression suite locates both workflow fields within their named job structures using only Python's standard library and refuses disagreement between the timeout literal and its copied environment value.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

It is also the isolation proof's refusing consumer: it judges `docs/fm-test-isolation-proof.json` against the code that is here now and refuses a proof whose subjects, fixtures, isolation semantics, or concurrency have moved.
Editing a proven-isolated test therefore means re-measuring the proof in the same change.
[`docs/fm-test-isolation-proof.md`](fm-test-isolation-proof.md) owns that loop and the exit codes; the freshness model itself is owned by `bin/fm-test-isolation-lib.sh`'s header.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial | 15 | The workflow owns the timeout literal; the runner owns the shard count, measured basis, and hang-tripwire margin. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
The recurrence control makes serial-lane growth visible while there is still margin to act on.
