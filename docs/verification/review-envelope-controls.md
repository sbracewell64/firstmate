# Review envelope controls

Maintainer-verification record for [`bin/fm-review-envelope.sh`](../../bin/fm-review-envelope.sh) and [`bin/fm-review-envelope-lib.sh`](../../bin/fm-review-envelope-lib.sh), the `review-envelope/v1` contract, its compiler and its classifier.
It records watched-red evidence for the original fifty controls and current green coverage for all fifty-three controls.

The library header owns the contract itself, and [`docs/contracts/review-envelope.md`](../contracts/review-envelope.md) is generated from its field catalog.
This file records only what was measured, and when.

## Why watched red is the acceptance condition here

The envelope exists because four separate defects in one day were caught only by a human noticing: a green computed against a base far behind the trunk, recorded evidence citing a head that had since moved, a validation transcript whose own `git rev-parse HEAD` showed a pre-rebase commit while claiming to prove the successor, and a generic CI run cited as evidence for an acceptance dimension its gate never invoked.
A control against those defects that has only ever been seen green is indistinguishable from no control at all.

Two measurement failures from the same campaign are the reason each red below is checked for its INTENDED reason rather than merely for being red.
One probe read a field that did not exist, so it failed unconditionally and corroborated whatever it was pointed at while measuring nothing.
Another exited zero because its request was rejected for an unrelated reason before ever reaching the property under test.

The second failure recurred here and was caught by this campaign.
The evidence-locator control originally pointed its escaping locator at a path that did not exist in the fixture's checked-out tree, so it refused because the file was missing and would have kept passing with the traversal guard removed.
It is now pointed at a file that exists outside the evidence root, whose digest matches, so the only thing standing between that locator and a review-ready envelope is the guard the control is named after.

## Environment

Measured 2026-08-16 on Linux 6.18.33.2-microsoft-standard-WSL2, against `git` 2.53.0, Python 3.14.4 and GNU bash 5.3.9, with the branch based on `d5002ed6`.

## Commands

The green pass, which must show every control passing:

```
bash tests/fm-review-envelope.test.sh
```

One red pass per defect build, where `<variant>` is a copy of BOTH `bin/fm-review-envelope.sh` and `bin/fm-review-envelope-lib.sh` into one directory, with exactly one edit:

```
FM_REVIEW_ENVELOPE_BIN=<variant>/bin/fm-review-envelope.sh bash tests/fm-review-envelope.test.sh
```

Both files are copied because the entrypoint sources its library from its own directory, so a variant carrying only one of them would test the tracked build.
`FM_REVIEW_ENVELOPE_BIN` is read only by the test file and defaults to the tracked script, so the seam exists for this measurement and changes nothing in production.

## Observed red and green, per control

Fifty-three controls pass against the shipped scripts.
Fifty-five single-defect builds produced the fifty-five measured control failures below for all fifty-three controls.
The dropped-obligation control was measured twice: once with its refusal removed, and once with the predecessor's obligation set read as empty, which is the shape the original incident took.
The request-identity control was also measured twice: once with its outer integrity binding removed, and once with validation-time identity recomputation disabled.

## Measured watched-red controls

Each row is one control, the defect that reddened it, and the exact first failing line that defect produced.
Every defect is a real edit to a real code path, and each build was confirmed to differ from the tracked script and to run before the suite was pointed at it.
That confirmation matters because a variant that never parsed would report a red line that measures the variant rather than the control.

