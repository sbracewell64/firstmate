---
name: fleet-admission
description: >-
  Agent-only procedure for fleet admission control, the third layer above routing and scheduling.
  Use at intake before dispatching new work in a home with an active admission policy, whenever an admission band other than preferred is returned, released, or overridden, and before acting on or reporting the advisory operator-attention observation.
user-invocable: false
metadata:
  internal: true
---

# fleet-admission

Admission control answers one question: should the fleet accept another task right now?
It is the third layer above routing (who is capable) and scheduling (when accepted work runs).

`docs/configuration.md` "Fleet admission control" owns the policy schema, `bin/fm-admission.sh`'s header owns the command contract and its decision record, and `bin/fm-admission-lib.sh` owns the executable schema check.
This skill owns what firstmate does with the result.

## The boundary that makes this a real layer

Admission inspects only properties of the fleet snapshot.
It never inspects the incoming task's tier, project, model, priority, urgency, estimated tokens, or file overlap, so the same snapshot returns the same band for every incoming task.
`bin/fm-admission.sh` enforces this structurally by refusing a task argument.

A task's criticality is not an admission input.
An explicit captain exception is an override applied *after* a refusal, never a value that changes the fleet's band.
If you ever find yourself wanting a different band because of what the task is, you are doing scheduling, and it belongs in the scheduling layer.

The other invariants that bind every decision:

- Most restrictive wins; no combination rule may average a hard result away.
- Unknown is explicit: missing required evidence maps to the configured band, never to zero or "probably fine".
- Admission never stops running work and never mutates a task's tier or priority.
- Deferred and refused requests stay in the owning backlog under `hold_kind=load`; there is no second queue.
- Capacity is released by successful cleanup, not by a worker's `done` line.
- Every threshold, freshness limit, and band mapping is read from configuration; a number this layer cannot read from config does not exist.

## At intake

A home with no configured policy prints `admission: not configured` and dispatch is unchanged; do not run this procedure.

When the policy is active, capture the request durably in its owning backlog first, so nothing is lost regardless of the band.
Then run `bin/fm-admission.sh` once, before routing and before scheduling.
Read the band, not the exit code alone, and act on it:

| Band | Action |
|---|---|
| `preferred` | Admit this task, then continue to routing and scheduling as normal. Silent. |
| `soft` | Do not dispatch. Apply a `load` hold and tell the captain immediately. |
| `hard` | Do not route or spawn. Apply a `load` hold, tell the captain immediately, and name the condition that must clear. |

An unknown required signal has already been mapped to its configured band by the evaluator; treat the result as that band and name the missing or contradictory evidence when you report it.

Admitting several requests in one intake means evaluating them one at a time: each admission changes the snapshot before the next is evaluated.

## The advisory operator-attention signal

Two rules in every decision record - `operator_attention.parked_units` and `operator_attention.parked_seconds` - name how many units are finished awaiting a merge or parked at a gate, and how long they have accumulated there.
The captain ruled this signal advisory: it is reported and never binding, the same posture the provider concurrency caps hold.

That ruling is enforced in the schema rather than left to memory, so there is nothing to decide here about whether it may change a band.
It may not, in any enforcement mode.
The one thing this procedure asks of you is the discipline that goes with an advisory number.

- Never defer, refuse, hold, or slow a request because this observation is large.
  A `preferred` band with a large parked count is still `preferred`, and the intake table above is the whole procedure.
- Never read it as saturation.
  It measures work the fleet has already finished or already stopped at a gate, not capacity the fleet is currently spending.
- Report it as its own values, never as a score.
  It is a count of units and an accumulated wait; both come from the census, and neither is combined into anything.
- When a unit's wait cannot be measured, the rule discloses that instead of estimating.
  Carry the disclosure with the number when you relay it; a total over some of the units is not a total.

