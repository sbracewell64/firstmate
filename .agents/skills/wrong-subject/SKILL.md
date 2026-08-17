---
name: wrong-subject
description: >-
  Agent-only vocabulary for the review failure where a check reasons correctly about one thing and its verdict is credited to another.
  Use before crediting any check, control, guard, or verifier with a property, whenever a green control or a refusing guard is surprising, and before writing or acting on a finding of this class.
  Owns the class name, its six drift axes, the required finding form, and the rule that resolves a credited claim to could-not-observe.
user-invocable: false
metadata:
  internal: true
---

# wrong-subject

A check runs.
Its logic is sound, its evidence is real, and it answers a question correctly - and it is not the question that was asked.
The verdict is then credited with a property it never established.

This skill is the single owner of that class: its name, its axes, the form a finding of it takes, and how it composes with three-valued evidence.
`bin/fm-wrong-subject.sh` is its only tool, and that script's header owns the finding form's exact mechanics.

## The class

A verdict is a **claim**, and a claim has a **subject** and a **property**.
A `wrong-subject` finding says: **the claim the check established and the claim the verdict is credited with are different claims, and the established one is true.**

The truth of the established claim is the discriminator, and it is what makes the class worth naming.
A check whose reasoning is wrong is an ordinary defect, and this vocabulary adds nothing to it.
This class is for the case where nothing in the reasoning is wrong and the conclusion is still unsupported, which is exactly why it gets re-derived from first principles every time it appears.

It is not a bug class about incorrect code.
Every founding instance had correct code.
What is destroyed is not the behavior; it is the knowledge.

The fleet already carries this shape as a set of separate laws - discovery is not identity, location is not identity, rendering is not identity, a name is not the thing it names, a commit id is not commit content.
They are the same failure under different axes, and they are collected here so a reviewer names the class once instead of rediscovering one member of it.

## The composition law

**A `wrong-subject` finding resolves the credited claim to could-not-observe.**

It never converts the credited verdict into its opposite, and this is the part that is easy to get wrong.
Naming the gap tells you the check did not look at the credited subject.
It tells you nothing about what the credited subject is actually like, so any value other than could-not-observe would be the same error one level up.

Both directions occur, and a review that only hunts false greens misses half the class:

- Credited **pass**, actually could-not-observe.
  A control over a fixture the check manufactured said nothing about the real path - and it did not say the real path was broken either.
- Credited **fail**, actually could-not-observe.
  A guard that refused because a commit was unreachable from a remote it could not see did not establish that the work was unsafe.
  The permanent false refusal is a `wrong-subject` finding exactly as much as the permanent false green.

The remedy is always a fresh observation bound to the credited subject.
It is never a re-reading of the same evidence, because the same evidence answers the other question no matter how carefully it is re-read.
Independent evidence about the credited subject may exist, and it is welcome, but it is a different observation and it is never established by this check.

This composes with `bin/fm-verify-lib.sh` rather than replacing it: could-not-observe here is that library's `NO_VERIFIER_RAN`, and narrowing it is that library's coercion, logged and loud.

## The six axes

A claim can drift from the claim credited along six axes.
Name the operative one; an instance may sit on two, and naming both is better than picking.
The diagnostic question is the point of each row - it is what a reviewer asks out loud without having to have read this file.

| Axis | The drift | Ask |
| --- | --- | --- |
| `instance` | Right kind, different individual. | Could there be a second thing of this kind, and did the check bind to the one the verdict speaks about? |
| `moment` | Right individual, read at a time the verdict does not speak about. | Was the subject read at the moment the verdict claims, or at a moment recorded earlier? |
| `extent` | Part examined, whole credited. | Does what the check covered reach everything the verdict speaks for, and is that boundary stated anywhere? |
| `stand-in` | Something that reliably leads to the subject was examined instead of the subject. | Is this the thing, or something that reliably leads to the thing? |
| `manufacture` | The examined subject exists only because the check made it. | What would have to be true of the real subject for this to go red? |
| `property` | Right subject, a different property established than the one credited. | Does the property established entail the property named always, or only usually? |

