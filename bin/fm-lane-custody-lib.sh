#!/usr/bin/env bash
# fm-lane-custody-lib.sh - the shared vocabulary of LOCAL lane custody: the ref
# namespace, the record schema, the "is this worktree clean" predicate, and the
# three-valued reads over the repository's SHARED ref store.
#
# WHY LOCAL CUSTODY EXISTS AT ALL
# bin/fm-teardown.sh returns a lane's worktree only once the work is recoverable
# WITHOUT it, and every authority it had for that was remote: reachable from a
# remote-tracking branch, published at the forge, or landed in the trunk. A lane
# that is finished, committed, clean and validated but deliberately NOT published
# - held behind a publication quarantine, say - satisfies none of them, so its
# slot stays held for as long as the hold lasts. The only relief was to push the
# commits somewhere, which is a publication act performed purely to buy back a
# slot. Local custody is the alternative: park the exact commits under a ref in
# the repository's shared object store, OUTSIDE the disposable worktree, and let
# teardown recognize that ref on the same terms as the remote authorities.
#
# THE REF IS THE MECHANISM, NOT A NOTE ABOUT ONE
# refs/fm/custody/<task-id>/<head-sha> lives in the ref store shared by every
# worktree of the repository (git's per-worktree namespace is only HEAD,
# refs/bisect/, refs/worktree/ and refs/rewritten/, so anything under refs/fm/
# is shared). Being a ref is what makes it load-bearing: `git gc` and `git prune`
# treat it as a reachability root, so returning the worktree and deleting the
# branch cannot collect the objects.
# docs/verification/lane-local-custody.md records that observation, its negative
# control, and the git it was observed against.
#
# LOCAL CUSTODY IS WEAKER THAN PUBLICATION, AND THAT IS STATED, NOT HIDDEN
# A published commit survives the loss of this machine. A parked one does not: it
# survives worktree return, branch deletion, slot reuse and gc, and nothing more.
# Teardown may therefore accept it only because a deliberate `park` created it -
# teardown never mints its own custody, so the authority always traces back to an
# operator act rather than to the cleanup that benefits from it.
#
# WHY THE MAPPING RECORD LIVES UNDER data/ AND NOT state/
# The record has to answer questions AFTER the lane is gone, and teardown's own
# volatile-state sweep removes state/<task-id>.*. A record the same command
# deletes cannot be the thing that made the removal safe. data/ is where this
# fleet keeps durable private records for exactly that reason, alongside
# data/landing-authorizations/ and data/outbound-artifacts/.
#
# EVERY READ HERE IS THREE-VALUED
# 0 is the positive answer, 1 is a PROVEN negative, and 2 is could-not-observe.
# A ref that could not be read is not an absent ref, and a status command that
# failed is not a clean worktree; collapsing either one is how a guard quietly
# stops guarding. Negatives are taken only from a read that SUCCEEDED and
# returned nothing, or from the exit status git reserves for absence.
#
# Every read uses --no-optional-locks so inspecting a worktree another lane owns
# never takes or rewrites its index lock.
set -u

# shellcheck disable=SC2034 # Read by sourcing callers (bin/fm-lane-custody.sh).
FM_CUSTODY_SCHEMA=fm-lane-custody.v1
FM_CUSTODY_REF_ROOT=refs/fm/custody

# Is <task-id> usable as BOTH a path component and a ref component? The path rule
# is bin/fm-pr-lib.sh's fm_task_id_path_safe, which every task-addressed store
# already shares; the ref rule is git's own, asked of git rather than reimplemented
# here, because the reserved shapes (a component ending in .lock, a bare @, an
# embedded ..) are git's to define and change.
fm_custody_task_id_valid() {  # <task-id>
  local id=${1-}
  fm_task_id_path_safe "$id" || return 1
  git check-ref-format "$FM_CUSTODY_REF_ROOT/$id/0000000000000000000000000000000000000000" 2>/dev/null
}

fm_custody_ref_name() {  # <task-id> <head-sha>
  printf '%s/%s/%s\n' "$FM_CUSTODY_REF_ROOT" "$1" "$2"
}

