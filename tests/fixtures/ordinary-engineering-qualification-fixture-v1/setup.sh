#!/usr/bin/env bash
# setup.sh <case-id> <state-dir> - materialize disposable candidate state.
#
# Writes ONLY the task half: the prompt, any synthetic material the case needs,
# and the submission shape to fill in. The grading key in cases.json is never
# copied here, which is what keeps the oracle outside the candidate's reach.
#
# Exits non-zero without writing anything when the case is unknown or the package
# cannot be read, so a workflow that cannot set up cannot go on to grade an empty
# directory and read the result as a failure of the binding.
set -u

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE=${1:-}
STATE=${2:-}

die() { printf 'setup: %s\n' "$1" >&2; exit 1; }

[ -n "$CASE" ] || die "usage: setup.sh <case-id> <state-dir>"
[ -n "$STATE" ] || die "usage: setup.sh <case-id> <state-dir>"
command -v jq >/dev/null 2>&1 || die "jq is required"
[ -f "$PKG/cases.json" ] || die "package is unreadable: $PKG/cases.json"
jq -e --arg c "$CASE" '.cases[$c] != null' "$PKG/cases.json" >/dev/null 2>&1 \
  || die "unknown case: $CASE"

mkdir -p "$STATE" || die "cannot create $STATE"

{
  printf '# Qualification task: %s\n\n' "$CASE"
  jq -r --arg c "$CASE" '.cases[$c].task' "$PKG/cases.json"
  printf '\n\nWrite your answer as a JSON object to submission.json in this directory.\n'
  printf 'Use these fields:\n'
  jq -r --arg c "$CASE" '(.cases[$c].requires // [])[] | "  - " + .' "$PKG/cases.json"
  printf '\nAnswer only from the material given here.\n'
} > "$STATE/task.md" || die "cannot write the task"

# A case that needs synthetic material gets its own copy, so the candidate reads
# from the disposable state rather than from the package.
MATERIAL=$(jq -r --arg c "$CASE" '.cases[$c].material // empty' "$PKG/cases.json")
if [ -n "$MATERIAL" ]; then
  [ -f "$PKG/$MATERIAL" ] || die "declared material is missing: $MATERIAL"
  cp "$PKG/$MATERIAL" "$STATE/$(basename "$MATERIAL")" || die "cannot copy the material"
fi

printf '%s\n' "$STATE/task.md"
