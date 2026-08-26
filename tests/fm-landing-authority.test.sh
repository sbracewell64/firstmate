#!/usr/bin/env bash
# tests/fm-landing-authority.test.sh - a landing decision is COMPILED FROM TYPED
# AUTHORITY SOURCES, never from whether a captain utterance exists.
#
# Subject: the landing-authority compiler in bin/fm-landing-seam-lib.sh, the
# effective-posture resolution in bin/fm-autonomy-lib.sh, and both of their
# wirings - bin/fm-decision-surface.sh check landing-authority, bin/fm-pr-merge.sh,
# bin/fm-merge-local.sh, and the disposition fold bin/fm-wake-drain.sh prints.
#
# WHY THIS SUITE EXISTS.
#
# On 2026-08-26 a pull request whose landing merits an outside reviewer had
# already approved was held, and the only thing holding it was that no chat
# message contained a merge word. Nothing in the fleet's structured state said
# the captain owed a ruling; the captain's own standing posture said the
# opposite. The projection was a property of the TRANSPORT the instruction
# arrived on, and transport is not an authority source.
#
# So the compiler this suite drives has NO input for an utterance. It reads the
# task's own commission record, the captain's standing posture at its canonical
# owner, the typed disposition of every open decision on the task, and the
# ruling that governs the candidate. `CAPTAIN_REQUIRED` is reachable only from a
# decision the fleet has TYPED as the captain's - and reachable from nothing
# else, which is what the absence cases below are for.
#
# WHAT EACH RED IS ATTRIBUTABLE TO. Every refusal case is one perturbation away
# from a case that lands, and the paired landing case runs the same fixture
# unperturbed. A gate that refuses everything produces the same reds otherwise.
#
# THE ACT IS COUNTED, NEVER ASSUMED. A merge is observed by counting the merge
# invocations the fake forge recorded and by comparing the local branch's own
# commit, because "no bad merge happened" is also what a wholly broken gate
# produces.
#
# Matrix:
#   (1) an ordinary reversible landing with an approving ruling, current gates,
#       a standing posture, and NO captain utterance anywhere is eligible, and
#       the pull request actually lands
#   (2) the same answer comes back from a fresh process that inherited no
#       environment and read only durable state
#   (3) an approval bound to another head refuses
#   (4) missing check evidence refuses, and never reads as eligible
#   (5) a decision the fleet typed as the captain's makes the landing
#       CAPTAIN_REQUIRED, and the merge gate refuses
#   (6) a standing posture cannot waive a real engineering gate
#   (7) the one-use landing authorization is minted and consumed through its own
#       owner, with no captain utterance in the fixture at all
#   (8) a local-only landing is delegated on the same terms, and the compile
#       reads the records of the home it was addressed to
#   (9) an unreadable decision record is could-not-observe, never eligible
#  (10) the effective posture follows the canonical registry, not the stale
#       value recorded on a live task
#  (11) the canonical owner is re-read on every resolution, so the posture
#       survives a restart and a registry edit takes effect without one
#  (12) registry presence controls whether canonical posture or snapshot wins
#  (13) every disposition in the closed vocabulary is classified, and an
#       unknown one is named unclassified rather than read as permission
#  (14) an absent or declining governing ruling stops in the compile, before
#       any authorization is minted
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The autonomy members, so no fixture below spells a posture the fleet does not
# write. bin/fm-autonomy-lib.sh is pure at source time.
# shellcheck source=bin/fm-autonomy-lib.sh
. "$ROOT/bin/fm-autonomy-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

FM_TEST_IDENTITY_CONTRACT=1

SURFACE="$ROOT/bin/fm-decision-surface.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-landing-authority) || exit 1

TASK_ID=planning-1
PROJECT_NAME=planning-repo
PR_URL='https://github.com/owner/demo/pull/29'
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REQUEST_ID=fm-ob-0123456789ab

SURFACE_OUT=
SURFACE_RC=0

# --- fixture -----------------------------------------------------------------
#
# One operational home per case. Correlation records are written as DATA in the
# schema bin/fm-outbound-artifact-lib.sh publishes rather than by calling that
# owner's emitter, for the same reason tests/fm-landing-seam.test.sh does it:
# this suite proves the authority compile, and reaching into the emitter would
# couple the two exactly where they must stay separable.
#
# NOTHING IN ANY FIXTURE IS A CAPTAIN UTTERANCE. There is no chat, no transcript,
# no approval flag, and no argument that stands for one. That is the claim: the
# eligible cases below reach eligible with nothing of the kind available.
new_home() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" \
    || return 1
  touch "$dir/home/state/.last-watcher-beat" || return 1
  printf '%s\n' "$dir"
}

# The canonical owner of the captain's standing posture: data/projects.md, read
# by bin/fm-project-mode.sh on every resolution.
register_project() {  # <dir> [<annotation>]
  local dir=$1 annotation=${2:-no-mistakes +yolo}
  printf -- '- %s [%s] - a planning repository (added 2026-08-26)\n' \
    "$PROJECT_NAME" "$annotation" > "$dir/home/data/projects.md"
}

configure_venue() {  # <dir>
  printf '%s\n' '{ "repo": "owner/control", "issue": 36 }' \
    > "$1/home/config/sol-control.json"
}

