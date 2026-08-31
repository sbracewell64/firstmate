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

The 73 outbound-artifact cases, 34 dead-predicate cases, and the bootstrap integration cases pass.
What follows is why that sentence is worth anything.

The focused suites were re-run on 2026-08-17 at exact implementation head `3c21e711075a75daa930d186811144d675c6ca09` with `bash tests/fm-outbound-artifact.test.sh && bash tests/fm-dead-predicate-check.test.sh && bash tests/fm-bootstrap.test.sh`; the command exited 0.
The same focused suites were re-run on 2026-08-18 at exact implementation head `24a78c1b0cd8bda51210d12daaaff074dff42aca`; the command exited 0 after the final empty could-not-observe section control was added.
The same focused suites were re-run on 2026-08-18 at exact implementation head `06e11d6e929f0dd0e02574cc7098d4cae006ff8f` plus the review round below; the command exited 0 after the reconcile status, emit-lock, sweep identity, and unparsable-lifecycle controls were added.
The same focused suites were re-run on 2026-08-18 at exact implementation head `876a69c43cef4f9a47664231eeb701196d22dbf8` plus the review round below; the command exited 0 after the reconcile report-completeness and observed-artifact-naming controls were added.
The same focused suites were re-run on 2026-08-18 at exact implementation head `617f794d8c34f874bc4fb81e15871abc2a4a99bb` plus the review round below; the command exited 0 after the bootstrap-deadline relay and defect-heading controls were added.
The same focused suites were re-run on 2026-08-18 at exact implementation head `e32e4f7e87503ad56e8cc73e53cf21b77cf61e7b` plus the review round below; the command exited 0 after the two unemitted classification tokens were wired to the live sites that had been reporting under a neighbouring token.
The same focused suites were re-run on 2026-08-18 at exact implementation head `e54aa8108c726e5ec9a31e0fc9983fd6e5314fdf` plus the review round below; the command exited 0 after the token-vocabulary control was added to enforce the block's own emit-site rule.
Re-run on 2026-08-18 after the exit fold and the unreadable-head split below: `tests/fm-outbound-artifact.test.sh` executed 76 cases with 0 failures, and `tests/fm-bootstrap.test.sh`, `tests/fm-commitment-register.test.sh`, `tests/fm-session-start.test.sh`, `tests/fm-landing-authorization.test.sh`, `tests/fm-dead-predicate-check.test.sh` and `tests/fm-teardown.test.sh` executed 39, 32, 32, 17, 34 and 87 cases respectively, all exiting 0.

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
| `sweep_exit` restored to testing `defects` first and returning | exit fold is the severity order | `exit fold: 1 defect + 1 could-not-observe exited 3, not the folded 4: outbound artifacts: 0 satisfied, 1 defect, 1 could-not-observe` |
| unreadable head collapsed back onto the incomplete-binding verdict | unreadable head is could-not-observe | `unreadable head: classified as 'defect', not could-not-observe`, on a row whose own `"token": "FM_OUTBOUND_HEAD_UNOBSERVED"` sat beside `"verdict": "defect"` and `"missing": "head"` |
| the same collapse, seen by the class-level control | no `*_UNOBSERVED` token reaches a defect | `unobserved class: a could-not-observe token was rendered as a defect: FM_OUTBOUND_HEAD_UNOBSERVED` |

The first two mutations were each applied ALONE, to a build carrying the other fix, so each red is attributable to one hunk: the exit-fold build passed 44 other cases and failed only the fold control, and the unreadable-head build passed 43 others.

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
That last one is reported as `FM_OUTBOUND_DONE_ARCHIVE_UNREADABLE` rather than folded into the unobserved-work-state token, because the two carry different repairs: no record is a gap in the corpus with nothing to do, while an unreadable archive is a permissions or I/O fault someone can go and fix.
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

