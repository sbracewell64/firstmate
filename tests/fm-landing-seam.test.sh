#!/usr/bin/env bash
# fm-landing-seam.test.sh - the landing authorization is CONSUMED BY THE REAL
# MUTATION PATH, not merely available beside it.
#
# Subject: bin/fm-landing-seam-lib.sh, as wired into bin/fm-pr-merge.sh and
# bin/fm-merge-local.sh. Evidence owner: docs/verification/inbound-ruling-authorization.md.
#
# WHY THIS SUITE EXISTS SEPARATELY FROM tests/fm-landing-authorization.test.sh.
#
# That suite proves the authority layer: one exact head, one use, intent before
# act, an indeterminate spend that stays indeterminate. It proved all of it while
# `bin/fm-pr-merge.sh` and `bin/fm-merge-local.sh` merged without ever calling it,
# and every one of its greens was true the whole time. A control that passes in
# isolation and can be walked around by the production route is a NON-DELIVERED
# control, and no amount of testing the control itself detects that.
#
# So this suite tests the SEAM, and it drives the real commands. Every case
# invokes `bin/fm-pr-merge.sh` or `bin/fm-merge-local.sh` end to end; none of them
# calls `bin/fm-landing-authorization.sh` directly to stage a result, because a
# fixture that spends an authorization by hand proves the authorization works and
# says nothing about whether the merge path reaches it.
#
# WHAT EACH RED IS ATTRIBUTABLE TO. Every refusal case below is one perturbation
# away from a case that lands. The perturbation is named in the test name and in
# the failure message, and the paired landing case runs the same fixture
# unperturbed. That pairing is what makes a refusal evidence about the
# perturbation rather than about a mechanism that refuses everything.
#
# THE ACT IS COUNTED, NEVER ASSUMED. A merge is observed by counting the `gh-axi
# pr merge` invocations the fake forge recorded, and a local landing by comparing
# the default branch's own commit. Both report the number they observed, because
# "no bad merge happened" is also what a completely broken gate produces.
#
# Matrix - bin/fm-pr-merge.sh:
#   (a) an ungoverned candidate lands, and REPORTS not-applicable
#   (b) an ungoverned candidate in a home with no control venue lands, and says so
#   (c) a governed candidate whose request carries no ruling is REFUSED
#   (d) a governed candidate under a valid ruling lands, spending the authority
#   (e) presenting the same spent authority again is REFUSED and merges nothing
#   (f) a governed item whose approved head is not the head being landed is REFUSED
#   (g) a declining ruling is REFUSED
#   (h) a ruling verdict this fleet cannot classify is REFUSED
#   (i) an unreadable correlation record is REFUSED, not read as an absence
#   (j) live governance with no configured control venue is REFUSED
#   (k) the pre-existing red-head refusal still fires under a VALID authority,
#       and leaves that authority unspent
#   (k1) the head is re-observed at the moment of use: a forge whose pull request
#        has moved refuses even when every local record still says the approved
#        head
#   (k2) two live requests claiming the same item at the same head are ambiguous
#        and REFUSE, rather than one of them being picked
#   (k3) a request that is closed no longer governs, so a past ruling cannot block
#        an item forever
#   (k4) a gate outside the landing-governing set does not govern, and the item
#        lands
#
# Matrix - bin/fm-merge-local.sh:
#   (l) an ungoverned candidate lands, and REPORTS not-applicable
#   (m) a governed candidate whose request carries no ruling is REFUSED
#   (n) a governed candidate under a valid ruling lands, spending the authority
#   (o) presenting the same spent authority again is REFUSED and moves nothing
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The check-rollup fixture folds through the real owner rather than restating it.
# shellcheck source=bin/fm-verify-lib.sh
. "$ROOT/bin/fm-verify-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

FM_TEST_IDENTITY_CONTRACT=1

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
# bin/fm-landing-authorization.sh is deliberately absent from this list. Nothing
# here invokes it: every authority these cases mint or spend is minted and spent
# by the merge gates themselves, which is the whole claim.

TMP_ROOT=$(fm_test_tmproot fm-landing-seam) || exit 1

TASK_ID=seam-1
PR_URL='https://github.com/owner/demo/pull/7'
# The same pull request addressed in another case, which is all a hand-typed url
# takes. Used only by the candidate half of the domain comparison.
MIXED_CASE_PR_URL='https://github.com/Owner/Demo/pull/7'
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REQUEST_ID=fm-ob-0123456789ab

# --- shared fixture ----------------------------------------------------------

# One operational home. `data/outbound-artifacts` is populated per case with a
# correlation record written as DATA in the schema bin/fm-outbound-artifact-lib.sh
# publishes, never by calling that owner's emitter: this suite proves the landing
# seam, and reaching into the emitter to build a fixture would couple the two
# exactly where they must stay separable.
new_home() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" || return 1
  # Keep the shared watcher-liveness banner quiet: these cases exercise the
  # landing seam, not supervision staleness.
  touch "$dir/home/state/.last-watcher-beat" || return 1
  printf '%s\n' "$dir"
}

# The venue, plus this home's DECLARED governed landing domain.
#
# The default declares a domain that does not contain either fixture repository,
# so every case that lands with no live correlation lands on POSITIVE
# out-of-domain grounds. That distinction is the whole subject of the applicability
# half of this suite: before the domain was declared, those same cases landed
# because no record was found, which is an absence rather than an answer.
PR_REPO_PATH='owner/demo'
LOCAL_REPO_PATH='owner/local-demo'

configure_venue() {  # <dir> [<repos-json>]
  local dir=$1 repos=${2:-'["owner/elsewhere"]'}
  printf '{ "repo": "owner/control", "issue": 2, "landing_domain": { "repos": %s } }\n' \
    "$repos" > "$dir/home/config/sol-control.json"
}

