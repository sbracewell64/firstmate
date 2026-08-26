#!/usr/bin/env bash
# Single owner of a task's TWO base references. A dispatched worker needs two
# different commits and the previous spawn path supplied only one, so a brief
# citing a file or a line number is silently unreliable whenever they differ:
#
#   slot base           the commit the task's worktree is placed at, so reads,
#                       greps, line citations and running the code all resolve
#                       against what the fleet ACTUALLY RUNS. This is the local
#                       default-branch tip of the project checkout - the same
#                       local-HEAD target secondmates already sync to, and no
#                       fetch is involved.
#   contribution target the commit the task's branch is CUT FROM, so the PR
#                       carries only the task's own commits. On a fork setup
#                       that is the upstream trunk, which is NOT the slot base.
#
# Cutting the branch from the slot base instead is the pollution this file
# exists to prevent: it silently carries every fleet-only commit into the
# contribution. Resetting the slot to the contribution target instead dispatches
# the task onto a trunk missing the code it edits. Neither single ref satisfies
# both roles, so both are resolved, recorded, and stated separately.
#
# Sourced by bin/fm-spawn.sh (resolves and records them), bin/fm-brief.sh
# (states them to the worker), and bin/fm-pr-check.sh (compares a pull request
# against the venue the spawn recorded). It sources bin/fm-landed-lib.sh itself,
# for the fetch-url-versus-push-url comparison both libraries reason about and
# for the name of the ref that holds the fork trunk when the local branch lags,
# and bin/fm-timeout-lib.sh, for the bound on its one external read.
#
# IT SPLITS IN TWO ALONG THE ONE DEPENDENCY IT DOES NOT SOURCE. Everything that
# reads a ref - task_base_resolve, task_base_upstream_ref, task_base_venue,
# task_base_verify_branch - reaches default_branch and primary_head_commit from
# bin/fm-ff-lib.sh, so a caller of those must source that lib first. The
# identity half - task_base_venue_identity and task_base_venue_identity_alias -
# is string and ssh-config work over a URL and needs nothing else, and
# bin/fm-pr-check.sh sources this lib for that half alone. Bash resolves
# function names at call time, so a caller reaching past its half gets a
# runtime `default_branch: command not found` rather than a failure to source.
#
# task_base_resolve <repo-dir> sets, and clears first:
#   TASK_BASE_SLOT          slot base commit SHA
#   TASK_BASE_SLOT_REF      the ref it was read from
#   TASK_BASE_CONTRIB       contribution target commit SHA (empty when unresolved)
#   TASK_BASE_CONTRIB_REF   the ref it was read from (or the one that failed)
#   TASK_BASE_STATE         coincident | distinct | unresolved
#   TASK_BASE_ERROR         human-readable reason when resolution degraded
#
# TASK_BASE_STATE is the whole contract in one word:
#   coincident  no distinct upstream, or upstream is already the slot base.
#               The two roles collapse to one commit and nothing changes.
#   distinct    the two differ. The worker MUST be told: read at the slot base,
#               cut its branch at the contribution target.
#   unresolved  an upstream relationship exists but its trunk cannot be read
#               locally. Refused rather than guessed, because silently falling
#               back to the slot base is exactly the pollution above.
#
# THE VENUE IS THE THIRD PROPERTY OF THE SAME CONTRACT
# A contribution target names a commit; it also, implicitly, names the repository
# that commit's trunk belongs to. That repository is where the task's pull
# request has to be raised, and it is NOT a per-project constant on a fork
# layout: a task cut from the upstream trunk belongs upstream, and a task cut
# from the fork trunk belongs at the fork. Deriving it from the target rather
# than from a fixed per-project setting is what makes the venue follow the task.
#
# task_base_venue derives it, and derives it from the target VALUE rather than
# from TASK_BASE_STATE, because the target can be overridden after resolution -
# retargeting a task onto fork-only material is exactly that override, and the
# venue has to move with it.

