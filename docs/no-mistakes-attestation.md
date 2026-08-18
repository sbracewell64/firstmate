# The no-mistakes attestation

`.github/workflows/no-mistakes-required.yml` is the `Require no-mistakes` check on pull requests targeting `main`.
This document owns what that check establishes, what it deliberately does not, and the format it verifies.
`bin/fm-attest.sh` owns the exact commands and flags.

## What the check reads

The check verifies a git note on `refs/notes/no-mistakes`, keyed by the pull request's exact head commit.

A note is used rather than a commit trailer or a line of pull request prose for three reasons.
It is keyed by a commit sha, so it can name the commit it covers without changing that commit's sha.
It never rewrites the branch, so producing one cannot disturb the pipeline's custody of it.
It reaches the forge as an ordinary ref, so a `pull_request` workflow can read it with `contents: read` and nothing more.

Git notes do not travel with `refs/pull/*`, so the ref is read from the repository the branch was pushed to.
The workflow addresses that repository, and the base repository holding `refs/pull/*`, as two named remotes and performs no read itself; the verifier reads them, once before its verdict and again for as long as the window below is open.
One program doing all of that is what keeps the first read and the re-reads from coming to disagree about what an unreachable repository means.
What stays in the workflow is what a pull request's own copy of anything must not decide: which repositories are addressed, and how the job's token is put into a URL.
The base repository is addressed through an explicit token URL and a fork through its plain `https` URL, which still carries the job's token because `actions/checkout` persists it in the workspace's git configuration.
Neither read is anonymous; both are read-only and both go to the host that issued the token, and the token is written where `actions/checkout` has already written it.
A read that fails for any reason other than "the ref is not there" stops the job, so an unreachable head repository is never resolved as either an absent or a present attestation.
Every remote call is made with its output suppressed, because a URL embedding the job token is quoted back by git in its own http errors and a stream left attached writes that token into the job log.
Actions redacts that token from logs, which makes the suppression defence in depth rather than the only thing between the token and the log.
The verifier names the repository it could not read by resolving the remote's URL back out and passing it through the same scrubber every other line it prints goes through, because "the remote 'attestation-source' would not serve it" sends nobody anywhere.

The workflow reads the verifier's exit status rather than only its success, because `bin/fm-attest.sh` separates a refusal from a failure and collapsing the two would have the check report evidence it never examined as absent evidence.
Exit 1 is a verdict and is reported as no attestation for this head.
Any other non-zero exit reached no verdict, and is reported as the check being unable to evaluate this head, naming the status and the two families of causes that reach it: repository or ref state the verifier could not read, or a verifier unavailable because the head predates this check, `bin/fm-attest.sh` is missing, or it has lost its executable bit.
Both outcomes fail the check, because a check that could not look must never report a pass; what differs is what the contributor is sent to repair.

## The format

```
no-mistakes-attestation: v1
head: <the 40-character lowercase sha of the commit this attests>
run: <the pipeline run identity that validated it>
gates: <comma-separated pipeline steps that completed for that head>
tool: <the pipeline binary and version that ran them>
```

`bin/fm-attest.sh --print-format` prints this from the implementation, so the two cannot drift.

A `v1` note is accepted only when every field is present and well formed, `head` equals the commit the note is attached to, and `gates` records a completed `review`, `test`, `lint` and `push`.
An unrecognized field is refused rather than ignored, so a later format can never be read as a weaker `v1` one.

Each failure reports its own reason: `no-attestation-ref`, `attestation-ref-unreadable`, `no-attestation-for-head`, `head-commit-unavailable`, `attestation-malformed`, `attestation-not-bound`, or `attestation-missing-gate`.
Keeping them distinct is the point rather than a convenience.
An absent attestation and a rejected one need different repairs, and neither may be reported as a pass.
`attestation-ref-unreadable` is the ref resolving but not readable as notes, such as one pointing at a blob; it is kept apart from `no-attestation-for-head` because publishing another note can never repair a damaged ref.

## The error model

`bin/fm-attest.sh` exits three ways, and the difference between them is the contract rather than an implementation detail.

A **refusal** exits 1 and prints `not attested (<reason>)`.
The evidence was examined and found absent, unbound or invalid, so this is a verdict.
`verify` refuses with the seven reasons above.
`write` refuses with `no-run-record`, `run-record-unreadable`, `run-record-unparsed`, `run-record-no-head`, `run-covers-another-branch`, `run-head-unavailable`, `run-covers-another-head` or `run-incomplete`.

