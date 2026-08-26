#!/usr/bin/env bash
# fm-landing-authorization-lib.sh - the contract for a ruling-derived one-use
# EFFECT authorization: its identity, its state vocabulary, and the pure
# predicates that decide whether one may be minted and whether one may be spent.
#
# LANDING WAS THE FIRST EFFECT and gave this file its name. Candidate publication
# is the second, and it is the same authority wearing a different subject: one
# irreversible act, against one exact head, exhausted by being used. It is
# carried here rather than in a second authorization owner because a second one
# would bring its own store, its own lifecycle and its own idea of what `spent`
# means - the second control plane every boundary in this pair exists to avoid.
# The file name is now narrower than its contents; docs/vocabulary-collisions.md
# records that, and the two live meanings of "publication" it forced apart.
#
# WHY THIS EXISTS, AND WHAT IT DELIBERATELY DOES NOT DO.
#
# The inbound control plane already establishes THAT a ruling answers a given
# request. bin/fm-outbound-artifact.sh joins a Browser Sol comment to the durable
# correlation record that asked for it, refuses an unrelated one, refuses a body
# whose request marker or verdict line is ambiguous, and invalidates a record
# whose identity has moved. That mechanism owns correlation, and this one does
# not repeat any part of it - a second joiner would be the second control plane
# both halves exist to avoid. This file starts from a correlation record that is
# already `ruled` and treats establishing that state as somebody else's proven
# work.
#
# What nothing owned is the step after. A ruling that approves a landing is an
# AUTHORITY, and an authority has properties a correlation record does not: it is
# bound to one exact head, it is exhausted by being used, and using it is an
# irreversible act against the outside world. Correlation is a fact about two
# documents, so re-deriving it is free; landing is an event, so re-deriving it is
# impossible. That asymmetry is the whole reason this file exists.
#
# THE FOURTH STATE, which is the hazard this file is shaped around.
#
# A spend has three answers a later reader may reach - it was spent, it was not
# spent, or that could not be observed - and one state a careless implementation
# reaches instead: the act happened and nothing recorded it. That fourth state is
# indistinguishable from "not spent" to every later reader, so the next attempt
# lands a second time. It is reached by exactly one mistake, writing the durable
# record after the act rather than before, which is why the spend sequence writes
# INTENT first and OUTCOME second and reports the gap between them as
# could-not-observe rather than as either neighbour.
#
# A failed act sits in that same gap. A merge command that exits non-zero has not
# said the merge did not happen; it has said it reported a failure, and for an
# irreversible act those are different claims. Reading the exit status as "no
# effect" is the same substitution as reading an unreadable file as an absent
# one, so a failed act leaves the authorization indeterminate and reconcilable
# rather than silently returning it to the pool. The cost is that an ordinary
# transient failure needs an explicit reconciliation instead of a blind retry,
# and that cost is accepted: a retry that lands twice is not recoverable and a
# reconciliation that took a minute is.
#
# WHY THE HEAD IS OBSERVED AND NOT ACCEPTED.
#
# The actor spending an authorization is the party the head condition is checked
# against, so a spend that compares only the head that actor passed in has
# anchored the condition to something the checked party sets in the same act.
# The caller states its intended head and that must agree, but the binding is
# carried by an independent observation of the pull request's current head at the
# moment of use. Agreement of all three - what the ruling approved, what the
# caller intends, and what the forge currently reports - is the property; any two
# of them is one of its weaker neighbours.
#
# THE EFFECT PLAN, which is what makes the authority an authority over an ACT.
#
# THIS IS THE ONE PLACE THE EFFECT-PLAN CONTRACT IS STATED. Every other mention
# of it in this repository is a cross-reference.
#
# An earlier shape of this mechanism bound WHEN a landing could happen - one
# ruling, one exact head, one use - and left WHAT was landed to whatever argv the
# spending caller handed it. Exact-head, one-use authority over an act nobody
# named is not authority over that act: a caller holding a valid authorization
# could substitute another executable, another repository, another ref, or a
# force mode, and every check above would still pass. So an authority now carries
# a TYPED, CLOSED EFFECT PLAN, the plan is part of the authorization identity,
# and the spend CONSTRUCTS the act from the plan rather than receiving one.
#
# The plan is a closed object per effect kind. Two kinds exist, and an unknown
# kind is could-not-observe rather than a pass-through:
#
#   pr-merge             venue=github, repo=<owner>/<name>, pr=<number>,
#                        head=<exact sha>, method=squash|merge|rebase,
#                        delete_branch=yes|no, force=no,
#                        exec_name/exec_path/exec_digest
#   local-fast-forward   venue=local, project=<path as addressed>,
#                        project_identity=<resolved path>,
#                        target_ref=refs/heads/<branch>,
#                        target_head=<exact sha observed at mint>,
#                        head=<exact sha to land>,
#                        mode=ff-only, force=no,
#                        exec_name/exec_path/exec_digest
#
# Every mutation-significant field is present, every field is a single plain
# line, and the canonical rendering of those lines in a fixed order is digested
# into the authorization identity. A plan that changes therefore produces a
# different authorization, exactly as a moved head does.
#
# EXECUTABLE IDENTITY IS RESOLVED AT THE OWNING BOUNDARY, NEVER AT USE. The
# executable for each kind is a fixed name this file chooses (`gh-axi`, `git`),
# resolved once at mint to an absolute path and a content digest. The act is
# invoked by that PATH, so a later `PATH` change cannot retarget it, and the
# digest is re-read at effect time, so a file swapped at that path refuses rather
# than running. A caller never names the executable.
#
# WHAT A CALLER MAY STILL SUPPLY, and what that supply is worth. A caller may
# assert the act it believes it is authorizing. The assertion is compared element
# by element against the act this file derived, and a difference refuses before
# any mutation. It can only ever agree or stop the landing; it can never choose.
#
# FRESHNESS IS RE-OBSERVED, NOT ASSUMED. Everything in the plan that can move
# between mint and use - the executable's content, the project path's resolution,
# which branch the project has checked out, whether the plan's head is still a
# fast-forward of the target ref - is read again at effect time. What could not be
# read is could-not-observe and stops the act; what was read and disagrees is a
# refusal. Neither is a retarget.
#
# A local fast-forward is addressed at the pinned project identity after the
# mutable project alias is re-observed, but `git merge` still advances whichever
# branch is checked out. The target ref is verified immediately before the act,
# and the remaining checked-out-branch race is accepted rather than closed.
#
# A pull-request plan binds the exact head in the authority and checks it before
# the act, but does not send that head to the forge as a merge precondition.
# `gh-axi` builds its `gh` arguments from a fixed allowlist that drops
# `--match-head-commit`, and the residual window is owned by decision
# `pipeline-reports-green-on-absent-ci-decision-merge-atomic-binding`.
#
# CREDENTIAL-BEARING INPUT IS REFUSED BEFORE THE EFFECT INTERFACE. A mechanism
# field or asserted argument carrying a token, password, key, or URL userinfo is
# refused at mint and again at spend, ahead of the comparison that would
# otherwise have quoted it into a refusal message.
#
# WHAT THIS FILE DOES NOT ESTABLISH, stated so no reader credits it with more.
#
# It does not re-derive the correlation record's own identity digest, and it does
# not re-read the ruling comment. That record is the outbound owner's artifact
# and its internal integrity is that owner's to prove; this file consumes it,
# requires it to be filed under its own request id, and refuses anything it
# cannot read as the schema it expects. A correlation record that is internally
# consistent but forged is out of scope here and in scope there. A ruling edited
# on the forge after correlation is likewise not detected here.
#
# The plan binds the ACT, not the outcome. It does not establish that the forge
# will perform the merge it is asked for, nor that the executable at the pinned
# path does what its name suggests; it establishes that the act performed is the
# one the authority names and no other.

