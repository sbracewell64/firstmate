#!/usr/bin/env bash
# fm-wrong-subject.sh - render and validate a wrong-subject finding: a review
# finding about a check that reasoned correctly and whose verdict is credited
# to a claim it never established.
#
# .agents/skills/wrong-subject/SKILL.md owns the CLASS - what it is, its six
# drift axes, and the law that a finding of it resolves the credited claim to
# could-not-observe. This script owns the finding's FORM, and owns nothing else.
#
# WHY THE FORM IS ENFORCED AND THE CLASS IS NOT
#
# The finding's value is the pair of claims. A finding that names only the
# defect - "this guard is wrong" - loses the reason, and the reason is the whole
# point of naming the class: the gap between the claim the check establishes and
# the claim its verdict is credited with IS the finding. So the pair is required,
# and this script refuses to render a block without it.
#
# Whether a given check ANYWHERE belongs to the class is a semantic mismatch
# between a verdict and a question, and nothing here tries to decide it. A
# detector for that would emit confident false positives, which is this exact
# failure one level up and the most likely way to make the problem worse.
#
# So the split is: form is decidable from the text and is enforced; membership
# is a judgment and is left to the author. `check` names its own subject in its
# result tokens for that reason - it reports on FORM, never on truth.
#
# THE DERIVED LINE
#
# `therefore:` is computed, never accepted from an author, because it is the one
# line an author could get wrong in the direction that matters. Naming the gap
# establishes that the check did not look at the credited subject; it says
# nothing about what that subject is actually like. So the credited claim
# resolves to could-not-observe and to nothing else - never to the opposite
# verdict, in either direction. That is fm-verify-lib.sh's NO_VERIFIER_RAN,
# reached for this specific reason.
#
# ONE PHYSICAL LINE PER FIELD
#
# Deliberately unwrapped. A wrapped block needs a continuation rule, and a
# continuation rule is a second way to write the same finding - so a value
# carrying a newline is refused rather than folded. Terminals and Markdown wrap
# the long lines themselves, and the parser stays exact.
#
# Usage:
#   fm-wrong-subject.sh axes
#   fm-wrong-subject.sh finding --check <where> --axis <axis> \
#       --examined <claim> --credited <claim> --credited-as <pass|fail> \
#       --gap <condition> [--remedy <text>] [--evidence <ref>]...
#   fm-wrong-subject.sh check <path|->
#   fm-wrong-subject.sh --help
#
# finding options:
#   --check <where>      where the check lives: a path, a path:line, a command,
#                        or the name of a guard. The locator that makes the
#                        finding actionable.
#   --axis <axis>        one of the six drift axes; run `axes` for the list and
#                        each axis's diagnostic question. The closed set is the
#                        point: an axis this script cannot name is an axis a
#                        reviewer cannot assert without re-arguing it.
#   --examined <claim>   the claim the check ACTUALLY establishes, stated so
#                        that it is true. Its truth is what makes this the
#                        wrong-subject class rather than an ordinary defect, so
#                        a claim that is simply false does not belong here.
#   --credited <claim>   the claim the verdict is being read as establishing.
#   --credited-as <v>    how that credited claim was being read: pass or fail.
#                        Both occur. A permanent false refusal is this class
#                        exactly as much as a permanent false green, and a
#                        review that hunts only false greens misses half of it.
#   --gap <condition>    the concrete condition under which the two claims come
#                        apart. Not "these differ" but "a squash merge replays
#                        the content under a new commit". Without it the finding
#                        is an assertion rather than a finding.
#   --remedy <text>      optional: what observation would establish the credited
#                        claim. Always a fresh observation bound to the credited
#                        subject, never a re-reading of the same evidence.
#   --evidence <ref>     optional, repeatable: a pointer to an artifact. A
#                        pointer, never the artifact's contents.
#
# check results, three-valued at this script's own seam:
#   FORM_COMPLETE    (exit 0) every block found is well formed
#   FORM_INCOMPLETE  (exit 1) at least one block is missing or malformed a field
#   FORM_UNREADABLE  (exit 3) the input could not be read, or holds no finding
#                    block at all. Zero blocks is could-not-observe and never a
#                    pass: a file with nothing to check has not been checked.
#
# Those are three distinct exit codes on purpose. One status covering both a
# negative verdict and a failure to reach one is the defect fm-verify.sh exists
# to prevent, and it would be an odd thing to reintroduce here.
#
# FORM_COMPLETE IS A STATEMENT ABOUT FORM AND ABOUT NOTHING ELSE.
# It does not establish that the examined claim is true, that the two claims
# differ in meaning, that the gap condition is real, or that the named check has
# this defect. Crediting it with any of those would be a wrong-subject finding
# against this script, on the `property` axis.
set -eu