Ambiguity and mismatch are separate classifications, not two spellings of one refusal.
A mismatch says the one candidate found is not about this work; ambiguity says several were found and none can be chosen.
So a comment carrying more than one ruling marker, and an exact head carrying more than one open pull request, are reported as `FM_OUTBOUND_AMBIGUOUS_CANDIDATES` with their observed count rather than as a misaddressed ruling or an unread forge - both refuse either way, but only one of the two labels sends the reader to the condition that actually holds.

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
| `reconcile-status-provenance` | `reconcile` reports the verdict of the stage that produced it: an emit that exhausts transport exits 4, and the following sweep's 3 never overwrites it | Read the status of a different pipeline stage - observed red, reported 3 for a could-not-observe emit | Does not cover more than one failing emit in one run; `reconcile-report-completeness` below owns the fact that a refusal no longer ends the run |
| `emit-lock-release` | Every emit releases its own per-request lock during the run rather than at process exit, so a multi-item `reconcile` leaves none behind | Drop the explicit release and rely on the EXIT trap - observed red, one lock left behind | Does not cover a process killed between acquiring and releasing; that lock is reclaimed by the dead-pid steal, which is a separate mechanism |
| `sweep-identity-distinct` | The sweep reports a readable record naming another request as an identity refusal and a defect, never as an unreadable record | Collapse the mismatch return back onto the unreadable return - observed red, exit 4 and `RECORD_UNREADABLE` | Does not cover a record that is both foreign and unparseable; the unparseable answer wins, correctly |
| `unparsable-lifecycle-row` | A candidate row whose lifecycle state cannot be parsed is work-state-unobserved, not a lifecycle conflict | Drop the zero-state branch so zero collapses onto the disagreement branch - observed red | Does not widen what the parser accepts; an indented row is still unreadable, it is now reported as unreadable rather than as a disagreement |
| `reconcile-report-completeness` | Every selected item is attempted, the report renders on the way out regardless, and the returned status is the worst outcome rather than the place it stopped | Restore `cmd_emit ... \|\| exit $?` - observed red, output collapsed to one un-prefixed `transport failed after 3 attempts` line with no `OUTBOUND:` token at all | Does not cover a refusal that kills the process outright; a SIGKILL mid-emit still loses the report, and bootstrap's own deadline line is what covers that |
| `observed-artifact-is-named` | An identity refusal names the artifact it actually observed and the request id whose record disagrees, and never borrows the no-artifact sentence | Pass an empty artifact and drop the token's own sentence - observed red, the row rendered `artifact: none` for an artifact the sweep had just read | Does not verify the named comment is still on the forge at read time; it reports the id this sweep observed |
| `bounded-report-survives-its-deadline` | A sweep stopped by `FM_OUTBOUND_BOOTSTRAP_DEADLINE` relays every finding it had already established AND still marks itself incomplete | Discard the child's output at the deadline - observed red, a real defect line vanished and only the deadline line remained | Does not recover a line the child was mid-write on when it was killed; the incompleteness marker is what covers that |
| `defect-heading-is-true-of-its-rows` | An observed artifact whose record names another request is filed under its own heading, never under the missing-artifact one, and the relay and human view agree | Put both under one heading - observed red, `artifact: comment/<id>` sat beneath a heading asserting no artifact exists | Does not split the could-not-observe section, whose rows share one honest heading |
| `branch-inventory` | A completed ship `fm/<item>` branch with unlanded work and no exact-head pull request is a defect; non-ship work is skipped; unknown or conflicting work state is could-not-observe; landed work is excluded | Remove branch enumeration - the anchor returns to zero defects at exit 0 | Covers registered non-local-only projects and the `fm/<item>` namespace only; historical completion evidence is not bound to the current branch head |
| `ambiguity-is-not-its-neighbour` | Several candidates and none choosable is classified as ambiguity, never as a misaddressed ruling or an unread forge: a comment with two ruling markers and an exact head with two open pull requests each name their count under the ambiguity token | Restore the neighbouring token at either site - observed red twice, `poll marker count: several candidates were not classified as ambiguous: FM_OUTBOUND_RULING_IDENTITY_MISMATCH: comment 570 carries 2 ruling marker lines` and the same assertion on the duplicate-head probe | Does not choose among the candidates; both sites still refuse and both still print their count, so only the label is under test |
| `unreadable-archive-is-named` | An existing done-archive that cannot be read is reported as an unreadable archive, not as an unobserved work state, because one is a repairable fault and the other is an empty corpus | Return the generic gap code from the unreadable-archive branch - observed red, `archive unreadable: the unreadable archive was not named: outbound artifacts: 0 satisfied, 0 defect, 1 could-not-observe` | Root can read anything, so the case self-skips under uid 0; it does not cover an archive that reads but is truncated |
| `exit-fold-not-a-shortcut` | A sweep holding BOTH a defect and a could-not-observe exits 4, the module's own severity order, rather than short-circuiting on the defect count; a defect-only sweep still exits 3 | Restore the `defects`-first return - observed red, exited 3 on 1 defect + 1 could-not-observe | An unevaluable-ONLY sweep already exited 4 before the fix, so only the mixed sweep distinguishes the fold from the ladder; this row does not cover the probe-cap input, which reaches the same branch by a separate condition |
| `unreadable-head-is-could-not-observe` | A binding missing ONLY its head is could-not-observe, because the head could not be READ and the forge was never consulted; a binding missing a structural field stays a defect even when the head is unreadable too | Collapse the split back onto one defect verdict - observed red at the row level and again at the class level | Does not establish that an artifact exists for those items; it establishes only that this sweep did not look, which is the whole claim |
| `no-unobserved-token-is-a-defect` | No `*_UNOBSERVED` token in this vocabulary ever reaches a `defect` verdict, so the class cannot be re-entered by a future token | Collapse the head split - observed red naming the offending token | Bounded to tokens whose NAME ends `_UNOBSERVED`; a could-not-observe condition given a name outside that convention is outside its universe |
| `declared-token-has-an-emitter` | Every `FM_OUTBOUND_TOKEN_*` declared in the lib's closed vocabulary is expanded somewhere in this module, and every violation is named in one failure | Declare two tokens that nothing emits - observed red, `token vocabulary: declared and never emitted: FM_OUTBOUND_TOKEN_PROBE_ONE FM_OUTBOUND_TOKEN_PROBE_TWO`; indenting the whole block out of the reader's sight - observed red, `no token declarations were read` | Bounded to this module's two files: it proves a token is expanded, not that the expansion reaches an operator, and it says nothing about declared vocabularies elsewhere in the repository |

