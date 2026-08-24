# Decision-enumeration verification

Audience: maintainer verification.

This record holds reusable evidence for one active guarantee: listing which captain decisions are open is a cheap read of durable records, bounded independently of whether any decision's pinned criterion has been verified.
`bin/fm-classify-lib.sh`'s "ENUMERATION IS NOT VERIFICATION" section owns the rule, `bin/fm-commitment-register.sh` owns the probe interpreter and its cache, and `commitments/schema.json`'s `probe_bounds` owns both bounds and their derivations.

Verified on 2026-08-18 on Linux 6.18.33.2-microsoft-standard-WSL2 with bash 5, jq 1.8.1, and ShellCheck 0.11.0.

## The cost the split removes, measured both ways

The open-decision fold asked the probe interpreter for a fresh verdict per resolved key, and each key spent up to the 60s decision-probe bound.
Measured against a fixture home carrying five resolved keys whose pinned `run:` outlives that bound:

```sh
$ time bash -c '. bin/fm-classify-lib.sh; scan_open_decisions "$FM_HOME/state"'
301s, 5 entries
```

Five keys at 60.2s each: the cost is linear in the number of registered probes, and every caller with a shorter bound gets nothing rather than a listing.
With enumeration separated from verification, the same fixture, the same five keys:

```sh
$ time bash -c '. bin/fm-classify-lib.sh; scan_open_decisions "$FM_HOME/state"'
0.31s, 5 entries
```

The listing is the same size; only the cost moved.

## The callers that returned nothing now return an answer

Against this repository's own operational home, carrying seven live lanes and 53 open decisions:

```sh
$ time bin/fm-fleet-snapshot.sh --json > snapshot.json
19.4s, exit 0, 942022 bytes
$ jq -r '.schema' snapshot.json
fm-fleet-snapshot.v1
$ jq '.tasks | length' snapshot.json
7
$ time bin/fm-admission.sh
20.0s, exit 4, band: hard -> refuse
```

Before the split both commands hit their callers' bounds: the snapshot exited 124 having written zero bytes, and admission timed out evaluating a census from it.
The `hard` band above is `authority.single_primary: observed=not-held`, which is the correct answer for a process that does not hold the session lock and is unrelated to enumeration cost.

The enumeration itself over the same home:

```sh
$ bash -c '. bin/fm-classify-lib.sh; scan_open_decisions "$FM_HOME/state"' | wc -l
53      # 1.68s
$ ... | awk -F'\t' 'NF>=5{print $4}' | sort | uniq -c
     13 CAPTAIN_REQUIRED_AND_BLOCKING
     40 CAPTAIN_REQUIRED_NONBLOCKING
$ ... | awk -F'\t' 'NF<5' | wc -l
0
```

Every entry carries exactly one disposition, and none is missing the field.

## The cache can warm, which at the previous bound it could not

A freshness bound shorter than the pass that fills the cache expires every entry that pass writes before the pass ends, so no entry is ever servable.
The 301s pass above wrote five entries; 602s later, the same stored entry was read under both bounds at the same instant:

```sh
$ FM_COMMITMENT_PROBE_CACHE_TTL=3600 ...   # the shipped bound
TIMEOUT: the probe for k1 ... [observed 2026-08-18T01:52:16Z, 602s ago, within the 3600s freshness bound]
$ FM_COMMITMENT_PROBE_CACHE_TTL=120 ...    # the previous bound
NOT PROBED YET: the probe for k1 has no stored observation inside the 120s freshness bound ...
```

## Freshness is not a reopen

Verified on 2026-08-24 on the same platform, bash 5, jq 1.8.1, ShellCheck 0.11.0.

Separating a decision's semantic lifecycle from the freshness of the observation that resolved it is a second active guarantee over the same fold, ruled by Browser Sol `SOL-FM-SUPERVISOR-HANDOFF-GEN4-FP1-DISPOSITION-20260824`.
`bin/fm-classify-lib.sh`'s "FRESHNESS IS NOT A REOPEN" section owns the rule and `decision_entry_is_ruling_owed` is the one predicate consumers ask.

The measured defect, against a fixture home whose durable stream is `blocked` then `resolved` for one key with a registered probe, warmed by one verifying fold and then read twice with nothing about the subject changed - same stream, same decision bytes, same worktree, same head:

```sh
# pre-repair owners, restored from the commit before this change
$ status_open_decisions "$H/state/t1.status"                     # inside the freshness bound
                                                                 # (no output: closed)
$ FM_COMMITMENT_PROBE_CACHE_TTL=1 status_open_decisions ...      # 2s later, past the bound
crit  blocked  CAPTAIN_REQUIRED_AND_BLOCKING  NOT PROBED YET: the probe for crit has no stored
observation inside the 1s freshness bound and this caller is enumerating rather than verifying, ...
```

