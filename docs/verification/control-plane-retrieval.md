# Control-plane retrieval completeness verification

Audience: maintainer verification.

This record holds the audit and the reusable evidence for one active guarantee: no control-plane read in this tree reaches a negative conclusion over a source whose candidate universe was never enumerated.

[`../../bin/fm-retrieval-lib.sh`](../../bin/fm-retrieval-lib.sh) owns the retrieval type, the traversal, and the conclusion algebra; [`../../bin/fm-control-read.sh`](../../bin/fm-control-read.sh) is the callable contract over it; [`../../bin/fm-retrieval-check.sh`](../../bin/fm-retrieval-check.sh) owns the enforced classification and the audit census; [`../../tests/fm-retrieval-contract.test.sh`](../../tests/fm-retrieval-contract.test.sh) owns the controls.
Each header owns its own contract; this file records what was measured.

Verified on 2026-08-17 with gh 2.96.0, jq 1.8.1, and ShellCheck 0.11.0 on Linux 6.18.33.2-microsoft-standard-WSL2.
Re-run the commands below rather than trusting the recorded output.

## Strongest live proof

The same question against the real GitHub API returned assertable `ABSENT` after a complete 6-page traversal of 29 records and `INDETERMINATE` when bounded to one page.
This reproduces and reverses the original defect on demand against the real forge rather than a fixture.

## The defect

A control-plane read reported that the reviewing authority had not replied, repeatedly over several hours, while three rulings sat unread.
One of them was an approval a worker was already parked on.
The read asked a paginated endpoint for an issue's comments and received the first page, and the first page holds the OLDEST comments.

Pagination is the mechanism, not the defect.
The defect was making a NEGATIVE CLAIM over a source whose complete candidate universe had never been enumerated.
An earlier version of the same miss was diagnosed as "I only read the newest comment", and the fix adopted then - scan by timestamp - still read only the first page.
Two correct instructions, both applied to the wrong layer of one defect.

## Verified mechanism facts

Each fact below was observed rather than assumed, because each one decides how a guard has to be written.

### gh flattens the check rollup and caps it at the OLDEST 100

```sh
$ gh --version | head -1
gh version 2.96.0 (2026-07-02)
$ GH_DEBUG=api gh pr view 2522 --repo sbracewell64/firstmate --json statusCheckRollup 2>&1 \
    | grep -o 'contexts([a-z]*:[0-9]*)' | sort -u
contexts(first:100)
$ GH_DEBUG=api gh pr list --repo sbracewell64/firstmate --state open --limit 1 \
    --json number,statusCheckRollup 2>&1 \
    | grep -o 'contexts([a-z]*:[0-9]*)' | sort -u
contexts(first:100)
```

`first:100`, not `last:100`, and the listing form asks for the same thing as the single-request form.
A head carrying more than 100 check members returns the oldest 100 and silently drops the newest, which are exactly the members a re-triggered check produces.
That response also flattens away both `totalCount` and `pageInfo`, so it carries no evidence of its own truncation.
At exactly 100 members a complete set and a truncated one are indistinguishable in it, so [`../../bin/fm-verify-lib.sh`](../../bin/fm-verify-lib.sh) refuses both: that costs a re-read on a head with exactly 100 checks and prevents a false green on every head above it.

That flattened field is now the NARROWER of the rule's two sources and is read only by the batched pull-request listing in [`../../bin/fm-bearings-snapshot.sh`](../../bin/fm-bearings-snapshot.sh), which renders it and authorizes nothing.
Every path whose answer will be acted on - `bin/fm-verify.sh pr-checks`, and through it certification and slot reservation, plus [`../../bin/fm-pr-merge.sh`](../../bin/fm-pr-merge.sh) - reads `contexts(last:100)` with `totalCount` and refuses a returned count below the reported one.

### GitHub's continuation is an opaque cursor, so page numbers are not a traversal

```sh
$ gh api -i "repos/sbracewell64/firstmate/issues?per_page=2&page=1&state=all" | grep -i '^Link:'
Link: <https://api.github.com/repositories/1312908036/issues?per_page=2&page=2&state=all&after=Y3Vyc29yOnYyOpLPAAABoAzeCOjPAAAAATP3vzY%3D>; rel="next"
```

The `after=` cursor is the source's own position in the collection.
Incrementing `page=` independently is guessing at a sequence GitHub did not publish, and under insertion it skips or repeats records.
The traversal therefore follows `rel="next"` and nothing else, and a continuation it cannot parse is could-not-observe rather than the end of the set.