# A venue that declares no domain at all, which is not an empty one.
configure_venue_without_domain() {  # <dir>
  printf '%s\n' '{ "repo": "owner/control", "issue": 2 }' \
    > "$1/home/config/sol-control.json"
}

# A venue whose domain declaration is present and malformed.
configure_venue_with_raw_domain() {  # <dir> <json>
  printf '{ "repo": "owner/control", "issue": 2, "landing_domain": %s }\n' \
    "$2" > "$1/home/config/sol-control.json"
}

configure_raw_venue() {  # <dir> <contents>
  printf '%s\n' "$2" > "$1/home/config/sol-control.json"
}

# <dir> <state> <verdict> <head> [<gate>] [<item>] [<request-id>]
write_correlation() {
  local dir=$1 state=$2 verdict=$3 head=$4
  local gate=${5:-EXACT_HEAD_BROWSER_REVIEW_REQUIRED} item=${6:-$TASK_ID} rid=${7:-$REQUEST_ID}
  mkdir -p "$dir/home/data/outbound-artifacts" || return 1
  jq -n --arg rid "$rid" --arg state "$state" --arg verdict "$verdict" \
    --arg head "$head" --arg gate "$gate" --arg item "$item" --arg pr "$PR_URL" \
    '{schema:"fm-outbound-artifact.v1",
      request_id:$rid,
      channel:"sol-control",
      identity:{gate:$gate,project:"demo-project",repo:"owner/control",item:$item,
                pr:$pr,head:$head,head_source:"pull-request"},
      venue:"owner/control#2",
      state:$state,
      comment_id:"900",
      attempts:1,
      created:"2026-08-18T00:00:00Z",
      updated:"2026-08-18T00:00:00Z",
      ruling:(if $verdict == "" then null
              else {comment_id:"901",verdict:$verdict,observed:"2026-08-18T01:00:00Z"} end),
      resumed:null,
      disposition:null,
      superseded_by:null}' \
    > "$dir/home/data/outbound-artifacts/$rid.json"
}

# The fake forge. It answers the three questions this path asks and nothing else:
# the merge gate's GraphQL rollup, the authorization layer's own head
# re-observation, and the merge itself. The head it reports for the pull request
# lives in a file so a case can move it, which is the only way to exercise a head
# that changed between approval and use.
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
      case " $* " in
        *" [.merged, .head.sha] | @tsv "*)
          printf 'true\t'
          ;;
      esac
      cat "$FM_TEST_FORGE_HEAD"
      exit 0
      ;;
  esac
  # Every other api read - the empty-rollup check-suite enrichment above all -
  # is deliberately unanswerable here, so a refusal is never dressed up with
  # detail this fixture invented.
  exit 1
fi
exit 0
SH
  chmod +x "$dir/fakebin/gh-axi" "$dir/fakebin/gh"
}

# A GraphQL rollup fixture in the API's own shape, so the merge gate's real query
# runs against it. label= is never hand-written: the case asks for a verdict mix
# and the real fold in bin/fm-verify-lib.sh produces the label.
write_rollup() {  # <dir> <head> <failing-count>
  local dir=$1 head=$2 failing=${3:-0} ok=2
  jq -n --arg head "$head" --argjson ok "$ok" --argjson failing "$failing" \
    '{data:{repository:{pullRequest:{
        headRefOid:$head,
        mergeable:"MERGEABLE",
        reviewDecision:null,
        commits:{nodes:[{commit:{oid:$head,statusCheckRollup:{contexts:{
          totalCount:($ok + $failing),
          nodes:(
            [range($ok) | {__typename:"CheckRun",name:"ok",conclusion:"SUCCESS",
                           status:"COMPLETED",databaseId:(1 + .),
                           checkSuite:{workflowRun:{workflow:{name:"w"}}}}]
            + [range($failing) | {__typename:"CheckRun",name:"bad",conclusion:"FAILURE",
                           status:"COMPLETED",databaseId:(100 + .),
                           checkSuite:{workflowRun:{workflow:{name:"w"}}}}])}}}}]}}}}}' \
    > "$dir/rollup.json"
}

