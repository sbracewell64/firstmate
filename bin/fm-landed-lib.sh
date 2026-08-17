#!/usr/bin/env bash
# fm-landed-lib.sh - the single owner of "has this content already landed?"
#
# WHY CONTENT, NOT COMMIT REACHABILITY
# `rev-list --count <ref>..HEAD` answers "is this COMMIT reachable from <ref>",
# which a squash merge, a rebase, or a local replay all break: the content is in
# the trunk under a different commit id, so the count stays non-zero forever.
# The question that actually protects work is "does <ref> already contain what
# HEAD introduces". A 3-way merge answers it: when HEAD adds nothing <ref> does
# not already have, the merged tree IS <ref>'s tree. Trunk commits past the
# merge-base do not count as "added", so an out-of-date slot still reads landed.
#
# WHY THE LANDING TARGET IS NOT ALWAYS refs/remotes/origin/<name>
# A remote-tracking ref is only the landing target for a fleet that pushes to
# that remote and refetches it. Two shapes in real use break that assumption:
#   - `origin` FETCHES from an upstream but PUSHES to a fork, so origin/<name>
#     tracks upstream while the fork trunk (the local branch) is where work
#     lands.
#   - A project that lands locally by design never advances origin/<name> at
#     all, so it drifts further behind every day.
# Callers therefore ask about a REF THEY CHOOSE. This library does not guess a
# landing target; fm_landed_default_branch_name resolves only the NAME, and each
# caller applies its own policy for which refs carrying that name to test.
#
# WHY THE FORK TRUNK NEEDS A REF OF ITS OWN
# In the fetch/push split above, NEITHER conventional ref is the fork trunk once
# the fork advances at the forge: origin/<name> is upstream, and the local
# branch is the fork trunk only while something keeps fast-forwarding it. When
# that lags, work provably merged into the fork reads as unlanded and holds its
# slot forever. The default fetch refspec cannot reach the fork - it points at
# the fetch URL - so the trunk is fetched from the PUSH url into a ref of its
# own under refs/fm-landing/. That ref is a landing target only because this
# fleet demonstrably pushes there; it is never inferred from a remote's name.
# fm_landed_refresh_push_target does the network read and is called only by a
# caller that already refreshes remotes, so the purely local guard path keeps
# whatever the last refresh left behind and never grows a network dependency.
#
# EXIT STATUS IS THREE-VALUED, ON PURPOSE, IN EVERY FUNCTION HERE
# 0 is the positive answer, 1 is a PROVEN negative, and 2 is could-not-observe.
# Collapsing the last two loses the difference between work that is demonstrably
# unlanded and a repository this could not read, and callers guarding real work
# need to refuse on both while reporting them differently.
#
# A PROVEN NEGATIVE NEEDS A SUCCESSFUL READ, NOT A FAILED ONE
# git reports "this thing is absent" and "this repository could not be read"
# through the same failing exit status at several call sites, so a failure is
# never taken as the negative on its own. Each negative below is taken either
# from a read that SUCCEEDED and returned nothing, or from the exit status git
# reserves for absence (`rev-parse --verify --quiet` exits 1 for a ref that is
# not there, `symbolic-ref --quiet` exits 1 for a ref that is not a symref, and
# both exit 128 when the repository itself cannot be read); any other failing
# status is could-not-observe. Where a positive enumeration is available it is
# preferred over an exit code: `git remote` succeeding and not listing a name is
# stronger evidence that the remote is absent than get-url failing.
# docs/verification/landing-resolution.md records those statuses observed
# against the git this fleet runs, and tests/fm-landed-lib.test.sh pins the
# property that no read failure anywhere in this path may produce a 1.
#
# COMPLETENESS IS A SEPARATE FACT FROM THE ANSWER
# fm_landed_candidate_refs enumerates a UNIVERSE, and a universe has a third
# state its members do not: the list can be non-empty and still incomplete,
# which no caller can detect from the content of the list. It therefore reports
# completeness in its own exit status rather than leaving a short list to pass
# for a whole one. The asymmetry that makes a partial list still useful:
# incompleteness kills NEGATIVES, not positives. A ref that provably contains
# HEAD's content proves the content survives, however many other refs went
# unread; only the conclusion "no landing target holds this" needs the whole
# universe.
#
# Every read uses --no-optional-locks so inspecting a worktree that another lane
# owns never takes or rewrites its index lock.
set -u

