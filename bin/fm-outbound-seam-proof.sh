#!/usr/bin/env bash
# fm-outbound-seam-proof.sh - the REAL end-to-end proof of the outbound return
# path, driven through the production binaries on a SCRATCH governed subject.
#
# WHAT THIS IS FOR, AND WHY A TEST SUITE IS NOT IT.
#
# tests/fm-outbound-artifact.test.sh proves each control can fail and fails for
# its own reason, with the forge behind a PATH shim. That is the right shape for
# a control, and it is deliberately not a proof that the SEAM works: every case
# there starts from a fixture somebody wrote, so a stage that never composes with
# its neighbour still passes. The seam is the composition - envelope, wait, typed
# ruling, exact wake, gates, mint, freshness, effect, exact-main closure,
# disposition, replay - and it is only observable by walking it once, forward,
# with each stage handed the previous stage's real output.
#
# THE EFFECT IS REAL AND THE SUBJECT IS SCRATCH. The landing this performs
# actually moves a branch, because an authorization that is never spent proves
# nothing about spending one. It moves a branch in a throwaway repository this
# script creates and deletes, on a ref no protection applies to, so a real
# mutation is observed without ever manufacturing one against protected work.
# Nothing here touches the operational home, a registered project, or a remote.
#
# Usage:
#   fm-outbound-seam-proof.sh [--root <dir>] [--keep] [--verbose]
#
#   --root     build the scratch fleet under this directory (default: mktemp -d)
#   --keep     leave the scratch fleet in place for inspection
#   --verbose  echo each command's output rather than only its verdict
#
# Exit status:
#   0  every stage of the seam was observed to hold
#   1  a stage was observed to FAIL - the seam is broken, and the failing stage
#      is named
#   4  a stage COULD NOT BE OBSERVED - a dependency is missing or the scratch
#      fleet could not be built. Never reported as a pass.
#
# THE RULING IS SUPPLIED LOCALLY, and that boundary is stated rather than
# blurred. A ruling is a comment a reviewer writes at the control venue, so
# reaching for a live one would make this proof wait on a human and stop being
# runnable on demand. What this proves is that a WELL-FORMED typed ruling drives
# the rest of the seam, and that malformed, stale and foreign ones do not; that
# the fleet reads the real venue correctly is owned by the poll controls in the
# suite and by docs/verification/outbound-transport-invariant.md.
set -u

ROOT_DIR=''
KEEP=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT_DIR=${2:-}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'fm-outbound-seam-proof: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

BIN_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
OB="$BIN_DIR/fm-outbound-artifact.sh"
AUTH="$BIN_DIR/fm-landing-authorization.sh"

STAGE=0
unobservable() { printf 'COULD-NOT-OBSERVE: %s\n' "$1" >&2; exit 4; }
broke() { printf 'FAIL [stage %s] %s\n' "$STAGE" "$1" >&2; exit 1; }
stage() { STAGE=$((STAGE + 1)); printf '\n== stage %s: %s\n' "$STAGE" "$1"; }
held() { printf '   ok  %s\n' "$1"; }
say() { [ "$VERBOSE" -eq 1 ] && printf '       %s\n' "$1"; return 0; }

for tool in git jq; do
  command -v "$tool" >/dev/null 2>&1 || unobservable "$tool is required and was not found"
done
[ -x "$OB" ] || unobservable "$OB is not executable"
[ -x "$AUTH" ] || unobservable "$AUTH is not executable"

if [ -z "$ROOT_DIR" ]; then
  ROOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-outbound-seam-proof.XXXXXX") \
    || unobservable "a scratch root could not be created"
else
  mkdir -p "$ROOT_DIR" || unobservable "the requested scratch root could not be created"
fi
cleanup() {
  if [ "$KEEP" -eq 1 ]; then printf '\nscratch fleet kept at %s\n' "$ROOT_DIR"
  else rm -rf "$ROOT_DIR"; fi
}
trap cleanup EXIT

HOME_DIR="$ROOT_DIR/home"
SUBJECT="$HOME_DIR/projects/scratch-subject"
ITEM=seam-proof-item
GATE=AWAITING_BROWSER_SOL
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/projects" "$ROOT_DIR/forge"
: > "$HOME_DIR/data/projects.md"