if [ -n "${FM_LANDING_AUTH_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_LANDING_AUTH_LIB_SOURCED=1

# --- contract constants ------------------------------------------------------

FM_AUTH_SCHEMA='fm-landing-authorization.v1'

# The correlation record schema this consumes. Owned by
# bin/fm-outbound-artifact-lib.sh as FM_OUTBOUND_RECORD_SCHEMA; named here as the
# version this reader accepts, so an unannounced schema change is refused as
# could-not-observe rather than parsed on a guess.
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_CORRELATION_SCHEMA='fm-outbound-artifact.v1'

# The only correlation state a landing authorization may be minted from.
# `emitted` has no ruling yet; `superseded` and `closed` are past; `resumed` has
# already moved the work on. Named positively, as one state rather than a list of
# excluded ones, so a state added to that vocabulary later is refused here rather
# than silently admitted.
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_CORRELATION_MINTABLE_STATE='ruled'

FM_AUTH_ID_PREFIX='fm-auth-'
FM_AUTH_ID_HEX_WIDTH=32

# The effects an authorization may authorize. Closed, and compared exactly: an
# effect this contract has never heard of must not reach a record, because the
# whole value of the authority is that its subject is known before it is spent.
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
#
# CUSTODY IS A THIRD EFFECT rather than a flag on publication, because the two
# grant different things and a record must say which. A custody authority backs
# one exact committed candidate up to its own unprotected feature ref; it grants
# no review, no CI, no acceptance and no landing. Spelling that as a mode of
# publication would let a record for the weaker act be read as a record for the
# stronger one, which is the exact confusion the effect field exists to prevent.
FM_AUTH_EFFECTS='landing
publication
custody'

# Authorization lifecycle.
#
#   granted   minted, unspent, and fresh as far as the last check could observe
#   spending  a spend began and its outcome is not recorded - the honest name for
#             the window in which the act may or may not have happened
#   spent     the act completed and this authority is exhausted
#   void      permanently inapplicable: the head moved, or the request it rests
#             on was superseded
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_STATES='granted
spending
spent
void'

# What a caller reads. `indeterminate` is deliberately a status a reader can
# reach and act on, not an error: it is the third value, and collapsing it into
# either neighbour is the defect this file exists to prevent.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_AUTH_STATUS_GRANTED='granted'
FM_AUTH_STATUS_SPENT='spent'
FM_AUTH_STATUS_INDETERMINATE='indeterminate'
FM_AUTH_STATUS_VOID='void'
FM_AUTH_STATUS_UNREADABLE='unreadable'
FM_AUTH_STATUS_ABSENT='absent'
}

# Stable refusal tokens. Callers and tests match these rather than prose, so the
# wording can improve without breaking a consumer.
#
# The two families are kept apart on purpose, the same distinction the inbound
# identity vocabulary already draws: a REFUSAL says a verdict was reached and it
# is no, and an UNOBSERVED says no verdict was reached at all. Both stop the act,
# so collapsing them is not unsafe - it is unreportable, and an operator told
# only "it did not work" repairs the wrong thing.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
# refusals: a verdict was reached and it is no
FM_AUTH_TOKEN_NOT_RULED=FM_AUTH_REQUEST_NOT_RULED
FM_AUTH_TOKEN_MISPLACED=FM_AUTH_CORRELATION_MISPLACED
FM_AUTH_TOKEN_ABSENT=FM_AUTH_CORRELATION_ABSENT
FM_AUTH_TOKEN_DECLINED=FM_AUTH_VERDICT_DECLINED
FM_AUTH_TOKEN_STALE_HEAD=FM_AUTH_STALE_HEAD
FM_AUTH_TOKEN_HEAD_MISMATCH=FM_AUTH_HEAD_MISMATCH
FM_AUTH_TOKEN_SUPERSEDED=FM_AUTH_REQUEST_SUPERSEDED
FM_AUTH_TOKEN_EXHAUSTED=FM_AUTH_ALREADY_SPENT
FM_AUTH_TOKEN_VOID=FM_AUTH_VOID
# Kept apart from VOID: an authorization that never existed and one that existed
# and was retired are different facts, and an operator chasing the first looks
# for a mint that did not happen while the second looks for what moved.
FM_AUTH_TOKEN_NONE=FM_AUTH_NO_AUTHORIZATION
FM_AUTH_TOKEN_IN_FLIGHT=FM_AUTH_SPEND_IN_FLIGHT
FM_AUTH_TOKEN_NO_ACT=FM_AUTH_NO_ACT
FM_AUTH_TOKEN_BAD_HEAD=FM_AUTH_HEAD_MALFORMED
FM_AUTH_TOKEN_NO_PR=FM_AUTH_GRANT_HAS_NO_PULL_REQUEST
# effect-plan refusals: the plan was read and the act it names may not be performed
FM_AUTH_TOKEN_ACT_MISMATCH=FM_AUTH_ACT_ASSERTION_MISMATCH
FM_AUTH_TOKEN_CREDENTIAL=FM_AUTH_CREDENTIAL_BEARING_INPUT
FM_AUTH_TOKEN_PLAN_STALE=FM_AUTH_EFFECT_PLAN_STALE
FM_AUTH_TOKEN_PLAN_FOREIGN=FM_AUTH_EFFECT_PLAN_FOREIGN
FM_AUTH_TOKEN_RULING_EXHAUSTED=FM_AUTH_RULING_ALREADY_LANDED

