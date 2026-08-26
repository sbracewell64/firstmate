# ordinary-engineering-qualification-fixture-v1

A bounded, deterministic fixture package for qualifying a candidate binding on the
ORDINARY ENGINEERING roles, so that "can this binding do the job?" is answered by
an observation rather than by a reputation.

`qualifications/schema.json` owns the field contract, the five-value result
vocabulary and the state computation.
`bin/fm-qualification.sh` is the interpreter.
This README owns what is in the package and why it is shaped this way.

## What it is for

A route may require that a binding has been OBSERVED to do a named job.
Nothing about a model's name, its benchmark scores, or the confidence of the
agent proposing it answers that question, and the register exists because those
were being treated as if they did.

This package is the material a bounded qualification workflow runs against.
It is deliberately not a benchmark: it produces pass or fail against a floor, not
a score, because scoring a handful of candidates on several axes from a short
suite manufactures precision the evidence cannot support.

## Every case is public and synthetic

Nothing here is drawn from a real project, a real incident, a real credential, or
any private material.
That is a hard property rather than a convenience: a qualification run hands this
material to a candidate binding on a third-party provider, so anything private in
it would leave this fleet as a side effect of qualifying.
The material is small, self-contained, and invented for this package.

## The roles

`cases.json` carries one case per role the ordinary-engineering ruling names.
Each case is a synthetic task plus a grading key the candidate never sees.
The roles are not interchangeable, and the package keeps them separate because
recording one result per role is what lets a route require the specific
capability it needs rather than a general impression:

| id | the job being observed |
|---|---|
| `implementation` | build a small stated behavior from a specification |
| `routine-modification` | make a narrow change without widening its blast radius |
| `tests-and-watched-reds` | write a check that is proven able to fail |
| `deterministic-bug-repair` | find and fix a defect with a reproducing case |
| `investigation` | reach a supported conclusion and say what was not established |
| `architectural-implementation` | build to a stated boundary without collapsing it |
| `refactoring` | change structure while preserving behavior |
| `ci-provenance-repair` | repair evidence production without weakening the gate |
| `fixture-tooling` | build test material that cannot pass vacuously |
| `bounded-planning-research` | scope work and name what would change the answer |
| `semantic-review` | judge a change against what it claims, not against itself |
| `large-context-analysis` | answer from a specific place in a large input |
| `recurrence-investigation` | find the lowest owner a failure class recurs through |
| `reversible-remediation` | act with a stated, single-step rollback |

## The oracle is outside the candidate's reach

`verify.sh` grades a submission against `cases.json`, which the candidate is never
given.
`setup.sh` materializes only the task half into disposable state.
This separation is the whole point of the `fixture_oracle` predicate kind: a
candidate that could see the grading key would be graded on its reading
comprehension rather than on the job.

## The controls come first

`run-controls.sh` proves the oracle is RED-CAPABLE before any candidate result is
believed.
An oracle nobody has watched reject something is indistinguishable from one that
passes everything, and a qualification register built on such an oracle would
record confident QUALIFIED results that mean nothing at all.

The controls also pin the distinction the result vocabulary exists to protect: a
wrong submission is `FAILED`, and a submission that is absent or unreadable is
`COULD_NOT_OBSERVE`.
Those are different facts about the binding - one is evidence against it and the
other is no evidence at all - and collapsing them is the failure the register was
built from.

## Status

The fixture is PREPARED, not run.
Landing it does not qualify anything: a record is created only by
`bin/fm-qualification.sh` from an actual observation, and the authoritative
qualification runs against the repaired qualification generation.
