#!/usr/bin/env bash
# fm-lane-custody.sh - park a finished lane's exact commits under a LOCAL custody
# ref outside its disposable worktree, so bin/fm-teardown.sh can return the slot
# without the work having to be published anywhere.
#
# THE PROBLEM THIS SOLVES. A ship lane that is committed, clean and validated but
# deliberately unpublished - held behind a publication quarantine, say - is
# recoverable through none of teardown's authorities, all of which are remote. Its
# pool slot stays held for as long as the hold lasts, and the only relief was to
# push the commits somewhere purely to buy the slot back. Parking writes
# refs/fm/custody/<task-id>/<head-sha> into the repository's SHARED ref store,
# which keeps the objects reachable across worktree return, branch deletion, slot
# reuse and `git gc`. bin/fm-lane-custody-lib.sh's header owns why that ref is the
# mechanism rather than a note about one, why the mapping record lives under
# data/, and why local custody is weaker than publication.
#
# WHAT THIS IS NOT. It is not publication, review, landing, or any claim that the
# work is current or acceptable. It moves nothing to a remote and opens nothing at
# a forge. Teardown never mints custody for itself; the authority always traces
# back to an operator running `park` on a lane they observed.
#
# USAGE
#   fm-lane-custody.sh park <task-id> [--worktree <dir>] [--branch <name>]
#                                     [--head <sha>]
#       Bind task -> branch -> head -> tree under a custody ref and record the
#       mapping. Resolves the worktree from state/<task-id>.meta when --worktree
#       is not given. REFUSES a dirty worktree (untracked bytes included), a
#       detached HEAD, a head that is not the branch tip, a stated branch or head
#       that does not match what the worktree shows, and a second custody for a
#       DIFFERENT head of the same task. Idempotent at the same head.
#
#   fm-lane-custody.sh verify <task-id> [--worktree <dir>] [--branch <name>]
#                                       [--repo <dir>] [--require-lane]
#       Re-derive the binding from what is on disk right now. With --worktree it
#       also re-verifies head == branch tip == custody ref, the tree digest, and a
#       clean worktree, and reports scope=lane; without one it can only speak for
#       the objects and reports scope=objects. --require-lane refuses to answer at
#       all without a worktree, so a caller that needs the lane axes cannot be
#       handed the narrower answer.
#
#   fm-lane-custody.sh reopen <task-id> --into <dir> [--repo <dir>]
#       Re-materialize the parked lane into a FRESH worktree at <dir> on its
#       recorded branch, then prove head and tree identity against the record.
#       Creates the branch from the custody ref when the branch is gone, reuses it
#       when it still sits at the recorded head, and REFUSES when it moved.
#
#   fm-lane-custody.sh release <task-id> --head <sha> [--repo <dir>]
#       Retire the custody ref and its record. The exact head must be stated, so
#       no sweep can drop one by accident. This is the only thing that removes a
#       custody ref; teardown never does.
#
#   fm-lane-custody.sh list
#       Enumerate every recorded custody with the live state of its ref. A partial
#       enumeration reports could-not-observe rather than a short list.
#
# RESTART / REOPEN PROOF - the exact commands
#   bin/fm-lane-custody.sh park my-task
#   bin/fm-teardown.sh my-task                     # the slot comes back
#   bin/fm-lane-custody.sh verify my-task          # scope=objects, token held
#   bin/fm-lane-custody.sh reopen my-task --into /path/to/fresh-worktree
#   git -C /path/to/fresh-worktree rev-parse HEAD HEAD^{tree}
# docs/verification/lane-local-custody.md records that run, its gc negative
# control, and the git it was observed against.
#
# EXIT CODES
#   0  the operation completed
#   2  usage error
#   3  refused - a verdict was reached and it is no
#   4  could-not-observe - no verdict was reached. Never read as either neighbour.
# Judge this command by the token it prints, not by the exit status alone: 3 and 4
# are different results and the token names which. Tokens: held, absent, not-held,
# unreadable, and released (from `release` only).
#
# ENVIRONMENT
#   FM_HOME                 operational home (default: repo root)
#   FM_DATA_OVERRIDE        data root (default: $FM_HOME/data)
#   FM_STATE_OVERRIDE       state root (default: $FM_HOME/state)
#   FM_LANE_CUSTODY_DIR     custody record store (default: $DATA/lane-custody)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CUSTODY_DIR="${FM_LANE_CUSTODY_DIR:-$DATA/lane-custody}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lane-custody-lib.sh
. "$SCRIPT_DIR/fm-lane-custody-lib.sh"

