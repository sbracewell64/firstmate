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

# --- complete no-mistakes run census ----------------------------------------
#
# WHY THIS EXISTS. Everything above answers "does THIS run belong to THIS
# worktree?" from whatever run `no-mistakes axi status` chose to report. That
# question is repository-scoped, and the repository is not the universe: the
# tool registers every managed run worktree as its own `repos.id`, so a run
# created from inside one (measured: 55 of 59 registered repositories on this
# host are exactly that shape) is invisible to the enclosing checkout's status
# and to `no-mistakes runs`, which lists one repository's rows and carries no
# run id at all. A fleet that asked only those two surfaces read a hidden
# active run as quiescence. Preventing new recursive runs upstream does not
# repair that: legacy rows, independently created rows, and future
# schema-compatible rows still have to be OBSERVED.
#
# WHAT IT OWNS, AND WHAT IT DOES NOT. This is an OBSERVATION seam. no-mistakes'
# own state.sqlite and its AXI surface remain the authority for run state; this
# file adds no database, no daemon, no scheduler, no watcher and no second
# authority. What firstmate owns, and what lives here, is the CROSS-SYSTEM
# JOIN: which of those runs could be mutating which piece of firstmate's own
# semantic work.
#
# COMPLETE means the universe is enumerated, not that every row is printed.
# Every registered repository and every run is read and counted inside ONE
# WAL-consistent read transaction; the printed `members` are the potentially
# candidate-owning ones, which are the only rows a join question applies to.
#
# CANDIDATE-OWNING means NON-TERMINAL, before anything is known about whose work
# it is. A terminal row is counted and never a member, however exactly its branch
# and head still match; a member classified UNRELATED is still counted, because a
# live run against somebody else's repository is still a live run.
#
# THREE VALUES, NEVER TWO, and the fold is WEAKEST-WINS, the same asymmetry
# bin/fm-verify-lib.sh and bin/fm-independence-lib.sh already obey:
#
#   REFUSED             a proven defect in the evidence itself - a duplicate
#                       primary identity, or two candidate-owning runs claiming
#                       one piece of work. Never a run state.
#   CNO                 could not observe: unreadable, truncated, schema-
#                       incompatible, daemon-unreachable, refusal-on-exit-zero,
#                       or a joined run whose generation moved past firstmate's
#                       stored head.
#   OBSERVED_ACTIVE     at least one candidate-owning run, completely enumerated.
#   OBSERVED_QUIESCENT  complete, clean enumeration AND zero candidate-owning
#                       runs. Only this one may be read as quiescence.
#
# CNO outranks OBSERVED_ACTIVE deliberately. "I saw one active run" and "I saw
# one active run and could not read the rest of the universe" are different
# facts, and the second may not be reported as the first. Nothing is lost by
# it: universe.active_runs and members[] still carry every positive finding, and
# a per-member question is answered from members[] rather than from the verdict.
#
# NON-VACUITY is a separate field, because zero rows and zero ACTIVE rows are
# different facts. A census over an empty database is legitimately quiescent and
# proves nothing; `universe.non_vacuous` is what a caller checks before treating
# a global zero as evidence.

# The no-mistakes data home. Its `worktrees/` subtree is what makes a registered
# repository a NESTED identity rather than a checkout someone works in.
fm_nm_home() {
  printf '%s' "${FM_NM_HOME:-$HOME/.no-mistakes}"
}

# The no-mistakes state database. ONE owner for the path, because two consumers
# already read it for different questions and a second spelling of the default
# would drift the moment only one was edited.
fm_nm_state_db() {
  printf '%s' "${FM_PIPELINE_STATE_DB:-$(fm_nm_home)/state.sqlite}"
}

FM_NM_CENSUS_TIMEOUT=${FM_NM_CENSUS_TIMEOUT:-20}
case "$FM_NM_CENSUS_TIMEOUT" in ''|*[!0-9]*|0) FM_NM_CENSUS_TIMEOUT=20 ;; esac
FM_NM_CENSUS_AXI_TIMEOUT=${FM_NM_CENSUS_AXI_TIMEOUT:-10}
case "$FM_NM_CENSUS_AXI_TIMEOUT" in ''|*[!0-9]*|0) FM_NM_CENSUS_AXI_TIMEOUT=10 ;; esac
# A bound on how many candidate-owning runs are corroborated through AXI. It is
# a BOUND, not a sample: hitting it records ENUMERATION_INCOMPLETE rather than
# quietly corroborating a prefix.
FM_NM_CENSUS_AXI_MAX=${FM_NM_CENSUS_AXI_MAX:-32}
case "$FM_NM_CENSUS_AXI_MAX" in ''|*[!0-9]*) FM_NM_CENSUS_AXI_MAX=32 ;; esac
# Row bound for the enumeration itself, on the same terms.
FM_NM_CENSUS_MAX_ROWS=${FM_NM_CENSUS_MAX_ROWS:-100000}
case "$FM_NM_CENSUS_MAX_ROWS" in ''|*[!0-9]*|0) FM_NM_CENSUS_MAX_ROWS=100000 ;; esac