### tasks-axi discloses its own truncation

```sh
$ tasks-axi list --file <backlog> --limit 2
count: 2 of 5 total
```

[`../../bin/fm-session-start.sh`](../../bin/fm-session-start.sh) passes that output through verbatim, so the startup digest carries the bound.
Measuring this against the installed tool rather than assuming it is what moved that site from suspected defect to judged safe.

## The sweep, and how the universe was determined

The universe was defined by axis, not by the example that produced the incident.
A site is in scope when it reads a collection from outside the process where the returned extent is decided by the SOURCE - a page, a cap, a limit, a window, a scrollback bound - rather than by the caller, AND its result can reach a conclusion of the form "no X exists", "nothing pending", "nothing new", "not present", or "already handled".

The discovery pattern was written against that axis and deliberately over-broadened: every forge, relay, backlog, pipeline, and terminal read form in the tree, every explicit page or limit parameter, every completeness-proof token, and prose that merely mentions one.
It was never narrowed to make violations disappear.
Both patterns print, so the universe is reproducible rather than described:

```sh
bin/fm-retrieval-check.sh --pattern           # the enforced read forms
bin/fm-retrieval-check.sh --pattern --audit   # the broader census pattern
bin/fm-retrieval-check.sh --audit             # every candidate site, classified
bin/fm-retrieval-check.sh --check             # the enforced gate
```

Two axis applications separate the enforced pattern from the census, and neither is a result-driven tune.

A whole-line comment reads nothing, so it is not a read site.
That is the axis applied rather than the pattern narrowed, and it matters here because header prose in this tree discusses gh flags and page parameters at length: before the exclusion the census reported 129 sites against the same tree, 29 of them sentences.

The census additionally matches completeness-proof tokens - `total_count`, `totalCount`, `hasNextPage`, `pageInfo`, a GraphQL `first:` or `last:` - and bare forge command names, which the enforced pattern omits.
Those tokens are evidence that a site already proves its own extent, which is what an audit wants to find, and they are not themselves reads.
They also occur inside multi-line quoted query bodies, where the shell has no syntax for a comment, so enforcing them would demand an annotation in a position that cannot exist.
[`../../tests/fm-retrieval-contract.test.sh`](../../tests/fm-retrieval-contract.test.sh) asserts the census stays strictly broader than the enforced set, so narrowing it back fails a control.

The gate enumerates every tracked file and partitions the universe by each file's actual role into scannable executable content, explicitly inert prose, data, assets, and test fixtures, or `UNCHECKED` files whose capability it cannot classify.
An `UNCHECKED` file is named and makes the gate non-zero, so coverage incompleteness cannot produce a pass.
Coverage is computed from that partition on every run rather than printed as a literal.
The passing record reports scanned, out-of-scope, and total universe counts with the measured `coverage=complete` verdict.

Shell files and workflow YAML `run:` blocks use the shell read-form classifier.
JavaScript, TypeScript, Python, and batch files add native `fetch`, `XMLHttpRequest`, HTTP-client, API-library, and subprocess read forms.
Executable configuration uses both classifier families because hook and command fields can launch either form.
Any language without a classifier is `UNCHECKED` rather than scanned with a pattern that cannot see it.

Successive review rounds exposed the same pattern at deeper layers: the traversal validated identity but not every named schema field, the gate enforced classifications without proving its own file universe, replay reached a verdict without the validation used by fetch, and the replay proof was not bound to the records it certified.
The contract was correct about the thing it gated while incomplete about itself each time.
A completeness contract must satisfy its own law, and checking that law rather than a checklist is what exposed each path.
This round converged because the remaining classifier item is a measured coverage improvement rather than a defect that makes the retrieval verdict unsafe.

The replay proof now carries a SHA-256 digest of the exact JSONL record bytes.
Replay recomputes that digest before schema validation or selection, and a missing digest, unavailable digest tool, or byte mismatch is unobserved state that forces `INDETERMINATE`.
Publication computes and validates the digest over a private per-attempt staging directory before replacing the record set and proof in order, proof last.
Live retrieval retains this attempt's private assembled records and proof through validation, selection, conclusion, and evidence printing, while replay certifies a private copy of the published pair.
Concurrent or crashed publishers can therefore leave a mismatch that reads as unobserved, but no lock or abandoned coordination state can block the next reader or publisher.

