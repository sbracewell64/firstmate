# Worktree allocation safety verification

Audience: maintainer verification.

This record supports the pre-allocation guard in `bin/fm-worktree-guard.sh` and its call site in `bin/fm-spawn.sh`.
It records only the treehouse behavior the guard's placement and shape depend on, so a treehouse version bump can be re-checked against it.
Incident chronology and delivery evidence stay in private reports or PR evidence.

The regression coverage is `tests/fm-worktree-guard.test.sh`.

## Why the guard runs before `treehouse get`, not after

Verified 2026-08-02 against treehouse v2.1.0, in an isolated throwaway pool.

`treehouse get` resets the slot while acquiring it, before it returns a path.
The binary states this itself:

```
$ treehouse enter --help
Unlike 'get', enter does not acquire, reset, or return the worktree: it
```

Measured directly: a slot on a branch with an unlanded commit and a clean working tree was handed out, and its HEAD moved from the branch to the default branch.

```
--- slot2 before: branch=fm/composer-nbsp-fix-sim sha=12ad5b2 dirty=[]
=== get
handed out -> .../repo-5c2ced/2/repo
--- slot2 after:  branch=HEAD sha=4fe9d25
--- branch ref still exists? 12ad5b23b8b976f4e773d1415e3a234978e5610e
```

`bin/fm-spawn.sh` learns the worktree path by polling the pane's current path, which only changes after that reset.
A check placed where the path becomes known therefore inspects a slot whose evidence has already been erased, and passes every time.
This is why the guard is a pre-allocation check over the slots treehouse reports allocatable, not a post-acquire inspection of the accepted worktree.

## How the slot is chosen, and why `enter` is what acquires it

Verified 2026-08-07 against treehouse v2.1.0, in an isolated throwaway pool with `max_trees = 4`.

`get` takes no slot argument and hands out the lowest-numbered available slot, so one parked slot early in the pool blockades every later empty one.
Measured with slot 1 on an unlanded branch, slot 2 clean, and slot 3 on an unlanded branch:

```
$ treehouse status                      # 1, 2, 3 all "available"
$ treehouse get --lease --lease-holder pick
.../proj-43a5c8/1/proj                  # the parked slot, not the clean one
$ git -C .../1/proj symbolic-ref --short HEAD || git -C .../1/proj rev-parse --short HEAD
detached at 211db19                     # the branch was detached out from under it
```

`enter <name>` acquires a named slot without that reset, which is what makes steering possible:

```
$ treehouse enter --print-path 3
.../proj-43a5c8/3/proj
$ git -C .../3/proj symbolic-ref --short HEAD
fm/work-3                              # untouched, and status still reports it "available"
```

Because `enter` leaves pool state untouched, the acquiring claim is the occupancy itself.
A slot is reported `in-use` and skipped by `get` while any process's cwd is inside it - a bare `sleep` is enough:

```
$ (cd .../2/proj && sleep 120 &)
$ treehouse status
2     in-use       .../proj-43a5c8/2/proj
                   sleep (3783741)
$ treehouse get --lease --lease-holder pick2
🌳 Leased worktree at .../proj-43a5c8/3/proj      # 2 was skipped
```

Measured 2026-08-07 against the same v2.1.0, in the same isolated throwaway pool: with the holder process running, the slot reports `in-use`, and `enter` still acquires it by name in both forms the code uses - the `--print-path` form and the interactive form the pane actually runs:

```
$ treehouse status
2     in-use       .../proj-43a5c8/2/proj
                   sleep (880066)
$ treehouse enter --print-path 2
.../proj-43a5c8/2/proj                            # exit 0
$ treehouse enter 2
Entered worktree 2 at .../proj-43a5c8/2/proj. Type 'exit' to leave.
Left worktree. Pool state unchanged.
```

This is treehouse's documented behavior, not an accident of version: `treehouse enter --help` states it opens a worktree by name "including worktrees that are already in use".

