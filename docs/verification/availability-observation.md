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

Verified 2026-08-12.

| Harness | Version | Command shape | Model probed | Observation | Latency |
|---|---|---|---|---|---|
| `claude` | 2.1.228 (Claude Code) | `claude -p --model <id> --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools '' --disallowed-tools <list> --no-session-persistence --agents '{}' --system-prompt <prompt> <prompt>`, run in an empty directory | `claude/opus` | `AVAILABLE` | 3s |
| `pi` | 0.81.1 | `pi -p --provider <p> --model <id> --no-tools --no-session --thinking off <prompt>`, run in an empty directory | `openai-codex/gpt-5.6-sol` | `AVAILABLE` | 7s |

A harness with no arm in `probe_one` records `unprobeable`, which is `UNOBSERVABLE`.
That was `claude`'s state before 2026-08-11, and it is why every claude-routed model carried a could-not-observe while the account was entitled and the model was live.

The failure direction is loud rather than silent: a command shape that stops working exits non-zero with output the classifier does not recognise, which reaches `unclassified` by its default arm, becomes `UNOBSERVABLE`, and files a `TOOLING_GAP` naming the reader.
Verified 2026-08-11 by replacing `--strict-mcp-config` with an unknown flag: the live guard failed with `claude (2.1.227 (Claude Code)): the probe command shape no longer works - claude/opus recorded UNOBSERVABLE (unclassified: error: unknown option '--not-a-real-flag')`.

## The probe's isolation boundary

A probe answers "does this provider serve this model to this account", and every ambient input is either a way to get a wrong answer or a way for a probe to have a side effect.
Each probe therefore runs in a freshly created empty directory that is removed afterwards, so no project instructions, project settings, hooks, or repository contents are in scope, and the session-identity environment variables of the calling agent are unset.
`--setting-sources ''` is the flag that matters most, because user, project and local settings are where hooks live; `claude --setting-sources bogus --version` rejects an unknown source while the empty value is accepted, which is what establishes that an empty list means no sources rather than a silently ignored flag.
`--strict-mcp-config` with an empty `--mcp-config` loads no MCP servers, `--tools ''` disables every built-in tool, `--disallowed-tools` denies known tools by name as a second layer, `--no-session-persistence` leaves no session behind, and `--agents '{}'` loads no subagents.

The boundary is observed rather than assumed, and observing it costs no live request: `tests/fm-availability-observation.test.sh` launches a fake harness that records its working directory, argument vector and environment, from a project directory carrying a `CLAUDE.md`, a settings hook and a secret, and asserts that none of them was in scope.
A flag this CLI stops accepting turns the probe into a client error, which is `UNOBSERVABLE` and a tooling gap - loud, and never a false positive about the model.

## What the record has to satisfy to be read at all

Parseability is not validity, and the difference is a fail-open defect class rather than a detail.
The reader originally recovered from unparseable JSON only, so a file that was valid JSON with a wrong or absent schema succeeded as an EMPTY exclusion set: every recorded could-not-observe disappeared and every candidate it was excluding became eligible again, in the function whose whole purpose is to fail closed.

`bin/fm-availability-lib.sh` now verifies the schema string, that `models` is an object, that every entry is an object whose `observation` is inside the closed vocabulary, that the evidence strings are non-empty and free of control characters, that an `UNOBSERVABLE` entry carries a complete `tooling_gap` block with a status matching its backlog item under the owning reason code, and that no other entry carries one.
Anything short of that is a could-not-observe about the record itself, reported with the reason so it can be repaired rather than guessed at, and it refuses under `FM_ROUTE_OBSERVATION_UNREADABLE` rather than re-admitting anything.
An absent file remains an empty exclusion set, because absence means no attempted observation has failed - which is never a claim that anything is healthy.

## Two records, one fact, and what happens when they come apart

An established unavailability writes two records: an observation here, and a hold in `state/model-health.json` through its supported writer.
An invariant that holds only when both writes succeed is not an invariant, so the fail-closed hold is written first, and routing additionally excludes on a recorded `UNAVAILABLE` observation that has no hold beside it, refusing under `FM_SPAWN_ROUTE_MODEL_UNAVAILABLE_UNHELD` and naming the missing half.