write_meta() {  # <dir>
  fm_write_meta "$1/home/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$1/wt" \
    "project=$1/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

# One PR-merge case, ready to run: a home, a meta, a forge, and a green rollup.
new_pr_case() {  # <name> [<head>]
  local name=$1 head=${2:-$HEAD_A} dir
  dir=$(new_home "$name") || return 1
  write_meta "$dir"
  add_forge "$dir" "$head"
  write_rollup "$dir" "$head" 0
  configure_venue "$dir"
  printf '%s\n' "$dir"
}

RC=0
run_pr_merge_at() {  # <dir> <pr-url> [args...]
  local dir=$1 url=$2; shift 2
  set +e
  ( cd "$dir" || exit 9
    FM_HOME="$dir/home" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_ROLLUP_FIXTURE="$dir/rollup.json" \
    FM_TEST_FORGE_HEAD="$dir/forge_head" \
    PATH="$dir/fakebin:$PATH" \
      "$PR_MERGE" "$TASK_ID" "$url" "$@" ) > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
}

run_pr_merge() {  # <dir> [args...]
  local dir=$1; shift
  run_pr_merge_at "$dir" "$PR_URL" "$@"
}

# The number of merges the forge was actually asked to perform. Reported rather
# than asserted-away, because zero is also what a gate that never ran produces.
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

auth_count() {  # <dir>
  local n
  n=$(auth_states "$1" | grep -c . || true)
  case $n in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

assert_output_has() {  # <dir> <needle> <label>
  grep -qF -- "$2" "$1/stdout" "$1/stderr" \
    || fail "$3: expected '$2' in the command's own output; got stdout=[$(cat "$1/stdout")] stderr=[$(cat "$1/stderr")]"
}

# --- bin/fm-pr-merge.sh ------------------------------------------------------

test_pr_merge_lands_a_candidate_proven_outside_the_domain() {
  local dir merges
  # The home declares a governed landing domain and this repository is not in it.
  # That is the ONLY thing that makes this landing ungoverned: no record was found
  # either, and before the domain was declared that absence is what let it merge.
  dir=$(new_pr_case out-of-domain)
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "out-of-domain: expected the merge to proceed, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "out-of-domain: the forge was asked to merge $merges times, expected exactly 1"
  assert_output_has "$dir" FM_LANDING_NOT_APPLICABLE out-of-domain
  assert_output_has "$dir" 'is not in this home'"'"'s declared Browser Sol landing domain' out-of-domain
  grep -qxF 'landing_authorization=not-applicable' "$dir/home/state/$TASK_ID.meta" \
    || fail "out-of-domain: the merge record does not say the landing was ungoverned"
  pass "a pull request proven outside the declared landing domain lands through fm-pr-merge and reports not-applicable (merges executed: $merges)"
}

test_pr_merge_refuses_an_in_domain_candidate_with_no_correlation() {
  local dir merges
  # THE REPAIR, at the real mutation path. One perturbation from the case above:
  # the same home, the same empty correlation store, the same green rollup, and
  # this repository named in the declared domain. An absent record must now be the
  # refusal rather than the permission.
  dir=$(new_pr_case in-domain-missing)
  configure_venue "$dir" "[\"$PR_REPO_PATH\"]"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "in-domain-missing: a governed repository with no review request must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "in-domain-missing: the forge was asked to merge $merges times with no authority in existence"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING in-domain-missing
  [ "$(auth_count "$dir")" -eq 0 ] \
    || fail "in-domain-missing: an authorization was minted for a landing no request covers"
  pass "a governed-domain pull request with no review request refuses the real fm-pr-merge path (merges executed: 0)"
}

test_pr_merge_refuses_when_the_landing_domain_is_undeclared() {
  local dir merges
  # A home that configured Sol control and never said what it governs cannot
  # answer this question. An undeclared domain is could-not-observe, never an
  # empty one, because reading it as empty is the silence this control replaces.
  dir=$(new_pr_case domain-undeclared)
  configure_venue_without_domain "$dir"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "domain-undeclared: an undeclared landing domain must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "domain-undeclared: the forge was asked to merge $merges times without knowing whether the landing was governed"
  assert_output_has "$dir" FM_LANDING_VENUE_INVALID domain-undeclared
  pass "a configured venue with no declared landing domain refuses fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_an_unreadable_landing_domain() {
  local dir merges
  dir=$(new_pr_case domain-unreadable)
  # Present and malformed. A declaration that cannot be read is a defect in the
  # declaration, not an answer about this candidate.
  configure_venue_with_raw_domain "$dir" '"everything"'
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "domain-unreadable: a malformed landing domain must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "domain-unreadable: the forge was asked to merge $merges times under an unreadable domain declaration"
  assert_output_has "$dir" FM_LANDING_VENUE_INVALID domain-unreadable
  pass "a malformed landing domain declaration refuses fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_malformed_venue_configuration() {
  local dir merges
  dir=$(new_pr_case venue-malformed)
  configure_raw_venue "$dir" '{not-json'
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "venue-malformed: malformed venue configuration must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "venue-malformed: the forge was asked to merge $merges times under malformed configuration"
  assert_output_has "$dir" FM_LANDING_VENUE_INVALID venue-malformed
  pass "malformed sol-control configuration refuses fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_venue_configuration_missing_repo() {
  local dir merges
  dir=$(new_pr_case venue-missing-repo)
  configure_raw_venue "$dir" '{"issue":2,"landing_domain":{"repos":[]}}'
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "venue-missing-repo: incomplete venue configuration must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "venue-missing-repo: the forge was asked to merge $merges times under incomplete configuration"
  assert_output_has "$dir" FM_LANDING_VENUE_INVALID venue-missing-repo
  pass "sol-control configuration missing repo refuses fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_multi_segment_domain_repositories() {
  local dir merges repo
  for repo in github.com/owner/repo owner/repo/extra; do
    dir=$(new_pr_case "domain-shape-${repo//\//-}")
    configure_venue "$dir" "[\"$repo\"]"
    run_pr_merge "$dir"
    [ "$RC" -ne 0 ] || fail "domain-shape: $repo must be rejected as malformed, got exit 0"
    merges=$(merge_count "$dir")
    [ "$merges" -eq 0 ] || fail "domain-shape: the forge was asked to merge $merges times with malformed repository $repo"
    assert_output_has "$dir" FM_LANDING_VENUE_INVALID domain-shape
  done
  pass "multi-segment landing-domain repositories refuse fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_invalid_venue_field_types() {
  local dir merges config label
  while IFS='|' read -r label config; do
    dir=$(new_pr_case "venue-schema-$label")
    configure_raw_venue "$dir" "$config"
    run_pr_merge "$dir"
    [ "$RC" -ne 0 ] || fail "venue-schema-$label: invalid venue configuration must refuse the merge, got exit 0"
    merges=$(merge_count "$dir")
    [ "$merges" -eq 0 ] || fail "venue-schema-$label: the forge was asked to merge $merges times under invalid configuration"
    assert_output_has "$dir" FM_LANDING_VENUE_INVALID "venue-schema-$label"
  done <<'EOF'
repo-object|{"repo":{},"issue":2,"landing_domain":{"repos":[]}}
issue-boolean|{"repo":"owner/control","issue":true,"landing_domain":{"repos":[]}}
repo-extra-component|{"repo":"host/owner/control","issue":2,"landing_domain":{"repos":[]}}
domain-non-string|{"repo":"owner/control","issue":2,"landing_domain":{"repos":[7]}}
unknown-key|{"repo":"owner/control","issue":2,"landing_domain":{"repos":[]},"extra":true}
EOF
  pass "invalid typed and extended venue configurations refuse fm-pr-merge (merges executed: 0)"
}

test_pr_merge_lands_when_the_landing_domain_is_declared_empty() {
  local dir merges
  # An empty domain is a complete positive answer on its own: it contains nothing,
  # so no candidate can be inside it. This is how a home keeps a Sol venue for
  # review correspondence without placing any landing under it.
  dir=$(new_pr_case domain-empty)
  configure_venue "$dir" '[]'
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "domain-empty: an empty landing domain must not block, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "domain-empty: the forge was asked to merge $merges times, expected exactly 1"
  assert_output_has "$dir" 'declares an empty Browser Sol landing domain' domain-empty
  pass "an explicitly empty landing domain lands through fm-pr-merge (merges executed: $merges)"
}

test_pr_merge_matches_the_landing_domain_case_insensitively() {
  local dir merges
  # A forge path is case-insensitive, so a case difference that read as a
  # different repository would shed the domain by renaming nothing at all.
  dir=$(new_pr_case domain-case)
  configure_venue "$dir" '["Owner/Demo"]'
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "domain-case: a case difference must not shed the declared domain, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "domain-case: the forge was asked to merge $merges times after a case difference shed the domain"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING domain-case
  pass "a case difference does not put a candidate outside the declared landing domain (merges executed: 0)"
}

test_pr_merge_matches_a_mixed_case_candidate_against_the_domain() {
  local dir merges
  # The other half of the comparison. The case above varies the DECLARATION's
  # case; this varies the CANDIDATE's, which is what a hand-typed pull request
  # url actually supplies. Both directions have to fold to the same repository or
  # the domain is shed by how somebody typed a link.
  dir=$(new_pr_case domain-case-candidate)
  configure_venue "$dir" "[\"$PR_REPO_PATH\"]"
  run_pr_merge_at "$dir" "$MIXED_CASE_PR_URL"
  [ "$RC" -ne 0 ] || fail "domain-case-candidate: a mixed-case candidate must not shed the declared domain, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "domain-case-candidate: the forge was asked to merge $merges times after a mixed-case candidate shed the domain"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING domain-case-candidate
  pass "a mixed-case candidate repository is still matched against the declared landing domain (merges executed: 0)"
}

test_pr_merge_lands_an_in_domain_candidate_under_a_valid_ruling() {
  local dir merges auths
  # Non-vacuity INSIDE the domain. Every refusal above is satisfied by a gate that
  # refuses everything in a governed repository; this is the case that is not.
  dir=$(new_pr_case in-domain-ruled)
  configure_venue "$dir" "[\"$PR_REPO_PATH\"]"
  write_correlation "$dir" ruled accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "in-domain-ruled: an approved ruling in the governed domain must land, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "in-domain-ruled: the forge was asked to merge $merges times, expected exactly 1"
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c ' spent$')" -eq 1 ] \
    || fail "in-domain-ruled: expected exactly one spent authorization, got [$auths]"
  pass "an approved ruling inside the declared landing domain lands and spends its authority (merges executed: $merges, authorizations spent: 1)"
}

test_pr_merge_lands_when_no_control_venue_is_configured() {
  local dir merges
  dir=$(new_pr_case no-venue)
  rm -f "$dir/home/config/sol-control.json"
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "no-venue: expected the merge to proceed, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "no-venue: the forge was asked to merge $merges times, expected exactly 1"
  assert_output_has "$dir" 'no Browser Sol control venue is configured' no-venue
  pass "a home with no control venue lands and names the missing venue (merges executed: $merges)"
}

test_pr_merge_refuses_a_governed_candidate_with_no_ruling() {
  local dir merges
  dir=$(new_pr_case governed-unruled)
  # The one perturbation: a live review request for this exact item and head that
  # has not been ruled on. Everything else is the fixture that lands in (d).
  write_correlation "$dir" emitted '' "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-unruled: an unruled review gate must refuse the merge, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "governed-unruled: the forge was asked to merge $merges times despite an unruled review gate"
  assert_output_has "$dir" FM_LANDING_AUTHORIZATION_REFUSED governed-unruled
  pass "an unruled Browser Sol review gate refuses the real fm-pr-merge path (merges executed: 0)"
}

test_pr_merge_lands_a_governed_candidate_under_a_valid_ruling() {
  local dir merges auths
  dir=$(new_pr_case governed-ruled)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "governed-ruled: an approved ruling must land, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "governed-ruled: the forge was asked to merge $merges times, expected exactly 1"
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c ' spent$')" -eq 1 ] \
    || fail "governed-ruled: expected exactly one spent authorization, got [$auths]"
  grep -qE '^landing_authorization=fm-auth-[0-9a-f]{32}$' "$dir/home/state/$TASK_ID.meta" \
    || fail "governed-ruled: the merge record does not name the authorization it spent"
  pass "an approved ruling lands through fm-pr-merge and spends its authority (merges executed: $merges, authorizations spent: 1)"
}

