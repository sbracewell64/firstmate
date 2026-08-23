# Pre-reservation role-path and custody preflight verification

Audience: maintainer verification.

This record supports the pre-reservation product in [`../../bin/fm-role-path-lib.sh`](../../bin/fm-role-path-lib.sh), its read interface `role-path` in [`../../bin/fm-route.sh`](../../bin/fm-route.sh), the chokepoint that enforces it in [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh), the complete run census in [`../../bin/fm-nm-run-lib.sh`](../../bin/fm-nm-run-lib.sh), and the `check role-path` claim in [`../../bin/fm-decision-surface.sh`](../../bin/fm-decision-surface.sh).
It records what was measured about those controls and the limits of what the measurement establishes.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The regression coverage is [`../../tests/fm-role-path-preflight.test.sh`](../../tests/fm-role-path-preflight.test.sh).

## What the source can and cannot supply

Measured 2026-08-22 against no-mistakes v1.40.3 on Linux 6.18 (WSL2), bash 5.2, git 2.53.0, shellcheck 0.11.0.

The census reads the tool's own listing.
These are properties of that listing, and they bound what any custody answer built on it may claim.

```
$ no-mistakes axi --help
Available Commands:
  abort  logs  respond  run  status  sync
$ no-mistakes --help | grep runs
  runs        List pipeline runs for the current repository
```

`axi status` reports the active or most recent run only, and `axi` exposes no enumeration verb at all.
The only enumeration is the top-level `no-mistakes runs`, and it is repository-scoped, carries no run id, reports a short head, and truncates by default.

```
$ no-mistakes runs --limit 3 2>/dev/null | tail -2

  (218 more runs, use --limit to see more)
$ no-mistakes runs --limit 500 2>/dev/null | grep -c .
221
```

The truncation footer is therefore the only completeness signal this source emits, and its absence at a sufficient limit is what `fm_nm_census` requires before returning a complete census.
The update banner is written to **stderr**, not stdout, so it never reaches the row parser.

One measured behaviour makes an exit-status reading unsafe: the tool reports the same condition two different ways.

```
$ cd /an/uninitialized/repo
$ no-mistakes runs --limit 5 2>/dev/null; echo "[exit=$?]"
[exit=1]
$ no-mistakes runs --limit 5 2>&1 >/dev/null | tail -1
repo not initialized (run 'no-mistakes init' first)
$ no-mistakes axi status 2>/dev/null | head -1; echo "[exit=$?]"
error: repo not initialized (run 'no-mistakes init' first)
[exit=0]
```

`runs` exits **1** with its refusal on **stderr**; `axi status` exits **0** with the same refusal on **stdout**.
A reader judging the status alone calls the first a broken read and the second a clean empty census - two wrong answers to one question.
The census therefore reads the tool's own refusal from either stream before it reads the status, and returns three values rather than two: complete, uninitialized, or could-not-observe.

An uninitialized repository is an **established absence**: no pipeline exists there, so no pipeline run can hold the candidate.
It is recorded as `not-initialized` rather than as an empty census, so no later reader can credit it with a census that was taken.
The classification matches vendor text, and deliberately only in the narrow direction: an unrecognised wording falls through to could-not-observe, which refuses, so a changed message costs a repair rather than buying a silent pass.

## What the suite executes

The suite drives `bin/fm-route.sh role-path`, `bin/fm-spawn.sh` and `bin/fm-decision-surface.sh` as executables against real isolated git repositories and worktrees, a real `bin/fm-attempt.sh` execution record, the real `bin/fm-worktree-guard.sh owner-state`, and a `no-mistakes` stub whose run population each case states.
Nothing asserts implementation source bytes.
The suite opts into the identity ledger, so a declared case that is never invoked fails the suite rather than quietly reducing what it proves.

