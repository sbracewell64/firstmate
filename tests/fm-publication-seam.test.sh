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

# --- fixture -----------------------------------------------------------------
#
# Every path is pinned under this suite's own temp root and asserted non-empty
# before any git command reaches it. An empty repo path would turn a fixture
# reset into a destructive command against the checkout these tests live in, and
# the two bash constructions that silently produce one are named in
# .agents/skills/firstmate-coding-guidelines/SKILL.md.

FX_HOME='' FX_CONFIG='' FX_DATA='' FX_REPO='' FX_REMOTE=''
FX_HEAD='' FX_TREE='' FX_AUTHOR=''

fixture() {  # <name>
  local name=$1
  [ -n "$name" ] || fail "fixture: no name"
  FX_HOME="$TMP_ROOT/$name/home"
  FX_CONFIG="$FX_HOME/config"
  FX_DATA="$FX_HOME/data"
  FX_REPO="$TMP_ROOT/$name/repo"
  FX_REMOTE="$TMP_ROOT/$name/remote.git"
  mkdir -p "$FX_CONFIG" "$FX_DATA" "$FX_REPO" "$FX_REMOTE" \
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
policy() {  # [<author>] [<committer>] [<generation>] [<role>]
  local author=${1:-$FX_AUTHOR}
  local committer=${2:-$FX_AUTHOR}
  local generation=${3:-pol-1}
  local role=${4:-canonical}
  jq -n --arg a "$author" --arg c "$committer" --arg g "$generation" \
        --arg v "$VENUE" --arg r "$REF" --arg i "$ITEM" --arg role "$role" \
    '{generation:$g,
      venues:{($v):{identities:{author:$a,committer:$c,delivery_actor:"fixture-actor",
                                maker:"maker/binding",reviewer:"reviewer/binding",
                                ruling:"browser-sol"},
                    work:{($r):{item:$i,role:$role}}}}}' \
    > "$FX_CONFIG/publication-identity.json" || fail "policy: could not write"
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
    bash "$GUARD" "$@" ) 2>&1
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
    git -C "$FX_REPO" push --quiet origin "$REF:$REF"
}

states() {  # -> "<id> <state>" per recorded authority
  local f
  for f in "$FX_DATA/landing-authorizations"/*.json; do
    [ -e "$f" ] || continue
    jq -r '"\(.authorization_id) \(.state)"' "$f" 2>/dev/null || printf 'unreadable\n'
  done
}

# --- (a) the green case, which every red below is one perturbation away from ---

test_publishes_one_governed_candidate_exactly_once() {
  local before after id out spent bound
  fixture green
  policy
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
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - -- \
    git -C "$FX_REPO" push --quiet origin "$REF:$REF") || rc=$?
  [ "$rc" -eq 0 ] || fail "publish: the composed operation did not complete (exit $rc): $out"
  assert_contains "$out" 'APPLIED' "publish: the composed operation reported no applied result: $out"
  after=$(tip) || fail "publish: the remote tip could not be observed"
  [ "$after" = "$FX_HEAD" ] \
    || fail "publish: the remote is at $after rather than the published head $FX_HEAD"
  pass "publish composes the decision and the act into one operation for a caller that cannot source shell"
}

test_a_refusal_relays_its_reason_rather_than_its_shape() {
  local out rc=0 after
  fixture publish-token
  policy
  record fm-ob-token emitted
  out=$(guard publish --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - -- \
    git -C "$FX_REPO" push --quiet origin "$REF:$REF") || rc=$?
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
  grant; id=$GRANT_ID
  guard consume "$id" --repo "$FX_REPO" --remote origin -- true > /dev/null 2>&1 || true
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
  grant
  # A second candidate for the SAME declared work at a different head. Which head
  # the work is cannot be settled by whichever one publishes first.
  printf 'rival\n' >> "$FX_REPO/file.txt"
  git -C "$FX_REPO" add file.txt || fail "duplicate: add"
  git -C "$FX_REPO" commit -qm rival || fail "duplicate: commit"
  rival=$(git -C "$FX_REPO" rev-parse HEAD) || fail "duplicate: head"
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
  grant; id=$GRANT_ID
  # The act runs and does not move the ref. Its exit status says nothing about
  # whether it had an effect, so the authority must not return to the pool.
  out=$(guard consume "$id" --repo "$FX_REPO" --remote origin -- true) || rc=$?
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
  local out after
  fixture ungoverned
  # No policy and no request: nothing in this home could govern this candidate.
  out=$(guard prepare --repo "$FX_REPO" --remote origin --venue "$VENUE" \
    --ref "$REF" --head "$FX_HEAD" --expected-tip - --item "$ITEM") \
    || fail "ungoverned: a publication nothing governs was not permitted: $out"
  assert_contains "$out" 'NOT_APPLICABLE' \
    "ungoverned: the result did not report that nothing governed it: $out"
  after=$(tip) || fail "ungoverned: the remote tip could not be observed"
  [ "$after" = '-' ] || fail "ungoverned: deciding applicability moved the remote to $after"
  pass "a publication nothing governs is reported as ungoverned rather than passing silently"
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

fm_test_contract "${BASH_SOURCE[0]}"
