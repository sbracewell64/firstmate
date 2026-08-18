# SSSF planning-transition awareness

FirstMate can consume Browser-Sol-managed SSSF planning promotions through one registered custom check. The feature deliberately reuses `fm-watch.sh`; it does not add another daemon, scheduler, event loop, or planning authority.

## Owner

`bin/fm-sssf-planning-check.sh`

Agent handling procedure:

`.agents/skills/sssf-planning-awareness/SKILL.md`

## Source contract

The producer is the SSSF planning feed:

`docs/development/PLANNING_EVENTS.jsonl`

Schema:

`sssf-planning-event/v1`

The feed is a notification index only. The event's `source_commit` and `authoritative_refs` identify the planning truth FirstMate must read.

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

The check resolves the configured GitHub ref to one immutable commit first, then reads the feed at that exact commit. This prevents a branch from moving between ref resolution and feed retrieval.

The private cursor records:

- exact byte offset;
- SHA-256 of the exact feed prefix through that offset;
- last handled event ID;
- mechanically derived planning-state map;
- last observed immutable feed commit.

The initial `snapshot` is validated against its exact source commit/references and consumed silently. It creates no pending event.

A later valid transition is captured into `state/sssf-planning.pending.json` **without advancing the cursor**. This makes a crash after capture replayable. The watcher surfaces only a bounded typed index such as:

```text
SSSF_PLANNING_EVENT pending plan-20260818-0042 awareness FUT-010 DECIDED <sha> -
```

or:

```text
SSSF_PLANNING_EVENT pending plan-20260818-0043 engineering FUT-010 ACTIVE <sha> FP-010
```

Until acknowledged, the pending event is surfaced again on later check cycles. Acknowledgement atomically advances the cursor and writes a private receipt before removing the pending event; an interrupted acknowledgement can be retried.

## Actionability

The consumer independently enforces:

- snapshot -> `baseline`;
- transition to `ACTIVE` -> `engineering` plus concrete increment;
- every other transition -> `awareness`.

`engineering` is **normal intake eligibility only**. The event itself never launches work and cannot waive admission, task identity, project posture, source custody, budgets, security constraints, validation, review, provenance, or landing gates.

## Exact-source validation

Before a snapshot or transition is accepted, the consumer verifies through GitHub that:

- `source_commit` resolves exactly;
- every `authoritative_refs` path resolves as a file at that commit;
- paths remain under `docs/` with no traversal;
- state transitions agree with the private state map;
- event IDs strictly advance;
- `ACTIVE` references its named `docs/increments/<increment-id>...` record.

The producer and consumer therefore validate independently. A producer-side green is not trusted as the consumer's observation.

## Continuity failure

If the current feed is shorter than the cursor offset or its historical prefix hash changed, the check emits:

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

## Acceptance boundary

The consumer is not production-enabled merely because this code lands or its focused tests pass. Live installation should occur only after:

1. the producer feed is accepted on the intended SSSF source ref;
2. this branch is rebased on the settled FirstMate watcher/custom-check surface;
3. focused and repository-required tests pass on the exact candidate;
4. normal independent review/provenance gates pass;
5. the configured source ref is explicitly selected for live use.