A **failure** exits 2 and prints `cannot attest (<reason>)`.
No verdict was reached, so it says nothing about the evidence either way: `not-a-git-repository`, `pipeline-tool-missing`, `head-unresolvable`, `head-detached`, `scratch-file-unavailable`, `push-target-unreadable`, `push-target-unfetchable`, `attestation-not-reconciled`, `attestation-not-recorded`, `attestation-not-published`, or `commit-unknown` for `show`.
`reconcile` adds `attestation-source-unreadable`, `attestation-source-unfetchable`, `pull-request-head-absent`, `pull-request-head-unreadable` and `clock-unreadable` to that list, and reaches no reason of its own beyond them: every verdict it reports is `verify`'s.

`--supports` is neither, and borrows neither error model.
It is a capability query answered as an exit status, zero for a capability this program has and non-zero for one it does not, and a copy old enough to predate the query answers non-zero by not recognizing it.

`recheck` is about a different subject and uses its own headline after its shared repository and scratch-file preflight, because a head can carry perfect evidence and still not be re-evaluated, and reporting that as `not attested` would send a reader to republish a note that is already correct.
The shared preflight failures remain `cannot attest (not-a-git-repository)` and `cannot attest (scratch-file-unavailable)`.
It prints `not re-evaluated (<reason>)` and exits 1 for a fact about this head, this pull request or this repository: `attestation-not-published`, `attestation-not-published-for-head`, `pull-request-not-open`, `pull-request-head-moved`, `pull-request-head-repository-mismatch`, `pull-request-ambiguous`, `no-applicable-run`, `run-in-progress` or `recheck-budget-spent`.
It prints `cannot re-evaluate (<reason>)` and exits 2 when the re-evaluation could not be carried out or judged, so nothing it says bears on whether the check would now pass: `forge-tool-missing`, `forge-unreadable`, `forge-read-truncated`, `pull-request-list-truncated`, `push-target-unreadable`, `push-target-unfetchable`, `attestation-ref-unreadable`, `pull-request-head-repository-absent`, `pull-request-head-repository-unreadable`, `rerun-not-requested`, `ledger-unreadable`, `ledger-unwritable`, `ledger-unlocatable`, `ledger-lock-unavailable` or `repository-unresolved`.
Published evidence that is present but invalid is **not** one of these: it exits through `verify`'s own refusals above, because that is a verdict on the evidence rather than a step that did not happen.
When `recheck` runs as `write`'s last step, every non-zero exit also says that the note was recorded and pushed before it ran, so the repair is never to publish it again.

A **usage error** exits 2 and names the argument in plain words, because there is no state to describe.

No condition borrows another's reason or another's words.
That rule is the one this component has had to relearn most often: an unreadable record reported as head divergence, or a missing utility reported as a tool exit, sends a reader to repair something that was never broken and to hit the identical message again.

## What it attests

That some pipeline run completed review, test, lint and push against **this exact commit**, and recorded which run and which tool version did it.

The binding is the property that matters.
An attestation cannot be copied from another pull request, cannot survive a rebase, an amend or a force-push, and cannot be produced before the commit it names exists.
Every new head needs its own.

## What it does not attest

**Who ran the pipeline.**
`no-mistakes` runs on the contributor's machine using the contributor's own credentials, so no artifact it emits can be unforgeable by the person running it: anything the pipeline can write, its operator can write.
Closing that gap needs an issuer the pull request author does not control, such as a check run posted by a GitHub App the base repository installs, and that is a change to the pipeline's architecture rather than to this check.
What this check removes is the far weaker property it replaced, where the evidence was a fixed string in the mutable pull request body that anyone could type once and paste anywhere.

**That the change is good.**
`.github/workflows/ci.yml` owns tests, lint and platform coverage on the same head.
This check is a provenance gate, not a quality one, and a passing attestation on a red pull request is still a red pull request.

**That the workflow itself was not edited.**
On `pull_request`, GitHub runs the workflow and scripts from the pull request's own head, so a pull request may change the gate that examines it.
That was equally true of the body-string check this replaces and is a property of the event, not of this design.
It is why the check's verdict is visible in the diff and why required-check configuration is a repository setting rather than something a workflow can assert about itself.