# --- the scratch governed subject -------------------------------------------
#
# A real repository with a real target branch and a real candidate, so the
# landing below is a real fast-forward rather than a described one.
stage 'build a scratch governed subject'
git init -q "$SUBJECT" || unobservable "the scratch subject repository could not be created"
git -C "$SUBJECT" config user.email proof@example.invalid
git -C "$SUBJECT" config user.name 'Seam Proof'
git -C "$SUBJECT" remote add origin 'https://example.invalid/scratch/subject.git'
printf 'base\n' > "$SUBJECT/f"
git -C "$SUBJECT" add f
git -C "$SUBJECT" -c commit.gpgsign=false commit -qm base
git -C "$SUBJECT" branch -M target
TARGET_BEFORE=$(git -C "$SUBJECT" rev-parse target)
git -C "$SUBJECT" checkout -q -b candidate
printf 'candidate\n' > "$SUBJECT/f"
git -C "$SUBJECT" add f
git -C "$SUBJECT" -c commit.gpgsign=false commit -qm candidate
CANDIDATE=$(git -C "$SUBJECT" rev-parse candidate)
TREE=$(git -C "$SUBJECT" rev-parse 'candidate^{tree}')
git -C "$SUBJECT" checkout -q target
[ "$TARGET_BEFORE" != "$CANDIDATE" ] \
  || unobservable "the scratch subject produced no distinct candidate"
held "target at $TARGET_BEFORE, candidate at $CANDIDATE"

# --- the scratch fleet -------------------------------------------------------
printf '{"repo":"scratch/control","issue":1}\n' > "$HOME_DIR/config/sol-control.json"
SNAP="$ROOT_DIR/snapshot.json"
jq -n --arg item "$ITEM" '
  {schema:"fm-fleet-snapshot.v1",
   backlog:{present:true,records:[
     {order:1,state:"queued",structured:true,id:$item,
      title:"scratch seam proof",hold_kind:"outbound",hold_reason:"awaiting browser sol",
      repo:"scratch-subject",pr_url:"https://github.com/scratch/subject/pull/1",
      body_excerpt:null}]}}' > "$SNAP"
# THE PULL-REQUEST REFERENCE IS NEVER CONTACTED. A landing authority is bound to
# the pull request the reviewed work sits on, so a request with none could not
# have its head re-observed at the moment of use and the authorization owner
# refuses to mint one - which is a rule worth keeping rather than working
# around. The forge shim answers every read of it, and the EFFECT this proof
# performs is the local fast-forward below, so no request ever leaves the
# machine and `scratch/subject` is a name, not a repository anyone owns.

# The forge shim. It is a shim for the VENUE only: every binding, identity,
# record write, refusal and effect below is the production path.
FAKEBIN="$ROOT_DIR/bin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SHIM'
#!/usr/bin/env bash
# Minimal `gh api` shim for the VENUE only: pull-request head reads, issue
# comment listing (plain and @base64 poll form), and comment creation. Every
# binding, identity, record write, refusal and effect in the proof is the
# production path; this stands in for the network and nothing else.
F="$FM_PROOF_FORGE"
path=
for a in "$@"; do case $a in repos/*) path=$a ;; esac; done
is_post=0
case " $* " in *" --input "*) is_post=1 ;; esac

case "$path" in
  */pulls/*)
    cat "$F/head"; exit 0 ;;
  */issues/comments/*)
    id=${path##*/}
    if [ -s "$F/ruling_id" ] && [ "$id" = "$(cat "$F/ruling_id")" ]; then
      body_file="$F/ruling_body"
    else
      body_file="$F/comment-$id.body"
      [ -f "$body_file" ] || body_file="$F/last_request_body"
    fi
    jq -n --argjson id "$id" --rawfile body "$body_file" \
      '{id:$id,issue_url:"https://api.github.com/repos/scratch/control/issues/1",body:$body}'
    exit 0 ;;
  */issues/*/comments)
    if [ "$is_post" = 1 ]; then
      payload=$(cat)
      body=$(printf '%s' "$payload" | jq -r '.body')
      rid=$(printf '%s' "$body" | sed -n 's/.*\(fm-ob-[0-9a-f]*\).*/\1/p' | head -1)
      id=$(( $(wc -l < "$F/comments") + 900 ))
      printf '%s %s\n' "$id" "$rid" >> "$F/comments"
      printf '%s\n' "$body" > "$F/last_request_body"
      printf '%s\n' "$body" > "$F/comment-$id.body"
      printf '{"id":%s}\n' "$id"
      exit 0
    fi
    want=
    prev=
    for a in "$@"; do
      case $prev in --jq) want=$(printf '%s' "$a" | sed -n 's/.*contains("\([^"]*\)").*/\1/p') ;; esac
      prev=$a
    done
    if printf '%s' "$*" | grep -q '@base64'; then
      while read -r id rid; do
        [ -n "$id" ] || continue
        body_file="$F/comment-$id.body"
        [ -f "$body_file" ] || body_file="$F/last_request_body"
        jq -nr --argjson id "$id" --rawfile body "$body_file" '[$id,$body] | @base64'
      done < "$F/comments"
      if [ -s "$F/ruling_id" ]; then
        jq -nr --argjson id "$(cat "$F/ruling_id")" --rawfile body "$F/ruling_body" \
          '[$id,$body] | @base64'
      fi
      exit 0
    fi
    while read -r id rid; do
      [ -n "$id" ] || continue
      if [ -z "$want" ] || [ "$rid" = "$want" ]; then printf '%s\n' "$id"; fi
    done < "$F/comments"
    exit 0 ;;