## One recurrence, five instances: a canonical thing that exists and is not consulted

Five separate review findings in this module were the same defect, and naming the shape matters more than the five fixes:

- `fm_outbound_applicability` - written correct, zero call sites, so no applicability test ran at all.
- `fm_outbound_record_state_valid` - defined once, consulted nowhere.
- `record_read` - a three-valued verdict collapsed back to a boolean at five call sites, so a readable record belonging to another request reported as merely unreadable.
- the typed `outbound-gate.json` declaration - authoritative in name, outranked by prose, so a stale sentence could route a detect-only item onto the emitting channel.
- `FM_OUTBOUND_TOKEN_AMBIGUOUS` and `FM_OUTBOUND_TOKEN_ARCHIVE_UNREADABLE` - declared in a block the header presents as the closed gate vocabulary, emitted by nothing, while the conditions they name were already detected at three live sites and reported there under a NEIGHBOURING token.

In each case the artifact existed, read correctly, and was not consulted - which is why reading the code proves nothing and only exercising it does.
The dead-predicate control catches the first two shapes and explicitly does not catch the last three; that boundary is stated in its own header rather than inferred.
The fifth is the shape one level below the control's reach: it scans function definitions for call sites, so a CONSTANT that is declared and never emitted is outside its universe by construction.
That instance was resolved by emitting both tokens rather than by deleting them, because a token whose condition is reachable and mislabelled is a reporting defect, and deleting it would have preserved the wrong label while removing the evidence that a better one was intended.
It is also the only one of the five with a mechanical guard: the `declared-token-has-an-emitter` control above reads this module's declarations and refuses an unemitted one, so the rule the lib header states is enforced rather than re-verified by hand.
That guard is deliberately module-local; the general form - every declared vocabulary in the repository - belongs with the dead-predicate control and is filed separately as `dead-token-detection`.

## Two standing laws this surface now applies

Browser Sol generalised the containment findings on this task into two laws, and they are recorded here because the code applies them rather than merely citing them.

**Discovery is not identity.** A substring, prefix, text occurrence, API hit, path or name match discovers CANDIDATES only, and can never by itself satisfy an identity-bearing join, dedupe, applicability, wait, authorization or acceptance decision. A discovered candidate must be validated by the consumer against the complete exact identity that decision needs. Prefix relation is never equality. Three instances were found on this surface: a forge endpoint returning pull requests that merely CONTAIN a commit, quoted prose counting as a call site, and a substring of a comment body satisfying request presence. A class sweep for containment-style matching across the outbound surface found no fourth; the sweep's own near-miss is recorded below.

