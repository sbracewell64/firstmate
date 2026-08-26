# Parked-lane local custody: reachability and reopen proof

Owner: [`bin/fm-lane-custody.sh`](../../bin/fm-lane-custody.sh), consumed by [`bin/fm-teardown.sh`](../../bin/fm-teardown.sh).
Architecture: [`../architecture.md`](../architecture.md#parked-lane-local-custody).
Regression entry point: `bash tests/fm-lane-custody.test.sh`.

Two facts hold the design up, and neither is a property of firstmate's own code:

1. a ref under `refs/fm/` written from a linked worktree lands in the repository's SHARED ref store, not in the per-worktree one;
2. `git gc --prune=now` treats that ref as a reachability root, so returning the worktree and deleting the lane's branch cannot collect the parked commits.

Both are observed below rather than assumed, and the second is recorded together with the negative control that makes it evidence.
`bin/fm-lane-custody.sh park` also re-reads the ref from the shared store before it writes a record, so a git that changed the namespace rules refuses at park time instead of parking into the very worktree teardown is about to return.

## Observed 2026-08-26

Environment: Linux 6.18.33.2-microsoft-standard-WSL2, `git version 2.53.0`.

The fixture is one repository with a linked worktree on `fm/parked-lane` carrying one non-empty commit.
`$PROJ` is the primary checkout, `$SLOT` its linked worktree, and the expected identities are `head=ae40c20086522277e01815dabe707216c5b2a60f`, `tree=9b00b12a95c3abfeef748514e69e29ddf84a3b2d`.

### 1. Park, recycle the slot, collect everything unreachable

```
$ bin/fm-lane-custody.sh park parked-lane
custody: held task=parked-lane ref=refs/fm/custody/parked-lane/ae40c20086522277e01815dabe707216c5b2a60f head=ae40c20086522277e01815dabe707216c5b2a60f tree=9b00b12a95c3abfeef748514e69e29ddf84a3b2d branch=fm/parked-lane store=/tmp/fm-custody-proof.qFxLqu/proj/.git scope=lane

$ git -C $SLOT checkout --detach main && git -C $PROJ branch -D fm/parked-lane
Deleted branch fm/parked-lane (was ae40c20).

$ git -C $PROJ reflog expire --expire=now --expire-unreachable=now --all && git -C $PROJ gc --prune=now
$ git -C $PROJ cat-file -t ae40c20086522277e01815dabe707216c5b2a60f
commit
```

The commit survives with its worktree recycled, its branch gone, and every reflog entry expired.
`store=` in the park line is `$PROJ/.git`, the shared store, which is fact 1: the ref is readable from the primary checkout even though the worktree wrote it.

### 2. Verify and reopen

```
$ bin/fm-lane-custody.sh verify parked-lane
custody: held task=parked-lane ref=refs/fm/custody/parked-lane/ae40c20086522277e01815dabe707216c5b2a60f head=ae40c20086522277e01815dabe707216c5b2a60f tree=9b00b12a95c3abfeef748514e69e29ddf84a3b2d branch=fm/parked-lane store=/tmp/fm-custody-proof.qFxLqu/proj/.git scope=objects

$ bin/fm-lane-custody.sh reopen parked-lane --into $S/reopened
custody: held task=parked-lane reopened=/tmp/fm-custody-proof.qFxLqu/reopened ref=refs/fm/custody/parked-lane/ae40c20086522277e01815dabe707216c5b2a60f head=ae40c20086522277e01815dabe707216c5b2a60f tree=9b00b12a95c3abfeef748514e69e29ddf84a3b2d branch=fm/parked-lane identity=exact

$ git -C $S/reopened rev-parse HEAD HEAD^{tree}
ae40c20086522277e01815dabe707216c5b2a60f
9b00b12a95c3abfeef748514e69e29ddf84a3b2d

$ cat $S/reopened/work.txt
the work
```

Head, tree and content are the parked ones exactly.
`scope=objects` on the verify is the narrower answer that command is entitled to with no worktree in front of it: it speaks for the parked objects and says nothing about a lane.
The lane-scoped answer needs `--worktree`, and `--require-lane` refuses to hand back the narrower one in its place.

### 3. Negative control: the same sequence with no custody ref

```
$ bin/fm-lane-custody.sh release parked-lane --head ae40c20086522277e01815dabe707216c5b2a60f
custody: released task=parked-lane ref=refs/fm/custody/parked-lane/ae40c20086522277e01815dabe707216c5b2a60f head=ae40c20086522277e01815dabe707216c5b2a60f store=/tmp/fm-custody-proof.qFxLqu/proj/.git

$ git -C $PROJ reflog expire --expire=now --expire-unreachable=now --all && git -C $PROJ gc --prune=now
$ git -C $PROJ cat-file -t ae40c20086522277e01815dabe707216c5b2a60f
fatal: git cat-file: could not get object info
(exit 128)
```

With the custody ref released and nothing else holding the commit, the identical gc collects it.
Without this run, section 1 would be evidence about that particular gc rather than about the ref.

## Watched reds, observed 2026-08-26

Every refusal in `tests/fm-lane-custody.test.sh` is paired inside its own case: the unperturbed fixture is driven green first, then exactly one perturbation is applied.
That pairing excludes a mechanism that refuses everything, and it is the only reason a refusal is attributable to the perturbation.
The complementary direction was measured separately, by removing one production check at a time and re-running the whole suite, restoring the mutated file byte-identically between builds and confirming the restore by digest.

| check removed | first case to go red |
| --- | --- |
| teardown accepts a held custody | `teardown refused a parked lane` |
| verify's two-ref ambiguity refusal | `two custody refs for one task did not refuse: expected exit 3, got 0` |
| park's colliding-head refusal | `a second head for one task did not refuse: expected exit 3, got 0` |
| verify's lane clean check | `a lane dirtied after parking did not refuse: expected exit 3, got 0` |
| verify's ref-head equality check | `a moved custody ref did not refuse: expected exit 3, got 0` |
| verify's tree equality check | `a tree the head does not carry did not refuse: expected exit 3, got 0` |
| the record's task-binding check | `a misbound record did not report could-not-observe: expected exit 4, got 0` |
| verify's absent-object classification | `an absent parked commit did not refuse: expected exit 3, got 4` |
| teardown keeping the custody store | `teardown removed the custody record` |

The eighth row is there because the sweep found a defect in the test rather than in the code.
Its fixture originally pointed the record at a scratch store holding a custody ref at a DIFFERENT sha, so the case was refused by the ref-head check and never reached the object check it claimed to be about; removing the object check left it green.
The ref check and the object check reach the same refusal for different facts, and a case that trips the first proves nothing about the second.
The fixture now writes a ref FILE naming the recorded head over an absent object, which git resolves (`rev-parse --verify --quiet` exits 0 and prints the sha, while peeling it to `^{tree}` exits 1), and that is the only shape that reaches the object check.

## What these observations do NOT establish

They establish local reachability and nothing wider.
A parked lane survives worktree return, branch deletion, slot reuse and repository maintenance on THIS machine; it does not survive the loss of the machine, a fresh clone, or a repository someone deletes.
That is why teardown treats custody as the weakest of its three recoverability authorities and why it never parks a lane for itself.

They also say nothing about whether the parked work is correct, reviewed, current, or landable.
Custody is a claim about retrievability only.

## Refreshing this record

Re-run the sequence above, or run the regression that pins it:

```
bash tests/fm-lane-custody.test.sh
```

That suite drives the same reachability observation and its negative control in one fixture, and adds the refusals this record does not transcribe: a missing, moved or ambiguous custody ref, an object absent from the store, dirty bytes, a head that moved past the parked one, a stale task mapping, a second custody for a different head, teardown recognition and its refusal of the identical unparked lane, and an ordinary spawn recycling the same slot.
Re-measure rather than restamping this file when the git version changes, because fact 1 is a namespace rule a git release could move.
