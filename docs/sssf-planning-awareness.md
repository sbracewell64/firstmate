# SSSF planning-transition awareness

Implementation identity: **FM-FP-001** — FirstMate consumer half of SSSF FUT-003.

FirstMate can consume Browser-Sol-managed SSSF planning promotions through one registered custom check. The feature deliberately reuses `fm-watch.sh`; it does not add another daemon, scheduler, event loop, or planning authority.

## Owner

`bin/fm-sssf-planning-check.sh`

Agent handling procedure:

`.agents/skills/sssf-planning-awareness/SKILL.md`

Focused regression owner:

`tests/fm-sssf-planning-awareness.test.sh`

## Source contract

The producer is the SSSF planning feed:

`docs/development/PLANNING_EVENTS.jsonl`

Schema:

`sssf-planning-event/v1`

The feed is a notification index only. Each event binds planning truth with:

- `source_commit` — exact authoritative SSSF commit;
- `authoritative_refs` — exact planning/increment paths;
- `authoritative_blobs` — exact Git blob ID expected for every authoritative path at that commit.

The branch/ref containing the feed is only transport. It never substitutes for those immutable source identities.

## Installation

Installation is explicit because choosing the source repository/ref is configuration and because this feature must not become live merely by landing code:

```sh
bin/fm-sssf-planning-check.sh install \
  --repo sbracewell64/inkwell-agent-sandboxes-and-software-factory \
  --ref <accepted-planning-ref>
```

The command:

1. writes private `state/sssf-planning.source`;
2. copies the exact consumer bytes to `state/sssf-planning.check.sh`;
3. protects the check at mode `0700`;
4. registers its SHA-256 through the existing `bin/fm-check-register.sh` trust path.

The watcher therefore runs a hash-bound private snapshot of the registered bytes under its existing bounded custom-check process owner.

No source is installed or enabled automatically by the repository merely containing this program.

## Detection lifecycle

The check resolves the configured GitHub ref to one immutable feed commit first, then reads the named feed at that exact commit. This prevents a branch from moving between ref resolution and feed retrieval.

The private cursor records:

- exact byte offset;
- SHA-256 of the exact feed prefix through that offset;
- last handled event ID;
- mechanically derived planning-state map;
- last observed immutable feed commit.

The initial `snapshot` is independently validated against its exact `source_commit`, each authoritative path, and each expected Git blob identity, then consumed silently. It creates no pending event.

A later valid transition is captured into `state/sssf-planning.pending.json` **without advancing the cursor**. This makes a crash after capture replayable. The watcher surfaces only a bounded typed index such as:

```text
SSSF_PLANNING_EVENT pending plan-20260818-0042 awareness FUT-010 DECIDED <sha> -
```

or:

```text
SSSF_PLANNING_EVENT pending plan-20260818-0043 engineering FUT-010 ACTIVE <sha> FP-010
```

Until acknowledged, the pending event is surfaced again on later check cycles. The current feed prefix through the pending event is rechecked before replay, so a history rewrite while an event is pending becomes a continuity failure rather than a stale replay.

Acknowledgement advances the cursor only after handling. A private receipt makes an interrupted/retried acknowledgement distinguishable from a new effect.

## Actionability

The consumer independently enforces:

- snapshot -> `baseline`;
- transition to `ACTIVE` -> `engineering` plus concrete increment;
- every other transition -> `awareness`.

`engineering` is **normal intake eligibility only**. The event itself never launches work and cannot waive admission, task identity, project posture, source custody, budgets, security constraints, validation, review, provenance, or landing gates.

The handling skill owns the semantic step after the typed wake. It requires exact-source reading and ordinary FirstMate intake before `ack ... intake` is valid.

## Exact-source validation

Before a snapshot or transition is accepted, the consumer verifies through GitHub that:

- `source_commit` resolves exactly;
- every `authoritative_refs` path resolves as a file at that exact commit;
- the observed Git blob ID for each path equals `authoritative_blobs[path]` exactly;
- the blob map contains every ref and no unrelated ref;
- paths remain under `docs/` with no traversal;
- state transitions agree with the private state map;
- event IDs strictly advance;
- `ACTIVE` references its named `docs/increments/<increment-id>...` record.

These remote reads are single-object/single-file observations, not paginated collection negatives, and are classified accordingly for FirstMate's retrieval audit.

The producer and consumer therefore validate independently. SSSF's shallow/offline producer CI proves the closed immutable witness structure; FirstMate re-observes the witness against GitHub before accepting it. Neither side treats the other's green as its own observation.

## Continuity failure

If the current feed is shorter than the cursor offset, its historical prefix hash changed, or a captured pending prefix changes before acknowledgement, the check emits:

```text
SSSF_PLANNING_CONTINUITY_BROKEN
```

It does not delete or reset the cursor. Silent rebasing would turn rewritten planning history into apparently continuous authority, so rebaseline requires an explicit separate decision.

## Other typed failures

The check uses a closed output vocabulary for transport problems:

- `SSSF_PLANNING_CONFIG_INVALID`
- `SSSF_PLANNING_TOOLING_GAP`
- `SSSF_PLANNING_COULD_NOT_OBSERVE`
- `SSSF_PLANNING_FEED_TOO_LARGE`
- `SSSF_PLANNING_EVENT_INVALID`
- `SSSF_PLANNING_CONTINUITY_BROKEN`
- `SSSF_PLANNING_CONSUMER_FAILED`

Repeated identical transport failures are rate-bounded by a private episode marker. Valid pending events are not suppressed by that marker because they must remain replayable until acknowledged.

## Operator commands

```sh
bin/fm-sssf-planning-check.sh status
bin/fm-sssf-planning-check.sh show <event-id>
bin/fm-sssf-planning-check.sh ack <event-id> awareness
bin/fm-sssf-planning-check.sh ack <event-id> intake
bin/fm-sssf-planning-check.sh retire
```

`retire` removes the active check, trust/config/cursor/pending state and preserves historical acknowledgement receipts.

## Rollback

Retiring the check restores the pre-bridge behavior: FirstMate no longer receives automatic SSSF planning notifications. It does not change the SSSF planning documents or their authority.

## FM-FP-001 acceptance

The implementation candidate must prove at least:

- bootstrap snapshot is silent and creates no pending work;
- awareness remains replayable until awareness acknowledgement;
- ACTIVE is mechanically distinct and accepts only intake acknowledgement;
- non-ACTIVE engineering actionability is rejected;
- malformed/stale events advance nothing;
- historical prefix rewrite/truncation refuses without reset;
- exact source commit and exact path/blob identities are independently re-observed;
- registered-check byte tampering is rejected by existing trust machinery;
- no change to `fm-watch.sh` is required;
- the new check/test remains inside FirstMate's normal lint, retrieval, regression partition, review, and provenance gates.

## Acceptance boundary

The consumer is not production-enabled merely because this code lands or its focused tests pass. Live installation should occur only after:

1. the producer feed is accepted on the intended SSSF source ref;
2. this branch is rebased on the settled FirstMate watcher/custom-check surface;
3. focused and repository-required tests pass on the exact candidate;
4. normal independent review and exact-head no-mistakes provenance gates pass;
5. the configured source ref is explicitly selected for live use.

Until then, FM-FP-001 remains an implementation candidate and PR #118 remains a draft hold surface.