```
$ bash tests/fm-role-path-preflight.test.sh
ok - role-path: one complete eligible product is PERMITTED and names exactly one reservation
ok - role-path: even a PERMITTED product allocates nothing itself
ok - role-path: an omitted maker is INCOMPLETE_ROLE_PATH with no reservation
ok - role-path: an omitted checker is INCOMPLETE_ROLE_PATH with no reservation
ok - role-path: a maker reviewing its own mutation is ASSIGNMENT_NOT_DISTINCT
ok - role-path: a role acting outside the governed resource path is ROLE_PATH_NOT_PERMITTED
ok - role-path: a declared contract the register cannot read is ROLE_QUALIFICATION_UNOBSERVED
ok - role-path: a binding the register has not observed may not take the assignment
ok - role-path: a candidate that moved under the decision is STALE_CANDIDATE_GENERATION
ok - role-path: the staleness axis discriminates on the exact head rather than refusing any head
ok - role-path: a live no-mistakes run owning the candidate is PARTICIPANT_OWNS_MUTATION
ok - role-path: only a LIVE run on THIS branch owns the candidate
ok - role-path: an unrecognised run status is treated as live, not as finished
ok - role-path: a truncated run census is NM_CENSUS_INCOMPLETE, never an empty one
ok - role-path: a run listing that refuses while exiting zero is could-not-observe
ok - role-path: an uninitialized repository is an established absence, and any other failure still refuses
ok - role-path: the run census is consulted only where no-mistakes owns mutation
ok - role-path: worktree custody that cannot be read is could-not-observe, not free
ok - role-path: a worktree another task holds is never this dispatch's to take
ok - role-path: succeeding an execution the lane never opened is STALE_EXECUTION
ok - role-path: two live owners refuse as DUPLICATE_MUTATION_OWNER rather than picking one
ok - role-path: FAIL outranks CNO, so an established violation is what gets reported
ok - role-path: an unresolved base is recorded always and refuses only where the caller required one
ok - role-path: a product that required no role records that, so it cannot read as a covered path
ok - fm-spawn: the preflight a dispatch was admitted against is durably recorded
ok - fm-spawn: a refused dispatch allocates nothing - metadata, branch, worktree and slot are untouched
ok - fm-spawn: the gate discriminates - the same dispatch proceeds when no live owner holds the candidate
ok - fm-spawn: a waiver clears exactly the axis it names and is recorded on the task
ok - fm-decision-surface: check role-path reads the recorded preflight and refuses to guess
FM_TEST_CONTRACT suite=fm-role-path-preflight.test.sh status=pass
```

## Non-vacuity

A suite of refusals passes trivially if the thing under test refuses everything, and a suite of permissions passes trivially if it refuses nothing.
Both directions are held by paired controls that run on the same fixture shape: the staleness case is paired with a permitted product at the head the branch actually carries, the participant-owned case is paired with the identical dispatch once the run is terminal, and the two-live-owner case is paired with the same fixture reduced to one owner.

Each control was additionally confirmed to fail when the behaviour it names is removed.
Measured 2026-08-22 by mutating the implementation, observing the red, and restoring:

| mutation | control that went red |
|---|---|
| every run status classified terminal | a live run owning the branch must be REFUSED, got 0 |
| truncation footer never detected | a truncated census must be could-not-observe (exit 4), got 0 |
| assignment distinctness never refused | an assignment collapse must be REFUSED (exit 1), got 0 |
| reservation named on a refusal | CNO must name no reservation |
| the spawn gate reports without stopping | a candidate a live run owns must not be dispatched |
| the per-role qualification verdict never refuses | an unreadable capability contract must be could-not-observe, got 0 |

The qualification controls deliberately declare their contract on the **maker**.
`fm_qualification_reviewer_refusal` examines only the checker's contracts, so a checker-side contract is caught by two paths at once and a control placed there stays green when either one is removed - which is how a redundant path hides a deleted axis.

The uninitialized classification carries its own paired control in the same case: the established-absence stub must proceed, and a stub whose listing fails with any other message on the same command must still refuse.

## What the product does not overturn

Two axes are recorded but refuse only when the caller asks for them, because another owner already ruled on the same input and one input with two rulings is settled by ordering rather than by decision.

- A **role path** is checked only for the legs a caller declares with `require=`.
  A product that required none records an empty `required_roles`, so it can never be read as a covered path.
- A **source base** is always recorded, and refuses only under `require=base`.
  [`../../bin/fm-task-base-lib.sh`](../../bin/fm-task-base-lib.sh) already reports an unresolvable base as `unresolved` and lets the dispatch proceed on a warning, leaving the slot at the commit it last held.
  `bin/fm-route.sh role-path` requires a resolved base by default because an operator asking for the product directly is asking for completeness; `bin/fm-spawn.sh` does not, which preserves that owner's landed disposition.

Fleet admission and provider capacity are likewise not axes of this product.
They are separate gates applied at the same chokepoint ahead of allocation, and a PERMITTED verdict means "no role, qualification, generation or custody fact refuses this candidate", never "this dispatch may start".

A lane's own open execution is not a competing owner either.
A relaunch after a lost runtime re-enters that lane and continues the attempt already open, so counting it would make every restart look like a collision.

## What this does not establish

The census is complete for **one repository**, which is the scope a branch-custody question needs and is not the scope a fleet-wide question needs.
A run in another repository is invisible to it, and no verdict here claims otherwise.

The properties above were measured on no-mistakes v1.40.3.
A newer generation may change the listing's shape, its truncation wording, or its exit behaviour; the row parser and the truncation check both refuse rather than guess when the shape stops matching, so a change surfaces as `NM_CENSUS_INCOMPLETE` rather than as a silent pass, but the measured facts themselves do not transfer without re-observation.

Role qualification is inert where no capability contract is declared, and the product records that as `NOT_APPLICABLE` rather than as an observation.
`NOT_APPLICABLE` is the absence of a requirement; it is not a fourth value of one, and it is never evidence that a binding was observed to do the job.