### Value, not location

The complete post-retrieval path sweep found only `fm_retrieval_validate_records`, `fm_retrieval_select`, the CLI `RECORDS` variable, and the JSON and `evidence_ref` proof readers as phases that reopen a path after retrieval.
The live call site hands every one of those phases this fetch attempt's retained private value, and replay hands them its certified private snapshot.
Publication is already value-bound because it digests private staged bytes, and load is already value-bound because it certifies its private snapshot.
The remaining named follow-up is structural hardening: these functions still accept paths, so safety is enforced by current call sites rather than made impossible by their types.
That is a generator of future risk rather than an open defect in the current verdict.
Inside this repository only `bin/fm-verify-fork-landing.sh` calls the CLI and it does not pass `--records`.
Whether callers outside this repository pass `--records` is unobserved rather than zero.

One coverage emitter owns the computed verdict and named `UNCHECKED` list for census, violation, coverage-refusal, and passing exits.
An unclassified site can therefore no longer conceal that the file universe was also incomplete.

### Deliberately deferred native-classifier reach

The native pattern currently recognizes `fetch`, `XMLHttpRequest`, `axios`, `octokit`, `urllib`, `requests`, and `http.client`.
It does not recognize ordinary forms including Node `https.get`, `https.request`, and `http.get`, `undici`, Python `httpx` and `aiohttp`, `got`, or a forge CLI invoked through a subprocess whose command appears on another line.
The recognized set came from an example list in the ruling, and extending an example enumeration is the same class of error this contract exists to prevent.
The durable follow-up is to invert the test so a file is clean only when the gate can establish it has no outbound capability, while any outbound-capable file without a classified site is `UNCHECKED`.
This is a coverage limitation under a verdict that refuses to overclaim, rather than authority to declare an unseen language clean.
The follow-up must not be closed by widening the classifier alone, because the verdict is the guarantee and classifier breadth is only its reach.
Fixing classifier breadth without first making the coverage verdict visible on every path would have been the unsafe ordering.

### Deliberately deferred publication-gated live verdict

`fm_retrieval_fetch` returns `fm_retrieval_publish`'s status and the live call site selects only when that status is zero, so a failure to write the caller's `--records` destination discards a verdict the attempt had already certified over its own private records.
It is filed rather than fixed, and the reason it is safe to file is the part to re-verify before relying on it, so it is reproducible here rather than asserted.

The measured behavior, with a fixture-served single-page collection and a destination directory the process cannot write:

```sh
$ bin/fm-control-read.sh endpoint 'fixture?x=1' --identity req-7 --claim exists --records <writable>/x.jsonl
  endpoint:fixture?x=1,complete,enumerated,1,1,0,unknown,1,0,0,0,exists,ABSENT,-,<proof>
exit=1
$ chmod 555 <unwritable-dir>
$ bin/fm-control-read.sh endpoint 'fixture?x=1' --identity req-7 --claim exists --records <unwritable-dir>/x.jsonl
  endpoint:fixture?x=1,unobserved,state_uncommitted,1,1,0,unknown,0,0,0,0,exists,INDETERMINATE,-,-
exit=2
```

THE SAFE-DIRECTION ARGUMENT. The suppressed outcome is `INDETERMINATE` with reason `state_uncommitted`, never a wrong `ABSENT` or `PRESENT`.
Note that `pages=1` and `records=1` survive while `candidates=0`, which shows the traversal did read and certify its records and only the selection was skipped.
Every other defect corrected in this increment could return an answer that was wrong while carrying a `complete` verdict; this one can only withhold an answer that was right.
That is why it is filed and the others were not: shipping it risks availability, not soundness, and it leaves no false-absence path open.

The durable fix is to separate attempt certification from optional replay publication, so only a failure to certify the private value blocks a verdict and a failure to write the replay artifact is recorded without touching the retrieval reason.
Whoever picks it up should re-run the two commands above first: if the second one ever reports a `complete` verdict or a conclusion other than `INDETERMINATE`, the safe-direction argument has stopped holding and the item is no longer merely an availability limitation.

Exposure today is bounded and measured rather than assumed.
The default records path is a fresh `mktemp` and is therefore writable by construction, so a caller that does not pass `--records` is unaffected.
Inside this repository only `bin/fm-verify-fork-landing.sh` calls the CLI and it does not pass `--records`.
Whether callers outside this repository pass it remains unobserved rather than zero.