`bin/fm-spawn.sh` therefore holds the chosen slot with one short-lived process of its own from the moment it chooses the slot until the pane's own shell is inside it, which is the only window in which another home's `get` could still take it.
`get` and `enter` differ in nothing else that matters here: neither removes ignored files, and treehouse's config carries no setup hooks (`treehouse init` writes only `max_trees` and `root`).
The slot is still placed at the resolved slot base by `fm-spawn.sh` itself, under its own guards, so nothing depends on `get`'s reset.

The release side is unchanged, because `treehouse return` is addressed by path and does not care how the slot was acquired.
A slot acquired by `enter` alone, carrying a branch and live processes, was returned by exactly the call `bin/fm-teardown.sh` makes:

```
$ treehouse return --force .../proj-43a5c8/3/proj
🌳 Terminated lingering processes: bash (478542), sleep (478546)
🌳 Worktree returned to pool.
$ treehouse status          # 3 available again, HEAD detached back at the default branch
```

## What treehouse already protects, and what it does not

Verified 2026-08-02 against treehouse v2.1.0.

Uncommitted content is protected by treehouse itself.
A dirty slot is reported `dirty`, is skipped by `get`, and is not reclaimed even when every slot in an exhausted pool is dirty:

```
$ printf 'max_trees = 2\nroot = "./"\n' > treehouse.toml   # both slots dirty, unleased
$ treehouse get --lease
all 2 worktrees are in use or dirty (max_trees = 2). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml
--- slot1 after: [ M f.txt ?? untracked-precious.txt ]
--- slot2 after: [ M f.txt ]
```

Commits unreachable from the default branch are not considered.
The same slot that `get` detached above is reported allocatable while it still holds the branch:

```
$ treehouse status --json
[{"name":"2","status":"available","path":".../2/repo",...}]   # while on fm/composer-nbsp-fix-sim
```

So the exposure the guard closes is specifically a clean working tree plus content that no landing target carries.
`get` also prefers reusing an available slot over creating a new one below `max_trees`, so an at-risk available slot is the next one handed out rather than a remote possibility.

## What "unlanded" is measured against

Verified 2026-08-03, against git 2.53.0 in isolated throwaway pools.

A remote-tracking ref is the landing target only for a fleet that pushes to that remote and refetches it, and neither repository in this fleet does.
`origin` here fetches from an upstream but pushes to a fork, so `refs/remotes/origin/main` tracks upstream while the fork trunk is the local branch.
A slot sitting on the fork trunk exactly, with zero content difference from it, was refused:

```
$ git -C slot1 rev-parse HEAD; git -C proj rev-parse main     # identical
597f72c...                                                    597f72c...
$ fm-worktree-guard.sh check proj
    found: detached HEAD with 3 commits not on remotes/origin/main
```

The same defect was measured the same day in a second, unrelated pool whose remote is simply never advanced, because that project replays and fast-forwards locally by design.
Its slots refused with 286, 360, 361 and 362 `commits not on remotes/origin/v1.2-recovery`, while on every one of them the working tree was clean, `merge-base --is-ancestor HEAD v1.2-recovery` passed, and `rev-list --count v1.2-recovery..HEAD` was 0.
One slot in that same pool was a genuine true positive carrying three real unlanded commits, so the guard was never simply broken; it was measuring against the wrong ref.
The defect is therefore remote-tracking ref versus local trunk in general, not anything fork-specific, and `tests/fm-worktree-guard.test.sh` case (o5) pins both verdicts surviving in one pool.

Commit reachability is also the wrong instrument on its own, because a squash merge leaves a landed branch permanently "ahead":

```
$ git -C slot2 rev-list --count refs/heads/main..HEAD         # after its content was squash-merged
2
```

`bin/fm-landed-lib.sh` therefore tests whether a ref already CONTAINS what HEAD introduces, by 3-way merging and comparing trees, and the guard accepts a slot when any ref carrying the default branch's name contains it.
Containment in any trunk proves the content outlives the slot.
That widening cannot launder unlanded work: content no candidate carries is reported contained by no candidate, which `tests/fm-worktree-guard.test.sh` cases (q) and (q2) pin against a slot in this same stale-remote shape.

