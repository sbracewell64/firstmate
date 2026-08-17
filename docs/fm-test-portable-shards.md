# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

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

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

`portable-serial-<k>of<n>` splits the remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
A script with no hint gets the `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default, set to the measured per-script mean.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.

### Declared budget and where the numbers come from

The lane budget, the shard count, and the drift bounds are all derived rather than chosen, and `bin/fm-test-run.sh` is their single owner.
State the basis whenever any of them is re-derived, because the number on its own cannot tell the next reader whether it still describes reality.

Current basis, 2026-08-17.
Measured on this repository's own main-push runs [32044341699](https://github.com/sbracewell64/firstmate/actions/runs/32044341699) and [32046031290](https://github.com/sbracewell64/firstmate/actions/runs/32046031290), whose portable-serial inventory matched that head's 122 scripts exactly.
Their per-shard timing artifacts summed to 2398034 ms and 2335349 ms of script time; the declared budget is the mean, 2366725 ms (~39.4 min).
Job wall exceeded script sum by under 10 s on every shard, so a shard's wall is its script sum for budgeting purposes.

The previous basis was 2026-08-02: 69 scripts and 1143762 ms (~19.1 min), which put four balanced shards at ~4.8 min.
The lane did not drift within that budget, it grew to 2.07x of it, so the budget is re-derived from what the suite now is rather than restored to what it used to be.

Growth alone is not what cancelled runs; growth plus a blind balancer is.
At the point of failure the hint table covered 68 of 122 scripts and the other 54 carried a flat default, so the packer predicted four evenly loaded 9.26-minute shards while the lane actually ran 8.06, 14.61, 8.79 and 8.06 minutes.
Shard 2 reached the 15-minute cap and cancelled whole runs.
Individually stale hints ran to 13.7x (`tests/fm-fleet-snapshot-view.test.sh` was hinted 5902 ms and measured 81131 ms).
Rebalancing alone would have landed every shard near 9.9 minutes, still only ~1.5x under the cap, which is why the shard count moved too.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-serial-1of8` | 14 | 295836 ms (~295.8 s) |
| `portable-serial-2of8` | 12 | 295836 ms (~295.8 s) |
| `portable-serial-3of8` | 15 | 295846 ms (~295.8 s) |
| `portable-serial-4of8` | 17 | 295836 ms (~295.8 s) |
| `portable-serial-5of8` | 17 | 295833 ms (~295.8 s) |
| `portable-serial-6of8` | 15 | 295852 ms (~295.8 s) |
| `portable-serial-7of8` | 17 | 295840 ms (~295.8 s) |
| `portable-serial-8of8` | 15 | 295846 ms (~295.8 s) |
| imbalance | | 19 ms |

Eight shards put the balanced wall at ~4.93 min against the unchanged 15-minute cap, which is the ~3x hang-tripwire margin the cap was chosen for.
The single longest script, `tests/fm-pr-check-security.test.sh` at 216161 ms (~3.60 min), is the floor for any shard count and binds near ten shards.

Refresh the hints and the budget together from the per-shard timing artifacts of a green run **on this repository's own lineage**, whose serial inventory matches the head being measured.
Artifacts from a fork or upstream with a different test inventory describe a different lane and must not be transferred in.

```sh
gh run download <run-id> -R sbracewell64/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

Replace the `portable_serial_weight_hints` table with the measured pairs, re-derive `PORTABLE_SERIAL_BUDGET_MS` and the shard count in `bin/fm-test-run.sh`, and update the basis and the table above.

## Serial budget recurrence control

`bin/fm-test-run.sh --check-budget <lane.json>...` judges the serial lane a run actually executed against the declared budget, and `.github/workflows/ci.yml` runs it in `tests-timing-aggregate` where every lane artifact is already downloaded.
It exists because the drift above was invisible until a shard reached its cap: nothing compared the lane the suite had become against the lane its timeout was sized for.

It answers three-valued, and could-not-observe is never a pass.

| Exit | Verdict | Meaning |
|---:|---|---|
| 0 | `ok` | Within every stated bound, and the declared partition ran exactly once. |
| 1 | `drifted` | A stated bound was passed, or the run did not execute the lane this head declares. |
| 3 | `could-not-observe` | Artifacts missing, unreadable, incomplete, or built for a different shard count. |

A shard cancelled at its hang tripwire uploads no timing, so it lands on that third value rather than on either of the other two.

Two bounds, both stated against the declared budget, and both chosen so ordinary runner jitter cannot reach them:

- **Lane drift**, `PORTABLE_SERIAL_BUDGET_DRIFT_PCT` (25%), carries the semantic verdict because the lane total is the stable measurement: the two basis runs differ by 2.7% across the whole lane.
  A 25% allowance is roughly nine times that spread, so a breach means the suite grew rather than that a runner was slow.
- **Shard headroom**, `PORTABLE_SERIAL_SHARD_HEADROOM_PCT` (60% of the hang tripwire, 9 min), is compared only against the tripwire and never against the balanced wall.
  A single shard moved 11% between the same two basis runs, and this bound sits 1.83x above the ~4.93 min healthy wall.
  Per-shard jitter is therefore not a verdict, while a shard drifting toward the cap still is.

That second bound is what catches the shape of the original incident, where the lane total looked unremarkable while one shard carried the imbalance to the edge of its timeout.

A job cannot read its own `timeout-minutes`, so the workflow passes its literal through `FM_SERIAL_TIMEOUT_MINUTES` and the control refuses a value that disagrees with the one its bounds were derived against, the same way a lane name carrying the wrong shard count is refused.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

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
| portable serial 1-8 | 15 | Each balanced shard is about 4.93 minutes, leaving roughly 3x hang-tripwire margin. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
The serial cap has never been raised to accommodate growth: when the balanced wall approached it, the shard count changed so the cap kept the meaning it was chosen for.
Raising it instead would buy time by making the tripwire worse at the one thing it is for, and the recurrence control above is what makes the next approach visible while there is still margin to act on.
