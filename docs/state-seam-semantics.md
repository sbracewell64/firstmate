# State and seam semantics

This is the maintainer-architecture owner for firstmate's semantic substrate: the `semantics/` register, its deterministic compiler, its generated projections, and the four validators.
It covers ownership, extension points, mechanism boundaries, and safety rationale.
Exact commands, flags, and field contracts live where they always do - in [`bin/fm-semantics.sh`](../bin/fm-semantics.sh)'s header and `--help`, and in the register's own `semantics/*.json` documents.

## What this is, and why it exists

Firstmate independently built the same state law six times, in six vocabularies, in six files.
Each rediscovery was correct; none was reusable by the next mechanism.

| Law | Where it was landed independently |
|---|---|
| unified terminal vocabulary with a total source mapping | `loopspecs/terminal-states.json` |
| three-valued observation type with a consumer that must handle all three | [`bin/fm-verify-lib.sh`](../bin/fm-verify-lib.sh) |
| compute state, never store it, enforced by refusing state-like keys by name | `commitments/schema.json` |
| a five-value result computed on every read, with declared freshness dependencies | `qualifications/schema.json` |
| one canonical identity compilation whose digest IS the identity | [`bin/fm-outbound-artifact-lib.sh`](../bin/fm-outbound-artifact-lib.sh) |
| a four-phase spendable authority with intent written before the act | [`bin/fm-landing-authorization-lib.sh`](../bin/fm-landing-authorization-lib.sh) |

The cost of that is not the duplicated code, which is small.
It is that a seventh mechanism has no prior art to inherit and reinvents the law a seventh time, usually less completely.
This register exists so the seventh mechanism inherits instead of rediscovering.

## The boundary this register may never cross

[`bin/fm-decision-surface.sh`](../bin/fm-decision-surface.sh) answers what a task is doing.
This register answers what a word means and what may follow it.
The moment it answers the first question, the fleet has two answers to one question and both get credited with the same sentence.

`semantics/schema.json`'s `refused_keys` is the mechanical form of that boundary, and `bin/fm-semantics.sh` enforces it at every depth of every document and manifest.
A document carrying `queue`, `schedule`, `runtime`, `watcher`, `current_state`, or any of the other refused names is refused outright rather than having the key ignored - because an ignored field still reads to a human as the answer.
That mechanism is not invented here: `commitments/schema.json` already refuses nine state-like keys by name for exactly the same reason, and this register extends the list rather than restating it.

The register holds no task state, no schedule, no queue, no decision, no runtime, no daemon, no event bus and no hook bus, and it never will.

## Ownership

| Document | Owns |
|---|---|
| `semantics/schema.json` | the field contract for the register, the refused keys, and the invariants no single document can see |
| `semantics/laws.json` | the five laws, three gate-placement predicates, the Observation Horizon Dominance predicate, the lifecycle-call strategy, and the adoption prerequisites |
| `semantics/state-families.json` | the nine work families, their legal successors, the two object families, the terminal reasons, the verdict vocabularies, and every source mapping |
| `semantics/reasons.json` | the six reason namespaces and their codes |
| `semantics/identity.json` | the seven identity namespaces, the canonical subject record, and the eleven cross-namespace edges |
| `semantics/seams.json` | the seam row contract, the four seam states, the protocol and version law, and the declared protocols |
| `semantics/inheritance-manifest.schema.json` | the field contract for one inheritance manifest |
| `semantics/census.json` | where each semantics is implemented today and how it is classified - the migration source of truth, and explicitly not an owner |

`bin/fm-semantics.sh` is their only interpreter, and `bin/fm-semantics-lib.sh` holds the four validators.

## Two axes, not one vocabulary

A terminal reason answers *why did this stop*.
A family answers *what kind of state is this*.
They are different questions at different granularity: five terminal reasons share the family `FAILED`, and the split between them is what tells an operator whether to repair the work, the bound, or the instrument.