What it is for is evidence.
A growing parked count and a growing accumulated wait are the measured shape of the fan-in the captain owns, and they belong in the captain's next fleet review with the actual numbers.
Report it as the plain consequence - how many finished pieces of work are waiting on them, and for how long - never as a band, a signal name, a threshold, or a rule id.
Follow the same rhythm as any other observation: it is digest-level, not an interrupt, unless the captain asked to be told sooner or a specific piece of waiting work has become urgent on its own.

## Queueing a deferred or refused request

`tasks-axi hold <id> --kind load --reason "<reason>"` is the whole queue substrate.
The reason is one line and must not contain parentheses.
Keep it to the controlling observation, its configured limit, and the config digest, for example:

```text
Fleet admission hard: census integrity unreadable against configured unknown_band hard; config sha256:...
```

Never put credentials, temporary paths, an opaque score, or an inferred cause in the reason; the full structured evidence belongs in the decision record.
Never use any hold kind other than `load` for an admission outcome - `captain` holds mean a captain decision is pending, and a load hold must never masquerade as one.

## Releasing

Re-examination happens at exactly two points, and both already exist.

1. **Successful cleanup.** `bin/fm-teardown.sh` prints the admission release reminder after a successful teardown. Recompute the band with `bin/fm-admission.sh`, and only if it is `preferred` release load-held requests - one at a time, re-evaluating between each, because each admission changes the snapshot. Scheduling then chooses which released request goes first, using priority and urgency; admission only decides how many new obligations the fleet can take.
2. **Session start.** The startup digest prints the same band for an admission-active home.

A failed cleanup releases nothing.
A worker's `done` status alone releases nothing.

A fleet that is already empty while a load-held request waits will not get a teardown event and waits until the next session start.
That gap is deliberate and named; do not add a daemon, timer, or second supervision loop for it.
If you observe it happening - the fleet returned to `preferred` while a load-held request sat untouched until session start - that is one measured missed release event, and it belongs in the captain's next fleet review as evidence, not as a reason to build machinery on the spot.

## Reporting to the captain

Follow `AGENTS.md` section 9's translation contract: no band names, config paths, digests, hold kinds, or signal identifiers in captain-facing chat.

- `preferred` is silent, and so is a repeated observation that changes nothing.
- A newly deferred or refused request is immediate, every time. Several requests deferred together in one intake may share one message that names each of them, but never delay one behind a digest.
- A recovered band that materially affects no waiting request is digest-level.

The captain-facing shape is the plain consequence: what the fleet observed, what it means, how many requests are waiting, that no worker was started, that existing work continues, and when it will be reconsidered.

## Overrides

A captain may direct an exception after a refusal.
Record the original band and its explanation, the exact override authority, the affected task, the configuration digest, and the expected consequence.
No standing priority or urgency field silently overrides a hard fleet decision.

## Telemetry seam

The record printed by `bin/fm-admission.sh --json` is the unit of admission telemetry.
It carries the decision identity, the snapshot and configuration digests, every observation with its source and freshness, every rule with its exact JSON config path and configured value, and the controlling rules.
The wake-outcome ledger is being built in parallel and does not expose an extension seam yet, so nothing is persisted today.
When that seam lands, append this record in the ledger owner's format; admission control owns these semantic fields and never opens a competing evidence store.
If a telemetry write ever fails, surface the degraded evidence and apply the configured unknown policy - never a hidden retry loop that blocks intake.

## What stays dormant

Do not build a distributed registry, reservation store, lease daemon, RPC service, or remote agent while one local session is the only intake authority; the per-home session lock already serializes the real fleet.
Do not populate a numeric threshold from intuition: the configured `enforcement_mode` refuses it, and the report checkpoint for each dormant mechanism is the place to revisit it with evidence.
Do not propose making operator attention bind a band; that posture is a captain ruling, and only the captain can change it.
An admission daemon, a task-weighted admission score, and provider quota inside the admission band are permanently rejected designs, not deferred ones.
