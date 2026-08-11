# Availability observation verification

Audience: maintainer verification.

This record supports the three-valued availability observation in `bin/fm-availability-lib.sh`, the per-harness probe command shapes in `bin/fm-model-verify.sh`, and the exclusion routing applies to a failed observation in `bin/fm-route-lib.sh`.
It records only facts that must be re-established when a harness, a provider response, or the observation type changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

## What each recorded value asserts

`AVAILABLE` and `UNAVAILABLE` are answers about the candidate; `UNOBSERVABLE` is an answer about the instrument.
Routing excludes the second and the third, and only the third names a reader to repair.
`docs/configuration.md` "Model observation record" owns the schema; the mapping from probe shape to observation is owned by `bin/fm-availability-lib.sh` and mirrored in `.agents/skills/model-onboarding/SKILL.md`'s response-shape table.

## Probe command shapes

Harness-dependent: the verdict comes from what a vendor CLI emits, so a fake harness can confirm only the assumption written into the fake.
Refresh with `FM_MODEL_PROBE_LIVE_E2E=1 bash tests/fm-model-probe-live-e2e.test.sh`, which is the command that re-establishes every row below.
Run it after every harness upgrade; the guard reports an absent harness explicitly and refuses a pass that checked nothing.

Verified 2026-08-11.

| Harness | Version | Command shape | Model probed | Observation | Latency |
|---|---|---|---|---|---|
| `claude` | 2.1.227 (Claude Code) | `claude -p --model <id> --strict-mcp-config <prompt>` | `claude/opus` | `AVAILABLE` | 5s |
| `pi` | 0.81.1 | `pi -p --provider <p> --model <id> --no-tools --no-session --thinking off <prompt>` | `openai-codex/gpt-5.6-sol` | `AVAILABLE` | under the 25s probe ceiling |

A harness with no arm in `probe_one` records `unprobeable`, which is `UNOBSERVABLE`.
That was `claude`'s state before 2026-08-11, and it is why every claude-routed model carried a could-not-observe while the account was entitled and the model was live.

The failure direction is loud rather than silent: a command shape that stops working exits non-zero with output the classifier does not recognise, which reaches `unclassified` by its default arm, becomes `UNOBSERVABLE`, and files a `TOOLING_GAP` naming the reader.
Verified 2026-08-11 by replacing `--strict-mcp-config` with an unknown flag: the live guard failed with `claude (2.1.227 (Claude Code)): the probe command shape no longer works - claude/opus recorded UNOBSERVABLE (unclassified: error: unknown option '--not-a-real-flag')`.

## Timing discriminator

Verified 2026-08-11: the `claude` probe of `claude/opus` returned in 5s, a server round trip.
`.agents/skills/model-onboarding/SKILL.md` records that a client-side failure returns in well under a second while a server-side refusal takes seconds, which is what keeps a local configuration error from being recorded as a provider outage.
The mapping enforces the same separation independently of duration: `client-error` is `UNOBSERVABLE` by classification, not by stopwatch.

## Recurrence closure

The recurrence probe tests the mechanism rather than the symptom, and is proven red-capable rather than assumed to be.
`tests/fm-availability-observation.test.sh` reintroduces each half of the permitting mechanism in a controlled copy of `bin/` and requires the probe to fail against it; a mutation that failed to change behaviour fails the case loudly instead of reporting a probe that can never go red.

Verified 2026-08-11 by three further controlled mutations of the shipped files, each restored immediately afterwards:

| Reintroduced mechanism | Result |
|---|---|
| a could-not-observe mapped to `AVAILABLE` | red |
| routing stops excluding on a failed observation | red |
| the record's absent numeric fields written as consecutive tabs | red, reproducing the original `rc=pi is not installed on this machine, so the reader could not run, -s) - .` shift |

The last row is the measured defect itself: tab is an IFS whitespace character, so `read` folds a run of consecutive tabs into one delimiter and the reason arrives in the wrong field.

Verified 2026-08-11 with `bash tests/fm-availability-observation.test.sh`.
The command passed every deterministic mapping, fail-closed routing, repairable `TOOLING_GAP`, non-empty reason, and red-capable recurrence case.

## Runtime evidence as a second source

Not built, and `bin/fm-availability-lib.sh`'s header owns the reason.
The short form: `state/<id>.meta` and `data/wake-ledger.tsv` record the bare harness alias rather than the registry key, `config/models.json` records that the alias binding moves when the harness updates, and no record carries a per-invocation served-at timestamp.
Identity, freshness, and scope therefore all fail, so a positive availability fact comes from a probe or from nowhere.
