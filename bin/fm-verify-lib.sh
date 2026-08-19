#!/usr/bin/env bash
# fm-verify-lib.sh - single owner of firstmate's three-valued observation type
# and of the check-set classification rule that depends on it.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-verify-lib.sh
#   . "$SCRIPT_DIR/fm-verify-lib.sh"
#
# THE TYPE RULE
#
# An observation returns three values, never two:
#   PASS             observed, and the subject is good
#   FAIL             observed, and the subject is bad
#   NO_VERIFIER_RAN  the observation did not happen
#
# The measured root cause of ten separate defects in this fleet was one type
# error: a function that can fail to OBSERVE returning the same type as one that
# observed a NEGATIVE result. "I looked and found nothing" and "I could not
# look" collapse into one value - empty, zero, false, absent - and that value
# then reads as fine.
#
# The third value never dies by being forgotten. It dies at a conversion: an
# exit code narrowing, an empty collection counting as zero failures, an
# unreadable file counting as no findings, a missing check set counting as a
# clean one. So this library gives consumers exactly one way to read a result -
# fm_verify_case, which refuses a consumer that does not handle all three - and
# exactly one way to narrow it - fm_verify_coerce, which is loud and logged.
#
# A caller who wants a two-branch read has to say so in writing, and the saying
# is the record.
#
# THE CHECK-ROLLUP RULE - ONE OWNER OF "IS THIS EXACT HEAD GREEN?"
#
# The question this section answers, in the words that make it one question:
# "is this exact candidate head sufficiently validated under the currently
# applicable required gate set?"
#
# It had two owners until 2026-08-18, and they were measured disagreeing. This
# file classified `gh pr view --json statusCheckRollup` with no attempt
# reduction, so any attempt that ever failed against a head made the head
# `failing` forever; bin/fm-pr-merge.sh classified a GraphQL rollup that
# reduced repeated executions to the current attempt and reconciled the members
# against totalCount. Driven with one head, one check `CI`, an older FAILURE and
# a newer SUCCESS, this file said `failing` and the merge gate said green. Both
# were credited with the same sentence.
#
# The direction matters. This file was the STRICTER one, so it produced a false
# FAIL rather than a false pass - and a FAIL is a positive observed-bad claim
# that propagates: bin/fm-certify.sh records it as LANDED_WITH_VERIFICATION_GAP,
# bin/fm-slot-reservation.sh admits a trunk-repair reservation on it and
# withholds a pool slot, and a crewmate told FAIL on a green head chases a
# defect that is not there. "Did any attempt at this head ever fail?" and "is
# this head failing?" are different questions, and only the second one is this.
#
# So there is now ONE FOLD, in FM_VERIFY_ROLLUP_FOLD, and two normalizers that
# feed it. A source that cannot supply an input the fold wants says so and gets
# a could-not-observe, rather than answering a narrower question and having the
# answer credited to this one.
#
# THE SIX LABELS. The fold produces exactly one of:
#
#   none          no check ran at all - the empty set. NOT green, ever. A pull
#                 request whose checks were never created, whose workflow file
#                 is broken, or whose runs were pruned looks exactly like a
#                 pull request that passed, unless the empty set is named
#                 separately. This is one of the three measured incidents that
#                 put the three-valued type in this fleet.
#   failing       at least one check's CURRENT attempt reached a terminal
#                 negative verdict: FAILURE, STARTUP_FAILURE, or ERROR. A
#                 workflow that failed to start never clears by waiting and
#                 re-running reproduces it until someone fixes the workflow, so
#                 it is a verdict and not a could-not-observe.
#   pending       checks exist and at least one current attempt has not
#                 completed. No verdict yet, and one may still arrive.
#   truncated     the member set was never established well enough to speak for
#                 this head. Three ways, all could-not-observe: the source
#                 returned fewer members than it reported; the members fill the
#                 page the source serves, so the extent was never established;
#                 or several attempts at one check carry no usable ordering, so
#                 WHICH one is current was never established. "No member is
#                 non-SUCCESS" is a negative claim, and over a set nothing fully
#                 read or ordered it is a negative claim about records nothing
#                 read.
#
#                 `gh pr view` and `gh pr list` ask for contexts(first:100) -
#                 verified against gh 2.96.0's own request body, both
#                 subcommands - and flatten away both totalCount and pageInfo,
#                 so a head with more than 100 members returns the OLDEST 100
#                 and silently drops the newest: a check re-run after 100
#                 earlier executions is exactly the member that would be
#                 missing. At exactly 100 members a full set and a truncated one
#                 are indistinguishable in that response, so both refuse. That
#                 costs a re-read on a head with exactly 100 checks and prevents
#                 a false green on every head above it.
#
#                 The label sits BELOW failing and pending on purpose:
#                 incompleteness kills negatives, not positives, so a failure
#                 actually observed in the returned part is still a failure
#                 about this head whatever else went unread.
#   inconclusive  every current attempt completed, none failed, and at least one
#                 ended without earning a verdict - TIMED_OUT, CANCELLED,
#                 ACTION_REQUIRED, SKIPPED, STALE, NEUTRAL, an absent
#                 conclusion, or any conclusion this rule does not know, which
#                 reaches this label by design rather than by omission. None of
#                 them observed the pull request: a run cancelled by a
#                 superseding push or killed by a timeout says nothing about
#                 the code, and ACTION_REQUIRED completed only to say a human
#                 must act. Folding any of them into "passing" is the empty
#                 set's defect one level down, and folding them into "failing"
#                 asserts a verdict nothing earned. No verdict, and none is
#                 coming.
#   passing       the set is non-empty, its extent is established, and EVERY
#                 check's current attempt completed successfully.
#
# ONE ADVERSE SET. The two owners also disagreed about TIMED_OUT: the merge gate
# counted it adverse, this file counted it a non-verdict. The narrower set wins,
# for the reason above - FAIL is a positive claim and TIMED_OUT never earned one
# - and nothing gets weaker by it: TIMED_OUT moves from the failing bucket to
# the no-verdict bucket, and BOTH refuse a merge. The merge gate's refusal
# changes wording, from "failed" to "reported no result", and not outcome.
#
# Two GitHub vocabularies meet here, which is why the rule reads
# .conclusion // .state: FAILURE, TIMED_OUT, CANCELLED, ACTION_REQUIRED,
# STARTUP_FAILURE, NEUTRAL, SKIPPED, STALE and SUCCESS are check-run
# conclusions, while ERROR, PENDING and EXPECTED belong to the older
# commit-status state vocabulary. Completeness is read per vocabulary too: a
# check run is complete when its status is COMPLETED, and a commit status is
# complete unless its state is PENDING or EXPECTED. A value neither vocabulary
# knows completes without a verdict, reaching "inconclusive" by the same
# by-design default the unknown conclusions do, so an unrecognized value can
# never arrive as a pass through either vocabulary's gap.
#
# Which vocabulary a member speaks is read from the member, not only from its
# __typename: a member carrying a .status field is a check run whether or not it
# says so. Both sources do send __typename, and a rule that trusted only that
# field would still silently reclassify every member of any caller that did not
# ask for it, turning a completed pass into a pending one.
#
# ATTEMPT REDUCTION. A head accumulates every execution ever run against it, not
# only the current one, so members are reduced to one verdict per check before
# anything is counted. Two members are two attempts at one check when they carry
# the same owning workflow and the same name, and the attempt with the newest
# ordering key speaks for that check. A member the source reports with no name
# is never an attempt at anything, because nothing identifies what it would
# supersede, so each of those counts on its own. Without that reduction a
# re-triggered check leaves its earlier run attached to the head forever, and
# that head can never be green again however often the check subsequently
# passes; the only escape is a new head, which for the attestation check needs a
# fresh attestation, so the pattern repeats. Reduction never excuses a current
# verdict: a failing latest attempt still refuses, and where attempts tie for
# latest the worst decides, so a tie can never manufacture a pass. Where a group
# of several attempts carries no usable ordering key at all, WHICH attempt is
# current was never established, and the group is UNDECIDABLE rather than
# resolved.
#
# TWO SOURCES, TWO EXPLICIT NARROWER PROPERTIES, ONE FOLD.
#
#   FM_VERIFY_ROLLUP_NORMALIZE_GRAPHQL - the AUTHORITATIVE source, and the only
#     one that may answer for a merge. FM_VERIFY_ROLLUP_GRAPHQL asks for
#     contexts(last:100) with totalCount, the commit's own oid alongside
#     headRefOid, and each CheckRun's databaseId. Its properties: the members
#     are the NEWEST page, their extent is reconciled against totalCount, the
#     evidence is bound to a named commit, and attempts are ordered by a
#     monotonic run identifier with the timestamp only as a tie-breaker.
#
#   FM_VERIFY_ROLLUP_NORMALIZE_FLAT - the NARROWER source, for gh's flattened
#     `--json statusCheckRollup`, which is the only shape available when many
#     pull requests are read in one listing. Its narrower properties, each one
#     a thing the fold is told rather than left to assume: it carries NO
#     totalCount, so its extent is provable only by the page sentinel; it
#     carries NO databaseId, so attempts are ordered by startedAt alone and a
#     group whose members share or lack that timestamp is UNDECIDABLE rather
#     than resolved; and it carries NO commit oid, so the evidence cannot be
#     bound to the head that was asked about. That last one is why this source
#     may never authorize a merge: it cannot say the checks it read belong to
#     the head being merged. FM_VERIFY_CHECK_ROLLUP_EXPR is this normalizer
#     folded, kept under its original name because it is spliced into a larger
#     jq program by its one consumer.
#
# Both normalizers emit the same object, and FM_VERIFY_ROLLUP_FOLD is the only
# thing that turns one into a label. A third source added later normalizes into
# that object and states its own narrower properties; it does not get a fold.
#
# CONSUMERS map the six labels onto their own vocabulary and must never collapse
# "none", "pending", "truncated", or "inconclusive" into a pass:
#   - bin/fm-verify.sh `pr-checks` reads the authoritative source and maps
#     none/pending/truncated/inconclusive to NO_VERIFIER_RAN and passing to PASS.
#   - bin/fm-pr-merge.sh reads the same authoritative source through
#     fm_verify_rollup_classify and refuses any label but passing, enriching
#     that refusal with its own wording from the published counts.
#   - bin/fm-bearings-snapshot.sh renders the narrower source's label as a
#     per-pull-request display projection and authorizes nothing.
#
# The jq expressions take no jq arguments, so a caller splices one into a larger
# single-quoted program without disturbing that program's own jq variables.

# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts, not by this
# file, and the $-prefixed names inside are jq variables that must reach jq
# unexpanded - the single quotes are the point.

# The page GitHub serves for a check-rollup connection. Not a choice made here:
# it is the connection's own limit, and a head carrying more than that is
# refused as unread rather than judged on the part that happened to arrive.
FM_VERIFY_ROLLUP_PAGE_LIMIT=100

# The whole adverse set. Anything absent from it that is not SUCCESS counts as a
# non-verdict rather than as a failure, so "this was examined and found broken"
# never reaches a reader wearing the words of "this was never examined".
FM_VERIFY_ROLLUP_ADVERSE='["FAILURE","STARTUP_FAILURE","ERROR"]'

# WHICH VOCABULARY ONE MEMBER SPEAKS, decided once and used everywhere a field
# differs between them. Evaluated with the member as its input, so it is spliced
# as-is in a normalizer and as (.value | ...) inside the reduction.
#
# __typename first, because both sources ask for it and it is the source's own
# answer. The .status fallback is for a caller that did not: a member carrying a
# .status field is a check run whether or not it says so, and without the
# fallback such a member would be read against the commit-status rules and a
# completed pass would silently become a pending one.
FM_VERIFY_ROLLUP_KIND='(if .__typename == "CheckRun" then "run"
   elif .__typename == "StatusContext" then "status"
   elif ((.status // "") != "") then "run"
   else "status" end)'

# The authoritative query. It is written here rather than taken from `gh pr view
# --json statusCheckRollup`, because that field flattens the rollup into members
# that carry no commit of their own. The rollup is the one GitHub attached to the
# pull request's latest commit, but nothing in that response says which commit
# that was, so evidence describing a superseded head reads exactly like evidence
# describing the head being asked about. This asks for that commit's own oid in
# the same snapshot as headRefOid so the two can be compared, and asks for the
# rollup's totalCount so members GitHub reported but did not return are refused
# as unread rather than counted as absent. mergeable and reviewDecision ride
# along because they are read from the same snapshot by the merge gate; they are
# not part of the greenness question and the fold ignores them.
# The $-prefixed names below are GraphQL variables, not shell expansions.
FM_VERIFY_ROLLUP_GRAPHQL='query($owner:String!,$repo:String!,$number:Int!){
  repository(owner:$owner,name:$repo){
    pullRequest(number:$number){
      headRefOid
      mergeable
      reviewDecision
      commits(last:1){nodes{commit{oid
        statusCheckRollup{contexts(last:100){totalCount nodes{
          __typename
          ... on CheckRun{databaseId name status conclusion startedAt checkSuite{workflowRun{workflow{name}}}}
          ... on StatusContext{context state createdAt}
        }}}
      }}}
    }
  }
}'

