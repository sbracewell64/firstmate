#!/usr/bin/env bash
# Merge a task's PR after re-verifying the pull request's current head, then
# record pr= and any available pr_head= through bin/fm-pr-check.sh, so teardown
# can verify landed work after squash merges. The full canonical GitHub PR URL
# is parsed by bin/fm-pr-lib.sh and the derived owner/repository and PR number
# are passed to gh-axi as separate arguments.
#
# Verification re-reads the pull request rather than trusting any recorded
# value, because a PR can go red between an earlier check and the merge and
# state/<id>.meta may carry a stale pr_head=. An early read refuses without
# recording the PR or arming its poll, then a final authoritative read runs after
# fm-pr-check.sh and immediately before the verification metadata write and
# merge. Each read takes the head, mergeability, review decision, and check
# results from one GraphQL response, so every state-based refusal names the exact
# head it evaluated once GitHub has supplied a readable head.
#
# That query is written here rather than taken from `gh pr view --json
# statusCheckRollup`, because that field flattens the rollup into members that
# carry no commit of their own. The rollup is the one GitHub attached to the
# pull request's latest commit, but nothing in that response says which commit
# that was, so evidence describing a superseded head reads exactly like evidence
# describing the head being merged. This asks for that commit's own oid in the
# same snapshot as headRefOid and refuses unless the two agree, and asks for the
# rollup's totalCount so members GitHub reported but did not return are refused
# as unread rather than counted as absent. GitHub serves at most 100 members in
# one page, which is the connection's own limit and not a choice made here, so a
# head carrying more than that is refused as unread rather than judged on the
# part that happened to arrive.
#
# A head accumulates every execution ever run against it, not only the current
# one, so the members are reduced to one verdict per check before anything is
# counted. Two members are two attempts at one check when they carry the same
# owning workflow and the same name, and the attempt with the newest run ID
# speaks for that check. A member GitHub reports with no name is never an
# attempt at anything, because nothing identifies what it would supersede, so
# each of those counts on its own. Without that reduction a re-triggered check
# leaves its earlier run attached to the head forever, and that head can never
# be merged again however often the check subsequently passes; the only escape is a new
# head, which for the attestation check needs a fresh attestation, so the
# pattern repeats. Reduction never excuses a current verdict: a failing latest
# attempt still refuses, and where attempts tie for latest the worst decides.
# The merge is refused when:
#   * the check results GitHub returned belong to a commit other than the head
#     being merged, or it returned fewer members than it reported - neither is
#     evidence about this head, and what was not read is never read as green;
#   * no check runs exist on that head - an empty rollup is never read as green,
#     which is the whole point of this guard: a cross-repo fork PR held at
#     action_required dispatches zero workflows and reports zero failures. The
#     refusal names why the set is empty, separating a head with no CI
#     configured from one whose workflows are held awaiting approval;
#   * any check's current attempt is not SUCCESS - a queued, in-progress,
#     skipped, neutral, cancelled, or failed run all refuse, so the guard fails
#     closed on anything that is not an observed pass. Checks whose current
#     attempt returned an adverse verdict and checks whose current attempt
#     returned no verdict are counted and reported separately, so a head nothing
#     examined is never described as a head something rejected;
#   * the pull request is not MERGEABLE - CONFLICTING and a not-yet-computed
#     UNKNOWN both refuse;
#   * a review requests changes.
#
# --allow-unverified <check-name> is the captain's explicit override. It is never
# a default and never inferred from the environment, and it waives exactly the
# one named check and nothing else. Verification still runs: every refusal above
# still refuses, so an empty rollup, any other failing check run, any other check
# run that reported no result, an unmergeable state, and a blocking review each
# still stop the merge. A head whose only check run is the waived one refuses
# too, because waiving it leaves nothing that examined the head at all.
#
# A name that matches no check run on the head is refused rather than accepted,
# so a typo cannot silently widen the waiver back into a total override, and a
# bare --allow-unverified carrying no name is refused for the same reason: an
# override that cannot say what it waived is the defect this argument exists to
# remove. A name matching more than one check on the head is refused too: two
# workflows can define the same job name, and one such name would waive that
# many independent verdicts while the record could still say only the name.
# Repeated executions of one check are not several verdicts and do not trip
# that refusal, because the reduction above has already resolved them to the
# one attempt that speaks for the check. The waiver covers exactly one check or
# none.
# The name must be a single line with no quote or backslash character, because
# it is embedded in the forge query as a string literal and repeated in
# refusals.
#
# An overridden merge records merge_verification=override and
# merge_waived_check=<name> in the task's meta, so the record says which check
# was waived rather than only that something was. A verified merge records
# merge_verification=verified and merge_verified_head=<sha>; an overridden merge
# records no verified head, because one check on it was never verified. Absence
# of all of these keys means unknown, never verified. They are written before pr=
# so the metadata identity contract in bin/fm-pr-lib.sh still parses. The flag is
# recognised only before the optional -- separator; after it, it is forwarded to
# gh-axi, which rejects it.
#
# The final verification is not atomically bound to the merge. It narrows the
# remaining race window to the verification metadata write, but a head can still
# change before the merge. Closing that race requires a server-side head
# precondition under decision
# pipeline-reports-green-on-absent-ci-decision-merge-atomic-binding. The real
# `gh pr merge` supports `--match-head-commit SHA`, but gh-axi constructs its gh
# arguments from a fixed allowlist of the method, --auto, --delete-branch, --body,
# and --subject and silently drops other flags. Adopting the precondition later
# therefore requires changing the single gh-axi invocation at the end.
#
# A task released before its pull request lands keeps a durable landing record
# instead of a meta, and this path lands it through that record. A task released
# before landing records existed keeps neither, so its record is rebuilt from a
# forge read of the request. An existing landing record must be valid and name
# the requested URL before any forge read or merge. Either way the request must
# still be open at its forge, and a request that resolves to nothing is refused.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [--allow-unverified <check-name>] [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2