# Phase 1: ONE WAL-consistent read transaction over the state database, plus the
# firstmate work inventory the join needs. Prints the census core, which carries
# every fact except the AXI corroboration and the verdict.
#
# Arguments: <state_dir> <scope_path_or_empty> <all_runs 0|1>
fm_nm_census_core() {  # <state_dir> <scope> <all_runs>
  local state_dir=${1:-} scope=${2:-} all_runs=${3:-0}
  command -v python3 >/dev/null 2>&1 || return 3
  fm_run_timed "$FM_NM_CENSUS_TIMEOUT" python3 - \
    "$(fm_nm_state_db)" "$(fm_nm_home)" "$state_dir" "$FM_NM_CENSUS_MAX_ROWS" \
    "$scope" "$all_runs" <<'FM_NM_CENSUS_CORE_PY'
import collections
import hashlib
import json
import os
import sqlite3
import sys
import time
import urllib.parse

db, nm_home, state_dir, max_rows_s, scope, all_runs_s = sys.argv[1:7]
max_rows = int(max_rows_s)
all_runs = all_runs_s == "1"

TERMINAL = {"completed", "failed", "cancelled"}
ACTIVE = {"pending", "running"}
REPO_REQUIRED = ("id", "working_path", "upstream_url")
RUN_REQUIRED = ("id", "repo_id", "branch", "head_sha", "status")

doc = {
    "schema": "fm-nm-census.v1",
    "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "generation": {},
    "universe": {
        "observed": False,
        "non_vacuous": False,
        "repositories": 0,
        "repositories_declared": None,
        "nested_identities": 0,
        "runs": 0,
        "runs_declared": None,
        "status_counts": {},
        "active_runs": 0,
        "candidate_owning_runs": 0,
    },
    "repositories": [],
    "members": [],
    "runs": [],
    "repo_scoped_projection": None,
    "cno": [],
    "refusals": [],
    "axi_pending": [],
}


def cno(code, subject, detail):
    doc["cno"].append({"code": code, "subject": subject, "detail": detail})


def refuse(code, subject, detail):
    doc["refusals"].append({"code": code, "subject": subject, "detail": detail})


def emit():
    json.dump(doc, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    sys.exit(0)


def stat_of(path):
    try:
        st = os.stat(path)
        return {"present": True, "bytes": st.st_size, "mtime": int(st.st_mtime)}
    except OSError:
        return {"present": False, "bytes": None, "mtime": None}


gen = doc["generation"]
gen["database"] = db
gen["nm_home"] = nm_home
gen["reader"] = "fm-nm-run-lib.sh/fm-nm-census.v1"
gen["sqlite_library"] = sqlite3.sqlite_version
dbstat = stat_of(db)
gen["database_bytes"] = dbstat["bytes"]
gen["database_mtime"] = dbstat["mtime"]
wal = stat_of(db + "-wal")
gen["wal_present"] = wal["present"]
gen["wal_bytes"] = wal["bytes"]
gen["wal_mtime"] = wal["mtime"]

if not dbstat["present"]:
    # An absent database is could-not-observe at collection time, never an empty
    # universe. A fleet that read it as zero rows would report the most
    # reassuring answer available for the least evidence.
    cno("DATABASE_ABSENT", db, "no-mistakes state database is not present")
    emit()

try:
    uri = "file:%s?mode=ro" % urllib.parse.quote(db)
    conn = sqlite3.connect(uri, uri=True, timeout=5, isolation_level=None)
except Exception as exc:  # noqa: BLE001 - every open failure is one CNO
    cno("DATABASE_UNREADABLE", db, "%s: %s" % (type(exc).__name__, exc))
    emit()

try:
    # ONE read transaction. The snapshot is taken by the first read inside it and
    # every later read in this program sees exactly that snapshot, so a run that
    # starts or ends mid-census cannot make the counts disagree with the rows.
    conn.execute("BEGIN")
    gen["journal_mode"] = conn.execute("PRAGMA journal_mode").fetchone()[0]
    integrity = conn.execute("PRAGMA quick_check(1)").fetchone()[0]
    gen["integrity"] = integrity
    if integrity != "ok":
        cno("INTEGRITY_CHECK_FAILED", db, "quick_check reported %r" % integrity)
        emit()

    master = dict(
        conn.execute(
            "select name, sql from sqlite_master"
            " where type = 'table' and name in ('repos', 'runs')"
        )
    )
    missing_tables = [t for t in ("repos", "runs") if t not in master]
    if missing_tables:
        gen["schema_fingerprint"] = None
        cno(
            "SCHEMA_INCOMPATIBLE",
            db,
            "required table(s) absent: %s" % ", ".join(missing_tables),
        )
        emit()
    digest = hashlib.sha256()
    for name in sorted(master):
        digest.update(("%s\n%s\n" % (name, master[name] or "")).encode("utf-8"))
    gen["schema_fingerprint"] = "sha256:" + digest.hexdigest()

    repo_cols = [r[1] for r in conn.execute("PRAGMA table_info(repos)")]
    run_cols = [r[1] for r in conn.execute("PRAGMA table_info(runs)")]
    gen["repos_columns"] = repo_cols
    gen["runs_columns"] = run_cols
    missing_cols = [c for c in REPO_REQUIRED if c not in repo_cols]
    missing_cols += ["runs." + c for c in RUN_REQUIRED if c not in run_cols]
    if missing_cols:
        # An unexpected schema is could-not-observe, not an empty universe. Extra
        # columns are fine and deliberately not refused: a newer no-mistakes that
        # only ADDS fields stays readable here.
        cno(
            "SCHEMA_INCOMPATIBLE",
            db,
            "required column(s) absent: %s" % ", ".join(missing_cols),
        )
        emit()

    repos_declared = conn.execute("select count(*) from repos").fetchone()[0]
    runs_declared = conn.execute("select count(*) from runs").fetchone()[0]
    doc["universe"]["repositories_declared"] = repos_declared
    doc["universe"]["runs_declared"] = runs_declared
    if repos_declared > max_rows or runs_declared > max_rows:
        cno(
            "ENUMERATION_INCOMPLETE",
            db,
            "declared rows exceed the reader bound %d (repos=%d runs=%d)"
            % (max_rows, repos_declared, runs_declared),
        )
        emit()

    def materialize(sql):
        """Rows one at a time, keeping what was read when one cannot be read.

        A row the reader cannot materialize TRUNCATES the enumeration; it does
        not make the database unreadable. Draining the cursor with list() would
        lose that distinction, and losing it is what turns "I read 56 of 59
        repositories" into "I read the database and it had nothing in it".
        """
        rows = []
        cur = conn.execute(sql)
        while True:
            try:
                row = cur.fetchone()
            except Exception as exc:  # noqa: BLE001 - one unreadable row
                rows.append(None)
                return rows, "%s: %s" % (type(exc).__name__, exc)
            if row is None:
                return rows, ""
            rows.append(row)

    repo_rows, repo_row_error = materialize(
        "select id, working_path, upstream_url, %s from repos"
        % ("default_branch" if "default_branch" in repo_cols else "''")
    )
    optional = lambda c: c if c in run_cols else "''"  # noqa: E731
    run_rows, run_row_error = materialize(
        "select id, repo_id, branch, head_sha, status, %s, %s, %s, %s, %s from runs"
        % (
            optional("submitted_head_sha"),
            optional("last_pushed_sha"),
            optional("pr_url"),
            optional("updated_at"),
            optional("error"),
        )
    )
    conn.execute("COMMIT")
except Exception as exc:  # noqa: BLE001 - every read failure is one CNO
    cno("DATABASE_UNREADABLE", db, "%s: %s" % (type(exc).__name__, exc))
    emit()
finally:
    try:
        conn.close()
    except Exception:  # noqa: BLE001 - close failure changes no observation
        pass

# The rows actually materialized are compared against the count the same
# snapshot declared. A reader that returned fewer rows than the database says it
# holds has TRUNCATED, and a truncated universe is could-not-observe.
repo_unreadable = sum(1 for r in repo_rows if r is None)
run_unreadable = sum(1 for r in run_rows if r is None)
repo_rows = [r for r in repo_rows if r is not None]
run_rows = [r for r in run_rows if r is not None]
if (
    len(repo_rows) != repos_declared
    or len(run_rows) != runs_declared
    or repo_row_error
    or run_row_error
):
    cno(
        "ENUMERATION_INCOMPLETE",
        db,
        "returned rows disagree with declared counts"
        " (repos %d/%d, runs %d/%d; unreadable rows: repos %d, runs %d)%s%s"
        % (
            len(repo_rows),
            repos_declared,
            len(run_rows),
            runs_declared,
            repo_unreadable,
            run_unreadable,
            (" repos: " + repo_row_error) if repo_row_error else "",
            (" runs: " + run_row_error) if run_row_error else "",
        ),
    )
    emit()

repo_ids = [r[0] for r in repo_rows]
run_ids = [r[0] for r in run_rows]
# Counted rather than rescanned per element: the row bound above admits far more
# rows than this host holds, and a quadratic scan would turn a large but healthy
# database into a timed-out read reported as could-not-observe.
repo_counts = collections.Counter(repo_ids)
run_counts = collections.Counter(run_ids)
dup_repos = sorted(i for i, n in repo_counts.items() if n > 1)
dup_runs = sorted(i for i, n in run_counts.items() if n > 1)
if dup_repos or dup_runs:
    # A duplicated primary identity is a PROVEN defect in the evidence, not an
    # unobserved one: nothing joined to it can be attributed to one subject.
    refuse(
        "IDENTITY_NONUNIQUE",
        db,
        "duplicate primary identity (repos: %s; runs: %s)"
        % (", ".join(dup_repos) or "none", ", ".join(dup_runs) or "none"),
    )

repo_by_id = {}
for rid, working_path, upstream_url, default_branch in repo_rows:
    repo_by_id[rid] = {
        "id": rid,
        "working_path": working_path or "",
        "upstream_url": upstream_url or "",
        "default_branch": default_branch or "",
    }

worktrees_root = os.path.join(nm_home, "worktrees") + os.sep


def real(path):
    if not path:
        return ""
    try:
        return os.path.realpath(path)
    except OSError:
        return path


for rid, rec in repo_by_id.items():
    wp = rec["working_path"]
    rec["nested"] = wp.startswith(worktrees_root)
    rec["enclosing_repo_id"] = None
    rec["enclosing_run_id"] = None
    rec["enclosing_observed"] = False
    if rec["nested"]:
        parts = wp[len(worktrees_root):].split(os.sep)
        rec["enclosing_repo_id"] = parts[0] if parts and parts[0] else None
        rec["enclosing_run_id"] = parts[1] if len(parts) > 1 and parts[1] else None
        rec["enclosing_observed"] = (
            rec["enclosing_repo_id"] in repo_by_id and rec["enclosing_run_id"] in run_ids
        )

# The root of a nested identity is resolved by WALKING the enclosing chain, not
# by trimming the path: a run worktree nested inside a run worktree (measured on
# this host, including one `.no-mistakes/gate-source` level) has to reach the
# same root as its parent or the two cannot be recognised as the same subject.
for rid, rec in repo_by_id.items():
    seen = set()
    cur = rid
    depth = 0
    resolved = True
    while repo_by_id.get(cur, {}).get("nested"):
        if cur in seen:
            resolved = False
            break
        seen.add(cur)
        nxt = repo_by_id[cur]["enclosing_repo_id"]
        if nxt not in repo_by_id:
            resolved = False
            break
        cur = nxt
        depth += 1
    rec["depth"] = depth
    rec["root_repo_id"] = cur if resolved and cur in repo_by_id else None
    rec["root_working_path"] = (
        repo_by_id[cur]["working_path"] if rec["root_repo_id"] else ""
    )
    rec["root_observed"] = resolved and rec["root_repo_id"] is not None
    if rec["nested"] and not rec["root_observed"]:
        cno(
            "NESTED_ROOT_UNRESOLVED",
            rec["working_path"],
            "nested repository identity %s has no observable enclosing chain" % rid,
        )

doc["repositories"] = [repo_by_id[i] for i in sorted(repo_by_id)]
doc["universe"]["repositories"] = len(repo_by_id)
doc["universe"]["nested_identities"] = sum(
    1 for r in repo_by_id.values() if r["nested"]
)
doc["universe"]["runs"] = len(run_rows)

status_counts = {}
runs = []
for (
    run_id,
    repo_id,
    branch,
    head_sha,
    status,
    submitted_head_sha,
    last_pushed_sha,
    pr_url,
    updated_at,
    error,
) in run_rows:
    status = (status or "").strip()
    status_counts[status or "<empty>"] = status_counts.get(status or "<empty>", 0) + 1
    repo = repo_by_id.get(repo_id)
    if repo is None:
        # A run outside the enumerated repository universe means the universe is
        # not the universe.
        cno(
            "ORPHAN_RUN_REPOSITORY",
            run_id,
            "run references repository %r that the census did not enumerate" % repo_id,
        )
    if status in ACTIVE:
        state = "active"
    elif status in TERMINAL:
        state = "terminal"
    else:
        state = "unknown"
        cno(
            "UNKNOWN_RUN_STATUS",
            run_id,
            "run status %r is outside the observed vocabulary; treated as"
            " potentially candidate-owning" % status,
        )
    runs.append(
        {
            "id": run_id,
            "repo_id": repo_id,
            "repository": repo,
            "branch": branch or "",
            "head_sha": head_sha or "",
            "submitted_head_sha": submitted_head_sha or "",
            "last_pushed_sha": last_pushed_sha or "",
            "pr_url": pr_url or "",
            "status": status,
            "state": state,
            "updated_at": updated_at,
            "error": error or "",
        }
    )

doc["universe"]["status_counts"] = status_counts
doc["universe"]["active_runs"] = sum(1 for r in runs if r["state"] == "active")

# --- firstmate semantic work inventory ---------------------------------------


def read_kv(path):
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                out[key.strip()] = value.strip()
    except OSError:
        return None
    return out


def worktree_branch(worktree):
    """Branch at a worktree HEAD, by reading git's own files.

    Deliberately a pure file read rather than a `git` call: the census is
    read-only telemetry that must not spawn a process per task, and the
    bounded-execution owner is bin/fm-timeout-lib.sh rather than this program.
    """
    if not worktree:
        return ""
    gitpath = os.path.join(worktree, ".git")
    head = None
    try:
        if os.path.isdir(gitpath):
            head = os.path.join(gitpath, "HEAD")
        elif os.path.isfile(gitpath):
            with open(gitpath, "r", encoding="utf-8", errors="replace") as fh:
                line = fh.read().strip()
            if line.startswith("gitdir:"):
                head = os.path.join(line.split(":", 1)[1].strip(), "HEAD")
    except OSError:
        return ""
    if not head:
        return ""
    try:
        with open(head, "r", encoding="utf-8", errors="replace") as fh:
            ref = fh.read().strip()
    except OSError:
        return ""
    if ref.startswith("ref: refs/heads/"):
        return ref[len("ref: refs/heads/"):]
    return ""


def normalize_url(url):
    u = (url or "").strip().lower()
    if u.endswith(".git"):
        u = u[: -len(".git")]
    return u.rstrip("/")


def normalize_pr(url):
    return (url or "").strip().lower().rstrip("/")


works = {}
if state_dir and os.path.isdir(state_dir):
    try:
        names = sorted(os.listdir(state_dir))
    except OSError:
        names = []
        cno("WORK_INVENTORY_UNREADABLE", state_dir, "state directory is not readable")
    for name in names:
        for suffix in (".meta", ".landing"):
            if not name.endswith(suffix):
                continue
            wid = name[: -len(suffix)]
            kv = read_kv(os.path.join(state_dir, name))
            if kv is None:
                cno(
                    "WORK_RECORD_UNREADABLE",
                    os.path.join(state_dir, name),
                    "firstmate work record could not be read",
                )
                continue
            rec = works.setdefault(
                wid,
                {
                    "id": wid,
                    "worktree": "",
                    "project": "",
                    "venue_url": "",
                    "pr": "",
                    "heads": [],
                    "branch": "",
                    "derived_branch": "fm/" + wid,
                    "sources": [],
                },
            )
            rec["sources"].append(suffix.lstrip("."))
            rec["worktree"] = rec["worktree"] or kv.get("worktree", "")
            rec["project"] = rec["project"] or kv.get("project", "")
            rec["venue_url"] = rec["venue_url"] or kv.get("contribution_venue_url", "")
            rec["pr"] = rec["pr"] or kv.get("pr", "")
            # ONLY heads that identify this work's own product. A task's
            # slot_base and contribution_target name the commit it started FROM,
            # which the whole fleet shares: joining on one would match a freshly
            # created run (whose tip is still the base) to every task at once and
            # refuse the lot as ambiguous.
            if kv.get("pr_head"):
                rec["heads"].append(("pr_head", kv["pr_head"]))
    for wid, rec in works.items():
        attempt = read_kv(os.path.join(state_dir, wid + ".attempt"))
        if attempt:
            if attempt.get("execution_head"):
                rec["heads"].append(("execution_head", attempt["execution_head"]))
            rec["execution_id"] = attempt.get("execution_id", "")
        rec["branch"] = worktree_branch(rec["worktree"])
        rec["worktree_real"] = real(rec["worktree"])

# Only the heads that identify a GENERATION firstmate recorded for the work are
# comparable to a run's own head. slot_base and contribution_target are the
# task's BASE, not its product, so they are kept out of the generation set.
#
# The run side of that comparison is its CURRENT and PUSHED head, never its
# submitted head. A submitted head that still matches an old firstmate record is
# exactly the drift case: it says which generation was once sent, not which one
# is live now. Leaving it out of the join keys too is deliberate and
# conservative - a run linkable only by a stale submitted head stays
# could-not-observe rather than being attributed on evidence about a past
# generation.
GENERATION_KEYS = ("pr_head", "execution_head")


def head_prefix_match(a, b):
    a = (a or "").strip().lower()
    b = (b or "").strip().lower()
    if len(a) < 7 or len(b) < 7:
        return False
    return a.startswith(b) or b.startswith(a)


known_venues = {
    normalize_url(w["venue_url"]) for w in works.values() if w["venue_url"]
}
known_roots = {w["worktree_real"] for w in works.values() if w.get("worktree_real")}
known_roots |= {real(w["project"]) for w in works.values() if w["project"]}

members = []
for run in runs:
    if run["state"] == "terminal":
        # A terminal row is historical evidence about a generation that is over.
        # It is enumerated and counted, and it is deliberately NOT a candidate
        # mutation owner however well its branch or head text still matches.
        continue
    repo = run["repository"] or {}
    run_heads = [
        h for h in (run["head_sha"], run["last_pushed_sha"]) if h
    ]
    candidates = []
    for wid in sorted(works):
        work = works[wid]
        keys = []
        if run["pr_url"] and work["pr"] and normalize_pr(run["pr_url"]) == normalize_pr(
            work["pr"]
        ):
            keys.append("pr")
        for label, value in work["heads"]:
            if any(head_prefix_match(rh, value) for rh in run_heads):
                keys.append("head:" + label)
        if run["branch"]:
            if work["branch"] and run["branch"] == work["branch"]:
                keys.append("branch-observed")
            if run["branch"] == work["derived_branch"]:
                keys.append("branch-derived")
        root = repo.get("root_working_path", "")
        if root and work.get("worktree_real") and real(root) == work["worktree_real"]:
            keys.append("custody")
        if not keys:
            continue
        venue = normalize_url(work["venue_url"])
        upstream = normalize_url(repo.get("upstream_url", ""))
        if venue and upstream and venue != upstream:
            # A branch name is not unique across projects. A recorded venue that
            # disagrees with the repository's upstream disqualifies the match
            # rather than weakening it.
            continue
        candidates.append({"work": wid, "keys": sorted(set(keys))})

    member = dict(run)
    member.pop("repository", None)
    member["repository"] = {
        "id": repo.get("id"),
        "working_path": repo.get("working_path", ""),
        "upstream_url": repo.get("upstream_url", ""),
        "nested": repo.get("nested", False),
        "depth": repo.get("depth", 0),
        "enclosing_repo_id": repo.get("enclosing_repo_id"),
        "enclosing_run_id": repo.get("enclosing_run_id"),
        "enclosing_observed": repo.get("enclosing_observed", False),
        "root_repo_id": repo.get("root_repo_id"),
        "root_working_path": repo.get("root_working_path", ""),
        "root_observed": repo.get("root_observed", False),
    }
    member["candidates"] = candidates
    member["generation"] = "not-applicable"
    member["exact_head_evidence"] = False

    if len(candidates) == 1:
        member["join"] = "JOINED"
        member["work"] = candidates[0]["work"]
        member["join_keys"] = candidates[0]["keys"]
        work = works[member["work"]]
        stored = [(k, v) for k, v in work["heads"] if k in GENERATION_KEYS]
        if not stored:
            member["generation"] = "unrecorded"
        elif any(
            any(head_prefix_match(rh, v) for rh in run_heads) for _, v in stored
        ):
            member["generation"] = "exact"
            member["exact_head_evidence"] = True
        else:
            submitted_only = run["submitted_head_sha"] and any(
                head_prefix_match(run["submitted_head_sha"], v) for _, v in stored
            )
            member["generation"] = "moved"
            member["submitted_head_only"] = bool(submitted_only)
            cno(
                "STALE_FIRSTMATE_PROJECTION",
                run["id"],
                "run head %s/%s has moved past firstmate's stored generation for"
                " %s (%s); prior exact-head evidence is stale%s"
                % (
                    run["head_sha"] or "-",
                    run["last_pushed_sha"] or "-",
                    member["work"],
                    ", ".join("%s=%s" % (k, v) for k, v in stored),
                    " (only the submitted head still matches)"
                    if submitted_only
                    else "",
                ),
            )
    elif len(candidates) > 1:
        member["join"] = "AMBIGUOUS"
        member["join_keys"] = []
        refuse(
            "AMBIGUOUS_MUTATION_OWNER",
            run["id"],
            "candidate-owning run joins %d pieces of firstmate work: %s"
            % (len(candidates), ", ".join(c["work"] for c in candidates)),
        )
    else:
        member["join_keys"] = []
        venue_known = normalize_url(repo.get("upstream_url", ""))
        root_real = real(repo.get("root_working_path", ""))
        if venue_known and venue_known not in known_venues and root_real not in known_roots:
            # POSITIVELY unrelated: this repository's upstream is none of the
            # venues firstmate is working against and its root is none of
            # firstmate's checkouts. That is an observation, not a shrug.
            member["join"] = "UNRELATED"
        else:
            member["join"] = "CNO"
            cno(
                "UNRESOLVED_GOVERNED_RUN",
                run["id"],
                "candidate-owning run on branch %r in %s could not be joined to"
                " firstmate work nor positively classified unrelated"
                % (run["branch"], repo.get("working_path", "?")),
            )
    members.append(member)

# The reverse direction of the same ambiguity. One piece of work claimed by two
# candidate-owning runs has no single mutation owner either, and reading the
# newer one as the owner is exactly the guess this refusal exists to prevent.
owners = {}
for member in members:
    if member["join"] == "JOINED":
        owners.setdefault(member["work"], []).append(member["id"])
for wid in sorted(owners):
    if len(owners[wid]) > 1:
        refuse(
            "AMBIGUOUS_MUTATION_OWNER",
            wid,
            "firstmate work is claimed by %d candidate-owning runs: %s"
            % (len(owners[wid]), ", ".join(sorted(owners[wid]))),
        )

doc["members"] = members
doc["universe"]["candidate_owning_runs"] = len(members)
doc["axi_pending"] = [m["id"] for m in members]
if all_runs:
    for run in runs:
        run.pop("repository", None)
    doc["runs"] = runs

if scope:
    scope_real = real(scope)
    matched = [
        r for r in repo_by_id.values() if r["working_path"] and real(r["working_path"]) == scope_real
    ]
    scoped_ids = {r["id"] for r in matched}
    doc["repo_scoped_projection"] = {
        "scope": scope,
        "repo_ids": sorted(scoped_ids),
        "active_runs": sum(
            1 for r in runs if r["repo_id"] in scoped_ids and r["state"] == "active"
        ),
        "complete": False,
        "rejected_reason": "a repository-scoped projection cannot define the"
        " authoritative universe: a run created inside a managed run worktree is"
        " registered under its own repository id and is absent from it",
    }

doc["universe"]["observed"] = True
doc["universe"]["non_vacuous"] = bool(repo_by_id) and bool(run_rows)
emit()
FM_NM_CENSUS_CORE_PY
}

# Phase 2: bounded AXI corroboration for the candidate-owning runs the core read
# found. The database is the run-state authority; this asks the daemon whether it
# AGREES, which is the only way a daemon-side contradiction can be seen at all.
#
# It runs only for candidate-owning runs, so the normal zero-active census makes
# no AXI call and takes no daemon dependency. `axi status --run <id>` answers for
# any run from any initialized checkout (verified against the installed v1.40.3),
# so one usable directory serves the whole set.
#
# Emits one TSV line per probed run: <run_id>\t<verdict>\t<detail>.
fm_nm_census_axi_probe() {  # <census-core-json-file>
  local core=$1 dir out err_line run_id id_field status_field outcome_field probe_rc n=0
  dir=${FM_NM_CENSUS_AXI_DIR:-}
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    dir=$(fm_nm_census_axi_dir "$core")
  fi
  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$FM_NM_CENSUS_AXI_MAX" ]; then
      printf '%s\tBOUND\tcorroboration bound %s reached; the remaining candidate-owning runs were not probed\n' \
        "$run_id" "$FM_NM_CENSUS_AXI_MAX"
      continue
    fi
    if [ -z "$dir" ]; then
      printf '%s\tNO_DIRECTORY\tno initialized no-mistakes checkout was available to ask\n' "$run_id"
      continue
    fi
    if ! command -v no-mistakes >/dev/null 2>&1; then
      printf '%s\tNO_TOOL\tthe no-mistakes command is not installed\n' "$run_id"
      continue
    fi
    probe_rc=0
    # The status is captured through `||` rather than read after the assignment:
    # this tool exits non-zero for its ordinary refusals, and under a caller's
    # `set -e` a bare assignment would abort the probe loop mid-way and silently
    # drop every remaining candidate-owning run.
    out=$(fm_nm_run_bounded "$dir" "$FM_NM_CENSUS_AXI_TIMEOUT" axi status --run "$run_id" 2>/dev/null) \
      || probe_rc=$?
    if [ "$probe_rc" = 124 ]; then
      printf '%s\tTIMEOUT\tthe reader did not answer within %ss\n' "$run_id" "$FM_NM_CENSUS_AXI_TIMEOUT"
      continue
    fi
    # The tool writes its own refusal to stdout as a leading `error:` line and
    # does not always exit non-zero for one, so the refusal is read from the
    # output rather than from the status. fm_nm_error_line owns that rule.
    err_line=$(fm_nm_error_line "$out")
    if [ -n "$err_line" ]; then
      case "$err_line" in
        *daemon*|*socket*|*connect*) printf '%s\tDAEMON\t%s\n' "$run_id" "$err_line" ;;
        *) printf '%s\tREFUSED\t%s\n' "$run_id" "$err_line" ;;
      esac
      continue
    fi
    if [ -z "$(fm_nm_trim "$out")" ]; then
      printf '%s\tSILENT\tthe reader returned no output at all (exit %s)\n' "$run_id" "$probe_rc"
      continue
    fi
    id_field=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
    status_field=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
    if [ -z "$id_field" ] || [ -z "$status_field" ]; then
      printf '%s\tSCHEMA\trun record lacks the required id/status fields\n' "$run_id"
      continue
    fi
    if [ "$id_field" != "$run_id" ]; then
      # A record fetched BY KEY whose own identity is a different key is refused
      # rather than returned: it answers for a subject nobody asked about.
      printf '%s\tIDENTITY_MISMATCH\trecord returned for run %s\n' "$run_id" "$id_field"
      continue
    fi
    outcome_field=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
    printf '%s\tOK\tstatus=%s outcome=%s head=%s\n' \
      "$run_id" "$status_field" "${outcome_field:--}" \
      "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")"
  done < <(fm_nm_census_pending "$core")
}