## Producing one

`bin/fm-attest.sh write` reads the pipeline's own run record through `no-mistakes axi status`, refuses unless that run covers this branch and completed every required step, then records and pushes the note on the head that run validated, and finally re-evaluates that head as described below.
It re-verifies its own payload with the same code path the gate uses, so a malformed note cannot reach the forge and be discovered only in CI.
`--no-recheck` publishes without asking GitHub anything, and is for the case where the note is wanted but the check is not the point.

The head it attests is not always `HEAD`.
The pipeline commits its own fixes and advances the run tip past the local checkout, so a run tip ahead of `HEAD` on the same history is the normal state, it is the head the pull request is opened on, and it is what gets attested.
A run tip behind or beside `HEAD` is refused as `run-covers-another-head`, because this branch then carries work that run never saw or its tip was rewritten.
A run tip that is not a commit in this checkout at all is refused separately as `run-head-unavailable`, because that is a fetch rather than a re-validation.
`bin/fm-nm-run-lib.sh` owns that directional rule for every caller that has to decide whether a run belongs to a worktree, and owns reading this tool's output; both are read from there rather than re-derived here, so a change to the tool's shape moves every reader at once.

Those refusals are reached by a head no pipeline run validated, which the check's own refusal names as a case of its own rather than leaving to be discovered by running `write` and being refused.
Sending that reader to publish and no further would send them to a command that must refuse, so the refusal says that this head has not been validated, that publishing is not the repair, and that the repair is to validate it through the pipeline and then attest the head that run pushed.
It says in the same breath not to add a commit merely to restart the check, because that advances the head past the last run's tip and reproduces the identical refusal on the new head; that is the loop this case exists to stop, and `CONTRIBUTING.md` step 8 states the same rule for the contributor following the workflow rather than reading a failed check.

It publishes to the remote's push URL rather than its fetch URL, and reconciles against that same repository before writing, because those are two different repositories in the setup `CONTRIBUTING.md` describes and only the push target is the one the check reads.
The reconciliation merges the published ref instead of forcing over the local one, so an attestation recorded locally with `--no-push` survives the publishing of a later one.
It names that repository in what it prints, because "published to origin" does not say which repository was reached and the note is evidence only on the one holding the pull request head.
A push target carrying no `refs/notes/no-mistakes` yet has nothing to reconcile against and is not an error, but a push target that cannot be read at all stops the command before anything is recorded: not reading a repository is not reading an absence, and that is the same line the gate draws when it fetches this ref.

git's own text is made safe to print rather than withheld wholesale when a remote call fails.
git quotes the push URL back in its messages and a credential in a log is a leak wherever that log ends up, but suppressing the text throws away the server's rejection reason with it, and a contributor blocked by a ruleset on `refs/notes/*`, a required-signature policy or a quota then has nothing to act on.
Making it safe is default deny, and that inversion is the safety property rather than a detail of it: a word that could carry a credential is emitted only when it positively matches a shape with no place for one, and a line holding anything withheld is withheld entire rather than shown in part.
Redacting what a reader recognises instead emits intact every shape it failed to model, which reads absence of detection as absence of a credential, and that is how credentials reached a log before the inversion.
This covers everything the command prints, git's output and the pipeline tool's two streams alike, so a refusal added later is safe because printing is what makes it safe.
`bin/fm-attest.sh`'s header comment is the single owner of the mechanism: the shapes that are modelled, why each guard is a rule rather than an implication of its pattern, the cost of withholding by line, and why one function is the only path text leaves the command by.

