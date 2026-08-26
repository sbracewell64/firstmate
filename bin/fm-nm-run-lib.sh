#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the branch+code-identity matching rule that decides whether a
# no-mistakes run belongs to a given worktree, used by fm-crew-state.sh
# (read-only current-state reporting) and fm-teardown.sh (pre-teardown run
# abort, see its "Fix 1" header comment). Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# It is also the one owner of the COMPLETE run census (fm_nm_census, below),
# which answers the different question a custody decision needs: not "is this
# run mine" but "is there any run that currently owns mutation here". The two
# live together because they read the same source and must never disagree about
# what that source can and cannot supply.
#
# What this file owns is reading and attributing the run record. Bounding the
# call is owned by bin/fm-timeout-lib.sh, which declares itself the single owner
# of bounded command execution, so the mechanism selection is not re-derived
# here. That matters beyond tidiness: its selection ends in a dependency-free
# bash watchdog, so a host with no timeout, gtimeout or perl still gets the same
# hard bound and process-group cleanup instead of an unbounded call or a refusal.
# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status, where 124 means the bound was
# hit; the checked form discards stderr, while fm_nm_run keeps the fail-open
# query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2
  shift 2
  ( cd "$dir" && fm_run_timed "$timeout_secs" no-mistakes "$@" )
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1
}

# The tool's own refusal, read from captured `axi status` output $1, or nothing
# when it reported none.
#
# The tool writes a refusal to stdout as a leading `error:` line, and does NOT
# always exit non-zero for one: `repo not initialized` exits 0 (measured
# 2026-08-18 against no-mistakes v1.40.3), which is the state of every checkout
# the pipeline was never set up in. A caller judging only the exit status
# therefore reads a refusal as a run record, and every field below reads as
# absent from it, so this belongs beside them rather than in each caller.
#
# Only the FIRST non-empty line is read. That is where the tool puts its own
# refusal, and a run record is free to carry an `error` field about the run it
# describes; a field inside a record is a fact about that run rather than the
# tool declining to report one, and the two must not share a branch.
fm_nm_error_line() {  # <toon-output>
  printf '%s\n' "${1:-}" | awk '
    /^[ \t]*$/ { next }
    {
      if (match($0, /^[ \t]*error:[ \t]*/)) print substr($0, RSTART + RLENGTH)
      exit
    }
  '
}

