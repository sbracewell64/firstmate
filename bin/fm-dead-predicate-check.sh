#!/usr/bin/env bash
# fm-dead-predicate-check.sh - refuse a fail-closed predicate that nothing consults.
#
# WHY THIS EXISTS. A guard that is defined but never called is worse than a
# missing guard, because reading the file proves the check exists. Two such
# guards were found in one module family, across three separate review findings:
# fm_outbound_applicability, written correct - refusing a superseded record,
# refusing to default an unobservable head to applicable - and never invoked, so
# the sweep applied no applicability test at all; and fm_outbound_record_state_valid,
# likewise defined once and consulted nowhere.
#
# Two, not three: the third finding's other half was a missing branch rather than
# a dead function. The count is stated exactly because a control built to catch a
# class should not begin by miscounting its own founding evidence.
#
# Fixing three call sites leaves the mechanism that produced them intact, so this
# control checks canonical `name() {` definitions against explicitly accepted
# direct-call forms. A definition or call form outside that syntax is UNCHECKED,
# returns could-not-observe, and names the file and construct. Within the accepted
# syntax, a function with no call site is a defect, and the only way to keep one
# is to say so in writing at the definition itself.
#
# ACCEPTED SYNTAX. Definitions are unindented `name() {` lines. Calls begin a
# command after indentation and optional shell control words, follow an unquoted
# command boundary, occur in a command substitution, begin a canonical one-line
# function body, name a trap handler, or use an `indirect-call: name` mark. A
# `printf` command is accepted only as opaque data and never as call evidence.
# Heredocs and every other function definition or function-name use are UNCHECKED
# rather than interpreted or skipped.
#
# WHAT THIS DOES NOT CATCH, STATED SO THE COVERAGE CANNOT INFLATE.
#
# This control answers exactly one question within its accepted syntax: is a
# function defined and never consulted. It does NOT catch the adjacent shape - a predicate
# that IS called but checks less than its name claims. The same review that found
# the two dead predicates here also found `record_read` validating only a record's
# schema while its name and every call site implied it validated the record, and
# no scanner would have flagged that: the function had call sites and looked
# consulted.
#
# That class is not mechanically decidable, and a control claiming to cover it
# would manufacture precision - the same error as scoring a check on an axis it
# never measured. It is caught by review, and this comment is the record that it
# is review's job rather than this file's.
#
# WHEN A `DEAD` VERDICT MAY BE TRUSTED, AND HOW MUCH OF THE REPOSITORY IS READ.
#
# `DEAD` is issued only when EVERY file that could have held a call site was
# parseable. If any possible consumer is outside the accepted syntax, the
# predicate is COULD_NOT_OBSERVE instead - never `DEAD`. That is the property
# that makes a `DEAD` verdict actionable: it says the call site is absent, not
# merely that this control failed to find one. An earlier version counted call
# sites only inside ENROLLED files, so a predicate called solely from an
# unenrolled consumer was reported `DEAD` although it was live - a false positive
# in the direction that invites deleting working code, and a verdict that
# depended on which files happened to be enrolled rather than on the code.
#
# The cost is visibility, and it is large enough to state plainly: on this
# repository 118 consumer files parse and 215 do not, so most of the tree is
# currently unreadable to this control and could_not_observe is its honest answer
# for any predicate whose consumers live in that majority. That is a measurement
# rather than a failure - the way to shrink 215 is to make more files parse - but
# it must never be mistaken for a clean repository. Every unchecked consumer is
# named in the output, and the summary line always prints `alive=` and
# `could_not_observe=` counts, because "nothing is dead" and "nothing could be
# resolved" are different facts that a single ok line would otherwise conflate.
#
# The checkable rule that came out of that finding, and which belongs with the
# code rather than here: any record retrieved BY KEY must have its content-derived
# identity verified against that key, and a mismatch must refuse rather than
# return the record. bin/fm-public-followup.sh already refuses a receipt whose
# .request_id does not match the request it was fetched for; that is the fleet
# pattern, not a new requirement.
#
# Usage:
#   fm-dead-predicate-check.sh [--json] [<file>...]
#       With no files, checks every enrolled file under the repo's bin/.
#
# ENROLLMENT is per file, by a marker line anywhere in it:
#   # fail-closed-predicates: enforced
# A file-level marker is what lets the repository adopt this one library at a
# time instead of on a flag day. It is deliberately NOT an exemption mechanism:
# removing enrollment to silence a finding is itself pinned by a test, so the
# quiet way out is closed.
#
# A DELIBERATELY UNUSED function is kept by marking the definition itself, on the
# line immediately above it:
#   # unused-by-design: <reason>
# The mark is per function and adjacent on purpose. There is no file-level or
# blanket exemption, because a blanket exemption would silence the next dead
# predicate along with the one someone actually reasoned about. Marked functions
# are REPORTED rather than hidden, so the list stays readable and a stale mark
# stays visible.
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  every enrolled file's functions are consulted, or explicitly marked
#   2  usage error
#   3  at least one function is defined and never consulted
#   4  could-not-observe - no enrolled file was found, or a target was unreadable
#
# 4 IS NOT 0. A checker that finds nothing to check has not established that the
# code is clean, and reporting that as a pass is the same defect one level up.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# The full LINE, not a fragment, because enrolment is matched exactly.
ENROL_MARKER='# fail-closed-predicates: enforced'
KEEP_MARKER='unused-by-design:'

