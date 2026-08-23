#!/usr/bin/env bash
# Behavior tests for the COMPLETE no-mistakes run census and firstmate
# semantic-work join - bin/fm-nm-census.sh over bin/fm-nm-run-lib.sh.
#
# The incident these pin: no-mistakes registers every managed run worktree as
# its own repository, so a run created from inside one is absent from the
# enclosing checkout's `axi status` AND from `no-mistakes runs`. Both of
# firstmate's existing reads are repository-scoped, so a hidden active run read
# as quiescence. The watched red below is exactly that shape - the old
# repository-scoped projection reports zero while the complete census reports
# one - and the green is the exact global zero, taken over a universe that
# demonstrably had rows in it.
#
# Every case drives a THROWAWAY database built from the installed schema's own
# column set, never the real one at $HOME/.no-mistakes/state.sqlite: these are
# reds, and a red must never be produced by mutating the fleet's live state.
#
# The vectors are the prepared contract in the task's test-vectors.json:
# hidden-active-nested-repo, enumeration-truncated, axi-malformed,
# axi-leading-refusal-exit-zero, daemon-unavailable, double-candidate-owner,
# head-advanced-unknown, original-head-generation-drift,
# nested-repository-identity, stale-cancelled-owner,
# duplicate-run-id-or-repo-id, could-satisfy-unjoined, and the global-zero
# non-vacuity green.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || {
  echo "ok - fm-nm-census: skipped, python3 is unavailable"
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-nm-census)
CENSUS="$ROOT/bin/fm-nm-census.sh"

# Verdict exit statuses, named so a case reads as its claim rather than a number.
QUIESCENT=0
ACTIVE=1
REFUSED=2
CNO=3

