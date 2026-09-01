# Production commit provenance verification

Audience: maintainer verification.

This record holds reusable evidence for one active guarantee of [`../../bin/fm-commit-identity.sh`](../../bin/fm-commit-identity.sh): that every production commit path this fleet can reach resolves the authoritative production author and committer, and that a path which cannot be shown to do so refuses before a commit object exists.
[`../../bin/fm-commit-identity-lib.sh`](../../bin/fm-commit-identity-lib.sh)'s header owns the channel precedence and the honest limits, that command's header owns the verb contract and exit statuses, and [`../configuration.md`](../configuration.md) "Publication identity policy" owns the schema the authoritative identity is declared in.

Verified on 2026-09-01 on Linux 6.18.33.2-microsoft-standard-WSL2 with git 2.51.0, jq 1.8.1, shellcheck 0.11.0, and no-mistakes v1.40.3.
The controls below were exercised at implementation head `74321f98c871b4259663503594d2e3192cc6362e` after the launch admission and its venue, worktree-isolation, pre-allocation, and fixture-reaping refinements were added.

## The defect this record is built from

This was not a hypothesis.
Four generations of independent observation recorded durable production commits on open pull requests carrying `Test <test@example.com>` as BOTH git author and committer, mapped by GitHub to an unrelated account, across the `review`, `document`, CI-fix and fixer commit-producing stages.
The exact contaminating selector was recorded as could-not-observe throughout: environment, repository configuration, global configuration, fixture leakage and resumed process state were all live candidates and none was asserted.

## The selector, reproduced

The selector is the machine's GLOBAL git identity, reached because the repository the validation pipeline commits in declares none of its own.

```sh
$ git config --global --get-regexp '^user\.'
user.email test@example.com
user.name Test

$ for d in ~/.no-mistakes/repos/*.git; do git --git-dir="$d" config --local --get user.email; done | wc -l
0                       # 79 gate repositories, not one repository-local identity

$ git --git-dir=~/.no-mistakes/repos/5f306883d81c.git var GIT_AUTHOR_IDENT
Test <test@example.com> 1788248010 -0400

$ tr '\0' '\n' < /proc/$(jq .pid ~/.no-mistakes/daemon.pid)/environ | grep -c '^GIT_\(AUTHOR\|COMMITTER\)_'
0                       # the daemon names no identity, so git falls through to the global one
```

That also explains the shape that hid it for four generations.
The fleet's own checkout DOES carry a repository-local identity, so a worker's own commits were correct while the pipeline's were not, and correct and defective provenance therefore alternated inside a single branch.
Both facts were confirmed against the published commit objects:

```sh
$ gh-axi api repos/sbracewell64/firstmate/commits/48157bdb --jq '.commit.author.email'
sbracewell64@gmail.com  # worker commit, made in the checkout
$ gh-axi api repos/sbracewell64/firstmate/commits/766b4d9c --jq '.commit.author.email'
test@example.com        # "no-mistakes: apply CI fixes", made in the gate repository
```

## Channel precedence, measured

Git resolves committing identity from the environment first, then repository-local configuration, then global configuration.
Every part of the design follows from this measurement rather than from the documentation:

```sh
$ git -C gatewt var GIT_AUTHOR_IDENT                       # no local identity, poisoned global
Test <test@example.com> ...
$ git --git-dir=gate.git config user.name 'Shane Bracewell'   # bind the repository
$ git -C gatewt var GIT_AUTHOR_IDENT
Shane Bracewell <sbracewell64@gmail.com> ...
$ GIT_AUTHOR_NAME=Poison git -C gatewt var GIT_AUTHOR_IDENT   # environment still outranks it
Poison <poison@example.invalid> ...
```

The last line is why the pipeline daemon's environment is OBSERVED rather than assumed, and why a daemon carrying an identity variable is a refusal rather than a note.

## The real production path

Run against the real checkout and the real gate repository, the read-only verdict reproduced the published defect before any commit was made, and the binding closed it:

```sh
$ bin/fm-commit-identity.sh check .
gate     : NOT BOUND - would commit as author Test <test@example.com> / committer Test <test@example.com>
verdict:   REFUSED - do not create production commits until the channel above is repaired   # exit 1

$ bin/fm-commit-identity.sh bind .
checkout : bound - Shane Bracewell <sbracewell64@gmail.com>
gate     : bound - Shane Bracewell <sbracewell64@gmail.com>
daemon:    clean - pid 3349937 sets no identity variable that would outrank the gate binding
verdict:   FM_CI_BOUND_EXACT - every reachable production commit path resolves the authoritative identity   # exit 0
```

## The suite

```sh
$ bash tests/fm-commit-identity.test.sh | tail -1
FM_TEST_CONTRACT suite=fm-commit-identity.test.sh status=pass
```

Twenty-seven controls observe a real commit object's author and committer, the absence of one, or the launch boundary that prevents either production path from becoming reachable.