die() { printf 'fm-dead-predicate-check: %s\n' "$1" >&2; exit "${2:-2}"; }

JSON=0
TARGETS=()
while [ $# -gt 0 ]; do
  case $1 in
    --json) JSON=1; shift ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1'" ;;
    *) TARGETS+=("$1"); shift ;;
  esac
done

function_definitions() {  # <file>
  grep -nE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' "$1" \
    | sed -E 's/^([0-9]+):([A-Za-z_][A-Za-z0-9_]*)\(\).*/\1:\2/'
}

function_has_call_site() {  # <function>
  local fn=$1 f
  for f in "${SCANNABLE[@]}"; do
    # The indirect-call mark is deliberately a COMMENT, so it must be read from
    # the raw file: the stripped text has comments removed, which is correct for
    # call detection and would silently discard the one call form that is
    # declared rather than written.
    grep -Eq "#[[:space:]]*indirect-call:[[:space:]]*$fn([^A-Za-z0-9_]|\$)" "$f" && return 0
    if strip_quoted "$f" | awk -v fn="$fn" '
      $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") { next }
      $0 ~ ("^[[:space:]]*((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\\$\\(" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[^\"\047`]*([;|&(){}])[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("\\$\\(" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\\$\\(.*[[:space:]]\\|[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*(if|while|until)[[:space:]].*[[:space:]](\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*[[:space:]](\\|\\||&&)[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*.*[[:space:]](\\|\\||&&)[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*if[[:space:]].*[[:space:]]\\|[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*\\{.*[[:space:]](&&|\\|\\|)[[:space:]]*!?[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("[[:space:]]\\|\\|[[:space:]]*\\{[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      # A CONTINUATION LINE that opens with || or && , optionally negated. This is
      # a genuine call site and a common idiom - measured at 65 occurrences across
      # bin/ - so its absence was the whitelist being under-specified rather than
      # the code being unusual. Added on that measurement, NOT to make a file pass:
      # widening an accepted-syntax list to silence a refusal is shaping a control
      # around its own answer, which is the failure this whitelist exists to avoid.
      $0 ~ ("^[[:space:]]*(\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*trap[[:space:]]+" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("^[[:space:]]*(if|elif)[[:space:]].*;[[:space:]]*then[[:space:]]+" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      $0 ~ ("#[[:space:]]*indirect-call:[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { found = 1 }
      END { exit(found ? 0 : 1) }
    '; then
      return 0
    fi
  done
  return 1
}

# Blank every quoted span, so quoted text is DATA and never read as code.
#
# This is a real walk over two states rather than a per-line heuristic, because
# the heuristic was wrong in the direction that matters. Counting quotes per line
# treats a MULTI-LINE single-quoted string - a jq program, a multi-line constant -
# as unbalanced, which marked most of this repository unreadable and turned every
# predicate into could-not-observe. A single quote inside DOUBLE quotes is not a
# quote opener, which is why double-quote state is tracked too: without it the
# quote-escape dance this repo uses everywhere would desynchronise the walk.
#
# Prints the file with quoted spans blanked. Exits 1 if a span is still
# open at end of file, the one case this cannot resolve.
strip_quoted() {  # <file>
  awk '
    BEGIN { mode = "normal"; escaped = 0; subdepth = 0; saw_backtick = 0 }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        nextc = substr($0, i + 1, 1)
        if (mode == "sq") { if (c == "\047") mode = "normal"; continue }
        if (mode == "subsq") { if (c == "\047") mode = "sub"; continue }
        if (mode == "ansi" || mode == "subansi") {
          if (escaped) { escaped = 0; continue }
          if (c == "\\") { escaped = 1; continue }
          if (c == "\047") mode = (mode == "ansi" ? "normal" : "sub")
          continue
        }
        if (mode == "dq" || mode == "subdq") {
          if (escaped) { escaped = 0; continue }
          if (c == "\\") { escaped = 1; continue }
          if (c == "$" && nextc == "(") {
            subdepth++
            parens[subdepth] = 1
            returns[subdepth] = mode
            mode = "sub"
            out = out "$("
            i++
            continue
          }
          if (c == "`") saw_backtick = 1
          if (c == "\"") mode = (mode == "dq" ? "normal" : "sub")
          continue
        }
        # A comment ends the line. Shell ignores an apostrophe in prose, and
        # without this every "control\047s" or "doesn\047t" in a header opened a
        # quote that never closed, so the file read as unterminated and every
        # predicate in it became could-not-observe.
        if (c == "#" && (i == 1 || substr($0, i-1, 1) ~ /[ \t]/)) break
        if (c == "$" && nextc == "\047") {
          mode = (mode == "sub" ? "subansi" : "ansi")
          i++
          continue
        }
        if (c == "\047") { mode = (mode == "sub" ? "subsq" : "sq"); continue }
        if (c == "\"") { mode = (mode == "sub" ? "subdq" : "dq"); continue }
        if (c == "`") saw_backtick = 1
        if (mode == "sub" && c == "(") parens[subdepth]++
        if (mode == "sub" && c == ")") {
          parens[subdepth]--
          if (parens[subdepth] == 0) {
            mode = returns[subdepth]
            delete parens[subdepth]
            delete returns[subdepth]
            subdepth--
          }
        }
        out = out c
      }
      print out
    }
    END {
      if (mode != "normal" || subdepth != 0) exit 1
      if (saw_backtick) exit 2
    }
  ' "$1"
}

# Why a file may not be reasoned about at all. Returns the offending
# "<line>:<text>" on stdout and 1 when the file is outside the accepted syntax.
file_parse_refusal() {  # <file>
  local f=$1 hit strip_rc
  hit=$({ grep -nF '<<' "$f" | grep -vF '<<<'
          grep -nE '^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*(\{|$)|^[[:space:]]*function[[:space:]]+[A-Za-z_]' "$f"
        } | head -1)
  if [ -z "$hit" ]; then
    strip_quoted "$f" >/dev/null 2>&1
    strip_rc=$?
    case $strip_rc in
      0) ;;
      1) hit="0:unterminated quoted string" ;;
      2) hit="0:legacy backtick substitution" ;;
      *) hit="0:quote walk failed" ;;
    esac
  fi
  [ -z "$hit" ] && return 0
  printf '%s\n' "$hit"
  return 1
}

# Every shell file a call site could live in. The scan is REPO-WIDE because the
# property is repo-wide: a predicate called from anywhere is not dead. Retreating
# to enrolled files narrowed the scope AND silently changed what DEAD means, so
# the same call produced a different verdict depending on which files happened to
# be enrolled - a verdict that depends on configuration rather than on the code.
consumer_files() {
  local d
  for d in "$ROOT/bin" "$ROOT/tests" "$ROOT/.agents"; do
    [ -d "$d" ] || continue
    find "$d" -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null
  done | sort -u
}

enrolled_files() {
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    printf '%s\n' "${TARGETS[@]}"
    return 0
  fi
  # -x, an EXACT full-line match. A substring match self-enrolled this very
  # file, because its own header quotes the marker while documenting it; any
  # file that merely mentions the rule would have been enrolled by describing it.
  grep -rlxF "$ENROL_MARKER" "$ROOT/bin" 2>/dev/null | sort
}

FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(enrolled_files)

if [ "${#FILES[@]}" -eq 0 ]; then
  printf 'fm-dead-predicate-check: COULD-NOT-OBSERVE - no enrolled file found (marker: %s)\n' \
    "$ENROL_MARKER" >&2
  exit 4
fi

for f in "${FILES[@]}"; do
  [ -r "$f" ] || die "target is unreadable: $f" 4
  grep -qxF "$ENROL_MARKER" "$f" 2>/dev/null || die "target is not enrolled: $f" 4
  unsupported=$({ grep -nF '<<' "$f" | grep -vF '<<<'; grep -nE '^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)\(\)[[:space:]]*(\{|$)|^[[:space:]]*function[[:space:]]+[A-Za-z_]' "$f"; } | head -1)
  [ -z "$unsupported" ] \
    || die "UNCHECKED $f:${unsupported%%:*} unsupported construct: ${unsupported#*:}" 4
done

# Partition every consumer into those this control can reason about and those it
# cannot. An unchecked consumer is NAMED, not skipped: the list is the honest
# measurement of how much of the repository this control can actually see, and
# the way to shorten it is to make more files parse.
SCANNABLE=()
UNCHECKED_CONSUMERS=()
UNCHECKED_FILES=()
while IFS= read -r cf; do
  [ -n "$cf" ] || continue
  [ -r "$cf" ] || { UNCHECKED_CONSUMERS+=("$cf: unreadable"); UNCHECKED_FILES+=("$cf"); continue; }
  if refusal=$(file_parse_refusal "$cf"); then
    SCANNABLE+=("$cf")
  else
    UNCHECKED_CONSUMERS+=("$cf:${refusal%%:*} ${refusal#*:}")
    UNCHECKED_FILES+=("$cf")
  fi
done < <(consumer_files)

FUNCTIONS=()
for f in "${FILES[@]}"; do
  while IFS= read -r line; do FUNCTIONS+=("${line#*:}"); done < <(function_definitions "$f")
done
VALIDATED_SCANNABLE=()
for f in "${SCANNABLE[@]}"; do
  unsupported=''
  for fn in "${FUNCTIONS[@]}"; do
    grep -Eq "#[[:space:]]*indirect-call:[[:space:]]*$fn([^A-Za-z0-9_]|$)" "$f" && continue
    unsupported=$(strip_quoted "$f" | awk -v fn="$fn" '
      $0 ~ "^[[:space:]]*#" { next }
      $0 ~ ("^" fn "\\(\\)[[:space:]]*\\{") { next }
      $0 ~ ("^[[:space:]]*((if|then|elif|else|while|until|do|!|command|builtin|env)[[:space:]]+)*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\\$\\(" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[A-Za-z_][A-Za-z0-9_]*\\(\\)[[:space:]]*\\{[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[^\"\047`]*([;|&(){}])[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("\\$\\(" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\\$\\(.*[[:space:]]\\|[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*(if|while|until)[[:space:]].*[[:space:]](\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*[[:space:]](\\|\\||&&)[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*.*[[:space:]](\\|\\||&&)[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*if[[:space:]].*[[:space:]]\\|[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*\\{.*[[:space:]](&&|\\|\\|)[[:space:]]*!?[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("[[:space:]]\\|\\|[[:space:]]*\\{[[:space:]]*" fn "([^A-Za-z0-9_]|$)") { next }
      # A CONTINUATION LINE that opens with || or && , optionally negated. This is
      # a genuine call site and a common idiom - measured at 65 occurrences across
      # bin/ - so its absence was the whitelist being under-specified rather than
      # the code being unusual. Added on that measurement, NOT to make a file pass:
      # widening an accepted-syntax list to silence a refusal is shaping a control
      # around its own answer, which is the failure this whitelist exists to avoid.
      $0 ~ ("^[[:space:]]*(\\|\\||&&)[[:space:]]*(![[:space:]]*)?" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*trap[[:space:]]+" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ ("^[[:space:]]*(if|elif)[[:space:]].*;[[:space:]]*then[[:space:]]+" fn "([^A-Za-z0-9_]|$)") { next }
      $0 ~ /^[[:space:]]*printf[[:space:]]/ { next }
      $0 ~ ("(^|[[:space:];|&(){}])" fn "([[:space:];|&(){}]|$)") { print NR ":" $0; exit }
    ')
    [ -z "$unsupported" ] || break
  done
  if [ -n "$unsupported" ]; then
    UNCHECKED_CONSUMERS+=("$f:${unsupported%%:*} unsupported call-site form for $fn: ${unsupported#*:}")
    UNCHECKED_FILES+=("$f")
  else
    VALIDATED_SCANNABLE+=("$f")
  fi
done
SCANNABLE=("${VALIDATED_SCANNABLE[@]}")

# WHAT THE COMPLETENESS CLAIM COVERS, AND WHERE IT STOPS.
#
# The per-predicate universe check closes the class for THIS control's own
# enumeration path: every read it performs is three-valued, and a read that fails
# yields could-not-observe rather than a negative answer.
#
# It does NOT close the class for the shared landing library this control's
# callers use. fm_landed_candidate_refs returns success whenever ANY candidate ref
# resolved, so a push-target read that fails inside the library leaves that ref
# simply absent from a NON-EMPTY list. From outside, an incomplete candidate set
# is indistinguishable from a complete one, and no check here can detect it.
#
# That gap is filed as landed-lib-unreadable-push-target-collapses and is
# deliberately out of scope here: the library is shared with the worktree guard,
# teardown, the decision surface and the task-base library, and changing its
# landing semantics from a task about outbound transport would be an unreviewed
# change to the guards that protect unlanded work.
#
# So the claim is scoped rather than class-wide, and saying so is the point: a
# control named class-level that silently depended on someone else's unfixed
# read would be the coverage inflation this file's other scope note refuses.

# WHY THIS MATCH IS ALLOWED TO BE LOOSE, AND WHERE THAT STOPS.
#
# The grep below is a bare identifier match with no syntax analysis behind it. It
# is legitimate here, and ONLY here, because of what it is used FOR: it decides
# whether an unparseable file belongs in a predicate's candidate universe, and
# the answer is only ever used to EXCLUDE. A false positive costs a
# COULD_NOT_OBSERVE - the control says "I could not tell" about a predicate that
# may in fact be dead. That is a wasted opportunity and nothing worse.
#
# The identical looseness used to CONFIRM that a call exists would be the
# opposite: it would let a mention in a comment, a quoted string or a heredoc
# payload establish that a predicate is ALIVE, which is discovery mistaken for
# identity - the defect this file has been falsified over seven times. A false
# positive there does not cost an opportunity, it hides a dead guard behind
# evidence that was never a call.
#
# So the asymmetry is the licence, not an accident of implementation: loose to
# EXCLUDE, never to CONFIRM. Nothing may route a call-site confirmation through
# UNCHECKED_CANDIDATES or through function_has_unchecked_candidate. Confirmation
# goes through function_has_call_site, which reads quote-stripped text and
# accepts only the enumerated call forms.
UNCHECKED_CANDIDATES=()
for f in "${UNCHECKED_FILES[@]}"; do
  if [ ! -r "$f" ]; then
    UNCHECKED_CANDIDATES+=("${FUNCTIONS[@]}")
    continue
  fi
  for fn in "${FUNCTIONS[@]}"; do
    grep -Eq "(^|[^A-Za-z0-9_])$fn([^A-Za-z0-9_]|$)" "$f" \
      && UNCHECKED_CANDIDATES+=("$fn")
  done
done

function_has_unchecked_candidate() {  # <function>
  local fn=$1 candidate
  for candidate in "${UNCHECKED_CANDIDATES[@]}"; do
    [ "$candidate" = "$fn" ] && return 0
  done
  return 1
}

dead_json='[]'
marked_json='[]'
cno_json='[]'
DEAD=0
MARKED=0
CNO=0
ALIVE=0

for f in "${FILES[@]}"; do
  [ -r "$f" ] || die "target is unreadable: $f" 4
  grep -qxF "$ENROL_MARKER" "$f" 2>/dev/null || die "target is not enrolled: $f" 4
  while IFS= read -r line; do
    lineno=${line%%:*}
    fn=${line#*:}
    [ -n "$fn" ] || continue
    if function_has_call_site "$fn"; then ALIVE=$((ALIVE + 1)); continue; fi
    prev=$((lineno - 1))
    if [ "$prev" -ge 1 ] && sed -n "${prev}p" "$f" | grep -qF "$KEEP_MARKER"; then
      reason=$(sed -n "${prev}p" "$f" | sed "s/.*${KEEP_MARKER}[[:space:]]*//")
      marked_json=$(printf '%s' "$marked_json" | jq --arg f "$f" --arg fn "$fn" \
        --argjson l "$lineno" --arg r "$reason" '. + [{file:$f,function:$fn,line:$l,reason:$r}]')
      MARKED=$((MARKED + 1))
      continue
    fi
    # No call site among the files this control can read. Whether that means
    # DEAD depends on whether it could read everywhere: with an unchecked
    # consumer outstanding, the call site may be in a file nobody looked at, and
    # asserting DEAD there would licence deleting live code. Missing a dead
    # predicate wastes an opportunity; deleting a live one is an outage.
    if function_has_unchecked_candidate "$fn"; then
      cno_json=$(printf '%s' "$cno_json" | jq --arg f "$f" --arg fn "$fn" --argjson l "$lineno" \
        '. + [{file:$f,function:$fn,line:$l}]')
      CNO=$((CNO + 1))
      continue
    fi
    dead_json=$(printf '%s' "$dead_json" | jq --arg f "$f" --arg fn "$fn" --argjson l "$lineno" \
      '. + [{file:$f,function:$fn,line:$l}]')
    DEAD=$((DEAD + 1))
  done < <(function_definitions "$f")
done

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson dead "$dead_json" --argjson marked "$marked_json" \
    --argjson cno "$cno_json" \
    --argjson files "$(printf '%s\n' "${FILES[@]}" | jq -R . | jq -s .)" \
    --argjson unchecked "$(printf '%s\n' "${UNCHECKED_CONSUMERS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" \
    --argjson scanned "${#SCANNABLE[@]}" --argjson alive "$ALIVE" \
    '{schema:"fm-dead-predicate-check.v1",enrolled:$files,scanned_consumers:$scanned,
      unchecked_consumers:$unchecked,alive:$alive,dead:$dead,could_not_observe:$cno,marked:$marked}'
else
  printf '%s' "$marked_json" | jq -r '.[] |
    "  marked   \(.function)  \(.file):\(.line)  unused by design: \(.reason)"'
  printf '%s' "$cno_json" | jq -r '.[] |
    "  CNO      \(.function)  \(.file):\(.line)  no call site among files this control can read"'
  printf '%s' "$dead_json" | jq -r '.[] |
    "  DEAD     \(.function)  \(.file):\(.line)  defined and never consulted"'
  if [ "${#UNCHECKED_CONSUMERS[@]}" -gt 0 ]; then
    printf '\n%s consumer file(s) UNCHECKED - outside the accepted syntax, so no call site in them was read:\n' \
      "${#UNCHECKED_CONSUMERS[@]}"
    printf '  %s\n' "${UNCHECKED_CONSUMERS[@]}"
    printf 'This list measures how much of the repository this control can see. Shorten it by making files parse.\n'
  fi
  if [ "$DEAD" -eq 0 ] && [ "$CNO" -eq 0 ]; then
    # alive= and could_not_observe= are printed ALWAYS, including when both are
    # zero. A line reading only "no dead predicates" is equally consistent with
    # every predicate resolved and with none of them being resolvable, and those
    # are different facts. A quiet control must never read as a clean repository.
    printf 'fm-dead-predicate-check: ok enrolled=%s scanned=%s unchecked=%s alive=%s could_not_observe=%s marked=%s\n' \
      "${#FILES[@]}" "${#SCANNABLE[@]}" "${#UNCHECKED_CONSUMERS[@]}" "$ALIVE" "$CNO" "$MARKED"
  elif [ "$DEAD" -gt 0 ]; then
    printf '\n%s function(s) exist but nothing consults them. A guard nothing calls is not a guard.\n' "$DEAD"
    printf 'Wire each one in, or mark the definition with "# %s <reason>" on the line above it.\n' "$KEEP_MARKER"
  else
    printf '\n%s function(s) COULD NOT BE OBSERVED: no call site was found, but an unchecked consumer may hold one.\n' "$CNO"
    printf 'That is not a pass and not a dead predicate. Make the unchecked consumers parse to resolve it.\n'
  fi
fi

# Exit is three-valued and in that order of severity. Unchecked consumers ALONE
# never make this red: a control that is permanently red gets ignored and then
# removed, and every case it enforces would be lost with it. They are reported
# and counted, and only bite when a predicate's verdict actually depends on one.
[ "$DEAD" -eq 0 ] || exit 3
[ "$CNO" -eq 0 ] || exit 4
exit 0