# <dir> <state> <verdict> <head> [<item>]
write_correlation() {
  local dir=$1 state=$2 verdict=$3 head=$4 item=${5:-$TASK_ID}
  mkdir -p "$dir/home/data/outbound-artifacts" || return 1
  jq -n --arg rid "$REQUEST_ID" --arg state "$state" --arg verdict "$verdict" \
    --arg head "$head" --arg item "$item" --arg pr "$PR_URL" \
    '{schema:"fm-outbound-artifact.v1",
      request_id:$rid,
      channel:"sol-control",
      identity:{gate:"EXACT_HEAD_BROWSER_REVIEW_REQUIRED",project:"planning-repo",
                repo:"owner/control",item:$item,pr:$pr,head:$head,
                head_source:"pull-request"},
      venue:"owner/control#36",
      state:$state,
      comment_id:"5424276700",
      attempts:1,
      created:"2026-08-26T00:00:00Z",
      updated:"2026-08-26T00:00:00Z",
      ruling:(if $verdict == "" then null
              else {comment_id:"5424276706",verdict:$verdict,
                    observed:"2026-08-26T01:00:00Z"} end),
      resumed:null,
      disposition:null,
      superseded_by:null}' \
    > "$dir/home/data/outbound-artifacts/$REQUEST_ID.json"
}