# shellcheck disable=SC2034 # The resolution outputs are read by callers (fm-spawn.sh) and tests, not by this lib.
TASK_BASE_SLOT='' TASK_BASE_SLOT_REF='' TASK_BASE_CONTRIB='' TASK_BASE_CONTRIB_REF='' TASK_BASE_STATE='' TASK_BASE_ERROR=''
# shellcheck disable=SC2034 # Same: consumed by fm-spawn.sh (records them) and tests.
TASK_BASE_VENUE='' TASK_BASE_VENUE_URL=''
TASK_BASE_POLICY_VENUE='' TASK_BASE_POLICY_URL='' TASK_BASE_POLICY_REF=''
# shellcheck disable=SC2034 # The rest of the policy role tuple, read by bin/fm-attest.sh and tests.
TASK_BASE_POLICY_GENERATION='' TASK_BASE_POLICY_ROLE='' TASK_BASE_POLICY_TARGET=''

task_base_metadata_field() {  # <meta-file> <key>
  local file=${1-} key=${2-}
  [ -f "$file" ] && [ ! -L "$file" ] && [ -n "$key" ] || return 1
  awk -F= -v key="$key" '
    $1 == key { value=substr($0, length(key) + 2); seen[value]=1 }
    END {
      for (value in seen) { count++; only=value }
      if (count == 0 || (count == 1 && only == "")) exit 1
      if (count != 1) exit 2
      print only
    }
  ' "$file"
}

# The POLICY ROLE TUPLE, normalized once here and consumed downstream.
#
# A contribution target is a commit. Policy is owned by a REF, and a commit is
# only ever the generation that ref resolved to at some moment. Collapsing the
# two - which this function used to do, mapping contribution_target straight
# into the policy ref slot - records an input but establishes no policy role:
# it cannot tell a generation that is current from one the venue has since
# moved past, and it cannot tell a target that IS the policy ref from one that
# merely happens to sit on the same commit today.
#
# So the two axes are carried separately and the RELATIONSHIP between them is
# recorded rather than inferred:
#
#   TASK_BASE_POLICY_VENUE       forge identity of the governed venue
#   TASK_BASE_POLICY_URL         the URL that venue is read from
#   TASK_BASE_POLICY_TARGET      the contribution target commit - the CANDIDATE's
#                                base, which is its own axis and never authority
#                                over what the venue's policy is
#   TASK_BASE_POLICY_REF         the NAMED ref that owns policy at that venue,
#                                empty when nothing recorded one
#   TASK_BASE_POLICY_GENERATION  the exact commit policy is read from
#   TASK_BASE_POLICY_ROLE        HOW the relationship was established
#
# TASK_BASE_POLICY_ROLE is the whole contract in one word, and it is the field
# that keeps this honest, because it makes "nobody recorded this" a distinct
# answer from "this was recorded as equivalent":
#
#   recorded            the task metadata names a policy ref outright.
#   target-equivalence  the metadata records, explicitly and as its own
#                       statement, that the contribution target IS the policy
#                       ref for this venue. The ruling allows that equivalence
#                       and requires it be recorded, never assumed because two
#                       strings or two commits coincide.
#   unrecorded          neither. A generation is still carried, because reading
#                       a declaration out of it is still meaningful, but it
#                       carries no ref role, and bin/fm-attest.sh must not
#                       treat it as authority over what the venue currently
#                       requires.
#
# Returns 2 when the metadata could not be read; the optional policy fields
# being absent is an ordinary recorded state, not a read failure.
TASK_BASE_POLICY_TARGET_EQUIVALENCE=contribution-target

# The venue-side spelling of the ref a contribution target was read from.
#
# task_base_resolve names that ref the way THIS checkout addresses it -
# `upstream/main`, `origin/main`, or the bare local branch - and none of those
# is a ref at the venue. The venue holds `refs/heads/main`. The mapping is the
# same two-shape resolution task_base_upstream_ref already performs, so this
# adds no new claim about the topology: it restates the ref that resolution
# picked, in the namespace the venue actually serves it from.
#
# This is what lets a spawn RECORD which ref owns policy instead of leaving it
# unrecorded, and an unrecorded one is not a small gap - it makes the currency
# question unanswerable for every task, which bin/fm-attest.sh then has to
# report as could-not-observe.
#
# Prints the ref, or returns 1 when the name is not one this can place at the
# venue - which is a refusal to guess, not a licence to fall back to HEAD.
task_base_policy_ref_for() {  # <contribution-ref>
  local ref=${1-} name
  case $ref in
    '' | unresolved) return 1 ;;
    refs/*) printf '%s\n' "$ref"; return 0 ;;
  esac
  name=${ref##*/}
  case $name in
    '' | *[[:space:]]* | *[[:cntrl:]]* | -*) return 1 ;;
  esac
  printf 'refs/heads/%s\n' "$name"
}