# The reduction from executions to checks, shared by both normalizers. Input is
# $members and $adverse; output is $checks, one entry per check with a verdict
# from the closed set SUCCESS / FAILING / PENDING / INCONCLUSIVE / UNDECIDABLE.
#
# Each member arrives carrying _order and _workflow, which its own normalizer
# supplied. The reduction never reaches for a substitute when _order is absent,
# and that is deliberate: WHICH key orders attempts is a property of the source,
# not of this rule. The authoritative source orders by a monotonic run
# identifier and nothing else, so a response missing it is UNDECIDABLE there;
# the flattened source has no such identifier at all and orders by start time,
# and that weaker guarantee is declared in its own normalizer rather than
# silently borrowed here. A fallback chain in this shared rule would hand the
# authoritative source the weaker key without anyone deciding to.
#
# PENDING and INCONCLUSIVE are separate because "no verdict yet, one may arrive"
# and "no verdict, and none is coming" send a reader to different actions. A
# consumer that needs them as one unsuccessful-but-not-failing bucket adds them;
# a consumer cannot split a bucket that arrived already merged.
FM_VERIFY_ROLLUP_REDUCE='($members | to_entries | map(
    (.value.name // .value.context // "") as $name
    | (.value | '"$FM_VERIFY_ROLLUP_KIND"') as $kind
    | {name: $name,
       check: (if ($name | length) == 0 then ["unnamed", (.key | tostring)]
               elif $kind == "run" then ["run", (.value._workflow // ""), $name]
               else ["status", $name] end),
       order: .value._order,
       complete: (if $kind == "run"
                  then (.value.status // "") == "COMPLETED"
                  else ((.value.state // "") | ascii_upcase
                        | . != "PENDING" and . != "EXPECTED" and . != "") end),
       verdict: ((.value.conclusion // .value.state // "") | ascii_upcase)})) as $attempts
  | ($attempts | group_by(.check) | map(
      . as $group
      | if (($group | length) > 1 and ($group | any(.order == null)))
        then {name: $group[0].name, verdict: "UNDECIDABLE"}
        else (map(.order) | max) as $latest
        | map(select(.order == $latest)) as $current
        | {name: $current[0].name,
           verdict: (if ($current | any(.verdict as $v | ($adverse | index($v)) != null))
                     then "FAILING"
                     elif ($current | any(.complete | not)) then "PENDING"
                     elif ($current | any(.verdict != "SUCCESS")) then "INCONCLUSIVE"
                     else "SUCCESS" end)} end)) as $checks'

# GraphQL response -> the normalized rollup object the fold consumes.
# subject is "bound" when the members demonstrably belong to the head asked
# about, "mismatch" when they belong to another commit, and "unbound" when the
# source cannot say. reported is the source's own count of members, or null when
# the source does not supply one.
FM_VERIFY_ROLLUP_NORMALIZE_GRAPHQL='.data.repository.pullRequest as $pr
  | ($pr.commits.nodes[0].commit // {}) as $commit
  | ($commit.statusCheckRollup.contexts // {}) as $contexts
  | (($contexts.nodes // []) | map(. + {
      _workflow: (.checkSuite.workflowRun.workflow.name),
      _order: (if '"$FM_VERIFY_ROLLUP_KIND"' == "run" then .databaseId else .createdAt end)})) as $members
  | ('"$FM_VERIFY_ROLLUP_ADVERSE"') as $adverse
  | '"$FM_VERIFY_ROLLUP_REDUCE"'
  | {head: ($pr.headRefOid // ""),
     evidence_head: ($commit.oid // ""),
     subject: (if (($pr.headRefOid // "") | length) == 0 then "unbound"
               elif (($commit.oid // "") | length) == 0 then "unbound"
               elif ($commit.oid == $pr.headRefOid) then "bound"
               else "mismatch" end),
     mergeable: ($pr.mergeable // ""),
     review: ($pr.reviewDecision // ""),
     members: ($members | length),
     reported: $contexts.totalCount,
     checks: $checks}'

# One flattened `gh pr view`/`gh pr list` element -> the same normalized object.
# See the narrower properties in this file's header: no totalCount, no
# databaseId, no commit oid.
FM_VERIFY_ROLLUP_NORMALIZE_FLAT='((.statusCheckRollup // []) | map(. + {
      _workflow: (.workflowName),
      _order: (if '"$FM_VERIFY_ROLLUP_KIND"' == "run" then .startedAt else .createdAt end)})) as $members
  | ('"$FM_VERIFY_ROLLUP_ADVERSE"') as $adverse
  | '"$FM_VERIFY_ROLLUP_REDUCE"'
  | {head: "",
     evidence_head: "",
     subject: "unbound",
     mergeable: (.mergeable // ""),
     review: (.reviewDecision // ""),
     members: ($members | length),
     reported: null,
     checks: $checks}'

# THE FOLD. Normalized rollup object -> exactly one of the six labels. This is
# the only place a check set becomes a verdict about a head.
#
# Precedence, and why each step sits where it does:
#   1. failing     a verdict actually observed survives every incompleteness
#                  below it. Incompleteness kills negatives, not positives.
#   2. pending     an observed positive fact about the set - something is still
#                  running - and not a negative claim over what went unread.
#   3. truncated   from here down every remaining answer is a negative claim, so
#                  an extent or an ordering that was never established kills it.
#   4. none        an empty set whose emptiness the source could actually
#                  establish. Never green.
#   5. inconclusive / passing
FM_VERIFY_ROLLUP_FOLD='. as $r
  | ($r.checks | map(select(.verdict == "FAILING")) | length) as $failing
  | ($r.checks | map(select(.verdict == "PENDING")) | length) as $pending
  | ($r.checks | map(select(.verdict == "UNDECIDABLE")) | length) as $undecidable
  | ($r.checks | map(select(.verdict != "SUCCESS")) | length) as $unsuccessful
  | if $failing > 0 then "failing"
    elif $pending > 0 then "pending"
    elif ($r.reported != null and $r.reported != $r.members) then "truncated"
    elif ($r.reported == null and $r.members >= '"$FM_VERIFY_ROLLUP_PAGE_LIMIT"') then "truncated"
    elif $undecidable > 0 then "truncated"
    elif ($r.checks | length) == 0 then "none"
    elif $unsuccessful > 0 then "inconclusive"
    else "passing" end'

# The narrower source, folded. Kept under its original name because
# bin/fm-bearings-snapshot.sh splices it into a larger jq program.
FM_VERIFY_CHECK_ROLLUP_EXPR='('"$FM_VERIFY_ROLLUP_NORMALIZE_FLAT"') | ('"$FM_VERIFY_ROLLUP_FOLD"')'

# The normalized object rendered as the key=value lines fm_verify_rollup_classify
# reads back. One line per fact, so one unreadable field cannot hide behind
# another's digits.
FM_VERIFY_ROLLUP_COUNTS='. as $r
  | ('"$FM_VERIFY_ROLLUP_FOLD"') as $label
  | "label=\($label)",
    "subject=\($r.subject)",
    "head=\($r.head)",
    "evidence_head=\($r.evidence_head)",
    "mergeable=\($r.mergeable)",
    "review=\($r.review)",
    "members=\($r.members)",
    "reported=\($r.reported // "")",
    "checks=\($r.checks | length)",
    "unsuccessful=\($r.checks | map(select(.verdict != "SUCCESS")) | length)",
    "failing=\($r.checks | map(select(.verdict == "FAILING")) | length)",
    "pending=\($r.checks | map(select(.verdict == "PENDING")) | length)",
    "inconclusive=\($r.checks | map(select(.verdict == "INCONCLUSIVE")) | length)",
    "undecidable=\($r.checks | map(select(.verdict == "UNDECIDABLE")) | length)"'

# fm_verify_rollup_waived_counts_expr <check-name>: the jq lines that break the
# reduced check set down for ONE named check, printed on stdout for a caller to
# append to FM_VERIFY_ROLLUP_COUNTS.
#
# It lives here for the same reason the fold does. The waiver itself belongs to
# bin/fm-pr-merge.sh - nothing else may narrow this question, and even there it
# narrows exactly one named check - but the VERDICT VOCABULARY it selects on is
# this file's, and a copy of it in the caller is a copy of the contract. A caller
# that spelled "FAILING" itself would keep working the day a verdict is renamed
# here and would silently start subtracting nothing.
#
# The name is embedded as a jq string literal, so the caller must have refused
# any quote, backslash, control character, or newline in it first; this refuses
# rather than escapes, because a name it has to rewrite is a name the caller's
# own refusals never saw.
fm_verify_rollup_waived_counts_expr() {
  local name=${1:-}
  [ -n "$name" ] || return 1
  case "$name" in
    *'"'*|*\\*) return 1 ;;
  esac
  [ "$name" = "${name//[[:cntrl:]]/}" ] || return 1
  local select='(.checks | map(select(.name == "'"$name"'")))'
  # unrun is PENDING and INCONCLUSIVE together, matching the single
  # no-verdict-yet bucket the merge gate subtracts from. UNDECIDABLE is
  # deliberately absent: a group whose current attempt was never established is
  # not something a waiver on one check name may cancel.
  printf '"waived=\\(%s | length)",\n' "$select"
  printf '"waived_failing=\\(%s | map(select(.verdict == "FAILING")) | length)",\n' "$select"
  printf '"waived_unrun=\\(%s | map(select(.verdict == "PENDING" or .verdict == "INCONCLUSIVE")) | length)"\n' "$select"
}

# --- the canonical classifier ------------------------------------------------

# fm_verify_rollup_classify <lines> [<expected-head>]: the shell half of the one
# owner. It takes the FM_VERIFY_ROLLUP_COUNTS output of the AUTHORITATIVE source,
# checks the integrity of that response, and publishes the classification.
#
# It does not fold. FM_VERIFY_ROLLUP_FOLD already did that, once, in jq. What
# this adds is every refusal jq cannot express: an absent or malformed response,
# a field that is not a whole number, a reduction that produced more checks than
# members, buckets that do not account for the unsuccessful members, and
# evidence bound to a commit other than the one asked about. Each of those is a
# could-not-observe about the head, and none of them is allowed to arrive as a
# label.
#
# Publishes:
#   FM_VERIFY_ROLLUP_LABEL   one of the six labels, or "unreadable"
#   FM_VERIFY_ROLLUP_REASON  a token from the closed vocabulary below
#   FM_VERIFY_ROLLUP_HEAD FM_VERIFY_ROLLUP_EVIDENCE_HEAD
#   FM_VERIFY_ROLLUP_MERGEABLE FM_VERIFY_ROLLUP_REVIEW
#   FM_VERIFY_ROLLUP_MEMBERS FM_VERIFY_ROLLUP_REPORTED FM_VERIFY_ROLLUP_CHECKS
#   FM_VERIFY_ROLLUP_UNSUCCESSFUL FM_VERIFY_ROLLUP_FAILING
#   FM_VERIFY_ROLLUP_PENDING FM_VERIFY_ROLLUP_INCONCLUSIVE
#   FM_VERIFY_ROLLUP_UNDECIDABLE
#
# "unreadable" is NOT a seventh greenness label. It is the absence of a subject
# to answer the greenness question about, and it is why the reason vocabulary is
# separate from the label:
#   verified          members_unread    set_truncated   order_undecidable
#   checks_failed     checks_pending    no_verdict      empty_set
#   subject_mismatch  source_unbound    response_unreadable
#
# EXIT STATUS IS THREE-VALUED, LIKE THE ANSWER: 0 only for passing, 1 for
# failing, 2 for everything else. A consumer that reads only the status
# therefore cannot turn a could-not-observe into either of the other two.
FM_VERIFY_ROLLUP_LABEL=
FM_VERIFY_ROLLUP_REASON=
FM_VERIFY_ROLLUP_HEAD=
FM_VERIFY_ROLLUP_EVIDENCE_HEAD=
FM_VERIFY_ROLLUP_MERGEABLE=
FM_VERIFY_ROLLUP_REVIEW=
FM_VERIFY_ROLLUP_MEMBERS=
FM_VERIFY_ROLLUP_REPORTED=
FM_VERIFY_ROLLUP_CHECKS=
FM_VERIFY_ROLLUP_UNSUCCESSFUL=
FM_VERIFY_ROLLUP_FAILING=
FM_VERIFY_ROLLUP_PENDING=
FM_VERIFY_ROLLUP_INCONCLUSIVE=
FM_VERIFY_ROLLUP_UNDECIDABLE=

# fm_verify_rollup_unreadable <reason>: publish the could-not-observe and stop.
fm_verify_rollup_unreadable() {
  FM_VERIFY_ROLLUP_LABEL=unreadable
  FM_VERIFY_ROLLUP_REASON=$1
  return 2
}

fm_verify_rollup_classify() {
  local lines=${1:-} expected=${2:-} line label='' subject='' n
  FM_VERIFY_ROLLUP_LABEL=
  FM_VERIFY_ROLLUP_REASON=
  FM_VERIFY_ROLLUP_HEAD=
  FM_VERIFY_ROLLUP_EVIDENCE_HEAD=
  FM_VERIFY_ROLLUP_MERGEABLE=
  FM_VERIFY_ROLLUP_REVIEW=
  FM_VERIFY_ROLLUP_MEMBERS=
  FM_VERIFY_ROLLUP_REPORTED=
  FM_VERIFY_ROLLUP_CHECKS=
  FM_VERIFY_ROLLUP_UNSUCCESSFUL=
  FM_VERIFY_ROLLUP_FAILING=
  FM_VERIFY_ROLLUP_PENDING=
  FM_VERIFY_ROLLUP_INCONCLUSIVE=
  FM_VERIFY_ROLLUP_UNDECIDABLE=

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      label=*) label=${line#label=} ;;
      subject=*) subject=${line#subject=} ;;
      head=*) FM_VERIFY_ROLLUP_HEAD=${line#head=} ;;
      evidence_head=*) FM_VERIFY_ROLLUP_EVIDENCE_HEAD=${line#evidence_head=} ;;
      mergeable=*) FM_VERIFY_ROLLUP_MERGEABLE=${line#mergeable=} ;;
      review=*) FM_VERIFY_ROLLUP_REVIEW=${line#review=} ;;
      members=*) FM_VERIFY_ROLLUP_MEMBERS=${line#members=} ;;
      reported=*) FM_VERIFY_ROLLUP_REPORTED=${line#reported=} ;;
      checks=*) FM_VERIFY_ROLLUP_CHECKS=${line#checks=} ;;
      unsuccessful=*) FM_VERIFY_ROLLUP_UNSUCCESSFUL=${line#unsuccessful=} ;;
      failing=*) FM_VERIFY_ROLLUP_FAILING=${line#failing=} ;;
      pending=*) FM_VERIFY_ROLLUP_PENDING=${line#pending=} ;;
      inconclusive=*) FM_VERIFY_ROLLUP_INCONCLUSIVE=${line#inconclusive=} ;;
      undecidable=*) FM_VERIFY_ROLLUP_UNDECIDABLE=${line#undecidable=} ;;
    esac
  done <<EOF
$lines
EOF

  case "$label" in
    none|failing|pending|truncated|inconclusive|passing) ;;
    *) fm_verify_rollup_unreadable response_unreadable; return ;;
  esac
  case "$subject" in
    bound|mismatch|unbound) ;;
    *) fm_verify_rollup_unreadable response_unreadable; return ;;
  esac

  # THE SUBJECT COMES FIRST, before any count is validated. A count is a fact
  # about some head, and until this establishes WHICH head, an integrity failure
  # among the counts would be reported as a defect in evidence that was never
  # about the asked-about head in the first place.
  # The subject. Evidence about another commit is not this head's evidence and
  # is never counted toward it, whatever it says.
  if [ "$subject" = mismatch ]; then
    fm_verify_rollup_unreadable subject_mismatch
    return
  fi
  if [ "$subject" != bound ]; then
    # The authoritative source always binds its evidence to a named commit, so
    # an unbound response is the NARROWER source reaching a consumer that may not
    # use it. That is a wiring defect rather than a fact about the head, and it
    # gets its own reason so the two never read as one.
    fm_verify_rollup_unreadable source_unbound
    return
  fi
  if [ -n "$expected" ] && [ "$expected" != "$FM_VERIFY_ROLLUP_HEAD" ]; then
    fm_verify_rollup_unreadable subject_mismatch
    return
  fi

  # Each count is validated on its own. Concatenating them would let one empty
  # field hide behind the other's digits and reach the comparisons below as an
  # empty string, which compares as neither zero nor positive.
  for n in "$FM_VERIFY_ROLLUP_MEMBERS" "$FM_VERIFY_ROLLUP_CHECKS" \
    "$FM_VERIFY_ROLLUP_UNSUCCESSFUL" "$FM_VERIFY_ROLLUP_FAILING" \
    "$FM_VERIFY_ROLLUP_PENDING" "$FM_VERIFY_ROLLUP_INCONCLUSIVE" \
    "$FM_VERIFY_ROLLUP_UNDECIDABLE"; do
    if [ -z "$n" ] || [ -n "${n//[0-9]/}" ]; then
      fm_verify_rollup_unreadable response_unreadable
      return
    fi
  done
  # An absent totalCount is a real state - no rollup at all reports no count -
  # and is distinct from one that arrived unreadable.
  if [ -n "$FM_VERIFY_ROLLUP_REPORTED" ] \
    && [ -n "${FM_VERIFY_ROLLUP_REPORTED//[0-9]/}" ]; then
    fm_verify_rollup_unreadable response_unreadable
    return
  fi
  if [ -z "$FM_VERIFY_ROLLUP_REPORTED" ] && [ "$FM_VERIFY_ROLLUP_MEMBERS" -ne 0 ]; then
    # Anything that returned members owes a count of them.
    fm_verify_rollup_unreadable response_unreadable
    return
  fi
  # A reduction can only ever shrink the members, so more checks than members
  # means the two lines describe different sets and neither can be trusted.
  if [ "$FM_VERIFY_ROLLUP_CHECKS" -gt "$FM_VERIFY_ROLLUP_MEMBERS" ] \
    || [ "$FM_VERIFY_ROLLUP_UNSUCCESSFUL" -gt "$FM_VERIFY_ROLLUP_CHECKS" ]; then
    fm_verify_rollup_unreadable response_unreadable
    return
  fi
  # The four disjoint buckets must account for exactly the checks that are not
  # successes. A response that breaks that identity was not understood.
  if [ "$((FM_VERIFY_ROLLUP_FAILING + FM_VERIFY_ROLLUP_PENDING \
    + FM_VERIFY_ROLLUP_INCONCLUSIVE + FM_VERIFY_ROLLUP_UNDECIDABLE))" \
    -ne "$FM_VERIFY_ROLLUP_UNSUCCESSFUL" ]; then
    fm_verify_rollup_unreadable response_unreadable
    return
  fi

  FM_VERIFY_ROLLUP_LABEL=$label
  case "$label" in
    passing)
      FM_VERIFY_ROLLUP_REASON=verified
      return 0
      ;;
    failing)
      FM_VERIFY_ROLLUP_REASON=checks_failed
      return 1
      ;;
    pending) FM_VERIFY_ROLLUP_REASON=checks_pending ;;
    none) FM_VERIFY_ROLLUP_REASON=empty_set ;;
    inconclusive) FM_VERIFY_ROLLUP_REASON=no_verdict ;;
    truncated)
      # The three ways the extent or the ordering went unestablished are
      # reported apart, because they send a reader to different work.
      if [ -n "$FM_VERIFY_ROLLUP_REPORTED" ] \
        && [ "$FM_VERIFY_ROLLUP_REPORTED" -ne "$FM_VERIFY_ROLLUP_MEMBERS" ]; then
        FM_VERIFY_ROLLUP_REASON=members_unread
      elif [ "$FM_VERIFY_ROLLUP_MEMBERS" -ge "$FM_VERIFY_ROLLUP_PAGE_LIMIT" ]; then
        FM_VERIFY_ROLLUP_REASON=set_truncated
      else
        FM_VERIFY_ROLLUP_REASON=order_undecidable
      fi
      ;;
  esac
  return 2
}

# --- the three-valued observation type --------------------------------------

# fm_verify_parse <record>: read one bin/fm-verify.sh record and export its
# fields as FM_VERIFY_VERIFIER / FM_VERIFY_RESULT / FM_VERIFY_REASON /
# FM_VERIFY_EVIDENCE. Returns non-zero for anything it cannot parse, and leaves
# no partially-populated fields behind: an unparseable record is itself a
# could-not-observe, and a consumer that treated it as an empty PASS would be
# the very defect this file exists to prevent.
fm_verify_parse() {
  local record=$1 row rest verifier result reason evidence
  FM_VERIFY_VERIFIER=''
  FM_VERIFY_RESULT=''
  FM_VERIFY_REASON=''
  FM_VERIFY_EVIDENCE=''
  row=$(printf '%s\n' "$record" | sed -n 's/^  //p' | head -1)
  [ -n "$row" ] || return 1
  verifier=${row%%,*}
  rest=${row#*,}
  [ "$rest" != "$row" ] || return 1
  result=${rest%%,*}
  rest=${rest#*,}
  reason=${rest%%,*}
  rest=${rest#*,}
  evidence=$rest
  case "$result" in
    PASS|FAIL|NO_VERIFIER_RAN) ;;
    *) return 1 ;;
  esac
  [ -n "$verifier" ] && [ -n "$reason" ] || return 1
  # Published only once every field has been accepted: a record rejected on its
  # last field must leave nothing behind either, or a consumer reading the
  # globals without the status still sees a result extracted from a record this
  # function just refused.
  FM_VERIFY_VERIFIER=$verifier
  FM_VERIFY_RESULT=$result
  FM_VERIFY_REASON=$reason
  FM_VERIFY_EVIDENCE=$evidence
  return 0
}

# fm_verify_case <record> <on_pass> <on_fail> <on_unverified>: the only
# supported way to consume a result. Each handler is the name of a defined
# function and is called with no arguments; the parsed fields are available to
# it as the FM_VERIFY_* variables above.
#
# It refuses, with a stable token on stderr and status 3, when:
#   - fewer or more than three handlers are named (consumer exhaustiveness: a
#     consumer that branches on pass-versus-not-pass reintroduces the defect
#     against a perfectly correct producer);
#   - a named handler is not a defined function;
#   - the unverified handler is the same function as the pass or fail handler,
#     which is coercion written as a consumer. Use fm_verify_coerce for that,
#     where it is recorded.
# An unparseable record is reported the same way rather than dropped.
fm_verify_case() {
  local record=${1:-} on_pass=${2:-} on_fail=${3:-} on_unverified=${4:-} handler
  if [ "$#" -ne 4 ]; then
    printf 'fm-verify: consumer must handle all three results\n' >&2
    return 3
  fi
  for handler in "$on_pass" "$on_fail" "$on_unverified"; do
    if ! declare -F "$handler" >/dev/null 2>&1; then
      printf 'fm-verify: consumer must handle all three results\n' >&2
      return 3
    fi
  done
  if [ "$on_unverified" = "$on_pass" ] || [ "$on_unverified" = "$on_fail" ]; then
    printf 'fm-verify: NO_VERIFIER_RAN is not coercible; use fm_verify_coerce\n' >&2
    return 3
  fi
  if ! fm_verify_parse "$record"; then
    printf 'fm-verify: unreadable result record\n' >&2
    return 3
  fi
  case "$FM_VERIFY_RESULT" in
    PASS) "$on_pass" ;;
    FAIL) "$on_fail" ;;
    *) "$on_unverified" ;;
  esac
}

# fm_verify_coerce <record> <PASS|FAIL> <reason>: the one sanctioned narrowing
# of NO_VERIFIER_RAN, for the case where a caller genuinely decides to proceed
# without the observation. It prints the coerced result on stdout and writes the
# decision to stderr always, plus FM_VERIFY_COERCION_LOG or
# $FM_HOME/state/verify-coercions.log when either is writable. A coercion with
# no reason, or of an already-observed result, is refused: only the missing
# observation is a decision anyone gets to make.
fm_verify_coerce() {
  local record=${1:-} target=${2:-} reason=${3:-} log=
  if [ "$#" -ne 3 ] || [ -z "$reason" ]; then
    printf 'fm-verify: coercion needs a target and a reason\n' >&2
    return 3
  fi
  case "$target" in
    PASS|FAIL) ;;
    *)
      printf 'fm-verify: coercion target must be PASS or FAIL\n' >&2
      return 3
      ;;
  esac
  if ! fm_verify_parse "$record"; then
    printf 'fm-verify: unreadable result record\n' >&2
    return 3
  fi
  if [ "$FM_VERIFY_RESULT" != NO_VERIFIER_RAN ]; then
    printf 'fm-verify: only NO_VERIFIER_RAN is coercible\n' >&2
    return 3
  fi
  printf 'fm-verify: COERCED %s -> %s (%s): %s reason=%s evidence=%s\n' \
    NO_VERIFIER_RAN "$target" "$reason" "$FM_VERIFY_VERIFIER" \
    "$FM_VERIFY_REASON" "$FM_VERIFY_EVIDENCE" >&2
  if [ -n "${FM_VERIFY_COERCION_LOG:-}" ]; then
    log=$FM_VERIFY_COERCION_LOG
  elif [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] && [ -w "$FM_HOME/state" ]; then
    log=$FM_HOME/state/verify-coercions.log
  fi
  if [ -n "$log" ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$FM_VERIFY_VERIFIER" "$target" "$FM_VERIFY_REASON" \
      "$FM_VERIFY_EVIDENCE" "$reason" >>"$log" 2>/dev/null || true
  fi
  FM_VERIFY_RESULT=$target
  printf '%s\n' "$target"
}