**Negative claims require complete observation.** Absent, no caller, dead predicate, nothing waiting - each qualifies only when the candidate universe is observable enough to exclude a satisfying member. `found=0` is not `clean=true` unless the verifier also establishes its completeness predicate, which is why the dead-predicate summary always prints `alive=` and `could_not_observe=` and why the sweep reports observation gaps beside findings.

The completeness predicate is PROPERTY-SCOPED, not global. The universe for one predicate is its possible callers, so an unreadable file that never references the name is irrelevant to that predicate's claim. A loose identifier pass decides that, and the asymmetry is what makes it sound: loose matching is legitimate for EXCLUDING a file from a universe, where a false positive costs only a could-not-observe, and is forbidden for CONFIRMING a call, where it would be the first law violated. Without property scoping, the unreadable majority of consumer files - the census `bin/fm-dead-predicate-check.sh`'s header owns and its summary line refreshes - made every unresolved predicate could-not-observe and the control answered almost nothing.

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

## The typed autonomous return path, and the seam proof

Captain directive 2026-08-30 (`SOL-FM-AUTOMATION-001`) closed the remaining gaps between a joined ruling and a landed effect.
This section records the evidence for the increment that added them; the clauses it does not mention were already held by the controls above.

### Why a suite was not enough, and what the seam proof adds

Every control in `tests/fm-outbound-artifact.test.sh` starts from a fixture, which is the right shape for proving a control can fail and fails for its own reason.
It is deliberately not a proof that the stages compose: a stage handed a hand-written predecessor still passes when it could never have consumed the real one.
`bin/fm-outbound-seam-proof.sh` walks the whole return path once, forward, with each stage consuming the previous stage's real output - envelope, wait admission, stale ruling refused, exact ruling joined, replay, mint, freshness refusal, the real effect, one-use replay, exact-main closure, and the revision path.

The landing it performs is real and moves a branch, because an authorization that is never spent proves nothing about spending one.
It moves a branch in a throwaway repository the script creates and deletes, on a ref no protection applies to, so a real mutation is observed without manufacturing one against protected work.
Nothing in the run touches the operational home, a registered project, or a remote; the pull-request reference the fixture carries is answered by the forge shim and is never contacted.

The focused suites were run on 2026-08-30 on Linux 6.18.33.2-microsoft-standard-WSL2 with jq 1.8.1, each exiting 0: `tests/fm-landing-authorization.test.sh`, `tests/fm-dead-predicate-check.test.sh`, `tests/fm-wrong-subject.test.sh` and `tests/fm-bootstrap.test.sh` executed 32, 36, 13 and 39 cases respectively, all with zero failures.
`tests/fm-outbound-artifact.test.sh` was re-run on 2026-08-31 after the isolation and revised-record preservation controls landed; its 108 cases exited 0 with zero failures.
The suite grew from 101 cases to 108: seven controls were added, and one existing control was repaired rather than rewritten after typed effect plans made `mint` require an `--effect`, which had been refusing the `HOLD` case one step before the verdict it exists to classify.

The seam proof was run on the same date and host, twice, both exiting 0:

```sh
$ bash bin/fm-outbound-seam-proof.sh | tail -1
SEAM PROOF HELD: 12 stages, effect observed on a scratch subject only
```

The observed effect in one run was the scratch target moving `e8498e34d667c0fcaf704c86ec67f5bccce7c636 -> 4192ff65f237820ba864658c7f56f1033b2c5ca4`, and the closure recorded `verification: exact` against that generation.

### What the walk found that the fixtures did not

Two defects surfaced only because the stages were composed, and each now has its own control.

**Replaying a ruling rewrote the record.**
Rejoining the identical comment rewrote `observed` and `updated` every time, so the record's own bytes stopped answering "has anything happened since?", and anything comparing the record across a replay saw movement that was only the clock.
The fixtures missed it because both writes landed in the same second until the walk got slower.
An identical ruling now converges and writes nothing, while a different one still joins; `test_replaying_the_same_ruling_writes_nothing` pins both halves.