# could-not-observe: no verdict was reached
FM_AUTH_TOKEN_UNREADABLE=FM_AUTH_CORRELATION_UNREADABLE
FM_AUTH_TOKEN_RECORD_UNREADABLE=FM_AUTH_RECORD_UNREADABLE
FM_AUTH_TOKEN_VERDICT_UNRECOGNIZED=FM_AUTH_VERDICT_UNRECOGNIZED
FM_AUTH_TOKEN_HEAD_UNOBSERVED=FM_AUTH_HEAD_UNOBSERVED
FM_AUTH_TOKEN_INDETERMINATE=FM_AUTH_SPEND_INDETERMINATE
FM_AUTH_TOKEN_ENUM_UNOBSERVED=FM_AUTH_ENUMERATION_UNOBSERVED
FM_AUTH_TOKEN_WRITE_UNOBSERVED=FM_AUTH_INTENT_UNRECORDABLE
FM_AUTH_TOKEN_PLAN_INCOMPLETE=FM_AUTH_EFFECT_PLAN_INCOMPLETE
FM_AUTH_TOKEN_PLAN_UNSUPPORTED=FM_AUTH_EFFECT_KIND_UNSUPPORTED
FM_AUTH_TOKEN_EXEC_UNOBSERVED=FM_AUTH_EFFECT_EXECUTABLE_UNOBSERVED
FM_AUTH_TOKEN_TARGET_UNOBSERVED=FM_AUTH_EFFECT_TARGET_UNOBSERVED
FM_AUTH_TOKEN_RECEIPT_UNOBSERVED=FM_AUTH_ACT_RECEIPT_UNRECORDABLE
}

# --- the effect-plan vocabulary ----------------------------------------------
#
# Closed sets, named positively. A value outside one of them is unsupported and
# stops, rather than being carried into an act nobody described.

FM_AUTH_EFFECT_KINDS='pr-merge
local-fast-forward'

FM_AUTH_MERGE_METHODS='squash
merge
rebase'

# The executable each effect kind is performed by, chosen HERE and never by a
# caller. Resolved to an absolute path and a content digest at mint.
fm_auth_effect_executable_name() {  # <kind>
  case ${1:-} in
    pr-merge) printf 'gh-axi\n' ;;
    local-fast-forward) printf 'git\n' ;;
    *) return 1 ;;
  esac
}

# The verdicts that authorize a landing, and the ones that decline it.
#
# A verdict outside BOTH lists is UNRECOGNIZED and refuses. The asymmetry is the
# point: the failure that matters is an unknown word being read as approval, so
# the approving set is closed and everything else stops. Compared
# case-insensitively because the ruling corpus writes both `accepted` and
# `APPROVE`.
FM_AUTH_VERDICTS_AUTHORIZING='accept
accepted
approve
approved'

FM_AUTH_VERDICTS_DECLINING='decline
declined
deny
denied
reject
rejected'

# --- digest ------------------------------------------------------------------