task_base_policy_metadata() {  # <meta-file>
  local file=${1-} recorded_ref recorded_generation
  TASK_BASE_POLICY_VENUE=
  TASK_BASE_POLICY_URL=
  TASK_BASE_POLICY_REF=
  TASK_BASE_POLICY_GENERATION=
  TASK_BASE_POLICY_ROLE=
  TASK_BASE_POLICY_TARGET=
  TASK_BASE_POLICY_VENUE=$(task_base_metadata_field "$file" contribution_venue) || return 2
  TASK_BASE_POLICY_URL=$(task_base_metadata_field "$file" contribution_venue_url) || return 2
  TASK_BASE_POLICY_TARGET=$(task_base_metadata_field "$file" contribution_target) || return 2

  # An absent optional field is a recorded state; only an AMBIGUOUS one (the
  # same key written twice with different values) is a read failure, and
  # task_base_metadata_field separates those as exit 1 and exit 2.
  recorded_ref=$(task_base_metadata_field "$file" policy_ref)
  case $? in
    0 | 1) ;;
    *) return 2 ;;
  esac
  recorded_generation=$(task_base_metadata_field "$file" policy_generation)
  case $? in
    0 | 1) ;;
    *) return 2 ;;
  esac

  if [ -z "$recorded_ref" ]; then
    TASK_BASE_POLICY_ROLE=unrecorded
    TASK_BASE_POLICY_GENERATION=$TASK_BASE_POLICY_TARGET
    return 0
  fi
  if [ "$recorded_ref" = "$TASK_BASE_POLICY_TARGET_EQUIVALENCE" ]; then
    TASK_BASE_POLICY_ROLE="target-equivalence"
    TASK_BASE_POLICY_REF=$TASK_BASE_POLICY_TARGET
    TASK_BASE_POLICY_GENERATION=$TASK_BASE_POLICY_TARGET
    return 0
  fi
  TASK_BASE_POLICY_ROLE=recorded
  TASK_BASE_POLICY_REF=$recorded_ref
  TASK_BASE_POLICY_GENERATION=${recorded_generation:-$TASK_BASE_POLICY_TARGET}
  return 0
}

# shellcheck source=bin/fm-landed-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-landed-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# Name the remote-tracking ref that holds the UPSTREAM trunk, when this repo
# contributes somewhere other than where it pushes. Two shapes are recognized:
#   1. a separate `upstream` remote (the conventional fork layout), and
#   2. an `origin` whose fetch URL differs from its push URL, which is the
#      layout firstmate itself uses - origin FETCHES upstream and PUSHES the
#      fork, so `origin/<default>` is the upstream trunk while local
#      `<default>` is the fork trunk.
# The fetch/push comparison in shape 2 is bin/fm-landed-lib.sh's
# fm_landed_push_url, so the two libraries that care about that split read it
# the same way: this one names the upstream side, that one the landing side.
# Prints the ref name; 1 when no distinct upstream PROVABLY exists, and 2 when
# that could not be read. The two are separated because "there is no distinct
# upstream" is what collapses the two base references onto one commit, and a
# repository whose remotes went unread has not established that.
task_base_upstream_ref() {  # <repo-dir>
  local dir=$1 default status
  if git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    default=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/upstream/HEAD 2>/dev/null) \
      && { printf '%s\n' "$default"; return 0; }
    default=$(default_branch "$dir") || return 2
    printf 'upstream/%s\n' "$default"
    return 0
  fi
  # That read fails both for a repository with no `upstream` remote and for one
  # whose configuration could not be read, so shape 1 is ruled out only by an
  # enumeration that positively does not list it.
  fm_landed_remote_listed "$dir" upstream
  status=$?
  [ "$status" -eq 1 ] || return 2
  fm_landed_push_url "$dir" >/dev/null
  status=$?
  [ "$status" -eq 1 ] && return 1
  [ "$status" -eq 0 ] || return 2
  default=$(default_branch "$dir") || return 2
  printf 'origin/%s\n' "$default"
}