test_pr_merge_refuses_a_second_landing_under_a_spent_authority() {
  local dir first second auths
  dir=$(new_pr_case governed-replay)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "governed-replay: the first landing must succeed, got exit $RC: $(cat "$dir/stderr")"
  first=$(merge_count "$dir")
  [ "$first" -eq 1 ] || fail "governed-replay: the first landing merged $first times, expected exactly 1"
  # The one perturbation: nothing at all. The same command, the same ruling, the
  # same head - and the authority is now exhausted.
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-replay: a spent authority must refuse the second landing, got exit 0"
  second=$(merge_count "$dir")
  [ "$second" -eq 1 ] \
    || fail "governed-replay: the forge was asked to merge $second times across two attempts, expected exactly 1"
  assert_output_has "$dir" FM_LANDING_ACT_NOT_PERFORMED governed-replay
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c .)" -eq 1 ] \
    || fail "governed-replay: a replay minted a second authority: [$auths]"
  pass "a spent landing authority refuses a replayed fm-pr-merge (merges executed across two attempts: $second)"
}

test_pr_merge_refuses_a_head_the_ruling_never_approved() {
  local dir merges
  dir=$(new_pr_case governed-moved-head "$HEAD_B")
  # The one perturbation from (d): the ruling approves HEAD_A while the pull
  # request now carries HEAD_B. Governance attaches to the item and survives the
  # move; the authority does not.
  write_correlation "$dir" ruled accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-moved-head: a head the ruling never approved must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "governed-moved-head: the forge was asked to merge $merges times on an unapproved head"
  assert_output_has "$dir" FM_LANDING_HEAD_NOT_APPROVED governed-moved-head
  [ "$(auth_count "$dir")" -eq 0 ] \
    || fail "governed-moved-head: an authorization was minted for a head no ruling approved"
  pass "a head no ruling approved refuses fm-pr-merge rather than falling through as ungoverned (merges executed: 0)"
}