### The fork trunk needs a ref of its own

Measured 2026-08-05 in the firstmate home, where `origin` fetches `kunchenguid/firstmate` but pushes `sbracewell64/firstmate`.
Both conventional refs were wrong at once: `refs/remotes/origin/main` tracked upstream, and `refs/heads/main` had not been fast-forwarded since the fork trunk advanced five times that day.
Pull request 44 was squash-merged, its recorded head `2582c15` was byte-identical to the fork trunk `f90ed1d`, and the slot still refused teardown:

```
$ git diff --stat 2582c15 f90ed1d                    # content demonstrably landed
$ git merge-base --is-ancestor 2582c15 f90ed1d ; echo $?
1                                                    # squash: ancestry cannot hold
```

The default fetch refspec cannot reach the fork, because it points at the fetch url.
`fm_landed_push_url` therefore resolves the push url when it differs from the fetch url, and `fm_landed_refresh_push_target` fetches that trunk into `refs/fm-landing/origin/<name>`, which `fm_landed_candidate_refs` then offers like any other candidate.
The ref is a landing target only because this fleet demonstrably pushes there; it is never inferred from a remote's name.
Only a caller that already refreshes remotes performs that fetch, so the guard stays local and never grows a network dependency.
A push url that exists but cannot be read leaves the landing target unread, and `bin/fm-teardown.sh` refuses rather than falling back to the upstream answer.
So does a push url whose very existence could not be read; [`landing-resolution.md`](landing-resolution.md) owns that boundary and the evidence for it.
`tests/fm-worktree-guard.test.sh` cases (o6) through (o9) and `tests/fm-teardown.test.sh` cases (u) through (y) pin the fix, the preserved refusals, the unread-target refusals, and the unchanged single-remote path.

## What the guard writes

Verified 2026-08-03, against git 2.53.0.

`git merge-tree --write-tree` writes its merged tree into the object store, so the containment test is not purely read-only.
Measured on a slot whose merge result was a genuinely new tree:

```
loose objects: 25 -> 26   (delta 1)
merged tree 696a3ec... type=tree
referenced by any ref? 0
HEAD/index/worktree still untouched: HEAD=f1f9fd9 dirty=''
```

The one object it adds is a dangling tree that no ref reaches, so `git gc` collects it, and no ref, HEAD, index, or working-tree file changes.
This is the same instrument `bin/fm-teardown.sh` already runs against these repositories.

## Why `--json` is preferred, and why a fallback is still required

Verified 2026-08-02 against treehouse v2.1.0 and v2.0.1.

`treehouse status --json` reports absolute paths and a stable per-slot schema, and prints `[]` for a pool with no slots.
An empty stdout is therefore never a valid empty-pool signal on that format, and the guard refuses rather than treating it as one.
`jq` is required whenever that format is used, and its absence is a refusal.

That flag does not exist before v2.1.0, and `bin/fm-install-treehouse.sh` pins v2.0.1 for CI:

```
$ treehouse --version
v2.0.1
$ treehouse status --json
unknown flag: --json
$ treehouse status --help
Flags:
  -h, --help   help for status
```

The same defect is present there - v2.0.1 also reports a clean slot holding an unlanded branch as `available` - so the guard must still inspect the pool on that build rather than refuse every spawn.
Capability is probed from `status --help` advertising `--json`, not from the error text and not from a version string.

The fallback parses the human-readable table, which needs two compensations the machine format does not.
A path under `$HOME` is printed abbreviated with a leading `~`, and a slot may be followed by indented per-slot process continuation lines:

```
1     in-use       ~/.treehouse/kun-agent-workspace-8bf1b0/1/kun-agent-workspace
                   bash (44801), claude (44970)
2     dirty        ~/.treehouse/kun-agent-workspace-8bf1b0/2/kun-agent-workspace
```

