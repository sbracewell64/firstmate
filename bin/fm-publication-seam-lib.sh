# shellcheck shell=bash
# fm-publication-seam-lib.sh - the single owner of ONE question, asked
# immediately before every governed remote-changing candidate publication this
# fleet owns: may THIS exact head move THIS exact ref on THIS exact remote, from
# the tip it is standing on, right now?
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-publication-seam-lib.sh
#   . "$SCRIPT_DIR/fm-publication-seam-lib.sh"
#
# It needs bin/fm-outbound-artifact-lib.sh for the gate register and
# bin/fm-landing-authorization-lib.sh for the head prefilter, the verdict
# classification and the authorization identity; source both before this one.
#
# WHY THIS EXISTS, AND WHY IT IS THE SIBLING OF THE LANDING SEAM.
#
# bin/fm-landing-seam-lib.sh closed the same hole one step later in the same
# pipeline: a ruling-governed LANDING could route around the authority that was
# supposed to permit it. Publication is the step before, and it had no such
# owner at all. A candidate reaches the outside world when it is PUSHED, not when
# it is merged - a reviewer, a CI run, a bot and every later ruling are all
# reacting to a head that publication already made real. So the question "is this
# permitted?" asked only at the merge is asked after the irreversible half has
# already happened.
#
# WHAT MAKES PUBLICATION DIFFERENT FROM LANDING, and why it needed its own
# resolution rather than another argument to the landing one.
#
#   1. There is no pull request yet. Landing re-observes a pull request's head at
#      the forge; publication has only a ref and the tip that ref currently
#      points at, so the independent observation is `git ls-remote`, not `gh`.
#   2. The effect can be a no-op. A push whose remote already equals the head
#      changes nothing, and treating that as an effect would spend an authority
#      for an act that never happened - which then reads, to every later reader,
#      as a publication this fleet performed. NO_EFFECT_ALREADY_EQUAL is
#      therefore a typed verdict of its own and consumes nothing.
#   3. The tip is part of what is authorized. A landing authority survives the
#      world moving around it because its subject is a head; a publication
#      authority must not, because a remote that moved is a remote whose current
#      state nobody compiled a verdict against.
#
# WHAT IT DOES NOT OWN, stated so nothing credits it with more.
#
# It does not decide whether a ruling approves - bin/fm-landing-authorization.sh
# owns the closed approving-verdict set and this reuses it rather than restating
# it. It does not correlate a ruling to a request; bin/fm-outbound-artifact.sh
# owns that and this reads its records read-only. It does not push, and it does
# not know how to. It establishes nothing about whether a head is green, tested
# or reviewed; those remain the calling path's own guards and this composes with
# them.
#
# It also makes NO claim over paths outside this fleet's own scripts. A direct
# `git push` typed by a human, a provider web UI, and no-mistakes' own PushStep
# each reach the remote without passing here. Server-side protection is the
# separate defence for those, and the honest scope of this file is: every
# remote-changing publication FIRSTMATE ITSELF performs reaches this verdict
# first. Claiming more would be the wrong-subject failure this fleet has a
# vocabulary for.
#
# APPLICABILITY IS AN OBSERVATION, NOT A SILENCE - held for exactly the reason
# the landing seam holds it. A publication no policy and no ruling governs must
# proceed and must SAY that it proceeded ungoverned, and it may only say so after
# the record store was successfully enumerated. A store that could not be read is
# could-not-observe and stops the publication, because the record it could not
# read is exactly the one that might have held it.

