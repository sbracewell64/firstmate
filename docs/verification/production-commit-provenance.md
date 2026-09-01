# Production commit provenance verification

Audience: maintainer verification.

This record holds reusable evidence for one active guarantee of [`../../bin/fm-commit-identity.sh`](../../bin/fm-commit-identity.sh): that every production commit path this fleet can reach resolves the authoritative production author and committer, and that a path which cannot be shown to do so refuses before a commit object exists.
[`../../bin/fm-commit-identity-lib.sh`](../../bin/fm-commit-identity-lib.sh)'s header owns the channel precedence and the honest limits, that command's header owns the verb contract and exit statuses, and [`../configuration.md`](../configuration.md) "Publication identity policy" owns the schema the authoritative identity is declared in.

Verified on 2026-09-01 on Linux 6.18.33.2-microsoft-standard-WSL2 with git 2.51.0, jq 1.8.1, shellcheck 0.11.0, and no-mistakes v1.40.3.
The controls below were exercised at implementation head `f75259f0f8317c9c4fb26d623aa3dcb8ff293753` after the pipeline's review, documentation, and lint fixes were applied.

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

Twenty controls, each observing a real commit object's author and committer or the absence of one, because a verdict about configuration would be a verdict about the wrong subject.

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

The remaining ruling-required reds are individually held by the suite: a poisoned `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment refuses by name and creates zero commits; poisoned repository-local and global configuration both lose to the binding; fixture activity establishing a `Test` identity in the same session does not cross the boundary; a restart between commits leaves the bound provenance as the sole selector; an unstated, placeholder, malformed, ungoverned or undeclared identity refuses with its own token and creates nothing; and a pipeline daemon carrying an identity variable refuses.

## What this does NOT establish

The honest scope is narrower than "the fleet cannot publish a contaminated commit", and the difference matters.

- A `git commit` typed by hand, a provider web UI, and a pipeline run started without passing this command are not reached by the binding.
  The gate repository binding survives in that repository's configuration, so a later run reuses it, but a gate repository this fleet has never bound is unbound.
- The pipeline daemon's environment is read, never set.
  A daemon started with an identity variable is refused rather than corrected, because this fleet may not restart a daemon serving other lanes.
- The gate repository is discovered by parsing `no-mistakes status` output, measured against v1.40.3.
  A future release that stops printing a `gate:` line degrades to could-not-observe and refuses, rather than silently binding nothing.
- The upstream tool exposes no commit-identity configuration of its own (its whole `commit` config key carries only `fix_message`), which is why the binding is installed into the repository it commits in rather than declared to it.
  That gap is filed upstream as [kunchenguid/no-mistakes#924](https://github.com/kunchenguid/no-mistakes/issues/924); this record does not claim it is closed.