# The fake forge, answering only the three questions this path asks: the merge
# gate's rollup, the authorization layer's head re-observation, and the merge.
add_forge() {  # <dir> [<forge-head>]
  local dir=$1 head=${2:-$HEAD_A}
  printf '%s\n' "$head" > "$dir/forge_head"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-}" = api ]; then
  case "${2:-}" in
    graphql)
      query=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -q|--jq) query=${2:-}; shift 2 || shift ;;
          *) shift ;;
        esac
      done
      jq -r "$query" "$FM_TEST_ROLLUP_FIXTURE"
      exit $?
      ;;
    */pulls/*)
      cat "$FM_TEST_FORGE_HEAD"
      exit 0
      ;;
  esac
  exit 1
fi
exit 0
SH
  chmod +x "$dir/fakebin/gh-axi" "$dir/fakebin/gh"
}

# A rollup fixture in the API's own shape, so the merge gate's real query runs
# against it and the real fold in bin/fm-verify-lib.sh produces the label.
write_rollup() {  # <dir> <head> [<failing-count>] [<review-decision>] [<reviewer>] [<maker>]
  local dir=$1 head=$2 failing=${3:-0} review=${4-APPROVED} reviewer=${5:-reviewer} maker=${6:-maker} ok=2
  jq -n --arg head "$head" --arg review "$review" --arg reviewer "$reviewer" --arg maker "$maker" \
    --argjson ok "$ok" --argjson failing "$failing" \
    '{data:{repository:{pullRequest:{
        headRefOid:$head,
        mergeable:"MERGEABLE",
        reviewDecision:(if $review == "" then null else $review end),
        author:{login:$maker},
        reviews:{totalCount:(if $review == "APPROVED" then 1 else 0 end),
                 nodes:(if $review == "APPROVED" then [{state:"APPROVED",author:{login:$reviewer},commit:{oid:$head}}] else [] end)},
        commits:{totalCount:1,nodes:[{commit:{oid:$head,author:{user:{login:$maker}},committer:{user:{login:$maker}},statusCheckRollup:{contexts:{
          totalCount:($ok + $failing),
          nodes:(
            [range($ok) | {__typename:"CheckRun",name:"ok",conclusion:"SUCCESS",
                           status:"COMPLETED",databaseId:(1 + .),
                           checkSuite:{workflowRun:{workflow:{name:"w"}}}}]
            + [range($failing) | {__typename:"CheckRun",name:"bad",
                           conclusion:"FAILURE",status:"COMPLETED",
                           databaseId:(100 + .),
                           checkSuite:{workflowRun:{workflow:{name:"w"}}}}])}}}}]}}}}}' \
    > "$dir/rollup.json"
}

# An empty rollup: the head nothing examined. Never a green head.
write_empty_rollup() {  # <dir> <head>
  local dir=$1 head=$2
  jq -n --arg head "$head" \
    '{data:{repository:{pullRequest:{
        headRefOid:$head,
        mergeable:"MERGEABLE",
        reviewDecision:null,
        author:{login:"maker"}, reviews:{totalCount:0,nodes:[]},
        commits:{totalCount:1,nodes:[{commit:{oid:$head,author:{user:{login:"maker"}},committer:{user:{login:"maker"}},statusCheckRollup:{contexts:{
          totalCount:0, nodes:[]}}}}]}}}}}' \
    > "$dir/rollup.json"
}

# The task's commission record. `yolo=` is deliberately the CAPTAIN value in
# every fixture that then registers the project with a standing posture: the
# stale snapshot is exactly the secondary owner this repair stops trusting.
write_meta() {  # <dir> [<yolo>]
  local dir=$1 yolo=${2:-$FM_AUTONOMY_STATE_CAPTAIN}
  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$dir/wt" \
    "project=$dir/home/projects/$PROJECT_NAME" \
    "role=ship" \
    "mode=no-mistakes" \
    "harness=claude" \
    "model=opus" \
    "yolo=$yolo" \
    "pr=$PR_URL" \
    "pr_head=$HEAD_A"
}

# A decision the fleet has TYPED as the captain's, written the way
# bin/fm-decision-hold.sh writes it: a fenced disposition block beside the
# decision, plus the status event that opened it.
open_typed_decision() {  # <dir> <key> <disposition> [<verb>]
  local dir=$1 key=$2 disposition=$3 verb=${4:-needs-decision}
  mkdir -p "$dir/home/data/$TASK_ID" || return 1
  # shellcheck disable=SC2016  # the fence is literal markdown, not an expansion
  printf '# decision\n\n```disposition\n%s\n```\n' "$disposition" \
    > "$dir/home/data/$TASK_ID/decision-$key.md"
  printf '%s [key=%s]: activate the paid tier\n' "$verb" "$key" \
    >> "$dir/home/state/$TASK_ID.status"
}

new_pr_case() {  # <name> [<head>]
  local name=$1 head=${2:-$HEAD_A} dir
  dir=$(new_home "$name") || return 1
  write_meta "$dir"
  register_project "$dir"
  add_forge "$dir" "$head"
  write_rollup "$dir" "$head" 0
  configure_venue "$dir"
  printf '%s\n' "$dir"
}

RC=0
run_pr_merge() {  # <dir> [args...]
  local dir=$1; shift
  set +e
  ( cd "$dir" || exit 9
    FM_HOME="$dir/home" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_ROLLUP_FIXTURE="$dir/rollup.json" \
    FM_TEST_FORGE_HEAD="$dir/forge_head" \
    FM_PIPELINE_STATE_DB="${FM_PIPELINE_STATE_DB:-}" \
    PATH="$dir/fakebin:$PATH" \
      "$PR_MERGE" "$TASK_ID" "$PR_URL" "$@" ) > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
}

# The landing-authority claim, asked of the composer firstmate consults.
run_surface_check() {  # <dir>
  local dir=$1
  set +e
  SURFACE_OUT=$(FM_HOME="$dir/home" FM_TEST_ROLLUP_FIXTURE="$dir/rollup.json" \
    FM_PIPELINE_STATE_DB="${FM_PIPELINE_STATE_DB:-}" PATH="$dir/fakebin:$PATH" \
    "$SURFACE" check landing-authority "$TASK_ID" 2>&1)
  SURFACE_RC=$?
  set -e
}

# The same claim, from a process that inherited NOTHING: no exported overrides,
# no PATH from this shell, no memory of a prior answer. This is the restart.
run_surface_check_cold() {  # <dir>
  local dir=$1
  set +e
  SURFACE_OUT=$(env -i \
    HOME="$dir/cold-home" \
    PATH="$dir/fakebin:/usr/local/bin:/usr/bin:/bin" \
    FM_HOME="$dir/home" \
    FM_TEST_ROLLUP_FIXTURE="$dir/rollup.json" \
    FM_TEST_FORGE_HEAD="$dir/forge_head" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    /usr/bin/env bash "$SURFACE" check landing-authority "$TASK_ID" 2>&1)
  SURFACE_RC=$?
  set -e
}

merge_count() {  # <dir>
  local n
  n=$(grep -c '^pr merge ' "$1/gh-axi.log" 2>/dev/null || true)
  case $n in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

auth_states() {  # <dir> -> "<id> <state>" per authorization
  local f
  for f in "$1"/home/data/landing-authorizations/*.json; do
    [ -e "$f" ] || continue
    jq -r '"\(.authorization_id) \(.state)"' "$f"
  done
}

# --- (1) and (7): eligible, and it actually lands ----------------------------

test_ordinary_landing_is_eligible_with_no_captain_utterance() {
  local dir
  dir=$(new_pr_case eligible) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 0 ] \
    || fail "an ordinary reversible landing under an approving ruling was not eligible (rc=$SURFACE_RC): $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F 'DELEGATED_LANDING_ALLOWED' >/dev/null \
    || fail "the eligible verdict did not name its compiled token: $SURFACE_OUT"

  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "the delegated landing refused (rc=$RC): $(cat "$dir/stderr")"
  [ "$(merge_count "$dir")" = 1 ] \
    || fail "expected exactly one merge, observed $(merge_count "$dir")"
  pass "an ordinary reversible landing with an approving ruling and current gates is eligible with no captain utterance"
}

test_one_use_authorization_is_minted_and_spent_through_its_owner() {
  local dir states
  dir=$(new_pr_case one-use) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"

  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "the governed landing refused (rc=$RC): $(cat "$dir/stderr")"
  states=$(auth_states "$dir")
  [ "$(printf '%s\n' "$states" | grep -c .)" = 1 ] \
    || fail "expected exactly one landing authorization, observed: ${states:-none}"
  printf '%s' "$states" | grep -F ' spent' >/dev/null \
    || fail "the landing authorization was not spent by the merge path: ${states:-none}"

  # Presenting it again performs nothing: one use means one.
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a second landing under a spent authority was permitted"
  [ "$(merge_count "$dir")" = 1 ] \
    || fail "a second merge was performed under a spent authority: $(merge_count "$dir")"
  pass "the one-use landing authorization is minted and spent through its own owner, with no captain utterance in the fixture"
}

test_governing_ruling_is_part_of_the_compile() {
  local dir
  dir=$(new_pr_case ruling-absent) || fail "fixture failed"
  write_correlation "$dir" emitted '' "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a governing request with no ruling passed the compile"
  grep -F 'carries no readable ruling verdict' "$dir/stderr" >/dev/null \
    || fail "the compile did not name the absent ruling: $(cat "$dir/stderr")"
  [ -z "$(auth_states "$dir")" ] \
    || fail "an authorization was minted before the absent ruling stopped the compile"

  dir=$(new_pr_case ruling-declined) || fail "fixture failed"
  write_correlation "$dir" ruled REJECT "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a declining ruling passed the compile"
  grep -F "does not delegate this landing" "$dir/stderr" >/dev/null \
    || fail "the compile did not name the declining ruling: $(cat "$dir/stderr")"
  [ -z "$(auth_states "$dir")" ] \
    || fail "an authorization was minted before the declining ruling stopped the compile"
  pass "the governing request and its ruling verdict are compiled before minting"
}

# --- (2) restart --------------------------------------------------------------

test_eligibility_survives_a_cold_restart() {
  local dir warm
  dir=$(new_pr_case restart) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"
  mkdir -p "$dir/cold-home"

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 0 ] || fail "the warm process did not find the landing eligible: $SURFACE_OUT"
  warm=$SURFACE_OUT

  run_surface_check_cold "$dir"
  [ "$SURFACE_RC" -eq 0 ] \
    || fail "a fresh process reading only durable state lost the eligibility (rc=$SURFACE_RC): $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F 'DELEGATED_LANDING_ALLOWED' >/dev/null \
    || fail "the cold verdict did not name the compiled token: $SURFACE_OUT"
  [ -n "$warm" ] || fail "the warm verdict printed nothing to compare against"
  pass "the eligible verdict comes back unchanged from a fresh process that inherited no environment"
}

# --- (3) wrong or stale head --------------------------------------------------

test_approval_bound_to_another_head_refuses() {
  local dir
  dir=$(new_pr_case stale-head) || fail "fixture failed"
  # The ruling approved HEAD_B; the pull request is at HEAD_A.
  write_correlation "$dir" ruled APPROVE "$HEAD_B"

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a landing whose approval names another head was permitted"
  [ "$(merge_count "$dir")" = 0 ] \
    || fail "a merge was performed under an approval bound to another head: $(merge_count "$dir")"
  grep -F 'FM_LANDING_HEAD_NOT_APPROVED' "$dir/stderr" >/dev/null \
    || fail "the refusal did not name the head binding it failed: $(cat "$dir/stderr")"
  pass "an approval bound to another head refuses, and merges nothing"
}

# --- (4) missing evidence -----------------------------------------------------

test_missing_check_evidence_refuses() {
  local dir
  dir=$(new_pr_case no-evidence) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"
  write_empty_rollup "$dir" "$HEAD_A"

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a head nothing examined was landed"
  [ "$(merge_count "$dir")" = 0 ] \
    || fail "a merge was performed on a head with no check evidence: $(merge_count "$dir")"
  [ "$(auth_states "$dir" | grep -c ' spent' || true)" = 0 ] \
    || fail "a landing authority was spent on a head with no check evidence"
  pass "required check evidence that is absent refuses, and is never read as eligible"
}

test_missing_review_evidence_requires_the_captain() {
  local dir
  dir=$(new_pr_case no-review) || fail "fixture failed"
  write_rollup "$dir" "$HEAD_A" 0 ''

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a landing with no reviewer evidence was permitted"
  grep -F 'assignment-distinct review evidence could not be observed' "$dir/stderr" >/dev/null \
    || fail "the compile did not name the missing review evidence: $(cat "$dir/stderr")"
  [ "$(merge_count "$dir")" = 0 ] || fail "a merge ran without review evidence"
  pass "missing review evidence compiles to CAPTAIN_REQUIRED"
}

test_changes_requested_refuses() {
  local dir
  dir=$(new_pr_case changes-requested) || fail "fixture failed"
  write_rollup "$dir" "$HEAD_A" 0 CHANGES_REQUESTED

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a landing with changes requested was permitted"
  grep -F 'a review requests changes' "$dir/stderr" >/dev/null \
    || fail "the refusal did not name the blocking review: $(cat "$dir/stderr")"
  [ "$(merge_count "$dir")" = 0 ] || fail "a merge ran with changes requested"
  pass "changes requested still refuses"
}

test_maker_associated_approval_requires_the_captain() {
  local dir
  dir=$(new_pr_case maker-review) || fail "fixture failed"
  write_rollup "$dir" "$HEAD_A" 0 APPROVED maker maker

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a maker-associated approval authorized its own landing"
  grep -F 'maker-associated-approval' "$dir/stderr" >/dev/null \
    || fail "the compile did not name the maker-associated approval: $(cat "$dir/stderr")"
  pass "a maker-associated approval compiles to CAPTAIN_REQUIRED"
}

test_independent_pipeline_review_allows_null_github_decision() {
  local dir project
  dir=$(new_pr_case pipeline-review) || fail "fixture failed"
  write_rollup "$dir" "$HEAD_A" 0 ''
  project="$dir/home/projects/$PROJECT_NAME"
  mkdir -p "$project"
  fm_test_model_registry "$dir/home/config/models.json"
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$project" \
    "fm/$TASK_ID|openai|gpt-5.6-sol|review||completed|$HEAD_A" || fail "pipeline fixture failed"

  FM_PIPELINE_STATE_DB="$dir/pipeline.sqlite" run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "exact-head independent pipeline evidence did not authorize landing: $(cat "$dir/stderr")"
  grep -F 'review=independent' "$dir/stdout" >/dev/null \
    || fail "the compiler did not report independent pipeline evidence: $(cat "$dir/stdout")"
  pass "exact-head independent pipeline evidence permits a null GitHub decision"
}

test_approved_review_allows_an_ungoverned_landing() {
  local dir
  dir=$(new_pr_case approved-review) || fail "fixture failed"

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 0 ] \
    || fail "the surface disagreed with the GitHub-reviewed landing: $SURFACE_OUT"

  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "an ungoverned landing with approved review evidence refused: $(cat "$dir/stderr")"
  grep -F 'review=github-approved' "$dir/stdout" >/dev/null \
    || fail "the compile did not report its review evidence: $(cat "$dir/stdout")"
  [ "$(merge_count "$dir")" = 1 ] || fail "the reviewed landing did not merge exactly once"
  pass "approved review evidence permits an ungoverned delegated landing"
}

test_decision_surface_never_delegates_an_unreviewed_candidate() {
  local dir
  dir=$(new_pr_case surface-unreviewed) || fail "fixture failed"
  write_rollup "$dir" "$HEAD_A" 0 ''

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 3 ] \
    || fail "the decision surface delegated a candidate with no review evidence (rc=$SURFACE_RC): $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F 'CAPTAIN_REQUIRED' >/dev/null \
    || fail "the decision surface did not name its review-evidence refusal: $SURFACE_OUT"
  pass "the decision surface does not bypass missing review evidence"
}

test_decision_surface_uses_live_pr_head() {
  local dir
  dir=$(new_pr_case surface-live-head) || fail "fixture failed"
  sed -i "s/^pr_head=.*/pr_head=$HEAD_B/" "$dir/home/state/$TASK_ID.meta"

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 3 ] \
    || fail "the surface compiled a stale recorded PR candidate (rc=$SURFACE_RC): $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F "live head=$HEAD_A differs from stale recorded head=$HEAD_B" >/dev/null \
    || fail "the surface refusal did not name the live and stale heads: $SURFACE_OUT"
  pass "the decision surface refuses stale recorded PR heads against the live head"
}

