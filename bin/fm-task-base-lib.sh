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
#                       contributing upstream that is the upstream trunk, which
#                       is NOT the slot base.
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
# THE CHECKOUT CANNOT NAME THE VENUE ON ITS OWN
# A fork layout has TWO trunks a task could be contributed to, and a clone that
# contributes to its fork looks exactly like a clone that contributes upstream.
# So the derivation below - which reads only the remotes - answered a question
# the remotes do not hold, and sent fork-approved work to an upstream repository
# whose trunk does not even carry the material that work builds on.
#
# The captain's standing answer is registry data. bin/fm-project-mode.sh's
# --contribution owns it and names exactly three words, which every entry point
# here takes as an optional last argument and defaults to when it is absent:
#
#   default   derive from the remotes, which is every behavior described below
#             and what an unregistered project and a project with no registered
#             posture both keep.
#   fork      the project contributes where it PUSHES. The two base references
#             collapse onto the slot base, and the venue is the push side - no
#             upstream trunk is read, because none is being contributed to.
#   upstream  the project contributes to its upstream trunk, which is the
#             derivation below made explicit. A repository with no upstream
#             distinct from where it pushes is then a CONTRADICTION rather than
#             a collapse: refused, not quietly resolved to the fork.
#
# A posture this cannot name is refused everywhere it is accepted. Picking
# between a fork and an upstream on the captain's behalf is precisely the guess
# the token was recorded to remove, so a caller handing this an unrecognized
# word gets a refusal rather than the derivation the token was meant to replace.
#
# THE POSTURE IS A STANDING DEFAULT, NOT AN OVERRIDE OF ONE. An explicit
# per-task contribution target still wins over both the posture and the
# derivation: bin/fm-spawn.sh applies --contribution-target after this resolution
# and then derives that task's venue with the posture withheld, so a single task
# aimed at the other trunk lands at the other trunk.
#
# task_base_resolve <repo-dir> [<contribution-posture>] sets, and clears first:
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
#               back to the slot base is exactly the pollution above. A
#               registered upstream posture on a repository with no distinct
#               upstream reports the same state, for the same reason: the trunk
#               the captain named is not there to cut from.
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
# venue has to move with it. A REGISTERED posture is the one input that is not a
# property of the task: it names the side for every task the project does not
# retarget, and the derivation from the target value is what a project with no
# registered posture keeps.

# shellcheck disable=SC2034 # The resolution outputs are read by callers (fm-spawn.sh) and tests, not by this lib.
TASK_BASE_SLOT='' TASK_BASE_SLOT_REF='' TASK_BASE_CONTRIB='' TASK_BASE_CONTRIB_REF='' TASK_BASE_STATE='' TASK_BASE_ERROR=''
# shellcheck disable=SC2034 # Same: consumed by fm-spawn.sh (records them) and tests.
TASK_BASE_VENUE='' TASK_BASE_VENUE_URL=''

# shellcheck source=bin/fm-landed-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-landed-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# The three words bin/fm-project-mode.sh's --contribution names, re-validated
# at every entry point that accepts one. This is not defensive duplication of
# that owner's parsing: it is the one place a caller that hands this library a
# word from anywhere else is stopped, and stopping it is the whole point - the
# fallback for an unrecognized posture would be the remote-only derivation the
# posture exists to override, which is the wrong answer stated confidently.
task_base_posture_is_known() {  # <posture>
  case ${1-} in
    default | fork | upstream) return 0 ;;
  esac
  return 1
}

# The venue a `fork` posture names: where this repository PUSHES.
# `git remote get-url --push --all origin` answers that in all three layouts a
# fork posture can appear in, because it prints the configured pushurl list when
# there is one and falls back to the fetch url when there is not: origin IS the
# fork (no split), origin fetches upstream and pushes the fork (a split), and a
# lone remote with no upstream at all.
#
# --all is load-bearing. Git accepts SEVERAL remote.origin.pushurl entries, and
# `get-url --push` without it returns the first one silently, so a repository
# configured to push two places would have one of them recorded as "the" venue
# with nothing to distinguish that from a repository that pushes one place.
# There is no fork to name there, so it is refused.
#
# Sets TASK_BASE_VENUE_URL. 0 with it set, 2 with TASK_BASE_ERROR set when the
# push side is missing, unreadable, or not unique.
task_base_fork_venue_url() {  # <repo-dir>
  local dir=$1 urls url key first_key first_url seen=0 status
  if ! urls=$(git --no-optional-locks -C "$dir" remote get-url --push --all origin 2>/dev/null); then
    # Absent remote and unreadable configuration both fail that read, so the
    # negative is taken only from the enumeration that can tell them apart -
    # the same separation bin/fm-landed-lib.sh makes for the same reason.
    fm_landed_remote_listed "$dir" origin
    status=$?
    if [ "$status" -eq 1 ]; then
      TASK_BASE_ERROR="no origin remote in $dir, so the fork venue its registered posture names cannot be derived"
    else
      TASK_BASE_ERROR="the urls $dir pushes to could not be read, so the fork venue its registered posture names cannot be derived"
    fi
    return 2
  fi
  first_key=
  first_url=
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    # Two urls differing only in transport, port, or a .git suffix name ONE
    # venue, so the comparison is on the forge identity; a remote this cannot
    # reduce to a forge (a local path) falls back to its normalized url, which
    # is the strongest comparison available for it.
    key=$(task_base_venue_identity "$url") || key=$(fm_landed_normalize_url "$url")
    if [ "$seen" -eq 0 ]; then
      seen=1
      first_key=$key
      first_url=$url
      continue
    fi
    [ "$key" = "$first_key" ] && continue
    TASK_BASE_ERROR="$dir pushes to more than one venue ($first_url and $url), so the fork its registered posture names is not unique"
    return 2
  done <<EOF
$urls
EOF
  if [ "$seen" -eq 0 ]; then
    TASK_BASE_ERROR="origin in $dir names no push url, so the fork venue its registered posture names cannot be derived"
    return 2
  fi
  TASK_BASE_VENUE_URL=$first_url
  return 0
}

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