test_pr_merge_refuses_a_declining_ruling() {
  local dir merges
  dir=$(new_pr_case governed-declined)
  write_correlation "$dir" ruled rejected "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-declined: a rejecting ruling must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "governed-declined: the forge was asked to merge $merges times under a rejecting ruling"
  assert_output_has "$dir" FM_AUTH_VERDICT_DECLINED governed-declined
  pass "a rejecting ruling refuses the real fm-pr-merge path (merges executed: 0)"
}

test_pr_merge_refuses_a_verdict_it_cannot_classify() {
  local dir merges
  dir=$(new_pr_case governed-revise)
  # REVISE is neither approving nor declining. An unknown word must never be read
  # as approval, and it must be reported as could-not-observe rather than as a
  # refusal, because closing a vocabulary gap is a different repair from
  # respecting a decision.
  write_correlation "$dir" ruled REVISE "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-revise: an unclassifiable verdict must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "governed-revise: the forge was asked to merge $merges times on an unclassifiable verdict"
  assert_output_has "$dir" FM_AUTH_VERDICT_UNRECOGNIZED governed-revise
  pass "a ruling verdict this fleet cannot classify refuses fm-pr-merge (merges executed: 0)"
}

test_pr_merge_refuses_an_unreadable_correlation_record() {
  local dir merges
  dir=$(new_pr_case unreadable-record)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  printf 'not json at all\n' > "$dir/home/data/outbound-artifacts/$REQUEST_ID.json"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "unreadable-record: an unreadable record must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "unreadable-record: the forge was asked to merge $merges times over an unreadable record"
  assert_output_has "$dir" FM_LANDING_RECORD_UNREADABLE unreadable-record
  pass "an unreadable correlation record refuses rather than reading as an absence of rulings (merges executed: 0)"
}

test_pr_merge_refuses_live_governance_with_no_configured_venue() {
  local dir merges
  dir=$(new_pr_case governed-no-venue)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  rm -f "$dir/home/config/sol-control.json"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "governed-no-venue: live governance with no venue must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "governed-no-venue: the forge was asked to merge $merges times with no venue to resolve its ruling against"
  assert_output_has "$dir" FM_LANDING_VENUE_UNCONFIGURED governed-no-venue
  pass "a home holding live rulings and no control venue refuses rather than reading as ungoverned (merges executed: 0)"
}

test_pr_merge_keeps_its_red_head_refusal_under_a_valid_authority() {
  local dir merges auths
  dir=$(new_pr_case composed-red)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  # The one perturbation from (d): one failing check on the head. A valid landing
  # authority must not buy past the gate's own verification.
  write_rollup "$dir" "$HEAD_A" 1
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "composed-red: a red head must refuse even under a valid authority, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "composed-red: the forge was asked to merge $merges times on a red head"
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c ' spent$')" -eq 0 ] \
    || fail "composed-red: a refused merge spent its landing authority anyway: [$auths]"
  pass "a valid landing authority composes with the check-rollup guard and never replaces it (merges executed: 0)"
}

test_pr_merge_reobserves_the_head_at_the_moment_of_use() {
  local dir merges auths
  dir=$(new_pr_case reobserved-head)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  # The one perturbation from (d): the forge's pull request has moved to HEAD_B
  # while every LOCAL record - the rollup this gate verified and the ruling that
  # approved it - still names HEAD_A. Only an independent read of the forge at
  # the moment of use can see that, so this case fails outright if the spend is
  # ever satisfied by the head the caller offered.
  printf '%s\n' "$HEAD_B" > "$dir/forge_head"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "reobserved-head: a moved forge head must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "reobserved-head: the forge was asked to merge $merges times after its head moved"
  assert_output_has "$dir" FM_AUTH_STALE_HEAD reobserved-head
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c ' void$')" -eq 1 ] \
    || fail "reobserved-head: the authority for a head that moved was not retired: [$auths]"
  pass "the head is re-observed at the moment of use and a moved one refuses (merges executed: 0)"
}