## Classification of every enforced site

Each site carries an `fm-retrieval-audit: <class> - <reason>` annotation in the applicable language's comment syntax, either trailing the site or immediately above it.
The check consumes an annotation for exactly one site, so a neighboring read cannot inherit it.
`bin/fm-retrieval-check.sh --list-classes` prints the vocabulary and that script's header defines each class.

| class | what it means here |
| ----- | ------------------ |
| `complete-source` | proves its own extent: short-page termination with a max-pages could-not-observe, `hasNextPage`, `total_count` reconciliation, an n+1 cap sentinel, or a source that discloses its own truncation |
| `not-a-collection` | one object, one queue pop, or one named artifact to a file |
| `not-a-read` | message text, a tool-presence probe, an install command printed for a human, or the check's own pattern text |
| `chokepoint` | a transport wrapper with no collection semantics of its own; its callers carry the classification |
| `window-is-the-subject` | the claim's universe IS the bounded window |
| `contract` | the contract's own request builder, whose traversal proves its own extent |
| `write` | an action, which has no observation type |
| `conservative-negative` | a false negative tightens the gate it feeds |
| `no-negative` | cannot reach a negative conclusion |
| `bound-disclosed` | bounded, and the bound travels with the result |

`bin/fm-retrieval-check.sh --check` prints that breakdown on its passing path, so the mix stays visible and re-running it is how to refresh these counts.
The check scans its own owners, and none of the `contract` sites is the migrated verifier: routing a read through the contract removes the direct-read site rather than reclassifying it, because the line no longer calls a forge command.

Five scripts had independently re-derived a correct completeness proof before this audit: [`../../bin/fm-attest.sh`](../../bin/fm-attest.sh) on `hasNextPage` and on `total_count` against the returned length, [`../../bin/fm-pr-merge.sh`](../../bin/fm-pr-merge.sh) on `totalCount` against returned members, [`../../bin/fm-attribution-sweep.sh`](../../bin/fm-attribution-sweep.sh) on short-page termination with an explicit max-pages could-not-observe, [`../../bin/fm-bearings-snapshot.sh`](../../bin/fm-bearings-snapshot.sh) on an n+1 cap sentinel reported as a minimum, and [`../../bin/fm-wake-ledger.sh`](../../bin/fm-wake-ledger.sh) escalating from a bounded tail to a full-file read on exactly the path where a false negative would be damaging.
That is strong evidence the discipline is understood and weak evidence it will be applied next time, which is the argument for one owner and a deterministic check rather than a sixth correct instruction.

## Defects found, and what was done

Two sites were load-bearing negatives over an unenumerated universe.

[`../../bin/fm-verify.sh`](../../bin/fm-verify.sh)'s `pr-checks` verifier classified gh's flattened rollup with no truncation detection, so "no member is non-SUCCESS" - a negative claim - was drawn over a set capped at the oldest 100.
It is fixed in the rule's owner, `bin/fm-verify-lib.sh`, which gained a `truncated` label placed below `failing` and `pending` and above `passing`: incompleteness kills negatives and not positives, so a failure actually observed in the returned part still refuses.
`bin/fm-verify.sh` maps that label to `NO_VERIFIER_RAN` with a new `retrieval_incomplete` reason, and `bin/fm-bearings-snapshot.sh`, the rule's other consumer, renders the label directly and needed no change.

That repair left the truncation closed and a second question open, which a later audit measured: `bin/fm-verify-lib.sh` and `bin/fm-pr-merge.sh` were TWO OWNERS of "is this exact head green?", and they were driven to opposite verdicts on one head carrying an older `FAILURE` and a newer `SUCCESS` for one check.
The library had no attempt reduction, so any attempt that ever failed made the head failing forever; the merge gate reduced attempts to the current one and read green.
The library was the stricter of the two, so it produced a false `FAIL` - a positive observed-bad claim that reaches `bin/fm-certify.sh` as a verification gap and `bin/fm-slot-reservation.sh` as grounds to withhold a pool slot.
There is now one fold in `bin/fm-verify-lib.sh` and two normalizers that feed it, each declaring what it cannot supply, and `pr-checks` reads the authoritative source.
`tests/fm-exact-head-green-one-owner.test.sh` keeps the divergence itself as an executed red control against the pre-consolidation rule.