# The first registered non-nested repository whose checkout still exists. A
# nested run worktree is routinely removed after its run ends, so asking there
# would report a directory problem as a run fact.
fm_nm_census_axi_dir() {  # <census-core-json-file>
  python3 - "$1" <<'FM_NM_CENSUS_DIR_PY'
import json
import os
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:  # noqa: BLE001 - an unreadable core prints no directory
    sys.exit(0)
for repo in doc.get("repositories", []):
    if repo.get("nested"):
        continue
    path = repo.get("working_path") or ""
    if path and os.path.isdir(os.path.join(path, ".git")) or (
        path and os.path.isfile(os.path.join(path, ".git"))
    ):
        print(path)
        break
FM_NM_CENSUS_DIR_PY
}

fm_nm_census_pending() {  # <census-core-json-file>
  python3 - "$1" <<'FM_NM_CENSUS_PENDING_PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:  # noqa: BLE001 - an unreadable core has nothing to probe
    sys.exit(0)
for run_id in doc.get("axi_pending", []):
    print(run_id)
FM_NM_CENSUS_PENDING_PY
}

# Phase 3: merge the corroboration into the core and fold ONE verdict. The fold
# lives here and only here.
fm_nm_census_fold() {  # <census-core-json-file> <axi-tsv-file>
  python3 - "$1" "$2" <<'FM_NM_CENSUS_FOLD_PY'
import json
import sys

core_path, axi_path = sys.argv[1], sys.argv[2]
try:
    with open(core_path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:  # noqa: BLE001 - an unreadable core is one CNO
    doc = {
        "schema": "fm-nm-census.v1",
        "generation": {},
        "universe": {"observed": False, "non_vacuous": False},
        "repositories": [],
        "members": [],
        "runs": [],
        "repo_scoped_projection": None,
        "cno": [
            {
                "code": "CENSUS_READER_FAILED",
                "subject": core_path,
                "detail": "the census reader produced no readable result: %s: %s"
                % (type(exc).__name__, exc),
            }
        ],
        "refusals": [],
        "axi_pending": [],
    }

# Every corroboration verdict that is not OK is could-not-observe or a refusal.
# None of them is ever a pass, and none of them may reduce to "no active run".
CNO_CODES = {
    "TIMEOUT": "AXI_TIMEOUT",
    "REFUSED": "AXI_REFUSED",
    "DAEMON": "DAEMON_UNAVAILABLE",
    "SILENT": "AXI_SILENT",
    "SCHEMA": "AXI_SCHEMA_UNEXPECTED",
    "BOUND": "ENUMERATION_INCOMPLETE",
    "NO_DIRECTORY": "AXI_UNAVAILABLE",
    "NO_TOOL": "AXI_UNAVAILABLE",
}
TERMINAL_OUTCOMES = {"cancelled", "failed", "passed", "checks-passed", "completed"}

by_id = {m["id"]: m for m in doc.get("members", [])}
try:
    with open(axi_path, "r", encoding="utf-8") as fh:
        axi_lines = fh.read().splitlines()
except OSError:
    axi_lines = []

for line in axi_lines:
    if not line.strip():
        continue
    parts = line.split("\t", 2)
    run_id = parts[0]
    verdict = parts[1] if len(parts) > 1 else "SCHEMA"
    detail = parts[2] if len(parts) > 2 else ""
    member = by_id.get(run_id)
    if member is not None:
        member["axi"] = {"verdict": verdict, "detail": detail}
    if verdict == "IDENTITY_MISMATCH":
        doc["refusals"].append(
            {"code": "IDENTITY_NONUNIQUE", "subject": run_id, "detail": detail}
        )
        continue
    if verdict != "OK":
        doc["cno"].append(
            {
                "code": CNO_CODES.get(verdict, "AXI_SCHEMA_UNEXPECTED"),
                "subject": run_id,
                "detail": detail,
            }
        )
        continue
    # The daemon answered. It agreeing that a database-active run is over is a
    # contradiction between the two authorities, not a reason to prefer one.
    fields = dict(
        piece.split("=", 1) for piece in detail.split(" ") if "=" in piece
    )
    outcome = fields.get("outcome", "-")
    if member is not None and outcome != "-" and outcome.lower() in TERMINAL_OUTCOMES:
        doc["cno"].append(
            {
                "code": "DAEMON_CONFLICT",
                "subject": run_id,
                "detail": "the database records this run %r while the reader"
                " reports outcome %r" % (member.get("status"), outcome),
            }
        )

universe = doc.get("universe", {})
if doc["refusals"]:
    verdict = "REFUSED"
elif doc["cno"] or not universe.get("observed"):
    verdict = "CNO"
elif universe.get("candidate_owning_runs"):
    verdict = "OBSERVED_ACTIVE"
else:
    verdict = "OBSERVED_QUIESCENT"
doc["verdict"] = verdict
json.dump(doc, sys.stdout, sort_keys=True)
sys.stdout.write("\n")
FM_NM_CENSUS_FOLD_PY
}

# The complete census: one document, one verdict.
#
#   fm_nm_census [--state <dir>] [--scope <path>] [--all-runs]
#
# Prints the census JSON on stdout. Returns 0 always; the VERDICT is the answer,
# and a caller that wants an exit status uses bin/fm-nm-census.sh.
# shellcheck disable=SC2120  # bin/fm-nm-census.sh passes the flags; the in-file
# caller below deliberately wants the defaults for this home.
fm_nm_census() {
  local state_dir scope="" all_runs=0 tmp core axi
  # The work inventory the join needs. Resolved the same way every entrypoint in
  # this repo resolves it, because a census run with no state directory joins
  # nothing and reports every candidate-owning run as unresolved - an alarming
  # answer produced entirely by a missing argument.
  state_dir=${FM_NM_CENSUS_STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}}
  if [ "$state_dir" = "/state" ]; then
    state_dir=''
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --state) state_dir=${2:-}; shift 2 ;;
      --scope) scope=${2:-}; shift 2 ;;
      --all-runs) all_runs=1; shift ;;
      *) shift ;;
    esac
  done
  if ! command -v python3 >/dev/null 2>&1; then
    # No reader, no observation. Printing a document with a CNO verdict is the
    # point: a caller must never be handed silence it can read as quiescence.
    printf '{"schema":"fm-nm-census.v1","verdict":"CNO","universe":{"observed":false,"non_vacuous":false},"members":[],"repositories":[],"runs":[],"refusals":[],"cno":[{"code":"READER_UNAVAILABLE","subject":"python3","detail":"no sqlite reader is available on this host"}]}\n'
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-census.XXXXXX") || return 1
  core="$tmp/core.json"
  axi="$tmp/axi.tsv"
  : > "$axi"
  if ! fm_nm_census_core "$state_dir" "$scope" "$all_runs" > "$core" 2>/dev/null; then
    printf '{"schema":"fm-nm-census.v1","verdict":"CNO","universe":{"observed":false,"non_vacuous":false},"members":[],"repositories":[],"runs":[],"refusals":[],"cno":[{"code":"CENSUS_READER_FAILED","subject":"%s","detail":"the bounded census read did not complete"}]}\n' \
      "$(fm_nm_state_db)"
    rm -rf "$tmp"
    return 0
  fi
  fm_nm_census_axi_probe "$core" > "$axi" 2>/dev/null || true
  if fm_nm_census_fold "$core" "$axi" > "$tmp/census.json" 2>/dev/null &&
    [ -s "$tmp/census.json" ]; then
    cat "$tmp/census.json"
  else
    printf '{"schema":"fm-nm-census.v1","verdict":"CNO","universe":{"observed":false,"non_vacuous":false},"members":[],"repositories":[],"runs":[],"refusals":[],"cno":[{"code":"CENSUS_FOLD_FAILED","subject":"%s","detail":"the census was read but could not be folded into one verdict"}]}\n' \
      "$(fm_nm_state_db)"
  fi
  rm -rf "$tmp"
}