Its own refusals stay as distinct as the gate's.
`no-run-record` means the pipeline reported no run, `run-record-unreadable` means the tool itself failed, `run-record-unparsed` means it reported something no run identity could be read from, and `run-record-no-head` means it reported a run naming no usable head commit; all four quote the tool's own output, because a tool error read as an absent run sends a contributor to re-run a pipeline that already ran.
That output is quoted through the same scrubbing as git's, because `no-mistakes` manages pushes and its error output can therefore carry a remote URL with a credential in it.
Only what the tool writes to stdout decides which of them it is, because unrelated notices such as its version-upgrade banner go to stderr and must never stand in for a run record; stderr is quoted alongside stdout purely as diagnostic detail.
A tool that failed is recognised from that stdout rather than from its exit status, because it writes a refusal as a leading `error:` line and does not always exit non-zero for one: `repo not initialized`, the state of every checkout the pipeline was never set up in, exits zero with that line and nothing else.
Read from the exit status alone it is `run-record-unparsed`, which says this transcription needs updating and sends a reader to repair something that was never broken; `bin/fm-nm-run-lib.sh` owns reading that line, from the first non-empty line only, so a record carrying an `error` field about the run it describes stays a record.
Every call to the tool is time-bounded, so one blocked on a lock or a network read refuses as `run-record-unreadable` rather than hanging at a contributor's terminal.
`bin/fm-timeout-lib.sh` owns imposing that bound, and `bin/fm-nm-run-lib.sh` delegates to it rather than carrying a second copy of the mechanism.
`docs/configuration.md` owns the `FM_ATTEST_NM_TIMEOUT`, `FM_ATTEST_RECHECK_WAIT`, `FM_ATTEST_RECHECK_POLL`, `FM_ATTEST_RECHECK_LOCK_WAIT`, `FM_ATTEST_RECONCILE_WINDOW` and `FM_ATTEST_RECONCILE_POLL` knobs, including why a non-positive `FM_ATTEST_NM_TIMEOUT` falls back to the default rather than shortening the bound while zero is a real value for the wait and window bounds.

When `no-mistakes` publishes this note itself, the helper becomes redundant and nothing about the check changes: the note format is the contract, and which program writes it is not.

## The bounded window before a verdict

The note can only exist after the push it attests, and that push is what starts this check, so the check's first look at a genuinely pipeline-raised head can be a near miss rather than anything about the change.
`bin/fm-attest.sh reconcile` is what the workflow runs, and it re-reads the attestation ref for a short bounded window while - and only while - no attestation for this head has arrived, then reaches its verdict through `verify`.
`verify` is the only thing here that reaches one at all: `reconcile` can delay a verdict, it cannot produce one, and it cannot delay one already reached.

### How long, and on what basis

60 seconds, measured against this repository's own publication history rather than picked.
Across 45 published attestations, the delay from the pull request event that started a check to the note being published ran from 9 seconds to 1815, with a median of 200.
Those observations cluster rather than spread: 11 of the 45 land within 55 seconds and the next one is at 75, because a short delay is a publication that raced its own push while a long one is a pipeline still working.
60 seconds covers that cluster and stops before the tail begins.
[`docs/verification/attestation-publication-latency.md`](verification/attestation-publication-latency.md) holds that measurement and the commands that reproduce it, so the number can be re-derived rather than inherited.
The bound is on waiting, so the observations themselves add to what a job spends; `FM_ATTEST_RECONCILE_WINDOW` and `FM_ATTEST_RECONCILE_POLL` are the knobs and `docs/configuration.md` owns them.

It is deliberately not sized to the tail, and what that costs is worth stating rather than leaving to be discovered.
It absorbs the near miss and nothing more: on those 45 observations, 11 publish inside the window and the other 34 still report a first red and still converge through the re-evaluation below.
Sizing the window to the tail would be an unbounded wait wearing a bound - it would hold a runner for the length of somebody else's validation run, and for every second of it the head would still be unattested.
The layering is the design rather than a compromise in it: a short window absorbs the race, and re-evaluation recovers everything past it.

### What ends the window

Four things, and only one of them is the clock.

- An attestation for this head arrives, and the verdict is `verify`'s immediately.
- Evidence is there and is invalid, unbound, stale or unreadable, and the verdict is `verify`'s on the first look.
  A window that graced evidence already observed to be bad would be buying time for exactly what this check exists to refuse, so the window is for absence and for nothing else.
- The pull request proposes a different commit.
  `refs/pull/<n>/head` is re-read on every observation the window makes, because waiting is a bet that evidence for **this** head is about to arrive and a request that has moved on will never produce it.
  Head movement is not a verdict and does not become one: the verdict is still `verify`'s, about the head this run was raised for, reached early rather than differently.
- The bound is spent, and the refusal says how long it waited, because otherwise the one number that shaped the verdict is the one number nowhere in it.

A repository or a ref that could not be read at all ends it differently, as `cannot attest`: `attestation-source-unreadable`, `attestation-source-unfetchable`, `pull-request-head-absent`, `pull-request-head-unreadable`, or `clock-unreadable` when the wait could not be bounded.
Not reading a repository is not reading an absence, which is the same line this component draws everywhere else.
Both outcomes are red; what differs is that one sends a contributor to publish an attestation and the other sends them to re-run a job.