An empty pool prints nothing at all in this format, unlike `[]` in the machine format.
Every non-blank, non-indented line must parse as a slot row; an unparseable one refuses rather than being skipped, since dropping a row would silently leave a slot uninspected.

## treehouse must be executable from fm-spawn's own environment

Before this guard, `bin/fm-spawn.sh` never ran `treehouse` itself: it sent the literal text `treehouse get` into the task pane, so only the pane's shell needed it on `PATH`.
The guard runs `treehouse status --json` from fm-spawn's own process before allocating, so `treehouse` and `jq` must both resolve there.
Either one not being resolvable is a refusal with the missing dependency named, not a silent pass.

## Ownership is a process identity, not a pid

A recorded pid alone cannot establish ownership across a restart: the kernel reissues pid numbers, so a pre-restart pid often resolves to an unrelated live process and reads as falsely alive.
`bin/fm-spawn.sh` therefore records `worktree_owner_pid` and `worktree_owner_identity` in `state/<id>.meta`, and the guard compares the recorded identity with `fm_pid_identity` (`bin/fm-wake-lib.sh`) rather than probing the pid.

An absent record reads unresolved, never as a released slot, so a home that has never recorded an identity cannot have its slots reclaimed on that basis.

A recorded pid is also the weakest evidence available, and only ever evidence *for* liveness.
It names one process sampled when the slot was accepted, so it stops matching for reasons that say nothing about the task: a reboot, or that sampled process simply exiting while the worker runs on.
Measured 2026-08-04 in this fleet, a slot whose worker was live and driving a validation pipeline was reported as `its worker is gone (recorded process identity no longer matches)`.
Stronger bindings are therefore read first, and any one of them carries the live verdict alone:

- `HERDR_PANE_ID` in a live process's `/proc/<pid>/environ` matching the task's recorded `herdr_pane_id`. Herdr injects it into every process it manages a pane for (`docs/herdr-backend.md`).
- `GOTMPDIR` matching `<tasktmp>/gotmp`, which `bin/fm-spawn.sh` exports into the pane before the agent starts, so a backend that records no pane id is still covered.
- A live process whose cwd is inside the slot.

Only a mismatched identity with none of those present reads dead.
`tests/fm-worktree-guard.test.sh` case (s3) pins each binding carrying the verdict on its own, with a negative control per binding and a near-miss value that must not read alive.

## The one slot a queued trunk repair may be held

Verified 2026-08-18, against the shipped build and twelve defect builds, by `tests/fm-slot-reservation.test.sh`.

A pool may carry one reservation, which withholds a single demonstrably empty slot from every dispatch except the one task it names.
`bin/fm-slot-reservation-lib.sh` owns the record, the admission predicate, and the release conditions; `bin/fm-worktree-guard.sh` applies it; `bin/fm-pool-lib.sh` owns where a pool's machine-private state lives, so the reservation and the pool selection lock cannot disagree about which directory that is.

### The honest bound, which is the reason it exists and the reason it is small

On 2026-08-16 the trunk was red, every pool slot held live work, and the repair stayed queued for hours behind unrelated dispatches while every lane cutting a worktree cut it from a broken trunk.

**This would not have fixed that day.**
The fleet was genuinely full and the repair would still have waited.
What a reservation does is bound the worst case - the repair waits for the next slot rather than for a slot it happens to win - not remove the wait.
It creates no capacity, guarantees no time bound, and promises no immediate start, so it must not be described as preventing trunk-red starvation.

### What it may not do

It never preempts.
The reservation is read strictly after the emptiness test above, never in place of it, so no running lane is stopped, evicted, or reclaimed for one, and no slot holding unlanded work is touched.
That is structural rather than a policy: there is no path through the applier that hands out a slot this guard would otherwise have refused.
Case (3) pins it, and its defect build - the applier reached with the last-inspected occupied slot - is observed handing out a slot holding live work.

It reserves one slot, not the pool, and it decides no order.
A pool holds one reservation; a second request is refused naming the current holder rather than queued behind it, because choosing between several waiting repairs is a scheduler and none was asked for.
Cases (8) and (10) pin both halves.