**A one-use authority converges rather than refusing.**
The first version of the walk asserted that a second spend fails.
It does not, and should not: a wake that arrives twice must not perform the act twice and must not report a failure for work already done, so an already-spent authority reports what it is and performs no act.
What makes it one-use is the absence of a second effect, so the stage now measures the target being unchanged rather than an exit status.

### Watched-red evidence for the new controls

Each control below was driven RED by a targeted mutation of the shipped implementation, syntax-checked with `bash -n` before the suite ran, and the implementation restored afterwards.

Each mutation was applied to a scratch copy of `bin/` and `tests/` rather than to the working tree, because sibling lanes were running the same suites concurrently and an in-place mutation would have raced them.
An earlier run of this suite proved that hazard is real rather than theoretical: a background suite launched while the implementation was being edited reported a syntax error and one unrelated failure, both artifacts of reading a half-written file, and neither reproduced on a clean re-run.

| Mutation | Control that caught it | Observed failure |
| --- | --- | --- |
| the backing-request requirement in `cmd_declare` bypassed | a wait may not be declared unbacked | `declare RED: an unbacked wait was declared: declared: waiting-item waits at AWAITING_BROWSER_SOL on ` |
| the terminal-state skip removed, so a retired request is a candidate | a retired request backs no wait | `terminal RED: a quarantined request backed a wait: declared: waiting-item waits at AWAITING_BROWSER_SOL on fm-ob-d1e3c2b13d5e` |
| `resume` no longer classifies a revising verdict | a revision never resumes | `revise RED: a REVISE ruling resumed the item it rejected: resumed: waiting-item` |
| `correct` accepts any verdict, not only a revising one | correction is not a way to discard a verdict | `correct RED: an approved request was retired as revised: revised: fm-ob-2e1d84fd0eea retired for correction` |
| closure no longer demands the authority the request had | a closure may not omit an effect it had | `closure RED: a spent landing authority closed on prose alone: closed: fm-ob-41ea8cc37b74 - landed, all good` |
| the chain predicate replaced by `true` | a foreign authority cannot close this request | `chain RED: a foreign authority closed this request: closed: fm-ob-e46a15d237c6 - landed` |
| the spent-and-applied predicate replaced by `true` | an unspent authority closes no effect | `chain RED: an unspent authority closed an effect: closed: fm-ob-45b0550a7433 - landed` |
| the observed-versus-claimed generation comparison disabled | the target ref is re-observed, not trusted | `chain RED: a generation the ref is not at was accepted: closed: fm-ob-33777757525f - landed (master at 0da270fb..., observed)` |
| the `exact-tree` line dropped from the request body | a request states the generation it is bound to | `wire: the request does not state the tree it is bound to` |
| the identical-ruling convergence disabled | replaying a ruling writes nothing | `replay: rejoining the same ruling changed the record: ruled: fm-ob-7b8bf0e40863 wakes waiting-item` |

One mutation was recorded as passing and then re-run, which is why it appears here as a red.
The chain-predicate edit was first applied through a shell-quoted one-liner that mangled its own escaping, so the replacement never matched, the file was unchanged, and the control reported `ok`.
A mutation that does not apply and a control that does not fire produce the same output, so the run was only trustworthy once the replacement was asserted to have matched exactly once before the suite ran.

Two of those controls were themselves wrong on first run, and both are recorded because a control that passes by agreeing with the implementation is the failure mode this document exists to catch.
The foreign-authority case built its second authority from an identical fixture, and the request identity is DERIVED from the governed subject, so the two fixtures were not two requests - they were the same request id computed twice, and the "foreign" authority belonged to the request under test.
The wrong-generation case named a head that the scratch clone's branch happened to already be at, so it asserted the ref was wrong while handing it the right answer.
Both now derive their adversarial value from what was actually observed rather than from a fixture constant.

### What the closure does and does not prove

A fast-forward landing is exactly checkable, because `ff-only` makes the target BECOME the authorized head, so anything else at that ref means something other than the authorized act moved it; the record stores `verification: exact`.
A squash or rebase merge produces a forge-authored commit that no local rule predicts, so for those the closure binds the generation the target ref is OBSERVED at and stores `verification: observed`, without claiming the reviewed head is contained in it.
The record states which was achieved rather than letting the stronger reading be assumed, because a uniform claim across both would be false for one of them.