Collapsing them would lose the repair.
Keeping them as two independent vocabularies with no mapping would give the fleet two answers.
So they are two axes with one total mapping, declared on every terminal reason.

## The compatibility projection, and why there was no flag day

`loopspecs/terminal-states.json` is now a generated projection of `semantics/state-families.json`.
Its vocabulary, its four source mappings and its invariants are reproduced unchanged; the only added bytes are a `generated` block no consumer reads.

Every existing consumer - [`bin/fm-loopspec.sh`](../bin/fm-loopspec.sh), the `loopspecs/schema.json` `external_enums` pointer, [`bin/fm-attempt.sh`](../bin/fm-attempt.sh), and [`bin/fm-loop-actuate.sh`](../bin/fm-loop-actuate.sh) - reads it exactly as before.
A rename to `state-families.json` was available and was deliberately not taken: it would have made every one of those consumers a migration, and a flag day is how a compatible change becomes an incident.

`tests/fm-semantics-compat.test.sh` proves the move by driving the real consumer across the regenerated file, in both directions, rather than by re-reading the file and calling that a crossing.

## Extension points

There are exactly three, and all of them are declarations rather than code:

1. **A new source vocabulary.** Add a `sources[]` entry to `semantics/state-families.json` with a total `map`. A row whose state names a value of an *observation* rather than a member of the target vocabulary sets `unified` to `OBSERVATION_RESULT` and names its `observation_verdict`. That encoding is what keeps the mapping total without forcing an unmade observation to read as a claim about work.
2. **A new reason code.** Add it to exactly one namespace in `semantics/reasons.json`, with a verdict and a repair. A code declared twice is refused, because its namespace could no longer be resolved by lookup.
3. **A subject-specific extension.** Declare it in an inheritance manifest with a `consumer_action_distinction` and a `why_canonical_reuse_fails`. An extension that names no consumer whose action differs is refused as a synonym, and one whose name collides with a canonical member is refused outright rather than shadowing it.

Adding a tenth work family is deliberately not an extension point.
The membership test is that two states belong to different families if and only if a correct consumer must take a different action; a family no consumer branches on is a synonym, and synonyms are how a vocabulary becomes unusable.

## The design preflight

`bin/fm-semantics.sh preflight` answers one question before a new stateful mechanism is designed: does an existing family, reason, identity namespace, subject type, protocol or seam already cover this?
Reuse is mandatory where it does, so an existing name **refuses** rather than being reported as a coincidence.

It also validates a proposed inheritance manifest end to end, which is the form to use when the mechanism already exists on paper.

## What must be true before any of this is authoritative

Nothing here becomes authoritative because a branch defines it.
`semantics/laws.json` declares eight adoption prerequisites, and `bin/fm-semantics.sh adoption` reports each one.

Three of the eight are deliberately not machine-evaluable from this tool's own position, and it answers could-not-observe for them rather than guessing:

- whether the mechanism duplicates an existing owner is a judgement about meaning, decided by review; `semantics/census.json` is its evidence base and not its verdict.
- whether a real producer-boundary-consumer crossing occurred, and whether a red was witnessed at the seam, are facts about a production crossing. A red seen in a test suite is evidence for the suite. Crediting it to the crossing would be the wrong-subject failure this substrate exists to refuse.
- exact-head review, reviewer qualification, and effect authorization are owned by [`bin/fm-pr-check.sh`](../bin/fm-pr-check.sh), [`bin/fm-qualification.sh`](../bin/fm-qualification.sh) and [`bin/fm-landing-authorization.sh`](../bin/fm-landing-authorization.sh).

Until they pass, every output of this mechanism is diagnostic, and every validator result line says `authority=diagnostic` in its own text rather than relying on a reader to remember.
The one exception is the terminal projection, which carried its existing authority across the owner move unchanged.

## Safety rationale for the choices that look like restrictions

