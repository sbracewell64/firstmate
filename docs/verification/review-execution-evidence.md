# Review execution evidence

Maintainer-verification record for [`bin/fm-review-exec.sh`](../../bin/fm-review-exec.sh), the substrate that launches and captures a reviewer and owns that review's execution evidence.
The guarantee it records is narrow and exact: no proxy can establish that a review executed, and every control enforcing that has been observed failing before it was trusted passing.

The script's own header owns the law, the seventeen bound dimensions, and the mechanics.
This file records only what was measured, and when.

## Why watched red is the acceptance condition here

The substrate this replaces accepted a proxy in its own implementation.
It ran an entire suite, grepped the output for a textual `ok - <case>` line, and printed `FM_RECURRENCE_ASSERTION_EXECUTED` on the strength of that line, so a suite that printed the label without running the assertion satisfied it.
Its review half then established "a review happened" by reading a status event the reviewer itself had emitted, laundered through a status file, which is a claim citing itself.

A control that has only ever been seen green is indistinguishable from that defect.
So every control in [`tests/fm-review-exec.test.sh`](../../tests/fm-review-exec.test.sh) was run against a single-defect build of the substrate and observed failing for its intended reason, then run against the real build and observed passing.
The defect builds are scratch copies; no tracked source was mutated to produce them.

## Environment

Measured 2026-08-16 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, `jq` 1.8.1, and GNU bash 5.3.9, with the branch based on `72f948dc`.

## Commands

The green pass, which must show every control passing:

```
bash tests/fm-review-exec.test.sh
```

One red pass per defect build, where `<variant>` is a copy of `bin/fm-review-exec.sh` carrying exactly one defect:

```
FM_REVIEW_EXEC_BIN=<variant> bash tests/fm-review-exec.test.sh
```

`FM_REVIEW_EXEC_BIN` is read only by the test file and defaults to the tracked script, so the seam exists for this measurement and changes nothing in production.

## Observed red and green, per control

Seventeen controls pass against the shipped script, and eighteen single-defect builds of those same shipped bytes each reddened one of them.
Every defect build was regenerated from the final bytes after the last change to the script, so no row here was observed against a version that is not the one landing.

Each row is one control, the defect that reddened it, and the exact first failing line that defect produced.
Every defect is a real edit to a real code path: the smallest is one line, and each build was confirmed to differ from the tracked script and to parse before it was run.
That confirmation matters because a probe that reads a field which does not exist fails unconditionally, corroborating whatever it was pointed at while measuring nothing.

| Control | Defect injected | Observed red |
| --- | --- | --- |
| every dimension recorded, clean exit passes | a dimension stops being recorded | `not ok - a reviewer that ran and exited cleanly is an observed-good execution: expected exit 0, got 2` |
| every dimension recorded, clean exit passes | the required-dimension contract silently shrinks | `not ok - dimension reviewer_effort must be recorded as observed` |
| a success literal in the reviewer's stream | the classifier reads the label out of the captured artifact | `not ok - a non-zero exit is an observed-bad execution regardless of what was printed: expected exit 1, got 0` |
| an unrelated failure carrying that string | the same label-reading classifier | `not ok - an unrelated failure is still an observed-bad execution: expected exit 1, got 0` |
| a task terminal line | a `verb=done key=review-execution` status line is read as execution | `not ok - a task terminal line must not establish execution (got PASS)` |
| a live reviewer | a materialized checkout is read as liveness proof | `not ok - a live reviewer has not executed; liveness must not reach PASS (got PASS)` |
| a reviewer acknowledgement | an acknowledgement artifact is read as execution | `not ok - a reviewer acknowledgement must not establish execution (got PASS)` |
| a wrapper marker | the recorded executable is the caller's named binding | `not ok - the record must name the executable that actually ran (got test-reviewer-binding)` |
| a forged record | the record is trusted about its checkout, with no re-proof on read | `not ok - a record with no materialized reviewer behind it must not pass (got PASS)` |
| a primary checkout as source | the primary-checkout refusal is dropped | `not ok - a primary checkout as source is could-not-observe: expected exit 2, got 0` |
| checkout isolated from the source | `--no-local` is lost, and with it the object-storage guard | `not ok - the reviewer checkout must not share object storage with the source` |
| a checkout moved off the candidate | the same missing re-proof on read | `not ok - a checkout moved off the pinned candidate must not still pass (got PASS)` |
| a record is written once | the occupied-directory refusal is dropped | `not ok - the refusal must name the immutability rule (missing: 'a record is written once')` |
| one unobserved dimension | the unobserved-dimension scan is dropped | `not ok - an unobserved dimension is could-not-observe: expected exit 2, got 0` |
| the artifact digest binding | the digest comparison is dropped | `not ok - a record must not outlive the bytes it attests to (got PASS)` |
| an unresolvable candidate | the candidate silently falls back to `HEAD` | `not ok - a candidate that does not resolve is could-not-observe: expected exit 2, got 0` |
| an unresolvable reviewer executable | the unresolved executable is launched anyway | `not ok - a reviewer that does not resolve is could-not-observe: expected exit 2, got 1` |
| the argv is recorded exactly | the argv is encoded by joining on newlines | `not ok - launch_argv must record an argument containing a newline` |
| the argv is recorded exactly | the argv is encoded with jq's `--args` | `not ok - a reviewer that ran and exited cleanly is an observed-good execution: expected exit 0, got 2` |