if [ -n "${FM_PUB_SEAM_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_PUB_SEAM_LIB_SOURCED=1

# --- contract constants ------------------------------------------------------

# The publication identity and delivery policy this reads. Home-private and
# gitignored, like every other config/ member: it names real people and real
# delivery actors, so it must never live in a template repo that ships to other
# homes. docs/configuration.md owns the schema.
FM_PUB_SEAM_POLICY_FILE='publication-identity.json'

# The governed identity axes a governed venue must declare in full. Named
# positively and required as a complete set: a policy that declares four of the
# six has not made a weaker promise, it has left two axes unstated, and an
# unstated axis at a load-bearing admission is could-not-observe.
FM_PUB_SEAM_IDENTITY_AXES='author
committer
delivery_actor
maker
reviewer
ruling'

# The identity pairs that must be DISTINCT parties. A maker reviewing its own
# candidate is the failure this encodes; the register in
# .agents/skills/role-qualification/SKILL.md owns the wider rule and this is the
# publication-time instance of it.
FM_PUB_SEAM_DISTINCT_PAIRS='maker reviewer'

# Identities that are never a governed party, whatever a policy says. This list
# is built in rather than configured because a placeholder that a home could
# switch off is not a floor. `Test <test@example.com>` is here by name: it is
# git's own worked-example identity and it has reached real remotes before.
FM_PUB_SEAM_PLACEHOLDER_IDENTITIES='Test <test@example.com>
test <test@example.com>
Your Name <you@example.com>
unknown <unknown>'

# The candidate roles a ref may hold. Only `canonical` is actionable: a retained
# predecessor stays readable, stays open, and stays unable to publish, which is
# the forge-actionability defect stated as a rule.
FM_PUB_SEAM_ROLE_ACTIONABLE='canonical'

# The authorization states that make another candidate for the same semantic
# work still actionable. `spending` counts: an authority whose act may or may not
# have happened is precisely one that must block a second candidate.
FM_PUB_SEAM_LIVE_AUTH_STATES='granted
spending'

# Stable tokens, in the three families this fleet keeps apart everywhere: a
# reported observation, a refusal that reached a verdict of no, and a
# could-not-observe that reached no verdict at all. All three stop a publication
# except the first two named here, and an operator told only "it did not work"
# repairs the wrong thing.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
# reported observations - neither is a refusal
FM_PUB_SEAM_TOKEN_NOT_APPLICABLE=FM_PUB_NOT_APPLICABLE
FM_PUB_SEAM_TOKEN_ALLOW=FM_PUB_ALLOW_EXACT
# a typed NO-EFFECT result: nothing to do, and nothing consumed
FM_PUB_SEAM_TOKEN_NO_EFFECT=NO_EFFECT_ALREADY_EQUAL
# refusals: a verdict was reached and it is no
FM_PUB_SEAM_TOKEN_REMOTE_MOVED=FM_PUB_REMOTE_TIP_MOVED
FM_PUB_SEAM_TOKEN_ACTIVE_HOLD=FM_PUB_ACTIVE_HOLD
FM_PUB_SEAM_TOKEN_HEAD_UNAPPROVED=FM_PUB_HEAD_NOT_APPROVED
FM_PUB_SEAM_TOKEN_RULING_DECLINED=FM_PUB_RULING_DECLINED
FM_PUB_SEAM_TOKEN_WORK_UNDECLARED=FM_PUB_WORK_IDENTITY_UNDECLARED
FM_PUB_SEAM_TOKEN_NOT_CANONICAL=FM_PUB_NOT_CANONICAL_SUCCESSOR
FM_PUB_SEAM_TOKEN_DUPLICATE=FM_PUB_DUPLICATE_ACTIONABLE_CANDIDATE
FM_PUB_SEAM_TOKEN_PLACEHOLDER=FM_PUB_IDENTITY_PLACEHOLDER
FM_PUB_SEAM_TOKEN_UNMAPPED=FM_PUB_IDENTITY_UNMAPPED
FM_PUB_SEAM_TOKEN_NOT_DISTINCT=FM_PUB_IDENTITY_NOT_DISTINCT
FM_PUB_SEAM_TOKEN_GENERATION=FM_PUB_GENERATION_CHANGED
# could-not-observe: no verdict was reached
FM_PUB_SEAM_TOKEN_CANDIDATE_UNBOUND=FM_PUB_CANDIDATE_UNBOUND
FM_PUB_SEAM_TOKEN_STORE_UNREADABLE=FM_PUB_RECORD_STORE_UNREADABLE
FM_PUB_SEAM_TOKEN_RECORD_UNREADABLE=FM_PUB_RECORD_UNREADABLE
FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE=FM_PUB_POLICY_UNREADABLE
FM_PUB_SEAM_TOKEN_IDENTITY_UNOBSERVED=FM_PUB_IDENTITY_UNOBSERVED
FM_PUB_SEAM_TOKEN_TIP_UNOBSERVED=FM_PUB_REMOTE_TIP_UNOBSERVED
FM_PUB_SEAM_TOKEN_AMBIGUOUS=FM_PUB_AMBIGUOUS_AUTHORITY
FM_PUB_SEAM_TOKEN_VENUE_UNCONFIGURED=FM_PUB_VENUE_UNCONFIGURED
FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE=FM_PUB_AUTHORIZATION_STORE_UNREADABLE
}

# --- outputs -----------------------------------------------------------------
#
# Sets, always, all five:
#   FM_PUB_SEAM_VERDICT     allow-exact | not-applicable | no-effect | refused | unobserved
#   FM_PUB_SEAM_TOKEN       one stable token from the block above
#   FM_PUB_SEAM_REASON      one line naming what was observed
#   FM_PUB_SEAM_REQUEST     the governing request id, empty when none governs
#   FM_PUB_SEAM_GENERATION  the compiled ruling-and-policy generation the verdict
#                           rested on, which the authorization identity binds
#
# Returns 0 for allow-exact, not-applicable and no-effect, 3 for refused and 4
# for unobserved, so a caller reading only the status still stops on both
# stopping values.

FM_PUB_SEAM_VERDICT=
FM_PUB_SEAM_TOKEN=
FM_PUB_SEAM_REASON=
FM_PUB_SEAM_REQUEST=
FM_PUB_SEAM_GENERATION=

# shellcheck disable=SC2034  # the five outputs are read by the sourcing publication paths
fm_pub_seam_set() {  # <verdict> <token> <reason> [<request>] [<generation>]
  FM_PUB_SEAM_VERDICT=$1
  FM_PUB_SEAM_TOKEN=$2
  FM_PUB_SEAM_REASON=$3
  FM_PUB_SEAM_REQUEST=${4:-}
  FM_PUB_SEAM_GENERATION=${5:-}
  case $1 in
    allow-exact|not-applicable|no-effect) return 0 ;;
    refused) return 3 ;;
    *) return 4 ;;
  esac
}