esac
exit 0
SHIM
chmod +x "$FAKEBIN/gh"
: > "$ROOT_DIR/forge/comments"
: > "$ROOT_DIR/forge/ruling_body"
: > "$ROOT_DIR/forge/ruling_id"
printf '%s\n' "$CANDIDATE" > "$ROOT_DIR/forge/head"

export FM_PROOF_FORGE="$ROOT_DIR/forge"
run_ob() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_OUTBOUND_SNAPSHOT="$SNAP" "$OB" "$@"
}
run_auth() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$AUTH" "$@"
}
declare_subject() {  # <head>
  # THE TREE IS READ FROM THE HEAD, never carried over from a previous one. A
  # declared tree that is not its head's is exactly what the subject validator
  # refuses, so pinning one across a corrected candidate would make this proof
  # fail for a fixture defect while reporting a governed-subject violation.
  local tree
  tree=$(git -C "$SUBJECT" rev-parse "$1^{tree}") || return 1
  mkdir -p "$HOME_DIR/data/$ITEM"
  jq -n --arg g "$GATE" --arg h "$1" --arg r scratch/subject --arg t "$tree" \
    '{gate:$g,head:$h,repo:$r,tree:$t}' > "$HOME_DIR/data/$ITEM/outbound-gate.json"
}
typed_ruling() {  # <request> <head> <decision> [<comment-id>]
  printf '%s\n' "${4:-201}" > "$ROOT_DIR/forge/ruling_id"
  cat > "$ROOT_DIR/forge/ruling_body" <<TYPED
protocol: fm-sol-control/v1
kind: ruling

in_reply_to: $1
from: browser-sol

decision: $3

expected_item: $ITEM
expected_head_sha: $2
TYPED
}

# --- stage: no wait without an envelope (clause 3) ---------------------------
stage 'a wait may not be entered before the question is asked'
declare_subject "$CANDIDATE"
if out=$(run_ob declare "$ITEM" --gate "$GATE" --head "$CANDIDATE" 2>&1); then
  broke "an unbacked wait was declared: $out"
fi
printf '%s' "$out" | grep -q FM_OUTBOUND_WAIT_UNBACKED \
  || broke "the unbacked wait was refused for the wrong reason: $out"
held 'refused before any wait existed'

# --- stage: envelope (clauses 1, 2) -----------------------------------------
stage 'emit the envelope'
out=$(run_ob emit "$ITEM" 2>&1) || broke "emit failed: $out"
say "$out"
RID=$(awk '{print $2}' "$ROOT_DIR/forge/comments" | tail -1)
[ -n "$RID" ] || broke "emit posted no identifiable request"
REC="$HOME_DIR/data/outbound-artifacts/$RID.json"
[ -r "$REC" ] || broke "emit left no durable record at $REC"
[ "$(jq -r '.identity.head' "$REC")" = "$CANDIDATE" ] \
  || broke "the request is not bound to the candidate head"
# The governed subject is not the transport venue.
[ "$(jq -r '.identity.repo' "$REC")" != "$(jq -r '.venue' "$REC" | sed 's/#.*//')" ] \
  || broke "the request names its transport venue as its governed subject"
grep -q "^exact-tree: $TREE\$" "$ROOT_DIR/forge/last_request_body" \
  || broke "the request does not state the generation it is bound to"
held "request $RID bound to $CANDIDATE, subject $(jq -r '.identity.repo' "$REC")"