Because that exclusion is independent, `bin/fm-route.sh availability release` retires the `UNAVAILABLE` observation it overrides, and says which entries it retired.
Without that, releasing the hold would leave the candidate excluded by a record the operator was never shown and the supported release command would quietly stop working.
A release never retires an `UNOBSERVABLE` entry: releasing repairs nothing about a broken reader, the refusal says so in those words, and letting a release clear one would turn "repair observability" back into "work around uncertainty".

## Evidence hygiene

Probe evidence is text a remote service or a vendor CLI produced, and it reaches both an operator's terminal and a durable record other tools read back.
It is sanitized where it first enters the fleet's records: C0 control characters and DEL are removed so an ANSI escape cannot rewrite the lines around a refusal, tab, newline and carriage return become spaces so the wire format's fields survive, known credential shapes and the generic `<secret-ish name> = <value>` form are replaced by `[redacted]`, and the result is bounded to 600 characters including its truncation marker so the operation is idempotent.
Because the record's read-time contract rejects control characters outright, every consumer can print a stored field directly.

## Timing discriminator

Verified 2026-08-12: the `claude` probe of `claude/opus` returned in 3s and the `pi` probe of `openai-codex/gpt-5.6-sol` in 7s, both server round trips.
`.agents/skills/model-onboarding/SKILL.md` records that a client-side failure returns in well under a second while a server-side refusal takes seconds, which is what keeps a local configuration error from being recorded as a provider outage.
The mapping enforces the same separation independently of duration: `client-error` is `UNOBSERVABLE` by classification, not by stopwatch.

## Recurrence closure

The recurrence probe tests the mechanism rather than the symptom, and is proven red-capable rather than assumed to be.
`tests/fm-availability-observation.test.sh` reintroduces each half of the permitting mechanism in a controlled copy of `bin/` and requires the probe to fail against it; a mutation that failed to change behaviour fails the case loudly instead of reporting a probe that can never go red.

Five permitting mechanisms are reintroduced in controlled copies and each must turn a probe red.
The first three are the original collapse; the last two are fail-open defects found in this change itself by an independent design review, which is why they are controlled the same way rather than merely fixed.

| Reintroduced mechanism | Result |
|---|---|
| a could-not-observe mapped to `AVAILABLE` | red |
| a could-not-observe mapped to `UNAVAILABLE` | red |
| routing stops excluding on a failed observation | red |
| the reader recovers a parseable-but-invalid record into an empty exclusion set | red |
| eligibility computed from the hold alone, so an observed unavailability with no hold is eligible | red |
| a two-branch consumer whose default arm records `AVAILABLE` | red |

The exhaustive-consumer control injects the same fault on both sides - a map returning a value the type does not define - and differs only in the consumer, so it isolates the exhaustiveness rule rather than the map.

Verified 2026-08-11 by a further controlled mutation of the shipped files, restored immediately afterwards:

| Reintroduced mechanism | Result |
|---|---|
| the record's absent numeric fields written as consecutive tabs | red, reproducing the original `rc=pi is not installed on this machine, so the reader could not run, -s) - .` shift |

That row is the measured defect itself: tab is an IFS whitespace character, so `read` folds a run of consecutive tabs into one delimiter and the reason arrives in the wrong field.

Verified 2026-08-12 with `bash tests/fm-availability-observation.test.sh`.
The command passed every deterministic mapping, fail-closed routing, repairable `TOOLING_GAP`, non-empty reason, record-integrity, paired-record, isolation, evidence-hygiene, and red-capable recurrence case.

## A probe that never returned

A probe killed by the sweep's total ceiling records `timeout`, which is `UNOBSERVABLE`, and files a tooling gap like any other failed reader.
The alternative - leaving an unfinished probe with no result at all - is a could-not-observe that nothing records, which is the same collapse one level down and the one place a sweep could report having observed more than it did.
The consequence is deliberate and worth stating: a provider slow enough to exceed the ceiling excludes its candidate until the next sweep re-probes it, and on a single-candidate pool that stops the route.
That is the fail-closed direction, and the repair is the ceiling or the provider, never a permissive default.

## Runtime evidence as a second source

Not built, and `bin/fm-availability-lib.sh`'s header owns the reason.
The short form: `state/<id>.meta` and `data/wake-ledger.tsv` record the bare harness alias rather than the registry key, `config/models.json` records that the alias binding moves when the harness updates, and no record carries a per-invocation served-at timestamp.
Identity, freshness, and scope therefore all fail, so a positive availability fact comes from a probe or from nowhere.
