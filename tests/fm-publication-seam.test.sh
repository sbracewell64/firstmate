#!/usr/bin/env bash
# fm-publication-seam.test.sh - a governed remote-changing publication is
# REFUSED BEFORE THE REMOTE MOVES, and the permitted one moves it exactly once.
#
# Subject: bin/fm-publication-guard.sh and bin/fm-publication-seam-lib.sh, plus
# the wiring into bin/fm-attest.sh, which is the one remote-changing publication
# this repository performs. Evidence owner:
# docs/verification/candidate-publication-effect-guard.md.
#
# THE EFFECT IS COUNTED, NEVER ASSUMED. Every case reads the remote's actual tip
# with `git ls-remote` before and after, and asserts the value it found. This
# matters more here than anywhere else in the fleet: "no bad publication
# happened" is also exactly what a completely broken guard produces, and a
# refusal asserted only from an exit code would pass just as well against a
# command that refuses everything.
#
# WHAT EACH RED IS ATTRIBUTABLE TO. Every refusal below is ONE perturbation away
# from test_publishes_one_governed_candidate_exactly_once, which runs the same
# fixture unperturbed and publishes. The perturbation is named in the test name
# and in the failure message. That pairing is what makes each refusal evidence
# about its own perturbation rather than about a mechanism that refuses
# everything - the failure mode a guard is most likely to have and least likely
# to be caught having.
#
# Matrix:
#   (a) a governed candidate with clean identity, no hold, one semantic owner,
#       fresh generations and the exact remote tip publishes ONCE
#   (b) an active publication hold refuses an otherwise valid candidate
#   (c) an authority granted while eligible refuses once a newer hold arrives
#   (d) a restarted run whose governing ruling was revoked refuses
#   (e) an unreadable correlation store is could-not-observe, not an absent hold
#   (f) a placeholder commit identity alone refuses
#   (g) a valid identity under a live must-close ruling refuses
#   (h) two actionable candidates for one semantic work refuse
#   (i) a changed ruling or policy generation refuses
#   (j) a wrong expected remote tip refuses
#   (k) a replayed authority refuses and publishes nothing
#   (l) the remote moving under a granted authority refuses without overwriting
#   (m) a remote already at the head is a typed no-effect that consumes nothing
#   (n) an authority consumed without a confirmed effect is retired, never reused
#   (o) a retained predecessor ref cannot publish while the successor can
#   (p) the real attestation path reaches the guard, and reports an ungoverned
#       publication rather than staying silent about it
#   (q) an outbound request in a state no landed vocabulary declares holds the
#       publication rather than disappearing from the answer
#   (r) a governed candidate publishes only when a ruling reviewed THIS head and
#       the register records its reviewer as qualified and assignment-distinct
#   (s) custody replication backs one exact clean candidate up to its own feature
#       ref, grants nothing, and refuses every way it could become a publication
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

FM_TEST_IDENTITY_CONTRACT=1

GUARD="$ROOT/bin/fm-publication-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-publication-seam) || exit 1

VENUE='github.com/fixture/candidate'
GATE='EXACT_HEAD_BROWSER_REVIEW_REQUIRED'
ITEM='fixture-work'
REF='refs/heads/candidate'
# The work's OWN feature ref, which is the only ref custody replication may
# address. Derived from the work exactly as the guard derives it, so a fixture
# cannot drift from the rule under test.
CUSTODY_REF="refs/heads/fm/$ITEM"

# The role qualification register this suite answers against. The CONTRACT is
# shared across fixtures because it is the same capability everywhere; the
# RECORDS are per-fixture, so a case that perturbs the reviewer's qualification
# perturbs its own and nothing leaks into the next.
QUAL_CONTRACT='publication-review-fixture'
QUAL_ADJUDICATOR='publication-adjudicator-fixture'
QUAL_CONTRACTS="$TMP_ROOT/qualification-contracts"
QUAL_NO_OVERLAY="$TMP_ROOT/qualification-no-overlay"
MAKER='maker/binding'
REVIEWER='reviewer/binding'

mkdir -p "$QUAL_CONTRACTS" || exit 1
cat > "$QUAL_CONTRACTS/$QUAL_CONTRACT.json" <<JSON
{
  "qualification_schema_version": 1,
  "id": "$QUAL_CONTRACT",
  "role": "PUBLICATION_REVIEWER",
  "risk_class": "runtime-job-v1",
  "contract_version": "1.0.0",
  "axis": "exact_change_review",
  "purpose": "A synthetic contract used only to pin publication-time review admissibility.",
  "grants": "Eligibility to review a candidate at the publication seam.",
  "does_not_grant": ["anything outside this exact contract"],
  "executable_predicate": {
    "kind": "declared_deterministic",
    "check": "bin/fm-qualification.sh",
    "expect": "QUALIFIED"
  },
  "adjudication": { "required": true, "adjudicator_contract": "$QUAL_ADJUDICATOR",
                    "independence_dimensions": ["binding"] },
  "required_freshness_dependencies": ["contract_version"]
}
JSON
# The chain has to terminate somewhere, and it terminates the way the register's
# own register does: the adjudicating contract requires no adjudication of its
# own. Without that, qualifying a reviewer needs a qualified adjudicator, which
# needs a qualified adjudicator.
cat > "$QUAL_CONTRACTS/$QUAL_ADJUDICATOR.json" <<JSON
{
  "qualification_schema_version": 1,
  "id": "$QUAL_ADJUDICATOR",
  "role": "PUBLICATION_REVIEW_ADJUDICATOR",
  "risk_class": "runtime-job-v1",
  "contract_version": "1.0.0",
  "axis": "assignment_independence",
  "purpose": "A synthetic contract used only to terminate the fixture adjudication chain.",
  "grants": "Eligibility to adjudicate a publication review qualification.",
  "does_not_grant": ["anything outside this exact contract"],
  "executable_predicate": {
    "kind": "declared_deterministic",
    "check": "bin/fm-qualification.sh",
    "expect": "QUALIFIED"
  },
  "adjudication": { "required": false, "adjudicator_contract": "$QUAL_ADJUDICATOR",
                    "independence_dimensions": ["binding"] },
  "required_freshness_dependencies": ["contract_version"]
}
JSON

# --- fixture -----------------------------------------------------------------
#
# Every path is pinned under this suite's own temp root and asserted non-empty
# before any git command reaches it. An empty repo path would turn a fixture
# reset into a destructive command against the checkout these tests live in, and
# the two bash constructions that silently produce one are named in
# .agents/skills/firstmate-coding-guidelines/SKILL.md.

FX_HOME='' FX_CONFIG='' FX_DATA='' FX_REPO='' FX_REMOTE='' FX_QUAL_RECORDS=''
FX_HEAD='' FX_TREE='' FX_AUTHOR=''

fixture() {  # <name>
  local name=$1
  [ -n "$name" ] || fail "fixture: no name"
  FX_HOME="$TMP_ROOT/$name/home"
  FX_CONFIG="$FX_HOME/config"
  FX_DATA="$FX_HOME/data"
  FX_REPO="$TMP_ROOT/$name/repo"
  FX_REMOTE="$TMP_ROOT/$name/remote.git"
  FX_QUAL_RECORDS="$TMP_ROOT/$name/qualification-records"
  mkdir -p "$FX_CONFIG" "$FX_DATA" "$FX_REPO" "$FX_REMOTE" "$FX_QUAL_RECORDS" \
    || fail "fixture: could not create $name"
  git init -q --bare "$FX_REMOTE" || fail "fixture: could not create the remote"
  git init -q -b main "$FX_REPO" || fail "fixture: could not create the repo"
  git -C "$FX_REPO" config user.name 'Fixture Maker' || fail "fixture: identity"
  git -C "$FX_REPO" config user.email 'maker@fixture.invalid' || fail "fixture: identity"
  printf 'seed\n' > "$FX_REPO/file.txt"
  git -C "$FX_REPO" add file.txt || fail "fixture: add"
  git -C "$FX_REPO" commit -qm seed || fail "fixture: commit"
  git -C "$FX_REPO" remote add origin "$FX_REMOTE" || fail "fixture: remote"
  git -C "$FX_REPO" push -q origin main || fail "fixture: seed push"
  git -C "$FX_REPO" checkout -q -b candidate || fail "fixture: branch"
  printf 'candidate\n' >> "$FX_REPO/file.txt"
  git -C "$FX_REPO" add file.txt || fail "fixture: add candidate"
  git -C "$FX_REPO" commit -qm candidate || fail "fixture: commit candidate"
  FX_HEAD=$(git -C "$FX_REPO" rev-parse HEAD) || fail "fixture: head"
  FX_TREE=$(git -C "$FX_REPO" rev-parse 'HEAD^{tree}') || fail "fixture: tree"
  # OBSERVED, not assumed. This suite runs under fm_git_identity, whose exported
  # identity outranks the repository config set above, so the governed identity
  # the policy declares is read back off the commit that actually exists.
  FX_AUTHOR=$(git -C "$FX_REPO" log -1 --format='%an <%ae>' "$FX_HEAD") \
    || fail "fixture: the fixture commit's own author could not be read"
  [ -n "$FX_AUTHOR" ] || fail "fixture: the fixture commit reported no author"
  printf '{"repo":"fixture/sol-control","issue":2}\n' > "$FX_CONFIG/sol-control.json"
}

# The identity policy, written as the whole file so a case that perturbs one axis
# perturbs exactly that axis and nothing drifts between cases.
policy() {  # [<author>] [<committer>] [<generation>] [<role>] [<contract>]
  local author=${1:-$FX_AUTHOR}
  local committer=${2:-$FX_AUTHOR}
  local generation=${3:-pol-1}
  local role=${4:-canonical}
  local contract=${5-$QUAL_CONTRACT}
  jq -n --arg a "$author" --arg c "$committer" --arg g "$generation" \
        --arg v "$VENUE" --arg r "$REF" --arg i "$ITEM" --arg role "$role" \
        --arg m "$MAKER" --arg rev "$REVIEWER" --arg k "$contract" \
    '{generation:$g,
      venues:{($v):{identities:{author:$a,committer:$c,delivery_actor:"fixture-actor",
                                maker:$m,reviewer:$rev,
                                ruling:"browser-sol"},
                    review_contracts:(if $k == "" then [] else [$k] end),
                    work:{($r):{item:$i,role:$role}}}}}' \
    > "$FX_CONFIG/publication-identity.json" || fail "policy: could not write"
  qualification QUALIFIED
}