fm_auth_digest() {  # reads stdin, prints a lowercase hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# --- identity ----------------------------------------------------------------
#
# Every field that changes WHAT IS AUTHORIZED is in the identity, one per line in
# a fixed order, so the canonical form is stable across shells and its digest is
# a durable id.
#
# head is the load-bearing member. A moved head produces a different identity, a
# different id, and therefore a different authorization, so "an authorization is
# bound to one exact head" falls out of the identity rather than being enforced
# beside it. Minting the same ruling twice reproduces the same id, which is what
# makes a duplicate mint converge on one authorization instead of two.
#
# An absent optional field is the literal "-" rather than empty, so "no pull
# request" and "pull request omitted" cannot collide into one identity.
#
# The effect digest is the other load-bearing member, and it is here for the same
# reason head is. The act an authority permits is part of what that authority IS,
# so a plan that differs by one field - another repository, another method,
# another executable content - is a DIFFERENT authorization with its own id and
# its own single use, rather than the same one re-pointed.

fm_auth_identity_canonical() {  # <request> <comment> <verdict> <item> <project> <repo> <pr> <head> <effect-digest>
  printf 'schema=%s\nrequest=%s\ncomment=%s\nverdict=%s\nitem=%s\nproject=%s\nrepo=%s\npr=%s\nhead=%s\neffect=%s\n' \
    "$FM_AUTH_SCHEMA" "$1" "$2" "$3" "$4" "${5:--}" "${6:--}" "${7:--}" "$8" "${9:--}"
}

fm_auth_id() {  # <same arguments as fm_auth_identity_canonical> -> id
  local sum
  sum=$(fm_auth_identity_canonical "$@" | fm_auth_digest) || return 1
  [ -n "$sum" ] || return 1
  printf '%s%s\n' "$FM_AUTH_ID_PREFIX" "${sum:0:$FM_AUTH_ID_HEX_WIDTH}"
}

fm_auth_id_valid() {  # <candidate>
  printf '%s' "${1:-}" \
    | grep -Eq "^${FM_AUTH_ID_PREFIX}[0-9a-f]{${FM_AUTH_ID_HEX_WIDTH}}\$"
}

fm_auth_effect_valid() {  # <candidate>
  printf '%s\n' "$FM_AUTH_EFFECTS" | grep -qxF "${1:-}"
}

# --- the publication subject -------------------------------------------------
#
# A candidate publication authorizes moving ONE ref on ONE remote from ONE tip to
# ONE head. Landing's identity cannot express that: it names a pull request, and
# a push has no pull request at the moment it happens.
#
# THREE MEMBERS ARE LOAD-BEARING, and each one turns a rule the caller would
# otherwise have to remember into a fact about the id.
#
#   head        what is being published. A different head is a different
#               authorization, exactly as in landing.
#   tip         the remote tip the effect was PLANNED AGAINST. This is the member
#               that makes "remote movement after eligibility compilation
#               invalidates the planned effect" fall out of the identity: a
#               remote that moved yields a different tip, a different id, and
#               therefore an authorization that was never minted. Nothing has to
#               notice the movement and refuse it separately, which is the form
#               of that rule least likely to be walked around.
#   generation  the compiled ruling and policy generation the verdict rested on.
#               A newer HOLD, REVISE, quarantine or supersession changes it, so a
#               permission compiled under the old one cannot address the new one.
#               This is what makes commission-time permission revocable: the
#               authority is bound to the generation that granted it rather than
#               to the moment it was granted.
#
# An absent optional member is the literal "-" rather than empty, so a new ref
# with no tip and a tip field left out cannot collide into one identity.
#
# THE EPOCH, and why a purely subject-derived id was not enough. An authorization
# consumed before its effect must never be reusable, so reconciling one to
# "the act did not happen" retires it permanently rather than returning it to the
# pool. But the world it named is unchanged - the remote is still where it was -
# so a recovery that re-asked the same question would reproduce the same id and
# find its own retired record standing in the way, and the lane would be wedged
# by the very rule meant to protect it.
#
# The epoch is how a fresh authority is granted for an unchanged subject without
# the retired one being resurrected. It counts the retired authorities for this
# exact subject, so it is derived from the store rather than chosen: two
# concurrent prepares for a subject with no history still converge on epoch 1 and
# therefore on one authorization, which is the idempotency that makes a duplicate
# wake harmless.

# THE EFFECT IS PART OF THE IDENTITY, not a label beside it. A custody
# replication and a publication of the same head on the same ref are different
# acts with different permissions, so they must digest to different authorities -
# otherwise the cheaper one's authority would present as the dearer one's.
fm_auth_effect_identity_canonical() {  # <effect> <venue> <remote> <push-url> <remote-identity> <ref> <item> <head> <tree> <tip> <generation> <epoch>
  printf 'schema=%s\neffect=%s\nvenue=%s\nremote=%s\npush_url=%s\nremote_identity=%s\nref=%s\nitem=%s\nhead=%s\ntree=%s\ntip=%s\ngeneration=%s\nepoch=%s\n' \
    "$FM_AUTH_SCHEMA" "$1" "${2:--}" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}" "${10:--}" "${11}" "${12:-1}"
}

fm_auth_effect_id() {  # <same arguments as fm_auth_effect_identity_canonical> -> id
  local sum
  sum=$(fm_auth_effect_identity_canonical "$@" | fm_auth_digest) || return 1
  [ -n "$sum" ] || return 1
  printf '%s%s\n' "$FM_AUTH_ID_PREFIX" "${sum:0:$FM_AUTH_ID_HEX_WIDTH}"
}

# The subject WITHOUT its epoch, so the store can be asked "what has already
# happened to this exact subject?" before an epoch is chosen for it.
fm_auth_effect_subject_digest() {  # <effect> <venue> <remote> <push-url> <remote-identity> <ref> <item> <head> <tree> <tip> <generation>
  printf 'schema=%s\neffect=%s\nvenue=%s\nremote=%s\npush_url=%s\nremote_identity=%s\nref=%s\nitem=%s\nhead=%s\ntree=%s\ntip=%s\ngeneration=%s\n' \
    "$FM_AUTH_SCHEMA" "$1" "${2:--}" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}" "${10:--}" "${11}" | fm_auth_digest
}

# --- verdict classification --------------------------------------------------
#
# Prints authorizing | declining | unrecognized. Three values, because "not on
# the approving list" covers both a ruling that said no and a ruling whose word
# nobody has taught this mechanism, and those are different repairs: one is a
# decision to respect, the other is a vocabulary gap to close.

fm_auth_verdict_class() {  # <verdict>
  local lower token
  lower=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  lower=${lower#"${lower%%[![:space:]]*}"}
  lower=${lower%"${lower##*[![:space:]]}"}
  [ -n "$lower" ] || { printf 'unrecognized\n'; return 0; }
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "$lower" = "$token" ] || continue
    printf 'authorizing\n'
    return 0
  done <<< "$FM_AUTH_VERDICTS_AUTHORIZING"
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "$lower" = "$token" ] || continue
    printf 'declining\n'
    return 0
  done <<< "$FM_AUTH_VERDICTS_DECLINING"
  printf 'unrecognized\n'
}

# --- head shape --------------------------------------------------------------
#
# A SHAPE PREFILTER ONLY, and named that way so nothing credits it with more.
# The load-bearing head check is equality against an independently observed head
# at the moment of the act; this only rejects a value that cannot be a head at
# all, such as a branch name or a forge error body captured from stdout.
#
# Both widths are accepted because the object format belongs to the target
# repository, which this mechanism never clones. That makes the prefilter weaker
# than the outbound owner's resolvable-object rule, and it is sound here only
# because the equality carries the property and this only screens the inputs.