- **G1 refuses; G3 grants.** An early gate may only ever refuse, never grant, and a permission is re-derived at the effect from scratch every time. This is the only assignment that makes both cheap and correct: a refusal is monotone, while a permission is anti-monotone - a condition that passes early can rot. `bin/fm-semantics.sh validate` refuses any register in which a predicate other than G3 may grant.
- **Four validators, not five.** The Seam Contract law has none, because a seam state is an observation of a crossing made by the seam owner and is not decidable from a declaration. A fifth validator returning a seam verdict from a file would grade the declaration and be credited to the crossing.
- **Direct calls, not a hook bus.** A lifecycle hook implies registration, dispatch, ordering and a bus, and each is a second control plane. The ordering question alone becomes configuration, which is how a check gets configured away. [`bin/fm-landing-seam-lib.sh`](../bin/fm-landing-seam-lib.sh) is the landed argument: a control the mutation path can route around is not a control.
- **Every verdict names its scope.** Each result line carries `dimensions=`, naming exactly what that call evaluated. A pass on those dimensions is not a pass on any other. That is Gate Dominance made visible rather than remembered.
- **The register is pure.** The validators read tracked files and one caller-supplied record. They open no socket, hold no lock, cache nothing, and write nothing, so a restarted fleet computes the identical answer - which is what makes restart a non-event rather than a reconstruction.

## Where the census fits

`semantics/census.json` records where each state, reason, identity, authority, effect, external-wait, seam, version and retry semantics is implemented today, and classifies each exactly once as `CANONICAL_OWNER`, `GENERATED_PROJECTION`, `ADAPTER`, `LEGACY_TO_MIGRATE` or `SUBJECT_SPECIFIC_EXTENSION`.

It is the migration source of truth and must never become a second semantic owner.
`bin/fm-semantics.sh validate` refuses a census row that declares a vocabulary member the owner documents do not, which is what keeps that boundary mechanical rather than a promise.

Two findings in it are load-bearing and are recorded rather than repaired on the branch that introduced the register:

- Two cross-namespace edges have **no owner**: fork lineage to upstream contribution base, and forge object back to work item. Zero owners and two owners are the same defect, because in both cases nobody is answerable.
- The `REVISE` family has **no source vocabulary** anywhere in the fleet. A review finding returns as `needs-decision`, which is an external wait because firstmate owes the ruling; once the ruling directs a fix, the worker reports `working`. The state in between - the finding is ruled, the obligation is on the maker, and promotion must be refused until it is addressed - has no name today. That absence is why the family exists.

## Transport is never the governed subject

The sharpest identity recurrence this fleet has recorded is not a wrong field.
It is a wrong RELATION between two fields that were each individually well formed.

Three independent Browser Sol rulings, on three different decision subjects, record one defect class.
Every one of them declared the same **transport** repository as the request's subject repository while binding an exact head that resolves - in a different repository.

| Ruling | Request | Declared repository | Exact head | Repository the head belongs to |
|---|---|---|---|---|
| `5385612078` | `fm-ob-26660534cd52` | `sbracewell64/firstmate-sol-control` | `1f2141ad…` | `sbracewell64/firstmate` |
| `5385881288` | `fm-ob-7804557b2dfe` | `sbracewell64/firstmate-sol-control` | `16db74ff…` | `sbracewell64/inkwell-agent-sandboxes-and-software-factory` |
| `5387155383` | `fm-ob-6267e1c729b9` | `sbracewell64/firstmate-sol-control` | `cf4c640b…` | `sbracewell64/firstmate` |

A per-field validator could not have caught any of them, because no field was invalid on its own.
The second instance is the load-bearing one: it repeated the same defect class **after** a canonical transport repair had already been authorized.
A defect that recurs past its own authorized fix is the argument for a mechanical, drift-checked declaration rather than another repair.

All three are `REVISE` on transport identity, self-handled under existing authority.
None is a merits ruling, and none grants approval, publication, landing, reviewer qualification, or one-use authority.