# The reviewer's standing in the role qualification register, which is the landed
# owner of "was this binding ever observed to do this job?" and is consulted
# rather than restated. The default is the one a governed venue needs; a case
# that perturbs it passes its own result.
qualification() {  # [<result>]
  local result=${1:-QUALIFIED}
  # The register refuses a record whose id does not match its filename, so a
  # perturbed result replaces the record rather than joining it.
  rm -f "$FX_QUAL_RECORDS"/*.json
  jq --arg id "reviewer-binding-$result" --arg c "$QUAL_CONTRACT" \
     --arg m "$REVIEWER" --arg r "$result" \
     '.id = $id | .contract = $c | .binding.model = $m | .result = $r' \
    > "$FX_QUAL_RECORDS/reviewer-binding-$result.json" <<'JSON' || fail "qualification: could not write"
{
  "qualification_schema_version": 1,
  "id": "placeholder",
  "contract": "placeholder",
  "contract_version": "1.0.0",
  "role": "PUBLICATION_REVIEWER",
  "risk_class": "runtime-job-v1",
  "binding": { "provider": "reviewer", "model": "placeholder", "harness": "pi",
               "harness_version": "9.9.9", "native_effort": "high" },
  "result": "placeholder",
  "result_evidence": "the deterministic oracle graded the candidate from outside it",
  "measured_context": 120000,
  "observed_at": "2026-08-13",
  "adjudication": { "adjudicator_binding": "adjudicator/binding", "adjudicator_harness": "pi",
                    "adjudicator_result": "QUALIFIED",
                    "evidence": "the assignment-distinct evaluator graded the retained package" },
  "freshness_dependencies": [ { "kind": "contract_version", "version": "1.0.0" } ],
  "known_limitations": ["synthetic fixture material"]
}
JSON
  jq --arg id "adjudicator-binding" --arg c "$QUAL_ADJUDICATOR" \
     --arg m 'adjudicator/binding' \
     '.id = $id | .contract = $c | .binding.model = $m | .role = "PUBLICATION_REVIEW_ADJUDICATOR"
      | .result = "QUALIFIED" | .adjudication = null' \
    > "$FX_QUAL_RECORDS/adjudicator-binding.json" <<'JSON' || fail "qualification: could not write the adjudicator"
{
  "qualification_schema_version": 1,
  "id": "placeholder",
  "contract": "placeholder",
  "contract_version": "1.0.0",
  "role": "placeholder",
  "risk_class": "runtime-job-v1",
  "binding": { "provider": "adjudicator", "model": "placeholder", "harness": "pi",
               "harness_version": "9.9.9", "native_effort": "high" },
  "result": "placeholder",
  "result_evidence": "the deterministic oracle graded the candidate from outside it",
  "measured_context": 120000,
  "observed_at": "2026-08-13",
  "adjudication": null,
  "freshness_dependencies": [ { "kind": "contract_version", "version": "1.0.0" } ],
  "known_limitations": ["synthetic fixture material"]
}
JSON
}

# The review itself: a ruling bound to THIS exact head. Separate from policy() on
# purpose - a governed venue is configuration, and a review is evidence about one
# candidate. Conflating the two is the defect the publication seam now refuses.
reviewed() {  # [<head>] [<request-id>]
  record "${2:-fm-ob-reviewed}" ruled approved "${1:-$FX_HEAD}"
}

record() {  # <request-id> <state> [<verdict>] [<head>]
  local rid=$1 state=$2 verdict=${3:-} head=${4:-$FX_HEAD}
  mkdir -p "$FX_DATA/outbound-artifacts" || fail "record: mkdir"
  jq -n --arg rid "$rid" --arg gate "$GATE" --arg item "$ITEM" --arg head "$head" \
        --arg state "$state" --arg verdict "$verdict" \
    '{schema:"fm-outbound-artifact.v1",request_id:$rid,channel:"sol-control",
      identity:{gate:$gate,project:"fixture",repo:"fixture/sol-control",item:$item,
                pr:null,head:$head,head_source:"local"},
      venue:"fixture/sol-control#2",state:$state,comment_id:"1",attempts:1,
      created:"2026-08-22T00:00:00Z",updated:"2026-08-22T00:00:00Z",
      ruling:(if $verdict == "" then null else {comment_id:"9001",verdict:$verdict} end),
      resumed:null,disposition:null,superseded_by:null}' \
    > "$FX_DATA/outbound-artifacts/$rid.json" || fail "record: could not write"
}

guard() {  # <args...>
  ( export FM_HOME="$FX_HOME" FM_CONFIG_OVERRIDE="$FX_CONFIG" FM_DATA_OVERRIDE="$FX_DATA"
    export FM_QUALIFICATION_CONTRACT_DIR="$QUAL_CONTRACTS"
    export FM_QUALIFICATION_RECORD_DIR="$FX_QUAL_RECORDS"
    export FM_QUALIFICATION_OVERLAY_DIR="$QUAL_NO_OVERLAY"
    bash "$GUARD" "$@" ) 2>&1
}

reject_pushes() {
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FX_REMOTE/hooks/pre-receive" \
    || fail "reject-pushes: write"
  chmod +x "$FX_REMOTE/hooks/pre-receive" || fail "reject-pushes: chmod"
}

tip() {  # -> the remote's current tip for the candidate ref, or "-"
  local out
  out=$(git -C "$FX_REPO" ls-remote "$FX_REMOTE" "$REF" 2>/dev/null) || return 1
  [ -n "$out" ] || { printf -- '-\n'; return 0; }
  printf '%s\n' "$out" | awk 'NF {print $1; exit}'
}

# Grant an authority for the current fixture into GRANT_ID.
#
# The result is a GLOBAL rather than stdout on purpose: `fail` inside a command
# substitution kills only the subshell, so a grant that failed would hand its
# caller an empty string and the suite would go on to test the wrong thing. That
# is exactly how this helper failed the first time it ran.
GRANT_ID=
grant() {
  local out
  GRANT_ID=
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -)
  GRANT_ID=$(printf '%s\n' "$out" | awk '$1=="ALLOW_EXACT" {print $2; exit}')
  [ -n "$GRANT_ID" ] || fail "grant: the fixture was expected to be publishable: $out"
}

# Spend an authority by publishing the candidate through it, and echo the result.
spend() {  # <auth-id>
  guard consume "$1" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF"
}

states() {  # -> "<id> <state>" per recorded authority
  local f
  for f in "$FX_DATA/landing-authorizations"/*.json; do
    [ -e "$f" ] || continue
    jq -r '"\(.authorization_id) \(.state)"' "$f" 2>/dev/null || printf 'unreadable\n'
  done
}

claim_fixture() {
  local id=$1 pid=$2 identity=$3 group=$4 dir
  dir="$FX_DATA/landing-authorizations/.$id.claim"
  mkdir "$dir" || fail "claim-fixture: mkdir"
  printf '%s\n' "$pid" > "$dir/owner-pid" || fail "claim-fixture: pid"
  printf '%s\n' "$identity" > "$dir/owner-identity" || fail "claim-fixture: identity"
  printf '%s\n' "$group" > "$dir/owner-group" || fail "claim-fixture: group"
}

claim_intent_fixture() {
  local id=$1 pid=$2 identity=$3 group=$4 dir
  dir="$FX_DATA/landing-authorizations/.$id.claim"
  jq -n --arg pid "$pid" --arg identity "$identity" --arg group "$group" \
    '{schema:"fm-publication-claim-reclaim.v1",owner_pid:$pid,
      owner_identity:$identity,owner_group:$group}' \
    > "$dir/reclaim-intent.json" || fail "claim-intent-fixture: write"
}

# --- (a) the green case, which every red below is one perturbation away from ---

test_publishes_one_governed_candidate_exactly_once() {
  local before after id out spent bound
  fixture green
  policy
  reviewed
  before=$(tip) || fail "green: the remote tip could not be observed before"
  [ "$before" = '-' ] || fail "green: the fixture remote already had $REF at $before"

  grant; id=$GRANT_ID
  out=$(spend "$id") || fail "green: the permitted publication did not complete: $out"
  assert_contains "$out" 'APPLIED' "green: the publication reported no applied result: $out"

  after=$(tip) || fail "green: the remote tip could not be observed after"
  [ "$after" = "$FX_HEAD" ] \
    || fail "green: the remote is at $after rather than the published head $FX_HEAD"

  spent=$(states | awk '$2=="spent"' | wc -l | tr -d '[:space:]')
  [ "$spent" = 1 ] || fail "green: expected exactly one spent authority, got [$(states | tr '\n' ';')]"

  # The spent authority names the exact subject it was granted for, so a later
  # reader can say which head and which tree this publication carried.
  bound=$(jq -r '"\(.grant.head) \(.grant.tree)"' \
    "$FX_DATA/landing-authorizations/$id.json" 2>/dev/null) \
    || fail "green: the spent authority could not be read back"
  [ "$bound" = "$FX_HEAD $FX_TREE" ] \
    || fail "green: the authority binds '$bound' rather than the published head and tree '$FX_HEAD $FX_TREE'"
  pass "a governed candidate with clean identity, no hold and the exact tip publishes exactly once"
}

# --- (a2) the intent survives into the outcome ---------------------------------

test_the_spent_record_keeps_the_intent_written_before_the_act() {
  local id record events
  fixture intent
  policy
  reviewed
  grant; id=$GRANT_ID
  spend "$id" > /dev/null || fail "intent: the permitted publication did not complete"
  record="$FX_DATA/landing-authorizations/$id.json"

  # The outcome is written ON TOP of the intent. An implementation that rebuilt
  # the record from the copy it read BEFORE the intent would still report
  # `spent`, and would silently drop the one field that says when this authority
  # was committed to an act - which is the entire reason the intent is written
  # first. So the assertion is on the intent, not on the state.
  [ -n "$(jq -r '.spend.intent // ""' "$record" 2>/dev/null)" ] \
    || fail "intent: the spent record carries no record of the intent written before the act: $(cat "$record")"
  [ -n "$(jq -r '.spend.by // ""' "$record" 2>/dev/null)" ] \
    || fail "intent: the spent record does not name what committed the act"
  events=$(jq -r '[.history[].event] | join(",")' "$record" 2>/dev/null)
  [ "$events" = 'intent-recorded,effect-confirmed' ] \
    || fail "intent: the history reads '$events' rather than the intent followed by its confirmation"
  assert_contains "$(jq -r '.spend.evidence // ""' "$record")" "$FX_HEAD" \
    "intent: the outcome does not name the remote observation that confirmed it"
  pass "the spent record keeps the intent written before the act, not just the outcome"
}

# --- (a3) the composed operation, and the token it relays ----------------------

test_publish_composes_the_decision_and_the_act() {
  local out rc=0 after
  fixture publish-cmd
  policy
  reviewed
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 0 ] || fail "publish: the composed operation did not complete (exit $rc): $out"
  assert_contains "$out" 'APPLIED' "publish: the composed operation reported no applied result: $out"
  assert_not_contains "$out" 'NOT_APPLICABLE' \
    "publish: a governed publication was reported as ungoverned: $out"
  after=$(tip) || fail "publish: the remote tip could not be observed"
  [ "$after" = "$FX_HEAD" ] \
    || fail "publish: the remote is at $after rather than the published head $FX_HEAD"
  pass "publish composes the decision and the act into one operation for a caller that cannot source shell"
}

test_refuses_commands_other_than_the_constructed_push() {
  local id out rc=0 after
  fixture command-shape
  policy
  reviewed
  grant; id=$GRANT_ID
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    sh -c "git -C '$FX_REPO' push origin '$FX_HEAD:$REF'") || rc=$?
  [ "$rc" -eq 3 ] || fail "command-shape: a shell wrapper was accepted (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_COMMAND_MISMATCH' "command-shape: wrapper refusal: $out"
  rc=0
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF" "$FX_HEAD:refs/heads/other") || rc=$?
  [ "$rc" -eq 3 ] || fail "command-shape: a second ref was accepted (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_COMMAND_MISMATCH' "command-shape: second-ref refusal: $out"
  rc=0
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push --force origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 3 ] || fail "command-shape: a force flag was accepted (exit $rc): $out"
  after=$(tip) || fail "command-shape: tip"
  [ "$after" = '-' ] || fail "command-shape: a refused command moved the remote to $after"
  spend "$id" > /dev/null || fail "command-shape: the constructed command was refused"
  pass "only the constructed single-ref non-forcing push is accepted"
}

test_uses_the_fixed_trusted_git_instead_of_caller_resolution() {
  local id marker record path digest
  fixture trusted-git
  policy
  reviewed
  grant; id=$GRANT_ID
  marker="$FX_HOME/caller-git-ran"
  mkdir -p "$FX_HOME/fakebin" || fail "trusted-git: mkdir"
  printf '%s\n' '#!/usr/bin/env bash' "printf invoked > '$marker'" > "$FX_HOME/fakebin/git" \
    || fail "trusted-git: fake"
  chmod +x "$FX_HOME/fakebin/git" || fail "trusted-git: chmod"
  # This function is intentionally never invoked because its non-invocation is the assertion.
  # shellcheck disable=SC2329
  git() { printf invoked > "$marker"; }
  export -f git
  PATH="$FX_HOME/fakebin:$PATH" spend "$id" > /dev/null \
    || fail "trusted-git: the trusted executable did not perform the push"
  unset -f git
  [ ! -e "$marker" ] || fail "trusted-git: caller-controlled Git resolution was invoked"
  record="$FX_DATA/landing-authorizations/$id.json"
  path=$(jq -r '.spend.executable.path // ""' "$record")
  digest=$(jq -r '.spend.executable.digest // ""' "$record")
  [ "${path#/}" != "$path" ] && [ -x "$path" ] || fail "trusted-git: no absolute executable was recorded"
  [ -n "$digest" ] && [ "$digest" = "$("$path" hash-object --no-filters "$path")" ] \
    || fail "trusted-git: the recorded executable digest does not identify its content"
  pass "caller functions and PATH shims cannot replace the recorded trusted Git executable"
}

test_authority_binds_the_remote_name_and_push_destination() {
  local id other out rc=0 after
  fixture remote-other
  policy
  reviewed
  grant; id=$GRANT_ID
  other="$TMP_ROOT/remote-other/other.git"
  git init -q --bare "$other" || fail "remote-other: init"
  git -C "$FX_REPO" remote add other "$other" || fail "remote-other: add"
  out=$(guard consume "$id" --repo "$FX_REPO" --remote other -- \
    git -C "$FX_REPO" push other "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 3 ] || fail "remote-other: another remote was accepted (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_REMOTE_MISMATCH' "remote-other: $out"
  after=$(git -C "$FX_REPO" ls-remote "$other" "$REF")
  [ -z "$after" ] || fail "remote-other: mismatched remote moved: $after"
  spend "$id" > /dev/null || fail "remote-other: the recorded remote positive control failed"

  fixture remote-repointed
  policy
  reviewed
  grant; id=$GRANT_ID
  other="$TMP_ROOT/remote-repointed/other.git"
  git init -q --bare "$other" || fail "remote-repointed: init"
  git -C "$FX_REPO" remote set-url --push origin "$other" || fail "remote-repointed: set-url"
  rc=0
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "remote-repointed: changed push URL was accepted (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_REMOTE_MISMATCH' "remote-repointed: $out"

  fixture remote-unresolved
  policy
  reviewed
  grant; id=$GRANT_ID
  git -C "$FX_REPO" remote remove origin || fail "remote-unresolved: remove"
  rc=0
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 4 ] || fail "remote-unresolved: missing remote exited $rc: $out"
  assert_contains "$out" 'FM_PUB_REMOTE_UNRESOLVED' "remote-unresolved: $out"
  pass "publication authorities bind remote names and resolved push destinations"
}

test_remote_credentials_are_never_persisted_or_emitted() {
  local secret url out rc=0 named_id direct_id suffix
  fixture remote-credentials
  policy
  reviewed
  secret='publication-secret-alpha'
  url="https://fixture:$secret@example.invalid/repo"
  out=$(guard prepare --repo "$FX_REPO" --remote "$url" --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "remote-credentials: direct credential URL exited $rc: $out"
  assert_contains "$out" 'FM_PUB_REMOTE_CREDENTIALS' "remote-credentials: $out"
  assert_not_contains "$out" "$secret" "remote-credentials: direct credential emitted: $out"

  for suffix in "?access_token=$secret" "#$secret"; do
    rc=0
    url="https://example.invalid/repo.git$suffix"
    out=$(guard prepare --repo "$FX_REPO" --remote "$url" --venue "$VENUE" \
      --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
    [ "$rc" -eq 3 ] || fail "remote-credentials: decorated URL exited $rc: $out"
    assert_contains "$out" 'FM_PUB_REMOTE_CREDENTIALS' "remote-credentials: $out"
    assert_not_contains "$out" "$secret" "remote-credentials: decorated credential emitted: $out"
  done

  url="https://fixture:$secret@example.invalid/repo"
  git -C "$FX_REPO" remote set-url --push origin "$url" || fail "remote-credentials: set-url"
  rc=0
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "remote-credentials: configured credential URL exited $rc: $out"
  assert_contains "$out" 'FM_PUB_REMOTE_CREDENTIALS' "remote-credentials: $out"
  assert_not_contains "$out" "$secret" "remote-credentials: configured credential emitted: $out"
  [ ! -d "$FX_DATA/landing-authorizations" ] \
    || ! rg -F "$secret" "$FX_DATA/landing-authorizations" >/dev/null \
    || fail "remote-credentials: raw URL persisted"

  git -C "$FX_REPO" remote set-url --push origin "$FX_REMOTE" || fail "remote-credentials: restore"
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || fail "remote-credentials: clean name: $out"
  named_id=$(printf '%s\n' "$out" | awk '$1=="ALLOW_EXACT" {print $2; exit}')
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote "$FX_REMOTE" --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || fail "remote-credentials: clean URL: $out"
  direct_id=$(printf '%s\n' "$out" | awk '$1=="ALLOW_EXACT" {print $2; exit}')
  [ -n "$named_id" ] && [ "$named_id" = "$direct_id" ] \
    || fail "remote-credentials: clean name and URL identities differ: $named_id $direct_id"

  git -C "$FX_REPO" remote set-url --push origin 'ext::unparseable publication remote' \
    || fail "remote-credentials: unparseable set-url"
  rc=0
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 4 ] || fail "remote-credentials: unparseable URL exited $rc: $out"
  assert_contains "$out" 'FM_PUB_REMOTE_UNRESOLVED' "remote-credentials: $out"
  pass "publication remotes refuse credentials and bind one canonical identity"
}

test_push_output_is_sanitized_bounded_and_recorded() {
  local id out rc=0 record response secret
  fixture push-output-rejection
  policy
  reviewed
  grant; id=$GRANT_ID
  secret='server-output-secret'
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' 'policy rejected https://fixture:$secret@example.invalid/repo' >&2" \
    'exit 1' > "$FX_REMOTE/hooks/pre-receive" || fail "push-output-rejection: hook"
  chmod +x "$FX_REMOTE/hooks/pre-receive" || fail "push-output-rejection: chmod"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 4 ] || fail "push-output-rejection: exit $rc: $out"
  assert_contains "$out" 'policy rejected https://example.invalid/repo' "push-output-rejection: $out"
  assert_not_contains "$out" "$secret" "push-output-rejection: secret emitted: $out"
  record="$FX_DATA/landing-authorizations/$id.json"
  response=$(jq -r '.spend.output // ""' "$record")
  assert_contains "$response" 'policy rejected https://example.invalid/repo' "push-output-rejection: $response"
  assert_not_contains "$response" "$secret" "push-output-rejection: secret recorded: $response"
  [ "$(printf '%s' "$response" | wc -c | tr -d '[:space:]')" -le 65536 ] \
    || fail "push-output-rejection: response exceeded its bound"

  fixture push-output-success
  policy
  reviewed
  grant; id=$GRANT_ID
  spend "$id" > /dev/null || fail "push-output-success: push failed"
  response=$(jq -r '.spend.output // ""' "$FX_DATA/landing-authorizations/$id.json")
  [ -n "$response" ] || fail "push-output-success: server response was not retained"
  pass "push responses are sanitized, bounded and recorded on failure and success"
}

test_concurrent_consumers_execute_exactly_one_push() {
  local id first second first_rc=0 second_rc=0 count successes refusals i
  fixture concurrent-consume
  policy
  reviewed
  grant; id=$GRANT_ID
  printf '%s\n' '#!/usr/bin/env bash' "printf x >> '$FX_DATA/push-count'" 'sleep 2' 'exit 0' \
    > "$FX_REMOTE/hooks/pre-receive" || fail "concurrent-consume: hook"
  chmod +x "$FX_REMOTE/hooks/pre-receive" || fail "concurrent-consume: chmod"
  guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF" > "$FX_DATA/first.out" 2>&1 &
  first=$!
  fm_test_reap "$first"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -d "$FX_DATA/landing-authorizations/.$id.claim" ] && break
    sleep 0.1
  done
  guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF" > "$FX_DATA/second.out" 2>&1 &
  second=$!
  fm_test_reap "$second"
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  successes=0 refusals=0
  [ "$first_rc" -eq 0 ] && successes=$(( successes + 1 ))
  [ "$second_rc" -eq 0 ] && successes=$(( successes + 1 ))
  [ "$first_rc" -eq 3 ] && refusals=$(( refusals + 1 ))
  [ "$second_rc" -eq 3 ] && refusals=$(( refusals + 1 ))
  count=$(wc -c < "$FX_DATA/push-count" | tr -d '[:space:]')
  [ "$successes" -eq 1 ] && [ "$refusals" -eq 1 ] && [ "$count" -eq 1 ] \
    || fail "concurrent-consume: rc=$first_rc,$second_rc pushes=$count first=$(cat "$FX_DATA/first.out") second=$(cat "$FX_DATA/second.out")"
  pass "two concurrent consumers execute one push and refuse the other"
}

test_reclaims_a_dead_owner_before_spending_a_granted_authority() {
  local id out
  fixture dead-claim
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999991 dead-owner 99999991
  out=$(spend "$id") || fail "dead-claim: a provably dead claim was not reclaimed: $out"
  assert_contains "$out" 'APPLIED' "dead-claim: $out"
  [ "$(tip)" = "$FX_HEAD" ] || fail "dead-claim: the publication did not execute"
  pass "a dead owner's claim beside a granted authority is reclaimed"
}

test_does_not_reclaim_a_live_owner() {
  local id out rc=0 identity group
  fixture live-claim
  policy
  reviewed
  grant; id=$GRANT_ID
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$$") || fail "live-claim: identity"
  group=$(ps -o pgid= -p "$$" | tr -d '[:space:]') || fail "live-claim: group"
  claim_fixture "$id" "$$" "$identity" "$group"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "live-claim: live owner exited $rc: $out"
  assert_contains "$out" 'FM_PUB_IN_FLIGHT' "live-claim: $out"
  [ "$(tip)" = '-' ] || fail "live-claim: the publication executed"
  pass "a live owner's claim stays in flight"
}

test_reclaims_a_reused_owner_pid_with_a_different_identity() {
  local id out group
  fixture reused-pid-claim
  policy
  reviewed
  grant; id=$GRANT_ID
  group=$(ps -o pgid= -p "$$" | tr -d '[:space:]') || fail "reused-pid-claim: group"
  claim_fixture "$id" "$$" stale-process-identity "$group"
  out=$(spend "$id") || fail "reused-pid-claim: a reused pid was not reclaimed: $out"
  assert_contains "$out" 'APPLIED' "reused-pid-claim: $out"
  [ "$(tip)" = "$FX_HEAD" ] || fail "reused-pid-claim: the publication did not execute"
  pass "a reused owner pid with a different identity is dead"
}

test_refuses_to_reclaim_an_unreadable_owner_record() {
  local id out rc=0 dir
  fixture unreadable-claim
  policy
  reviewed
  grant; id=$GRANT_ID
  dir="$FX_DATA/landing-authorizations/.$id.claim"
  mkdir "$dir" || fail "unreadable-claim: mkdir"
  printf '%s\n' 99999992 > "$dir/owner-pid" || fail "unreadable-claim: pid"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 4 ] || fail "unreadable-claim: unreadable owner exited $rc: $out"
  assert_contains "$out" 'FM_PUB_CLAIM_OWNER_UNOBSERVED' "unreadable-claim: $out"
  [ "$(tip)" = '-' ] || fail "unreadable-claim: the publication executed"
  pass "an unreadable claim owner is could-not-observe"
}

test_process_table_failure_is_could_not_observe() {
  local id out rc=0 fakebin
  fixture process-table-unobserved
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999994 dead-owner 99999994
  fakebin="$FX_HOME/fakebin"
  mkdir "$fakebin" || fail "process-table-unobserved: fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 2' > "$fakebin/ps" \
    || fail "process-table-unobserved: ps"
  chmod +x "$fakebin/ps" || fail "process-table-unobserved: chmod"
  out=$(PATH="$fakebin:$PATH" spend "$id") || rc=$?
  [ "$rc" -eq 4 ] || fail "process-table-unobserved: ps failure exited $rc: $out"
  assert_contains "$out" 'FM_PUB_CLAIM_OWNER_UNOBSERVED' "process-table-unobserved: $out"
  [ -d "$FX_DATA/landing-authorizations/.$id.claim" ] \
    || fail "process-table-unobserved: the claim was reclaimed"
  [ "$(tip)" = '-' ] || fail "process-table-unobserved: the publication executed"
  pass "a process-table observation failure is could-not-observe"
}

test_recovers_a_reclaim_interrupted_after_intent() {
  local id out
  fixture reclaim-after-intent
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999995 dead-owner 99999995
  claim_intent_fixture "$id" 99999995 dead-owner 99999995
  out=$(spend "$id") || fail "reclaim-after-intent: recovery failed: $out"
  assert_contains "$out" 'APPLIED' "reclaim-after-intent: $out"
  [ "$(tip)" = "$FX_HEAD" ] || fail "reclaim-after-intent: the publication did not execute"
  pass "a reclaim interrupted after its durable intent resumes"
}

test_recovers_a_reclaim_interrupted_while_removing_owner_files() {
  local id out dir
  fixture reclaim-mid-removal
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999996 dead-owner 99999996
  claim_intent_fixture "$id" 99999996 dead-owner 99999996
  dir="$FX_DATA/landing-authorizations/.$id.claim"
  rm -f "$dir/owner-identity" "$dir/owner-group"
  out=$(spend "$id") || fail "reclaim-mid-removal: recovery failed: $out"
  assert_contains "$out" 'APPLIED' "reclaim-mid-removal: $out"
  [ "$(tip)" = "$FX_HEAD" ] || fail "reclaim-mid-removal: the publication did not execute"
  pass "a reclaim interrupted during owner-file removal resumes from intent"
}

test_unknown_reclaim_marker_is_could_not_observe() {
  local id out rc=0 dir
  fixture unknown-reclaim-marker
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999997 dead-owner 99999997
  dir="$FX_DATA/landing-authorizations/.$id.claim"
  mkdir "$dir/reclaiming" || fail "unknown-reclaim-marker: marker"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 4 ] || fail "unknown-reclaim-marker: unknown marker exited $rc: $out"
  assert_contains "$out" 'FM_PUB_CLAIM_OWNER_UNOBSERVED' "unknown-reclaim-marker: $out"
  [ -d "$dir/reclaiming" ] || fail "unknown-reclaim-marker: the marker was removed"
  [ "$(tip)" = '-' ] || fail "unknown-reclaim-marker: the publication executed"
  pass "an unknown reclaim marker is could-not-observe"
}

test_concurrent_dead_claim_reclaimers_execute_exactly_one_push() {
  local id first second first_rc=0 second_rc=0 count successes
  fixture concurrent-dead-claim
  policy
  reviewed
  grant; id=$GRANT_ID
  claim_fixture "$id" 99999993 dead-owner 99999993
  printf '%s\n' '#!/usr/bin/env bash' "printf x >> '$FX_DATA/push-count'" 'sleep 1' 'exit 0' \
    > "$FX_REMOTE/hooks/pre-receive" || fail "concurrent-dead-claim: hook"
  chmod +x "$FX_REMOTE/hooks/pre-receive" || fail "concurrent-dead-claim: chmod"
  spend "$id" > "$FX_DATA/first.out" 2>&1 &
  first=$!
  fm_test_reap "$first"
  spend "$id" > "$FX_DATA/second.out" 2>&1 &
  second=$!
  fm_test_reap "$second"
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  successes=0
  [ "$first_rc" -eq 0 ] && successes=$(( successes + 1 ))
  [ "$second_rc" -eq 0 ] && successes=$(( successes + 1 ))
  count=$(wc -c < "$FX_DATA/push-count" | tr -d '[:space:]')
  [ "$successes" -eq 1 ] && [ "$count" -eq 1 ] \
    || fail "concurrent-dead-claim: rc=$first_rc,$second_rc pushes=$count first=$(cat "$FX_DATA/first.out") second=$(cat "$FX_DATA/second.out")"
  pass "two dead-claim reclaimers execute exactly one publication"
}

test_a_refusal_relays_its_reason_rather_than_its_shape() {
  local out rc=0 after
  fixture publish-token
  policy
  record fm-ob-token emitted
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 3 ] || fail "token: a held publication did not refuse (exit $rc): $out"
  # THE REASON, NOT THE SHAPE. The guard prints `REFUSE <token>`, so a wiring
  # that read the first field relayed the literal word `REFUSE` as the token -
  # naming the shape of the answer instead of what was wrong, to every caller
  # that repeats it.
  assert_contains "$out" 'REFUSE FM_PUB_ACTIVE_HOLD' \
    "token: the refusal relayed its shape rather than its reason: $out"
  assert_not_contains "$out" 'REFUSE REFUSE' \
    "token: the refusal doubled its own verdict word instead of naming the reason: $out"
  after=$(tip) || fail "token: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "token: the remote moved to $after under an active hold"
  pass "a refusal relayed through the composed operation names its reason, not its shape"
}

# --- (a4) a probe must not mint --------------------------------------------------

test_a_dry_run_compiles_the_same_verdict_and_writes_nothing() {
  local dry real before after
  fixture dry-run
  policy
  reviewed
  before=$(states | wc -l | tr -d '[:space:]')
  dry=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) \
    || fail "dry-run: a permitted candidate was not compiled: $dry"
  assert_contains "$dry" 'ALLOW_EXACT' "dry-run: the verdict was not compiled: $dry"
  after=$(states | wc -l | tr -d '[:space:]')
  # THE POINT. `prepare` is side-effect-free only on the paths where it refuses,
  # so a probe written to expect a refusal silently becomes a mint on the day
  # that refusal stops firing - leaving a live one-use authority behind exactly
  # when nobody wanted one.
  [ "$before" = "$after" ] \
    || fail "dry-run: a probe minted an authority ($before -> $after): [$(states | tr '\n' ';')]"

  # And it is the SAME verdict, not a weaker one: the identity is deterministic,
  # so the id a dry run names is the id a real prepare grants.
  real=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) \
    || fail "dry-run: the real prepare did not complete: $real"
  # Both captures carry the command's stderr too, so the id is read off the
  # verdict line rather than off whichever line happens to come first.
  [ "$(printf '%s\n' "$dry" | awk '$1=="ALLOW_EXACT"{print $2; exit}')" \
    = "$(printf '%s\n' "$real" | awk '$1=="ALLOW_EXACT"{print $2; exit}')" ] \
    || fail "dry-run: the dry run named a different authority than the real one granted: '$dry' vs '$real'"
  pass "a dry run compiles the same verdict, names the same authority, and writes nothing"
}

# --- (a5) retiring an authority that must never be spent -----------------------
#
# The repair for a mistaken grant is a RECORDED retirement, never a deletion and
# never a hand edit. These cases assert what the record still says afterwards,
# not merely that the state changed, because a repair that discards the evidence
# of what it repaired is the failure this store exists to prevent.

test_retiring_a_granted_authority_preserves_its_whole_record() {
  local id record before after
  fixture retire
  policy
  reviewed
  grant; id=$GRANT_ID
  record="$FX_DATA/landing-authorizations/$id.json"
  before=$(jq -S '.grant, .subject, .epoch, .minted, .request_id' "$record") \
    || fail "retire: the granted record could not be read"

  guard retire "$id" --reason 'minted by a probe and must never be spent' > /dev/null \
    || fail "retire: a granted authority could not be retired"

  [ "$(jq -r '.state' "$record")" = void ] || fail "retire: the authority is not void: $(jq -r '.state' "$record")"
  after=$(jq -S '.grant, .subject, .epoch, .minted, .request_id' "$record") \
    || fail "retire: the retired record could not be read"
  [ "$before" = "$after" ] \
    || fail "retire: retirement changed what the record says it authorized: '$before' vs '$after'"
  assert_contains "$(jq -r '.void_reason // ""' "$record")" 'must never be spent' \
    "retire: the record does not say why it was retired"
  [ "$(jq -r '[.history[] | select(.event=="retired")] | length' "$record")" = 1 ] \
    || fail "retire: the retirement is not recorded once in the history: $(jq -c '.history' "$record")"
  pass "retiring a granted authority preserves its whole record and says why"
}

test_a_retired_authority_cannot_be_consumed_and_moves_nothing() {
  local id out rc=0 after fresh
  fixture retire-consume
  policy
  reviewed
  grant; id=$GRANT_ID
  guard retire "$id" --reason 'superseded before use' > /dev/null \
    || fail "retire-consume: the authority could not be retired"

  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "retire-consume: a retired authority was accepted (exit $rc): $out"
  after=$(tip) || fail "retire-consume: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "retire-consume: the remote moved to $after under a retired authority"

  # REPLAY CANNOT RESURRECT IT. A fresh grant for the same unchanged subject is a
  # DIFFERENT authority, so recovery still works while the retired one stays
  # retired - the property that keeps the retirement from wedging the lane.
  grant; fresh=$GRANT_ID
  [ "$fresh" != "$id" ] \
    || fail "retire-consume: a fresh grant reproduced the retired authority $id"
  [ "$(guard status "$id")" = void ] \
    || fail "retire-consume: the retired authority did not stay void"
  pass "a retired authority cannot be consumed, moves nothing, and is not resurrected by a fresh grant"
}

test_retiring_is_idempotent_and_records_it_once() {
  local id record first out
  fixture retire-twice
  policy
  reviewed
  grant; id=$GRANT_ID
  record="$FX_DATA/landing-authorizations/$id.json"
  guard retire "$id" --reason 'first' > /dev/null || fail "retire-twice: the first retirement failed"
  first=$(cat "$record") || fail "retire-twice: the retired record could not be read"

  out=$(guard retire "$id" --reason 'second') \
    || fail "retire-twice: repeating the retirement failed: $out"
  assert_contains "$out" 'already retired' "retire-twice: the repeat did not report the record was already retired: $out"
  [ "$first" = "$(cat "$record")" ] \
    || fail "retire-twice: repeating the retirement changed the record"
  pass "retiring the same record again reports it and accumulates no second entry"
}

test_retire_refuses_an_authority_that_records_an_act() {
  local id out rc=0
  fixture retire-spent
  policy
  reviewed
  grant; id=$GRANT_ID
  spend "$id" > /dev/null || fail "retire-spent: the publication did not complete"
  out=$(guard retire "$id" --reason 'tidy up') || rc=$?
  [ "$rc" -eq 3 ] || fail "retire-spent: a spent authority was retired (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_NOT_RETIRABLE' "retire-spent: the refusal did not name the rule: $out"
  [ "$(guard status "$id")" = spent ] || fail "retire-spent: the spent record did not stay spent"
  pass "retiring refuses an authority that records an act that happened"
}

test_retire_refuses_an_authority_whose_effect_is_unobserved() {
  local id out rc=0
  fixture retire-indeterminate
  policy
  reviewed
  grant; id=$GRANT_ID
  reject_pushes
  guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF" > /dev/null 2>&1 || true
  out=$(guard retire "$id" --reason 'tidy up') || rc=$?
  [ "$rc" -eq 3 ] || fail "retire-indeterminate: an unobserved effect was retired (exit $rc): $out"
  assert_contains "$out" 'reconcile' "retire-indeterminate: the refusal did not name the owner that settles it: $out"
  [ "$(guard status "$id")" = indeterminate ] \
    || fail "retire-indeterminate: the record did not stay indeterminate"
  pass "retiring refuses an authority whose effect is unobserved, leaving it for reconciliation"
}

# --- (b) an active publication hold -------------------------------------------

test_refuses_a_candidate_under_an_active_publication_hold() {
  local out rc=0 after
  fixture hold
  policy
  record fm-ob-hold emitted
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "hold: an active publication hold did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_ACTIVE_HOLD' "hold: the refusal did not name the hold: $out"
  after=$(tip) || fail "hold: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "hold: the remote moved to $after under an active hold"
  pass "an active publication hold refuses an otherwise valid candidate before the remote moves"
}

# --- (c) commissioned eligible, then a newer hold --------------------------------

test_refuses_once_a_newer_hold_arrives_after_the_authority_was_granted() {
  local id out rc=0 after
  fixture newer-hold
  policy
  reviewed
  grant; id=$GRANT_ID
  # The hold lands between the grant and the act, which is the window a guard
  # that only asked at commission time would publish straight through.
  record fm-ob-late emitted
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "newer-hold: a hold arriving after the grant did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_ACTIVE_HOLD' "newer-hold: the refusal did not name the hold: $out"
  after=$(tip) || fail "newer-hold: the remote tip could not be observed"
  [ "$after" = '-' ] \
    || fail "newer-hold: the remote moved to $after under a hold that arrived after the grant"
  pass "an authority granted while eligible refuses once a newer hold arrives before the act"
}

# --- (d) a restart after the governing ruling was revoked ----------------------

test_refuses_a_restarted_run_whose_ruling_was_revoked() {
  local id out rc=0 after
  fixture revoked
  policy
  record fm-ob-rule ruled approved
  grant; id=$GRANT_ID
  # The restart: the ruling that granted this authority is replaced by one that
  # declines, exactly as a REVISE or a quarantine would arrive.
  record fm-ob-rule ruled declined
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "revoked: a revoked ruling did not refuse the restarted run (exit $rc): $out"
  after=$(tip) || fail "revoked: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "revoked: the remote moved to $after after its ruling was revoked"
  pass "a restarted run whose governing ruling was revoked refuses rather than resuming"
}

# --- (e) the hold could not be observed ----------------------------------------

test_cannot_observe_a_hold_when_the_record_store_is_unreadable() {
  local out rc=0 after
  fixture unreadable
  policy
  record fm-ob-unreadable emitted
  printf 'not json\n' > "$FX_DATA/outbound-artifacts/fm-ob-unreadable.json"
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 4 ] \
    || fail "unreadable: an unreadable correlation record must be could-not-observe, not a verdict (exit $rc): $out"
  assert_contains "$out" 'CNO' "unreadable: the result was not reported as could-not-observe: $out"
  after=$(tip) || fail "unreadable: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "unreadable: the remote moved to $after while a hold might have applied"
  pass "an unreadable correlation record is could-not-observe rather than an absent hold"
}

# --- (f) placeholder identity alone --------------------------------------------

test_refuses_a_placeholder_commit_identity_alone() {
  local out rc=0 after head
  fixture placeholder
  # The ONLY perturbation is who authored the commit; the policy names that same
  # placeholder, so this is not a mapping mismatch wearing a placeholder's name.
  GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com \
  GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com \
    git -C "$FX_REPO" commit -q --amend --no-edit \
    || fail "placeholder: could not rewrite the fixture identity"
  head=$(git -C "$FX_REPO" rev-parse HEAD) || fail "placeholder: head"
  FX_HEAD=$head
  policy 'Test <test@example.com>' 'Test <test@example.com>'
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "placeholder: a placeholder identity did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_IDENTITY_PLACEHOLDER' \
    "placeholder: the refusal did not name the placeholder identity: $out"
  after=$(tip) || fail "placeholder: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "placeholder: the remote moved to $after under a placeholder identity"
  pass "a placeholder commit identity refuses on its own, with every other axis clean"
}

test_refuses_an_identity_that_maps_to_no_governed_party() {
  local out rc=0
  fixture unmapped
  policy 'Someone Else <other@fixture.invalid>'
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "unmapped: an unmapped author did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_IDENTITY_UNMAPPED' \
    "unmapped: the refusal did not name the unmapped identity: $out"
  pass "a commit identity that maps to no governed party refuses"
}

# --- (g) a live must-close ruling ----------------------------------------------

test_refuses_a_valid_identity_under_a_live_must_close_ruling() {
  local out rc=0 after
  fixture must-close
  policy
  # A live request bound to a DIFFERENT head: the work is under review and this
  # head is not the one anybody approved.
  record fm-ob-mustclose ruled approved 0000000000000000000000000000000000000000
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "must-close: a live must-close ruling did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_ACTIVE_HOLD' \
    "must-close: the refusal did not name the unmet obligation: $out"
  after=$(tip) || fail "must-close: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "must-close: the remote moved to $after under a live must-close ruling"
  pass "a clean identity under a live must-close ruling refuses"
}

# --- (h) two actionable candidates for one semantic work -----------------------

test_refuses_two_actionable_candidates_for_one_semantic_work() {
  local out rc=0 rival
  fixture duplicate
  policy
  reviewed
  grant
  # A second candidate for the SAME declared work at a different head. Which head
  # the work is cannot be settled by whichever one publishes first.
  printf 'rival\n' >> "$FX_REPO/file.txt"
  git -C "$FX_REPO" add file.txt || fail "duplicate: add"
  git -C "$FX_REPO" commit -qm rival || fail "duplicate: commit"
  rival=$(git -C "$FX_REPO" rev-parse HEAD) || fail "duplicate: head"
  # The rival is REVIEWED TOO, and the first review is closed behind it, so the
  # only thing left standing between the two candidates is the live authority the
  # first one holds. Without this the rival would refuse for the unmet review it
  # does not have, and the case would stop being about two candidates at all.
  record fm-ob-reviewed closed
  reviewed "$rival" fm-ob-reviewed-rival
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$rival" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "duplicate: a second actionable candidate did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_DUPLICATE_ACTIONABLE_CANDIDATE' \
    "duplicate: the refusal did not name the rival candidate: $out"
  pass "two actionable candidates for one semantic work refuse rather than racing"
}

# --- (i) a changed ruling or policy generation ---------------------------------

test_refuses_a_changed_policy_generation() {
  local id out rc=0 after
  fixture generation
  policy
  reviewed
  grant; id=$GRANT_ID
  policy "$FX_AUTHOR" "$FX_AUTHOR" pol-2
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "generation: a bumped policy generation did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_GENERATION_CHANGED' \
    "generation: the refusal did not name the changed generation: $out"
  after=$(tip) || fail "generation: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "generation: the remote moved to $after under a stale generation"
  pass "an authority whose ruling or policy generation has since changed refuses"
}

# --- (j) a wrong expected remote tip -------------------------------------------

test_refuses_a_wrong_expected_remote_tip() {
  local out rc=0
  fixture wrong-tip
  policy
  reviewed
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" \
    --expected-tip 1111111111111111111111111111111111111111) || rc=$?
  [ "$rc" -eq 3 ] || fail "wrong-tip: a wrong expected tip did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_REMOTE_TIP_MOVED' \
    "wrong-tip: the refusal did not name the tip disagreement: $out"
  pass "a plan compiled against a tip the remote does not have refuses"
}

# --- (k) replay ----------------------------------------------------------------

test_refuses_a_replayed_authority_and_publishes_nothing() {
  local id out rc=0 before after
  fixture replay
  policy
  reviewed
  grant; id=$GRANT_ID
  spend "$id" > /dev/null || fail "replay: the first publication did not complete"
  before=$(tip) || fail "replay: the remote tip could not be observed"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "replay: a spent authority was accepted again (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_REPLAY' "replay: the refusal did not name the replay: $out"
  after=$(tip) || fail "replay: the remote tip could not be observed after"
  [ "$after" = "$before" ] || fail "replay: the remote moved from $before to $after on a replay"
  pass "a spent authority presented again refuses and publishes nothing"
}

# --- (l) the remote moved under a granted authority ----------------------------

test_refuses_unexpected_remote_movement_without_overwriting_it() {
  local id out rc=0 intruder after
  fixture moved
  policy
  reviewed
  grant; id=$GRANT_ID
  # Somebody else publishes to the same ref between the grant and the act. The
  # authority names a world in which that ref was absent, and this is no longer
  # that world.
  git -C "$FX_REPO" push -q origin "main:$REF" || fail "moved: could not move the remote"
  intruder=$(tip) || fail "moved: the remote tip could not be observed"
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "moved: unexpected remote movement did not refuse (exit $rc): $out"
  after=$(tip) || fail "moved: the remote tip could not be observed after"
  [ "$after" = "$intruder" ] \
    || fail "moved: the remote was overwritten from $intruder to $after"
  pass "a remote that moved under a granted authority refuses without overwriting it"
}

# --- (m) the typed no-effect result --------------------------------------------

test_reports_no_effect_without_consuming_an_authority() {
  local id out granted
  fixture no-effect
  policy
  reviewed
  grant; id=$GRANT_ID
  spend "$id" > /dev/null || fail "no-effect: the first publication did not complete"
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip "$FX_HEAD") \
    || fail "no-effect: a remote already at the head was not a clean result: $out"
  assert_contains "$out" 'NO_EFFECT_ALREADY_EQUAL' \
    "no-effect: a remote already at the head was not reported as a no-effect result: $out"
  granted=$(states | awk '$2=="granted"' | wc -l | tr -d '[:space:]')
  [ "$granted" = 0 ] \
    || fail "no-effect: a no-effect result minted $granted authority(s): [$(states | tr '\n' ';')]"
  pass "a remote already at the head is a typed no-effect that consumes no authority"
}

# --- (n) consumed without a confirmed effect -----------------------------------

test_retires_an_authority_consumed_without_a_confirmed_effect() {
  local id out rc=0 status after
  fixture unconfirmed
  policy
  reviewed
  grant; id=$GRANT_ID
  reject_pushes
  # The act runs and does not move the ref. Its exit status says nothing about
  # whether it had an effect, so the authority must not return to the pool.
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 4 ] \
    || fail "unconfirmed: an unconfirmed effect was not could-not-observe (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT' \
    "unconfirmed: the result did not name the unconfirmed effect: $out"
  status=$(guard status "$id") || true
  assert_contains "$status" 'indeterminate' \
    "unconfirmed: the authority did not stay indeterminate: $status"

  # Reconciled from an observation that it did not happen, it is RETIRED rather
  # than restored - the divergence from the landing authority, and the reason a
  # later effect needs a fresh authority.
  guard reconcile "$id" --observed not-applied --evidence "remote tip is still $(tip)" \
    > /dev/null || fail "unconfirmed: the reconciliation did not complete"
  status=$(guard status "$id") || true
  assert_contains "$status" 'void' "unconfirmed: a retired authority was not void: $status"
  rc=0
  out=$(spend "$id") || rc=$?
  [ "$rc" -eq 3 ] || fail "unconfirmed: a retired authority was accepted (exit $rc): $out"
  after=$(tip) || fail "unconfirmed: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "unconfirmed: the remote moved to $after under a retired authority"

  # And recovery can still proceed: a FRESH authority is granted for the same
  # unchanged subject, which is what keeps the retirement from wedging the lane.
  rm -f "$FX_REMOTE/hooks/pre-receive"
  grant; id=$GRANT_ID
  out=$(spend "$id") || fail "unconfirmed: recovery could not publish under a fresh authority: $out"
  [ "$(tip)" = "$FX_HEAD" ] || fail "unconfirmed: recovery did not publish the candidate"
  pass "an authority consumed without a confirmed effect is retired, never reused, and recovery mints a fresh one"
}

# --- (o) a retained predecessor -------------------------------------------------

test_refuses_a_retained_predecessor_ref() {
  local out rc=0
  fixture predecessor
  policy "$FX_AUTHOR" "$FX_AUTHOR" pol-1 superseded
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] || fail "predecessor: a superseded candidate did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_NOT_CANONICAL_SUCCESSOR' \
    "predecessor: the refusal did not name the successor rule: $out"
  pass "a retained predecessor ref cannot publish while only the canonical successor can"
}

# --- (p) the ungoverned publication is reported, not silent --------------------
#
# APPLICABILITY IS AN OBSERVATION. A publication nothing governs must proceed and
# must say so, and it may only say so after the record store was successfully
# enumerated. The failure this replaces is a home that looks authorised because
# nothing spoke.
#
# The wiring claim - that bin/fm-attest.sh actually REACHES this decision rather
# than pushing beside it - is proven behaviourally in tests/fm-attest.test.sh,
# where the real command runs against a real push target and its state is read
# afterwards. It is not asserted here, because nothing in this file drives that
# command.

test_reports_an_ungoverned_publication_rather_than_staying_silent() {
  local out after state
  fixture ungoverned
  # No policy and no request: nothing in this home could govern this candidate.
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - --item "$ITEM" -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") \
    || fail "ungoverned: a publication nothing governs was not permitted: $out"
  assert_contains "$out" 'NOT_APPLICABLE' \
    "ungoverned: the result did not report that nothing governed it: $out"
  assert_contains "$out" 'proceeded ungoverned' \
    "ungoverned: the confirmed effect lost its ungoverned classification: $out"
  after=$(tip) || fail "ungoverned: the remote tip could not be observed"
  [ "$after" = "$FX_HEAD" ] || fail "ungoverned: the confirmed remote tip was $after"
  state=$(states | awk 'NF {print $2; exit}')
  [ "$state" = spent ] || fail "ungoverned: the effect did not consume a one-use authority: $state"
  pass "a publication nothing governs is reported as ungoverned rather than passing silently"
}

test_unguverned_effects_refuse_unsafe_or_unconfirmed_commands() {
  local out rc=0 after
  fixture ungoverned-force
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - --item "$ITEM" -- \
    git -C "$FX_REPO" push --force origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 3 ] || fail "ungoverned-force: force was accepted (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_COMMAND_MISMATCH' "ungoverned-force: $out"
  after=$(tip) || fail "ungoverned-force: tip"
  [ "$after" = '-' ] || fail "ungoverned-force: remote moved to $after"

  fixture ungoverned-unconfirmed
  reject_pushes
  rc=0
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - --item "$ITEM" -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$REF") || rc=$?
  [ "$rc" -eq 4 ] || fail "ungoverned-unconfirmed: unconfirmed push exited $rc: $out"
  assert_not_contains "$out" 'NOT_APPLICABLE' \
    "ungoverned-unconfirmed: an unconfirmed effect was reported as completed: $out"
  after=$(tip) || fail "ungoverned-unconfirmed: tip"
  [ "$after" = '-' ] || fail "ungoverned-unconfirmed: remote moved to $after"
  pass "ungoverned effects share command validation and remote confirmation"
}

# --- (q) an outbound state no landed vocabulary declares is a hold -------------

test_an_undeclared_outbound_state_holds_rather_than_disappearing() {
  local state out rc after
  # `quarantined` is the state that actually caused this: it is written by the
  # outbound owner's quarantine path and is absent from the record vocabulary, so
  # a live-state test dropped the record and a quarantined request holding this
  # exact candidate read as no hold at all. The second value is arbitrary on
  # purpose - the rule under test is "undeclared holds", not one string.
  for state in quarantined not-a-state-this-fleet-declares; do
    fixture "undeclared-$state"
    policy
    record fm-ob-undeclared "$state"
    rc=0
    out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
      --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
    [ "$rc" -eq 3 ] \
      || fail "undeclared: a request in state '$state' did not refuse the publication (exit $rc): $out"
    assert_contains "$out" 'FM_PUB_ACTIVE_HOLD' \
      "undeclared: a request in state '$state' was not reported as a hold: $out"
    after=$(tip) || fail "undeclared: the remote tip could not be observed"
    [ "$after" = '-' ] \
      || fail "undeclared: a refused publication moved the remote to $after"
  done
  pass "an outbound request in a state no landed vocabulary declares holds the publication rather than disappearing from it"
}

# --- (r) the review, and the qualification of whoever performed it ------------
#
# THE WRONG-SUBJECT FINDING THIS CLOSES, kept as executed controls rather than as
# prose. A governed venue reached ALLOW_EXACT while the declared reviewer was
# QUALIFICATION_REQUIRED and no ruling had ever addressed the candidate's head.
# What the guard had examined was that the candidate matched a configured
# identity and target; what its verdict was credited with was that a qualified,
# assignment-distinct review of this exact head had happened. Each case below
# removes exactly one limb of that credited claim from the green fixture.

test_refuses_a_governed_candidate_that_no_ruling_has_reviewed() {
  local out rc=0 after
  fixture unreviewed
  policy
  # No ruling at all. This is the exact shape the finding was raised against: a
  # governed venue, a matching identity, an absent remote tip, and no review.
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "unreviewed: a candidate no ruling reviewed did not refuse (exit $rc): $out"
  assert_not_contains "$out" 'ALLOW_EXACT' \
    "unreviewed: a probe credited an unreviewed candidate as permitted: $out"
  assert_contains "$out" 'FM_PUB_NO_EXACT_CANDIDATE_REVIEW' \
    "unreviewed: the refusal did not name the missing review: $out"
  after=$(tip) || fail "unreviewed: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "unreviewed: the remote moved to $after with no review"
  pass "a governed candidate no ruling has reviewed at its exact head refuses rather than being credited as permitted"
}

test_refuses_a_review_by_a_reviewer_that_is_not_qualified() {
  local result out rc after
  # Every result the register can hold that is NOT a qualification. The rule under
  # test is "not QUALIFIED refuses", not one spelling of it.
  for result in QUALIFICATION_REQUIRED QUALIFICATION_STALE FAILED; do
    fixture "unqualified-$result"
    policy
    reviewed
    qualification "$result"
    rc=0
    out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
      --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
    [ "$rc" -eq 3 ] \
      || fail "unqualified: a $result reviewer did not refuse (exit $rc): $out"
    assert_not_contains "$out" 'ALLOW_EXACT' \
      "unqualified: a probe credited a $result reviewer as permitted: $out"
    assert_contains "$out" 'FM_PUB_REVIEWER_NOT_QUALIFIED' \
      "unqualified: the refusal did not name the reviewer's standing: $out"
    after=$(tip) || fail "unqualified: the remote tip could not be observed"
    [ "$after" = '-' ] \
      || fail "unqualified: the remote moved to $after under a $result reviewer"
  done
  pass "a ruling by a reviewer the register does not record as qualified refuses, whatever the register records instead"
}

test_cannot_observe_a_review_whose_reviewer_qualification_is_unreadable() {
  local out rc=0 after
  fixture qualification-unobserved
  policy
  reviewed
  qualification COULD_NOT_OBSERVE
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  # COULD-NOT-OBSERVE PROJECTS AS NON-PASS, which is the sentence the finding
  # ended on. It is kept apart from the refusal above because an operator told
  # only "not permitted" would go and argue with a register that never answered.
  [ "$rc" -eq 4 ] \
    || fail "qualification-unobserved: an unobserved qualification was not could-not-observe (exit $rc): $out"
  assert_not_contains "$out" 'ALLOW_EXACT' \
    "qualification-unobserved: a probe credited an unobserved qualification as permitted: $out"
  assert_contains "$out" 'FM_PUB_REVIEWER_QUALIFICATION_UNOBSERVED' \
    "qualification-unobserved: the result did not name what could not be observed: $out"
  after=$(tip) || fail "qualification-unobserved: the remote tip could not be observed"
  [ "$after" = '-' ] \
    || fail "qualification-unobserved: the remote moved to $after on an unobserved qualification"
  pass "a reviewer whose qualification could not be observed is could-not-observe, never a pass"
}

test_cannot_observe_a_review_the_policy_names_no_contract_for() {
  local out rc=0
  fixture contracts-undeclared
  # A governed venue that declares no review contracts has not promised a lighter
  # review; it has left unstated what its reviewer had to be qualified for.
  policy "$FX_AUTHOR" "$FX_AUTHOR" pol-1 canonical ''
  reviewed
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 4 ] \
    || fail "contracts-undeclared: an unstated review contract was not could-not-observe (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_REVIEW_CONTRACTS_UNDECLARED' \
    "contracts-undeclared: the result did not name the unstated declaration: $out"
  pass "a governed venue that declares no review contract is could-not-observe about its reviewer, not silently exempt"
}

test_one_approval_does_not_cover_for_another_unmet_obligation() {
  local out rc=0 after
  fixture one-approval
  policy
  reviewed
  # A SECOND governing request on the same work, emitted and never answered. It
  # is a live unmet obligation, and an approval given elsewhere is not an answer
  # to it - otherwise emitting a request would again be the cheapest way to
  # publish before anyone read it.
  record fm-ob-second emitted
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "one-approval: an unanswered request beside an approval did not refuse (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_ACTIVE_HOLD' \
    "one-approval: the refusal did not name the unanswered request: $out"
  assert_contains "$out" 'fm-ob-second' \
    "one-approval: the refusal did not name WHICH request still holds: $out"
  after=$(tip) || fail "one-approval: the remote tip could not be observed"
  [ "$after" = '-' ] \
    || fail "one-approval: the remote moved to $after with an obligation unmet"
  pass "an approval bound to this head does not cover for another live request that is still unanswered"
}

# --- (s) custody replication is not publication -------------------------------
#
# THE DISTINCTION THESE CONTROLS HOLD OPEN. A candidate needs to survive the
# machine it was made on, and that need had no answer except publication - which
# drags the whole review, CI and acceptance lifecycle behind it. Custody
# replication is the answer: a remote copy of one exact commit on the work's own
# feature ref, granting nothing. The cases below are the price of that grant
# being narrow: every one of them is a way the weaker act could quietly become
# the stronger one, and each is refused rather than reclassified.

custody_tip() {  # -> the remote's tip for the custody ref, or "-"
  local out
  out=$(git -C "$FX_REPO" ls-remote "$FX_REMOTE" "$CUSTODY_REF" 2>/dev/null) || return 1
  [ -n "$out" ] || { printf -- '-\n'; return 0; }
  printf '%s\n' "$out" | awk 'NF {print $1; exit}'
}

custody_grant() {  # -> GRANT_ID
  local out
  GRANT_ID=
  out=$(guard prepare --effect custody --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip - --item "$ITEM")
  GRANT_ID=$(printf '%s\n' "$out" | awk '$1=="ALLOW_EXACT" {print $2; exit}')
  [ -n "$GRANT_ID" ] || fail "custody-grant: the fixture was expected to be replicable: $out"
  assert_contains "$out" 'class=CUSTODY_REPLICATION' \
    "custody-grant: the authority was not typed as custody: $out"
}

custody_refuses() {  # <label> <expected-token> <prepare-args...>
  local label=$1 token=$2 out rc=0 before after
  shift 2
  # UNCHANGED, not absent. A case that seeds the ref deliberately is still a case
  # in which the refusal must move nothing, and asserting absence would quietly
  # skip the assertion there.
  before=$(custody_tip) || fail "$label: the custody ref could not be observed before"
  out=$(guard prepare --effect custody --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --item "$ITEM" "$@") || rc=$?
  [ "$rc" -eq 3 ] || fail "$label: the custody replication was not refused (exit $rc): $out"
  assert_contains "$out" "$token" "$label: the refusal did not name the rule: $out"
  assert_not_contains "$out" 'ALLOW_EXACT' "$label: a refused custody replication was permitted: $out"
  after=$(custody_tip) || fail "$label: the custody ref could not be observed after"
  [ "$after" = "$before" ] \
    || fail "$label: a refused custody replication moved the remote from $before to $after"
}

test_custody_replicates_an_exact_clean_candidate_and_grants_nothing() {
  local id out after
  fixture custody-green
  policy
  # NO ruling, and NO reviewer qualification beyond the default. Custody claims
  # neither, so it must not require either - a candidate that cannot be published
  # yet is exactly the one that most needs to survive this machine.
  custody_grant; id=$GRANT_ID
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$CUSTODY_REF") \
    || fail "custody-green: the permitted custody replication did not complete: $out"
  assert_contains "$out" 'CUSTODY_REPLICATION' \
    "custody-green: the completed act was not typed as custody: $out"
  after=$(custody_tip) || fail "custody-green: the custody ref could not be observed"
  [ "$after" = "$FX_HEAD" ] \
    || fail "custody-green: the custody ref is at $after rather than $FX_HEAD"
  [ "$(jq -r '.effect' "$FX_DATA/landing-authorizations/$id.json")" = custody ] \
    || fail "custody-green: the spent authority does not record itself as custody"
  pass "an exact clean candidate replicates to its own feature ref under a custody authority"
}

test_custody_refuses_a_candidate_that_is_not_the_one_here() {
  local drifted
  fixture custody-drift
  policy
  # The head named is a real commit and is not the one checked out. A clean
  # worktree says nothing about WHICH head it is clean at.
  drifted=$(git -C "$FX_REPO" rev-parse HEAD~1) || fail "custody-drift: parent"
  custody_refuses custody-drift FM_PUB_CUSTODY_CANDIDATE_DRIFT \
    --ref "$CUSTODY_REF" --head "$drifted" --expected-tip -
  pass "custody refuses a head that is not the candidate this checkout is sitting on"
}

test_custody_refuses_an_unclean_worktree() {
  local file
  for file in tracked untracked; do
    fixture "custody-dirty-$file"
    policy
    if [ "$file" = tracked ]; then
      printf 'uncommitted\n' >> "$FX_REPO/file.txt"
    else
      printf 'stray\n' > "$FX_REPO/stray.txt"
    fi
    # A backup taken from a tree with work in it records a ref carrying the
    # committed head while the work that mattered stays only on this disk.
    custody_refuses "custody-dirty-$file" FM_PUB_WORKTREE_NOT_CLEAN \
      --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip -
  done
  pass "custody refuses an unclean worktree, counting untracked files as uncommitted work"
}

test_custody_refuses_a_ref_that_is_not_this_works_own() {
  fixture custody-wrong-ref
  policy
  custody_refuses custody-wrong-ref FM_PUB_CUSTODY_REF_NOT_PERMITTED \
    --ref refs/heads/fm/some-other-task --head "$FX_HEAD" --expected-tip -
  fixture custody-plain-ref
  policy
  custody_refuses custody-plain-ref FM_PUB_CUSTODY_REF_NOT_PERMITTED \
    --ref refs/heads/anything --head "$FX_HEAD" --expected-tip -
  pass "custody refuses any ref but the one derived from the work, including another task's"
}

test_custody_refuses_a_protected_ref() {
  local ref
  # THE CASE THAT ONLY THIS RULE CATCHES, and the reason it is written this way.
  # A protected ref like refs/heads/main is ALSO refused by the permitted-ref
  # rule, because it is not the work's own ref - so a case built on main would
  # pass with the protection removed entirely and would be evidence about the
  # wrong check. What only protection catches is a home that protects a ref which
  # IS derived from the work: then the ref is permitted and must still refuse.
  fixture custody-protected-own
  policy
  jq --arg r "$CUSTODY_REF" '.protected_refs = [$r]' "$FX_CONFIG/publication-identity.json" \
    > "$FX_CONFIG/p.tmp" && mv "$FX_CONFIG/p.tmp" "$FX_CONFIG/publication-identity.json"
  custody_refuses custody-protected-own FM_PUB_PROTECTED_REF \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip -

  # A glob a home declared, over the same derived ref.
  fixture custody-protected-glob
  policy
  jq '.protected_refs = ["refs/heads/fm/*"]' "$FX_CONFIG/publication-identity.json" \
    > "$FX_CONFIG/p.tmp" && mv "$FX_CONFIG/p.tmp" "$FX_CONFIG/publication-identity.json"
  custody_refuses custody-protected-glob FM_PUB_PROTECTED_REF \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip -

  # The built-in floor. A home may ADD to the protected set and may not subtract
  # from it, so these are asserted refused without claiming this rule is the only
  # thing refusing them.
  for ref in refs/heads/main refs/heads/master; do
    fixture "custody-floor-$(printf '%s' "$ref" | tr '/' '-')"
    policy
    custody_refuses "custody-floor-$ref" FM_PUB_PROTECTED_REF \
      --ref "$ref" --head "$FX_HEAD" --expected-tip -
  done
  pass "custody refuses a protected ref even when the work's own derived ref is the protected one"
}

test_custody_refuses_every_force_form() {
  local id arg out rc after
  # The plan can be exactly right about its head and its tip and still destroy
  # history if the push carries a force, so the ACT is checked, not only the
  # subject. Asked at consume because that is the first point the act is visible.
  for arg in --force --force-with-lease --mirror --delete -f; do
    fixture "custody-force-$(printf '%s' "$arg" | tr -d '-')"
    policy
    custody_grant; id=$GRANT_ID
    rc=0
    out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
      git -C "$FX_REPO" push "$arg" origin "$FX_HEAD:$CUSTODY_REF") || rc=$?
    [ "$rc" -eq 3 ] || fail "custody-force: '$arg' was not refused (exit $rc): $out"
    assert_contains "$out" 'FM_PUB_COMMAND_MISMATCH' \
      "custody-force: the refusal of '$arg' did not name the rule: $out"
    after=$(custody_tip) || fail "custody-force: the custody ref could not be observed"
    [ "$after" = '-' ] || fail "custody-force: '$arg' moved the remote to $after"
  done
  pass "custody refuses every forcing form of the act before the remote is touched"
}

# THE FORCE AXIS, PINNED TO THE COMPONENT THAT ACTUALLY HOLDS IT.
#
# A blacklist of forbidden flags was defined in the seam library and never
# called, and the control that reported it dead was right on both counts: it was
# dead AND it was redundant. The axis is enforced by fm_pub_seam_command_matches,
# a WHITELIST admitting exactly one push shape, which refuses strictly more than
# the blacklist could - including forcing spellings no list was ever updated for,
# such as --force-if-includes. Deleting the blacklist was correct; deleting it
# without pinning the whitelist would have left the property with no regression
# test at all. This is that test, and it is a unit test of the predicate because
# the predicate is where the guarantee lives: the custody case above proves the
# axis end to end for one class, while this proves the rule itself, which both
# classes reach through the same consume-time call.
#
# THE POSITIVE CONTROL IS LOAD-BEARING rather than decorative. A whitelist that
# refused everything would satisfy every refusal below while breaking publication
# outright, so the canonical shape must be ACCEPTED in the same run for the
# refusals to carry any meaning. It is asserted first, and its failure abandons
# the case rather than reporting a green built on a vacuous check.
test_the_command_whitelist_holds_the_force_axis() {
  local out rc=0
  out=$(
    set -u
    # shellcheck source=bin/fm-publication-seam-lib.sh
    . "$ROOT/bin/fm-publication-seam-lib.sh" || { printf 'the seam library could not be sourced\n'; exit 2; }
    repo=/repo; remote=origin; head=abc123def456; ref=refs/heads/fm/candidate
    status=0
    if ! fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      git -C "$repo" push "$remote" "$head:$ref"; then
      printf 'the canonical push shape was refused, so every refusal here proves nothing\n'
      exit 1
    fi
    for flag in --force --force-with-lease --force-if-includes --prune --delete; do
      if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
        git -C "$repo" push "$remote" "$head:$ref" "$flag"; then
        printf 'accepted a forcing act carrying %s\n' "$flag"
        status=1
      fi
    done
    if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      git -C "$repo" push "$remote" --mirror; then
      printf 'accepted a mirror push\n'
      status=1
    fi
    if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      git -C "$repo" push "$remote" "+$head:$ref"; then
      printf 'accepted a + forced refspec\n'
      status=1
    fi
    if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      git -C "$repo" push "$remote" "$head:$ref" -fd; then
      printf 'accepted a short-option cluster carrying forcing letters\n'
      status=1
    fi
    if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      git -C "$repo" push "$remote" "$head:$ref" "$head:refs/heads/other"; then
      printf 'accepted a second ref in the same act\n'
      status=1
    fi
    if fm_pub_seam_command_matches "$repo" "$remote" "$head" "$ref" \
      sh -c "git -C $repo push $remote $head:$ref"; then
      printf 'accepted a wrapper that hides the act\n'
      status=1
    fi
    exit "$status"
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "the command whitelist did not hold the force axis: $out"
  pass "the command whitelist accepts the canonical act and refuses every forcing form"
}

test_custody_refuses_a_ref_another_head_already_occupies() {
  local other
  fixture custody-occupied
  policy
  # Something else is using this ref. Advancing it would be a publication of a
  # new head onto an occupied ref, which is exactly what custody is defined not
  # to be - and the reason custody never needs a force.
  other=$(git -C "$FX_REPO" rev-parse HEAD~1) || fail "custody-occupied: parent"
  git -C "$FX_REPO" push -q origin "$other:$CUSTODY_REF" || fail "custody-occupied: seed"
  # COMPILED AGAINST THE TIP THAT IS ACTUALLY THERE, so this is a caller that
  # knows the ref is occupied and is asking to advance it. Passing an absent
  # expected tip instead would be refused by the remote-moved rule, and the case
  # would be evidence about that rule rather than about this one.
  custody_refuses custody-occupied FM_PUB_CUSTODY_REF_OCCUPIED \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip "$other"
  pass "custody refuses a ref another head already occupies rather than advancing it"
}

test_custody_grants_no_publication_and_the_projection_says_so() {
  local id out before after
  fixture custody-grants-nothing
  policy
  custody_grant; id=$GRANT_ID
  guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$CUSTODY_REF" > /dev/null \
    || fail "custody-grants-nothing: the custody replication did not complete"

  # THE PROJECTION, which is the claim under test: the candidate is backed up and
  # is nothing else. Not reviewed, not qualified to publish, not authorized to
  # land, not landed.
  out=$(guard project --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") \
    || fail "custody-grants-nothing: the projection did not report reclaimable: $out"
  assert_contains "$out" 'STATE custody-replicated' \
    "custody-grants-nothing: the projection did not stop at custody: $out"
  printf '%s\n' "$out" | awk '$1=="review-published" && $2!="no" {exit 1}' \
    || fail "custody-grants-nothing: a custody replication was read as a review: $out"
  printf '%s\n' "$out" | awk '$1=="publication-qualified" && $2=="yes" {exit 1}' \
    || fail "custody-grants-nothing: a custody replication was read as publication-qualified: $out"
  printf '%s\n' "$out" | awk '$1=="landing-authorized" && $2!="no" {exit 1}' \
    || fail "custody-grants-nothing: a custody replication was read as landing authority: $out"
  printf '%s\n' "$out" | awk '$1=="landed" && $2!="no" {exit 1}' \
    || fail "custody-grants-nothing: a custody replication was read as landed: $out"

  # And the publication obligations are STILL unmet afterwards, asked of the
  # guard rather than inferred from the projection.
  before=$(custody_tip) || fail "custody-grants-nothing: the custody ref could not be observed"
  out=$(guard prepare --dry-run --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip -) && \
    fail "custody-grants-nothing: publication became permitted after a custody replication: $out"
  assert_not_contains "$out" 'ALLOW_EXACT' \
    "custody-grants-nothing: a custody replication was credited as publication permission: $out"
  after=$(custody_tip) || fail "custody-grants-nothing: the custody ref could not be observed"
  [ "$before" = "$after" ] \
    || fail "custody-grants-nothing: asking about publication moved the custody ref"
  pass "a custody replication creates no review, no publication eligibility, no landing authority and no landing"
}

test_custody_restart_is_a_typed_no_effect_that_consumes_nothing() {
  local id out states_before states_after
  fixture custody-restart
  policy
  custody_grant; id=$GRANT_ID
  guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$CUSTODY_REF" > /dev/null \
    || fail "custody-restart: the first replication did not complete"
  states_before=$(states)

  # The restart. The backup already exists at exactly this head, so there is
  # nothing to do - and nothing to spend for having done it.
  out=$(guard prepare --effect custody --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --expected-tip "$FX_HEAD" --item "$ITEM") \
    || fail "custody-restart: a repeated replication did not complete: $out"
  assert_contains "$out" 'NO_EFFECT_ALREADY_EQUAL' \
    "custody-restart: a repeated replication was not a typed no-effect: $out"
  states_after=$(states)
  [ "$states_before" = "$states_after" ] \
    || fail "custody-restart: a no-effect restart changed the authority store: '$states_before' vs '$states_after'"
  pass "a repeated custody replication of the same exact head is a typed no-effect that consumes no authority"
}

test_custody_consumed_without_a_confirmed_effect_is_reobserved_not_reused() {
  local id out rc=0 fresh
  fixture custody-unconfirmed
  policy
  custody_grant; id=$GRANT_ID
  reject_pushes
  # The act runs and does not move the ref. Its exit status says nothing about
  # whether it had an effect, so the authority must not return to the pool.
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$CUSTODY_REF") || rc=$?
  [ "$rc" -eq 4 ] \
    || fail "custody-unconfirmed: an unconfirmed custody effect was not could-not-observe (exit $rc): $out"
  assert_contains "$out" 'FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT' \
    "custody-unconfirmed: the result did not name the unconfirmed effect: $out"
  [ "$(guard status "$id")" = indeterminate ] \
    || fail "custody-unconfirmed: the record did not stay indeterminate"

  # Recovery REOBSERVES the remote and retires this authority permanently; a
  # fresh one is a different authority, so the lane is not wedged by the rule.
  guard reconcile "$id" --observed not-applied --evidence "$CUSTODY_REF absent on the remote" > /dev/null \
    || fail "custody-unconfirmed: the reconciliation failed"
  [ "$(guard status "$id")" = void ] \
    || fail "custody-unconfirmed: the reconciled authority was not retired"
  custody_grant; fresh=$GRANT_ID
  [ "$fresh" != "$id" ] \
    || fail "custody-unconfirmed: recovery reproduced the retired authority $id"
  pass "a custody authority consumed without a confirmed effect is reobserved and retired, never reused"
}

test_the_projection_answers_reclaimability_from_the_exact_head() {
  local out rc other
  # (i) verified exact-head custody is reclaimable
  fixture reclaim-exact
  policy
  custody_grant
  guard consume "$GRANT_ID" --repo "$FX_REPO" --remote origin -- \
    git -C "$FX_REPO" push origin "$FX_HEAD:$CUSTODY_REF" > /dev/null \
    || fail "reclaim-exact: the custody replication did not complete"
  rc=0
  out=$(guard project --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") || rc=$?
  [ "$rc" -eq 0 ] || fail "reclaim-exact: an exact-head backup was not reclaimable (exit $rc): $out"
  assert_contains "$out" 'reclaimable            yes' "reclaim-exact: $out"

  # (ii) the branch EXISTS at another head. Existence is not backup.
  fixture reclaim-other-head
  policy
  other=$(git -C "$FX_REPO" rev-parse HEAD~1) || fail "reclaim-other-head: parent"
  git -C "$FX_REPO" push -q origin "$other:$CUSTODY_REF" || fail "reclaim-other-head: seed"
  rc=0
  out=$(guard project --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") || rc=$?
  [ "$rc" -eq 3 ] \
    || fail "reclaim-other-head: a branch at another head was treated as a backup (exit $rc): $out"
  assert_contains "$out" 'reclaimable            no' "reclaim-other-head: $out"

  # (iii) the remote could not be reached. Not reclaimable, and a DIFFERENT
  # repair from a ref standing at the wrong head.
  fixture reclaim-unreachable
  policy
  rc=0
  out=$(guard project --repo "$FX_REPO" --remote "$TMP_ROOT/no-such-remote.git" \
    --venue "$VENUE" --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") || rc=$?
  [ "$rc" -eq 4 ] \
    || fail "reclaim-unreachable: an unreachable remote was not could-not-observe (exit $rc): $out"
  assert_contains "$out" 'reclaimable            could-not-observe' "reclaim-unreachable: $out"
  pass "a slot is reclaimable only when the remote resolves the custody ref to the exact candidate head"
}

test_the_projection_reads_review_from_this_head_not_this_work() {
  local out earlier
  fixture project-other-head
  policy
  # A live request holding this WORK at an EARLIER head. That is evidence that a
  # different candidate was submitted, and reading it as this one would report a
  # head nobody has ever seen as under review - which is exactly the shape of the
  # finding this whole seam was repaired for.
  earlier=$(git -C "$FX_REPO" rev-parse HEAD~1) || fail "project-other-head: parent"
  record fm-ob-earlier emitted '' "$earlier"
  out=$(guard project --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") || true
  printf '%s\n' "$out" | awk '$1=="review-published" && $2=="yes" {exit 1}' \
    || fail "project-other-head: a request at another head was read as this head being submitted: $out"
  assert_contains "$out" 'STATE local-only' \
    "project-other-head: the projection did not stop at local-only: $out"

  # And the same request AT this head is a review, so the control is not simply
  # a mechanism that always answers no.
  fixture project-this-head
  policy
  record fm-ob-here emitted
  out=$(guard project --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$CUSTODY_REF" --head "$FX_HEAD" --item "$ITEM") || true
  printf '%s\n' "$out" | awk '$1=="review-published" && $2=="yes" {found=1} END {exit !found}' \
    || fail "project-this-head: a request at this exact head was not read as a review: $out"
  pass "the projection reads review publication from this exact head rather than from this work"
}

# --- run -----------------------------------------------------------------------

test_publishes_one_governed_candidate_exactly_once
test_the_spent_record_keeps_the_intent_written_before_the_act
test_a_dry_run_compiles_the_same_verdict_and_writes_nothing
test_retiring_a_granted_authority_preserves_its_whole_record
test_a_retired_authority_cannot_be_consumed_and_moves_nothing
test_retiring_is_idempotent_and_records_it_once
test_retire_refuses_an_authority_that_records_an_act
test_retire_refuses_an_authority_whose_effect_is_unobserved
test_publish_composes_the_decision_and_the_act
test_refuses_commands_other_than_the_constructed_push
test_uses_the_fixed_trusted_git_instead_of_caller_resolution
test_authority_binds_the_remote_name_and_push_destination
test_remote_credentials_are_never_persisted_or_emitted
test_push_output_is_sanitized_bounded_and_recorded
test_concurrent_consumers_execute_exactly_one_push
test_reclaims_a_dead_owner_before_spending_a_granted_authority
test_does_not_reclaim_a_live_owner
test_reclaims_a_reused_owner_pid_with_a_different_identity
test_refuses_to_reclaim_an_unreadable_owner_record
test_process_table_failure_is_could_not_observe
test_recovers_a_reclaim_interrupted_after_intent
test_recovers_a_reclaim_interrupted_while_removing_owner_files
test_unknown_reclaim_marker_is_could_not_observe
test_concurrent_dead_claim_reclaimers_execute_exactly_one_push
test_a_refusal_relays_its_reason_rather_than_its_shape
test_refuses_a_candidate_under_an_active_publication_hold
test_refuses_once_a_newer_hold_arrives_after_the_authority_was_granted
test_refuses_a_restarted_run_whose_ruling_was_revoked
test_cannot_observe_a_hold_when_the_record_store_is_unreadable
test_refuses_a_placeholder_commit_identity_alone
test_refuses_an_identity_that_maps_to_no_governed_party
test_refuses_a_valid_identity_under_a_live_must_close_ruling
test_refuses_two_actionable_candidates_for_one_semantic_work
test_refuses_a_changed_policy_generation
test_refuses_a_wrong_expected_remote_tip
test_refuses_a_replayed_authority_and_publishes_nothing
test_refuses_unexpected_remote_movement_without_overwriting_it
test_reports_no_effect_without_consuming_an_authority
test_retires_an_authority_consumed_without_a_confirmed_effect
test_refuses_a_retained_predecessor_ref
test_reports_an_ungoverned_publication_rather_than_staying_silent
test_unguverned_effects_refuse_unsafe_or_unconfirmed_commands
test_an_undeclared_outbound_state_holds_rather_than_disappearing
test_refuses_a_governed_candidate_that_no_ruling_has_reviewed
test_refuses_a_review_by_a_reviewer_that_is_not_qualified
test_cannot_observe_a_review_whose_reviewer_qualification_is_unreadable
test_cannot_observe_a_review_the_policy_names_no_contract_for
test_one_approval_does_not_cover_for_another_unmet_obligation
test_custody_replicates_an_exact_clean_candidate_and_grants_nothing
test_custody_refuses_a_candidate_that_is_not_the_one_here
test_custody_refuses_an_unclean_worktree
test_custody_refuses_a_ref_that_is_not_this_works_own
test_custody_refuses_a_protected_ref
test_custody_refuses_every_force_form
test_the_command_whitelist_holds_the_force_axis
test_custody_refuses_a_ref_another_head_already_occupies
test_custody_grants_no_publication_and_the_projection_says_so
test_custody_restart_is_a_typed_no_effect_that_consumes_nothing
test_custody_consumed_without_a_confirmed_effect_is_reobserved_not_reused
test_the_projection_answers_reclaimability_from_the_exact_head
test_the_projection_reads_review_from_this_head_not_this_work

fm_test_contract "${BASH_SOURCE[0]}"