# A throwaway no-mistakes home plus firstmate state directory for one case.
# Sets CASE_DIR, NM_HOME, DB and STATE rather than echoing them: `fail` inside a
# command substitution kills only the subshell and would hand the caller an
# empty path, and an empty path is how a fixture turns into a command against
# the checkout these tests live in.
CASE_DIR=""
NM_HOME=""
DB=""
STATE=""
new_case() {  # <name>
  CASE_DIR="$TMP_ROOT/$1"
  NM_HOME="$CASE_DIR/nm"
  DB="$NM_HOME/state.sqlite"
  STATE="$CASE_DIR/state"
  case "$CASE_DIR" in
    "$TMP_ROOT"/*) ;;
    *) fail "fixture refused: case dir '$CASE_DIR' is outside $TMP_ROOT" ;;
  esac
  mkdir -p "$NM_HOME/worktrees" "$STATE" || fail "could not build case $1"
}

# The two tables the census reads, with the installed v1.40.3 column set.
# `--no-pk` builds the same columns WITHOUT the primary keys, which is how a
# duplicate primary identity is reachable at all: the installed schema's own
# constraint makes it unreachable there, and the census must not depend on a
# constraint it never verified.
init_db() {  # [--no-pk]
  local pk="PRIMARY KEY"
  [ "${1:-}" = --no-pk ] && pk=""
  python3 - "$DB" "$pk" <<'PY'
import sqlite3
import sys

db, pk = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db)
conn.executescript(
    """
    CREATE TABLE repos (
        id             TEXT %s,
        working_path   TEXT NOT NULL,
        upstream_url   TEXT NOT NULL,
        fork_url       TEXT,
        default_branch TEXT NOT NULL DEFAULT 'main',
        created_at     INTEGER NOT NULL
    );
    CREATE TABLE runs (
        id                   TEXT %s,
        repo_id              TEXT NOT NULL,
        branch               TEXT NOT NULL,
        head_sha             TEXT NOT NULL,
        base_sha             TEXT NOT NULL,
        submitted_head_sha   TEXT,
        status               TEXT NOT NULL DEFAULT 'pending',
        pr_url               TEXT,
        last_pushed_sha      TEXT,
        error                TEXT,
        created_at           INTEGER NOT NULL,
        updated_at           INTEGER NOT NULL
    );
    """
    % (pk, pk)
)
conn.commit()
conn.close()
PY
}

# The registered checkout is created on disk as well as in the table. It has to
# exist: the corroboration read asks a real initialized checkout, and a fixture
# that registered a path nobody created would report a missing DIRECTORY as a
# fact about the run.
add_repo() {  # <id> <working_path> [<upstream_url>]
  mkdir -p "$2/.git" || fail "could not create registered checkout $2"
  python3 - "$DB" "$1" "$2" "${3:-https://github.com/o/p.git}" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "insert into repos values (?, ?, ?, null, 'main', 1)", tuple(sys.argv[2:5])
)
conn.commit()
conn.close()
PY
}

# add_run <id> <repo_id> <branch> <head_sha> <status> [<submitted>] [<pr_url>] [<last_pushed>]
add_run() {
  python3 - "$DB" "$@" <<'PY'
import sqlite3
import sys

argv = sys.argv[1:]
db, run_id, repo_id, branch, head, status = argv[:6]
submitted = argv[6] if len(argv) > 6 and argv[6] else None
pr_url = argv[7] if len(argv) > 7 and argv[7] else None
pushed = argv[8] if len(argv) > 8 and argv[8] else None
conn = sqlite3.connect(db)
conn.execute(
    "insert into runs values (?, ?, ?, ?, 'base', ?, ?, ?, ?, null, 1, 1)",
    (run_id, repo_id, branch, head, submitted, status, pr_url, pushed),
)
conn.commit()
conn.close()
PY
}

# A firstmate work record, with a worktree whose git HEAD names its branch. The
# HEAD is written as git's own files rather than by running git: the census
# reads them the same way, and the point of the case is the join, not git.
add_work() {  # <id> <branch> [<pr_head>] [<pr_url>] [<venue>]
  local id=$1 branch=$2 pr_head=${3:-} pr_url=${4:-} venue=${5:-https://github.com/o/p.git}
  local wt="$CASE_DIR/wt-$id"
  mkdir -p "$wt/.git" || fail "could not build work $id"
  printf 'ref: refs/heads/%s\n' "$branch" > "$wt/.git/HEAD"
  {
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$wt"
    printf 'deliverable=ship\n'
    printf 'contribution_venue_url=%s\n' "$venue"
    # Every real task meta carries these two, and every task dispatched from one
    # trunk carries the SAME value in them. They are here so a fixture cannot
    # accidentally prove a join rule that the real record shape would break.
    printf 'slot_base=%s\n' "${FM_TEST_BASE:-baaaaaaaaaaa}"
    printf 'contribution_target=%s\n' "${FM_TEST_BASE:-baaaaaaaaaaa}"
    [ -n "$pr_head" ] && printf 'pr_head=%s\n' "$pr_head"
    [ -n "$pr_url" ] && printf 'pr=%s\n' "$pr_url"
  } > "$STATE/$id.meta"
}

# A fake `no-mistakes` whose `axi status --run` answer this case controls.
# FM_FAKE_AXI serves the body verbatim; the default corroborates whatever run id
# it is asked about, which is the shape a healthy daemon has.
fakebin() {
  local fb="$CASE_DIR/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = axi ] && [ "${2:-}" = status ] && [ "${3:-}" = --run ]; then
  if [ -n "${FM_FAKE_AXI:-}" ]; then
    printf '%s\n' "$FM_FAKE_AXI"
  else
    printf 'run:\n  id: "%s"\n  status: running\n  head: cccccccccccc\n' "$4"
  fi
fi
exit "${FM_FAKE_AXI_EXIT:-0}"
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# One census run over this case's fixture, printing the JSON and RETURNING the
# verdict exit status. The status is deliberately not recorded inside this
# helper: it runs in a command-substitution subshell, so an assignment here
# never reaches the caller and every case would silently assert against the
# status of the case before it. Call sites record it themselves.
census() {  # <extra args...>
  PATH="$CASE_DIR/fakebin:$PATH" \
  FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" FM_NM_CENSUS_FILE='' \
    "$CENSUS" --json --state "$STATE" "$@"
}
CENSUS_CODE=0

# One field out of a census document, by jq-free python path so the suite does
# not acquire a jq dependency the code under test does not have. The document is
# handed over BY FILE: python is already reading its program on stdin here, so a
# document sent the same way would be eaten by the interpreter and every
# assertion would silently read an empty census.
field() {  # <json> <python expression over `d`>
  local doc="$CASE_DIR/.field.json"
  printf '%s' "$1" > "$doc"
  python3 - "$doc" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    d = json.load(fh)
print(eval(sys.argv[2]))
PY
}

# --- the watched red ---------------------------------------------------------

test_hidden_active_nested_repository_is_seen() {
  new_case hidden-active-nested
  init_db
  fakebin >/dev/null
  local top="$CASE_DIR/checkout"
  mkdir -p "$top/.git"
  add_repo top "$top"
  # The registered repository IS a managed run worktree of the outer run.
  add_repo nest "$NM_HOME/worktrees/top/RUNOUTER"
  add_run RUNOUTER top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNINNER nest fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census --scope "$top"); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "a hidden active nested run is not quiescence"
  assert_contains "$(field "$out" 'd["repo_scoped_projection"]["active_runs"]')" "0" \
    "the old repository-scoped projection reports zero active runs"
  assert_contains "$(field "$out" 'str(d["repo_scoped_projection"]["complete"])')" "False" \
    "the repository-scoped projection is rejected as incomplete"
  assert_contains "$(field "$out" 'd["universe"]["active_runs"]')" "1" \
    "the complete census reports the one governed active run"
  assert_contains "$(field "$out" '[m["id"] for m in d["members"]]')" "RUNINNER" \
    "the hidden run is a census member"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "JOINED" \
    "the hidden run joins firstmate work exactly once"
  assert_contains "$(field "$out" 'd["members"][0]["work"]')" "task-x" \
    "the hidden run joins the work whose branch it carries"
  pass "a run registered under a nested repository identity is seen and joined"
}

test_repo_scoped_projection_alone_is_the_defect() {
  # The negative control for the case above: with the SAME database, asking only
  # the original repository is the answer that was wrong, and the census says so
  # in the document rather than leaving a caller to infer it.
  new_case repo-scoped-rejected
  init_db
  fakebin >/dev/null
  local top="$CASE_DIR/checkout"
  mkdir -p "$top/.git"
  add_repo top "$top"
  add_repo nest "$NM_HOME/worktrees/top/RUNOUTER"
  add_run RUNOUTER top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNINNER nest fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out reason
  out=$(census --scope "$top"); CENSUS_CODE=$?
  reason=$(field "$out" 'd["repo_scoped_projection"]["rejected_reason"]')
  assert_contains "$reason" "cannot define the authoritative universe" \
    "the rejected projection states why it cannot be the universe"
  pass "the repository-scoped projection is carried as rejected, never as the answer"
}

# --- the green, and its non-vacuity -----------------------------------------

test_global_zero_over_a_populated_universe_is_quiescent() {
  new_case global-zero
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_repo nest "$NM_HOME/worktrees/top/RUNOUTER"
  add_run RUNOUTER top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNOLD nest fm/task-x bbbbbbbbbbbb failed
  add_run RUNDONE top fm/task-y dddddddddddd completed
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$QUIESCENT" "$CENSUS_CODE" "a complete clean zero is quiescent"
  assert_contains "$(field "$out" 'd["verdict"]')" "OBSERVED_QUIESCENT" \
    "the verdict is observed quiescence"
  assert_contains "$(field "$out" 'str(d["universe"]["non_vacuous"])')" "True" \
    "the zero was taken over a universe that had rows in it"
  assert_contains "$(field "$out" 'd["universe"]["runs"]')" "3" \
    "every run was enumerated, not only the active ones"
  assert_contains "$(field "$out" 'd["universe"]["repositories"]')" "2" \
    "every registered repository was enumerated"
  assert_contains "$(field "$out" 'd["universe"]["nested_identities"]')" "1" \
    "the nested repository identity was retained rather than omitted"
  pass "an exact global zero over a populated universe is observed quiescence"
}

test_empty_universe_is_quiescent_but_vacuous() {
  # The reason non-vacuity is a separate field: this database is legitimately
  # quiescent and proves nothing whatever about the fleet.
  new_case empty-universe
  init_db
  fakebin >/dev/null

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$QUIESCENT" "$CENSUS_CODE" "an empty database is quiescent"
  assert_contains "$(field "$out" 'str(d["universe"]["non_vacuous"])')" "False" \
    "a zero over an empty universe is marked vacuous"
  pass "a zero over an empty universe is quiescent and explicitly vacuous"
}

test_one_running_row_turns_the_green_red() {
  # The negative control for the green: the same complete enumeration, one row
  # changed, and the verdict must move. A green that cannot be driven red is not
  # evidence of anything.
  new_case green-negative-control
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled
  add_work task-x fm/task-x
  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$QUIESCENT" "$CENSUS_CODE" "the control starts green"

  add_run RUNB top fm/task-x cccccccccccc running
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "one running row must turn the green red"
  pass "the global-zero green is driven red by a single running row"
}

# --- incomplete and unreadable universe reds --------------------------------

test_absent_database_is_could_not_observe() {
  new_case absent-db
  fakebin >/dev/null
  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an absent database is could-not-observe"
  assert_contains "$out" "DATABASE_ABSENT" "the absence is named"
  assert_not_contains "$(field "$out" 'd["verdict"]')" "QUIESCENT" \
    "an absent database is never quiescence"
  pass "an absent state database is could-not-observe, never an empty universe"
}

test_row_bound_is_enumeration_incomplete() {
  new_case bounded-enumeration
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNB top fm/task-x bbbbbbbbbbbb cancelled

  local out
  out=$(
    PATH="$CASE_DIR/fakebin:$PATH" FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" \
    FM_NM_CENSUS_MAX_ROWS=1 FM_NM_CENSUS_FILE='' "$CENSUS" --json --state "$STATE"
  )
  CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a bound the reader hit is could-not-observe"
  assert_contains "$out" "ENUMERATION_INCOMPLETE" "the bound is reported as incompleteness"
  pass "a reader bound reports enumeration incompleteness rather than a prefix"
}

test_unreadable_row_truncates_rather_than_hiding() {
  # A row the reader cannot materialize. It must reduce the enumeration to
  # could-not-observe, not disappear from the counts: an invisible row is how a
  # universe silently shrinks to the reassuring answer.
  new_case unreadable-row
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
# A TEXT column holding bytes that are not UTF-8. count(*) still counts the row
# and the row read cannot decode it, which is what makes the enumeration
# provably short of what the same snapshot declared.
conn.execute(
    "insert into runs values (CAST(x'fffe2d626164' AS TEXT), 'top', 'fm/task-x',"
    " 'bbbbbbbbbbbb', 'base', null, 'cancelled', null, null, null, 1, 1)"
)
conn.commit()
conn.close()
PY

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an unreadable row is could-not-observe"
  assert_contains "$out" "ENUMERATION_INCOMPLETE" \
    "an unreadable row truncates the enumeration"
  pass "a row the reader cannot materialize truncates rather than vanishing"
}

test_incompatible_schema_is_could_not_observe() {
  new_case schema-drift
  mkdir -p "$NM_HOME"
  fakebin >/dev/null
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.executescript(
    "create table repos (id text primary key, working_path text, upstream_url text);"
    "create table runs (id text primary key, repo_id text, branch text);"
)
conn.commit()
conn.close()
PY

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a schema the reader cannot read is could-not-observe"
  assert_contains "$out" "SCHEMA_INCOMPATIBLE" "the missing columns are named"
  pass "an incompatible schema is could-not-observe, never zero active runs"
}

test_additional_columns_stay_readable() {
  # The other direction of the same rule: a newer no-mistakes that only ADDS
  # columns must not be read as schema drift, or every future release would
  # silently stop the fleet from observing its own runs. The rows go in BEFORE
  # the column is added, so the case cannot pass over an empty table - which is
  # how a forward-compatibility test quietly becomes a test of nothing.
  new_case schema-forward
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNB top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.execute("alter table runs add column some_future_field text")
conn.commit()
conn.close()
PY

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "an added column is not schema drift"
  assert_contains "$(field "$out" 'd["universe"]["runs"]')" "2" \
    "every run is still enumerated through the widened schema"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "JOINED" \
    "the join still resolves through the widened schema"
  pass "a forward-compatible schema with extra columns stays readable"
}

test_orphan_run_repository_is_could_not_observe() {
  new_case orphan-run
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA missing fm/task-x aaaaaaaaaaaa cancelled

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a run outside the enumerated repositories is could-not-observe"
  assert_contains "$out" "ORPHAN_RUN_REPOSITORY" "the orphan is named"
  pass "a run referencing an unenumerated repository means the universe is not the universe"
}

test_unknown_run_status_is_candidate_owning() {
  new_case unknown-status
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc some_future_state
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an unrecognized run status is could-not-observe"
  assert_contains "$out" "UNKNOWN_RUN_STATUS" "the unrecognized status is named"
  assert_contains "$(field "$out" 'd["universe"]["candidate_owning_runs"]')" "1" \
    "an unrecognized status is treated as potentially candidate-owning"
  pass "a run status outside the vocabulary is candidate-owning, not terminal"
}

# --- AXI corroboration reds --------------------------------------------------

test_axi_refusal_on_exit_zero_is_never_a_run() {
  new_case axi-refusal
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='error: repo not initialized' census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a refusal that exits zero is could-not-observe"
  assert_contains "$out" "AXI_REFUSED" "the refusal is named as one"
  assert_not_contains "$(field "$out" 'd["verdict"]')" "QUIESCENT" \
    "a refusal is never quiescence"
  assert_contains "$(field "$out" 'd["universe"]["active_runs"]')" "1" \
    "the active run the database recorded is still reported"
  pass "a leading refusal on a zero exit is could-not-observe and never a run"
}

# The ordinary refusal shape: the tool prints its refusal AND exits non-zero.
# The zero-exit case above is the surprising one; this is the common one, and a
# reader that let a non-zero status abort it would drop every candidate-owning
# run after the first refusal.
test_axi_refusal_with_nonzero_exit_is_could_not_observe() {
  new_case axi-refusal-nonzero
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_run RUNB top fm/task-y dddddddddddd running
  add_work task-x fm/task-x
  add_work task-y fm/task-y
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='error: not in a git repository' FM_FAKE_AXI_EXIT=1 census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a refusal that exits non-zero is could-not-observe"
  assert_contains "$(field "$out" 'len([c for c in d["cno"] if c["code"] == "AXI_REFUSED"])')" "2" \
    "every candidate-owning run is probed, not just the one before the first refusal"
  pass "a refusal that exits non-zero is could-not-observe and never stops the sweep"
}

test_daemon_unavailable_is_never_zero_active() {
  new_case daemon-down
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='error: connect to daemon: no such file or directory' census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an unreachable daemon is could-not-observe"
  assert_contains "$out" "DAEMON_UNAVAILABLE" "the daemon is named as the unreachable part"
  assert_contains "$(field "$out" 'd["universe"]["active_runs"]')" "1" \
    "an unreachable daemon never reduces the active count to zero"
  pass "an unreachable reader is could-not-observe, never zero active runs"
}

test_axi_record_without_required_fields_is_schema_unexpected() {
  new_case axi-malformed
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='run:
  branch: fm/task-x' census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a record without id/status is could-not-observe"
  assert_contains "$out" "AXI_SCHEMA_UNEXPECTED" "the unexpected shape is named"
  pass "an AXI record lacking the required id and status fields is could-not-observe"
}

test_axi_record_for_another_run_is_refused() {
  # A record fetched BY KEY whose own identity is a different key answers for a
  # subject nobody asked about. It is refused rather than returned.
  new_case axi-identity-mismatch
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='run:
  id: "SOMEOTHERRUN"
  status: running' census); CENSUS_CODE=$?
  expect_code "$REFUSED" "$CENSUS_CODE" "a record for another run is refused"
  assert_contains "$out" "IDENTITY_NONUNIQUE" "the identity mismatch is refused by name"
  pass "an AXI record whose identity is not the key asked for is refused"
}

test_daemon_contradiction_is_could_not_observe() {
  new_case daemon-conflict
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_work task-x fm/task-x
  fakebin >/dev/null

  local out
  out=$(FM_FAKE_AXI='run:
  id: "RUNA"
  status: cancelled
outcome: cancelled' census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "two authorities disagreeing is could-not-observe"
  assert_contains "$out" "DAEMON_CONFLICT" "the contradiction is named"
  pass "a database-active run the reader calls finished is a contradiction, not a preference"
}

test_axi_corroboration_bound_is_enumeration_incomplete() {
  new_case axi-bound
  init_db
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x cccccccccccc running
  add_run RUNB top fm/task-y dddddddddddd running
  add_work task-x fm/task-x
  add_work task-y fm/task-y
  fakebin >/dev/null

  local out
  out=$(
    PATH="$CASE_DIR/fakebin:$PATH" FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" \
    FM_NM_CENSUS_AXI_MAX=1 FM_NM_CENSUS_FILE='' "$CENSUS" --json --state "$STATE"
  )
  CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a corroboration bound is could-not-observe"
  assert_contains "$out" "ENUMERATION_INCOMPLETE" \
    "the corroboration bound is reported rather than silently truncating"
  pass "a corroboration bound is reported, never a quietly corroborated prefix"
}

# --- join reds ---------------------------------------------------------------

test_two_runs_claiming_one_work_is_refused() {
  new_case double-owner
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_repo nest "$NM_HOME/worktrees/top/RUNA"
  add_run RUNA top fm/task-x cccccccccccc running
  add_run RUNB nest fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$REFUSED" "$CENSUS_CODE" "one work with two candidate owners is refused"
  assert_contains "$out" "AMBIGUOUS_MUTATION_OWNER" "the ambiguity is refused by name"
  pass "two candidate-owning runs claiming one piece of work is refused, not resolved"
}

test_one_run_claiming_two_works_is_refused() {
  new_case ambiguous-owner
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/shared cccccccccccc running
  add_work task-a fm/shared
  add_work task-b fm/shared

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$REFUSED" "$CENSUS_CODE" "one run with two candidate owners is refused"
  assert_contains "$out" "AMBIGUOUS_MUTATION_OWNER" "the ambiguity is refused by name"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "AMBIGUOUS" \
    "the member itself records the ambiguity"
  pass "a run that joins two pieces of work is refused rather than assigned to one"
}

# A run whose tip is still the trunk it branched from - the shape of every run
# in the moments after it is created. The base is shared by the whole fleet, so
# a join that read it as identity would match this run to every task at once and
# refuse them all as ambiguous. It must join on the branch alone.
test_shared_base_head_does_not_make_every_task_a_candidate() {
  new_case shared-base
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-a baaaaaaaaaaa running
  add_work task-a fm/task-a
  add_work task-b fm/task-b
  add_work task-c fm/task-c

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "a run still at the shared base is not ambiguous"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "JOINED" \
    "the run joins exactly the work whose branch it carries"
  assert_contains "$(field "$out" 'd["members"][0]["work"]')" "task-a" \
    "the shared base must not attract the other tasks"
  assert_contains "$(field "$out" 'len(d["refusals"])')" "0" \
    "a shared base is not an ambiguous mutation owner"
  pass "a run sitting at the shared trunk base joins on identity, not on the base"
}

test_moved_generation_is_stale_projection() {
  new_case generation-moved
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  # The run's CURRENT head is not the head firstmate recorded for this work.
  add_run RUNA top fm/task-x eeeeeeeeeeee running
  add_work task-x fm/task-x aaaaaaaaaaaa

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "a moved generation is could-not-observe"
  assert_contains "$out" "STALE_FIRSTMATE_PROJECTION" "the stale projection is named"
  assert_contains "$(field "$out" 'd["members"][0]["generation"]')" "moved" \
    "the member records that its generation moved"
  assert_contains "$(field "$out" 'str(d["members"][0]["exact_head_evidence"])')" "False" \
    "prior exact-head evidence is not carried forward"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "JOINED" \
    "a moved generation still joins - movement is propagated, not dropped"
  pass "a run head past firstmate's stored generation is a stale projection"
}

test_submitted_head_cannot_identify_the_current_generation() {
  new_case submitted-head-drift
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  # Submitted head still matches the old firstmate record; current and pushed
  # heads have both moved past it.
  add_run RUNA top fm/task-x eeeeeeeeeeee running aaaaaaaaaaaa '' ffffffffffff
  add_work task-x fm/task-x aaaaaaaaaaaa

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an old submitted head does not identify the generation"
  assert_contains "$out" "STALE_FIRSTMATE_PROJECTION" "the drift is named"
  assert_contains "$(field "$out" 'str(d["members"][0]["submitted_head_only"])')" "True" \
    "the member records that only the submitted head still matches"
  pass "an old submitted head cannot identify the current generation"
}

test_exact_generation_is_recorded_as_exact() {
  new_case generation-exact
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa running
  add_work task-x fm/task-x aaaaaaaaaaaa

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "a matching generation is a clean active observation"
  assert_contains "$(field "$out" 'd["members"][0]["generation"]')" "exact" \
    "the member records exact-head evidence"
  pass "a run at firstmate's stored generation carries exact-head evidence"
}

test_unjoinable_governed_run_is_could_not_observe() {
  new_case unjoined
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  # Same upstream as firstmate's work, so it cannot be positively unrelated -
  # and no branch, head or PR matches anything, so it cannot be joined either.
  add_run RUNA top fm/somebody-elses-branch cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an unjoinable governed run is could-not-observe"
  assert_contains "$out" "UNRESOLVED_GOVERNED_RUN" "the unresolved run is named"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "CNO" \
    "the member is retained as could-not-observe rather than dropped"
  pass "a governed run that can be neither joined nor excluded is kept as could-not-observe"
}

test_positively_unrelated_run_is_classified_not_shrugged() {
  new_case unrelated
  init_db
  fakebin >/dev/null
  add_repo other "$CASE_DIR/elsewhere" https://github.com/someone/else.git
  add_run RUNA other main cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "an unrelated active run is still an active run"
  assert_contains "$(field "$out" 'd["members"][0]["join"]')" "UNRELATED" \
    "a run against a venue firstmate is not working on is positively unrelated"
  assert_contains "$(field "$out" 'len(d["cno"])')" "0" \
    "a positive classification produces no could-not-observe"
  pass "a run outside every firstmate venue and checkout is positively unrelated"
}

test_cancelled_row_is_history_not_a_mutation_owner() {
  new_case stale-cancelled
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  # Branch AND head both match the work exactly - and the run is over.
  add_run RUNOLD top fm/task-x aaaaaaaaaaaa cancelled
  add_work task-x fm/task-x aaaaaaaaaaaa

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$QUIESCENT" "$CENSUS_CODE" "a cancelled run leaves the universe quiescent"
  assert_contains "$(field "$out" 'len(d["members"])')" "0" \
    "a terminal run is not a candidate mutation owner however well its text matches"
  assert_contains "$(field "$out" 'd["universe"]["runs"]')" "1" \
    "the terminal run is still enumerated and counted"
  pass "a cancelled row is historical evidence, never the current mutation owner"
}

test_duplicate_primary_identity_is_refused() {
  new_case duplicate-identity
  init_db --no-pk
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNA top fm/task-x bbbbbbbbbbbb cancelled

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$REFUSED" "$CENSUS_CODE" "a duplicate primary identity is refused"
  assert_contains "$out" "IDENTITY_NONUNIQUE" "the duplicate identity is refused by name"
  pass "duplicate primary identity in the authoritative rows is refused"
}

# --- nested repository identity ----------------------------------------------

test_recursive_nesting_resolves_to_one_root() {
  new_case recursive-nesting
  init_db
  fakebin >/dev/null
  local top="$CASE_DIR/checkout"
  add_repo top "$top"
  add_repo nest1 "$NM_HOME/worktrees/top/RUN1"
  # The shape measured on the real host: a gate source inside a run worktree
  # that is itself inside a run worktree.
  add_repo nest2 "$NM_HOME/worktrees/nest1/RUN2/.no-mistakes/gate-source"
  add_run RUN1 top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUN2 nest1 fm/task-x bbbbbbbbbbbb cancelled
  add_run RUN3 nest2 fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$ACTIVE" "$CENSUS_CODE" "a twice-nested active run is seen"
  assert_contains "$(field "$out" 'd["universe"]["nested_identities"]')" "2" \
    "both nested repository identities are enumerated"
  assert_contains "$(field "$out" 'd["members"][0]["repository"]["root_working_path"]')" "$top" \
    "the enclosing chain resolves to the one real checkout"
  assert_contains "$(field "$out" 'd["members"][0]["repository"]["depth"]')" "2" \
    "the nesting depth is recorded"
  assert_contains "$(field "$out" 'd["members"][0]["repository"]["enclosing_run_id"]')" "RUN2" \
    "the enclosing run is attached where it is observable"
  pass "a recursively nested repository identity is retained and resolved to its root"
}

test_nested_identity_with_no_observable_enclosure_is_kept() {
  new_case orphan-nesting
  init_db
  fakebin >/dev/null
  # A nested identity whose enclosing repository was never registered. It must
  # still be enumerated: omitting it is exactly the defect this census repairs.
  add_repo nest "$NM_HOME/worktrees/vanished/RUNX"
  add_run RUNA nest fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out
  out=$(census); CENSUS_CODE=$?
  expect_code "$CNO" "$CENSUS_CODE" "an unresolvable enclosure is could-not-observe"
  assert_contains "$out" "NESTED_ROOT_UNRESOLVED" "the unresolvable chain is named"
  assert_contains "$(field "$out" 'd["universe"]["nested_identities"]')" "1" \
    "the nested identity is still enumerated"
  assert_contains "$(field "$out" 'len(d["members"])')" "1" \
    "its run is still a member"
  pass "a nested identity with no observable enclosure is kept, never omitted"
}

# --- the consumer question ---------------------------------------------------

test_branch_query_answers_from_the_complete_universe() {
  new_case branch-query
  init_db
  fakebin >/dev/null
  local top="$CASE_DIR/checkout"
  add_repo top "$top"
  add_repo nest "$NM_HOME/worktrees/top/RUNOUTER"
  add_run RUNOUTER top fm/task-x aaaaaaaaaaaa cancelled
  add_run RUNINNER nest fm/task-x cccccccccccc running
  add_work task-x fm/task-x

  local out code
  out=$(
    PATH="$CASE_DIR/fakebin:$PATH" FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" \
    FM_NM_CENSUS_FILE='' "$CENSUS" --branch fm/task-x --state "$STATE"
  )
  code=$?
  expect_code "$ACTIVE" "$code" "the branch carries a candidate-owning run"
  assert_contains "$out" "RUNINNER" "the hidden run is the one reported"

  out=$(
    PATH="$CASE_DIR/fakebin:$PATH" FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" \
    FM_NM_CENSUS_FILE='' "$CENSUS" --branch fm/no-such-branch --state "$STATE"
  )
  code=$?
  expect_code "$QUIESCENT" "$code" "a branch with no run answers none over a complete universe"
  assert_contains "${out:-<none>}" "<none>" "no run is reported for a branch that carries none"
  pass "the branch query answers from the complete universe, not one repository"
}

test_branch_query_on_an_unobservable_universe_is_not_none() {
  # The whole failure this census exists to make unreachable: "no run for this
  # branch" and "I could not read the universe" are the same empty list, and
  # they must not share an exit status.
  new_case branch-query-cno
  fakebin >/dev/null
  local out code
  out=$(
    PATH="$CASE_DIR/fakebin:$PATH" FM_NM_HOME="$NM_HOME" FM_PIPELINE_STATE_DB="$DB" \
    FM_NM_CENSUS_FILE='' "$CENSUS" --branch fm/task-x --state "$STATE"
  )
  code=$?
  expect_code "$CNO" "$code" "an unobservable universe answers could-not-observe"
  assert_contains "${out:-<empty>}" "<empty>" "no run is reported from an unobservable universe"
  pass "an unobservable universe answers could-not-observe, never no-run"
}

# --- generation binding ------------------------------------------------------

test_every_result_is_bound_to_its_database_and_schema_generation() {
  new_case generation-binding
  init_db
  fakebin >/dev/null
  add_repo top "$CASE_DIR/checkout"
  add_run RUNA top fm/task-x aaaaaaaaaaaa cancelled

  local out fingerprint
  out=$(census); CENSUS_CODE=$?
  assert_contains "$(field "$out" 'd["generation"]["database"]')" "$DB" \
    "the result names the exact database it was taken from"
  fingerprint=$(field "$out" 'd["generation"]["schema_fingerprint"]')
  assert_contains "$fingerprint" "sha256:" "the result carries a schema fingerprint"
  assert_contains "$(field "$out" 'd["generation"]["integrity"]')" "ok" \
    "the result carries the integrity check it was taken under"
  assert_contains "$(field "$out" 'str(d["generation"]["database_bytes"] > 0)')" "True" \
    "the result carries the exact database size it read"
  assert_contains "$(field "$out" 'd["generation"]["reader"]')" "fm-nm-census.v1" \
    "the result names the reader generation that produced it"

  # A schema change must change the binding, or the binding is decoration.
  python3 - "$DB" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
conn.execute("alter table runs add column later_field text")
conn.commit()
conn.close()
PY
  out=$(census); CENSUS_CODE=$?
  assert_not_contains "$(field "$out" 'd["generation"]["schema_fingerprint"]')" "$fingerprint" \
    "a changed schema must produce a different fingerprint"
  pass "every result is bound to the exact database and schema generation it was read from"
}

test_hidden_active_nested_repository_is_seen
test_repo_scoped_projection_alone_is_the_defect
test_global_zero_over_a_populated_universe_is_quiescent
test_empty_universe_is_quiescent_but_vacuous
test_one_running_row_turns_the_green_red
test_absent_database_is_could_not_observe
test_row_bound_is_enumeration_incomplete
test_unreadable_row_truncates_rather_than_hiding
test_incompatible_schema_is_could_not_observe
test_additional_columns_stay_readable
test_orphan_run_repository_is_could_not_observe
test_unknown_run_status_is_candidate_owning
test_axi_refusal_on_exit_zero_is_never_a_run
test_axi_refusal_with_nonzero_exit_is_could_not_observe
test_daemon_unavailable_is_never_zero_active
test_axi_record_without_required_fields_is_schema_unexpected
test_axi_record_for_another_run_is_refused
test_daemon_contradiction_is_could_not_observe
test_axi_corroboration_bound_is_enumeration_incomplete
test_two_runs_claiming_one_work_is_refused
test_one_run_claiming_two_works_is_refused
test_shared_base_head_does_not_make_every_task_a_candidate
test_moved_generation_is_stale_projection
test_submitted_head_cannot_identify_the_current_generation
test_exact_generation_is_recorded_as_exact
test_unjoinable_governed_run_is_could_not_observe
test_positively_unrelated_run_is_classified_not_shrugged
test_cancelled_row_is_history_not_a_mutation_owner
test_duplicate_primary_identity_is_refused
test_recursive_nesting_resolves_to_one_root
test_nested_identity_with_no_observable_enclosure_is_kept
test_branch_query_answers_from_the_complete_universe
test_branch_query_on_an_unobservable_universe_is_not_none
test_every_result_is_bound_to_its_database_and_schema_generation

echo "all fm-nm-census tests passed"