# --- (5) a decision the fleet typed as the captain's --------------------------

test_a_captain_reserved_decision_requires_the_captain() {
  local dir
  dir=$(new_pr_case reserved) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"
  open_typed_decision "$dir" paid-tier CAPTAIN_REQUIRED_AND_BLOCKING blocked

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 3 ] \
    || fail "a typed captain-reserved decision did not contradict the delegated claim (rc=$SURFACE_RC): $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F 'CAPTAIN_REQUIRED' >/dev/null \
    || fail "the verdict did not name CAPTAIN_REQUIRED: $SURFACE_OUT"
  printf '%s' "$SURFACE_OUT" | grep -F 'paid-tier' >/dev/null \
    || fail "the verdict did not name the decision that reserved it: $SURFACE_OUT"

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a landing was performed while a captain-reserved decision was open"
  [ "$(merge_count "$dir")" = 0 ] \
    || fail "a merge ran while a captain-reserved decision was open: $(merge_count "$dir")"
  pass "a decision the fleet typed as the captain's makes the landing CAPTAIN_REQUIRED and the merge gate refuses"
}

# --- (6) a posture cannot waive an engineering gate ---------------------------

test_standing_posture_cannot_waive_an_engineering_gate() {
  local dir
  dir=$(new_pr_case posture-vs-gate) || fail "fixture failed"
  # Every authority source is as permissive as it can be.
  write_meta "$dir" "$FM_AUTONOMY_STATE_SELF"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"
  write_rollup "$dir" "$HEAD_A" 1

  run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 0 ] \
    || fail "the authority compile itself should still be delegated here: $SURFACE_OUT"

  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "a standing posture waived a failing check"
  [ "$(merge_count "$dir")" = 0 ] \
    || fail "a merge ran past a failing check under a standing posture: $(merge_count "$dir")"
  [ "$(auth_states "$dir" | grep -c ' spent' || true)" = 0 ] \
    || fail "a landing authority was spent past a failing check"
  pass "a standing posture and an approving ruling together cannot waive a real engineering gate"
}