SELF=$(basename "$0")

AXES='instance moment extent stand-in manufacture property'

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit 2
}

axis_known() {  # <axis>
  local a
  for a in $AXES; do
    [ "$a" = "$1" ] && return 0
  done
  return 1
}

print_axes() {
  cat <<'EOF'
The six axes a claim drifts along, and the question each one asks.
Name the operative axis; an instance may sit on two, and naming both beats picking.

instance     Right kind, different individual.
             Could there be a second thing of this kind, and did the check bind
             to the one the verdict speaks about?

moment       Right individual, read at a time the verdict does not speak about.
             Was the subject read at the moment the verdict claims, or at a
             moment recorded earlier?

extent       Part examined, whole credited.
             Does what the check covered reach everything the verdict speaks
             for, and is that boundary stated anywhere?

stand-in     Something that reliably leads to the subject was examined instead
             of the subject.
             Is this the thing, or something that reliably leads to the thing?

manufacture  The examined subject exists only because the check made it.
             What would have to be true of the real subject for this to go red?

property     Right subject, a different property established than the one
             credited.
             Does the property established entail the property named always, or
             only usually?

.agents/skills/wrong-subject/SKILL.md owns the class and the composition law.
EOF
}

# The derived line, in one place. Its wording is fixed here rather than left to
# an author precisely because it is the claim an author would be tempted to
# soften.
therefore_line() {  # <credited-as>
  printf 'the credited claim is could-not-observe, not %s' "$1"
}

emit_field() {  # <key> <value>
  printf '  %-12s %s\n' "$1:" "$2"
}

# The newline is written $'\n' and never "$(printf '\n')": command substitution
# strips trailing newlines, so the latter is the empty string, and a case pattern
# of *""* matches every value. That refusal would fire on everything while
# looking exactly like a working guard.
reject_newline() {  # <option> <value>
  case "$2" in
    *$'\n'*)
      die "$1 value contains a newline; one physical line per field"
      ;;
  esac
}

cmd_finding() {
  local check='' axis='' examined='' credited='' credited_as='' gap='' remedy=''
  local evidence='' missing='' opt val

  while [ $# -gt 0 ]; do
    opt=$1
    case "$opt" in
      --check|--axis|--examined|--credited|--credited-as|--gap|--remedy|--evidence)
        [ $# -ge 2 ] || die "$opt needs a value"
        val=$2
        shift 2
        reject_newline "$opt" "$val"
        case "$opt" in
          --check) check=$val ;;
          --axis) axis=$val ;;
          --examined) examined=$val ;;
          --credited) credited=$val ;;
          --credited-as) credited_as=$val ;;
          --gap) gap=$val ;;
          --remedy) remedy=$val ;;
          --evidence)
            # Repeatable, so each pointer keeps its own line rather than being
            # concatenated into one unparseable field.
            if [ -n "$evidence" ]; then
              evidence="$evidence"$'\n'"$val"
            else
              evidence=$val
            fi
            ;;
        esac
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "unknown option '$opt' (see --help)"
        ;;
    esac
  done

  for opt in check axis examined credited credited-as gap; do
    case "$opt" in
      check) val=$check ;;
      axis) val=$axis ;;
      examined) val=$examined ;;
      credited) val=$credited ;;
      credited-as) val=$credited_as ;;
      gap) val=$gap ;;
      *) val='' ;;
    esac
    [ -n "$val" ] || missing="$missing --$opt"
  done
  [ -z "$missing" ] || die "finding is missing required option(s):$missing"

  axis_known "$axis" || die "unknown axis '$axis' (run '$SELF axes')"
  case "$credited_as" in
    pass|fail) ;;
    *) die "--credited-as must be pass or fail, not '$credited_as'" ;;
  esac
  # Two identical claims name no gap, and the gap is the finding. This is the
  # one refusal that catches a finding written in the shape of the class while
  # saying nothing the class is for.
  [ "$examined" != "$credited" ] ||
    die "--examined and --credited are identical; the gap between them is the finding"

  printf 'wrong-subject finding (axis: %s)\n' "$axis"
  emit_field check "$check"
  emit_field examined "$examined"
  emit_field credited "$credited"
  emit_field credited-as "$credited_as"
  emit_field gap "$gap"
  emit_field therefore "$(therefore_line "$credited_as")"
  [ -z "$remedy" ] || emit_field remedy "$remedy"
  if [ -n "$evidence" ]; then
    while IFS= read -r val; do
      emit_field evidence "$val"
    done <<EOF
$evidence
EOF
  fi
}

# --- check ------------------------------------------------------------------
#
# A block is found by its header line and runs while the following lines are
# fields, so a finding embedded in a scout report or a review comment is checked
# where it actually lives. Every block found is reported; the run's result is
# the worst of them.