[`../../bin/fm-verify-fork-landing.sh`](../../bin/fm-verify-fork-landing.sh) asked `gh-axi pr list --head` and took the first number the listing printed.
That is two mistakes in one line: the listing was never enumerated, so "no open pull request" was a negative over an unread universe, and the first row is the SOURCE's choice of which pull request the subject is rather than the verifier's.
It now reads through `bin/fm-control-read.sh` with `--identity-mode exact` on `head.ref`, and refuses an ambiguous head rather than resolving it, because two open pull requests carrying one head are two candidate subjects and picking either would be a sound reading of the wrong one.

### Residuals retained, named rather than resolved

[`../../bin/fm-crew-state.sh`](../../bin/fm-crew-state.sh)'s cross-branch fallback reads the newest 200 pipeline rows and returns empty both when the branch has no run inside that window and when the newest row cannot be bound to the worktree.
It is classified `window-is-the-subject` because the question is whether a run for this branch is active NOW and the listing is newest-first.
The residual is the 200-row assumption: a fleet that started 200 newer runs could push an active run out of the window, and repairing it means changing that function's return type, which is outside this change's fence.

[`../../bin/fm-teardown.sh`](../../bin/fm-teardown.sh)'s `pr_number_from_branch` asks with `--limit 1`, so which pull request a branch with several resolves to is the source's ordering rather than a choice.
It is classified `conservative-negative`: a miss returns non-zero and the landed-work test falls back to the stricter content check, and the positive path is independently bound by an ancestry check against the merged head, so neither outcome can authorize discarding unlanded work.

## Controls

[`../../tests/fm-retrieval-contract.test.sh`](../../tests/fm-retrieval-contract.test.sh), in the portable-serial lane and therefore a required CI shard.
Every negative case asserts the retrieval completeness value alongside the conclusion, so no case can call a result "no ruling" unless completeness is itself proven.

```sh
bash tests/fm-retrieval-contract.test.sh
```

The 2026-08-17 post-header-correction rerun completed with `FM_TEST_CONTRACT suite=fm-retrieval-contract.test.sh status=pass`.

Controls covering the commissioned list: an applicable ruling only on page 2 or later; multiple pages with the oldest record on page 1; the latest applicable ruling not on the first page; page 1 carrying a ruling a later page supersedes; pagination stopping early; one page that cannot be read; duplicate identifiers across pages; an irrelevant later comment after the applicable ruling; an identifier present only in quoted or reply prose; prefix collision, `X` versus `X` plus a suffix; complete retrieval with a genuinely absent ruling, the negative that must stay assertable; and complete retrieval with exactly one applicable ruling, the non-vacuity anchor.

Beyond that list: a unique-record bound enforced during page ingestion, an absent reader tool, a moved response schema, live and replayed records missing each configured selection-critical field, an unparsable continuation, a bounded retry that recovers a transient page, a rate-limited source, a refused credential, an unreadable subject, the completeness sidecar as the write commit point, digest refusal after record deletion, append, reorder, a missing digest, or digest-command failure, coherent concurrent publication without coordination, valid replay anchors for both `PRESENT` and `ABSENT`, consumer exhaustiveness, non-coercibility of `INDETERMINATE`, per-language gate coverage including native reads and its `UNCHECKED` class, annotation ownership and comment syntax, coverage emission beside violations, and the three rollup-cap behaviors.

### Negative controls: each guard watched failing

The whole suite was watched red before any implementation existed.
Each guard was then deliberately broken and the controls covering it were watched red individually, because absence of failures is not evidence that a control works.
The library was restored byte-identically afterwards, confirmed with `diff -q` against a pre-mutation copy.

| mutation | controls that went red |
| -------- | ---------------------- |
| traversal stops after page one and calls it enumerated | 11, including every page-2 case, both bounded-out cases, dedup, and the provenance case |
| `INDETERMINATE` folded into `ABSENT` | 5: early stop, unreadable page, schema movement, rate limit, uncommitted state |
| `latest` no longer requires complete retrieval | the extremal-claim case |
| identity matched as a plain substring | the quoted-prose and prefix-collision cases |
| dedup keyed on page position instead of remote identity | the duplicate-identifier case |
| rollup cap detection removed | the page-cap case, while the below-cap pass and below-cap failure stayed green |
| every `fm_retrieval_case` guard removed | both consumer-type cases |

Removing only the arity guard from `fm_retrieval_case` left both consumer controls green, because the handler-existence guard catches the same call independently.
That is redundancy in the implementation rather than a gap in the controls, and removing all three guards turns both red.