The foundation makes the distinction mechanically expressible in `semantics/identity.json`:

- **Venue axes are declared, and declared as not-identity.** A subject type may name `venue_axes` - where a request was carried, asked or stored. `bin/fm-semantics.sh validate` refuses a subject type in which a venue axis is also an identity axis, so a configured transport repository has no identity axis to occupy.
- **The identity axis is named for what it identifies.** The `outbound_request` subject type declares `governed_repo`, not an ambiguous `repo`.
- **The minimum binding set all three rulings required is declared.** `governed_repo`, `item`, `head`, `tree`, `review_envelope` and `policy_generation`, alongside `gate`, `project`, `pr` and `purpose`.
- **Referential integrity is checked before any durable effect, and against sustaining one.** Axes are checked *together* rather than one at a time, because each value was individually well formed. An identity that fails may neither create a wait nor hold one open, and a restart recomputes the same refusal from the same durable records rather than resurrecting it.
- **Typed identity outranks every untyped source.** Human context, prose, a local path, a configured venue, an inbound response, or a model-supplied repository name may aid discovery and may never override the typed identity consumed for applicability. The first ruling states this explicitly, because in that instance the request's own prose named the governed repository correctly while the typed binding named the transport one.

This branch declares the target and changes no producer.
`bin/fm-outbound-artifact-lib.sh` still compiles six axes under the name `repo`, and `semantics/census.json` rows `CEN-ID-08` and `CEN-ID-09` record that divergence rather than hiding it.
Repairing the compiler is phase 9, and adding or renaming an identity axis changes every existing digest, so the compatible path there is a declared v2 compilation beside the declared v1 rather than a recomputation.

## Harness and runtime applicability

Every supported harness and runtime backend was inspected for an integration surface rather than assumed unaffected, because "it is only a registry" is exactly the assumption that hides a coupling.

| Surface | Affected | Why |
|---|---|---|
| `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi` | no | The register spawns nothing, reads no rendered harness output, handles no trust dialog, and consumes no adapter. No verdict here comes from anything a vendor emits, so no check in this mechanism is harness-dependent and none needs a live-harness guard. |
| `tmux`, `herdr`, `zellij`, `orca`, `cmux`, `codex-app` | no | The register allocates no endpoint, writes no `state/<id>.*` record, and reads no backend inventory. `bin/fm-semantics.sh` touches only tracked files under `semantics/` and `loopspecs/`. |
| Stock macOS Bash 3.2 | yes, and covered | `bin/fm-semantics.sh` and `bin/fm-semantics-lib.sh` are in the canonical lint file set, so the macOS parse sweep already covers them. The generated shell projection is NOT in that set, because it is not under `bin/`; `bin/fm-semantics.sh compile` therefore parses it itself before writing, and `tests/fm-semantics.test.sh` sources it and reads a value back out. Neither script nor projection uses an associative array, `mapfile`, or case-modification expansion. |
| Windows launcher bridge | no | The bridge launches a WSL session; nothing here participates in launch. |

The one genuinely affected surface is therefore the shell the scripts run under, and it is covered by an existing lane plus one check the compiler performs on its own output.

## Verification

`bin/fm-semantics.sh check` composes the owner invariants, the projection drift check, and the manifest check into the single command CI invokes, so CI carries no second spelling of any of them.

| Suite | Proves |
|---|---|
| `tests/fm-semantics.test.sh` | owner invariants, compiler determinism, drift refusal, preflight, manifests, and that the mechanism reports its own prerequisites unmet |
| `tests/fm-semantics-validators.test.sh` | the four validators return three values, never two, with mechanically distinct reason namespaces |
| `tests/fm-semantics-compat.test.sh` | the real producer-boundary-consumer crossing with the existing terminal consumer, plus four watched reds |

Every block in all three drives its control red against a mutated fixture before trusting a green result on the shipped register, because a checker that cannot fail proves nothing by passing.
