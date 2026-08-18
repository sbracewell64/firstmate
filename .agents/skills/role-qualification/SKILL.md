---
name: role-qualification
description: >-
  Agent-only decision procedure for role qualification: whether a binding has been observed to do a job a route requires, and what to do when it has not.
  Load before asserting that a route has no usable binding, before deciding whether missing capability evidence needs the captain, when a route returns a zero-route classification, before recording or resolving a qualification result, and before choosing a reviewer for work another binding made.
user-invocable: false
metadata:
  internal: true
---

# role-qualification

The procedure for one question: **has this binding been OBSERVED to do the job this route requires, and if not, what kind of not?**

`qualifications/schema.json` owns the field contract, the five-value vocabulary and the state computation.
`bin/fm-qualification-lib.sh` and `bin/fm-qualification.sh --help` own the mechanics.
[`docs/configuration.md`](../../../docs/configuration.md) "Role qualification register" owns the register and the `requires_capabilities` floor axis.
This skill owns Firstmate's operating response to the computed decision.

## The mistake this exists to prevent

Missing qualification and incapability were the same value.
So a route whose one plausible candidate had no capability evidence produced exactly one available answer - ask the captain for a task-specific floor exception - and it produced that answer repeatedly, for the same missing evidence, while a bounded workflow could have produced the evidence instead.

The captain ruled on 2026-08-13 that missing qualification is an engineering state to resolve.
Two sentences from that ruling do the most work:

> Model names are bindings to capability contracts, not capability contracts themselves.

> Claude or Fable availability is not a prerequisite for runtime progress when other bindings can satisfy the same executable capability and assignment-independence predicates.

Read both as prohibitions on inference. A model name is never evidence of a capability, and one vendor's reachability is never evidence about a job.

## Never assert this from memory

`bin/fm-route.sh zero-route --route <id>` answers why a route has no eligible candidate, and `bin/fm-decision-surface.sh check route-qualified <route-id>` refuses a claim it contradicts.
Do not state that a route has no usable binding, that a model cannot do a job, or that a capability gap needs the captain without reading one of them.
An `unevaluable` verdict means the fact may not be asserted at all - not that the claim is safe.

## Five states, five different actions

| state | what was observed | what you do |
|---|---|---|
| `QUALIFIED` | the predicate ran, passed, and an assignment-distinct adjudicator agreed | route it |
| `FAILED` | the predicate ran and rejected this binding | exclude it, keep the evidence, evaluate the next candidate |
| `QUALIFICATION_REQUIRED` | no applicable observation exists, or one exists without its required adjudication | qualify it |
| `QUALIFICATION_STALE` | an observation existed and a declared material dependency changed | qualify it again |
| `COULD_NOT_OBSERVE` | the predicate, the adjudication, or a dependency could not be observed | repair the observation |

Three of those five are not a pass and not a finding against the binding.
Reporting any of them to the captain as "this model cannot do the work" is the failure, not a paraphrase of it.

`FAILED` is the only state that excludes, and even that reopens on a directly evidenced material change to the binding, the harness, or the contract - with the adverse record retained rather than deleted.

## The four zero-route classifications

Only one of them is the captain's.

| classification | action | escalates |
|---|---|---|
| `QUALIFICATION_REQUIRED` | activate one bounded workflow for the cheapest promising candidate | no |
| `QUALIFICATION_COULD_NOT_OBSERVE` | repair the observation; record nothing against any binding | no |
| `AWAITING_AVAILABILITY` | wait; the availability hold or capacity deferral owns it | no |
| `NO_MODEL_CAN_SATISFY_ROUTE` | stop and report | **yes** |

A candidate is **promising** only when its ONLY blocker is fixable qualification.
One that also misses a floor axis is not made eligible by qualifying it, so a bounded workflow spent on it is wasted.

## Running the bounded workflow

1. `bin/fm-qualification.sh activate --route <id> --blocks <blocked-work-id>`.
   It refuses any classification other than `QUALIFICATION_REQUIRED`, picks the cheapest promising candidate, writes a durable activation record, and blocks the named work identity through the existing backlog owner.
   A second request for the same pair reports already-active rather than creating a second workflow.
2. `bin/fm-qualification.sh dispatch <activation-id>` launches it through `bin/fm-spawn.sh`, the one chokepoint, so route, admission, capacity, cost, entitlement and concurrency are all re-evaluated there.
   Brief the worker to run the contract's own predicate unchanged: do not tune a fixture, a prompt or an acceptance criterion against the candidate to obtain a pass, and preserve every adverse observation.
3. `bin/fm-qualification.sh resolve <activation-id> --result <RESULT>`.
   A `QUALIFIED` result is verified against the register before it is accepted, so write the record first; the word alone is refused.

The workflow is bounded by `bin/fm-attempt.sh` on its **own** identity.
Never let it read, spend or reset the blocked work's attempt count, retry budget or custody bases: a task that was waiting for a capability did not fail.
On a pass the blocked identity is UNBLOCKED, never re-created.

## Choosing a reviewer

`bin/fm-qualification.sh reviewer --maker <model> --reviewer <model> --contract <id>...` is the check, and it refuses in this order: self-review, then an unqualified reviewer, then a failed independence dimension.

Three rules it enforces that are easy to talk yourself out of:

- **A maker never reviews its own candidate**, however well it qualified as maker. Qualifying for the reviewing contract is not independence.
- **Pre-mutation design challenge and post-mutation exact-change review are separate capabilities.** A route requiring both requires two `QUALIFIED` records. One reviewer may perform both on one assignment only when it holds each record and assignment independence still holds.
- **Holding a record is never availability, and availability is never a record.** They are different axes with different owners.

## Nine axes, and the two collapses that keep happening

`qualifications/schema.json`'s `axes` block names all nine and refuses a contract that claims a second one.
The two worth naming here because they are the ones that get conflated in conversation:

- **A reachable binding is not a qualified one.** One vendor answering says nothing about whether any binding was observed to do this job.
- **An unreachable binding does not make a route unsatisfiable.** If another binding satisfies the same predicates, the route is satisfiable and saying otherwise is a claim the route owner contradicts.

## What never happens

- Missing or stale qualification never produces `CAPTAIN_EXCEPTION_REQUIRED`.
- A `COULD_NOT_OBSERVE` never becomes a pass, a failure, or a reputation.
- A recorded `FAILED` is never deleted to make room for a retry.
- A record's state is never hand-written; it is computed on every read.
- A contract never names a model, provider, harness or vendor - the validator refuses one that does, because a contract naming who does the job cannot be re-run against the next candidate.
