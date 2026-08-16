# Outbound transport invariant verification

Audience: maintainer verification.

This record holds reusable evidence for one active guarantee of `bin/fm-outbound-artifact.sh`: that every control enforcing the outbound transport invariant can actually fail, and fails for its own reason.
`bin/fm-outbound-artifact-lib.sh`'s header owns the invariant statement and the identity rule, `bin/fm-outbound-artifact.sh`'s header owns the command contract, [`../configuration.md`](../configuration.md) "Browser Sol control venue" owns the configuration, and `.agents/skills/bootstrap-diagnostics/SKILL.md` owns the handling procedure for a printed `OUTBOUND:` line.

Verified on 2026-08-16 on Linux 6.18.33.2-microsoft-standard-WSL2 with jq 1.8.1 and shellcheck 0.11.0.

## Why this record exists

The invariant's whole subject is a condition that produces no symptom.
An item waiting for a review nobody requested behaves exactly like an item waiting for a review someone is conducting: both are quiet, and both stay quiet forever.
A test suite over that subject is therefore worth precisely as much as its ability to fail, and a green suite proves nothing on its own.

This fleet has already shipped a probe that read a field which did not exist, failed unconditionally, and corroborated a ruling while measuring nothing.
So each control below was driven RED by a targeted mutation of the implementation, and the observed failure is recorded next to it.

## The suite

```sh
$ bash tests/fm-outbound-artifact.test.sh | tail -1
all fm-outbound-artifact tests passed
$ bash tests/fm-bootstrap.test.sh | tail -1
ok - bootstrap bounds the outbound sweep and reports timeout as unevaluable
```

The 23 outbound-artifact cases and the bootstrap integration case pass.
What follows is why that sentence is worth anything.

## Watched-red evidence, one mutation per control

Each mutation is a single semantically valid edit to the shipped implementation; each was syntax-checked with `bash -n` before the suite ran, so no row here is a control firing on a broken file.
The suite was restored to the unmutated implementation after every row.

| Mutation | Control that caught it | Observed failure |
| --- | --- | --- |
| `sweep_exit` never returns 3 | 1, no request goes red | `control 1: expected defect exit 3, got 0: outbound artifacts: 0 satisfied, 1 defect, 0 unevaluable` |
| identity canonical form drops `head` | 2, exact-head applicability | `control 2: a moved head did not go red, got 0: outbound artifacts: 1 satisfied, 0 defect, 0 unevaluable` |
| forge dedupe check disabled before posting | 3, one cycle cannot duplicate | `control 3: a repeat emit did not report the existing request: requested: fm-ob-89bfb60c859c on o/control#2` |
| retry budget forced to 1 attempt | 4, transient failure retries | `control 4: emit gave up on a transient failure: transport failed after 1 attempts` |
| ruling write drops the correlation field | 5, a ruling wakes its item | `control 5: the ruling was not correlated onto the request` |
| unknown request id accepted instead of refused | 6, unrelated ruling cannot wake | `control 6: an unknown request id was accepted, exit 0: ruled: fm-ob-deadbeefcafe wakes waiting-item` |
| closure accepts an `emitted` request | 7, disposition completes the chain | `control 7: closure skipped the ruling step, exit 0: closed: fm-ob-89bfb60c859c - approved` |
| binding-completeness check bypassed | 8, fail closed on a vague request | `control 8: a headless emit was not refused, exit 0: requested: fm-ob-84c763056cc6 on o/control#2` |
| unconfigured venue rendered as `satisfied` | 9, could-not-observe is not a pass | `control 9: an unobservable forge did not reach 4, got 0: outbound artifacts: 1 satisfied, 0 defect, 0 unevaluable` |

The mutation for control 6 is the reason this table is not decoration.
On its first run it produced **no failure at all**: the control was vacuous.
The refusal in `require_record` ran inside a command substitution, where `exit` kills only the subshell, so the caller continued with an empty record and was refused later by an unrelated state check.
It still refused, which is why the mistake survives reading, but it refused with the wrong verdict: an unreadable record - could-not-observe, exit 4 - would have been reported as an identity mismatch, a verdict, exit 3.
That is the three-value collapse the whole mechanism exists to prevent, reproduced inside the mechanism.
`require_record` now answers through a global and the mutation fires, as the table records.

## Non-vacuity against the live fleet

A recognizer that matches nothing is the failure mode this invariant is most exposed to, because a clean report and a blind one are the same output.
Run read-only against the primary home, with records directed to a scratch directory so nothing in that home is written:

```sh
$ FM_HOME=<primary-home> FM_OUTBOUND_DIR=<scratch> FM_OUTBOUND_MAX_PROBES=4 \
    bin/fm-outbound-artifact.sh check | head -1
outbound artifacts: 0 satisfied, 9 defect, 4 unevaluable
```

The nine defects include every item this increment was commissioned from, and each is recognised from durable state with no annotation written for the invariant's benefit:

- `fleet-attention-advisory-signal`, `engraphis-consolidation-dry-run-default`, and `engraphis-structured-graph-api-upstream` type as `CONTRIBUTION_SUBMISSION_REQUIRED` on the `pull-request` channel - finished branches with no pull request on any remote.
- `engraphis-reserved-defects-recovery` types the same way and was **not** among the items reported when this work was commissioned, so the sweep found one the manual pass missed.
- The four SSSF hardening rows type as `INDEPENDENT_BROWSER_REVIEW_REQUIRED` on the `sol-control` channel and report `FM_OUTBOUND_TRANSPORT_UNCONFIGURED`, because the primary home has no `config/sol-control.json` yet.

That last group is the honest reading and not a gap in the check: with no configured venue the sweep cannot see whether a request exists, so it reports could-not-observe rather than either verdict.

## Three defects this found in itself, against live data

All three were invisible to the fixture suite and appeared only when the command was pointed at a real backlog and a real forge.
Each now has its own regression control in the suite.

**Tab is IFS whitespace.**
The sweep read the classifier's three tab-separated fields with `IFS=$'\t' read`, which collapses runs of tabs, so an untyped gate - the empty middle field, and the exact case the binding check refuses on - silently shifted the tier into the gate slot.
It rendered live rows as `gate: prose`.
The sweep now uses `cut -f`.

**A hold reason stops at its first comma.**
The backlog parser captures `hold:` with `[^,)]*`.
On the live row `RECLASSIFIED ...: VALID UNFINISHED WORK, never submitted`, the parsed `hold_reason` ends at `WORK`, and the two words naming the defect are cut off.
Reading `hold_reason` alone made the recognizer blind to all three never-submitted items it had just been widened to catch.
The truncation is the backlog parser's own contract and was not changed; the recognizer now reads the untruncated `raw` row as well.

**A forge error body is not a head.**
`gh api` prints its error payload to stdout and exits non-zero, so an unvalidated read captured a 404 body and carried it forward as the exact head, surfacing in a session-start line as `head {"message":"Not Found",...}`.
The invariant still held - the binding check refused it, because a JSON blob is not a sha - so the item stayed red, but for a misreported reason.
The head cascade now validates the shape at the point of observation, and an error payload is no observation at all rather than a bad one.

## Refreshing this record

```sh
$ bash tests/fm-outbound-artifact.test.sh
$ bin/fm-lint.sh
$ FM_HOME=<home> FM_OUTBOUND_DIR=<scratch> bin/fm-outbound-artifact.sh check
```

The mutation rows are refreshed by re-applying each single edit in the table, confirming `bash -n` still passes, running the suite, and recording which case failed.
A mutation that produces no failure is a vacuous control and must be repaired before the row is restored, exactly as control 6 was.