usage() { sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

die() {  # <message> [<code>]
  printf 'fm-lane-custody: %s\n' "$1" >&2
  exit "${2:-2}"
}

# One machine-readable line on stdout in every outcome, so a caller reads the
# token rather than inferring a verdict from the exit status alone.
say() {  # <token> <detail...>
  printf 'custody: %s %s\n' "$1" "$2"
}

refuse() {  # <token> <detail>
  say "$1" "$2"
  exit 3
}

unobserved() {  # <token> <detail>
  say "$1" "$2"
  exit 4
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

meta_value() {  # <meta-path> <key>
  [ -f "$1" ] || return 1
  sed -n "s/^$2=//p" "$1" | head -1
}

record_path() {  # <task-id>
  printf '%s/%s.json\n' "$CUSTODY_DIR" "$1"
}

# Atomic by rename, so a reader never sees a half-written record and a crash
# leaves either the previous record or the new one, never a torn one.
record_write() {  # <task-id> <json>
  local path tmp
  path=$(record_path "$1")
  mkdir -p "$CUSTODY_DIR" || return 1
  tmp="$path.tmp.$$"
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Three-valued, and the caller must keep the three apart:
#   0 and RECORD set   readable and well formed
#   3                  no such record - genuinely absent
#   4                  present and unreadable, or not this schema, or misbound
RECORD=
record_read() {  # <task-id>
  local expected=$1 path raw stored
  path=$(record_path "$expected")
  if [ ! -e "$path" ]; then
    RECORD=
    return 3
  fi
  raw=$(cat "$path" 2>/dev/null) || return 4
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 4
  [ "$(printf '%s' "$raw" | jq -r '.schema // ""')" = "$FM_CUSTODY_SCHEMA" ] || return 4
  printf '%s' "$raw" | jq -e '
    (.task | type == "string" and length > 0) and
    (.branch | type == "string" and length > 0) and
    (.head | type == "string" and (test("^[0-9a-f]{40}$"))) and
    (.tree | type == "string" and (test("^[0-9a-f]{40}$"))) and
    (.ref | type == "string" and length > 0) and
    (.git_common_dir | type == "string" and length > 0) and
    (.project | type == "string") and
    (.worktree_at_park | type == "string") and
    (.parked | type == "string" and length > 0)' >/dev/null 2>&1 || return 4
  stored=$(printf '%s' "$raw" | jq -r '.task')
  [ "$stored" = "$expected" ] || return 4
  RECORD=$raw
  return 0
}

record_field() {  # <key>
  printf '%s' "$RECORD" | jq -r ".$1"
}

# The worktree a caller named, or the one state/<task-id>.meta recorded. Prints
# nothing and fails when neither resolves, because guessing a worktree here would
# bind custody to a directory nobody named.
resolve_worktree() {  # <task-id> <explicit-or-empty>
  local id=$1 explicit=$2 wt
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  wt=$(meta_value "$STATE/$id.meta" worktree) || return 1
  [ -n "$wt" ] || return 1
  printf '%s\n' "$wt"
}

require_task_id() {  # <task-id>
  fm_custody_task_id_valid "${1:-}" || die "invalid task id: ${1:-<empty>}"
}

# --- park --------------------------------------------------------------------

cmd_park() {
  local id=${1:-}
  shift || true
  local want_wt='' want_branch='' want_head=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree) want_wt=${2:-}; shift 2 || die "--worktree needs a directory" ;;
      --branch) want_branch=${2:-}; shift 2 || die "--branch needs a name" ;;
      --head) want_head=${2:-}; shift 2 || die "--head needs a sha" ;;
      *) die "unknown park argument: $1" ;;
    esac
  done
  require_task_id "$id"

  local wt common branch head tip tree ref existing_ref existing_sha status
  wt=$(resolve_worktree "$id" "$want_wt") \
    || die "no worktree for $id: pass --worktree, or record one in $STATE/$id.meta" 2
  [ -d "$wt" ] || unobserved unreadable "task=$id the worktree $wt does not exist"

  common=$(fm_custody_common_dir "$wt") \
    || unobserved unreadable "task=$id the shared git store behind $wt could not be resolved"

  branch=$(git --no-optional-locks -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  [ -n "$branch" ] \
    || refuse not-held "task=$id $wt is at a detached HEAD; custody binds a branch, so there is nothing to park"
  if [ -n "$want_branch" ] && [ "$want_branch" != "$branch" ]; then
    refuse not-held "task=$id stated branch $want_branch but $wt is on $branch"
  fi

  head=$(git --no-optional-locks -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) \
    || unobserved unreadable "task=$id HEAD in $wt could not be read"
  [ -n "$head" ] || unobserved unreadable "task=$id HEAD in $wt could not be read"
  if [ -n "$want_head" ] && [ "$want_head" != "$head" ]; then
    refuse not-held "task=$id stated head $want_head but $wt is at $head"
  fi

  tip=$(fm_custody_shared_ref_head "$common" "refs/heads/$branch")
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id branch $branch does not exist in the shared store" ;;
    *) unobserved unreadable "task=$id the tip of $branch could not be read" ;;
  esac
  [ "$tip" = "$head" ] \
    || refuse not-held "task=$id head $head is not the tip of $branch ($tip); commit or reset the lane first"

  fm_custody_worktree_clean "$wt"
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id $wt is dirty: $FM_CUSTODY_DIRTY_LINE" ;;
    *) unobserved unreadable "task=$id $wt could not be inspected for uncommitted changes" ;;
  esac

  tree=$(fm_custody_commit_tree "$common" "$head")
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id the commit $head is not present in the shared store" ;;
    *) unobserved unreadable "task=$id the commit $head could not be read" ;;
  esac

  ref=$(fm_custody_ref_name "$id" "$head")
  git check-ref-format "$ref" 2>/dev/null || die "refusing to write a malformed custody ref: $ref"

  # A second custody for a DIFFERENT head of the same task is the stale mapping
  # this refuses: two parked heads make "the lane" ambiguous, and picking one
  # silently is how the wrong commits get reopened later. The enumeration's own
  # completeness is read first, because "no other head is parked" is a claim about
  # the whole set and a partial listing cannot support it.
  local refs already=0
  refs=$(fm_custody_refs_for_task "$common" "$id")
  status=$?
  case "$status" in
    0) ;;
    1) refs= ;;
    *) unobserved unreadable "task=$id existing custody refs could not be enumerated, so a colliding head cannot be ruled out" ;;
  esac
  while IFS=' ' read -r existing_ref existing_sha; do
    [ -n "$existing_ref" ] || continue
    if [ "$existing_ref" = "$ref" ] && [ "$existing_sha" = "$head" ]; then
      already=1
      continue
    fi
    refuse not-held "task=$id already holds custody at $existing_sha via $existing_ref; release that head before parking $head"
  done <<< "$refs"

  if [ "$already" -eq 0 ]; then
    git --git-dir="$common" update-ref "$ref" "$head" "" 2>/dev/null \
      || unobserved unreadable "task=$id the custody ref $ref could not be created"
  fi

  # Prove it landed in the SHARED store rather than assuming the namespace rules.
  # Anything under refs/fm/ is shared today; a git that changed that would put the
  # ref inside the worktree this is about to release, which is the one place it
  # must not be.
  local landed
  landed=$(fm_custody_shared_ref_head "$common" "$ref") \
    || unobserved unreadable "task=$id $ref is not readable from the shared store at $common"
  [ "$landed" = "$head" ] \
    || unobserved unreadable "task=$id $ref resolves to $landed in the shared store, not $head"

  local project record
  project=$(meta_value "$STATE/$id.meta" project 2>/dev/null) || project=
  record=$(jq -n \
    --arg schema "$FM_CUSTODY_SCHEMA" --arg task "$id" --arg project "$project" \
    --arg common "$common" --arg branch "$branch" --arg head "$head" --arg tree "$tree" \
    --arg ref "$ref" --arg wt "$wt" --arg parked "$(now_iso)" \
    '{schema:$schema, task:$task, project:$project, git_common_dir:$common,
      branch:$branch, head:$head, tree:$tree, ref:$ref,
      worktree_at_park:$wt, parked:$parked}') \
    || unobserved unreadable "task=$id the custody record could not be composed"
  record_write "$id" "$record" \
    || unobserved unreadable "task=$id the custody record could not be written to $(record_path "$id")"

  say held "task=$id ref=$ref head=$head tree=$tree branch=$branch store=$common scope=lane"
  printf 'reopen it with: %s reopen %s --into <fresh-worktree>\n' "$0" "$id"
}

