#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off, the two members
# bin/fm-autonomy-lib.sh owns.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-reflag.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# --with-source appends a THIRD word naming where the printed posture came from:
#
#   registered    the registry names this project; the posture is the captain's
#                 own recorded standing choice for it
#   unregistered  a registry exists and does not name this project
#   no-registry   this home has no registry at all
#
# THREE ANSWERS, NOT TWO, and this flag is why the distinction exists. Without
# it every one of those cases prints the same `off`, so a caller cannot tell a
# posture the captain recorded from a posture nobody recorded - and a consumer
# resolving a live task's EFFECTIVE posture has to tell them apart, because the
# first outranks the value that task recorded at dispatch and the second does
# not. The default output is unchanged for every existing caller.
# Usage: fm-project-mode.sh [--raw] [--with-source] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-autonomy-lib.sh
. "$SCRIPT_DIR/fm-autonomy-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
WITH_SOURCE=0
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --raw) RAW=1; shift ;;
    --with-source) WITH_SOURCE=1; shift ;;
    *) break ;;
  esac
done
NAME=${1:?usage: fm-project-mode.sh [--raw] [--with-source] <project-name>}

# The one place the printed line is assembled, so the optional third word cannot
# drift from the two that precede it.
emit() {  # <mode> <yolo> <source>
  if [ "$WITH_SOURCE" -eq 1 ]; then
    echo "$1 $2 $3"
  else
    echo "$1 $2"
  fi
}

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  emit no-mistakes off no-registry
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  emit no-mistakes off unregistered
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
source=registered
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  # An unparseable annotation is not a posture the captain recorded, so its
  # source is reported as unregistered along with the conservative fallback.
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off; source=unregistered ;;
esac
# The vocabulary is bin/fm-autonomy-lib.sh's, so the standing posture this
# prints is spelled the way the spawn that consumes it accepts. A value the
# awk above could not produce falls back to the captain's side, matching the
# unknown-mode fallback: this resolves a registry DEFAULT, and the conservative
# default is that nothing granted standing routine authority.
fm_autonomy_state_is_known "$yolo" || { yolo=$FM_AUTONOMY_STATE_CAPTAIN; source=unregistered; }
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
emit "$mode" "$yolo" "$source"