# --- (8) local-only -----------------------------------------------------------

test_local_only_landing_is_delegated_on_the_same_terms() {
  local dir proj before after
  dir=$(new_home local-only) || fail "fixture failed"
  proj="$dir/home/projects/$PROJECT_NAME"
  mkdir -p "$proj"
  fm_git_init_commit "$proj" >/dev/null 2>&1 || fail "fixture repo failed"
  git -C "$proj" checkout -q -b "fm/$TASK_ID" || fail "fixture branch failed"
  printf 'planning note\n' > "$proj/NOTE.md"
  git -C "$proj" add NOTE.md >/dev/null
  git -C "$proj" -c commit.gpgsign=false commit -q -m "add a planning note" \
    || fail "fixture commit failed"
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master

  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$dir/wt" \
    "project=$proj" \
    "role=ship" \
    "mode=local-only" \
    "harness=claude" \
    "model=opus" \
    "yolo=$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$dir" "local-only +yolo"
  fm_test_model_registry "$dir/home/config/models.json"
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$proj" \
    "fm/$TASK_ID|openai|gpt-5.6-sol|review||completed|$(git -C "$proj" rev-parse "fm/$TASK_ID")" || return 1

  FM_PIPELINE_STATE_DB="$dir/pipeline.sqlite" run_surface_check "$dir"
  [ "$SURFACE_RC" -eq 0 ] \
    || fail "the surface disagreed with the reviewed local-only candidate: $SURFACE_OUT"

  before=$(git -C "$proj" rev-parse HEAD)
  set +e
  ( FM_HOME="$dir/home" FM_PIPELINE_STATE_DB="$dir/pipeline.sqlite" \
      "$MERGE_LOCAL" "$TASK_ID" ) > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
  [ "$RC" -eq 0 ] || fail "the local-only landing refused (rc=$RC): $(cat "$dir/stderr")"
  after=$(git -C "$proj" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "the local-only landing moved nothing"
  pass "a local-only landing is delegated on the same terms, with no captain utterance"
}

# --- (8b) the compile reads the home it was ASKED about -----------------------
#
# Driven with the state and data overrides and NO FM_HOME, the shape every
# operator command supports and the shape a fixture needs. The pair is what makes
# it evidence: the same fixture lands unperturbed and refuses once a decision the
# fleet typed as the captain's is placed in THAT home's records. A compile
# reading the ambient home instead would land both times.
make_override_case() {  # <name>
  local name=$1 dir proj
  dir=$(new_home "$name") || return 1
  proj="$dir/home/projects/$PROJECT_NAME"
  mkdir -p "$proj"
  fm_git_init_commit "$proj" >/dev/null 2>&1 || return 1
  git -C "$proj" checkout -q -b "fm/$TASK_ID"
  printf 'planning note\n' > "$proj/NOTE.md"
  git -C "$proj" add NOTE.md >/dev/null
  git -C "$proj" -c commit.gpgsign=false commit -q -m "add a planning note"
  git -C "$proj" checkout -q main 2>/dev/null || git -C "$proj" checkout -q master
  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$dir/wt" \
    "project=$proj" \
    "role=ship" \
    "mode=local-only" \
    "harness=claude" \
    "model=opus" \
    "yolo=$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$dir" "local-only +yolo"
  fm_test_model_registry "$dir/home/config/models.json"
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$proj" \
    "fm/$TASK_ID|openai|gpt-5.6-sol|review||completed|$(git -C "$proj" rev-parse "fm/$TASK_ID")" || return 1
  printf '%s\n' "$dir"
}

run_merge_local_by_override() {  # <dir>
  local dir=$1
  set +e
  ( FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_PIPELINE_STATE_DB="$dir/pipeline.sqlite" \
      "$MERGE_LOCAL" "$TASK_ID" ) > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
}

test_the_compile_reads_the_home_it_was_asked_about() {
  local clean dirty proj before after
  clean=$(make_override_case override-clean) || fail "fixture failed"
  run_merge_local_by_override "$clean"
  [ "$RC" -eq 0 ] || fail "the override-addressed landing refused (rc=$RC): $(cat "$clean/stderr")"
  grep -F 'DELEGATED_LANDING_ALLOWED' "$clean/stdout" >/dev/null \
    || fail "the override-addressed landing reported no compiled authority: $(cat "$clean/stdout")"

  dirty=$(make_override_case override-reserved) || fail "fixture failed"
  proj="$dirty/home/projects/$PROJECT_NAME"
  open_typed_decision "$dirty" spend CAPTAIN_REQUIRED_AND_BLOCKING blocked
  before=$(git -C "$proj" rev-parse HEAD)
  run_merge_local_by_override "$dirty"
  after=$(git -C "$proj" rev-parse HEAD)
  [ "$RC" -ne 0 ] \
    || fail "a decision recorded under the addressed home's data directory was not seen"
  [ "$before" = "$after" ] || fail "the local landing moved despite a reserved decision"
  pass "the compile reads the records of the home it was addressed to, through the state and data overrides"
}

test_local_pipeline_review_is_bound_to_the_landing_head() {
  local dir proj landing_head stale_head
  dir=$(make_override_case stale-local-review) || fail "fixture failed"
  proj="$dir/home/projects/$PROJECT_NAME"
  landing_head=$(git -C "$proj" rev-parse "fm/$TASK_ID")
  stale_head=$HEAD_B
  rm -f "$dir/pipeline.sqlite"
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$proj" \
    "fm/$TASK_ID|openai|gpt-5.6-sol|review||completed|$stale_head" || fail "pipeline fixture failed"

  run_merge_local_by_override "$dir"
  [ "$RC" -ne 0 ] || fail "review evidence for another head authorized the local landing"
  grep -F "stale-head=$stale_head expected=$landing_head" "$dir/stderr" >/dev/null \
    || fail "the refusal did not name the stale and landing heads: $(cat "$dir/stderr")"
  pass "local independent review evidence is bound to the exact landing head"
}

# --- (9) could-not-observe ----------------------------------------------------

test_an_unreadable_decision_record_is_never_eligible() {
  local dir
  dir=$(new_pr_case unreadable) || fail "fixture failed"
  write_correlation "$dir" ruled APPROVE "$HEAD_A"
  # A status log this process cannot read is exactly the one that might carry
  # the captain's decision, so it is could-not-observe rather than an absence.
  printf 'needs-decision [key=unknown]: something\n' > "$dir/home/state/$TASK_ID.status"
  chmod 000 "$dir/home/state/$TASK_ID.status"

  run_surface_check "$dir"
  chmod 644 "$dir/home/state/$TASK_ID.status"
  [ "$SURFACE_RC" -eq 4 ] \
    || fail "an unreadable decision universe did not report could-not-observe (rc=$SURFACE_RC): $SURFACE_OUT"
  [ "$SURFACE_RC" -ne 0 ] || fail "an unreadable decision universe read as eligible"
  pass "a decision universe that could not be read is could-not-observe, never eligible"
}

# --- (10) the effective posture follows the canonical owner -------------------

drain_dispositions() {  # <dir> -> the drain's OPEN DECISIONS lines
  local dir=$1
  FM_DATA_OVERRIDE="$dir/home/data" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" "$DRAIN" 2>/dev/null
}

test_effective_posture_follows_the_registry_not_the_task_record() {
  local dir out
  dir=$(new_home effective-posture) || fail "fixture failed"
  write_meta "$dir" "$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$dir"
  printf 'blocked [key=rollout]: pick the rollout order\n' \
    > "$dir/home/state/$TASK_ID.status"

  out=$(drain_dispositions "$dir")
  printf '%s' "$out" | grep -F "$TASK_ID [key=rollout] SELF_HANDLE" >/dev/null \
    || fail "a task on a project the captain registered with a standing posture still reported as the captain's: $out"
  pass "a live task's stale recorded posture no longer projects the decision as the captain's"
}

# --- (11) the canonical owner is a file read on every resolution --------------

test_the_posture_is_reread_on_every_resolution() {
  local dir warm cold edited
  dir=$(new_home reread) || fail "fixture failed"
  mkdir -p "$dir/cold-home"
  write_meta "$dir" "$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$dir"
  printf 'blocked [key=rollout]: pick the rollout order\n' \
    > "$dir/home/state/$TASK_ID.status"

  warm=$(drain_dispositions "$dir")
  printf '%s' "$warm" | grep -F 'SELF_HANDLE' >/dev/null \
    || fail "the posture was not ON before the restart: $warm"

  cold=$(env -i HOME="$dir/cold-home" PATH="/usr/local/bin:/usr/bin:/bin" \
    FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_STATE_OVERRIDE="$dir/home/state" \
    /usr/bin/env bash "$DRAIN" 2>/dev/null)
  printf '%s' "$cold" | grep -F 'SELF_HANDLE' >/dev/null \
    || fail "the posture was not ON after a fresh process read only durable state: $cold"

  # A registry edit takes effect with no restart at all, which is what proves
  # the canonical owner is read rather than remembered.
  register_project "$dir" "no-mistakes"
  edited=$(drain_dispositions "$dir")
  printf '%s' "$edited" | grep -F 'CAPTAIN_REQUIRED_AND_BLOCKING' >/dev/null \
    || fail "withdrawing the standing posture at its canonical owner had no effect: $edited"
  pass "the standing posture survives a restart and follows a registry edit without one"
}

# --- (13) the compile classifies the whole disposition vocabulary -------------
#
# The one thing a new disposition must never do is arrive unclassified and be
# read as permission. The compile answers a fourth value for exactly that case,
# and this drives the real predicate over the real vocabulary so adding a member
# to one owner without teaching the other turns the suite red.
test_every_disposition_is_classified_by_the_compile() {
  local member rc unclassified=''
  # shellcheck source=bin/fm-landing-seam-lib.sh
  . "$ROOT/bin/fm-landing-seam-lib.sh"
  [ -n "${FM_DECISION_DISPOSITION_VOCABULARY:-}" ] \
    || fail "the disposition vocabulary was not reachable from the compile's own owners"
  for member in $FM_DECISION_DISPOSITION_VOCABULARY; do
    rc=0
    fm_landing_authority_disposition_reserves "$member" || rc=$?
    case "$rc" in
      0|1|2) ;;
      *) unclassified="$unclassified $member($rc)" ;;
    esac
  done
  [ -z "$unclassified" ] \
    || fail "the landing compile does not classify these dispositions, so they would stop every landing as an instrument defect:$unclassified"
  # The negative half: a value that is NOT in the vocabulary must reach the
  # fourth answer rather than any of the three, so this case cannot pass by the
  # predicate answering something for everything.
  rc=0
  fm_landing_authority_disposition_reserves NOT_A_DISPOSITION || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "an unclassified disposition answered $rc rather than naming itself unclassified"
  pass "every disposition in the closed vocabulary is classified by the landing compile, and an unknown one is not"
}