# --- stage: the wait is now backed ------------------------------------------
stage 'the same wait is admitted once the question exists'
out=$(run_ob declare "$ITEM" --gate "$GATE" --head "$CANDIDATE" 2>&1) \
  || broke "a backed wait was refused: $out"
[ "$(jq -r '.request' "$HOME_DIR/data/$ITEM/outbound-gate.json")" = "$RID" ] \
  || broke "the declaration does not name the request backing it"
held 'the wait names the request that backs it'

# --- stage: only the exact ruling wakes it (clauses 4, 6) -------------------
stage 'a stale ruling does not wake the exact request'
typed_ruling "$RID" "$TARGET_BEFORE" approved 200
if out=$(run_ob ruling --request "$RID" --comment 200 --issue 1 2>&1); then
  broke "a ruling on another head was joined: $out"
fi
printf '%s' "$out" | grep -q FM_OUTBOUND_RULING_IDENTITY_MISMATCH \
  || broke "the stale ruling was refused for the wrong reason: $out"
[ "$(jq -r '.state' "$REC")" = emitted ] || broke "a refused ruling still moved the record"
held 'a ruling bound to another head changed nothing'

stage 'the exact ruling wakes it, once'
typed_ruling "$RID" "$CANDIDATE" approved 201
out=$(run_ob ruling --request "$RID" --comment 201 --issue 1 2>&1) \
  || broke "the exact ruling did not join: $out"
say "$out"
[ "$(jq -r '.state' "$REC")" = ruled ] || broke "the exact ruling did not move the record to ruled"
BEFORE_REPLAY=$(jq -S . "$REC")
run_ob ruling --request "$RID" --comment 201 --issue 1 >/dev/null 2>&1 || true
[ "$(jq -S . "$REC")" = "$BEFORE_REPLAY" ] \
  || broke "replaying the same ruling changed the record"
held 'joined once, and a replay of the same ruling changed nothing'

# --- stage: approval is not permission (clause 8) ---------------------------
stage 'approval mints a one-use authority, bound to the whole chain'
out=$(run_auth mint "$RID" --effect local-fast-forward \
  --project "$SUBJECT" --target-branch target 2>&1) || broke "mint failed: $out"