# The waived check name is embedded in the forge query as a jq string literal and
# repeated in refusals, so a quote, a backslash, or a control character is
# refused rather than escaped. A name beginning with a dash is refused because
# the flag's argument is the name itself: a following flag means the name was
# omitted, and a nameless override is the defect this argument removes.
waived_check_name_valid() {
  local name=$1
  [ -n "$name" ] || return 1
  case "$name" in
    -*) return 1 ;;
    *'"'*) return 1 ;;
    *\\*) return 1 ;;
  esac
  [ "$name" = "${name//[[:cntrl:]]/}" ]
}

WAIVED_CHECK=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-unverified)
      shift
      if [ "$#" -eq 0 ]; then
        echo "error: --allow-unverified requires the name of the one check it waives; a nameless override is refused" >&2
        exit 2
      fi
      if ! waived_check_name_valid "$1"; then
        echo "error: --allow-unverified requires one check name: a single line with no quote or backslash character, not starting with a dash" >&2
        exit 2
      fi
      WAIVED_CHECK=$1
      shift
      ;;
    --allow-unverified=*)
      echo "error: --allow-unverified requires the name of the one check it waives as a separate argument" >&2
      exit 2
      ;;
    --) shift; break ;;
    *) break ;;
  esac
done

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
# Landing identity comes from whichever durable record the task still has, and
# from the pull request itself when it has none. A live task keeps its meta and
# takes the unchanged path below. A released task keeps only the landing record
# bin/fm-teardown.sh left behind, and a task released before landing records
# existed keeps neither: its pull request is then the authority for its own
# identity and the record is rebuilt from a forge read, never from the caller.
LANDING="$STATE/$ID.landing"
REBUILD=0
if ! RECORD=$(fm_pr_identity_record_path "$STATE" "$ID"); then
  if [ -e "$LANDING" ] || [ -L "$LANDING" ]; then
    echo "error: task landing record is invalid" >&2
    exit 1
  fi
  RECORD=$LANDING
  REBUILD=1
fi

