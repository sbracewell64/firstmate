# Landing-resolution three-valuedness verification

This record cites no commit ids. The one commit-shaped string in it is a deliberately invalid value a transcript writes into a ref to manufacture a broken repository, not a commit reference.

Audience: maintainer verification.

This record holds the evidence that the exercised landing-library entry points never turn a single failed read into a definite negative, plus the safe-direction controls for their exercised consumers.

[`../../bin/fm-landed-lib.sh`](../../bin/fm-landed-lib.sh) owns the contract, the exit-status vocabulary, and the rule that a proven negative needs a successful read.
[`../../tests/fm-landed-lib.test.sh`](../../tests/fm-landed-lib.test.sh) owns the controls, including the class control that sweeps every read by index.
The exercised consumer directions are owned by [`../../tests/fm-teardown.test.sh`](../../tests/fm-teardown.test.sh) case (w2), [`../../tests/fm-worktree-guard.test.sh`](../../tests/fm-worktree-guard.test.sh) case (o9), [`../../tests/fm-task-base.test.sh`](../../tests/fm-task-base.test.sh), and [`../../tests/fm-slot-reservation.test.sh`](../../tests/fm-slot-reservation.test.sh) cases (6) and (20) through (22).

Verified on 2026-08-17 with git 2.53.0 and ShellCheck 0.11.0 on Linux 6.18.33.2-microsoft-standard-WSL2.
Re-run the commands below rather than trusting the recorded output.

## Safety boundary

`fm_landed_push_target_ref` distinguishes a repository with no distinct push target from one whose push target could not be read.
`fm_landed_candidate_refs` reports completeness in its status even when it can still print a non-empty partial list.
A partial list may prove a positive containment result, but only a complete list may support the negative conclusion that no landing target contains the work.

## Verified mechanism facts

Each fact below was observed rather than assumed, because each one decides whether a negative may be taken from a failing read.

### git separates "absent" from "could not read" by exit status

```sh
$ git --version
git version 2.53.0
$ git rev-parse --verify --quiet refs/heads/nope; echo "exit=$?"
exit=1
$ (cd /tmp && git rev-parse --verify --quiet refs/heads/nope 2>&1); echo "exit=$?"
fatal: not a git repository (or any of the parent directories): .git
exit=128
$ git symbolic-ref --quiet --short refs/remotes/origin/HEAD; echo "exit=$?"
exit=1
$ (cd /tmp && git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>&1); echo "exit=$?"
fatal: not a git repository (or any of the parent directories): .git
exit=128
```

Exit 1 is git reporting a successful read that found nothing, which is a proven absence.
Any other failing status is a read that did not happen.
`fm_landed_ref_exists` and `fm_landed_default_branch_name` classify on exactly that boundary.

### `git remote` enumerates, and an empty enumeration is evidence

```sh
$ git remote get-url origin 2>&1; echo "exit=$?"
error: No such remote 'origin'
exit=2
$ git remote; echo "exit=$? (empty listing)"
exit=0 (empty listing)
$ (cd /tmp && git remote 2>&1); echo "exit=$?"
fatal: not a git repository (or any of the parent directories): .git
exit=128
```

`git remote` prints nothing and succeeds for a repository with no remotes, and fails only when it could not read the configuration.
So `fm_landed_push_url` takes "there is no origin" from that enumeration rather than from `get-url` failing, which is the stronger evidence and does not depend on `get-url`'s status 2 keeping its current meaning.

### a broken ref is reported by git as absent, not as unreadable

```sh
$ echo deadbeefdeadbeefdeadbeefdeadbeefdeadbeef > .git/refs/heads/broken
$ git rev-parse --verify --quiet refs/heads/broken; echo "exit=$?"
warning: ignoring broken ref refs/heads/broken
exit=1
$ git for-each-ref --format='%(refname)' refs/heads/broken; echo "exit=$?"
warning: ignoring broken ref refs/heads/broken
exit=0
```

Both instruments classify object-level corruption as absence, and the only signal separating it is a warning string.
This library inherits git's classification rather than depending on that string.
Detecting repository corruption is a different question than "has this landed?", and it is named here as a limit rather than half-answered.