test_pr_merge_refuses_two_requests_claiming_the_same_head() {
  local dir merges
  dir=$(new_pr_case ambiguous-authority)
  write_correlation "$dir" ruled accepted "$HEAD_A"
  # The one perturbation from (d): a second live request, under a different
  # landing-governing gate, claiming the same item at the same head. Picking one
  # would be choosing which authority a landing consumes on no evidence.
  write_correlation "$dir" ruled accepted "$HEAD_A" AWAITING_BROWSER_SOL "$TASK_ID" fm-ob-cafe00000000
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "ambiguous-authority: two claims on one head must refuse, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "ambiguous-authority: the forge was asked to merge $merges times under an undetermined authority"
  assert_output_has "$dir" FM_LANDING_AMBIGUOUS_AUTHORITY ambiguous-authority
  [ "$(auth_count "$dir")" -eq 0 ] \
    || fail "ambiguous-authority: an authorization was minted before the ambiguity was resolved"
  pass "two live requests claiming one head refuse rather than one being picked (merges executed: 0)"
}

test_pr_merge_lands_when_the_only_request_is_closed() {
  local dir merges
  dir=$(new_pr_case closed-request)
  # A past authority must not govern forever. Its disposition is recorded on the
  # record itself, and a home that could never land again after one closed review
  # would be a worse failure than the one this seam prevents.
  write_correlation "$dir" closed accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "closed-request: a closed request must not govern, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "closed-request: the forge was asked to merge $merges times, expected exactly 1"
  assert_output_has "$dir" FM_LANDING_NOT_APPLICABLE closed-request
  pass "a closed Browser Sol request no longer governs, and the item lands (merges executed: $merges)"
}

test_pr_merge_lands_under_a_gate_that_does_not_govern_landing() {
  local dir merges
  dir=$(new_pr_case nongoverning-gate)
  # ARCHITECTURE_RULING_REQUIRED rules on a design question rather than on this
  # head's fitness to land, and the exclusion is a decision this case pins. An
  # unruled request under it must not block the landing.
  write_correlation "$dir" emitted '' "$HEAD_A" ARCHITECTURE_RULING_REQUIRED
  run_pr_merge "$dir"
  [ "$RC" -eq 0 ] || fail "nongoverning-gate: a non-landing gate must not block, got exit $RC: $(cat "$dir/stderr")"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 1 ] || fail "nongoverning-gate: the forge was asked to merge $merges times, expected exactly 1"
  assert_output_has "$dir" FM_LANDING_NOT_APPLICABLE nongoverning-gate
  pass "a gate outside the landing-governing set does not block a landing (merges executed: $merges)"
}

test_pr_merge_refuses_an_in_domain_closed_request() {
  local dir merges
  # Governance ENDING is not the same as never having applied. Inside the declared
  # domain a closed request stops granting and does not become permission: the
  # landing needs a live request, and the refusal names the missing one rather than
  # the closed one.
  dir=$(new_pr_case in-domain-closed)
  configure_venue "$dir" "[\"$PR_REPO_PATH\"]"
  write_correlation "$dir" closed accepted "$HEAD_A"
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "in-domain-closed: a closed request must not authorise a governed-domain landing, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "in-domain-closed: the forge was asked to merge $merges times on a closed request"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING in-domain-closed
  pass "a closed request does not authorise a governed-domain landing (merges executed: 0)"
}

test_pr_merge_refuses_an_in_domain_nongoverning_gate() {
  local dir merges
  # The gate exclusion decides which gates govern, not which repositories are in
  # the domain. A record under a non-landing gate leaves the item uncovered, and
  # inside the domain an uncovered item refuses rather than reading as outside it.
  dir=$(new_pr_case in-domain-nongoverning)
  configure_venue "$dir" "[\"$PR_REPO_PATH\"]"
  write_correlation "$dir" emitted '' "$HEAD_A" ARCHITECTURE_RULING_REQUIRED
  run_pr_merge "$dir"
  [ "$RC" -ne 0 ] || fail "in-domain-nongoverning: a non-landing gate must not authorise a governed-domain landing, got exit 0"
  merges=$(merge_count "$dir")
  [ "$merges" -eq 0 ] || fail "in-domain-nongoverning: the forge was asked to merge $merges times under a gate that grants nothing"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING in-domain-nongoverning
  pass "a gate outside the landing-governing set does not authorise a governed-domain landing (merges executed: 0)"
}

# --- bin/fm-merge-local.sh ---------------------------------------------------

# A local-only task whose project is a two-commit repo: main at the base, and the
# task branch one commit ahead. The correlation record's head is that branch head,
# because that is the commit a reviewer would have been shown.
new_local_case() {  # <name> [no-remote]
  local name=$1 remote=${2:-} dir proj
  dir=$(new_home "$name") || return 1
  proj="$dir/project"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" symbolic-ref HEAD refs/heads/main
  # A real clone names the repository it pushes to, and the landing gate reads
  # that remote to ask the declared domain about the right repository. `no-remote`
  # is the deliberate opposite: a clone whose repository cannot be established.
  [ "$remote" = no-remote ] \
    || git -C "$proj" remote add origin "https://github.com/$LOCAL_REPO_PATH.git"
  git -C "$proj" config user.name 'Firstmate Tests'
  git -C "$proj" config user.email 'tests@example.invalid'
  printf 'base\n' > "$proj/tracked.txt"
  git -C "$proj" add -A
  git -C "$proj" commit -qm base
  git -C "$proj" checkout -q -b "fm/$TASK_ID"
  printf 'work\n' > "$proj/tracked.txt"
  git -C "$proj" add -A
  git -C "$proj" commit -qm work
  # The landing gate merges INTO the default branch and refuses to run from any
  # other, so the checkout goes back to main exactly as a real project's does.
  git -C "$proj" checkout -q main
  fm_write_meta "$dir/home/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$dir/wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  add_forge "$dir" "$(git -C "$proj" rev-parse "refs/heads/fm/$TASK_ID")"
  configure_venue "$dir"
  printf '%s\n' "$dir"
}

local_branch_head() { git -C "$1/project" rev-parse "refs/heads/fm/$TASK_ID"; }
local_main_head() { git -C "$1/project" rev-parse refs/heads/main; }