fm_auth_head_shape_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

# --- pull request locator ----------------------------------------------------
#
# The correlation record stores a pull request as its URL, which is a LOCATION.
# This does not pretend otherwise: parsing it yields the coordinates needed to
# ASK the forge what the head currently is, and the answer is then required to
# equal the head the ruling approved. The location never substitutes for the
# identity; it only addresses the question.
#
# The parse is strict so a near-miss string cannot resolve to some other
# repository's pull request. A URL carrying a trailing path, query, or fragment
# is refused rather than trimmed: a URL this parser had to repair is not a URL
# this parser understood.
#
# Prints "<owner>/<repo> <number>" and returns 1 when the input is not one.

fm_auth_pr_locator() {  # <pr-url>
  local url=${1:-} rest owner repo number
  case $url in
    https://github.com/*/pull/*) rest=${url#https://github.com/} ;;
    *) return 1 ;;
  esac
  owner=${rest%%/*}
  rest=${rest#*/}
  repo=${rest%%/*}
  rest=${rest#*/}
  case $rest in
    pull/*) number=${rest#pull/} ;;
    *) return 1 ;;
  esac
  case $number in
    ''|*[!0-9]*) return 1 ;;
  esac
  case $owner in ''|*/*|*\?*|*\#*) return 1 ;; esac
  case $repo in ''|*/*|*\?*|*\#*) return 1 ;; esac
  printf '%s/%s %s\n' "$owner" "$repo" "$number"
}

# --- mechanism-input hygiene -------------------------------------------------
#
# Every plan field and every asserted argument is one plain line. A value
# carrying a newline could not be rendered into the canonical form without
# changing what the digest covers, and a value carrying a control character could
# not be quoted into a refusal without changing what the operator reads, so both
# are refused rather than escaped.

fm_auth_plain_value() {  # <candidate>
  local v=${1-}
  [ -n "$v" ] || return 1
  [ "$v" = "${v//[[:cntrl:]]/}" ]
}

# Credential-bearing mechanism input, refused before it can reach the effect
# interface. Deliberately broad and deliberately not a secret scanner: it screens
# the small set of shapes a landing mechanism field could carry a credential in,
# and it refuses rather than redacting, because a value that had to be redacted
# to be safe was never a mechanism field this owner should be holding.
fm_auth_credential_bearing() {  # <candidate>
  printf '%s' "${1-}" | grep -Eqi \
    -e '(^|[^[:alnum:]])--?(token|password|passwd|secret|api[-_]?key|apikey|credential|netrc|bearer|authorization)([=[:space:]]|$)' \
    -e '(token|password|passwd|secret|api[-_]?key|apikey|credential|bearer|authorization)[[:space:]]*[=:][^[:space:]]' \
    -e 'gh[pousr]_[[:alnum:]]{16,}' \
    -e 'github_pat_[[:alnum:]_]{20,}' \
    -e '-----BEGIN[[:space:]]' \
    -e '://[^/@[:space:]]*@'
}

# --- effect plan -------------------------------------------------------------
#
# The plan is read into named values, rendered to its canonical form, and only
# then turned into an act. Reading, rendering, and constructing are one pass so
# no consumer can build an act from a plan that was never validated.
#
# Every failure sets FM_AUTH_PLAN_DEFECT to the reason and returns non-zero, with
# the return value naming which of the three answers the caller reached:
#   1  incomplete or malformed - could-not-observe
#   2  unsupported effect kind - could-not-observe
#   3  credential-bearing input - a refusal
#
# shellcheck disable=SC2034  # the parsed plan is read by sourcing callers
{
FM_AUTH_PLAN_DEFECT=
FM_AUTH_PLAN_CANONICAL=
FM_AUTH_PLAN_KIND=
FM_AUTH_PLAN_VENUE=
FM_AUTH_PLAN_REPO=
FM_AUTH_PLAN_PR=
FM_AUTH_PLAN_HEAD=
FM_AUTH_PLAN_METHOD=
FM_AUTH_PLAN_DELETE_BRANCH=
FM_AUTH_PLAN_PROJECT=
FM_AUTH_PLAN_PROJECT_IDENTITY=
FM_AUTH_PLAN_TARGET_REF=
FM_AUTH_PLAN_TARGET_HEAD=
FM_AUTH_PLAN_MODE=
FM_AUTH_PLAN_FORCE=
FM_AUTH_PLAN_EXEC_NAME=
FM_AUTH_PLAN_EXEC_PATH=
FM_AUTH_PLAN_EXEC_DIGEST=
FM_AUTH_ACT=()
}

fm_auth_plan_reset() {
  FM_AUTH_PLAN_DEFECT=
  FM_AUTH_PLAN_CANONICAL=
  FM_AUTH_PLAN_KIND=
  FM_AUTH_PLAN_VENUE=
  FM_AUTH_PLAN_REPO=
  FM_AUTH_PLAN_PR=
  FM_AUTH_PLAN_HEAD=
  FM_AUTH_PLAN_METHOD=
  FM_AUTH_PLAN_DELETE_BRANCH=
  FM_AUTH_PLAN_PROJECT=
  FM_AUTH_PLAN_PROJECT_IDENTITY=
  FM_AUTH_PLAN_TARGET_REF=
  FM_AUTH_PLAN_TARGET_HEAD=
  FM_AUTH_PLAN_MODE=
  FM_AUTH_PLAN_FORCE=
  FM_AUTH_PLAN_EXEC_NAME=
  FM_AUTH_PLAN_EXEC_PATH=
  FM_AUTH_PLAN_EXEC_DIGEST=
  FM_AUTH_ACT=()
}

# One field, read strictly. An absent, null, or non-string value is a missing
# field rather than an empty one, because "the plan does not say" and "the plan
# says nothing" are the same refusal here and neither is a default.
#
# The per-field validator is named as an argument and called by name, which is a
# call form bin/fm-dead-predicate-check.sh cannot resolve on its own. Each one is
# declared to it here so a live predicate is not reported dead and, worse, so the
# whole file does not become unreadable to that control:
#   indirect-call: fm_auth_head_shape_valid
#   indirect-call: fm_auth_plan_repo_valid
#   indirect-call: fm_auth_plan_number_valid
#   indirect-call: fm_auth_plan_absolute_path_valid
#   indirect-call: fm_auth_plan_exec_name_valid
#   indirect-call: fm_auth_plan_digest_valid
#   indirect-call: fm_auth_plan_target_ref_valid
#   indirect-call: fm_auth_plan_member_of
#   indirect-call: fm_auth_plan_literal
#
# Every mark above names a function this file really does call by name as an
# argument. A mark is an assertion about how a call is written, so declaring one
# for a function that is called ORDINARILY makes the control report a call site
# it never found - the control stops saying "I could not read this" and starts
# saying "I read it and it is alive", which is a different and false claim. When
# a consumer becomes unreadable, the repair is the construct that made it
# unreadable, never a mark that hides the gap.
FM_AUTH_PLAN_VALUE=
fm_auth_plan_read() {  # <plan-json> <field> [<validator> [<validator-arg>]]
  local plan=$1 field=$2 check=${3:-} value
  FM_AUTH_PLAN_VALUE=
  value=$(printf '%s' "$plan" | jq -r --arg f "$field" \
    'if (.[$f] | type) == "string" then .[$f]
     elif (.[$f] | type) == "boolean" then (if .[$f] then "yes" else "no" end)
     elif (.[$f] | type) == "number" then (.[$f] | tostring)
     else "" end' 2>/dev/null) || {
    FM_AUTH_PLAN_DEFECT="the effect plan could not be read for field '$field'"
    return 1
  }
  if ! fm_auth_plain_value "$value"; then
    FM_AUTH_PLAN_DEFECT="the effect plan names no usable '$field'"
    return 1
  fi
  if fm_auth_credential_bearing "$value"; then
    FM_AUTH_PLAN_DEFECT="the effect plan's '$field' carries credential-bearing input"
    return 3
  fi
  if [ -n "$check" ] && ! "$check" "$value" "${4:-}"; then
    FM_AUTH_PLAN_DEFECT="the effect plan's '$field' is not a value this contract accepts"
    return 1
  fi
  FM_AUTH_PLAN_VALUE=$value
  return 0
}

fm_auth_plan_repo_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
}

fm_auth_plan_number_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^[0-9]+$'
}

fm_auth_plan_absolute_path_valid() {  # <candidate>
  case ${1:-} in
    /*) ;;
    *) return 1 ;;
  esac
  case ${1:-} in
    *'//'*|*/./*|*/../*|*/..|*/.) return 1 ;;
  esac
  return 0
}