The verifier runs from the pull request's own head, so a head raised before `reconcile` existed does not carry it.
The workflow asks `bin/fm-attest.sh --supports reconcile` before choosing what to run, and verifies such a head without a window exactly as it did before rather than failing it for the age of its checkout.
`--supports` answers as an exit status and nothing else, so a caller never has to tell "this program does not do that" from "that failed" by reading a message.
That fallback can go once no open pull request predates the subcommand.

## Re-evaluating a head after the note is published

Most attestations are published past the window above, and one published past it repairs the evidence but not the verdict already reported.
`refs/notes/no-mistakes` is not a pull request head, so pushing it fires no `pull_request` event and nothing re-reads the head.
`bin/fm-attest.sh recheck` is what re-reads it, and `write` runs it on the head it just published, so a successful delivery converges on a green check with nobody closing, reopening or editing a pull request.

It re-runs the workflow run that already judged that exact head.
That is GitHub's own supported mechanism, and it keeps GitHub the only place a verdict comes from: the same event payload replays, so the job checks out the same `head.sha`, fetches the ref afresh, and re-derives its verdict from the evidence now present.
There is no second check, no second truth store, and nothing that could report a head as green without the workflow itself saying so.
Nothing about the pull request is mutated; automating a title or body edit would restore the manual step with a different actor rather than remove it.

What it establishes before asking GitHub for anything:

- The repository the check reads - the push target of the named remote, not the local ref - now serves an attestation for **this exact head**, and that attestation passes the same `verify_note_payload` the gate runs.
  A note that is absent there, bound to another commit, or malformed is refused as **evidence**, in the evidence's own words, and no re-run is requested: re-running a check that must refuse again would spend a job to be told what is already known.
- The pull request is open and its head is still this commit.
  Its head repository must also be the resolved push-target repository the attestation was read from, on both paths: the explicit lookup reads `head.repo.full_name` and the resolved one reads `headRepository.nameWithOwner`.
  Those are compared as identities rather than as text, because GitHub repository names are case-insensitive and the two sides are spelled by different authorities - the push side lowercased out of a remote URL, the forge side in GitHub's own canonical casing.
  Comparing them raw refused a match that was really a match, which fails closed and so never reports a head green on unseen evidence, but puts the manual re-trigger back for every contributor whose repository name carries a capital.
  Every message keeps the spelling its reader used; only the comparison is normalized.
  A mismatch refuses before the POST: it cannot produce a false green, but proceeding would report evidence as published where the check does not look and spend a re-run that cannot converge.
  An absent head repository, including a deleted fork, and an unreadable head repository are separate could-not-observe outcomes and are never assumed to match.
  Named explicitly, a request that has moved on is refused as `pull-request-head-moved`, because evidence for a head nobody is proposing does not cover the head under review.
  Resolved from this checkout's own github.com remotes instead, only a request open **on** this commit counts: GitHub associates a request with every commit that was ever in its history, so a request whose head has moved past this one still comes back and is not it.
  A commit a candidate repository does not carry is a fact about that repository and is passed over; a candidate that could not be read at all stops the command, because not reading a repository is not reading an absence.
  One head on two open requests is refused rather than chosen between, and naming the request with `--repo` and `--pr` is the way past both that and an unreadable candidate.
- The applicable run is a `no-mistakes-required.yml` run for this head, on this pull request.
  The run that started last is the one re-run, which is the same "latest attempt speaks for the check" ordering `bin/fm-verify-lib.sh`'s rollup reduction uses, so a re-run can never leave a newer failure still speaking.
- Nothing has already been done about it.
  One re-run per run attempt, and at most three per repository, pull request and head, counted from a durable record.

Every re-run request is appended to `fm-attest-recheck.log` in the repository's common git directory before it is made, binding repository, pull request, head, note object, run and attempt to the action taken and why.
The log also records later request outcomes and the ordinary skip states that are reached after its prerequisites have been established.
It is never committed and the check never reads it: it is an audit record of what this program did, not a second place a verdict could come from.
The count and pre-request append are serialized through a bounded atomic lock shared by every worktree of the clone.
The lock records its host and process, reclaims a holder only when that process is demonstrably gone on this host, and fails closed for live or unobservable holders.
The record is keyed on the repository rather than on how one invocation spelled it, because keying on the spelling let a spent per-head bound be reset by retyping the same name in another case.
The record is written **before** the request and consumes that run attempt, because after a crash the program cannot distinguish a request that never happened from one GitHub accepted before the requested record was appended.
The bound counts attempts rather than successes so that a forge swallowing every request cannot buy unlimited ones.