# Names of the steps a run has completed, one per line, read from the
# steps[N]{step,status,...} table in captured `axi status` output $1. The table
# ends at the next key line, so a scalar or a later block is never read as a row.
fm_nm_completed_steps() {  # <toon-output>
  printf '%s\n' "$1" | awk '
    /steps\[[0-9]+\]\{/ { in_steps = 1; next }
    !in_steps { next }
    /^[ \t]*[A-Za-z_]+[:[]/ { in_steps = 0; next }
    {
      row = $0
      sub(/^[ \t]+/, "", row)
      if (split(row, f, ",") < 2) next
      gsub(/[ \t"]/, "", f[1])
      gsub(/[ \t"]/, "", f[2])
      if (f[2] == "completed") print f[1]
    }
  '
}

# THREE-VALUED code-identity answer for run head $2 against worktree $1, the
# same rule everywhere this attribution is needed. The third value is the point:
# "I cannot determine this" is not "this is not mine".
#
#   0  MATCH         the run head resolves here and is either this worktree's
#                    HEAD or a descendant of it (pipeline fix commits on the
#                    same history advanced the run tip past local HEAD)
#   1  NO MATCH      no run head was reported at all, so the run made no code
#                    identity claim to test; or the run head resolves here and
#                    is a strict ancestor of, or diverged from, local HEAD
#                    (local work advanced outside the run, or the branch tip
#                    was rewritten)
#   2  UNRESOLVABLE  a run head was reported but this worktree cannot answer
#                    for it - the object is not in reach, the worktree has no
#                    readable HEAD to compare against, or the ancestry check
#                    itself errored instead of answering - so its relation to
#                    local HEAD is genuinely UNKNOWN
#
# Why 2 exists (measured 2026-08-06): while a run validates, no-mistakes commits
# its fix rounds in its own gate-repo clone and does not push until the push
# step, so the LIVE run's tip is routinely an object the crew's worktree has
# never seen. Reporting that as "no match" made the documented descendant case -
# the normal case during every fix round - structurally unmatchable, and the
# rejected run then fell through to a coarser scan where an OLDER, genuinely
# failed run sitting at the worktree's own head matched and won. A working lane
# was reported dead. Resolution is deliberately read-only and side-effect free:
# this helper never fetches to make an absent object appear.
#
# Callers must keep 2 distinct from 1 and decide what unknown means for them.
# Neither caller may turn 2 into a terminal verdict: fm-crew-state.sh reports
# working/validating or unknown, and fm-teardown.sh declines to abort a run it
# cannot positively attribute.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full rc=0
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 2
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 2
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Complete run census
# ---------------------------------------------------------------------------
#
# The attribution above answers "is THIS run mine". The census answers a
# different question that no caller could previously ask: "is there ANY run that
# currently owns mutation here". A custody decision needs the second one, and
# reading it off the first would credit a one-run answer to a whole-population
# claim - the wrong-subject failure this fleet names in .agents/skills/wrong-subject.
#
# WHAT THE SOURCE CANNOT SUPPLY, stated here rather than inside the fold that
# consumes it, because a source that quietly answers a narrower question is how a
# complete-looking census gets credited with completeness it never had:
#
#   - `no-mistakes runs` is REPOSITORY-SCOPED. It cannot see a run in any other
#     repository, so a census is complete FOR ONE REPOSITORY and claims nothing
#     beyond it. That is the exact scope a branch-custody question needs, and it
#     is not the scope a fleet-wide question needs.
#   - It reports NO RUN ID, so a row cannot be re-inspected with `axi status
#     --run`. A row is identified only by its (status, branch, head) triple.
#   - Its head is a SHORT SHA that resolves only when the object is reachable
#     from the reading worktree. A live run commits its fix rounds in its own
#     gate-repo clone and does not push until the push step, so an unresolvable
#     head is the NORMAL shape of a live run, never evidence against one.
#   - It is TRUNCATED by default. The truncation footer is the only completeness
#     signal it emits, and its absence is what this reader requires.
#
# Returns:
#   0  COMPLETE       one normalized "<status><TAB><branch><TAB><head>" row per
#                     run on stdout. An empty census is a real, complete answer:
#                     the tool ran and reported no runs.
#   3  NOT_INITIALIZED  this repository has no pipeline at all, so no run can own
#                     anything in it. That is an ESTABLISHED absence, not an
#                     unread one, and it is reported apart so a caller can record
#                     it as such instead of as a covered census.
#   2  COULD-NOT-OBSERVE  the reason on stdout.
#
# The three are kept apart because the tool reports the same condition two ways:
# `no-mistakes runs` exits 1 with its refusal on STDERR, while `axi status` exits
# 0 with the same refusal on STDOUT (both measured 2026-08-22, v1.40.3). Reading
# only the status would call the first a broken read and the second a clean empty
# census - two wrong answers to one question.
#
# The uninitialized classification is the one place this reader matches vendor
# TEXT. It is deliberately the narrow direction: an unrecognised wording falls
# through to COULD-NOT-OBSERVE, which refuses, so a changed message costs a
# repair rather than buying a silent pass.
FM_NM_CENSUS_TERMINAL='completed failed cancelled'
FM_NM_CENSUS_UNINITIALIZED='repo not initialized'

fm_nm_census() {  # <dir> <timeout_secs> <limit>
  local dir=$1 timeout_secs=$2 limit=$3 out err errfile rc=0 line status branch head rest
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-nm-census.XXXXXX") || {
    printf 'a temporary file for the run listing could not be created, so which runs exist could not be observed\n'
    return 2
  }
  # fm-retrieval-audit: complete-source - the truncation footer is the only completeness signal this source emits, and the check below turns its presence into COULD-NOT-OBSERVE, so a bounded listing never returns as a census and no caller can reach an absence through it.
  out=$(fm_nm_run_bounded "$dir" "$timeout_secs" runs --limit "$limit" 2>"$errfile") || rc=$?
  err=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"
  # The tool's own refusal, from EITHER stream, before the status is read: the
  # status alone cannot tell an uninitialized repository from a broken listing.
  local refusal
  refusal=$(fm_nm_error_line "$out")
  case "$out$err" in
    *"$FM_NM_CENSUS_UNINITIALIZED"*)
      printf 'no-mistakes is not initialized in %s, so no pipeline run exists there to own anything\n' "$dir"
      return 3
      ;;
  esac
  if [ "$rc" -eq 124 ]; then
    printf 'the run listing did not answer within %ss, so which runs exist could not be observed\n' "$timeout_secs"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    printf 'the run listing exited %s, so which runs exist could not be observed\n' "$rc"
    return 2
  fi
  if [ -n "$refusal" ]; then
    printf 'the run listing refused: %s\n' "$refusal"
    return 2
  fi
  # The only completeness signal this source emits. A listing that says more
  # rows exist is exactly the population this census may not claim to cover.
  if printf '%s\n' "$out" | grep -qE '\([0-9]+ more runs'; then
    printf 'the run listing is truncated at limit %s and reports more runs beyond it, so the census is incomplete\n' "$limit"
    return 2
  fi
  while IFS= read -r line; do
    line=$(fm_nm_trim "$line")
    [ -n "$line" ] || continue
    status=${line%% *}
    rest=$(fm_nm_trim "${line#* }")
    branch=${rest%% *}
    rest=$(fm_nm_trim "${rest#* }")
    head=${rest%% *}
    # A row this reader cannot decompose is a run it cannot attribute, and a
    # census that silently drops one is incomplete while looking whole.
    if [ -z "$status" ] || [ -z "$branch" ] || [ -z "$head" ] || [ "$branch" = "$status" ]; then
      printf 'a run listing row could not be read as "<status> <branch> <head>": %s\n' "$line"
      return 2
    fi
    printf '%s\t%s\t%s\n' "$status" "$branch" "$head"
  done <<EOF
$out
EOF
  return 0
}

# Whether one census status word names a run that has STOPPED. Anything this
# fleet has not observed as terminal is treated as live, which is the fail-closed
# direction: an unrecognized status is a run that may still own an effect, and
# reading it as finished is what lets a dispatch land on top of a live pipeline.
fm_nm_census_terminal() {  # <status>
  local s=$1 t
  for t in $FM_NM_CENSUS_TERMINAL; do
    [ "$s" = "$t" ] && return 0
  done
  return 1
}

# A stable identity for one census, so a decision made against it can be shown to
# have been made against THAT population and not a later one.
fm_nm_census_digest() {  # <census-rows>
  local rows=${1:-}
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256:%s' "$(printf '%s' "$rows" | sha256sum | cut -c1-16)"
  elif command -v shasum >/dev/null 2>&1; then
    printf 'sha256:%s' "$(printf '%s' "$rows" | shasum -a 256 | cut -c1-16)"
  else
    printf 'unobserved'
  fi
}