task_base_resolve() {  # <repo-dir>
  local dir=$1 upstream_ref upstream_sha status
  TASK_BASE_SLOT=
  TASK_BASE_SLOT_REF=
  TASK_BASE_CONTRIB=
  TASK_BASE_CONTRIB_REF=
  TASK_BASE_STATE=
  TASK_BASE_ERROR=

  TASK_BASE_SLOT_REF=$(default_branch "$dir" 2>/dev/null) || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="no default branch in $dir"
    return 1
  }
  TASK_BASE_SLOT=$(primary_head_commit "$dir") || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="default branch $TASK_BASE_SLOT_REF has no commit in $dir"
    return 1
  }

  # No distinct upstream: the two roles collapse onto the slot base and every
  # caller stays on today's single-reference behavior. That collapse is a claim
  # about the repository's remotes, so it is made only when they were read - a
  # could-not-observe reports unresolved instead, exactly like an upstream trunk
  # that was named but could not be read below.
  upstream_ref=$(task_base_upstream_ref "$dir")
  status=$?
  if [ "$status" -eq 1 ]; then
    TASK_BASE_CONTRIB=$TASK_BASE_SLOT
    TASK_BASE_CONTRIB_REF=$TASK_BASE_SLOT_REF
    TASK_BASE_STATE=coincident
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="whether $dir contributes somewhere other than where it pushes could not be read, so the two base references cannot be collapsed onto one"
    return 0
  fi

  TASK_BASE_CONTRIB_REF=$upstream_ref
  if ! upstream_sha=$(git -C "$dir" rev-parse --verify --quiet "$upstream_ref^{commit}" 2>/dev/null); then
    # Refuse to guess. Falling back to the slot base here would cut the branch
    # at the fork trunk and carry every fleet-only commit into the PR.
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="upstream trunk $upstream_ref is not readable locally (never fetched?)"
    return 0
  fi
  TASK_BASE_CONTRIB=$upstream_sha
  if [ "$upstream_sha" = "$TASK_BASE_SLOT" ]; then
    TASK_BASE_STATE=coincident
  else
    TASK_BASE_STATE=distinct
  fi
  return 0
}

# The pollution guard. A branch cut from the contribution target descends from
# it, so the target is an ancestor of the branch head and `target..branch` holds
# only the task's own commits. A branch cut from the slot base instead does NOT
# descend from a diverged upstream target, and this fails - which is the whole
# point: it catches the polluted branch whether or not the worker has committed
# anything on top yet.
# Returns 0 clean, 1 polluted, 2 when a ref cannot be read.
task_base_verify_branch() {  # <repo-dir> <contribution-target> <branch-ref>
  local dir=$1 target=$2 branch=$3 target_sha branch_sha
  TASK_BASE_ERROR=
  target_sha=$(git -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }
  branch_sha=$(git -C "$dir" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="branch '$branch' is not a readable commit"
    return 2
  }
  if git -C "$dir" merge-base --is-ancestor "$target_sha" "$branch_sha"; then
    return 0
  fi
  local extra
  extra=$(git -C "$dir" rev-list --count "$target_sha..$branch_sha" 2>/dev/null || echo '?')
  TASK_BASE_ERROR="branch '$branch' does not descend from contribution target '$target'; it carries $extra commit(s) absent from that target, so a PR from it would contribute work the target never had"
  return 1
}