One control exists because the FIRST LIVE RUN failed, not because inspection found it.
A boundary pattern strict enough to reject `req-7.1` also rejected `APPROVE req-7.` at the end of a sentence, which is a false negative on the most ordinary way a human writes a ruling.
The rule is now extraction of identifier runs followed by equality, and the punctuation case is a control.

## Live end-to-end verification

Against the real GitHub API on 2026-08-17.
`--per-page 5` forces continuation on a thread that would otherwise fit in one page.

Complete enumeration of a real 29-comment thread across 6 pages, each continuation URL GitHub's own cursor, ending in an assertable absence:

```sh
$ bin/fm-control-read.sh issue-comments cli/cli 1268 \
    --identity fm-no-such-identifier --claim exists --per-page 5
...,complete,enumerated,6,29,0,unknown,29,0,0,0,exists,ABSENT,-,...
exit=1
```

The same question bounded to one page, which is the original defect's read shape, refuses instead of answering:

```sh
$ bin/fm-control-read.sh issue-comments cli/cli 1268 \
    --identity fm-no-such-identifier --claim exists --per-page 5 --max-pages 1
...,incomplete,page_bound_reached,1,5,0,unknown,5,0,0,0,exists,INDETERMINATE,-,...
exit=2
```

An identifier present only beyond page one: refused under the bound, found under the complete read, with the matching comment named.

```sh
$ bin/fm-control-read.sh issue-comments cli/cli 1268 \
    --identity Alternatively --claim latest --per-page 5 --max-pages 1
...,incomplete,page_bound_reached,1,5,...,latest,INDETERMINATE,-,...
exit=2
$ bin/fm-control-read.sh issue-comments cli/cli 1268 \
    --identity Alternatively --claim latest --per-page 5
...,complete,enumerated,6,29,0,unknown,29,1,0,0,latest,PRESENT,1520910395,...
exit=0
```

Suffix collision against real data: `accepted` occurs in that thread only inside `hacktoberfest-accepted`, so the complete read reports the absence and counts the rejection rather than matching a different identifier.

```sh
$ bin/fm-control-read.sh issue-comments cli/cli 1268 --identity accepted --claim exists --per-page 5
...,complete,enumerated,6,29,0,unknown,29,0,0,1,exists,ABSENT,-,...
exit=1
```

An unreadable subject is could-not-observe, never an empty thread:

```sh
$ bin/fm-control-read.sh issue-comments cli/cli 999999999 --identity x --claim exists
...,unobserved,subject_unreadable,0,0,0,unknown,0,0,0,0,exists,INDETERMINATE,-,...
exit=2
```

The migrated verifier, against the live fork, on both sides of its question:

```sh
$ bin/fm-verify-fork-landing.sh --event-key fm/no-such-branch-abcdef
fail: no open pull request on sbracewell64/firstmate with head fm/no-such-branch-abcdef (the whole open set was read: complete)
exit=1
$ bin/fm-verify-fork-landing.sh --event-key fm/review-recurrence-proof-owner
evidence: fork pull request 104 exists on sbracewell64/firstmate for head fm/review-recurrence-proof-owner (open set read completely: complete)
evidence: check summary for pull request 104: passed=8 failed=2 pending=3 total=13
exit=1
```

## What this does not establish

It does not change what any ruling means, alter hold semantics, or touch the control protocol; applicability is a pattern the caller supplies.

The enforced check scans tracked source files regardless of their location and refuses unknown file capabilities as `UNCHECKED` rather than silently excluding them.

`complete` means the source published no further continuation at the moment of the read.
A record created after the traversal passed its page is a later fact about the source rather than an error in this one, which is why the observation time is in the proof sidecar.

The classification annotations are maintainer judgment recorded at the site.
The check enforces that a judgment exists and names a class in the closed vocabulary with a reason; it cannot verify that the reason is true.

A returned verdict is trustworthy, but a returned `INDETERMINATE` does not by itself prove the source was unreadable.
The publication-gated live-verdict limitation can produce one from a sound observation when the process cannot write the `--records` destination.
Read the `reason` field rather than the conclusion alone before concluding anything about the source, because `state_uncommitted` is a publication fact rather than a source-read fact.
The separate native-classifier limitation produces a named `UNCHECKED` file and a non-zero gate result, not a retrieval conclusion.