# --- (12) the unknown-project default ----------------------------------------

test_registry_presence_controls_snapshot_fallback() {
  local dir out
  dir=$(new_home unregistered) || fail "fixture failed"
  write_meta "$dir" "$FM_AUTONOMY_STATE_SELF"
  printf -- '- some-other-project [no-mistakes +yolo] - not this one (added 2026-08-26)\n' \
    > "$dir/home/data/projects.md"
  printf 'blocked [key=rollout]: pick the rollout order\n' \
    > "$dir/home/state/$TASK_ID.status"

  out=$(drain_dispositions "$dir")
  printf '%s' "$out" | grep -F 'CAPTAIN_REQUIRED_AND_BLOCKING' >/dev/null \
    || fail "a registry omission inherited an on task snapshot: $out"

  dir=$(new_home no-registry) || fail "fixture failed"
  write_meta "$dir" "$FM_AUTONOMY_STATE_SELF"
  rm "$dir/home/data/projects.md" 2>/dev/null || true
  out=$(FM_HOME="$dir/home" fm_autonomy_state_effective "$dir/home/state/$TASK_ID.meta" "$dir/home")
  [ "$out" = "$FM_AUTONOMY_STATE_SELF" ] \
    || fail "a home with no registry lost its on task snapshot: $out"

  dir=$(new_home registered-on) || fail "fixture failed"
  write_meta "$dir" "$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$dir"
  out=$(FM_HOME="$dir/home" fm_autonomy_state_effective "$dir/home/state/$TASK_ID.meta" "$dir/home")
  [ "$out" = "$FM_AUTONOMY_STATE_SELF" ] \
    || fail "a registered +yolo project did not resolve on: $out"

  dir=$(new_home registered-off) || fail "fixture failed"
  write_meta "$dir" "$FM_AUTONOMY_STATE_SELF"
  register_project "$dir" no-mistakes
  out=$(FM_HOME="$dir/home" fm_autonomy_state_effective "$dir/home/state/$TASK_ID.meta" "$dir/home")
  [ "$out" = "$FM_AUTONOMY_STATE_CAPTAIN" ] \
    || fail "a registered off posture inherited an on task snapshot: $out"
  pass "registry presence controls whether the current posture or task snapshot wins"
}