say "$out"
AUTH_ID=''
for f in "$HOME_DIR/data/landing-authorizations"/*.json; do
  [ -f "$f" ] || continue
  AUTH_ID=$(jq -r '.authorization_id' "$f"); break
done
[ -n "$AUTH_ID" ] || broke "mint left no authorization record"
AUTH_REC="$HOME_DIR/data/landing-authorizations/$AUTH_ID.json"
[ "$(jq -r '.request_id' "$AUTH_REC")" = "$RID" ] \
  || broke "the authority is not bound to the request that earned it"
[ "$(jq -r '.grant.head' "$AUTH_REC")" = "$CANDIDATE" ] \
  || broke "the authority is not bound to the reviewed head"
held "authority $AUTH_ID bound to $RID at $CANDIDATE"

# --- stage: freshness at the moment of use (clause 9) -----------------------
stage 'a head that moved after approval refuses at the moment of use'
git -C "$SUBJECT" checkout -q candidate
printf 'moved\n' > "$SUBJECT/f"
git -C "$SUBJECT" add f
git -C "$SUBJECT" -c commit.gpgsign=false commit -qm moved
MOVED=$(git -C "$SUBJECT" rev-parse candidate)
git -C "$SUBJECT" checkout -q target
if out=$(run_auth spend "$AUTH_ID" --head "$MOVED" 2>&1); then
  broke "an authority was spent against a head it never approved: $out"
fi
say "$out"
[ "$(git -C "$SUBJECT" rev-parse target)" = "$TARGET_BEFORE" ] \
  || broke "a refused spend still moved the target"
held 'refused, and the target never moved'

# --- stage: the effect (real, on the scratch subject) -----------------------
stage 'the authorized act, performed for real'
git -C "$SUBJECT" branch -f candidate "$CANDIDATE"
out=$(run_auth spend "$AUTH_ID" --head "$CANDIDATE" 2>&1) \
  || broke "the authorized spend failed: $out"
say "$out"
TARGET_AFTER=$(git -C "$SUBJECT" rev-parse target)
[ "$TARGET_AFTER" = "$CANDIDATE" ] \
  || broke "the fast-forward did not leave the target at the authorized head"
[ "$TARGET_AFTER" != "$TARGET_BEFORE" ] || broke "the target did not move at all"
held "target moved $TARGET_BEFORE -> $TARGET_AFTER"

stage 'the authority is one-use, and a replay converges without acting again'
# A REPLAY IS NOT A REFUSAL, and expecting one here was wrong. A wake that
# arrives twice must not perform the act twice, and it also must not report a
# failure for work that is already done - so an already-spent authority reports
# what it is and performs NO act. What makes it one-use is the absence of a
# second effect, which is what this measures.
out=$(run_auth spend "$AUTH_ID" --head "$CANDIDATE" 2>&1) || true
printf '%s' "$out" | grep -q 'FM_AUTH_ALREADY_SPENT' \
  || broke "a second spend did not recognise the authority as already spent: $out"
printf '%s' "$out" | grep -q 'no act performed' \
  || broke "a second spend did not report that it performed no act: $out"
[ "$(git -C "$SUBJECT" rev-parse target)" = "$TARGET_AFTER" ] \
  || broke "a replayed spend moved the target a second time"
held 'replayed without acting, and the target is unchanged'

# --- stage: exact-main closure (clause 10) ----------------------------------
stage 'closure is bound to the generation the effect produced'
out=$(run_ob resume --request "$RID" 2>&1) || broke "resume failed: $out"
if out=$(run_ob close --request "$RID" --disposition 'landed' 2>&1); then
  broke "a request that had an effect closed on prose alone: $out"
fi
printf '%s' "$out" | grep -q FM_OUTBOUND_CLOSURE_UNPROVEN \
  || broke "the unproven closure was refused for the wrong reason: $out"
if out=$(run_ob close --request "$RID" --disposition landed --authorization "$AUTH_ID" \
  --target-ref refs/heads/target --target-generation "$TARGET_BEFORE" 2>&1); then
  broke "a closure naming a generation the ref is not at was accepted: $out"
fi
out=$(run_ob close --request "$RID" --disposition landed --authorization "$AUTH_ID" \
  --target-ref refs/heads/target --target-generation "$TARGET_AFTER" 2>&1) \
  || broke "the correct post-effect closure was refused: $out"
say "$out"
[ "$(jq -r '.disposition.effect.verification' "$REC")" = exact ] \
  || broke "a fast-forward landing did not close as exactly verified"
held 'closed against the observed target generation'

# --- stage: REVISE -> correction -> a fresh envelope (clause 7) -------------
stage 'a revision retires its request and transfers nothing'
declare_subject "$MOVED"
sed -i "s/$CANDIDATE/$MOVED/" "$SNAP" 2>/dev/null || true
git -C "$SUBJECT" branch -f candidate "$MOVED"
out=$(run_ob emit "$ITEM" 2>&1) || broke "the corrected candidate could not be emitted: $out"
RID2=$(awk '{print $2}' "$ROOT_DIR/forge/comments" | tail -1)
[ -n "$RID2" ] && [ "$RID2" != "$RID" ] \
  || broke "the corrected candidate did not ask its own question"
typed_ruling "$RID2" "$MOVED" REVISE 202
run_ob ruling --request "$RID2" --comment 202 --issue 1 >/dev/null 2>&1 \
  || broke "the REVISE ruling did not join"
if out=$(run_ob resume --request "$RID2" 2>&1); then
  broke "a REVISE ruling resumed the candidate it rejected: $out"
fi
printf '%s' "$out" | grep -q FM_OUTBOUND_REVISION_REQUIRED \
  || broke "the revision was refused for the wrong reason: $out"
if out=$(run_auth mint "$RID2" --effect local-fast-forward \
  --project "$SUBJECT" --target-branch target 2>&1); then
  broke "a REVISE ruling minted a landing authority: $out"
fi
out=$(run_ob correct --request "$RID2" 2>&1) || broke "the revision could not be retired: $out"
[ "$(jq -r '.state' "$HOME_DIR/data/outbound-artifacts/$RID2.json")" = revised ] \
  || broke "the revised request was not retired"
rm -f "$HOME_DIR/data/$ITEM/outbound-gate.json"
declare_subject "$MOVED"
if out=$(run_ob declare "$ITEM" --gate "$GATE" --head "$MOVED" 2>&1); then
  broke "a retired revision still backed a wait: $out"
fi
held 'retired, granted nothing, and backs no wait'

printf '\nSEAM PROOF HELD: %s stages, effect observed on a scratch subject only\n' "$STAGE"
