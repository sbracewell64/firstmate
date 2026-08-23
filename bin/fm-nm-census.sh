#!/usr/bin/env bash
# fm-nm-census.sh - the COMPLETE no-mistakes run census and firstmate
# semantic-work join.
#
# One schema-checked, WAL-consistent read transaction over the installed
# no-mistakes state database enumerates EVERY registered repository - including
# every nested repository identity registered under a managed run worktree - and
# EVERY run. Each potentially candidate-owning run is then joined exactly once to
# firstmate's own semantic work, or classified explicitly unrelated, ambiguous,
# or could-not-observe.
#
# The rule, the vocabulary, and the fold are owned by bin/fm-nm-run-lib.sh; read
# its "complete no-mistakes run census" header for what each verdict means and
# why the fold is weakest-wins. This file is the executable front end.
#
# no-mistakes' state.sqlite and its AXI surface remain the authority for run
# state. This command adds no database, daemon, scheduler, watcher or run
# engine; it observes and joins, and it writes nothing anywhere.
#
# Usage:
#   fm-nm-census.sh [--json] [--state <dir>] [--scope <path>] [--all-runs]
#   fm-nm-census.sh --branch <branch> [--state <dir>]
#
#   --json          print the whole census document (schema fm-nm-census.v1)
#   --state <dir>   firstmate state directory the work inventory is read from
#                   (default: $FM_STATE_OVERRIDE, else $FM_HOME/state)
#   --scope <path>  additionally report the REJECTED repository-scoped projection
#                   for that checkout, the incomplete answer this census replaces
#   --all-runs      include every enumerated run row, not only the members
#   --branch <b>    ask only whether a candidate-owning run carries that branch
#                   anywhere in the complete universe, one line per match
#
# Exit status is the verdict, and 0 is reserved for observed quiescence alone:
#   0  OBSERVED_QUIESCENT  complete, clean enumeration and zero candidate-owning
#                          runs. Check universe.non_vacuous before treating a
#                          global zero as evidence of anything.
#   1  OBSERVED_ACTIVE     at least one candidate-owning run
#   2  REFUSED             a proven defect in the evidence (duplicate identity,
#                          or one piece of work claimed by two runs)
#   3  CNO                 could not observe. NEVER a pass, and never quiescence.
#
# --branch narrows the same four statuses to one branch, so 0 keeps meaning
# observed-and-quiet: 0 no candidate-owning run carries it over a completely
# observed universe, 1 one does, 2 refused, 3 could not observe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

JSON=0
ALL_RUNS=0
SCOPE=""
BRANCH=""
HAVE_BRANCH=0

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --all-runs) ALL_RUNS=1; shift ;;
    --state) [ $# -ge 2 ] || { echo "fm-nm-census: --state needs a value" >&2; exit 2; }
             STATE=$2; shift 2 ;;
    --scope) [ $# -ge 2 ] || { echo "fm-nm-census: --scope needs a value" >&2; exit 2; }
             SCOPE=$2; shift 2 ;;
    --branch) [ $# -ge 2 ] || { echo "fm-nm-census: --branch needs a value" >&2; exit 2; }
              BRANCH=$2; HAVE_BRANCH=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-nm-census: unknown argument: $1" >&2; exit 2 ;;
  esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-census-cli.XXXXXX") || exit 3
trap 'rm -rf "$TMP"' EXIT
DOC="$TMP/census.json"

ARGS=(--state "$STATE")
[ -n "$SCOPE" ] && ARGS+=(--scope "$SCOPE")
[ "$ALL_RUNS" = 1 ] && ARGS+=(--all-runs)
fm_nm_census "${ARGS[@]}" > "$DOC"

if [ "$HAVE_BRANCH" = 1 ]; then
  fm_nm_census_branch_filter "$BRANCH" "$DOC"
  exit $?
fi

if [ "$JSON" = 1 ]; then
  cat "$DOC"
else
  python3 - "$DOC" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as exc:  # noqa: BLE001 - printed as the could-not-observe it is
    print("fm-nm-census: verdict=CNO detail=unreadable-census (%s)" % exc)
    sys.exit(0)
u = doc.get("universe", {})
gen = doc.get("generation", {})
print(
    "fm-nm-census: verdict=%s non_vacuous=%s repositories=%s nested=%s runs=%s"
    " active=%s candidate_owning=%s cno=%s refusals=%s"
    % (
        doc.get("verdict", "CNO"),
        "yes" if u.get("non_vacuous") else "no",
        u.get("repositories", 0),
        u.get("nested_identities", 0),
        u.get("runs", 0),
        u.get("active_runs", 0),
        u.get("candidate_owning_runs", 0),
        len(doc.get("cno", [])),
        len(doc.get("refusals", [])),
    )
)
print(
    "fm-nm-census: generation database=%s schema=%s sqlite=%s"
    % (gen.get("database"), gen.get("schema_fingerprint"), gen.get("sqlite_library"))
)
scoped = doc.get("repo_scoped_projection")
if scoped:
    print(
        "fm-nm-census: REJECTED repo-scoped projection for %s reports active=%s"
        " - %s" % (scoped["scope"], scoped["active_runs"], scoped["rejected_reason"])
    )
for member in doc.get("members", []):
    repo = member.get("repository", {})
    print(
        "fm-nm-census: member run=%s status=%s branch=%s join=%s work=%s"
        " generation=%s nested=%s repo=%s"
        % (
            member.get("id"),
            member.get("status"),
            member.get("branch"),
            member.get("join"),
            member.get("work", "-"),
            member.get("generation"),
            "yes" if repo.get("nested") else "no",
            repo.get("working_path"),
        )
    )
for entry in doc.get("refusals", []):
    print("fm-nm-census: REFUSED %s %s - %s" % (entry["code"], entry["subject"], entry["detail"]))
for entry in doc.get("cno", []):
    print("fm-nm-census: CNO %s %s - %s" % (entry["code"], entry["subject"], entry["detail"]))
PY
fi

case "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("verdict","CNO"))' "$DOC" 2>/dev/null)" in
  OBSERVED_QUIESCENT) exit 0 ;;
  OBSERVED_ACTIVE) exit 1 ;;
  REFUSED) exit 2 ;;
  *) exit 3 ;;
esac