## Watched reds

The suite carries its own red as a first-class control rather than only as a mutation: `test_an_unbound_gate_reproduces_the_published_defect` makes a commit the way the pipeline made the contaminated ones and asserts `Test <test@example.com>` appears in both fields.
If that control ever stops reproducing the defect, every positive control in the suite is vacuous and must not be believed.

The binding itself was additionally driven red by mutation, replacing the two `git config` writes in `fm_commit_identity_install_repo` with a no-op:

```
checkout : UNVERIFIED - the identity was written into .../checkout but git does not report it back
gate     : UNVERIFIED - the identity was written into .../gate.git but git does not report it back
verdict:   REFUSED - do not create production commits until the channel above is repaired
not ok - after binding, an ordinary commit on each production path carries the authoritative author and committer: expected exit 0, got 1
```

That the mutation surfaces as UNVERIFIED rather than as a silent pass is the re-observation step working: the command never credits a `git config` write it did not read back.

The retargeted-venue launch control was observed failing against the prior launch gate because the spawn path selected the checkout origin's identity instead of the finalized contribution venue.
The same-project launch control was observed failing against the prior repository-local binding because the second launch replaced the first launch's identity in their shared config.
Both controls now drive bounded real launches and observe commit objects in the task worktrees, while the unresolved-venue companion refuses before publishing a task record.
The distinct-role no-gate launch was observed passing phase-one validation and allocating its endpoint against the prior head before phase two refused it.
It now refuses with both declared roles and `FM_CI_REPO_IDENTITY_DISTINCT` before the fixture observes any slot or endpoint allocation.

The remaining ruling-required reds are individually held by the suite: a poisoned `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment refuses by name and creates zero commits; poisoned repository-local and global configuration both lose to the binding; fixture activity establishing a `Test` identity in the same session does not cross the boundary; a restart between commits leaves the bound provenance as the sole selector; an unstated, placeholder, malformed, ungoverned or undeclared identity refuses with its own token and creates nothing; and a pipeline daemon carrying an identity variable refuses.

## The admission is the launch owner, not the brief

An earlier generation of this work bound correctly and was still not closed, because the only thing that made a worker run the binder was a sentence in a generated brief.
A worker that skipped it, a resumed session that never read it, and a pipeline started by hand all reached commit creation in exactly the unbound state the recurrence red reproduces.

The binding is therefore a precondition of [`../../bin/fm-spawn.sh`](../../bin/fm-spawn.sh), the owner nothing this fleet dispatches exists without passing through.
Before allocation it resolves and validates the finalized venue and identity, rejects ambient overrides, binds and re-observes the pipeline gate repository, observes the daemon environment, and proves that the identity can be installed and re-observed through the current project worktree's worktree-scoped channel.
After the isolated task worktree is known, it installs those already-validated values into that worktree's scoped config and re-observes only that mechanical write before worker execution.
The brief keeps its call as projection, and it earns its place for a reason a launch-time bind cannot cover: it runs in the WORKER's own process, so it is the only check that sees the worker's environment, which outranks every repository binding.

`test_a_launch_whose_identity_cannot_bind_is_mechanically_refused` drives the real launch path with no brief instruction anywhere and a policy whose identity cannot be bound, and requires that no task record is published and no endpoint exists.
`test_an_unobservable_worktree_binding_refuses_before_any_launch_allocation` makes the worktree-scoped channel unreadable and requires refusal before a task record, slot, or endpoint exists.
`test_an_ordinary_launch_binds_both_production_paths_with_no_manual_step` starts through the ordinary lifecycle with nothing invoking the binder, then makes real commits both ways production commits are actually made - by the worker in its slot and by a pipeline stage in the gate repository - and requires the authoritative author and committer on both.
A home that declares no publication identity policy launches and says so, which is this fleet's existing reading of that absent file at the publication seam rather than an exception opened here.

The refusal control was driven red by removing the launch gate, which is the demonstration that it measures the gate and not something incidental:

```
not ok - a launch whose production identity cannot be bound must refuse: notice: unbindable
  launches with commit provenance ungoverned - this home declares no publication identity
  policy, so there is no authoritative production identity to bind