# A remote URL reduced to the forge identity "host/owner/repo", so a recorded
# venue can be compared against a pull request URL without either side keeping a
# second URL parser. Deliberately NOT a general URL parser: it recognizes the
# transports git uses to address a forge and refuses everything else, because a
# venue this cannot name is a venue no guard may claim to have checked.
# Lowercased, since forge hosts and GitHub/GitLab paths are case-insensitive and
# a case difference must never read as a different venue.
# Prints the identity, or returns 1 when the URL names no forge (a local path, a
# file: URL, or any shape without a host and a path).
task_base_venue_identity() {  # <url>
  local url=${1-} rest host path
  case $url in
    '' | /* | file://*) return 1 ;;
  esac
  case $url in
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac

  case $url in
    https://* | http://* | ssh://* | git://*)
      rest=${url#*://}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 1
      host=${host##*@}
      # A port is addressing, not identity, so two URLs differing only by port
      # are the same venue. A bracketed IPv6 literal keeps its brackets.
      case $host in
        '['*']':*) host=${host%:*} ;;
        '['*']') ;;
        *:*) host=${host%%:*} ;;
      esac
      ;;
    *:*)
      # scp-like [user@]host:path, which has no scheme to strip.
      rest=${url##*@}
      host=${rest%%:*}
      path=${rest#*:}
      case $host in
        *'/'*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac

  path=${path%/}
  path=${path%.git}
  path=${path#/}
  [ -n "$host" ] && [ -n "$path" ] || return 1
  printf '%s/%s\n' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

# The same identity with an SSH HOST ALIAS resolved to the host it actually
# addresses. `git@gh-work:owner/repo` is the ordinary way one machine addresses
# two accounts at the same forge, and it names the venue "gh-work/owner/repo"
# while every pull request raised at that repository is "github.com/owner/repo".
# The alias is addressing, not identity, exactly like the port stripped above.
#
# Resolution reads configuration rather than the forge: `ssh -G` prints the
# effective client configuration and opens no connection to the repository. It
# is NOT inert, though - it evaluates any `Match exec` block in the user's
# ssh_config, which runs a shell command, and it can resolve names under
# CanonicalizeHostname. This sits on the landing path, where an unbounded read
# would stall every arm and every merge routed through bin/fm-pr-check.sh, so it
# goes through the repo's own hard bound and an expired read simply yields no
# alternative identity.
#
# This is an ALTERNATIVE identity, never a replacement. A caller compares
# against the literal identity AND this one, because a configuration that
# rewrites a real forge host rather than aliasing a private name would otherwise
# turn a venue that matches today into a refusal.
# Prints the resolved identity, or returns 1 when there is nothing to resolve: a
# non-SSH transport, no ssh to ask, a host name that is not a plain alias, or a
# host that resolves to itself.
TASK_BASE_SSH_CONFIG_TIMEOUT=${FM_TASK_BASE_SSH_CONFIG_TIMEOUT:-5}
case "$TASK_BASE_SSH_CONFIG_TIMEOUT" in ''|*[!0-9]*|0) TASK_BASE_SSH_CONFIG_TIMEOUT=5 ;; esac

task_base_venue_identity_alias() {  # <url>
  local url=${1-} rest host resolved identity
  case $url in
    ssh://*)
      rest=${url#ssh://}
      rest=${rest%%/*}
      host=${rest##*@}
      host=${host%%:*}
      ;;
    '' | /* | file://* | https://* | http://* | git://*) return 1 ;;
    *:*)
      rest=${url##*@}
      host=${rest%%:*}
      ;;
    *) return 1 ;;
  esac
  # Only a plain alias label is resolvable, and refusing everything else keeps
  # a host that could be read as an option away from ssh's argument list.
  case $host in
    '' | -* | *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  command -v ssh >/dev/null 2>&1 || return 1
  resolved=$(fm_run_timed "$TASK_BASE_SSH_CONFIG_TIMEOUT" ssh -G "$host" 2>/dev/null \
    | awk '$1 == "hostname" { print $2; exit }') || return 1
  [ -n "$resolved" ] && [ "$resolved" != "$host" ] || return 1
  identity=$(task_base_venue_identity "$url") || return 1
  printf '%s/%s\n' "$resolved" "${identity#*/}" | tr '[:upper:]' '[:lower:]'
}