fm_auth_plan_exec_name_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9._-]+$'
}

fm_auth_plan_digest_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^[0-9a-f]{64}$'
}

fm_auth_plan_target_ref_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^refs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
  case ${1:-} in
    *..*|*/.*|*.lock|*//*|*/) return 1 ;;
  esac
  return 0
}

fm_auth_plan_member_of() {  # <candidate> <newline-separated set>
  printf '%s\n' "${2:-}" | grep -qxF "${1:-}"
}

fm_auth_plan_literal() {  # <candidate> <required literal>
  [ "${1:-}" = "${2:-}" ]
}

# The whole plan, validated and rendered. On success FM_AUTH_PLAN_CANONICAL holds
# the exact bytes the identity digest covers and FM_AUTH_ACT holds the act.
fm_auth_plan_parse() {  # <plan-json>
  local plan=$1 kind
  fm_auth_plan_reset
  if ! printf '%s' "$plan" | jq -e 'type == "object"' >/dev/null 2>&1; then
    FM_AUTH_PLAN_DEFECT='the authority carries no effect plan, so the act it permits is undetermined'
    return 1
  fi
  kind=$(printf '%s' "$plan" | jq -r 'if (.kind | type) == "string" then .kind else "" end' 2>/dev/null) || kind=
  if ! fm_auth_plan_member_of "$kind" "$FM_AUTH_EFFECT_KINDS"; then
    FM_AUTH_PLAN_DEFECT="the effect plan declares kind '${kind:--}', which this contract does not perform"
    return 2
  fi
  FM_AUTH_PLAN_KIND=$kind

  fm_auth_plan_read "$plan" executable_name fm_auth_plan_exec_name_valid || return $?
  FM_AUTH_PLAN_EXEC_NAME=$FM_AUTH_PLAN_VALUE
  [ "$FM_AUTH_PLAN_EXEC_NAME" = "$(fm_auth_effect_executable_name "$kind")" ] || {
    FM_AUTH_PLAN_DEFECT="the effect plan performs '$kind' with '$FM_AUTH_PLAN_EXEC_NAME', which is not the executable this contract performs it with"
    return 1
  }
  fm_auth_plan_read "$plan" executable_path fm_auth_plan_absolute_path_valid || return $?
  FM_AUTH_PLAN_EXEC_PATH=$FM_AUTH_PLAN_VALUE
  fm_auth_plan_read "$plan" executable_digest fm_auth_plan_digest_valid || return $?
  FM_AUTH_PLAN_EXEC_DIGEST=$FM_AUTH_PLAN_VALUE
  fm_auth_plan_read "$plan" force fm_auth_plan_literal no || return $?
  FM_AUTH_PLAN_FORCE=$FM_AUTH_PLAN_VALUE

  case $kind in
    pr-merge)
      fm_auth_plan_read "$plan" venue fm_auth_plan_literal github || return $?
      FM_AUTH_PLAN_VENUE=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" repo fm_auth_plan_repo_valid || return $?
      FM_AUTH_PLAN_REPO=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" pr fm_auth_plan_number_valid || return $?
      FM_AUTH_PLAN_PR=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" head fm_auth_head_shape_valid || return $?
      FM_AUTH_PLAN_HEAD=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" method fm_auth_plan_member_of "$FM_AUTH_MERGE_METHODS" || return $?
      FM_AUTH_PLAN_METHOD=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" delete_branch fm_auth_plan_member_of 'yes