The class's center of gravity is subject identity, and `property` is the axis on which the same failure reaches a check whose subject was right all along.
`stand-in` is the axis the fleet's existing laws already occupy, and its instances are worth knowing by heart: a commit id standing in for commit content, a wrapper process standing in for the child that acts, a function name standing in for the behavior, a rendered display standing in for the stored bytes.
`manufacture` looks like `instance` and is not: in `instance` the right subject exists and the check reached past it, while in `manufacture` the examined subject was authored by the check, so the check cannot go red for the real subject at all.

## Writing the finding

A finding that names only the defect loses the reason, and the reason is the whole value of the class.
State both claims, because **the gap between them is the finding**.

Use `bin/fm-wrong-subject.sh finding`, which refuses a form that omits either claim and derives the could-not-observe line rather than letting an author write it.
Run `bin/fm-wrong-subject.sh axes` to pick the axis name; that is the whole cost of naming the class in a review.

The rendered block is the assertable unit.
Paste it into a scout report, a review comment, or a decision record, and a later reader gets the reason without re-deriving it.

```
wrong-subject finding (axis: stand-in)
  check:       bin/fm-teardown.sh recoverable-work guard
  examined:    the commit is not reachable from a remote ref this worktree can see
  credited:    the work is not safely recoverable and must not be discarded
  credited-as: fail
  gap:         the task worktree has no origin remote at all, only the gate remote, so a commit the pipeline pushed is unreachable here while being the head of a green PR on the forge
  therefore:   the credited claim is could-not-observe, not fail
  remedy:      ask the authoritative forge whether the work landed; an unreachable origin stays could-not-observe and still refuses
```

Read the `therefore:` line carefully, because it is the part reviewers get wrong.
It does not say the work is safe.
It says this guard never asked, and the refusal it produced was never evidence either way.

`bin/fm-wrong-subject.sh check <path>` re-derives that line and compares it, so a block edited by hand into something softer is caught rather than read as a sound finding.
It grades findings where they live, including inside a longer report, and it treats a file holding no finding block as could-not-observe rather than as a clean one.

## What is mechanically checkable, and what is not

**Checkable, and checked:** the finding's *form*.
Both claims present and different, the axis inside the closed set, the credited reading inside `pass|fail`, the gap condition stated, and the could-not-observe line derived rather than authored.
That much is decidable from the text alone, so it is enforced rather than requested.

**Not checkable, and deliberately not attempted:** whether any given check in any codebase belongs to this class.
That is a semantic mismatch between a verdict and a question.
A detector for it would emit confident false positives - which is this exact failure one level up, and the single most likely way to make the problem worse - so do not build one.

`bin/fm-wrong-subject.sh check` returns `FORM_COMPLETE`, `FORM_INCOMPLETE`, or `FORM_UNREADABLE`, three-valued at its own seam.
`FORM_COMPLETE` establishes that the finding is well formed and nothing else.
It does not establish that the established claim is true, that the two claims differ in meaning, that the gap condition is real, or that the named check has this defect.
Crediting it with any of those would be a `wrong-subject` finding against this tool, and the axis would be `property`.

## The two instances this tool committed

`bin/fm-wrong-subject.sh check` committed this defect twice, on two different input paths.

It tested whether its input was readable, and credited that with whether its input could be consumed.
A directory passes a readability test, and the read then died at exit 1 - the code reserved for a form that was examined and found wanting.
The named-path input and the stdin input each carried that same gap, and each had to be closed on its own.
Both reported a could-not-observe as a definite negative, on the `property` axis, inside the tool built to name that failure, and a reviewer found them rather than their author.

Two instances on two surfaces of one small tool is the part worth keeping.
A single slip would say only that someone was careless.
A recurrence across input paths says the class is structural: it rides on whatever the check happens to touch, and it survives precisely where a guard looks most obviously correct.

Take it as the measure of how hard this class is to see from inside.
The surrounding reasoning was sound, the suite was green, and all three of its own values were documented and deliberately chosen.
None of that was evidence against the class, which is exactly why a reviewer needs to be able to name it rather than argue it into existence each time.

## What this is not

It is not a gate.
Nothing here blocks work, no pipeline calls it, and no existing gate is weakened by it.
It is vocabulary and structure for reviews.

It does not replace three-valued evidence; it is one specific reason a claim is could-not-observe.
It does not license reporting a check as broken when the check is fine - the finding is about what the verdict is credited with, and the fix is often at the reader rather than in the code.
And a finding of this class is an assertion by its author, exactly like any other review finding: the tool renders it, and never validates it.