# A census document held for reuse inside ONE observation. FM_NM_CENSUS_FILE
# lets a caller that already took the census (a fleet snapshot reading many
# tasks) hand it to the readers below instead of each of them taking it again.
# It is a projection with a lifetime, not a cache with an authority: past
# FM_NM_CENSUS_MAX_AGE it is not served at all.
FM_NM_CENSUS_MAX_AGE=${FM_NM_CENSUS_MAX_AGE:-120}
case "$FM_NM_CENSUS_MAX_AGE" in ''|*[!0-9]*) FM_NM_CENSUS_MAX_AGE=120 ;; esac

fm_nm_census_document() {  # -> census JSON on stdout
  local now age
  # No arguments by design: every reader below wants THE census for this home,
  # and letting a caller reshape it would mean two readers disagreeing about
  # which universe they observed.
  if [ -n "${FM_NM_CENSUS_FILE:-}" ] && [ -s "${FM_NM_CENSUS_FILE:-}" ]; then
    now=$(date +%s)
    age=$(( now - $(fm_nm_file_mtime "$FM_NM_CENSUS_FILE") ))
    if [ "$age" -ge 0 ] && [ "$age" -le "$FM_NM_CENSUS_MAX_AGE" ]; then
      cat "$FM_NM_CENSUS_FILE"
      return 0
    fi
  fi
  # shellcheck disable=SC2119  # the defaults are the point here, not $@.
  fm_nm_census
}