CHECK_BLOCKS=0
CHECK_BAD=0

report_block() {  # <line-no> <axis> <fields...>
  local line_no=$1 axis=$2 seen=$3 examined=$4 credited=$5 credited_as=$6 want
  local missing='' key note=''

  for key in check examined credited credited-as gap therefore; do
    case " $seen " in
      *" $key "*) ;;
      *) missing="$missing,$key" ;;
    esac
  done

  if [ -n "$missing" ]; then
    note="missing=${missing#,}"
  elif ! axis_known "$axis"; then
    note="bad=axis:$axis"
  else
    case "$credited_as" in
      pass|fail) ;;
      *) note="bad=credited-as:$credited_as" ;;
    esac
    if [ -z "$note" ] && [ "$examined" = "$credited" ]; then
      note='bad=examined-equals-credited'
    fi
    if [ -z "$note" ]; then
      want=$(therefore_line "$credited_as")
      # The derived line is re-derived and compared rather than trusted, so a
      # hand-edited block that softened it is caught here instead of reading as
      # a well-formed finding.
      [ "$CHECK_THEREFORE" = "$want" ] || note='bad=therefore'
    fi
  fi

  CHECK_BLOCKS=$((CHECK_BLOCKS + 1))
  if [ -n "$note" ]; then
    CHECK_BAD=$((CHECK_BAD + 1))
    printf 'FORM_INCOMPLETE block=%s line=%s %s\n' "$CHECK_BLOCKS" "$line_no" "$note"
  else
    printf 'FORM_COMPLETE block=%s line=%s axis=%s credited-as=%s\n' \
      "$CHECK_BLOCKS" "$line_no" "$axis" "$credited_as"
  fi
}

cmd_check() {
  local src=${1:-} line n=0 in_block=0 block_line=0
  local axis='' seen='' examined='' credited='' credited_as='' key val

  [ -n "$src" ] || die "check needs a path or - (see --help)"
  if [ "$src" != '-' ] && { [ ! -f "$src" ] || [ ! -r "$src" ]; }; then
    printf 'FORM_UNREADABLE input=%s reason=not-readable\n' "$src"
    return 3
  fi
  [ "$src" != '-' ] || src=/dev/stdin

  CHECK_THEREFORE=''
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in
      'wrong-subject finding (axis: '*')')
        if [ "$in_block" -eq 1 ]; then
          report_block "$block_line" "$axis" "$seen" "$examined" "$credited" "$credited_as"
        fi
        axis=${line#wrong-subject finding (axis: }
        axis=${axis%)}
        in_block=1
        block_line=$n
        seen=''
        examined=''
        credited=''
        credited_as=''
        CHECK_THEREFORE=''
        continue
        ;;
    esac
    [ "$in_block" -eq 1 ] || continue
    case "$line" in
      '  '[a-z]*': '*|'  '[a-z]*':  '*)
        key=${line#  }
        key=${key%%:*}
        val=${line#*: }
        # Trim the alignment padding the renderer emits; a value never begins
        # with a space, so this cannot eat one.
        while [ "${val# }" != "$val" ]; do val=${val# }; done
        if [ -n "$val" ]; then
          seen="$seen $key"
          case "$key" in
            examined) examined=$val ;;
            credited) credited=$val ;;
            credited-as) credited_as=$val ;;
            therefore) CHECK_THEREFORE=$val ;;
          esac
        fi
        ;;
      *)
        report_block "$block_line" "$axis" "$seen" "$examined" "$credited" "$credited_as"
        in_block=0
        ;;
    esac
  done <"$src"
  [ "$in_block" -eq 0 ] ||
    report_block "$block_line" "$axis" "$seen" "$examined" "$credited" "$credited_as"

  # Zero blocks is could-not-observe, not a clean file. A run that examined
  # nothing has established nothing, and reporting it as complete would be the
  # empty-set-reads-as-green defect this whole vocabulary is about.
  if [ "$CHECK_BLOCKS" -eq 0 ]; then
    printf 'FORM_UNREADABLE input=%s reason=no-finding-block\n' "${1:-}"
    return 3
  fi
  [ "$CHECK_BAD" -eq 0 ] || return 1
  return 0
}

CHECK_THEREFORE=''

case "${1:--h}" in
  axes)
    [ $# -eq 1 ] || die "axes takes no arguments"
    print_axes
    ;;
  finding)
    shift
    cmd_finding "$@"
    ;;
  check)
    shift
    [ $# -eq 1 ] || die "check takes exactly one path or - (see --help)"
    cmd_check "$1"
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "unknown command '$1' (see --help)"
    ;;
esac