run_merge_local() {  # <dir>
  local dir=$1
  set +e
  ( cd "$dir" || exit 9
    FM_HOME="$dir/home" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_ROLLUP_FIXTURE="$dir/rollup.json" \
    FM_TEST_FORGE_HEAD="$dir/forge_head" \
    PATH="$dir/fakebin:$PATH" \
      "$MERGE_LOCAL" "$TASK_ID" ) > "$dir/stdout" 2> "$dir/stderr"
  RC=$?
  set -e
}

test_merge_local_lands_a_candidate_proven_outside_the_domain() {
  local dir
  # The clone names the repository it pushes to, the home declares a domain that
  # does not contain it, and that positive non-membership is what makes this
  # landing ungoverned.
  dir=$(new_local_case local-out-of-domain)
  run_merge_local "$dir"
  [ "$RC" -eq 0 ] || fail "local-out-of-domain: expected the fast-forward to proceed, got exit $RC: $(cat "$dir/stderr")"
  [ "$(local_main_head "$dir")" = "$(local_branch_head "$dir")" ] \
    || fail "local-out-of-domain: main was not fast-forwarded to the task branch"
  assert_output_has "$dir" FM_LANDING_NOT_APPLICABLE local-out-of-domain
  assert_output_has "$dir" "$LOCAL_REPO_PATH is not in this home" local-out-of-domain
  pass "a local-only task proven outside the declared landing domain lands through fm-merge-local (fast-forwards executed: 1)"
}

test_merge_local_refuses_an_in_domain_candidate_with_no_correlation() {
  local dir before
  # THE REPAIR, at the local mutation path. One perturbation from the case above:
  # this clone's repository is named in the declared domain.
  dir=$(new_local_case local-in-domain-missing)
  configure_venue "$dir" "[\"$LOCAL_REPO_PATH\"]"
  before=$(local_main_head "$dir")
  run_merge_local "$dir"
  [ "$RC" -ne 0 ] || fail "local-in-domain-missing: a governed repository with no review request must refuse the fast-forward, got exit 0"
  [ "$(local_main_head "$dir")" = "$before" ] \
    || fail "local-in-domain-missing: main moved with no authority in existence"
  assert_output_has "$dir" FM_LANDING_APPLICABLE_MISSING local-in-domain-missing
  [ "$(auth_count "$dir")" -eq 0 ] \
    || fail "local-in-domain-missing: an authorization was minted for a landing no request covers"
  pass "a governed-domain local-only task with no review request refuses the real fm-merge-local path (fast-forwards executed: 0)"
}

test_merge_local_refuses_when_its_repository_cannot_be_established() {
  local dir before
  # A clone naming no remote cannot be shown to be outside a non-empty domain, and
  # removing a remote is exactly the shape a bypass would take. Could-not-observe,
  # never an answer.
  dir=$(new_local_case local-no-repo no-remote)
  configure_venue "$dir" "[\"$LOCAL_REPO_PATH\"]"
  before=$(local_main_head "$dir")
  run_merge_local "$dir"
  [ "$RC" -ne 0 ] || fail "local-no-repo: an unestablished repository must refuse under a declared domain, got exit 0"
  [ "$(local_main_head "$dir")" = "$before" ] \
    || fail "local-no-repo: main moved without establishing which repository was being written"
  assert_output_has "$dir" FM_LANDING_CANDIDATE_REPOSITORY_UNOBSERVED local-no-repo
  pass "a local landing whose repository cannot be established refuses under a declared domain (fast-forwards executed: 0)"
}

test_merge_local_lands_with_no_repository_under_an_empty_domain() {
  local dir
  # The paired non-vacuity for the case above: an empty domain contains nothing,
  # so it needs no repository identity and the same clone lands. Without this, the
  # refusal above would be evidence about a gate that refuses remoteless clones.
  dir=$(new_local_case local-no-repo-empty no-remote)
  configure_venue "$dir" '[]'
  run_merge_local "$dir"
  [ "$RC" -eq 0 ] || fail "local-no-repo-empty: an empty domain must not need a repository identity, got exit $RC: $(cat "$dir/stderr")"
  [ "$(local_main_head "$dir")" = "$(local_branch_head "$dir")" ] \
    || fail "local-no-repo-empty: main was not fast-forwarded under an empty landing domain"
  assert_output_has "$dir" 'declares an empty Browser Sol landing domain' local-no-repo-empty
  pass "an empty landing domain lands a clone whose repository is unestablished (fast-forwards executed: 1)"
}

test_merge_local_refuses_a_governed_candidate_with_no_ruling() {
  local dir before
  dir=$(new_local_case local-governed-unruled)
  before=$(local_main_head "$dir")
  write_correlation "$dir" emitted '' "$(local_branch_head "$dir")"
  run_merge_local "$dir"
  [ "$RC" -ne 0 ] || fail "local-governed-unruled: an unruled review gate must refuse the fast-forward, got exit 0"
  [ "$(local_main_head "$dir")" = "$before" ] \
    || fail "local-governed-unruled: main moved despite an unruled review gate"
  assert_output_has "$dir" FM_LANDING_AUTHORIZATION_REFUSED local-governed-unruled
  pass "an unruled Browser Sol review gate refuses the real fm-merge-local path (fast-forwards executed: 0)"
}

test_merge_local_lands_a_governed_candidate_under_a_valid_ruling() {
  local dir auths
  dir=$(new_local_case local-governed-ruled)
  write_correlation "$dir" ruled accepted "$(local_branch_head "$dir")"
  run_merge_local "$dir"
  [ "$RC" -eq 0 ] || fail "local-governed-ruled: an approved ruling must land, got exit $RC: $(cat "$dir/stderr")"
  [ "$(local_main_head "$dir")" = "$(local_branch_head "$dir")" ] \
    || fail "local-governed-ruled: main was not fast-forwarded under a valid authority"
  auths=$(auth_states "$dir")
  [ "$(printf '%s\n' "$auths" | grep -c ' spent$')" -eq 1 ] \
    || fail "local-governed-ruled: expected exactly one spent authorization, got [$auths]"
  pass "an approved ruling lands through fm-merge-local and spends its authority (fast-forwards executed: 1, authorizations spent: 1)"
}