## Which direction each consumer falls

Established per consumer rather than assumed, because the safe direction is not the same in all of them.

| Consumer | Could-not-observe direction | Reason |
| --- | --- | --- |
| [`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh) `content_in_default` | refuse teardown | an unread landing target cannot establish that work is safe to discard |
| [`../../bin/fm-worktree-guard.sh`](../../bin/fm-worktree-guard.sh) `worktree_evidence` | refuse with unverifiable wording | a partial candidate universe cannot support a definite unlanded-commit count |
| [`../../bin/fm-task-base-lib.sh`](../../bin/fm-task-base-lib.sh) `task_base_upstream_ref` | report `unresolved` | unread remotes cannot justify collapsing the slot and contribution bases |
| [`../../bin/fm-task-base-lib.sh`](../../bin/fm-task-base-lib.sh) `task_base_venue` | refuse | an unread push url cannot be replaced with the fetch url without potentially naming the wrong forge |
| [`../../bin/fm-decision-surface.sh`](../../bin/fm-decision-surface.sh) | delegate to the landing owner | the surface names the library as owner and does not call it directly |
| [`../../bin/fm-slot-reservation-lib.sh`](../../bin/fm-slot-reservation-lib.sh) `fm_slot_reservation_read` | report `unobservable` and withhold nothing | a candidate universe read short cannot support the negative that the trunk has not moved, and a slot withheld on a reservation nobody can read is the permanent hold that record exists to avoid |
| [`../../bin/fm-slot-reservation.sh`](../../bin/fm-slot-reservation.sh) `open --trunk-ref` | refuse the ref | a ref whose membership in the landing set was never established would record a head no candidate ref can be shown to have advanced past |

The outbound-artifact consumer and its remaining landing-observation limit are documented in [`outbound-transport-invariant.md`](outbound-transport-invariant.md).

## The class control, and what it does not cover

`tests/fm-landed-lib.test.sh`'s final case does not name individual reads.
For each entry point it runs the call clean and requires the definite answer, counts the git invocations that call made, then fails each one in turn and requires could-not-observe every time.
A read added to any of these functions later is swept the day it is added, with no test edit - which is the point, since this defect was the sixth instance of one habit and a control that only knew about the sixth would be followed by a seventh.

Failures are injected at the tool boundary by a `git` shim (`fm_fake_git_fault` in [`../../tests/lib.sh`](../../tests/lib.sh)) that exits 128, because a fixture can only build a repository where something is genuinely absent and the whole distinction under test is between that and a read that did not happen.

The same sweep is applied to the second library on this path in `tests/fm-task-base.test.sh`, over `task_base_resolve` (9 reads) and `task_base_venue` (19 reads).
Its allowed set is deliberately not "could-not-observe every time", and the difference matters: some negatives there are established by a DIFFERENT read that succeeded - failing `remote get-url upstream` still leaves `git remote` to prove no such remote exists - so those answers are earned and must stand.
What it forbids is the collapse itself: no read failure may produce `coincident`, and none may name a venue other than the one the unperturbed derivation named.

Stated limits, so no reader credits it with more:

- It sweeps the reads REACHED by its fixtures. A branch no fixture enters is not swept.
- It bounds the class at these two libraries. A consumer that makes its own landing-shaped read outside them is covered only by that consumer's own suite, and `bin/fm-teardown.sh`'s own `content_in_default` reads are in that position.
- It fails one read per run. A correlated failure that takes out several reads at once is a different experiment, and a library that compensated for one failure by trusting another would not be caught by it.
- It inherits git's classification of a broken ref as absent, per the mechanism fact above.
- It proves nothing about concurrent mutation: a ref that appears between two reads is a different question.

The control is non-vacuous by construction rather than by inspection: every swept entry point must return its DEFINITE answer on the unperturbed fixture in the same case, so a library that answered could-not-observe to everything fails instead of passing.

## Running the controls

```sh
$ bin/fm-test-run.sh tests/fm-landed-lib.test.sh
$ bin/fm-test-run.sh tests/fm-worktree-guard.test.sh tests/fm-task-base.test.sh tests/fm-teardown.test.sh
```

Recorded result:

```text
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0
```