# One read of the live pull request, so the head reported in a refusal is the
# same head the checks, mergeability, and review decision were read from, and
# so the commit its check results are attached to is read from that same
# snapshot rather than inferred. The $-prefixed names below are GraphQL
# variables, not shell expansions.
# shellcheck disable=SC2016
PR_VERIFY_GRAPHQL='query($owner:String!,$repo:String!,$number:Int!){
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
# A CheckRun carries .conclusion (empty while queued or running); a legacy
# StatusContext carries .state instead. Neither is treated as a pass unless it
# says SUCCESS.
#
# The checks are counted in three disjoint buckets, not two, because "ran and
# reported a failure" and "never produced a result" are different facts about a
# head and collapsing them loses the one this guard exists to report. A run that
# failed, errored, timed out, or failed to start returned an adverse verdict; a
# run that is queued, in progress, skipped, neutral, cancelled, stale, or held
# at action_required returned no verdict at all. Both refuse, and each says so
# in its own words. PR_VERIFY_FAILING is the whole adverse set, so anything
# absent from it that is not SUCCESS counts as unrun rather than as a failure.
PR_VERIFY_FAILING='["FAILURE","ERROR","TIMED_OUT","STARTUP_FAILURE"]'

# The reduction from executions to checks, shared by every line read back below.
# Each member is keyed by the check it is an attempt at - its owning workflow
# and its name together, since two workflows may define one job name - and an
# unnamed member is keyed by its own position so it can never be taken for an
# attempt at another. Check runs are ordered by their monotonic database ID,
# with their timestamp as a tie-breaker, while legacy statuses continue to use
# their creation time. Where attempts tie for latest the worst verdict decides,
# so a tie can never manufacture a pass.
#
# The jq bindings below ($pr, $commit, $adverse, $checks and the rest) are jq's
# own, not shell variables; only PR_VERIFY_FAILING is expanded by the shell.
# shellcheck disable=SC2016
PR_VERIFY_REDUCE='.data.repository.pullRequest as $pr
| ($pr.commits.nodes[0].commit // {}) as $commit
| ($commit.statusCheckRollup.contexts // {}) as $contexts
| ($contexts.nodes // []) as $members
| ('"$PR_VERIFY_FAILING"') as $adverse
| ($members | to_entries | map(
    (.value.name // .value.context // "") as $name
    | {name: $name,
       check: (if ($name | length) == 0 then ["unnamed", (.key | tostring)]
               elif .value.__typename == "CheckRun"
               then ["run", (.value.checkSuite.workflowRun.workflow.name // ""), $name]
               else ["status", $name] end),
       order: (if .value.__typename == "CheckRun"
               then .value.databaseId
               else .value.createdAt end),
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
                   elif ($current | any(.verdict != "SUCCESS")) then "UNRUN"
                   else "SUCCESS" end)} end)) as $checks
| '

# shellcheck disable=SC2016
PR_VERIFY_QUERY=$PR_VERIFY_REDUCE'"head=\($pr.headRefOid // "")",
"mergeable=\($pr.mergeable // "")",
"review=\($pr.reviewDecision // "")",
"rollup_head=\($commit.oid // "")",
"members=\($members | length)",
"reported=\($contexts.totalCount // "")",
"checks=\($checks | length)",
"unsuccessful=\($checks | map(select(.verdict != "SUCCESS")) | length)",
"failing=\($checks | map(select(.verdict == "FAILING")) | length)",
"unrun=\($checks | map(select(.verdict == "UNRUN")) | length)",
"undecidable=\($checks | map(select(.verdict == "UNDECIDABLE")) | length)"'

# Three further lines, asked for only when a check is waived, so a merge with no
# override sends byte-identical query text and reads back the same lines it
# always did. They count the checks carrying the waived name and how those
# checks break down, which is exactly what has to be subtracted from the totals
# above. They read the same reduced set, so a waived check that was re-triggered
# is one check here too.
if [ -n "$WAIVED_CHECK" ]; then
  # shellcheck disable=SC2016
  PR_VERIFY_WAIVED_SELECT='$checks | map(select(.name == "'"$WAIVED_CHECK"'"))'
  # shellcheck disable=SC2016
  PR_VERIFY_QUERY=$PR_VERIFY_QUERY',
"waived=\(('"$PR_VERIFY_WAIVED_SELECT"') | length)",
"waived_failing=\(('"$PR_VERIFY_WAIVED_SELECT"') | map(select(.verdict == "FAILING")) | length)",
"waived_unrun=\(('"$PR_VERIFY_WAIVED_SELECT"') | map(select(.verdict == "UNRUN")) | length)"'
fi

VERIFIED_HEAD=

# An empty rollup has more than one cause, and the two common ones need
# different work from the captain: a repository with no CI configured for this
# head, and a cross-repo fork pull request whose workflows exist but are held at
# action_required until a maintainer approves them. GitHub reports neither as a
# check run, so both arrive here as the same empty list, but the check-suite
# read below separates them. This only enriches an already-decided refusal: it
# runs on the refusal path alone, reports nothing when it cannot read the
# suites, and can never turn a refusal into a merge.
empty_rollup_evidence() {
  local head=$1 counts total held extra
  command -v gh >/dev/null 2>&1 || return 0
  # fm-retrieval-audit: no-negative - enriches an already-decided refusal only and reports nothing when it cannot read the suites, so it can never turn a refusal into a merge
  counts=$(gh api "repos/$PR_OWNER/$PR_REPO/commits/$head/check-suites" \
    -q '"\(.total_count // 0) \([.check_suites[]? | select(((.conclusion // "") | ascii_downcase) == "action_required")] | length)"' \
    2>/dev/null) || return 0
  # Exactly two whole numbers, or this response was not the one asked for and
  # the refusal stands with no added detail rather than an invented one.
  read -r total held extra <<< "$counts" || return 0
  [ -z "$extra" ] || return 0
  [ -n "$total" ] && [ -z "${total//[0-9]/}" ] || return 0
  [ -n "$held" ] && [ -z "${held//[0-9]/}" ] || return 0
  if [ "$held" -gt 0 ]; then
    printf ' (%s check suite(s) on it are held at action_required, so its workflows are waiting on a maintainer to approve them and will not run on their own)' \
      "$held"
  elif [ "$total" -eq 0 ]; then
    printf ' (no check suite exists for it either, so no CI is configured to run on this head)'
  fi
  return 0
}

# One wording for every way the rollup came back unreadable, because they are
# one fact about the head: nothing here can be resolved either way.
refuse_unreadable_rollup() {
  printf 'error: refusing to merge head %s: the check rollup could not be read from GitHub\n' \
    "$1" >&2
}

verify_current_head() {
  local output line joined remaining eff_failing eff_unrun
  local head='' mergeable='' review='' checks='' unsuccessful='' failing='' unrun='' undecidable=''
  local rollup_head='' members='' reported=''
  local waived='' waived_failing='' waived_unrun=''
  local -a reasons=()

  command -v gh >/dev/null 2>&1 || {
    echo "error: refusing to merge: the pull request could not be verified because gh is not on PATH" >&2
    return 1
  }
  # fm-retrieval-audit: complete-source - refuses when the rollup returned fewer members than its own totalCount reported, so what was not read is never read as green
  output=$(gh api graphql -f query="$PR_VERIFY_GRAPHQL" \
    -f owner="$PR_OWNER" -f repo="$PR_REPO" -F number="$PR_NUMBER" \
    -q "$PR_VERIFY_QUERY" 2>/dev/null) || {
    echo "error: refusing to merge: the pull request state could not be read from GitHub" >&2
    return 1
  }

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      head=*) head=${line#head=} ;;
      mergeable=*) mergeable=${line#mergeable=} ;;
      review=*) review=${line#review=} ;;
      rollup_head=*) rollup_head=${line#rollup_head=} ;;
      members=*) members=${line#members=} ;;
      reported=*) reported=${line#reported=} ;;
      checks=*) checks=${line#checks=} ;;
      unsuccessful=*) unsuccessful=${line#unsuccessful=} ;;
      failing=*) failing=${line#failing=} ;;
      unrun=*) unrun=${line#unrun=} ;;
      undecidable=*) undecidable=${line#undecidable=} ;;
      waived=*) waived=${line#waived=} ;;
      waived_failing=*) waived_failing=${line#waived_failing=} ;;
      waived_unrun=*) waived_unrun=${line#waived_unrun=} ;;
    esac
  done <<< "$output"

  fm_pr_head_valid "$head" || {
    echo "error: refusing to merge: the pull request head commit could not be read from GitHub" >&2
    return 1
  }
  # GitHub attaches check results to a commit, and a pull request's latest
  # commit moves under a force-push or a queued update, so the commit the
  # results came from is compared against the head being merged instead of
  # assumed to be it. Results belonging to another commit describe a superseded
  # head: they are not this head's evidence and are never counted toward it.
  fm_pr_head_valid "$rollup_head" || {
    refuse_unreadable_rollup "$head"
    return 1
  }
  if [ "$rollup_head" != "$head" ]; then
    printf 'error: refusing to merge head %s: GitHub returned check results for commit %s, so nothing here examined the head being merged\n' \
      "$head" "$rollup_head" >&2
    return 1
  fi
  # A member GitHub reported but did not return is unread rather than absent,
  # and an unread member could be the one that failed.
  if [ -z "$members" ] || [ -n "${members//[0-9]/}" ]; then
    refuse_unreadable_rollup "$head"
    return 1
  fi
  if [ -z "$reported" ]; then
    # No rollup at all reports no count; anything else owes one.
    if [ "$members" -ne 0 ]; then
      refuse_unreadable_rollup "$head"
      return 1
    fi
  elif [ -n "${reported//[0-9]/}" ]; then
    refuse_unreadable_rollup "$head"
    return 1
  elif [ "$reported" -ne "$members" ]; then
    printf 'error: refusing to merge head %s: GitHub reported %s check results for it but returned %s, so the rest could not be read\n' \
      "$head" "$reported" "$members" >&2
    return 1
  fi
  # Each count is validated on its own. Concatenating them would let one empty
  # field hide behind the other's digits and reach the comparisons below as an
  # empty string, which compares as neither zero nor positive and would merge.
  if [ -z "$checks" ] || [ -n "${checks//[0-9]/}" ] \
    || [ -z "$unsuccessful" ] || [ -n "${unsuccessful//[0-9]/}" ] \
    || [ -z "$failing" ] || [ -n "${failing//[0-9]/}" ] \
    || [ -z "$unrun" ] || [ -n "${unrun//[0-9]/}" ] \
    || [ -z "$undecidable" ] || [ -n "${undecidable//[0-9]/}" ]; then
    refuse_unreadable_rollup "$head"
    return 1
  fi
  # A reduction can only ever shrink the members, so more checks than members
  # means the two lines describe different sets and neither can be trusted.
  if [ "$checks" -gt "$members" ] || [ "$unsuccessful" -gt "$checks" ] \
    || [ "$undecidable" -gt "$checks" ]; then
    refuse_unreadable_rollup "$head"
    return 1
  fi
  # The two disjoint buckets must account for exactly the members that are not
  # successes. A response that breaks that identity was not understood, and an
  # unreadable rollup is reported as unreadable rather than resolved either way.
  if [ "$((failing + unrun + undecidable))" -ne "$unsuccessful" ]; then
    refuse_unreadable_rollup "$head"
    return 1
  fi
  # The waived counts are subtracted from the totals below, so a count that is
  # unreadable or cannot be a subset of what it is subtracted from would silently
  # shrink a refusal. Each is validated on its own and against its own total,
  # exactly as the three above are, and an unreadable answer stays unreadable.
  if [ -n "$WAIVED_CHECK" ]; then
    if [ -z "$waived" ] || [ -n "${waived//[0-9]/}" ] \
      || [ -z "$waived_failing" ] || [ -n "${waived_failing//[0-9]/}" ] \
      || [ -z "$waived_unrun" ] || [ -n "${waived_unrun//[0-9]/}" ] \
      || [ "$waived" -gt "$checks" ] \
      || [ "$((waived_failing + waived_unrun))" -gt "$waived" ] \
      || [ "$waived_failing" -gt "$failing" ] || [ "$waived_unrun" -gt "$unrun" ]; then
      refuse_unreadable_rollup "$head"
      return 1
    fi
  fi

  [ "$mergeable" = MERGEABLE ] \
    || reasons+=("the pull request is not mergeable (mergeable=${mergeable:-unreported})")
  [ "$review" != CHANGES_REQUESTED ] || reasons+=("a review requests changes")
  # Zero check runs and all-successful check runs both report zero failures, so
  # the empty rollup is refused on its own count and never folded into the
  # counts below. A non-empty rollup reports its failed and its unrun members
  # separately, so "this was examined and found broken" never reaches the
  # captain wearing the words of "this was never examined", or the reverse.
  # An empty rollup is decided first and identically either way, because there is
  # nothing on the head for a waiver to name. Everything the waiver does not name
  # is then judged by exactly the counts above, less the waived member's own.
  if [ "$checks" -eq 0 ]; then
    reasons+=("no check runs exist on this head$(empty_rollup_evidence "$head")")
  else
    [ "$undecidable" -eq 0 ] \
      || reasons+=("GitHub omitted the ordering value for $undecidable check run group(s), so the current attempt could not be determined")
  fi
  if [ "$checks" -ne 0 ] && [ -n "$WAIVED_CHECK" ]; then
    remaining=$((checks - waived))
    if [ "$waived" -eq 0 ]; then
      reasons+=("no check run named \"$WAIVED_CHECK\" exists on this head, so the override names nothing it could waive")
    elif [ "$waived" -gt 1 ]; then
      reasons+=("$waived check runs on this head are named \"$WAIVED_CHECK\", so the override does not name one check and would waive $waived separate verdicts")
    elif [ "$remaining" -eq 0 ]; then
      reasons+=("waiving check \"$WAIVED_CHECK\" leaves no other check run on this head, so nothing examined it")
    else
      eff_failing=$((failing - waived_failing))
      eff_unrun=$((unrun - waived_unrun))
      [ "$eff_failing" -eq 0 ] \
        || reasons+=("$eff_failing of the $remaining check runs other than the waived \"$WAIVED_CHECK\" failed")
      [ "$eff_unrun" -eq 0 ] \
        || reasons+=("$eff_unrun of the $remaining check runs other than the waived \"$WAIVED_CHECK\" reported no result (queued, in progress, skipped, neutral, cancelled, or held for approval)")
    fi
  elif [ "$checks" -ne 0 ]; then
    [ "$failing" -eq 0 ] \
      || reasons+=("$failing of $checks check runs failed")
    [ "$unrun" -eq 0 ] \
      || reasons+=("$unrun of $checks check runs reported no result (queued, in progress, skipped, neutral, cancelled, or held for approval)")
  fi

  if [ "${#reasons[@]}" -gt 0 ]; then
    joined=$(printf '%s; ' "${reasons[@]}")
    printf 'error: refusing to merge head %s: %s\n' "$head" "${joined%; }" >&2
    return 1
  fi
  VERIFIED_HEAD=$head
}

MERGE_META_TMP=
merge_meta_cleanup() {
  [ -z "$MERGE_META_TMP" ] || rm -f -- "$MERGE_META_TMP"
  MERGE_META_TMP=
}
trap merge_meta_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Record how this merge was authorised. The three keys are emitted before any
# pr=/pr_head= lines so fm_pr_metadata_identity_parse, which refuses any unknown
# key after pr=, still accepts the file at every instant.
record_merge_verification() {
  local status=$1 head=$2 waived=$3 line state_device meta_device
  state_device=$(fm_pr_file_device "$STATE") || return 1
  meta_device=$(fm_pr_file_device "$META") || return 1
  [ "$meta_device" = "$state_device" ] || return 1
  MERGE_META_TMP=$(mktemp "$STATE/.fm-pr-merge-meta.XXXXXX") || return 1
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        merge_verification=*|merge_verified_head=*|merge_waived_check=*|pr=*|pr_head=*) ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$META"
    printf 'merge_verification=%s\n' "$status"
    [ -z "$head" ] || printf 'merge_verified_head=%s\n' "$head"
    [ -z "$waived" ] || printf 'merge_waived_check=%s\n' "$waived"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        pr=*|pr_head=*) printf '%s\n' "$line" ;;
      esac
    done < "$META"
  } > "$MERGE_META_TMP" || return 1
  chmod 0600 "$MERGE_META_TMP" || return 1
  fm_pr_private_file_valid "$MERGE_META_TMP" 600 "$state_device" || return 1
  fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || return 1
  mv -f -- "$MERGE_META_TMP" "$META" || return 1
  MERGE_META_TMP=
}

# This fork carries a released task's landing record as well as a live task's
# meta, so the record is resolved in three ordered stages rather than one. Its
# own refusals - a torn-down meta, an invalid landing record, a record naming
# another request - come first and cost no forge read, exactly as before.
# Verification runs next, so nothing is recorded and no poll is armed for a head
# it refuses. Only then does the task's identity get written.
LIVE_TASK=0
if [ "$RECORD" != "$LANDING" ]; then
  if [ ! -f "$RECORD" ] || [ -L "$RECORD" ]; then
    echo "error: task metadata is unavailable" >&2
    exit 1
  fi
  # Recording and arming are deferred until after verification below, so a head
  # the guard refuses leaves the task with no pr= and no armed poll.
  LIVE_TASK=1
else
  if [ "$REBUILD" = 0 ]; then
    fm_pr_metadata_identity_parse "$RECORD" || {
      echo "error: task landing record is invalid" >&2
      exit 1
    }
    RECORD_URL=$FM_PR_META_URL
    if [ "$RECORD_URL" != "$URL" ]; then
      echo "error: task landing record names $RECORD_URL, but $URL was requested" >&2
      exit 1
    fi
  fi
  # A released task has no worktree, no worker, and nothing left to tear down,
  # and the merge below is synchronous, so no merge poll is armed for it. The
  # forge decides here instead: the request must still be open, and the landing
  # record is then written from what the forge reported rather than from a stale
  # local value or anything the caller asserted.
  RECORD_PROJECT=
  [ "$REBUILD" = 1 ] \
    || RECORD_PROJECT=$(grep '^project=' "$RECORD" | tail -1 | cut -d= -f2- || true)
  if ! fm_pr_forge_view "$URL"; then
    if [ "$REBUILD" = 1 ]; then
      echo "error: task metadata is unavailable" >&2
      echo "No record for task $ID, and $URL could not be resolved at its forge." >&2
    else
      echo "error: $URL could not be resolved at its forge" >&2
    fi
    exit 1
  fi
  if [ "$FM_PR_FORGE_STATE" != open ]; then
    if [ "$REBUILD" = 1 ]; then
      echo "error: task metadata is unavailable" >&2
      echo "No record for task $ID, and $URL is $FM_PR_FORGE_STATE at its forge rather than an open pull request." >&2
    else
      echo "error: $URL is $FM_PR_FORGE_STATE at its forge rather than an open pull request" >&2
    fi
    exit 1
  fi
  fm_pr_landing_record_write "$STATE" "$ID" "$URL" "$FM_PR_FORGE_HEAD" "$RECORD_PROJECT" || {
    echo "error: task landing record could not be written" >&2
    exit 1
  }
  [ "$REBUILD" = 0 ] || printf 'rebuilt: state/%s.landing from %s\n' "$ID" "$URL"
fi

# The override does not skip this. It waives one named check inside the same
# verification, so a head that is red for any other reason still leaves the task
# with no pr= and no armed poll.
verify_current_head || exit 1

[ "$LIVE_TASK" = 0 ] || "$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
META=$RECORD
grep -qxF "pr=$URL" "$RECORD" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

VERIFIED_HEAD=
verify_current_head || exit 1
if [ -n "$WAIVED_CHECK" ]; then
  # One check on this head was waived rather than verified, so the merge records
  # the waiver and no verified head: the head as a whole was never verified.
  MERGE_VERIFICATION=override
  VERIFIED_HEAD=
else
  MERGE_VERIFICATION=verified
fi

record_merge_verification "$MERGE_VERIFICATION" "$VERIFIED_HEAD" "$WAIVED_CHECK" || {
  echo "error: merge verification metadata could not be recorded" >&2
  exit 1
}
grep -qxF "merge_verification=$MERGE_VERIFICATION" "$META" || {
  echo "error: merge verification metadata could not be recorded" >&2
  exit 1
}
[ -z "$WAIVED_CHECK" ] || grep -qxF "merge_waived_check=$WAIVED_CHECK" "$META" || {
  echo "error: merge verification metadata could not be recorded" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"  # fm-retrieval-audit: write - the merge itself, which is an action and has no observation type

# The landing record exists only so a released task's pull request can still be
# landed here, so it is spent once that merge succeeds. It is retained while a
# merge poll is still armed against it, because the poll's registration binds to
# it and the watcher would otherwise reject an authentic check.
if [ "$RECORD" = "$LANDING" ] && [ -f "$LANDING" ] && [ ! -L "$LANDING" ] \
  && [ ! -e "$STATE/$ID.check.sh" ] && [ ! -L "$STATE/$ID.check.sh" ] \
  && [ ! -e "$STATE/$ID.pr-poll" ] && [ ! -L "$STATE/$ID.pr-poll" ]; then
  rm -f -- "$LANDING" || true
fi