# --- verify ------------------------------------------------------------------

cmd_verify() {
  local id=${1:-}
  shift || true
  local want_wt='' want_branch='' want_repo='' require_lane=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --worktree) want_wt=${2:-}; shift 2 || die "--worktree needs a directory" ;;
      --branch) want_branch=${2:-}; shift 2 || die "--branch needs a name" ;;
      --repo) want_repo=${2:-}; shift 2 || die "--repo needs a directory" ;;
      --require-lane) require_lane=1; shift ;;
      *) die "unknown verify argument: $1" ;;
    esac
  done
  require_task_id "$id"
  if [ "$require_lane" = 1 ] && [ -z "$want_wt" ]; then
    die "--require-lane needs --worktree: the lane axes cannot be verified without one"
  fi

  local status
  record_read "$id"
  status=$?
  case "$status" in
    0) ;;
    3) refuse absent "task=$id no custody is recorded at $(record_path "$id")" ;;
    *) unobserved unreadable "task=$id the custody record at $(record_path "$id") is unreadable or not $FM_CUSTODY_SCHEMA" ;;
  esac

  local rec_branch rec_head rec_tree rec_ref rec_common
  rec_branch=$(record_field branch)
  rec_head=$(record_field head)
  rec_tree=$(record_field tree)
  rec_ref=$(record_field ref)
  rec_common=$(record_field git_common_dir)

  [ "$rec_ref" = "$(fm_custody_ref_name "$id" "$rec_head")" ] \
    || unobserved unreadable "task=$id the record's ref $rec_ref does not match its own head $rec_head"

  # Which store to ask. A caller that names a worktree or repository is asking
  # about THAT checkout, so its store must be the recorded one; disagreement is a
  # refusal rather than a silent fall back to the record's own path, which would
  # answer about a repository the caller never mentioned.
  local common probe=
  [ -n "$want_wt" ] && probe=$want_wt
  [ -z "$probe" ] && [ -n "$want_repo" ] && probe=$want_repo
  if [ -n "$probe" ]; then
    [ -d "$probe" ] || unobserved unreadable "task=$id $probe does not exist"
    common=$(fm_custody_common_dir "$probe") \
      || unobserved unreadable "task=$id the shared git store behind $probe could not be resolved"
    [ "$common" = "$rec_common" ] \
      || refuse not-held "task=$id $probe belongs to the store $common, not the recorded $rec_common"
  else
    common=$rec_common
    [ -d "$common" ] || unobserved unreadable "task=$id the recorded store $common does not exist"
  fi

  local ref_head
  ref_head=$(fm_custody_shared_ref_head "$common" "$rec_ref")
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id the custody ref $rec_ref is missing from $common" ;;
    *) unobserved unreadable "task=$id the custody ref $rec_ref could not be read" ;;
  esac
  [ "$ref_head" = "$rec_head" ] \
    || refuse not-held "task=$id the custody ref $rec_ref moved to $ref_head, not the recorded $rec_head"

  local tree
  tree=$(fm_custody_commit_tree "$common" "$rec_head")
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id the commit $rec_head is no longer present in $common" ;;
    *) unobserved unreadable "task=$id the commit $rec_head could not be read" ;;
  esac
  [ "$tree" = "$rec_tree" ] \
    || refuse not-held "task=$id the commit $rec_head carries tree $tree, not the recorded $rec_tree"

  # Ambiguity is a refusal, not a preference. Two parked heads for one task make
  # "the lane" undefined, and answering held for whichever the record happens to
  # name would credit that answer to a binding nobody re-confirmed.
  local refs count
  refs=$(fm_custody_refs_for_task "$common" "$id")
  status=$?
  case "$status" in
    0) ;;
    1) unobserved unreadable "task=$id $rec_ref read as present and the task's ref set read as empty" ;;
    *) unobserved unreadable "task=$id the task's custody refs could not be enumerated" ;;
  esac
  count=$(printf '%s\n' "$refs" | grep -c . || true)
  [ "$count" = 1 ] \
    || refuse not-held "task=$id holds $count custody refs, so its parked head is ambiguous"

  local scope=objects
  if [ -n "$want_wt" ]; then
    local branch wt_head tip
    branch=$(git --no-optional-locks -C "$want_wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
    [ -n "$branch" ] \
      || refuse not-held "task=$id $want_wt is at a detached HEAD, not on the recorded branch $rec_branch"
    [ "$branch" = "$rec_branch" ] \
      || refuse not-held "task=$id $want_wt is on $branch, not the recorded branch $rec_branch"
    if [ -n "$want_branch" ] && [ "$want_branch" != "$rec_branch" ]; then
      refuse not-held "task=$id stated branch $want_branch but custody records $rec_branch"
    fi
    wt_head=$(git --no-optional-locks -C "$want_wt" rev-parse --verify --quiet HEAD 2>/dev/null) \
      || unobserved unreadable "task=$id HEAD in $want_wt could not be read"
    [ "$wt_head" = "$rec_head" ] \
      || refuse not-held "task=$id $want_wt is at $wt_head, not the parked head $rec_head"
    tip=$(fm_custody_shared_ref_head "$common" "refs/heads/$rec_branch")
    status=$?
    case "$status" in
      0) ;;
      1) refuse not-held "task=$id branch $rec_branch no longer exists in $common" ;;
      *) unobserved unreadable "task=$id the tip of $rec_branch could not be read" ;;
    esac
    [ "$tip" = "$rec_head" ] \
      || refuse not-held "task=$id branch $rec_branch is at $tip, not the parked head $rec_head"
    fm_custody_worktree_clean "$want_wt"
    status=$?
    case "$status" in
      0) ;;
      1) refuse not-held "task=$id $want_wt is dirty: $FM_CUSTODY_DIRTY_LINE" ;;
      *) unobserved unreadable "task=$id $want_wt could not be inspected for uncommitted changes" ;;
    esac
    scope=lane
  fi

  say held "task=$id ref=$rec_ref head=$rec_head tree=$rec_tree branch=$rec_branch store=$common scope=$scope"
}