```

Without the gate the launch simply proceeds, which is precisely the state the earlier candidate shipped in.

## A defect this record exists to remember

The daemon environment check compares the process start time against the time the pipeline recorded, so a reused PID cannot pass as the daemon.
Its first implementation read `ps -o lstart=`, which prints LOCAL time with no zone designator, and parsed it with `date -u`, which reads a zone-less string as UTC.
Every comparison was therefore off by the host's UTC offset, and on this host a live, correctly-running daemon was permanently unidentifiable:

```sh
$ date +%z
-0400
$ recorded=1787747390; process=1787732990; echo $(( recorded - process ))
14400                   # exactly four hours: the offset, not a different process
```

The suite did not catch it, and the reason is the part worth keeping.
The fixture converted its own timestamp with the same `date -u -d` mistake, so fixture and implementation agreed with each other while neither matched a real daemon.
A green suite proved the code was self-consistent, not that it could identify anything.
Both sides now parse local time as local and convert through an unambiguous epoch, and the result was checked against the real running daemon rather than only against the fixture.

That defect mattered beyond its own correctness: an unidentifiable daemon is could-not-observe, and once the binding became a launch precondition, could-not-observe refuses. Shipped as it was, it would have blocked every dispatch in this fleet.

## The shared validation repository, and the option that was rejected

That repository is shared per project and holds ONE identity pair, so two same-project lanes governed by different venues cannot both be served by it.
Lane A binds it, lane B later binds it to a different identity, and lane A's pipeline stages then commit as B - with nothing wrong in either lane.

Two remedies were available and they produce different fleets.

**Rejected: re-establish at each lane's own boundary.**
Admit both lanes and have each re-assert the repository immediately before its own pipeline can commit.
It preserves parallelism, and it is what the ruling's own wording contemplates.
It was rejected because the last moment this fleet owns is the launch and the worker's pre-pipeline step: a sibling that rebinds while a run is already MID-FLIGHT still lands a wrong immutable object, and that window cannot be closed without the pipeline's cooperation.
A remedy that narrows a hole is not the same as one that closes it, and the difference is invisible in a green test run.

**Adopted: refuse the contended interval.**
A lane is admitted only when no other live lane holds that same repository under a different identity.
The refusal is a WAIT and not a failure - nothing is allocated, no attempt is spent, no task record is written, and the dispatch becomes admissible again as soon as the holder is released, through the ordinary re-evaluation of queued work.
It reads only the task records this home already keeps, so no second registry exists and nothing outlives those records.

The cost is real and bounded: two same-project lanes with different governed venues no longer run at once.
That is exactly the cone the ruling permits constraining, and `test_same_identity_lanes_on_one_project_are_not_contended` holds the boundary by requiring that same-identity lanes on one project still run together.

Ordering matters as much as the check.
Validation deliberately does NOT write to that repository; the write happens after custody is settled.
An earlier revision of this work validated and bound in one step, so a lane that was about to be refused had already rebound the repository - the control caught it, reporting the holder's pipeline path carrying the refused lane's identity.

Both new controls were driven red before their fix.
Removing the custody check yields:

```
not ok - a contended shared gate must refuse the second lane
```

The concurrent-admission control calls the custody owner function directly with its explicit bounded barrier parameter after the custody read and before claim publication; production calls that function without a barrier, and every other custody control continues to exercise real launches.
Against the raw-path lock-key mutation, both path-aliased contenders reached that barrier and both claims were published, producing `not ok - the custody owner must admit exactly one unlike identity: a=0 b=0 arrivals=2`.
Against the repaired owner, one contender reached the barrier and published while holding the canonical gate lock, then the other refused after its custody read, producing one admitted claim and one arrival.
The launch-path alias control concurrently gives two differently governed lanes physical and symlinked spellings of one project and gate, and requires exactly one admission.

## What this does NOT establish

The honest scope is narrower than "the fleet cannot publish a contaminated commit", and the difference matters.

- A `git commit` typed by hand and a provider web UI are outside any of this, and always will be; server-side protection is the separate defence for those.
- The launch gate covers what this fleet DISPATCHES. A repository nobody has ever dispatched work in is unbound until the first such launch, and a pipeline run started by hand in a repository this fleet has never launched into reaches commit creation without passing here.
  The binding is durable in repository configuration once made, so later runs in a bound repository reuse it.
- The worker's own environment is checked by the brief's projection call, in the worker's process, and not by the launch gate.
  A launch-time check reads the launching process's environment, which is not the one the worker will commit in, and crediting it with that reach would be the wrong-subject failure this fleet has a vocabulary for.
- The pipeline daemon's environment is read, never set.
  A daemon started with an identity variable is refused rather than corrected, because this fleet may not restart a daemon serving other lanes.
- The gate repository is discovered by parsing `no-mistakes status` output, measured against v1.40.3.
  A future release that stops printing a `gate:` line degrades to could-not-observe and refuses, rather than silently binding nothing.
- Custody covers lanes this fleet ADMITS. A rebinding performed outside that path - by hand, or by another home sharing the same repository - is not prevented, and a lane whose run is already in flight when that happens still commits under the changed identity.
- The upstream tool exposes no commit-identity configuration of its own (its whole `commit` config key carries only `fix_message`), which is why the binding is installed into the repository it commits in rather than declared to it.
  That gap is filed upstream as [kunchenguid/no-mistakes#924](https://github.com/kunchenguid/no-mistakes/issues/924); this record does not claim it is closed.
- The shared validation repository is contended rather than partitioned. The section above records how that contention is closed, what it costs, and the alternative that was rejected.
  The fleet does not own that repository's worktrees and does not claim to isolate this upstream channel.