# --- subject shape -----------------------------------------------------------
#
# A subject this file cannot bind is refused before any record or policy is read.
# The reason is the same one the landing seam gives for its own prefilter: a head
# that is a branch name or a captured error body would compare equal to no record
# and reach not-applicable, which is a bypass wearing the shape of a clean answer.
#
# The tip is allowed to be the literal "-", meaning the ref does not exist on the
# remote yet. That is a real and common subject - the first push of a branch -
# and it is spelled explicitly rather than as an empty string so that "no tip"
# and "tip not supplied" cannot collide.

# A WHITELIST rather than a list of forbidden characters, because the forbidden
# list is the one that silently gains a hole when a shell, a git version or a
# reader's escaping disagrees about one character. Everything git's own refname
# rules would reject is outside this set already.
fm_pub_seam_ref_valid() {  # <ref>
  local ref=${1:-}
  case $ref in
    refs/heads/?*|refs/notes/?*|refs/tags/?*) ;;
    *) return 1 ;;
  esac
  case $ref in
    *[![:alnum:]/._-]*) return 1 ;;
    *..*|*//*|*/|*.lock) return 1 ;;
  esac
  return 0
}

fm_pub_seam_tip_valid() {  # <tip-or-dash>
  [ "${1:-}" = '-' ] && return 0
  fm_auth_head_shape_valid "${1:-}"
}

fm_pub_seam_subject_valid() {  # <item> <venue> <ref> <head> <tree> <expected-tip> <observed-tip>
  [ -n "${1:-}" ] || return 1
  [ -n "${2:-}" ] || return 1
  fm_pub_seam_ref_valid "${3:-}" || return 1
  fm_auth_head_shape_valid "${4:-}" || return 1
  fm_auth_head_shape_valid "${5:-}" || return 1
  fm_pub_seam_tip_valid "${6:-}" || return 1
  fm_pub_seam_tip_valid "${7:-}" || return 1
  return 0
}

# --- the policy --------------------------------------------------------------
#
# Reading it is a three-valued act. A file that is not there means this home has
# declared no publication identity policy, which is an ABSENCE and not a defect:
# combined with no governing request it yields not-applicable. A file that is
# there and cannot be parsed is could-not-observe, because the policy that failed
# to parse is exactly the one that might have refused this publication.

FM_PUB_SEAM_POLICY_RAW=
FM_PUB_SEAM_POLICY_STATE=

fm_pub_seam_policy_read() {  # <config-dir> -> sets STATE to absent|present|unreadable
  local file=${1:-}/$FM_PUB_SEAM_POLICY_FILE raw
  FM_PUB_SEAM_POLICY_RAW=
  FM_PUB_SEAM_POLICY_STATE=absent
  [ -e "$file" ] || return 0
  if ! raw=$(cat "$file" 2>/dev/null); then
    FM_PUB_SEAM_POLICY_STATE=unreadable
    return 0
  fi
  if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    FM_PUB_SEAM_POLICY_STATE=unreadable
    return 0
  fi
  FM_PUB_SEAM_POLICY_RAW=$raw
  FM_PUB_SEAM_POLICY_STATE=present
  return 0
}

# Every argument is passed to jq, so a caller may bind --arg values and keep the
# filter last. Its own failure prints nothing, which callers read as an absent
# field; the policy's readability was already settled by fm_pub_seam_policy_read.
fm_pub_seam_policy_get() {  # [jq-args...] <jq-filter>
  printf '%s' "$FM_PUB_SEAM_POLICY_RAW" | jq -r "$@" 2>/dev/null
}

# The three shapes the policy is asked for. Wrapping them keeps the jq programs
# in one place, so a filter's single quotes need explaining once rather than at
# every call site, and a caller cannot accidentally build a filter from a venue
# name.

# shellcheck disable=SC2016  # jq program variables, not shell expansions.
fm_pub_seam_policy_venue_governed() {  # <venue>
  [ "$(fm_pub_seam_policy_get --arg v "$1" '.venues // {} | has($v)')" = true ]
}

# shellcheck disable=SC2016  # jq program variables, not shell expansions.
fm_pub_seam_policy_identity() {  # <venue> <axis>
  fm_pub_seam_policy_get --arg v "$1" --arg a "$2" '.venues[$v].identities[$a] // ""'
}

# shellcheck disable=SC2016  # jq program variables, not shell expansions.
fm_pub_seam_policy_work() {  # <venue> <ref> <field>
  fm_pub_seam_policy_get --arg v "$1" --arg r "$2" --arg f "$3" '.venues[$v].work[$r][$f] // ""'
}

# An identity is a placeholder when the built-in list names it, or when the
# policy's own additional list does. Compared case-insensitively on the whole
# string, because the failure being prevented is a real remote receiving a commit
# nobody can attribute, and `TEST <Test@Example.com>` attributes no better.

fm_pub_seam_identity_is_placeholder() {  # <identity>
  local want extra
  want=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$want" ] || return 0
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    [ "$want" = "$(printf '%s' "$extra" | tr '[:upper:]' '[:lower:]')" ] || continue
    return 0
  done <<< "$FM_PUB_SEAM_PLACEHOLDER_IDENTITIES"
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    [ "$want" = "$(printf '%s' "$extra" | tr '[:upper:]' '[:lower:]')" ] || continue
    return 0
  done < <(fm_pub_seam_policy_get '.placeholders // [] | .[]')
  return 1
}