# --- reopen ------------------------------------------------------------------

cmd_reopen() {
  local id=${1:-}
  shift || true
  local into='' want_repo=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --into) into=${2:-}; shift 2 || die "--into needs a directory" ;;
      --repo) want_repo=${2:-}; shift 2 || die "--repo needs a directory" ;;
      *) die "unknown reopen argument: $1" ;;
    esac
  done
  require_task_id "$id"
  [ -n "$into" ] || die "reopen needs --into <fresh-worktree>"

  local status
  record_read "$id"
  status=$?
  case "$status" in
    0) ;;
    3) refuse absent "task=$id no custody is recorded at $(record_path "$id")" ;;
    *) unobserved unreadable "task=$id the custody record at $(record_path "$id") is unreadable or not $FM_CUSTODY_SCHEMA" ;;
  esac

  local rec_branch rec_head rec_tree rec_ref rec_common rec_project
  rec_branch=$(record_field branch)
  rec_head=$(record_field head)
  rec_tree=$(record_field tree)
  rec_ref=$(record_field ref)
  rec_common=$(record_field git_common_dir)
  rec_project=$(record_field project)

  # Never into something that already exists: a reopen that could overwrite is a
  # reopen that can destroy, and this command exists to recover work.
  if [ -e "$into" ]; then
    refuse not-held "task=$id $into already exists; reopen never writes into an existing path"
  fi

  # The repository to add the worktree to. The recorded project first, then the
  # parent of the recorded store, and whichever is used must resolve to the SAME
  # shared store the custody ref lives in.
  local repo common
  for repo in "$want_repo" "$rec_project" "${rec_common%/.git}"; do
    [ -n "$repo" ] || continue
    [ -d "$repo" ] || continue
    common=$(fm_custody_common_dir "$repo") || continue
    [ "$common" = "$rec_common" ] && break
    common=
  done
  [ -n "${common:-}" ] \
    || unobserved unreadable "task=$id no readable repository resolves to the recorded store $rec_common; pass --repo"

  local ref_head
  ref_head=$(fm_custody_shared_ref_head "$common" "$rec_ref")
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id the custody ref $rec_ref is missing from $common; nothing to reopen" ;;
    *) unobserved unreadable "task=$id the custody ref $rec_ref could not be read" ;;
  esac
  [ "$ref_head" = "$rec_head" ] \
    || refuse not-held "task=$id the custody ref $rec_ref moved to $ref_head, not the recorded $rec_head"

  local tip
  tip=$(fm_custody_shared_ref_head "$common" "refs/heads/$rec_branch")
  status=$?
  case "$status" in
    0)
      [ "$tip" = "$rec_head" ] \
        || refuse not-held "task=$id branch $rec_branch already exists at $tip, not the parked head $rec_head; reopen never moves a branch"
      git -C "$repo" worktree add --quiet "$into" "$rec_branch" 2>/dev/null \
        || unobserved unreadable "task=$id git worktree add of $rec_branch into $into failed"
      ;;
    1)
      git -C "$repo" worktree add --quiet -b "$rec_branch" "$into" "$rec_ref" 2>/dev/null \
        || unobserved unreadable "task=$id git worktree add of a fresh $rec_branch into $into failed"
      ;;
    *) unobserved unreadable "task=$id the tip of $rec_branch could not be read" ;;
  esac

  # The proof. A reopen that is not verified is a directory, not a recovery.
  local new_head new_tree new_branch
  new_head=$(git --no-optional-locks -C "$into" rev-parse --verify --quiet HEAD 2>/dev/null) \
    || unobserved unreadable "task=$id HEAD in the reopened $into could not be read"
  new_tree=$(git --no-optional-locks -C "$into" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) \
    || unobserved unreadable "task=$id the tree of the reopened $into could not be read"
  new_branch=$(git --no-optional-locks -C "$into" symbolic-ref --quiet --short HEAD 2>/dev/null) || new_branch=
  [ "$new_head" = "$rec_head" ] \
    || refuse not-held "task=$id the reopened $into is at $new_head, not the parked head $rec_head"
  [ "$new_tree" = "$rec_tree" ] \
    || refuse not-held "task=$id the reopened $into carries tree $new_tree, not the parked tree $rec_tree"
  [ "$new_branch" = "$rec_branch" ] \
    || refuse not-held "task=$id the reopened $into is on ${new_branch:-a detached HEAD}, not $rec_branch"
  fm_custody_worktree_clean "$into"
  status=$?
  case "$status" in
    0) ;;
    1) refuse not-held "task=$id the reopened $into is dirty: $FM_CUSTODY_DIRTY_LINE" ;;
    *) unobserved unreadable "task=$id the reopened $into could not be inspected for uncommitted changes" ;;
  esac

  say held "task=$id reopened=$into ref=$rec_ref head=$new_head tree=$new_tree branch=$new_branch identity=exact"
}