test_merge_local_refuses_a_second_landing_under_a_spent_authority() {
  local dir base
  dir=$(new_local_case local-governed-replay)
  base=$(local_main_head "$dir")
  write_correlation "$dir" ruled accepted "$(local_branch_head "$dir")"
  run_merge_local "$dir"
  [ "$RC" -eq 0 ] || fail "local-governed-replay: the first landing must succeed, got exit $RC: $(cat "$dir/stderr")"
  [ "$(local_main_head "$dir")" = "$(local_branch_head "$dir")" ] \
    || fail "local-governed-replay: the first landing did not fast-forward main"
  # Put main and its working tree back where they started so a second
  # fast-forward would be a real, observable landing again. The branch, the
  # ruling, and the head are untouched: the exhausted authority is the only thing
  # left that can refuse.
  #
  # The path is asserted non-empty first. A fixture helper that returned nothing
  # would otherwise turn this into a hard reset against whatever tree the tests
  # themselves are running in.
  [ -n "$dir" ] && [ -d "$dir/project/.git" ] \
    || fail "local-governed-replay: the fixture project is not where this case can safely reset it"
  git -C "$dir/project" reset -q --hard "$base"
  run_merge_local "$dir"
  [ "$RC" -ne 0 ] || fail "local-governed-replay: a spent authority must refuse the second landing, got exit 0"
  [ "$(local_main_head "$dir")" = "$base" ] \
    || fail "local-governed-replay: main moved a second time under an exhausted authority"
  assert_output_has "$dir" FM_LANDING_ACT_NOT_PERFORMED local-governed-replay
  pass "a spent landing authority refuses a replayed fm-merge-local (fast-forwards executed across two attempts: 1)"
}

# --- run ---------------------------------------------------------------------
#
# The declared control set, in order. Naming it once lets a measurement run a
# SINGLE control against a defect build, which is what a complete red matrix
# needs: this suite stops at its first failing control, so a defect that reddens
# several of them would otherwise only ever be seen reddening the earliest.
# tests/landing-seam-red-matrix.py is that measurement.
FM_CONTROLS=(
  test_pr_merge_lands_a_candidate_proven_outside_the_domain
  test_pr_merge_refuses_an_in_domain_candidate_with_no_correlation
  test_pr_merge_refuses_when_the_landing_domain_is_undeclared
  test_pr_merge_refuses_an_unreadable_landing_domain
  test_pr_merge_refuses_malformed_venue_configuration
  test_pr_merge_refuses_venue_configuration_missing_repo
  test_pr_merge_refuses_multi_segment_domain_repositories
  test_pr_merge_refuses_invalid_venue_field_types
  test_pr_merge_lands_when_the_landing_domain_is_declared_empty
  test_pr_merge_matches_the_landing_domain_case_insensitively
  test_pr_merge_matches_a_mixed_case_candidate_against_the_domain
  test_pr_merge_lands_an_in_domain_candidate_under_a_valid_ruling
  test_pr_merge_refuses_an_in_domain_closed_request
  test_pr_merge_refuses_an_in_domain_nongoverning_gate
  test_pr_merge_lands_when_no_control_venue_is_configured
  test_pr_merge_refuses_a_governed_candidate_with_no_ruling
  test_pr_merge_lands_a_governed_candidate_under_a_valid_ruling
  test_pr_merge_refuses_a_second_landing_under_a_spent_authority
  test_pr_merge_refuses_a_head_the_ruling_never_approved
  test_pr_merge_refuses_a_declining_ruling
  test_pr_merge_refuses_a_verdict_it_cannot_classify
  test_pr_merge_refuses_an_unreadable_correlation_record
  test_pr_merge_refuses_live_governance_with_no_configured_venue
  test_pr_merge_keeps_its_red_head_refusal_under_a_valid_authority
  test_pr_merge_reobserves_the_head_at_the_moment_of_use
  test_pr_merge_refuses_two_requests_claiming_the_same_head
  test_pr_merge_lands_when_the_only_request_is_closed
  test_pr_merge_lands_under_a_gate_that_does_not_govern_landing
  test_merge_local_lands_a_candidate_proven_outside_the_domain
  test_merge_local_refuses_an_in_domain_candidate_with_no_correlation
  test_merge_local_refuses_when_its_repository_cannot_be_established
  test_merge_local_lands_with_no_repository_under_an_empty_domain
  test_merge_local_refuses_a_governed_candidate_with_no_ruling
  test_merge_local_lands_a_governed_candidate_under_a_valid_ruling
  test_merge_local_refuses_a_second_landing_under_a_spent_authority
)

if [ -n "${FM_LANDING_SEAM_ONLY:-}" ]; then
  # Refused rather than silently running nothing: a measurement that selects a
  # control which does not exist would report a clean run having observed
  # nothing at all.
  for control in "${FM_CONTROLS[@]}"; do
    [ "$control" = "$FM_LANDING_SEAM_ONLY" ] && break
    control=
  done
  [ -n "$control" ] || fail "FM_LANDING_SEAM_ONLY names no declared control: $FM_LANDING_SEAM_ONLY"
  "$FM_LANDING_SEAM_ONLY"
else
  for control in "${FM_CONTROLS[@]}"; do
    "$control"
  done
  fm_test_contract "${BASH_SOURCE[0]}"
fi