# --- the commit identity, OBSERVED and not accepted ---------------------------
#
# The party whose identity is being checked is the party performing the push, so
# a check that compares only the identity that party handed in has anchored the
# condition to something the checked party sets in the same act. This reads the
# author and committer out of the repository at the exact head instead, which is
# the same reason the landing authority re-observes a pull request's head at the
# forge rather than trusting the head its caller stated.
#
# A head that cannot be read here is could-not-observe and not an absent
# identity. Those are different facts and only one of them is safe to publish on.

FM_PUB_SEAM_AUTHOR=
FM_PUB_SEAM_COMMITTER=

fm_pub_seam_observe_commit_identity() {  # <repo-dir> <head> -> 0 observed, 1 not
  local repo=${1:-} head=${2:-} line
  FM_PUB_SEAM_AUTHOR=
  FM_PUB_SEAM_COMMITTER=
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  line=$(git --no-optional-locks -C "$repo" log -1 --no-show-signature \
    --format='%an <%ae>%n%cn <%ce>' "$head" 2>/dev/null) || return 1
  FM_PUB_SEAM_AUTHOR=$(printf '%s\n' "$line" | sed -n '1p')
  FM_PUB_SEAM_COMMITTER=$(printf '%s\n' "$line" | sed -n '2p')
  [ -n "$FM_PUB_SEAM_AUTHOR" ] && [ -n "$FM_PUB_SEAM_COMMITTER" ]
}

# --- governing requests and active holds -------------------------------------
#
# One pass over the correlation store answers two questions that must not be
# asked separately: which live Browser Sol request governs this work, and whether
# any of them is an unmet obligation standing in front of this publication.
#
# WHY A LIVE REQUEST THAT HAS NOT APPROVED THIS HEAD IS A HOLD rather than a
# fall-through. If an unanswered request let publication proceed, then emitting a
# review request would be the cheapest way to publish before anyone read it, and
# moving the head would be the cheapest way to shed a ruling already given. Both
# are the same escape, and both are closed by the same rule: live governance with
# no approval bound to THIS head refuses.
#
# The counters are returned rather than the decision, because the caller folds
# them together with the policy's own governance and one fold is easier to keep
# correct than two.

FM_PUB_SEAM_LIVE=0
FM_PUB_SEAM_GRANTING=0
FM_PUB_SEAM_GRANTING_ID=
FM_PUB_SEAM_GRANTING_COMMENT=
FM_PUB_SEAM_GRANTING_VERDICT=
FM_PUB_SEAM_HOLDS=