no' || return $?
      FM_AUTH_PLAN_DELETE_BRANCH=$FM_AUTH_PLAN_VALUE
      FM_AUTH_PLAN_CANONICAL=$(printf 'effect=%s\nvenue=%s\nrepo=%s\npr=%s\nhead=%s\nmethod=%s\ndelete_branch=%s\nforce=%s\nexec_name=%s\nexec_path=%s\nexec_digest=%s\n' \
        "$FM_AUTH_PLAN_KIND" "$FM_AUTH_PLAN_VENUE" "$FM_AUTH_PLAN_REPO" \
        "$FM_AUTH_PLAN_PR" "$FM_AUTH_PLAN_HEAD" "$FM_AUTH_PLAN_METHOD" \
        "$FM_AUTH_PLAN_DELETE_BRANCH" "$FM_AUTH_PLAN_FORCE" \
        "$FM_AUTH_PLAN_EXEC_NAME" "$FM_AUTH_PLAN_EXEC_PATH" "$FM_AUTH_PLAN_EXEC_DIGEST")
      FM_AUTH_ACT=("$FM_AUTH_PLAN_EXEC_PATH" pr merge "$FM_AUTH_PLAN_PR"
        --repo "$FM_AUTH_PLAN_REPO" "--$FM_AUTH_PLAN_METHOD")
      if [ "$FM_AUTH_PLAN_DELETE_BRANCH" = yes ]; then
        FM_AUTH_ACT+=(--delete-branch)
      fi
      ;;
    local-fast-forward)
      fm_auth_plan_read "$plan" venue fm_auth_plan_literal local || return $?
      FM_AUTH_PLAN_VENUE=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" project fm_auth_plan_absolute_path_valid || return $?
      FM_AUTH_PLAN_PROJECT=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" project_identity fm_auth_plan_absolute_path_valid || return $?
      FM_AUTH_PLAN_PROJECT_IDENTITY=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" target_ref fm_auth_plan_target_ref_valid || return $?
      FM_AUTH_PLAN_TARGET_REF=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" target_head fm_auth_head_shape_valid || return $?
      FM_AUTH_PLAN_TARGET_HEAD=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" head fm_auth_head_shape_valid || return $?
      FM_AUTH_PLAN_HEAD=$FM_AUTH_PLAN_VALUE
      fm_auth_plan_read "$plan" mode fm_auth_plan_literal ff-only || return $?
      FM_AUTH_PLAN_MODE=$FM_AUTH_PLAN_VALUE
      FM_AUTH_PLAN_CANONICAL=$(printf 'effect=%s\nvenue=%s\nproject=%s\nproject_identity=%s\ntarget_ref=%s\ntarget_head=%s\nhead=%s\nmode=%s\nforce=%s\nexec_name=%s\nexec_path=%s\nexec_digest=%s\n' \
        "$FM_AUTH_PLAN_KIND" "$FM_AUTH_PLAN_VENUE" "$FM_AUTH_PLAN_PROJECT" \
        "$FM_AUTH_PLAN_PROJECT_IDENTITY" "$FM_AUTH_PLAN_TARGET_REF" \
        "$FM_AUTH_PLAN_TARGET_HEAD" "$FM_AUTH_PLAN_HEAD" "$FM_AUTH_PLAN_MODE" "$FM_AUTH_PLAN_FORCE" \
        "$FM_AUTH_PLAN_EXEC_NAME" "$FM_AUTH_PLAN_EXEC_PATH" "$FM_AUTH_PLAN_EXEC_DIGEST")
      FM_AUTH_ACT=("$FM_AUTH_PLAN_EXEC_PATH" -C "$FM_AUTH_PLAN_PROJECT_IDENTITY"
        merge --ff-only --quiet "$FM_AUTH_PLAN_HEAD")
      ;;
  esac
  [ -n "$FM_AUTH_PLAN_CANONICAL" ] || {
    # shellcheck disable=SC2034  # read by sourcing callers to name the defect
    FM_AUTH_PLAN_DEFECT='the effect plan could not be rendered to its canonical form'
    return 1
  }
  return 0
}

# The digest the authorization identity carries, taken from the canonical form a
# successful parse produced. It reads that global rather than re-parsing, because
# a parse inside a command substitution would lose the defect it recorded - which
# is exactly how a refusal ends up naming nothing.
fm_auth_plan_canonical_digest() {
  local sum
  [ -n "$FM_AUTH_PLAN_CANONICAL" ] || return 1
  sum=$(printf '%s\n' "$FM_AUTH_PLAN_CANONICAL" | fm_auth_digest) || return 1
  fm_auth_plan_digest_valid "$sum" || return 1
  printf '%s\n' "$sum"
}

# --- spend admissibility -----------------------------------------------------
#
# The pure half of the spend decision: what the record's own state permits,
# before any freshness is re-observed. Prints one token.
#
#   proceed        granted, and freshness has still to be checked
#   exhausted      already spent - the caller returns the recorded outcome and
#                  performs no act, which is what makes a duplicate wake converge
#   indeterminate  a spend began and no outcome was recorded
#   void           permanently inapplicable
#   unreadable     the state is not one this contract knows

fm_auth_spend_admissibility() {  # <state>
  case ${1:-} in
    granted) printf 'proceed\n' ;;
    spent) printf 'exhausted\n' ;;
    spending) printf 'indeterminate\n' ;;
    void) printf 'void\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}

# --- reported status ---------------------------------------------------------
#
# The record state a caller sees. `spending` is reported as `indeterminate`
# because that is what it means to a reader: the durable record cannot say
# whether the act happened. Naming it after the internal transition would invite
# a reader to treat it as "in progress" and wait for something to finish it.