fm_nm_file_mtime() {  # <path>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=0
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# The consumers' question, answered from the COMPLETE universe rather than from
# one repository's projection: is a candidate-owning run carrying this branch
# live anywhere at all, including inside a managed run worktree registered under
# its own repository id?
#
# Prints one line per match: <status> <run_id> <repository working path>
#
# The exit statuses are the census verdict's, narrowed to one branch, so 0 means
# the same thing on every command of this seam - observed, and quiet:
#
#   0  no candidate-owning run carries this branch, over a completely observed
#      universe
#   1  at least one candidate-owning run carries it
#   2  the evidence is refused
#   3  could not observe - NEVER read as "no run"
fm_nm_census_branch_active() {  # <branch> [<census-json-file>]
  local branch=$1 doc=${2:-} tmp rc
  rc=0
  if [ -n "$doc" ] && [ -s "$doc" ]; then
    fm_nm_census_branch_filter "$branch" "$doc" || rc=$?
    return "$rc"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-nm-census-branch.XXXXXX") || return 3
  fm_nm_census_document > "$tmp"
  fm_nm_census_branch_filter "$branch" "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# The census document is passed BY PATH, never on stdin: these readers hand
# python its program on stdin, so a document sent the same way would be eaten by
# the interpreter and every caller would silently read an empty universe.
fm_nm_census_branch_filter() {  # <branch> <census-json-file>
  command -v python3 >/dev/null 2>&1 || return 3
  python3 - "$1" "$2" <<'FM_NM_CENSUS_BRANCH_PY'
import json
import sys

branch, path = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:  # noqa: BLE001 - an unreadable document is could-not-observe
    sys.exit(3)
verdict = doc.get("verdict")
matches = [m for m in doc.get("members", []) if m.get("branch") == branch]
for m in matches:
    print(
        "%s %s %s"
        % (
            m.get("status") or "-",
            m.get("id") or "-",
            (m.get("repository") or {}).get("working_path") or "-",
        )
    )
if verdict == "REFUSED":
    sys.exit(2)
if matches:
    sys.exit(1)
# No match is only an ANSWER when the universe was completely observed. On a CNO
# census "none for this branch" and "I could not read the universe" are the same
# empty list, and collapsing them is the whole failure this census exists to
# make unreachable.
if verdict in ("OBSERVED_QUIESCENT", "OBSERVED_ACTIVE"):
    sys.exit(0)
sys.exit(3)
FM_NM_CENSUS_BRANCH_PY
}