task_base_remote_safe_url() {  # <url>
  local url=${1-} base scheme rest authority path host
  case $url in ''|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;; esac
  task_base_remote_url_is_credential_bearing "$url" && return 1
  base=$url
  [ -n "$base" ] || return 1
  case $base in
    file:///*)
      path=${base#file://}
      [ -n "$path" ] || return 1
      printf 'file://%s\n' "$(fm_landed_normalize_url "$path")"
      ;;
    https://*|http://*|ssh://*|git://*)
      scheme=${base%%://*}
      rest=${base#*://}
      authority=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 1
      authority=${authority##*@}
      case $authority in ''|*@*|*'/'*) return 1 ;; esac
      [ -n "$path" ] || return 1
      printf '%s://%s/%s\n' "$scheme" "$authority" "$(fm_landed_normalize_url "$path")"
      ;;
    /*|./*|../*)
      printf '%s\n' "$(fm_landed_normalize_url "$base")"
      ;;
    *:*)
      rest=${base##*@}
      host=${rest%%:*}
      path=${rest#*:}
      case $host in ''|*'/'*|*@*) return 1 ;; esac
      [ -n "$path" ] && [ "$path" != "$rest" ] || return 1
      printf '%s:%s\n' "$host" "$(fm_landed_normalize_url "$path")"
      ;;
    *) return 1 ;;
  esac
}

task_base_remote_url_is_credential_bearing() {  # <url>
  local url=${1-} rest authority
  case $url in *\?*|*\#*) return 0 ;; esac
  case $url in
    https://*|http://*|ssh://*|git://*)
      rest=${url#*://}
      authority=${rest%%/*}
      case $authority in *@*) return 0 ;; esac
      ;;
    *:*)
      rest=${url%%:*}
      case $rest in *@*) return 0 ;; esac
      ;;
  esac
  return 1
}

# The venue a contribution target names, set into TASK_BASE_VENUE_URL (the
# remote URL) and TASK_BASE_VENUE (its comparable forge identity, empty when the
# URL names no forge).
#
# Both trunks are named by the SAME two-shape upstream resolution
# task_base_upstream_ref performs, so every layout that has a distinct upstream
# derives a venue from it: a separate `upstream` remote names the upstream side
# directly and leaves origin as the fork, and an origin with a fetch/push split
# fetches the upstream side and pushes the fork. Recognizing only the second
# shape would record the fork venue for an upstream-cut task and refuse its
# correct pull request.
#
# The ordering below is the safety property, not a preference. Upstream is
# tested FIRST, so a target the upstream trunk already reaches resolves upstream
# and a target it does not reach can never resolve there. Fork-only commits are
# by definition unreachable from the upstream trunk, so no fork-only target can
# be assigned the upstream venue - which is the inversion that turns a five
# commit contribution into a thirty two commit one.
#
# The fork trunk is then tested against every ref that can hold it, because the
# local branch is the fork trunk only while something keeps fast-forwarding it.
# bin/fm-landed-lib.sh owns that candidate list - it already names the local
# branch, the refs/fm-landing/origin/<name> ref it maintains for exactly that
# lag, and origin's trunk, filtered to the ones that exist - so a target already
# on the fork trunk at the forge resolves the fork venue instead of degrading to
# unresolved and leaving its request unchecked.
#
# EVERY TRUNK IS PROVEN READABLE BEFORE IT IS TESTED. `merge-base --is-ancestor`
# fails FATALLY on a ref that does not resolve, which is indistinguishable from
# a clean "not an ancestor" once the error is discarded, so an unfetched trunk
# would silently hand its targets to whichever trunk IS readable - the exact
# inversion this derivation exists to prevent.
#
# 0 with the venue set, 2 when it could not be derived. There is no "probably";
# an underivable venue is reported so a caller can refuse rather than guess.
task_base_venue() {  # <repo-dir> <contribution-target>
  local dir=$1 target=${2-} fetch_url push_url upstream_url upstream_ref name target_sha ref fork_seen
  local status refs complete
  TASK_BASE_VENUE=
  TASK_BASE_VENUE_URL=
  TASK_BASE_ERROR=

  target_sha=$(git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }
  fetch_url=$(git --no-optional-locks -C "$dir" remote get-url origin 2>/dev/null) || {
    TASK_BASE_ERROR="no origin remote in $dir, so no venue can be named"
    return 2
  }

  # No distinct upstream: the project has one venue and every target names it.
  # Only a PROVEN absence names it, because this branch writes a venue that
  # bin/fm-pr-check.sh will later refuse a contradicting pull request against -
  # so deriving it from remotes that went unread would refuse a correct request.
  upstream_ref=$(task_base_upstream_ref "$dir")
  status=$?
  if [ "$status" -eq 1 ]; then
    TASK_BASE_VENUE_URL=$fetch_url
    TASK_BASE_VENUE=$(task_base_venue_identity "$fetch_url" || true)
    return 0
  fi
  if [ "$status" -ne 0 ]; then
    TASK_BASE_ERROR="whether $dir contributes somewhere other than where it pushes could not be read, so the venue '$target' names cannot be derived"
    return 2
  fi

  # An upstream relationship exists but its trunk was never fetched. Refused for
  # the same reason task_base_resolve refuses it: guessing past it would assign
  # an upstream-cut task the fork venue, and bin/fm-pr-check.sh would then refuse
  # that task's own correct pull request.
  if ! git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$upstream_ref^{commit}" >/dev/null 2>&1; then
    TASK_BASE_ERROR="upstream trunk $upstream_ref is not readable locally (never fetched?), so the venue '$target' names cannot be derived"
    return 2
  fi

  # Which url is which follows the shape task_base_upstream_ref just resolved: a
  # separate `upstream` remote names the upstream side, and otherwise origin
  # FETCHES the upstream side and PUSHES the fork.
  upstream_url=$(git --no-optional-locks -C "$dir" remote get-url upstream 2>/dev/null) || upstream_url=$fetch_url
  # The fetch url stands in for the push url only when there PROVABLY is no
  # distinct one. A push url that could not be read is a different fact, and
  # recording the fetch url as the venue in that case names the wrong forge.
  push_url=$(fm_landed_push_url "$dir")
  status=$?
  if [ "$status" -eq 1 ]; then
    push_url=$fetch_url
  elif [ "$status" -ne 0 ]; then
    TASK_BASE_ERROR="the url $dir pushes to could not be read, so the venue '$target' names cannot be derived"
    return 2
  fi

  if git --no-optional-locks -C "$dir" merge-base --is-ancestor \
    "$target_sha" "$upstream_ref" 2>/dev/null; then
    TASK_BASE_VENUE_URL=$upstream_url
    TASK_BASE_VENUE=$(task_base_venue_identity "$upstream_url" || true)
    return 0
  fi

  name=$(default_branch "$dir" 2>/dev/null) || {
    TASK_BASE_ERROR="no default branch in $dir, so the fork trunk cannot be named"
    return 2
  }
  # Read into a variable rather than a process substitution: the completeness of
  # this list is carried by the exit status, and a `< <(...)` redirection
  # discards it. Both conclusions below are negatives over the whole candidate
  # set, so a list that is merely non-empty is not enough to reach either.
  refs=$(fm_landed_candidate_refs "$dir" "$name")
  complete=$?
  fork_seen=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    fork_seen=1
    if git --no-optional-locks -C "$dir" merge-base --is-ancestor \
      "$target_sha" "$ref" 2>/dev/null; then
      TASK_BASE_VENUE_URL=$push_url
      TASK_BASE_VENUE=$(task_base_venue_identity "$push_url" || true)
      return 0
    fi
  done <<EOF
$refs
EOF
  if [ "$complete" -eq 2 ]; then
    TASK_BASE_ERROR="the refs that could hold the fork trunk $name could not be fully enumerated in $dir, so the venue '$target' names cannot be derived"
    return 2
  fi
  if [ "$fork_seen" -eq 0 ]; then
    TASK_BASE_ERROR="fork trunk $name is not held by any ref in $dir, so the venue '$target' names cannot be derived"
    return 2
  fi

  TASK_BASE_ERROR="contribution target '$target' is on neither the upstream trunk ($upstream_ref) nor the fork trunk ($name), so the venue it names cannot be derived"
  return 2
}