Three outcomes are ordinary rather than faults, and each says so: the run already passed, this attempt was already re-triggered, and no open pull request is on this head at all - the last being the landing-branch shape below.

### What still needs a hand, and only this

Re-running a workflow run needs write access to that repository's Actions.
The author of a pull request raised **from a fork against a parent repository** does not hold that on the parent, and `gh` may be absent or unauthenticated.
In those cases `recheck` reports `forge-tool-missing`, `forge-unreadable` or `rerun-not-requested`, says that nothing has re-read the head, and names the fallback: re-run that workflow run from the repository's Actions tab, or ask someone who holds the access to.
The attestation is already published and correct in that case and must not be published again.

That is the whole residual manual case.
Closing and reopening a pull request is no longer part of this procedure, and `edited` is no longer subscribed for it.
`edited` remains subscribed because it is the only event GitHub fires when a pull request's base branch changes, so without it a pull request retargeted onto `main` would never run this check at all.

## Landing an already-validated change on a fork

A fork's landing branch carries work that was validated upstream, but its commits are new, so an attestation for the upstream head does not cover them; the check refuses it, correctly.

Because the attestation is bound to a commit rather than written into a pull request body, that branch can be validated in its own right without proposing anything upstream.
Run the pipeline against the landing branch with the pull request and CI steps skipped, then attest the head it validated.
That is what separates the signature from upstream submission: previously the only way to obtain the marker was to open an upstream pull request, so a landing branch could not be signed without duplicating a live contribution.

A head proposed nowhere has no check to re-evaluate, and `write` reports exactly that and exits cleanly rather than treating it as a fault.

## Verification

`tests/fm-attest.test.sh` pins every refusal and its matched positive control through the executable interface, for `bin/fm-attest.sh` and for the workflow's own step scripts, which it lifts out of the workflow by step name and runs as the workflow runs them.
The two live in one suite because what the check tells a contributor is decided jointly by the verifier's exit status and the step's reading of it, and splitting them lets the two drift apart.
Each negative fixture differs from the passing one by exactly one property, because a verifier that refused everything would satisfy red-only assertions and would be a worse defect than the honour-system check it replaces.

The window's cases are about **when** a verdict is reached, because what the verdict is remains `verify`'s and is pinned separately.
They run against real local repositories standing in for the head repository, the base repository and the job's workspace, and they assert elapsed time, because a window that was honoured and a window that was skipped differ in nothing else.
One of them pins the correspondence the window rests on directly: every state `verify` reports as an absent attestation is waited through, and every other refusal is reached at once, so a reason added on one side and not the other fails there rather than quietly widening what gets graced.
Convergence is asserted against a note published while the window is open, and against the matched control of the same fixture with nothing publishing, because a convergence assertion on a fixture that was already green would prove nothing.

The re-evaluation cases assert on the **action taken against the forge**, read out of a log of every call, and never on a message this program prints about it.
Every negative case there additionally asserts that no re-run was requested, and the converging cases assert that nothing altered the pull request itself.
The stub applies the real `--jq` filters to real fixture JSON, so the selection rules - this head only, this pull request, the run that started last - are exercised rather than assumed.

The suite proves that the ledger lock is taken before the count and that a holder stops the request.
It does not directly prove that two invocations racing for the last budget slot cannot both take it; mutual exclusion between holders is inherited from the atomicity of POSIX `mkdir`.
It also does not establish GitHub's behavior when re-running a `pull_request` workflow against an unchanged head.
The stale-attempt rollup reduction is separately owned by `bin/fm-verify-lib.sh` and proved by `tests/fm-exact-head-green-one-owner.test.sh`.

The suite was re-measured on 2026-08-18 with `bash tests/fm-attest.test.sh`, which exited 0 and reported 92 passing cases.
That number is bound to the head it was measured at and to nothing else: it is prose, and no control reads it, so it goes stale silently whenever the suite grows. Re-measure it rather than reconciling it against a remembered figure.