# --- release -----------------------------------------------------------------

cmd_release() {
  local id=${1:-}
  shift || true
  local want_head='' want_repo=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) want_head=${2:-}; shift 2 || die "--head needs a sha" ;;
      --repo) want_repo=${2:-}; shift 2 || die "--repo needs a directory" ;;
      *) die "unknown release argument: $1" ;;
    esac
  done
  require_task_id "$id"
  [ -n "$want_head" ] || die "release needs --head <sha>: the exact parked head must be stated"

  local status
  record_read "$id"
  status=$?
  case "$status" in
    0) ;;
    3) refuse absent "task=$id no custody is recorded at $(record_path "$id")" ;;
    *) unobserved unreadable "task=$id the custody record at $(record_path "$id") is unreadable or not $FM_CUSTODY_SCHEMA" ;;
  esac

  local rec_head rec_ref rec_common repo common
  rec_head=$(record_field head)
  rec_ref=$(record_field ref)
  rec_common=$(record_field git_common_dir)
  [ "$want_head" = "$rec_head" ] \
    || refuse not-held "task=$id stated head $want_head but custody holds $rec_head; release never guesses which head to drop"

  for repo in "$want_repo" "$(record_field project)" "${rec_common%/.git}"; do
    [ -n "$repo" ] || continue
    [ -d "$repo" ] || continue
    common=$(fm_custody_common_dir "$repo") || continue
    [ "$common" = "$rec_common" ] && break
    common=
  done
  [ -n "${common:-}" ] && [ -d "$common" ] || common=$rec_common
  [ -d "$common" ] || unobserved unreadable "task=$id the recorded store $common does not exist"

  # Compare-and-delete: the ref goes only if it still holds the head just proved,
  # so a ref that moved under this command is left alone rather than dropped.
  git --git-dir="$common" update-ref -d "$rec_ref" "$rec_head" 2>/dev/null \
    || unobserved unreadable "task=$id the custody ref $rec_ref could not be deleted at $rec_head"
  rm -f -- "$(record_path "$id")" \
    || unobserved unreadable "task=$id the custody record could not be removed"
  say released "task=$id ref=$rec_ref head=$rec_head store=$common"
  printf 'the objects under %s are now reachable only from whatever else references them\n' "$rec_head"
}

