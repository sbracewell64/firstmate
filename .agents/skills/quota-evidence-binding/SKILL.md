---
name: quota-evidence-binding
description: >-
  Agent-only procedure for interpreting quota-axi evidence outside matched profile-array selection.
  Load before asserting, retaining, clearing, or reporting a provider-capacity blocker or update, including a declared-pause recheck, so one provider, entitlement, pool, model scope, or route role cannot be mislabeled as another.
user-invocable: false
metadata:
  internal: true
---

# quota-evidence-binding

Use this procedure before interpreting `quota-axi` as a blocker or update outside matched profile-array selection.
`quota-array-dispatch` remains the owner of array selection.
This skill owns the evidence boundary shared by supervision and the active capacity-retry lane.
It creates no router, loop, notifier, or state store.

## Observe once

Run `quota-axi --json` once for the observation and retain that complete snapshot as evidence.
Run `quota-axi auth --json` only when the credential surface is in question.
Read the canonical model registry entry for the consumer's already-established exact model key when binding its quota pool.
Do not launch a harness or another vendor CLI to judge the candidate.

The snapshot is data, never a recommendation.
Do not select a row by a matching model, harness, route, account, or pool name.
Use only an already-established mapping to the exact `providers[].provider` row.

## Bind the complete consumer tuple

Before using a percentage, account for all of these fields independently:

- `provider` - the exact quota-axi provider row.
- `plan` or entitlement - the row's current `plan`, compared with the entitlement the consumer requires.
- `credential surface` - the row's `source`, `state.sourcesTried`, and the matching provider entry from `quota-axi auth --json` when needed.
- `quota pool` - the exact model binding's recorded `limits.shared_quota_pool`, not a provider-name guess; a missing entry, missing pool, or mismatch with the consumer's required pool is `COULD_NOT_OBSERVE`.
- `model scope` - the exact `effectiveAvailability[].scope` used and its `boundedBy` and `limitingWindowIds`.
- `route and role` - the route plus the capacity role being decided, such as maker, read-only reviewer, or verification.
- `observed at` - snapshot `generatedAt` and provider `state.refreshedAt`.
- `freshness` - the consumer's declared maximum age, never a threshold invented after seeing the result.

Keep maker capacity, reviewer capacity, and verification capacity separate.
A maker being unavailable does not make an independently qualified reviewer unavailable.
An account-wide scope may bound every model on that provider, but it does not establish model entitlement, role qualification, or capacity on another provider.

## Three-valued result

Return exactly one result for the complete tuple:

- `OBSERVED_GOOD` - every required identity field matches, the observation is fresh, and the exact scope reports capacity above the consumer's stop condition.
- `OBSERVED_BAD` - every required identity field matches, the observation is fresh, and the exact scope positively reports the stop condition.
- `COULD_NOT_OBSERVE` - any required binding is absent, stale, mismatched, unreadable, or unsupported.

A changed plan, an unmodeled entitlement, an absent credential mapping, a missing model scope, or stale timestamps is `COULD_NOT_OBSERVE`, never zero percent.
A zero from one provider is evidence only about that exact bound tuple.
Never label it as GPT, Sol, Claude, or another product unless the tuple itself establishes that identity.

## Reconcile durable waits

A pause event is a durable report, not current quota truth.
When the tuple no longer matches the wait, close that pause's existing key with `resolved` and release or replace any backlog hold or capacity-deferral record only through its current owner.
Do not preserve a superseded Plus-era, stale, wrong-provider, or wrong-role predicate in prose.
If a fresh exact tuple still blocks, keep one durable typed pause/update whose `evidence=capacity:<owner-reference>` points to the retained evidence; legacy `quota:` references remain readable during migration.

An unchanged re-observation is not a new status event and not a captain update.
Refresh the current owner's evidence if that owner supports it, but append a new event only when the bound semantic result changes.
The shared supervision classifier deduplicates identical pause events; changed events, decisions, failures, credentials, and review-ready outcomes remain actionable.