Two controls are shadowed in a full-suite run because an earlier control reddens first and the suite stops there.
Both were additionally run in isolation against their defect build and against the tracked script, and the rows above are those isolated observations.

The controls for a deliberate exit 143, a genuine SIGTERM, dirty and attached reviewer checkouts, divergent checkout and candidate identities, shared object storage on reread, and checkout-relative executable resolution are could-not-observe watched-red gaps because no corresponding defect build has yet been measured.

## The `--no-local` measurement

Losing `--no-local` is invisible to every other isolation check: a hardlinked clone still detaches onto the candidate, still owns its repository administration, and still has no `objects/info/alternates`.
So the property is measured directly rather than the flag being trusted.
On this environment, a default local clone of a four-commit repository shared all twelve object inodes with its source, and a `--no-local` clone shared none; the same separation shows as a link count above one under the clone's object store.
The launch refuses on that link count, and the control asserts it.

## The argv encoding measurement

Recording the argv exactly is harder than it looks, and both obvious encodings were measured failing here rather than reasoned about.
Joining the arguments on newlines and splitting them back cannot represent an argument that contains a newline, and its emptiness filter drops an empty argument.
Passing them through jq's `--args` fails outright on jq 1.8.1 for any argument beginning with a dash, which jq still parses as one of its own options: `jq: Unknown option --role-arg`.
The shipped encoding base64s each argument before it reaches jq, and the control exercises all three shapes - a leading dash, an embedded newline, and an empty string - in one launch.

## Registry conformance

[`bin/fm-verify.sh`](../../bin/fm-verify.sh) declares a `review-exec` verifier that transports this substrate's result rather than forming its own.
Adding it to the registry without a control failed `tests/fm-verify.test.sh` at its conformance obligation, observed as `not ok - every declared verifier needs an unobservable-case control here; registry is 'browser merge-clean pr-checks review-exec', covered is 'browser merge-clean pr-checks'`.
That red is the registry's own guard working, and the control added for it asserts all three values plus the case where an observed-good execution's evidence stops being reachable.

## What this record does not establish

The authenticity boundary of an execution record is the filesystem it sits on.
Re-proving the isolation law on every read means the cheapest forgery - a plausible record with no reviewer behind it - reaches could-not-observe, because a forger must also materialize an isolated checkout standing at the exact candidate tree.
It does not make the record unforgeable by someone who can write to that directory, and nothing here claims otherwise.

This substrate answers only whether a named reviewer actually ran against a named tree and where its bytes are.
It does not read, parse, judge, or classify the review's content, so no measurement here says anything about whether a review was correct, thorough, or independent.

There is no deadline option, deliberately.
Wrapping the launch in `timeout(1)` would make exit 124 mean either that the deadline killed the reviewer or that the reviewer exited 124 on its own, and one status covering both a kill and a verdict is the type error this substrate exists to refuse.
A reviewer that never terminates is already covered, because with no terminal state observed the result is could-not-observe.

The recurrence and mutation proof owner is deliberately absent.
The exactly-one-occurrence mutation-target guard belongs to it and is not recreated here, because landing a mutation runner with no consumer would be preserved code rather than a working slice.