# --- list --------------------------------------------------------------------

cmd_list() {
  [ "$#" -eq 0 ] || die "list takes no arguments"
  if [ ! -d "$CUSTODY_DIR" ]; then
    say absent "store=$CUSTODY_DIR no custody has been parked in this home"
    return 0
  fi
  local incomplete=0 found=0 path id status rec_ref rec_head rec_common ref_head state
  for path in "$CUSTODY_DIR"/*.json; do
    [ -e "$path" ] || continue
    id=${path##*/}
    id=${id%.json}
    found=1
    if ! fm_custody_task_id_valid "$id"; then
      incomplete=1
      printf 'custody: unreadable task=%s a record is filed under an unusable id\n' "$id"
      continue
    fi
    record_read "$id"
    status=$?
    if [ "$status" -ne 0 ]; then
      incomplete=1
      printf 'custody: unreadable task=%s record=%s\n' "$id" "$path"
      continue
    fi
    rec_ref=$(record_field ref)
    rec_head=$(record_field head)
    rec_common=$(record_field git_common_dir)
    ref_head=$(fm_custody_shared_ref_head "$rec_common" "$rec_ref")
    status=$?
    case "$status" in
      0) [ "$ref_head" = "$rec_head" ] && state=present || state=moved ;;
      1) state=missing ;;
      *) state=unreadable; incomplete=1 ;;
    esac
    printf 'custody: recorded task=%s head=%s branch=%s ref=%s store=%s ref_state=%s\n' \
      "$id" "$rec_head" "$(record_field branch)" "$rec_ref" "$rec_common" "$state"
  done
  if [ "$incomplete" -eq 1 ]; then
    unobserved unreadable "store=$CUSTODY_DIR the listing is INCOMPLETE; entries above name what could not be read"
  fi
  [ "$found" -eq 1 ] || say absent "store=$CUSTODY_DIR no custody has been parked in this home"
}

# --- dispatch ----------------------------------------------------------------

case "${1:-}" in
  park) shift; cmd_park "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  reopen) shift; cmd_reopen "$@" ;;
  release) shift; cmd_release "$@" ;;
  list) shift; cmd_list "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) usage >&2; die "unknown subcommand: $1" ;;
esac