The same two reads under the repaired owners:

```sh
$ status_open_decisions "$H/state/t1.status"                     # inside the freshness bound
                                                                 # (no output: closed)
$ FM_COMMITMENT_PROBE_CACHE_TTL=1 status_open_decisions ...      # 2s later, past the bound
crit  verification-stale  CNO_DECISION_VERIFICATION  NOT PROBED YET: the probe for crit was not run
because this caller is enumerating rather than verifying, and its last observation is
VERIFICATION-STALE - PASS recorded at 2026-08-24T22:54:54Z, 2s ago, past the 1s freshness bound,
so it is not served as a current one; the criterion is could-not-observe and stays unverified
until a verifying caller spends the probe
```

The entry stays in the census and still says the criterion is unverified, so nothing reads the expired PASS as current; what changed is the type of what is reported.
The three could-not-observe causes the register now distinguishes - expired, never stored, and stored about a different subject - are separate because a reader deciding whether a resolution is unverified or was never verified cannot tell them apart from "no fresh result".

## Watched-red calibration

Each named property was driven red by one defect build before the passing run was trusted, including the non-vacuity control on the accepting path.
Executed-case counts are recorded rather than an absence of failures, because a suite reporting zero failures over zero executed cases reports nothing.

| Defect build | Property it breaks | Suite | Result |
| --- | --- | --- | --- |
| presentation bound returned to 4000 bytes | the whole universe is listed | `fm-wake-drain-open-decisions` | red: `listed 17 of 80 open decisions` |
| incompleteness returned to a trailing "N more omitted (byte cap)" line | exceeding a bound is reported as `CNO_DECISION_UNIVERSE` | `fm-wake-drain-open-decisions` | red: `the incompleteness must lead the section, not trail it` |
| a derived disposition leaves the vocabulary | the vocabulary is closed | `fm-classify`, `fm-wake-drain-open-decisions` | red in both |
| an unestablished disposition becomes an empty field | `CNO_DECISION_SUBJECT` is a value, not a gap | `fm-classify` | red: `got` (empty) |
| the recorded-disposition read is skipped | every member is reachable | `fm-classify` | red: `recorded disposition ... came back as CNO_DECISION_SUBJECT` |
| an unreadable decision record falls through to derivation | an unreadable record is could-not-observe | `fm-classify` | red: `got CAPTAIN_REQUIRED_NONBLOCKING` |
| the fold's `--cache-only` default removed | enumeration executes no probe | `fm-commitment-register` | red: `enumeration executed 3 registered probes` |
| cache bound returned to 120s | the cache can warm | `fm-commitment-register` | red: `serves a stored observation for 120s ... documents 3600s` |
| a granted probe budget no longer executes | ACCEPTING path non-vacuity | `fm-commitment-register` | red: `a passing criterion must still close the decision` |
| the pre-repair fold (HEAD before this change) | an expired observation is not a reopen | `fm-commitment-register` | red: `an expired observation reopened the decision as 'blocked'; freshness is not a reopen` |
| the pre-repair register | a miss names its cause | `fm-commitment-register` | red: `the refusal must say the observation was about another subject, not that none was stored` |
| the pre-repair fold | the stale projection is reachable at all | `fm-commitment-register` | red: `with no observation available the entry must be verification-stale` |
| the opening verb read back out of the live record | a reopened decision keeps the verb it was opened with | `fm-commitment-register` | red: `a reopened decision must carry the verb it was opened with, got 'needs-decision'` |
| the pre-repair consumer guard | an unverifiable resolution owes no captain hold | `fm-decision-hold-lifecycle` | red: `an unverifiable resolution demanded a captain hold nobody owes` |
| a derived-only disposition accepted as a recorded one | only the fold may derive it | `fm-classify`, `fm-decision-hold-lifecycle` | red in both |

Passing run, same suites, positive executed counts:

```sh
$ bin/fm-test-run.sh tests/fm-commitment-register.test.sh tests/fm-classify.test.sh tests/fm-wake-drain-open-decisions.test.sh tests/fm-decision-hold-lifecycle.test.sh
39 + 8 + 10 + 10 = 67 executed cases, 0 failed
```

Refresh this record by re-running those four suites plus `bin/fm-fleet-snapshot.sh --json` and `bin/fm-admission.sh` against a home carrying open decisions.
