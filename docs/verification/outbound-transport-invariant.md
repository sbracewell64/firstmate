# Outbound transport invariant verification

Audience: maintainer verification.

This record holds reusable evidence for one active guarantee of `bin/fm-outbound-artifact.sh`: that every control enforcing the outbound transport invariant can actually fail, and fails for its own reason.
`bin/fm-outbound-artifact-lib.sh`'s header owns the invariant statement and the identity rule, `bin/fm-outbound-artifact.sh`'s header owns the command contract, [`../configuration.md`](../configuration.md) "Browser Sol control venue" owns the configuration, and `.agents/skills/bootstrap-diagnostics/SKILL.md` owns the handling procedure for a printed `OUTBOUND:` line.

Verified on 2026-08-17 on Linux 6.18.33.2-microsoft-standard-WSL2 with jq 1.8.1 and shellcheck 0.11.0.
The watched-red controls below were exercised at implementation head `e083b9d011a2b081166662c9722bea1cb1215d99`.
The full focused green suites were re-run at exact implementation head `b77ec4d674fe77212a05c07de42c12868ef98bcd` after the no-mistakes document and lint fixes.
The outbound-artifact suite was re-run at exact implementation head `fc430723b7dd6320109a96d611bab76bedcde605` after duplicate local and remote refs were deduplicated before consuming the probe budget.

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
$ bash tests/fm-dead-predicate-check.test.sh | tail -1
all fm-dead-predicate-check tests passed
$ bash tests/fm-bootstrap.test.sh | tail -1
ok - bootstrap preserves definitive outbound defect classification
```

The 71 outbound-artifact cases, 34 dead-predicate cases, and the bootstrap integration cases pass.
What follows is why that sentence is worth anything.

The focused suites were re-run on 2026-08-17 at exact implementation head `3c21e711075a75daa930d186811144d675c6ca09` with `bash tests/fm-outbound-artifact.test.sh && bash tests/fm-dead-predicate-check.test.sh && bash tests/fm-bootstrap.test.sh`; the command exited 0.
The same focused suites were re-run on 2026-08-18 at exact implementation head `24a78c1b0cd8bda51210d12daaaff074dff42aca`; the command exited 0 after the final empty could-not-observe section control was added.
The same focused suites were re-run on 2026-08-18 at exact implementation head `06e11d6e929f0dd0e02574cc7098d4cae006ff8f` plus the review round below; the command exited 0 after the reconcile status, emit-lock, sweep identity, and unparsable-lifecycle controls were added.

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

## Branch inventory non-vacuity

A recognizer that matches nothing is the failure mode this invariant is most exposed to, because a clean report and a blind one are the same output.
The anchor control creates completed ship work on an `fm/<item>` branch with no pull request, then proves the sweep reports `recognised: inventory` and exits 3.
Before branch enumeration, that same fixture reported zero defects at exit 0, so the control establishes that the finding comes from enumerating refs rather than from an annotation.
Candidate scoping is three-valued: only a durable completed `kind: ship` record can make the missing pull request a defect, a durable non-ship record is skipped because its deliverable is not a pull request, and missing, incomplete, unreadable, unfinished, or conflicting lifecycle evidence is could-not-observe.
Could-not-observe is the primary signal for this control because released tasks are the population most likely to have lost their live records; it has its own count and headed section, and every section prints even when empty so an empty result cannot look like an omitted observation.
Retention does not bound the observation because completed entries rotate into the append-only, unpruned archive.
Record completeness and home locality do: records are per-home, so this home cannot establish the lifecycle of a branch produced by a secondmate from that secondmate's record, and an archive that exists but cannot be read makes the candidate could-not-observe even if the backlog alone appears sufficient.
The measured three-project population was 42 branches, of which 34 joined to a durable record and 8 did not.
Its negative controls prove that work already contained in the landing target, including squash-landed content, is excluded rather than reported forever.
They also prove in-progress and non-ship work are not defects, while the observation-gap controls make an absent project registry, unreadable project posture or completion archive, conflicting lifecycle, failed ref or object-width read, unresolved landing target, and failed candidate-ref enumeration exit 4 with the affected item or project named.

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

## Historical reconciliation for this module

The ruling requires classifying still-operationally-relevant records as `MATCH`, `MISMATCH`, or `COULD_NOT_OBSERVE`, without presuming corruption occurred.

The population is **empty**: no correlation record exists anywhere in the fleet, because the mechanism ships here and has never emitted. That is a statement about the population and not a clean bill of health - there were no records to classify, so no `MATCH` was observed either, and nothing is repaired because nothing exists to repair.

The bounded audit of other keyed-retrieval seams, and reconciliation of records this module does not own, are filed as their own increment `keyed-retrieval-identity-audit` and are deliberately not done here.

## Identity-bound retrieval, and the three-valued verdict

Captain ruling 2026-08-16: filesystem location is a locator, not proof of semantic identity. Anything retrieved by identity X must prove from its own validated content that it is X before it participates in a join, a wait satisfaction, a routing decision, or a ruling application.

Retrieval now recomputes the identity from the record's own fields rather than comparing the stored string, so a record whose id was rewritten to match its filename is still caught by its content. The consumer that owns `WAITING_FOR_RULING -> RULING_AVAILABLE` fetches the ruling comment and requires its body to carry every identity field exactly, so a comment id - which only says where to look - cannot satisfy a wait on its own.

A ruling body must first establish its sender with exactly one `from:` line whose whole trimmed value is the closed-enum inbound role `browser-sol`.
Missing, duplicate, unknown, self-claimed, or prefix-only sender values refuse before verdict parsing and wake nothing.
A ruling body must then contain exactly one `verdict:` line.
Zero verdict lines or more than one are ambiguous and refuse while naming the observed count; neither first-match nor last-match position is treated as identity or intent.

The verdict is three-valued, and the two refusals are not interchangeable:

| Verdict | Meaning | Response |
| --- | --- | --- |
| `VALID_MATCH` | the content proves it is the requested object | consume |
| `IDENTITY_MISMATCH` | the content names something else | refuse, exit 3 |
| `COULD_NOT_OBSERVE` | identity missing, unreadable, malformed, unsupported schema | refuse, exit 4 |

A two-valued check here is not unsafe so much as **unreportable**, which is how the collapse survives review: both values refuse, so nothing breaks in testing. The cost appears later. Told only "could not read it", an operator looks for a corrupt file or a permissions problem and finds neither, while the real condition is a perfectly readable record belonging to another request - a correlation defect with a completely different repair. A transient-looking verdict also invites a retry, and retrying a wrong-record-under-the-right-key just fails again.

An assertion in this suite previously required a mismatched record to report as unreadable. It passed because the two verdicts were collapsed. That expectation was corrected rather than preserved.

## Head identity: width comes from the repository

An exact head is an object id, and an object id's width is a property of the **target repository**, not a constant. Accepting either 40 or 64 universally is not a stricter rule but a different hole: this fleet writes 64-character sha256 content digests routinely - manifest digests, patch digests, check-trust hashes - so a universal 64 lets a content digest be read as an exact head in a sha1 repository. That is the same substitution as an abbreviation, arriving from the other side.

Width is therefore read from `git rev-parse --show-object-format`, shape is only the cheap pre-filter, and resolvability against the repository is preferred where it can be observed. An undeterminable object format refuses as could-not-observe rather than falling back to a guessed default.

Verified 2026-08-16: all five clones this fleet holds report `sha1`.

## Control coverage

Each row states what the control actually establishes and what it does not. A known limitation stays visible until a separate control closes it.

| Control | Property actually tested | Negative mutation that triggers red | Known non-coverage |
| --- | --- | --- | --- |
| `no-request-is-red` | An item at a gate with no artifact on the forge is a defect | `sweep_exit` never returns 3 - observed red | Does not prove the artifact would have been *usable*, only that none exists |
| `exact-head-applicability` | A moved head makes the previous request inapplicable | Identity canonical form drops `head` - observed red | Generation here IS the head; proves nothing about a scheme with a separate version counter |
| `duplicate-suppression` | Six cycles at one identity post exactly one request | Forge dedupe check disabled - observed red | Sequential cycles, not simultaneous ones; the per-id lock is a separate mechanism not proven here |
| `retry-without-loss` | Two transient failures retry through to one request, and exhaustion keeps the checkpoint | Retry budget forced to 1 - observed red | Does not cover a forge that accepts a post and then loses it silently |
| `ruling-wakes-its-item` | A ruling correlates onto the request that asked | Ruling write drops the correlation field - observed red | - |
| `unrelated-ruling-refused` | An unknown id, a foreign issue, or a body missing any identity field cannot wake the item | Unknown id accepted - observed red | - |
| `disposition-completes-chain` | Closure requires ruling and resumption first | Closure accepts an `emitted` request - observed red | - |
| `identity-mismatch-distinct` | A readable record naming another request refuses as a mismatch, NOT as unreadable | Collapse the two verdicts into one return - this is the defect that shipped | Does not cover a record whose non-identity fields are wrong |
| `head-object-id-width` | A 64-character value is refused for a sha1 repository; an abbreviation is refused; an unresolvable well-shaped id is refused; undeterminable format refuses | Accept any 7-40 hex, or a bare 40-or-64 - observed red | **No sha256 repository was available.** Acceptance of a 64-character head in a sha256 repository is UNPROVEN |
| `unambiguous-ruling-verdict` | Exactly one verdict line is required, and ambiguity refuses while naming its count | Add a quoted prior verdict beside the decided verdict | Does not decide which verdict was intended when a ruling contains more than one |
| `inbound-sender-boundary` | An inbound ruling needs exactly one whole-value `from: browser-sol`, checked before its verdict, and any other sender wakes nothing | Supply the live prefix-shaped malformed sender or claim the `firstmate` role | Does not authenticate the forge account that authored the comment |
| `dead-predicate` | A function in an enrolled file with no call site in its complete possible-caller universe is refused; blanket exemption does not silence; zero enrolled files is could-not-observe | Wire the offender in, or remove enrolment | Does NOT prove a called predicate implements everything its name implies - not mechanically decidable, caught by review. `DEAD` is issued only when every possible caller is parseable; an unparseable file that does not even loosely mention that predicate is outside its property-scoped universe, while a loose mention can only make the verdict could-not-observe and can never confirm a call |
| `reconcile-status-provenance` | `reconcile` reports the verdict of the stage that produced it: an emit that exhausts transport exits 4, and the following sweep's 3 never overwrites it | Read the status of a different pipeline stage - observed red, reported 3 for a could-not-observe emit | Does not cover more than one failing emit in one run; the first refusal ends the run |
| `emit-lock-release` | Every emit releases its own per-request lock during the run rather than at process exit, so a multi-item `reconcile` leaves none behind | Drop the explicit release and rely on the EXIT trap - observed red, one lock left behind | Does not cover a process killed between acquiring and releasing; that lock is reclaimed by the dead-pid steal, which is a separate mechanism |
| `sweep-identity-distinct` | The sweep reports a readable record naming another request as an identity refusal and a defect, never as an unreadable record | Collapse the mismatch return back onto the unreadable return - observed red, exit 4 and `RECORD_UNREADABLE` | Does not cover a record that is both foreign and unparseable; the unparseable answer wins, correctly |
| `unparsable-lifecycle-row` | A candidate row whose lifecycle state cannot be parsed is work-state-unobserved, not a lifecycle conflict | Drop the zero-state branch so zero collapses onto the disagreement branch - observed red | Does not widen what the parser accepts; an indented row is still unreadable, it is now reported as unreadable rather than as a disagreement |
| `branch-inventory` | A completed ship `fm/<item>` branch with unlanded work and no exact-head pull request is a defect; non-ship work is skipped; unknown or conflicting work state is could-not-observe; landed work is excluded | Remove branch enumeration - the anchor returns to zero defects at exit 0 | Covers registered non-local-only projects and the `fm/<item>` namespace only; historical completion evidence is not bound to the current branch head |

## One recurrence, four instances: a canonical thing that exists and is not consulted

Four separate review findings in this module were the same defect, and naming the shape matters more than the four fixes:

- `fm_outbound_applicability` - written correct, zero call sites, so no applicability test ran at all.
- `fm_outbound_record_state_valid` - defined once, consulted nowhere.
- `record_read` - a three-valued verdict collapsed back to a boolean at five call sites, so a readable record belonging to another request reported as merely unreadable.
- the typed `outbound-gate.json` declaration - authoritative in name, outranked by prose, so a stale sentence could route a detect-only item onto the emitting channel.

In each case the artifact existed, read correctly, and was not consulted - which is why reading the code proves nothing and only exercising it does.
The dead-predicate control catches the first two shapes and explicitly does not catch the second two; that boundary is stated in its own header rather than inferred.

## Two standing laws this surface now applies

Browser Sol generalised the containment findings on this task into two laws, and they are recorded here because the code applies them rather than merely citing them.

**Discovery is not identity.** A substring, prefix, text occurrence, API hit, path or name match discovers CANDIDATES only, and can never by itself satisfy an identity-bearing join, dedupe, applicability, wait, authorization or acceptance decision. A discovered candidate must be validated by the consumer against the complete exact identity that decision needs. Prefix relation is never equality. Three instances were found on this surface: a forge endpoint returning pull requests that merely CONTAIN a commit, quoted prose counting as a call site, and a substring of a comment body satisfying request presence. A class sweep for containment-style matching across the outbound surface found no fourth; the sweep's own near-miss is recorded below.

**Negative claims require complete observation.** Absent, no caller, dead predicate, nothing waiting - each qualifies only when the candidate universe is observable enough to exclude a satisfying member. `found=0` is not `clean=true` unless the verifier also establishes its completeness predicate, which is why the dead-predicate summary always prints `alive=` and `could_not_observe=` and why the sweep reports observation gaps beside findings.

The completeness predicate is PROPERTY-SCOPED, not global. The universe for one predicate is its possible callers, so an unreadable file that never references the name is irrelevant to that predicate's claim. A loose identifier pass decides that, and the asymmetry is what makes it sound: loose matching is legitimate for EXCLUDING a file from a universe, where a false positive costs only a could-not-observe, and is forbidden for CONFIRMING a call, where it would be the first law violated. Without property scoping, 215 unreadable files made every unresolved predicate could-not-observe and the control answered almost nothing.

### A note for the next class sweep on this surface

The sweep that found the third instance nearly missed the correct code beside it: filtering for unanchored `grep` on `-qx` skipped the `-Fqx` whole-line matches, which are the opposite of containment and are the validator the fix reuses. A class sweep has to cover flag-order and flag-combination variants rather than the canonical spelling, or it acquires a blind spot of the same kind it is hunting.

## The completeness claim is scoped, and what owns the rest

The dead-predicate control's per-predicate universe check closes the class for its own enumeration path: every read it performs is three-valued, and a failed read yields could-not-observe rather than a negative answer.

It does not close the class for the shared landing library its callers use.
`fm_landed_candidate_refs` returns success whenever any candidate ref resolved, so a push-target read that fails inside the library leaves that ref absent from a non-empty list, and an incomplete candidate set is indistinguishable from a complete one to any caller.
That gap is filed as `landed-lib-unreadable-push-target-collapses` and is deliberately out of scope here: the library is shared with the worktree guard, teardown, the decision surface and the task-base library, and changing its landing semantics from a task about outbound transport would be an unreviewed change to the guards that protect unlanded work.

Saying so is the point. A control described as class-level that silently depended on someone else's unfixed read would be exactly the coverage inflation the rest of this record refuses.

## One widening, and the measurement that earned it

After merging repaired main, eight predicates reported could-not-observe because a call written as `|| ! fm_outbound_is_sha ...` - a continuation line opening with `||` and a negation - was not in the accepted call-site syntax, so its whole file was refused and every predicate it consumes lost its caller universe.

Two fixes existed and only one is legitimate. Rewriting the call site would have made the file pass; widening accepted syntax to silence a refusal is shaping a control around its own answer. The choice was therefore decided by measurement: that form occurs 65 times across `bin/` and once in this module, which makes it a normal idiom of the codebase and its absence an under-specification rather than an oddity in the caller.

Verified in both directions, because adding an accepted call form is precisely the change that can re-open a falsification: the eight predicates resolve to alive, and a quoted `|| ! dead_one` is still reported DEAD, so prose still cannot confirm a call through the new rule.

## Refreshing this record

```sh
$ bash tests/fm-outbound-artifact.test.sh
$ bash tests/fm-dead-predicate-check.test.sh
$ bash tests/fm-bootstrap.test.sh
$ bin/fm-lint.sh
$ FM_HOME=<home> FM_OUTBOUND_DIR=<scratch> bin/fm-outbound-artifact.sh check
```

The mutation rows are refreshed by re-applying each single edit in the table, confirming `bash -n` still passes, running the suite, and recording which case failed.
A mutation that produces no failure is a vacuous control and must be repaired before the row is restored, exactly as control 6 was.