| Control | Defect injected | Observed red |
| --- | --- | --- |
| a complete candidate is review-ready | the envelope binds the base commit where the head belongs | `not ok - a complete candidate is review-ready: expected exit 0, got 1` |
| required contracts are computed from the changed files | a mandatory applicability rule stops being honoured | `not ok - a mandatory contract and a contract whose paths changed are both required` |
| identical facts produce an identical digest | the compile time is moved inside the digested body | `not ok - nothing time-varying may sit inside the digested body` |
| a stale envelope refuses | the candidate reference is no longer compared with the bound head | `not ok - a stale envelope refuses: expected exit 1, got 0` |
| a base that falls behind the trunk refuses | the base-to-trunk distance is no longer compared with policy | `not ok - the refusal must name the policy bound it exceeded (missing: 'refusal base_behind_main_exceeds_policy')` |
| an asserted head the repository contradicts refuses | the head asserted by the inputs is believed instead of checked | `not ok - a head asserted in prose that the repository contradicts refuses: expected exit 1, got 0` |
| a tampered envelope body refuses | the stored body is no longer re-digested on read | `not ok - an edited envelope body refuses: expected exit 1, got 0` |
| an envelope is written once | an occupied output directory is reused instead of refused | `not ok - overwriting an envelope is could-not-observe: expected exit 2, got 0` |
| a missing required contract refuses | a required contract with no reference is skipped | `not ok - a required contract with no reference refuses: expected exit 1, got 0` |
| a missing required verifier result refuses | a required world with no result is skipped | `not ok - a required contract with no result refuses: expected exit 1, got 0` |
| a verifier result bound to another head refuses | a verifier result's head is no longer compared with the candidate | `not ok - a result bound to another head refuses: expected exit 1, got 0` |
| a missing red calibration refuses | a missing red calibration returns instead of refusing | `not ok - a passing verifier never observed failing refuses: expected exit 1, got 0` |
| a red calibration that records a pass refuses | the calibration's recorded outcome is no longer checked | `not ok - a calibration that never went red refuses: expected exit 1, got 0` |
| a could-not-observe verifier cannot become review-ready | a non-PASS verifier result falls through to the passing path | `not ok - a could-not-observe verifier is not a pass: expected exit 2, got 0` |
| a broken evidence digest refuses | the evidence check returns before it checks anything | `not ok - evidence that no longer matches its digest refuses: expected exit 1, got 0` |
| an evidence locator that escapes its root refuses | the parent-traversal guard on evidence locators is removed | `not ok - a locator escaping its evidence root refuses: expected exit 1, got 0` |
| an evidence symlink that escapes its root refuses before reading | symlink resolution is replaced by lexical path normalization | `not ok - a symlink outside the evidence root refuses: expected exit 1, got 0` |
| a result that does not identify its verifier refuses | a result carrying no verifier identity is accepted | `not ok - a result that does not identify what produced it refuses: expected exit 1, got 0` |
| wrong head ci refuses | every attempt is treated as if it ran at the candidate head | `not ok - a required platform covered only by another head's run refuses: expected exit 1, got 0` |
| a skipped required check refuses | a skipped current check stops refusing | `not ok - a skipped required check refuses: expected exit 1, got 0` |
| an absent required platform refuses | an uncovered required platform stops refusing | `not ok - a required platform with no check at all refuses: expected exit 1, got 0` |
| a pending required check is could-not-observe | a still-running required check stops being could-not-observe | `not ok - a check still running has reached no verdict: expected exit 2, got 0` |
| duplicate attempts with no ordering refuse | unorderable repeated attempts are resolved anyway | `not ok - the refusal must name the check whose current attempt is undecidable (missing: 'refusal ci_duplicate_attempt_undecidable')` |
| two workflows sharing a check name stay two checks | checks are keyed by name alone, dropping the owning workflow | `not ok - one workflow's pass must not mask another workflow's failure: expected exit 1, got 0` |
| a superseded failure is replaced by its later rerun | every attempt is treated as current, not just the latest | `not ok - a superseded failure must not block its own successful rerun: expected exit 0, got 1` |
| alias fallback resolves a later declared candidate | only the first declared executable candidate is evaluated | `not ok - a capability whose first alias is absent and whose second is present is observed, not could-not-observe: expected exit 0, got 2` |
| an exhausted candidate set is could-not-observe | an unresolved required capability stops being could-not-observe | `not ok - an exhausted candidate set is could-not-observe: expected exit 2, got 0` |
| a candidate that will not state its identity is not a selection | a candidate that will not state its identity is selected anyway | `not ok - the unusable candidate must be recorded as identity_failed, not as absent` |
| a silently dropped obligation refuses | an unaccounted predecessor obligation is skipped | `not ok - an obligation that simply disappears refuses: expected exit 1, got 0` |
| a silently dropped obligation refuses | the predecessor's active obligations are read as an empty set | `not ok - the refusal must name the unaccounted obligation (missing: 'refusal obligation_dropped')` |
| every prior obligation may be accounted for explicitly | a discharged obligation is treated as still active | `not ok - explicit accounting for every prior obligation advances: expected exit 0, got 1` |
| a satisfied obligation without evidence refuses | satisfaction stops requiring named evidence | `not ok - satisfaction asserted without evidence refuses: expected exit 1, got 0` |
| a preserved obligation missing from the active set refuses | preservation stops requiring presence in the active set | `not ok - an obligation called preserved but absent refuses: expected exit 1, got 0` |
| a superseded obligation without a replacement refuses | supersession stops requiring an active replacement | `not ok - supersession pointing at nothing refuses: expected exit 1, got 0` |
| a resolution without an authority refuses | resolution stops requiring an authority and a reason | `not ok - a resolution with no authority refuses: expected exit 1, got 0` |
| a successor that declares no predecessor is could-not-observe | an absent predecessor block is assumed to mean a fresh chain | `not ok - an undeclared predecessor is could-not-observe: expected exit 2, got 0` |
| a disposition for an obligation the predecessor never held refuses | a disposition for an unheld obligation is accepted | `not ok - a disposition for an obligation nobody held refuses: expected exit 1, got 0` |
| duplicate obligation dispositions refuse independently of array order | the duplicate-disposition refusal is disabled | `not ok - the duplicate refusal must not depend on disposition order (missing: 'refusal obligation_disposition_duplicate')` |
| request identity claims and stored identities are checked against recomputation | the declared request identity is removed from the outer integrity digest | `not ok - deleting a declared claim breaks outer integrity: expected exit 1, got 2` |
| request identity claims and stored identities are checked against recomputation | validation-time comparisons with the recomputed request identity are disabled | `not ok - validation preserves the compile-time request identity refusal: expected exit 1, got 0` |
| a predecessor that is not the declared one is could-not-observe | the supplied predecessor's digest is no longer compared | `not ok - a predecessor that is not the declared one is could-not-observe: expected exit 2, got 1` |
| a ruling that does not apply cannot authorize a resolution | a ruling's head applicability is no longer compared | `not ok - a ruling issued against another head cannot authorize anything here: expected exit 1, got 0` |
| a blocking adverse finding refuses | a blocking adverse finding stops refusing | `not ok - a blocking adverse finding refuses: expected exit 1, got 0` |
| a required unproven dimension is could-not-observe | a required unproven dimension stops being could-not-observe | `not ok - a required unproven dimension is could-not-observe: expected exit 2, got 0` |
| a fully excluded scope refuses | a scope that excludes everything stops refusing | `not ok - excluding everything refuses: expected exit 1, got 0` |
| excluded scope is bound explicitly | the rule that excluded a path is no longer recorded | `not ok - the envelope must name which rule excluded each path` |
| a contribution that changes nothing refuses | an empty changed-file set stops refusing | `not ok - the refusal must say the contribution changes nothing (missing: 'refusal changed_file_set_empty')` |
| a base the candidate does not descend from refuses | a base outside the candidate's ancestry stops refusing | `not ok - the refusal must name the base the candidate does not descend from (missing: 'refusal base_not_ancestor_of_candidate')` |
| a declared repository identity this is not refuses | the declared repository identity is no longer checked | `not ok - compiling against the wrong repository refuses: expected exit 1, got 0` |
| a check that names no head cannot cover a required platform | an attempt naming no head is treated as if it named one | `not ok - the refusal must say the platform has no exact-head check (missing: 'refusal ci_required_platform_uncovered')` |
| validate refuses to guess about evidence | validation guesses the evidence decision instead of refusing | `not ok - validation with no evidence decision is could-not-observe: expected exit 2, got 1` |
| declining the evidence recheck cannot reach review ready | a declined evidence recheck no longer blocks review-ready | `not ok - a declined evidence recheck cannot pass: expected exit 2, got 0` |
| validate rechecks evidence bytes | the evidence recheck arm never runs | `not ok - evidence replaced after compilation refuses at validation: expected exit 1, got 0` |
| the generated contract page matches the catalog | the generated contract page's section heading changes | `not ok - docs/contracts/review-envelope.md is stale; regenerate it with bin/fm-review-envelope.sh docs` |
| a crashed compiler cannot reach a verdict | an unreadable compiler result is read as a pass | `not ok - a compiler that produced no result is could-not-observe: expected exit 2, got 0` |
