#!/usr/bin/env bash
# Resolve a project's REGISTERED posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off, the two members
# bin/fm-autonomy-lib.sh owns.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-reflag.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init),
# bin/fm-spawn.sh's advisory registry-deviation notice, and - through
# --contribution - bin/fm-spawn.sh's base and venue resolution.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
# The annotation is a set of tokens, so contribute= below composes with either
# of the two above in any order, and may also stand alone.
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
# CONTRIBUTION POSTURE - `contribute=fork` | `contribute=upstream`, read only by
# --contribution, which prints exactly one word: fork, upstream, or default.
#
# It exists because a fork layout has TWO trunks a task could be contributed to
# and the checkout alone cannot say which one the captain approved. The clone
# looks identical either way, so bin/fm-task-base-lib.sh derived the upstream
# trunk from the remotes and sent fork-approved work to the upstream repository -
# a venue whose trunk does not even carry the material the work builds on. The
# captain's standing answer is registry data, not something to re-derive, so it
# is recorded here as a token and consumed there as an input.
#
# ABSENT IS `default`, AND UNREADABLE IS A REFUSAL. No token, an unregistered
# project, and an absent registry all print `default`, which is today's
# derive-from-the-remotes behavior and the conservative posture for a project
# nobody declared one for. A token this cannot name - an unknown value, or the
# same key written twice - prints nothing and exits 1, because the captain
# declared SOMETHING and choosing between fork and upstream on their behalf is
# the exact guess this token was added to remove. That refusal is scoped to
# --contribution: the mode and yolo answer is derived independently and is still
# printed, so a contribution typo never silently drops the delivery gate.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
# It is a variant of the two-word answer and does not combine with --contribution.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
# Usage: fm-project-mode.sh [--raw | --contribution] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-autonomy-lib.sh
. "$SCRIPT_DIR/fm-autonomy-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
QUERY=posture
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --raw) RAW=1; shift ;;
    --contribution) QUERY=contribution; shift ;;
    *) break ;;
  esac
done
if [ "$RAW" -eq 1 ] && [ "$QUERY" = contribution ]; then
  echo "error: --raw and --contribution answer different questions; pass one" >&2
  exit 1
fi
NAME=${1:?usage: fm-project-mode.sh [--raw | --contribution] <project-name>}

# The registry-absent and project-absent answers are the same conservative
# default for both questions: the most rigorous delivery gate, and the
# derive-from-the-remotes contribution posture nobody declared otherwise for.
# The warning names the answer this call actually returns, so a caller reading
# stderr is not told about a gate it did not ask for.
unregistered() {  # <why>
  if [ "$QUERY" = contribution ]; then
    echo "warn: $1; defaulting $NAME to the derived contribution posture" >&2
    echo "default"
  else
    echo "warn: $1; defaulting $NAME to no-mistakes off" >&2
    echo "no-mistakes off"
  fi
  exit 0
}

if [ ! -f "$REG" ]; then
  unregistered "no registry at $REG"
fi

# awk emits "<mode>\t<yolo>\t<contribute-values>" (one line) or nothing if the
# project is absent. The annotation is read ONCE, here, and the three answers are
# derived from that one read: contribute= values are passed through joined by a
# comma rather than resolved, so the shell below can tell a key written twice
# from a key written once and refuse instead of picking one.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off"; contribute="";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      # A leading token that is one of the orthogonal flags leaves the mode at
      # its default, so an annotation may carry the flags alone.
      if (a[1] != "" && a[1] != "+yolo" && a[1] !~ /^contribute=/) mode = a[1];
      for (j=1; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else if (a[j] ~ /^contribute=/) contribute = contribute (contribute==""?"":",") substr(a[j], 12);
      }
    }
    printf "%s\t%s\t%s\n", mode, yolo, contribute; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  unregistered "project \"$NAME\" not in registry"
fi

mode=${parsed%%	*}
rest=${parsed#*	}
yolo=${rest%%	*}
contribute=${rest#*	}

if [ "$QUERY" = contribution ]; then
  # An absent token is the derive-from-the-remotes default; a token this cannot
  # name is refused rather than resolved on the captain's behalf (see the header).
  case "$contribute" in
    '') echo "default" ;;
    fork|upstream|default) echo "$contribute" ;;
    *,*)
      echo "error: $NAME registers contribute= more than once (\"$contribute\"); one contribution posture per project" >&2
      exit 1 ;;
    *)
      echo "error: $NAME registers an unknown contribution posture \"$contribute\"; use contribute=fork or contribute=upstream" >&2
      exit 1 ;;
  esac
  exit 0
fi

case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
# The vocabulary is bin/fm-autonomy-lib.sh's, so the standing posture this
# prints is spelled the way the spawn that consumes it accepts. A value the
# awk above could not produce falls back to the captain's side, matching the
# unknown-mode fallback: this resolves a registry DEFAULT, and the conservative
# default is that nothing granted standing routine authority.
fm_autonomy_state_is_known "$yolo" || yolo=$FM_AUTONOMY_STATE_CAPTAIN
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
