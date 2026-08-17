# Landing-resolution three-valuedness verification

Audience: maintainer verification.

This record holds the evidence for one active guarantee: no read failure anywhere in the landing-resolution path produces a definite negative.

[`../../bin/fm-landed-lib.sh`](../../bin/fm-landed-lib.sh) owns the contract, the exit-status vocabulary, and the rule that a proven negative needs a successful read.
[`../../tests/fm-landed-lib.test.sh`](../../tests/fm-landed-lib.test.sh) owns the controls, including the class control that sweeps every read by index.
Each consumer's own suite owns the direction that consumer falls: [`../../tests/fm-teardown.test.sh`](../../tests/fm-teardown.test.sh) case (w2), [`../../tests/fm-worktree-guard.test.sh`](../../tests/fm-worktree-guard.test.sh) case (o9), and [`../../tests/fm-task-base.test.sh`](../../tests/fm-task-base.test.sh).

Verified on 2026-08-17 with git 2.53.0 and ShellCheck 0.11.0 on Linux 6.18.33.2-microsoft-standard-WSL2.
Re-run the commands below rather than trusting the recorded output.

## The defect

`fm_landed_push_target_ref` mapped every failed read of the push url to the same status as "this repository has no distinct push target".
The landing target was then simply absent from `fm_landed_candidate_refs`' output while that function still returned SUCCESS with a NON-EMPTY list, because the local branch and origin's trunk were still there.

That combination is what made it undetectable from any call site.
A caller could not see it in the status, because the status said success; and could not see it in the output, because the output was neither empty nor wrong - only short.
Containment was then tested against a partial universe and "not landed" concluded from it.

This was the sixth instance of one habit; five others were fixed in [`../../bin/fm-landing-authorization-lib.sh`](../../bin/fm-landing-authorization-lib.sh)'s lane, which made every read it owned three-valued and still could not detect a non-empty-but-incomplete candidate set from outside.

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

| Consumer | Effect of the collapse before the fix | Safe direction | Was it safe? |
| --- | --- | --- | --- |
| [`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh) `content_in_default` | with the push url unread, the landing target was never named and the UPSTREAM trunk answered instead | refuse | **no** - it released a worktree; see below |
| [`../../bin/fm-worktree-guard.sh`](../../bin/fm-worktree-guard.sh) `worktree_evidence` | a missing candidate can only reduce containment, so the slot was refused | refuse | act yes, reason no - it worded a definite commit count over a universe it never enumerated |
| [`../../bin/fm-task-base-lib.sh`](../../bin/fm-task-base-lib.sh) `task_base_upstream_ref` | an unread push url read as "no distinct upstream", collapsing the two base references onto one commit | `unresolved` | **no** - that collapse is the branch pollution the file exists to prevent |
| [`../../bin/fm-task-base-lib.sh`](../../bin/fm-task-base-lib.sh) `task_base_venue` | an unread push url was replaced by the fetch url, naming the wrong forge | refuse | **no** - [`../../bin/fm-pr-check.sh`](../../bin/fm-pr-check.sh) then refuses the task's own correct request |
| [`../../bin/fm-decision-surface.sh`](../../bin/fm-decision-surface.sh) | none directly: it names this library as the `work_landed` owner and calls none of it | refuse | delegated - fixing the delegate is what fixes the surface |

The teardown case is the one where the act, not only the wording, was wrong.
Its own header already claimed that an unreadable push url "refuses rather than falling back to the upstream answer", and that claim held for a push url whose TRUNK could not be fetched but not for a push url whose EXISTENCE could not be read - the second returned "nothing to refresh" and let the upstream trunk answer.
Measured against `tests/fm-teardown.test.sh` case (w2)'s fixture, pre-fix teardown exited 0 and released the worktree.

The `bin/fm-outbound-artifact.sh` pass named alongside these consumers is not present in this tree; that is a could-not-observe on this checkout, not a finding that it does not consume the library.

## The class control, and what it does not cover

`tests/fm-landed-lib.test.sh`'s final case does not name individual reads.
For each entry point it runs the call clean and requires the definite answer, counts the git invocations that call made, then fails each one in turn and requires could-not-observe every time.
A read added to any of these functions later is swept the day it is added, with no test edit - which is the point, since this defect was the sixth instance of one habit and a control that only knew about the sixth would be followed by a seventh.

Failures are injected at the tool boundary by a `git` shim (`fm_fake_git_fault` in [`../../tests/lib.sh`](../../tests/lib.sh)) that exits 128, because a fixture can only build a repository where something is genuinely absent and the whole distinction under test is between that and a read that did not happen.

The same sweep is applied to the second library on this path in `tests/fm-task-base.test.sh`, over `task_base_resolve` (9 reads) and `task_base_venue` (19 reads).
Its allowed set is deliberately not "could-not-observe every time", and the difference matters: some negatives there are established by a DIFFERENT read that succeeded - failing `remote get-url upstream` still leaves `git remote` to prove no such remote exists - so those answers are earned and must stand.
What it forbids is the collapse itself: no read failure may produce `coincident`, and none may name a venue other than the one the unperturbed derivation named.
Pre-fix, failing read #5 of `task_base_resolve` produced `coincident`.

Stated limits, so no reader credits it with more:

- It sweeps the reads REACHED by its fixtures. A branch no fixture enters is not swept.
- It bounds the class at these two libraries. A consumer that makes its own landing-shaped read outside them is covered only by that consumer's own suite, and `bin/fm-teardown.sh`'s own `content_in_default` reads are in that position.
- It fails one read per run. A correlated failure that takes out several reads at once is a different experiment, and a library that compensated for one failure by trusting another would not be caught by it.
- It inherits git's classification of a broken ref as absent, per the mechanism fact above.
- It proves nothing about concurrent mutation: a ref that appears between two reads is a different question.

The control is non-vacuous by construction rather than by inspection: every swept entry point must return its DEFINITE answer on the unperturbed fixture in the same case, so a library that answered could-not-observe to everything fails instead of passing.

## Reproducing the defect and the controls

Point the suite's library at the pre-fix copy and every control fails; the class sweep reports status 0 - a claim of a COMPLETE candidate set - for every one of the five reads `fm_landed_candidate_refs` makes on a fetch/push split:

```sh
$ git show <pre-fix-rev>:bin/fm-landed-lib.sh > /tmp/old-landed-lib.sh
# with the suite's fault-injecting git shim on PATH, against the fetch/push split fixture:
  fm_landed_push_url            -> 1 (want 2)
  fm_landed_push_target_ref     -> 1 (want 2)
  fm_landed_refresh_push_target -> 0 (want 1)
  candidate_refs status         -> 0 (want 2), list non-empty: yes, landing ref present: no
  failing read #1..#5           -> status 0 (want 2)
```

Post-fix, the same measurements return 2, 2, 1, 2 and 2 for every read index, with the list still non-empty and still missing the landing ref - the list is unchanged and only the completeness claim moved, which is the whole correction.

Run the controls:

```sh
$ bin/fm-test-run.sh tests/fm-landed-lib.test.sh
$ bin/fm-test-run.sh tests/fm-worktree-guard.test.sh tests/fm-task-base.test.sh tests/fm-teardown.test.sh
```