test_effective_posture_memo_is_scoped_to_the_addressed_home() {
  local on off got
  on=$(new_home memo-home-on) || fail "fixture failed"
  off=$(new_home memo-home-off) || fail "fixture failed"
  write_meta "$on" "$FM_AUTONOMY_STATE_CAPTAIN"
  write_meta "$off" "$FM_AUTONOMY_STATE_SELF"
  register_project "$on"
  register_project "$off" no-mistakes

  got=$(fm_autonomy_state_effective "$on/home/state/$TASK_ID.meta" "$on/home")
  [ "$got" = "$FM_AUTONOMY_STATE_SELF" ] || fail "the on home did not resolve on: $got"
  got=$(fm_autonomy_state_effective "$off/home/state/$TASK_ID.meta" "$off/home")
  [ "$got" = "$FM_AUTONOMY_STATE_CAPTAIN" ] \
    || fail "the memo leaked the first home's posture into the second home: $got"
  pass "effective posture lookup and memoization are scoped to the addressed home"
}

test_decision_disposition_honours_its_explicit_home() {
  local ambient target got
  ambient=$(new_home disposition-ambient) || fail "fixture failed"
  target=$(new_home disposition-target) || fail "fixture failed"
  write_meta "$ambient" "$FM_AUTONOMY_STATE_CAPTAIN"
  write_meta "$target" "$FM_AUTONOMY_STATE_CAPTAIN"
  register_project "$ambient" no-mistakes
  register_project "$target"
  . "$ROOT/bin/fm-classify-lib.sh"

  got=$(FM_HOME="$ambient/home" decision_disposition "$TASK_ID" rollout blocked "$target/home")
  [ "$got" = SELF_HANDLE ] \
    || fail "decision_disposition read the ambient home instead of its explicit home: $got"
  pass "decision disposition honours its explicit home"
}