task_base_resolve() {  # <repo-dir> [<contribution-posture>]
  local dir=$1 posture=${2-} upstream_ref upstream_sha status
  TASK_BASE_SLOT=
  TASK_BASE_SLOT_REF=
  TASK_BASE_CONTRIB=
  TASK_BASE_CONTRIB_REF=
  TASK_BASE_STATE=
  TASK_BASE_ERROR=

  [ -n "$posture" ] || posture=default
  task_base_posture_is_known "$posture" || {
    TASK_BASE_STATE=unresolved
    TASK_BASE_ERROR="unknown contribution posture '$posture'; bin/fm-project-mode.sh --contribution owns that word and names only default, fork, or upstream"
    return 1
  }

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

  # A REGISTERED FORK POSTURE ENDS THE RESOLUTION HERE. The project contributes
  # where it pushes, so the trunk the branch is cut from is the trunk the fleet
  # already runs and the two roles collapse onto that one commit - the same
  # coincident state a project with no upstream at all reports.
  #
  # No upstream trunk is read, and that is deliberate rather than an
  # optimization: an upstream this project is not contributing to has no say in
  # where its branches are cut, so an unfetched one must not be able to refuse a
  # dispatch, and a readable one must not be able to pull the target away from
  # the trunk the captain approved.
  if [ "$posture" = fork ]; then
    TASK_BASE_CONTRIB=$TASK_BASE_SLOT
    TASK_BASE_CONTRIB_REF=$TASK_BASE_SLOT_REF
    TASK_BASE_STATE=coincident
    return 0
  fi

  # No distinct upstream: the two roles collapse onto the slot base and every
  # caller stays on today's single-reference behavior. That collapse is a claim
  # about the repository's remotes, so it is made only when they were read - a
  # could-not-observe reports unresolved instead, exactly like an upstream trunk
  # that was named but could not be read below.
  upstream_ref=$(task_base_upstream_ref "$dir")
  status=$?
  if [ "$status" -eq 1 ]; then
    # Except under a registered upstream posture, where the collapse would
    # silently substitute the fork for the trunk the captain named. The two
    # facts contradict, and a contradiction is refused rather than resolved.
    if [ "$posture" = upstream ]; then
      TASK_BASE_STATE=unresolved
      TASK_BASE_ERROR="$dir is registered to contribute upstream but has no upstream distinct from where it pushes, so there is no upstream trunk to cut from"
      return 0
    fi
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
# A REGISTERED POSTURE REPLACES THAT DERIVATION RATHER THAN BIASING IT. The
# ordering below is a safety property only while the venue is being GUESSED from
# reachability; once the captain has named the side, reachability is the wrong
# question entirely. It has to be, because the two trunks are not always
# distinguishable by it: the moment upstream merges everything the fork holds,
# the fork trunk becomes an ancestor of the upstream trunk and the upstream-first
# test resolves upstream for work that must still be raised at the fork.
#
# 0 with the venue set, 2 when it could not be derived. There is no "probably";
# an underivable venue is reported so a caller can refuse rather than guess.
task_base_venue() {  # <repo-dir> <contribution-target> [<contribution-posture>]
  local dir=$1 target=${2-} posture=${3-}
  local fetch_url push_url upstream_url upstream_ref name target_sha ref fork_seen
  local status refs complete
  TASK_BASE_VENUE=
  TASK_BASE_VENUE_URL=
  TASK_BASE_ERROR=

  [ -n "$posture" ] || posture=default
  task_base_posture_is_known "$posture" || {
    TASK_BASE_ERROR="unknown contribution posture '$posture'; bin/fm-project-mode.sh --contribution owns that word and names only default, fork, or upstream"
    return 2
  }

  target_sha=$(git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$target^{commit}" 2>/dev/null) || {
    TASK_BASE_ERROR="contribution target '$target' is not a readable commit"
    return 2
  }

  # The registered fork posture. The venue is the push side and no trunk is
  # tested for reachability, so no upstream - merged, diverged, or unfetched -
  # can move a fork-approved task's pull request to another repository.
  if [ "$posture" = fork ]; then
    task_base_fork_venue_url "$dir" || return 2
    TASK_BASE_VENUE=$(task_base_venue_identity "$TASK_BASE_VENUE_URL" || true)
    return 0
  fi

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
    # A registered upstream posture names a trunk this repository does not have,
    # so recording its single venue here would quietly answer "fork" to a
    # question the captain already answered "upstream". Refused, matching
    # task_base_resolve's refusal of the same contradiction.
    if [ "$posture" = upstream ]; then
      TASK_BASE_ERROR="$dir is registered to contribute upstream but has no upstream distinct from where it pushes, so the venue that posture names does not exist"
      return 2
    fi
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

  # The registered upstream posture. Same shape as the fork branch above and for
  # the same reason: the side is named, so the target is not tested against it.
  # The push side is deliberately left unread - a project contributing upstream
  # does not need its fork to be nameable for its pull request to have a venue.
  if [ "$posture" = upstream ]; then
    TASK_BASE_VENUE_URL=$upstream_url
    TASK_BASE_VENUE=$(task_base_venue_identity "$upstream_url" || true)
    return 0
  fi

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