# 0 when <ref> already contains everything HEAD introduces, 1 when it provably
# does not, 2 when that could not be determined (unreadable ref, unreadable
# HEAD, or a merge conflict, which means the trees genuinely diverge but is
# reported as inconclusive rather than as a clean "not contained").
fm_landed_tree_contains() {  # <dir> <ref>
  local dir=$1 ref=$2 ref_tree merged status
  ref_tree=$(git --no-optional-locks -C "$dir" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 2
  [ -n "$ref_tree" ] || return 2
  git --no-optional-locks -C "$dir" rev-parse --quiet --verify HEAD >/dev/null 2>&1 || return 2
  merged=$(git --no-optional-locks -C "$dir" merge-tree --write-tree "$ref" HEAD 2>/dev/null)
  status=$?
  # merge-tree exits non-zero on conflict AND on usage/read failure. Both are
  # inconclusive here: a conflict proves the trees diverge, but this predicate
  # only ever claims "demonstrably contained", never "demonstrably unlanded".
  [ "$status" -eq 0 ] || return 2
  merged=$(printf '%s\n' "$merged" | head -1)
  [ -n "$merged" ] || return 2
  [ "$merged" = "$ref_tree" ] && return 0
  return 1
}

# Does <ref> exist and resolve in <dir>? 0 yes, 1 provably not, 2 could not be
# read. `rev-parse --verify --quiet` reserves exit 1 for "no such ref" and uses
# git's ordinary fatal status for a repository it cannot read, so the two are
# separable here without a second read.
#
# A ref whose object is missing is reported by git itself as absent (it warns and
# exits 1), so this inherits that classification. Detecting object-level
# corruption is a different question than this library asks, and is named as a
# limit in docs/verification/landing-resolution.md rather than half-answered.
fm_landed_ref_exists() {  # <dir> <ref>
  local status
  git --no-optional-locks -C "$1" rev-parse --verify --quiet "$2" >/dev/null 2>&1
  status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Is <name> configured as a remote in <dir>? 0 yes, 1 provably not, 2 could not
# be read. The negative comes from an enumeration that SUCCEEDED and did not list
# the name, never from a per-remote read that failed: `git remote` exits 0 for a
# repository with no remotes at all and non-zero only when it could not read the
# configuration, so an empty listing is evidence and a failed one is not.
fm_landed_remote_listed() {  # <dir> <name>
  local dir=$1 name=$2 listing line
  listing=$(git --no-optional-locks -C "$dir" remote 2>/dev/null) || return 2
  while IFS= read -r line; do
    [ "$line" = "$name" ] && return 0
  done <<EOF
$listing
EOF
  return 1
}

# The default branch NAME (no refs/ prefix), preferring what origin/HEAD records
# and otherwise the first conventional name that exists as either a local branch
# or a remote-tracking branch. 1 when no name provably resolves and 2 when that
# could not be read; every caller must treat BOTH as unverifiable rather than as
# "nothing to protect", so the two are distinguished for reporting rather than
# for control flow.
fm_landed_default_branch_name() {  # <dir>
  local dir=$1 ref branch status unread=0
  ref=$(git --no-optional-locks -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  status=$?
  if [ "$status" -eq 0 ] && [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  # Exit 1 is git's "origin/HEAD is not a symbolic ref", which is an ordinary
  # repository that never recorded one and is the common case. Any other failure
  # leaves what origin/HEAD records unread, so the conventional names below would
  # be a guess dressed as an answer.
  [ "$status" -eq 1 ] || return 2
  for branch in main master; do
    fm_landed_ref_exists "$dir" "refs/heads/$branch"
    status=$?
    [ "$status" -eq 0 ] && { printf '%s\n' "$branch"; return 0; }
    [ "$status" -eq 2 ] && unread=1
    fm_landed_ref_exists "$dir" "refs/remotes/origin/$branch"
    status=$?
    [ "$status" -eq 0 ] && { printf '%s\n' "$branch"; return 0; }
    [ "$status" -eq 2 ] && unread=1
  done
  [ "$unread" -eq 0 ] || return 2
  return 1
}

# Normalize a remote URL for comparison: trailing slash and .git suffix only.
# Deliberately not a URL parser - scheme/host differences are real differences.
fm_landed_normalize_url() {  # <url>
  local url=${1%/}
  printf '%s\n' "${url%.git}"
}

# The url this repo PUSHES to when that differs from where `origin` FETCHES,
# which is the fetch/push split described above and the layout firstmate itself
# uses. 1 when there PROVABLY is no such url - no origin at all, or two urls read
# successfully and found equal - which is every ordinary single-remote repository
# and the conventional `upstream`-remote fork layout, since in both origin/<name>
# already tracks what this repo pushes. 2 when the remote configuration could not
# be read, which is a different fact: the landing target may well exist and this
# simply does not know, so no caller may treat it as the ordinary layout.
fm_landed_push_url() {  # <dir>
  local dir=$1 fetch push status
  if ! fetch=$(git --no-optional-locks -C "$dir" remote get-url origin 2>/dev/null); then
    # Absent remote and unreadable configuration both fail that read, so the
    # negative is taken only from the enumeration that can tell them apart.
    fm_landed_remote_listed "$dir" origin
    status=$?
    [ "$status" -eq 1 ] || return 2
    return 1
  fi
  push=$(git --no-optional-locks -C "$dir" remote get-url --push origin 2>/dev/null) || return 2
  [ -n "$fetch" ] && [ -n "$push" ] || return 2
  [ "$(fm_landed_normalize_url "$fetch")" != "$(fm_landed_normalize_url "$push")" ] || return 1
  printf '%s\n' "$push"
}

# The private ref holding the push remote's <name> trunk, 1 when this repo
# provably has no distinct push url, and 2 when that could not be read. Naming it
# does not make it exist; a caller that needs it populated calls
# fm_landed_refresh_push_target first, and a caller that only reads local state
# tests it like any other candidate.
#
# The 2 is the whole point of this function having three values. A caller that
# reads it as "there is no push target" drops the landing target itself out of
# whatever it is about to conclude, and then concludes it anyway.
fm_landed_push_target_ref() {  # <dir> <name>
  local status
  fm_landed_push_url "$1" >/dev/null
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  printf 'refs/fm-landing/origin/%s\n' "$2"
}

# Refresh the push remote's trunk into that private ref. TOUCHES THE NETWORK, so
# only a caller that already refreshes remotes should call it.
# 0 when there provably was nothing to refresh (no distinct push url) or the
# refresh succeeded; 2 when the landing target went unread - because a distinct
# push url exists but its trunk could not be fetched, OR because whether there is
# a distinct push url could not be read at all.
# A caller must treat that 2 as unverifiable and refuse: the landing target is
# precisely the ref it could not read, so nothing it can still reach is evidence
# that the work landed.
fm_landed_refresh_push_target() {  # <dir> <name>
  local dir=$1 name=$2 url ref status
  url=$(fm_landed_push_url "$dir")
  status=$?
  [ "$status" -eq 1 ] && return 0
  [ "$status" -eq 0 ] || return 2
  ref=$(fm_landed_push_target_ref "$dir" "$name") || return 2
  git -C "$dir" fetch --quiet "$url" "+refs/heads/$name:$ref" >/dev/null 2>&1 || return 2
  return 0
}

# Every existing ref carrying <name> that could be a landing target, most-local
# first, one per line. The local branch leads because the two fleet shapes above
# both land there; the push remote's trunk follows, because on a fetch/push
# split it is where work actually lands and the local branch only mirrors it
# when something keeps that up to date; origin/<name> is last. A caller that
# needs the remote to win can reorder, and a caller that needs ALL of them
# tested reads the whole list.
#
# THE EXIT STATUS IS ABOUT THE UNIVERSE, NOT ABOUT THE LIST:
#   0  complete, and at least one candidate exists
#   1  complete, and no ref carrying <name> exists - a PROVEN empty universe
#   2  INCOMPLETE: at least one candidate could not be read, so a ref that may
#      exist is missing from the output
# A 2 can arrive with a non-empty list, and that combination is exactly what no
# caller can see any other way: the output is a short list that looks like a
# whole one, and testing containment against it tests a partial universe. A
# caller must read this status, not the emptiness of the output.
#
# The partial list is still printed rather than withheld, because a positive
# containment against any ref in it is valid whatever went unread. Only a
# negative conclusion needs the whole universe.
fm_landed_candidate_refs() {  # <dir> <name>
  local dir=$1 name=$2 found=1 incomplete=0 ref push_ref status
  local -a candidates=("refs/heads/$name")
  push_ref=$(fm_landed_push_target_ref "$dir" "$name")
  status=$?
  case "$status" in
    0) candidates+=("$push_ref") ;;
    1) : ;;
    *) incomplete=1 ;;
  esac
  candidates+=("refs/remotes/origin/$name")
  for ref in "${candidates[@]}"; do
    fm_landed_ref_exists "$dir" "$ref"
    status=$?
    case "$status" in
      0) printf '%s\n' "$ref"; found=0 ;;
      1) : ;;
      *) incomplete=1 ;;
    esac
  done
  [ "$incomplete" -eq 0 ] || return 2
  return "$found"
}