test_ordinary_landing_is_eligible_with_no_captain_utterance
test_one_use_authorization_is_minted_and_spent_through_its_owner
test_governing_ruling_is_part_of_the_compile
test_eligibility_survives_a_cold_restart
test_approval_bound_to_another_head_refuses
test_missing_check_evidence_refuses
test_missing_review_evidence_requires_the_captain
test_changes_requested_refuses
test_maker_associated_approval_requires_the_captain
test_independent_pipeline_review_allows_null_github_decision
test_approved_review_allows_an_ungoverned_landing
test_decision_surface_never_delegates_an_unreviewed_candidate
test_decision_surface_uses_live_pr_head
test_a_captain_reserved_decision_requires_the_captain
test_standing_posture_cannot_waive_an_engineering_gate
test_local_only_landing_is_delegated_on_the_same_terms
test_the_compile_reads_the_home_it_was_asked_about
test_local_pipeline_review_is_bound_to_the_landing_head
test_an_unreadable_decision_record_is_never_eligible
test_effective_posture_follows_the_registry_not_the_task_record
test_the_posture_is_reread_on_every_resolution
test_registry_presence_controls_snapshot_fallback
test_effective_posture_memo_is_scoped_to_the_addressed_home
test_decision_disposition_honours_its_explicit_home
test_every_disposition_is_classified_by_the_compile

fm_test_contract "${BASH_SOURCE[0]}"