fm_pub_seam_scan_records() {  # <record-dir> <item> <head>
  local dir=$1 item=$2 head=$3
  local f rid raw stored gate state rec_head verdict comment class

  FM_PUB_SEAM_LIVE=0
  FM_PUB_SEAM_GRANTING=0
  FM_PUB_SEAM_GRANTING_ID=
  FM_PUB_SEAM_GRANTING_COMMENT=
  FM_PUB_SEAM_GRANTING_VERDICT=
  FM_PUB_SEAM_HOLDS=

  if [ ! -d "$dir" ]; then
    # Never held a correlation record. A genuine emptiness, not an unreadable one.
    return 0
  fi
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_STORE_UNREADABLE" \
      "the Browser Sol correlation store at $dir could not be enumerated, so this is not an absence of holds"
    return $?
  fi

  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    rid=${f##*/}
    rid=${rid%.json}
    if ! raw=$(cat "$f" 2>/dev/null) || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record $f could not be read, and an unreadable record is exactly the one that might hold $item"
      return $?
    fi
    if [ "$(printf '%s' "$raw" | jq -r '.schema // ""')" != "$FM_OUTBOUND_RECORD_SCHEMA" ]; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record $f does not declare schema $FM_OUTBOUND_RECORD_SCHEMA, so what it holds could not be read"
      return $?
    fi
    # LOCATION IS NOT IDENTITY: a record adopted from its filename can be moved
    # into place, so the record must name itself.
    stored=$(printf '%s' "$raw" | jq -r '.request_id // ""')
    if [ "$stored" != "$rid" ]; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record filed as $rid names request '$stored', so what it holds could not be read"
      return $?
    fi

    [ "$(printf '%s' "$raw" | jq -r '.identity.item // ""')" = "$item" ] || continue
    gate=$(printf '%s' "$raw" | jq -r '.identity.gate // ""')
    fm_landing_seam_gate_governs "$gate" || continue
    state=$(printf '%s' "$raw" | jq -r '.state // ""')
    fm_landing_seam_state_live "$state" || continue

    FM_PUB_SEAM_LIVE=$((FM_PUB_SEAM_LIVE + 1))
    rec_head=$(printf '%s' "$raw" | jq -r '.identity.head // ""')
    verdict=$(printf '%s' "$raw" | jq -r '.ruling.verdict // ""')
    comment=$(printf '%s' "$raw" | jq -r '.ruling.comment_id // ""')

    if [ "$rec_head" != "$head" ]; then
      FM_PUB_SEAM_HOLDS="$FM_PUB_SEAM_HOLDS $rid($gate/$state at ${rec_head:--})"
      continue
    fi
    if [ "$state" != ruled ] || [ -z "$verdict" ]; then
      FM_PUB_SEAM_HOLDS="$FM_PUB_SEAM_HOLDS $rid($gate/$state unruled)"
      continue
    fi
    class=$(fm_auth_verdict_class "$verdict")
    if [ "$class" != authorizing ]; then
      FM_PUB_SEAM_HOLDS="$FM_PUB_SEAM_HOLDS $rid($gate/$state verdict=$verdict/$class)"
      continue
    fi
    FM_PUB_SEAM_GRANTING=$((FM_PUB_SEAM_GRANTING + 1))
    FM_PUB_SEAM_GRANTING_ID=$rid
    FM_PUB_SEAM_GRANTING_COMMENT=$comment
    FM_PUB_SEAM_GRANTING_VERDICT=$verdict
  done
  return 0
}

# --- other actionable candidates for the same semantic work -------------------
#
# GITHUB OPENNESS IS NOT SEMANTIC ACTIONABILITY, which is the defect this closes.
# Several candidates can be open, alive and technically pushable for one piece of
# work; exactly one of them is the successor the fleet means. So a live authority
# already standing for this work at a DIFFERENT head makes this candidate a
# second actionable one, and a second actionable candidate is an ambiguity about
# which head the work is, not a race to be won by whoever pushes first.
#
# `spending` counts as live for the same reason it is reported as indeterminate
# everywhere else: an act that may or may not have happened is exactly the one
# that must block a second candidate.

FM_PUB_SEAM_RIVALS=

fm_pub_seam_scan_authorizations() {  # <auth-dir> <item> <venue> <head>
  local dir=$1 item=$2 venue=$3 head=$4
  local f raw state

  FM_PUB_SEAM_RIVALS=

  [ -d "$dir" ] || return 0
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
      "the publication authorization store at $dir could not be enumerated, so whether another candidate already holds this work could not be observed"
    return $?
  fi

  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if ! raw=$(cat "$f" 2>/dev/null) || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
        "authorization record $f could not be read, and an unreadable one is exactly the one that might already hold this work"
      return $?
    fi
    [ "$(printf '%s' "$raw" | jq -r '.effect // ""')" = publication ] || continue
    [ "$(printf '%s' "$raw" | jq -r '.grant.item // ""')" = "$item" ] || continue
    [ "$(printf '%s' "$raw" | jq -r '.grant.venue // ""')" = "$venue" ] || continue
    [ "$(printf '%s' "$raw" | jq -r '.grant.head // ""')" != "$head" ] || continue
    state=$(printf '%s' "$raw" | jq -r '.state // ""')
    printf '%s\n' "$FM_PUB_SEAM_LIVE_AUTH_STATES" | grep -qxF "$state" || continue
    FM_PUB_SEAM_RIVALS="$FM_PUB_SEAM_RIVALS $(printf '%s' "$raw" | jq -r '.authorization_id // "?"')(${state} at $(printf '%s' "$raw" | jq -r '.grant.head // "?"'))"
  done
  return 0
}

# --- the compiled generation --------------------------------------------------
#
# What the verdict RESTED ON, reduced to one value the authorization identity can
# bind. A newer ruling comment, a different verdict, a bumped policy generation
# or a different declared work identity all change it.
#
# This is what makes commission-time permission revocable. An authority minted
# under generation X addresses generation X and nothing else, so a HOLD, REVISE,
# quarantine or supersession that lands afterwards does not have to be raced: it
# changes the generation, and the permission that was already granted simply no
# longer names the world it is being presented against.

fm_pub_seam_generation() {  # <policy-generation> <request> <comment> <verdict> <venue> <ref> <item>
  printf 'policy=%s\nrequest=%s\ncomment=%s\nverdict=%s\nvenue=%s\nref=%s\nitem=%s\n' \
    "${1:--}" "${2:--}" "${3:--}" "${4:--}" "$5" "$6" "$7" | fm_auth_digest
}

# --- resolution ---------------------------------------------------------------
#
# ONE fold, in one order, because the order is part of the contract.
#
# The no-effect answer comes before every governance question on purpose. A push
# whose remote already equals the head is not a publication that happened to be
# permitted; it is not a publication at all, and asking whether it was permitted
# would produce a verdict about an act nobody is about to perform - and then
# spend an authority for it.
#
# Everything after "governed" is mandatory and unknown-hostile. Before that
# point, an absence is allowed to mean absence; after it, an axis this file
# cannot read is could-not-observe and stops the publication, because a governed
# candidate whose governed identity nobody could establish is the exact case the
# whole mechanism exists for.
#
# `item` may be the literal "-" when the caller has no independent claim of its
# own; the policy's declared work identity is then used. When the caller DOES
# make a claim and the policy declares a different one, that is two sources
# disagreeing about what work this is, and it refuses rather than picking one.

# The work identity the resolution settled on, which the caller needs because the
# policy may have supplied it in place of the caller's own claim.
FM_PUB_SEAM_ITEM=

fm_pub_seam_resolve() {  # <record-dir> <auth-dir> <config-dir> <repo-dir> <item-or-dash> <venue> <ref> <head> <tree> <expected-tip> <observed-tip>
  local records=$1 auths=$2 config=$3 repo=$4
  local item=$5 venue=$6 ref=$7 head=$8 tree=$9 expected=${10} observed=${11}
  local policy_governed=0 declared='' role='' axis value left right
  local policy_generation='' generation='' governed=0

  if ! fm_pub_seam_subject_valid "$item" "$venue" "$ref" "$head" "$tree" "$expected" "$observed"; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_CANDIDATE_UNBOUND" \
      "the publication names ref '$ref' at head '$head' (tree '$tree') on venue '$venue', moving from '$expected' with '$observed' observed, which is not an exact candidate effect, so whether it may proceed could not be asked"
    return $?
  fi

  # NOTHING TO DO, and therefore nothing to authorize.
  if [ "$observed" = "$head" ]; then
    fm_pub_seam_set no-effect "$FM_PUB_SEAM_TOKEN_NO_EFFECT" \
      "$venue already has $ref at $head, so this publication moves nothing and consumes no authorization"
    return $?
  fi

  # THE REMOTE MOVED. Either the caller compiled its plan against a tip that is
  # no longer there, or something published between compilation and here. Both
  # are the same fact and neither may proceed on the plan that was made.
  if [ "$expected" != "$observed" ]; then
    fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_REMOTE_MOVED" \
      "$venue has $ref at $observed while this publication was compiled against $expected, so the remote moved and the planned effect no longer addresses it"
    return $?
  fi

  fm_pub_seam_policy_read "$config"
  if [ "$FM_PUB_SEAM_POLICY_STATE" = unreadable ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" \
      "the publication identity policy at $config/$FM_PUB_SEAM_POLICY_FILE could not be read as JSON, and a policy that failed to parse is exactly the one that might have refused this publication"
    return $?
  fi
  if [ "$FM_PUB_SEAM_POLICY_STATE" = present ]; then
    policy_generation=$(fm_pub_seam_policy_get '.generation // ""')
    if [ -z "$policy_generation" ]; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" \
        "the publication identity policy at $config/$FM_PUB_SEAM_POLICY_FILE declares no generation, so what generation this verdict would rest on could not be observed"
      return $?
    fi
    if fm_pub_seam_policy_venue_governed "$venue"; then
      policy_governed=1
    fi
  fi

  if [ "$policy_governed" -eq 1 ]; then
    declared=$(fm_pub_seam_policy_work "$venue" "$ref" item)
    role=$(fm_pub_seam_policy_work "$venue" "$ref" role)
    if [ -z "$declared" ]; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_WORK_UNDECLARED" \
        "$venue is a governed publication venue and declares no semantic work identity for $ref, so what work this candidate publishes is not established"
      return $?
    fi
    if [ "$item" != '-' ] && [ "$item" != "$declared" ]; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_WORK_UNDECLARED" \
        "this publication claims work '$item' while the governed policy declares $ref carries '$declared', so two sources disagree about what work is being published"
      return $?
    fi
    item=$declared
    [ -n "$role" ] || role=$FM_PUB_SEAM_ROLE_ACTIONABLE
    if [ "$role" != "$FM_PUB_SEAM_ROLE_ACTIONABLE" ]; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_NOT_CANONICAL" \
        "$ref is recorded as '$role' for work $item rather than the canonical successor, so it is retained evidence and not an actionable candidate"
      return $?
    fi
  elif [ "$item" = '-' ]; then
    # A publication that names no work identity cannot be scanned for holds,
    # because a hold is keyed on the work it holds. What that means depends
    # entirely on whether this home has declared any publication governance:
    #
    #   no policy at all   nothing in this home could have governed this
    #                      publication, so it is genuinely ungoverned. This is
    #                      the ordinary case for a remote that is not a forge -
    #                      a local mirror, a test fixture - and refusing it would
    #                      stop every such publication in every home that has not
    #                      opted in, which is a broken guard rather than a strict
    #                      one.
    #   a policy exists    this home HAS opted in, and a publication whose venue
    #                      that policy does not name and whose work is unstated
    #                      is one nobody can place. That is could-not-observe,
    #                      and it is the direction that matters: once governance
    #                      is declared, an unidentifiable subject cannot be the
    #                      way around it.
    if [ "$FM_PUB_SEAM_POLICY_STATE" != absent ]; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_CANDIDATE_UNBOUND" \
        "this publication names no work identity and the publication policy in this home does not name $venue, so whether a hold applies to publishing $ref could not be asked"
      return $?
    fi
    fm_pub_seam_set not-applicable "$FM_PUB_SEAM_TOKEN_NOT_APPLICABLE" \
      "this home declares no publication identity policy and this publication names no work identity, so nothing in it governs publishing $ref on $venue"
    return $?
  fi

  fm_pub_seam_scan_records "$records" "$item" "$head" || return $?

  # Live governance with no venue to resolve it against is a contradiction in
  # this home's own configuration, not an answer about this candidate.
  if [ "$FM_PUB_SEAM_LIVE" -gt 0 ] && ! fm_landing_seam_venue_configured "$config"; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_VENUE_UNCONFIGURED" \
      "$FM_PUB_SEAM_LIVE live Browser Sol request(s) hold $item while no control venue is configured in this home, so whether their rulings apply could not be observed"
    return $?
  fi
  if [ "$FM_PUB_SEAM_LIVE" -gt 0 ] && [ "$FM_PUB_SEAM_GRANTING" -eq 0 ]; then
    fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_ACTIVE_HOLD" \
      "$FM_PUB_SEAM_LIVE live Browser Sol request(s) hold $item and none approves publishing $head:$FM_PUB_SEAM_HOLDS"
    return $?
  fi
  if [ "$FM_PUB_SEAM_GRANTING" -gt 1 ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_AMBIGUOUS" \
      "$FM_PUB_SEAM_GRANTING live Browser Sol requests approve publishing $item at $head, so which authority this publication would rest on could not be determined"
    return $?
  fi

  [ "$FM_PUB_SEAM_GRANTING" -eq 1 ] && governed=1
  [ "$policy_governed" -eq 1 ] && governed=1
  if [ "$governed" -eq 0 ]; then
    fm_pub_seam_set not-applicable "$FM_PUB_SEAM_TOKEN_NOT_APPLICABLE" \
      "no publication identity policy and no live Browser Sol request govern $item on $venue, so publishing $ref at $head is not governed"
    return $?
  fi

  # --- GOVERNED. Every axis below is mandatory and every unknown stops here. ---

  if [ "$policy_governed" -eq 0 ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_IDENTITY_UNOBSERVED" \
      "Browser Sol request $FM_PUB_SEAM_GRANTING_ID governs $item while this home declares no publication identity policy for $venue, so the governed identities this publication would carry could not be observed"
    return $?
  fi

  while IFS= read -r axis; do
    [ -n "$axis" ] || continue
    value=$(fm_pub_seam_policy_identity "$venue" "$axis")
    if [ -z "$value" ]; then
      fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_IDENTITY_UNOBSERVED" \
        "the governed publication policy for $venue declares no $axis identity, so who would be publishing $head as $axis could not be observed"
      return $?
    fi
    if fm_pub_seam_identity_is_placeholder "$value"; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_PLACEHOLDER" \
        "the governed publication policy for $venue declares the placeholder identity '$value' as $axis, which names no party that could be held to this publication"
      return $?
    fi
  done <<< "$FM_PUB_SEAM_IDENTITY_AXES"

  while read -r left right; do
    [ -n "$left" ] || continue
    if [ "$(fm_pub_seam_policy_identity "$venue" "$left")" \
       = "$(fm_pub_seam_policy_identity "$venue" "$right")" ]; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_NOT_DISTINCT" \
        "the governed publication policy for $venue names one identity as both $left and $right, so this publication carries no independent $right"
      return $?
    fi
  done <<< "$FM_PUB_SEAM_DISTINCT_PAIRS"

  if ! fm_pub_seam_observe_commit_identity "$repo" "$head"; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_IDENTITY_UNOBSERVED" \
      "the author and committer of $head could not be read from $repo, which is not the same as this candidate having none"
    return $?
  fi
  for value in "$FM_PUB_SEAM_AUTHOR" "$FM_PUB_SEAM_COMMITTER"; do
    if fm_pub_seam_identity_is_placeholder "$value"; then
      fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_PLACEHOLDER" \
        "$head carries the placeholder identity '$value', which names no party that could be held to this publication"
      return $?
    fi
  done
  if [ "$FM_PUB_SEAM_AUTHOR" != "$(fm_pub_seam_policy_identity "$venue" author)" ]; then
    fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_UNMAPPED" \
      "$head is authored by '$FM_PUB_SEAM_AUTHOR', which is not the governed author $venue declares, so this candidate's authorship maps to no governed party"
    return $?
  fi
  if [ "$FM_PUB_SEAM_COMMITTER" != "$(fm_pub_seam_policy_identity "$venue" committer)" ]; then
    fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_UNMAPPED" \
      "$head is committed by '$FM_PUB_SEAM_COMMITTER', which is not the governed committer $venue declares, so this candidate's delivery maps to no governed party"
    return $?
  fi

  fm_pub_seam_scan_authorizations "$auths" "$item" "$venue" "$head" || return $?
  if [ -n "$FM_PUB_SEAM_RIVALS" ]; then
    fm_pub_seam_set refused "$FM_PUB_SEAM_TOKEN_DUPLICATE" \
      "work $item already has a live publication authority at another head on $venue:$FM_PUB_SEAM_RIVALS - which head this work is cannot be settled by whichever candidate pushes first"
    return $?
  fi

  generation=$(fm_pub_seam_generation "$policy_generation" "$FM_PUB_SEAM_GRANTING_ID" \
    "$FM_PUB_SEAM_GRANTING_COMMENT" "$FM_PUB_SEAM_GRANTING_VERDICT" "$venue" "$ref" "$item")
  if [ -z "$generation" ]; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" \
      "the ruling and policy generation for $item on $venue could not be compiled, so what this verdict would rest on could not be observed"
    return $?
  fi

  # shellcheck disable=SC2034  # read by the sourcing publication paths
  FM_PUB_SEAM_ITEM=$item
  fm_pub_seam_set allow-exact "$FM_PUB_SEAM_TOKEN_ALLOW" \
    "publishing $ref at $head on $venue from $expected is governed and permitted for work $item" \
    "$FM_PUB_SEAM_GRANTING_ID" "$generation"
  return $?
}

# --- the wiring ---------------------------------------------------------------
#
# THE ONLY WIRING, deliberately, for the same reason bin/fm-landing-seam-lib.sh
# is the only wiring for the two merge gates: two publication paths that each
# reached the guard their own way would drift into two different answers about
# whether a publication was governed, and the one that drifted looser would be
# the one that mattered.
#
# THE ACT RUNS INSIDE THE CONSUME. A caller that asked "may I publish?" and then
# published would have a window between the two, and this fleet has already
# named what lands in that window. So the command is handed to the guard rather
# than run after it, and the guard writes its intent record before reaching it.
#
# An UNGOVERNED publication still runs, and still reports that it ran ungoverned.
# That is the landing seam's rule and it is held here for its reason: the failure
# being replaced is a home that looks authorised because nothing spoke.

# What the act itself said, so a caller can relay the remote's own words. A push
# refused by a server explains why in text only that server has, and a guard that
# swallowed it would leave the operator repairing the guard instead of the rule
# the server named.
# shellcheck disable=SC2034  # read by the sourcing publication paths
FM_PUB_SEAM_OUTPUT=

# The guard prints its verdict word first and its stable token second on a
# refusal or a could-not-observe (`REFUSE <token>: ...`), so the token a caller
# matches on is the SECOND field there and the first everywhere else. Reading the
# first field unconditionally reported the token as the literal `REFUSE`, which
# is the one thing a caller relaying it must never say: it names the shape of the
# answer instead of the reason for it.
fm_pub_seam_token_of() {  # <guard-output>
  local first second
  first=$(printf '%s\n' "${1:-}" | awk 'NF {print $1; exit}')
  second=$(printf '%s\n' "${1:-}" | awk 'NF {print $2; exit}')
  second=${second%:}
  case $first in
    REFUSE|CNO) printf '%s\n' "${second:-$first}" ;;
    *) printf '%s\n' "$first" ;;
  esac
}

fm_pub_seam_publish() {  # <guard> <repo> <remote> <venue> <ref> <head> <expected-tip> <item-or-dash> <command...>
  local guard=$1 repo=$2 remote=$3 venue=$4 ref=$5 head=$6 expected=$7 item=$8
  shift 8
  local out rc=0 word id act
  FM_PUB_SEAM_OUTPUT=

  out=$("$guard" prepare --repo "$repo" --remote "$remote" --venue "$venue" \
    --ref "$ref" --head "$head" --expected-tip "$expected" --item "$item" 2>&1) || rc=$?
  word=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}')

  if [ "$rc" -eq 3 ]; then
    fm_pub_seam_set refused "$(fm_pub_seam_token_of "$out")" \
      "publishing $ref at $head on $venue was refused before the remote was touched: $out"
    return $?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_pub_seam_set unobserved "$(fm_pub_seam_token_of "$out")" \
      "whether publishing $ref at $head on $venue may proceed could not be observed, so it did not: $out"
    return $?
  fi

  case $word in
    NO_EFFECT_ALREADY_EQUAL)
      fm_pub_seam_set no-effect "$FM_PUB_SEAM_TOKEN_NO_EFFECT" \
        "$venue already has $ref at $head, so nothing was published and no authority was consumed"
      return $?
      ;;
    NOT_APPLICABLE)
      rc=0
      act=$("$@" 2>&1) || rc=$?
      FM_PUB_SEAM_OUTPUT=$act
      if [ "$rc" -ne 0 ]; then
        fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_TIP_UNOBSERVED" \
          "the ungoverned publication of $ref at $head exited $rc, which does not establish that it had no effect"
        return $?
      fi
      fm_pub_seam_set not-applicable "$FM_PUB_SEAM_TOKEN_NOT_APPLICABLE" \
        "no publication identity policy and no live Browser Sol request govern $ref on $venue, so it was published ungoverned"
      return $?
      ;;
    ALLOW_EXACT) ;;
    *)
      fm_pub_seam_set unobserved "$(fm_pub_seam_token_of "$out")" \
        "the publication guard answered '$out', which is not one of its results, so publishing $ref did not proceed"
      return $?
      ;;
  esac

  id=$(printf '%s\n' "$out" | awk 'NF {print $2; exit}')
  if ! fm_auth_id_valid "$id"; then
    fm_pub_seam_set unobserved "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
      "the publication guard permitted $ref at $head and returned no authorization id: $out"
    return $?
  fi

  rc=0
  out=$("$guard" consume "$id" --repo "$repo" --remote "$remote" -- "$@" 2>&1) || rc=$?
  # shellcheck disable=SC2034  # read by the sourcing publication paths
  FM_PUB_SEAM_OUTPUT=$out
  word=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}')
  case $rc in
    0)
      case $word in
        NO_EFFECT_ALREADY_EQUAL)
          fm_pub_seam_set no-effect "$FM_PUB_SEAM_TOKEN_NO_EFFECT" \
            "$venue already had $ref at $head by the time the authority was consumed, so nothing was published"
          return $?
          ;;
      esac
      fm_pub_seam_set allow-exact "$FM_PUB_SEAM_TOKEN_ALLOW" \
        "$ref was published at $head on $venue under authority $id, confirmed on the remote" '' ''
      return $?
      ;;
    3)
      fm_pub_seam_set refused "$(fm_pub_seam_token_of "$out")" \
        "authority $id refused to publish $ref at $head: $out"
      return $?
      ;;
    *)
      fm_pub_seam_set unobserved "$(fm_pub_seam_token_of "$out")" \
        "publishing $ref at $head under authority $id reached no confirmed result: $out"
      return $?
      ;;
  esac
}

# fail-closed-predicates: enforced