# The absolute path of the SHARED object and ref store backing <dir>.
# `git rev-parse --git-common-dir` answers relative to the invocation's working
# directory - it is a bare ".git" in a primary checkout and absolute in a linked
# worktree - so it is resolved here rather than consumed raw by callers that
# will later pass it to --git-dir from somewhere else.
# 0 and prints the path; 2 when it could not be read or does not exist.
fm_custody_common_dir() {  # <dir>
  local dir=$1 common resolved
  common=$(git --no-optional-locks -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 2
  [ -n "$common" ] || return 2
  case "$common" in
    /*) resolved=$common ;;
    *) resolved=$(cd "$dir" && cd "$common" 2>/dev/null && pwd) || return 2 ;;
  esac
  [ -n "$resolved" ] && [ -d "$resolved" ] || return 2
  printf '%s\n' "$resolved"
}

# The object <ref> names in the shared store at <common-dir>.
# 0 and prints the sha, 1 when the ref is PROVABLY absent, 2 when it could not be
# read. `rev-parse --verify --quiet` reserves exit 1 for "no such ref" and uses
# git's ordinary fatal status for a store it cannot read, which is what keeps the
# two apart without a second read.
fm_custody_shared_ref_head() {  # <common-dir> <ref>
  local out status
  out=$(git --no-optional-locks --git-dir="$1" rev-parse --verify --quiet "$2" 2>/dev/null)
  status=$?
  case "$status" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# Every custody ref currently recorded for <task-id>, one "<ref> <sha>" per line.
#   0  at least one exists, and the enumeration was complete
#   1  a PROVEN empty set - the enumeration succeeded and listed nothing
#   2  the enumeration itself could not be read, so a ref that may exist is
#      missing from the output
# The universe matters here rather than the list: the collision rule below
# concludes "no other head is parked for this task", and only a complete
# enumeration can support that.
fm_custody_refs_for_task() {  # <common-dir> <task-id>
  local out status
  out=$(git --no-optional-locks --git-dir="$1" for-each-ref \
    --format='%(refname) %(objectname)' "$FM_CUSTODY_REF_ROOT/$2/" 2>/dev/null)
  status=$?
  [ "$status" -eq 0 ] || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Does the commit <sha> exist as a commit in the store at <common-dir>, and what
# tree does it carry? 0 and prints the tree sha; 1 when the object is provably
# absent or is not a commit; 2 when the store could not be read.
#
# The 1 is the shape that matters most to a custody caller: it is exactly what a
# collected object looks like, and it must never be reported as a store this
# could not read - "the work is gone" and "I could not check" are different
# things to tell an operator holding the only copy.
fm_custody_commit_tree() {  # <common-dir> <sha>
  local out status
  out=$(git --no-optional-locks --git-dir="$1" rev-parse --verify --quiet "$2^{tree}" 2>/dev/null)
  status=$?
  case "$status" in
    0) ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  [ -n "$out" ] || return 2
  printf '%s\n' "$out"
}

# THE SINGLE DEFINITION OF A CLEAN LANE, shared by custody and by teardown.
# Two definitions that must agree is one definition too many: custody would start
# refusing lanes teardown accepts, or accept lanes teardown refuses, the moment
# either copy was edited alone.
#
#   0  clean
#   1  dirty, and FM_CUSTODY_DIRTY_LINE holds the first offending status line
#   2  could-not-observe - the status read itself failed, which a caller must
#      never treat as clean
#
# --untracked-files=all so git never collapses an untracked directory to a bare
# "?? .opencode/" line: the allowlist names one exact spawn-written file, and a
# collapsed directory line could neither match it nor prove the directory holds
# nothing else. Expanding only ever adds lines, so it cannot hide real dirty work.
#
# The allowlist is firstmate's OWN spawn-written turn-end scaffolding
# (bin/fm-spawn.sh), which is never the worker's work and must not read as
# uncommitted changes when the info/exclude write did not take. Exact paths only.
FM_CUSTODY_DIRTY_LINE=
fm_custody_worktree_clean() {  # <dir>
  local raw
  FM_CUSTODY_DIRTY_LINE=
  raw=$(git -C "$1" status --porcelain --untracked-files=all 2>/dev/null) || return 2
  FM_CUSTODY_DIRTY_LINE=$(printf '%s\n' "$raw" \
    | grep -vE '^\?\? (\.claude/|\.opencode/plugins/fm-turn-end\.js$|\.fm-(grok|kimi)-turnend$)' \
    | head -1 || true)
  [ -z "$FM_CUSTODY_DIRTY_LINE" ] || return 1
  return 0
}

# fail-closed-predicates: enforced