### What counts as a trunk repair

The predicate is established from state the opener resolves itself, never from what the requesting task says about itself.
Opening one requires a project whose default branch resolves through `bin/fm-landed-lib.sh`, a trunk head the opener reads for itself rather than accepting from the caller, and a `bin/fm-verify.sh` record whose result is `FAIL`.
`PASS` is refused because a trunk observed good needs no repair, and `NO_VERIFIER_RAN` is refused because an observation that did not happen is not evidence.

That third condition is corroboration and not proof, and the boundary is stated rather than implied: firstmate declares no trunk-checks verifier today, so what can be required is that an observation ran and returned `FAIL`, not that a particular check proved this particular trunk red.
Declaring such a verifier is the way to tighten it.
What keeps that proportionate is the bound above - a reservation grants no capacity and cannot preempt, so the worst an unjustified one does is withhold one empty slot, visibly, until it expires.
Case (9) pins the admission, including that the record names the observation that admitted it.

### How it ends, which is stated because state nobody ends becomes a permanent hold

Three release conditions, any one of which ends it:

| Condition | Reached when | Case |
| --- | --- | --- |
| claimed | its holder is handed the slot, which `select` consumes at that moment | (11) |
| `landed_or_superseded` | the recorded ref no longer points at the recorded head, so the repair landed or something else ended the situation | (5) |
| `expired` | the TTL, default 7200 seconds and recorded in the record, has run out | (4) |

The TTL is the unconditional backstop for the abandoned case and needs no other condition to hold: a dropped repair leaves a trunk that never moves, so without a clock the record would withhold a slot until a person noticed it.
It is deliberately shorter than a repair might take, because expiry does not cancel a repair - it only stops withholding a slot for one - while a TTL long enough to cover every repair is long enough for an abandoned reservation to survive into a day nobody remembers opening it.

The clock is therefore checked before the trunk read, because a clock is readable whatever else is broken.

### Three-valued throughout

`absent` and `unreadable_record` are different facts and reach different branches with different output.
An absent reservation is silent, because nothing is being withheld.
A reservation whose state could not be observed - an unparseable record, or a trunk ref that could not be resolved - withholds nothing **and says so**, because a slot silently withheld on a record nobody can read is precisely the invisible permanent hold this design exists to avoid.
Case (6) pins the distinction against a defect build that collapses the could-not-observe branch into the same silence as absence.

### Non-vacuity

Case (7) is the control: with no reservation in the pool, an ordinary dispatch still gets a free slot.
Case (12) is the acceptance sequence end to end - a full pool starts nothing, one slot frees, an unrelated dispatch reaches the pool first and is refused, and the queued repair takes the slot that freed.

Every case is asserted green against the shipped build and red against its own defect build planted in the exact production bytes it depends on, and the suite closes on positive executed counts rather than an absence of failures:

```
$ bash tests/fm-slot-reservation.test.sh | tail -3
FM_TEST_CONTRACT suite=fm-slot-reservation.test.sh status=pass
FM_SLOT_RESERVATION_COUNTS properties_green=12 defect_builds_red=12
```

A plant whose target bytes are absent, or present more than once, fails its case outright, so a defect build that did not apply can never leave an ordinary green run reading as a watched red.

## Boundaries this guard does not cross

The guard never resets, cleans, forces, discards, or releases a slot; it only names one to allocate, or refuses the spawn.
`bin/fm-teardown.sh` remains the sole releaser of a slot holding work and the owner of the complete recoverable-work test.
The guard deliberately asks the strictly weaker, offline question "is this slot demonstrably empty?", so it neither restates nor weakens that contract.
It shares only the containment instrument with teardown, never teardown's policy: teardown refreshes the remote first and measures against it, which the guard must not do because it inspects every available slot before every spawn.
Every git read uses `--no-optional-locks` so inspecting another lane's worktree never writes its index, and the single dangling tree object recorded above is the only thing it adds.