fm_auth_reported_status() {  # <state>
  case ${1:-} in
    granted) printf '%s\n' "$FM_AUTH_STATUS_GRANTED" ;;
    spent) printf '%s\n' "$FM_AUTH_STATUS_SPENT" ;;
    spending) printf '%s\n' "$FM_AUTH_STATUS_INDETERMINATE" ;;
    void) printf '%s\n' "$FM_AUTH_STATUS_VOID" ;;
    *) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE" ;;
  esac
}

# --- record construction -----------------------------------------------------

fm_auth_record_new() {  # <id> <request> <comment> <verdict> <item> <project> <repo> <pr> <head> <now> <effect-json>
  jq -n \
    --arg schema "$FM_AUTH_SCHEMA" \
    --arg id "$1" --arg request "$2" --arg comment "$3" --arg verdict "$4" \
    --arg item "$5" --arg project "$6" --arg repo "$7" --arg pr "$8" \
    --arg head "$9" --arg now "${10}" --argjson effect "${11}" \
    '{schema:$schema,
      authorization_id:$id,
      request_id:$request,
      ruling:{comment_id:$comment,verdict:$verdict},
      grant:{item:$item,project:$project,repo:$repo,
             pr:(if $pr == "" or $pr == "-" then null else $pr end),
             head:$head},
      effect:$effect,
      uses:1,
      state:"granted",
      minted:$now,
      updated:$now,
      spend:null,
      void_reason:null,
      history:[]}'
}

# The publication record carries the SAME lifecycle fields under the same names,
# because the whole point of extending this contract rather than writing a second
# one is that `granted`, `spending`, `spent` and `void` mean one thing in this
# fleet. Only `grant` differs, and it differs because the subject differs.
#
# `request_id` is null for a publication no Browser Sol request governs. That is
# a real, reportable state rather than a gap: an ungoverned publication still
# mints an authority, so it is still one-use, still head-bound and still
# crash-recoverable. What governance adds is the ruling, not the exactly-once.

fm_auth_effect_record_new() {  # <effect> <id> <request-or-empty> <venue> <remote> <push-url> <remote-identity> <ref> <item> <head> <tree> <tip> <generation> <epoch> <subject> <now>
  local effect=$1
  shift
  fm_auth_effect_valid "$effect" || return 1
  jq -n \
    --arg schema "$FM_AUTH_SCHEMA" --arg effect "$effect" \
    --arg id "$1" --arg request "$2" --arg venue "$3" --arg remote "$4" \
    --arg push_url "$5" --arg remote_identity "$6" --arg ref "$7" \
    --arg item "$8" --arg head "$9" --arg tree "${10}" --arg tip "${11}" \
    --arg generation "${12}" --arg epoch "${13}" --arg subject "${14}" --arg now "${15}" \
    '{schema:$schema,
      authorization_id:$id,
      effect:$effect,
      request_id:(if $request == "" or $request == "-" then null else $request end),
      subject:$subject,
      epoch:($epoch|tonumber),
      grant:{venue:$venue,remote:{name:$remote,push_url:$push_url,identity:$remote_identity},
             ref:$ref,item:$item,head:$head,tree:$tree,
             tip:(if $tip == "" or $tip == "-" then null else $tip end),
             generation:$generation},
      uses:1,
      state:"granted",
      minted:$now,
      updated:$now,
      spend:null,
      void_reason:null,
      history:[]}'
}

# --- the store ----------------------------------------------------------------
#
# Where a record lives and how it is written. Both effects write through here, so
# an authorization record has one on-disk shape however it was minted.
#
# ATOMIC BY RENAME, and the spend sequence depends on it. An intent record that
# could be half-written would put the fourth state back: a reader finding a torn
# record cannot tell an act that was about to happen from one that did.

fm_auth_store_path() {  # <dir> <auth-id>
  fm_auth_id_valid "${2:-}" || return 1
  printf '%s/%s.json\n' "$1" "$2"
}

fm_auth_store_write() {  # <dir> <auth-id> <json>
  local path tmp
  path=$(fm_auth_store_path "$1" "$2") || return 1
  mkdir -p "$1" || return 1
  tmp="$path.tmp.$$"
  printf '%s\n' "$3" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

auth_claim_path() {
  fm_auth_id_valid "${1:-}" || return 1
  printf '%s/.%s.claim\n' "$AUTH_DIR" "$1"
}

claim_acquire() {  # <auth-id> [serial]
  local dir pid identity group mode=${2:-group}
  dir=$(auth_claim_path "$1") || return 1
  pid=${BASHPID:-$$}
  group=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$mode" = serial ] || [ "$group" = "$pid" ] || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  mkdir -p "$AUTH_DIR" || return 1
  mkdir "$dir" 2>/dev/null || return 1
  if printf '%s\n' "$pid" > "$dir/owner-pid" \
    && printf '%s\n' "$identity" > "$dir/owner-identity" \
    && printf '%s\n' "$group" > "$dir/owner-group"; then
    :
  else
    rm -f "$dir/owner-pid" "$dir/owner-identity" "$dir/owner-group"
    rmdir "$dir" 2>/dev/null
    return 1
  fi
  CLAIM=$dir
  trap claim_release EXIT
  if [ "$mode" = serial ]; then
    trap 'claim_release; exit 4' INT TERM
  else
    trap 'claim_terminate INT' INT
    trap 'claim_terminate TERM' TERM
  fi
  return 0
}

claim_terminate() {  # <signal>
  local signal=$1 group=${BASHPID:-$$}
  trap - EXIT INT TERM
  kill -s "$signal" -- "-$group" 2>/dev/null || exit 4
  exit 4
}

claim_release() {
  [ -n "$CLAIM" ] || return 0
  rm -f "$CLAIM/owner-pid" "$CLAIM/owner-identity" "$CLAIM/owner-group"
  rmdir "$CLAIM" 2>/dev/null || true
  CLAIM=
}

# fail-closed-predicates: enforced
